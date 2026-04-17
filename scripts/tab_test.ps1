param(
    [string]$OutFile = "tab_test.png",
    [int]$WaitMs = 5000
)

$exePath = "zig-out\bin\vulkan-ed.exe"
$ScreenDir = "screenshots"
$OutPath = Join-Path $ScreenDir $OutFile

if (-Not (Test-Path $ScreenDir)) {
    New-Item -ItemType Directory -Path $ScreenDir | Out-Null
}

# Win32 API
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hDC, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr p);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

function Get-WindowHwnd($pid) {
    $hwnd = [IntPtr]::Zero
    $maxArea = 0
    [Win32]::EnumWindows({
        param($hWnd, $p)
        $outPid = 0
        [Win32]::GetWindowThreadProcessId($hWnd, [ref]$outPid) | Out-Null
        if ($outPid -eq $pid -and [Win32]::IsWindowVisible($hWnd)) {
            $r = New-Object Win32+RECT
            [Win32]::GetWindowRect($hWnd, [ref]$r) | Out-Null
            $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
            if ($area -gt $maxArea) {
                $maxArea = $area
                $hwnd = $hWnd
            }
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    return $hwnd
}

function Take-Screenshot($hwnd, $path) {
    $rect = New-Object Win32+RECT
    [Win32]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [Win32]::PrintWindow($hwnd, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $bmp.Save($path)
    $bmp.Dispose()
    Write-Host "Screenshot: ${w}x${h} -> $path"
}

function Send-Rpc($method, $params, $id) {
    $msg = "{`"jsonrpc`": `"2.0`",`"id`":$id,`"method`":`"$method`",`"params`":$params}"
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', 9999)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream)
    $reader = New-Object System.IO.StreamReader($stream)
    $writer.WriteLine($msg)
    $writer.Flush()
    $stream.Flush()
    Start-Sleep -Milliseconds 200
    $result = $null
    if ($stream.DataAvailable) {
        $result = $reader.ReadLine()
    }
    $client.Close()
    return $result
}

Write-Host "=== Tab Test ==="
Write-Host "Building..."
& zig build 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!"; exit 1 }

Write-Host "Starting app in E2E mode..."
$proc = Start-Process -FilePath (Resolve-Path $exePath).Path -ArgumentList "--e2e" -PassThru -WindowStyle Normal
Start-Sleep -Seconds 3

$hwnd = Get-WindowHwnd $proc.Id
if ($hwnd -eq [IntPtr]::Zero) { Write-Host "No window!"; $proc | Stop-Process -Force; exit 1 }

Write-Host "Taking initial screenshot..."
Take-Screenshot $hwnd (Join-Path $ScreenDir "before_tabs.png")

Write-Host "Opening tabs via RPC..."
Send-Rpc "open_file" '["src/main.zig"]' 1 | Out-Null
Start-Sleep -Milliseconds 300
Send-Rpc "open_file" '["src/ui/mod.zig"]' 2 | Out-Null
Start-Sleep -Milliseconds 300
Send-Rpc "open_file" '["src/ui/tab_bar.zig"]' 3 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "Screenshot after opening 3 tabs..."
Take-Screenshot $hwnd (Join-Path $ScreenDir "three_tabs.png")

Write-Host "Closing tab 0 via RPC..."
Send-Rpc "close_tab" '[0]' 4 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "Screenshot after closing tab 0..."
Take-Screenshot $hwnd (Join-Path $ScreenDir "two_tabs.png")

Write-Host "Closing another tab..."
Send-Rpc "close_tab" '[0]' 5 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "Final screenshot..."
Take-Screenshot $hwnd $OutPath

$proc | Stop-Process -Force
Write-Host "Done! Check $OutPath"