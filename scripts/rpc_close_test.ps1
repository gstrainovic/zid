param(
    [string]$OutFile = "rpc_close_test.png",
    [int]$WaitMs = 8000
)

$exePath = "zig-out\bin\vulkan-ed.exe"
$ScreenDir = "screenshots"

if (-Not (Test-Path $ScreenDir)) {
    New-Item -ItemType Directory -Path $ScreenDir | Out-Null
}

$OutPath = Join-Path $ScreenDir $OutFile

Write-Host "=== RPC Close Tab Test ==="

# Build
& zig build 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!"; exit 1 }

# Start app in E2E mode
$proc = Start-Process -FilePath (Resolve-Path $exePath).Path -ArgumentList "--e2e" -PassThru -WindowStyle Normal
Write-Host "Started PID $($proc.Id)"

# Wait for window + RPC server to be ready
Start-Sleep -Milliseconds $WaitMs

# Win32 API - MUST come before EnumWindows
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

# Find window FIRST
$script:targetHwnd = [IntPtr]::Zero
$script:maxArea = 0
[Win32]::EnumWindows({
    param($hWnd, $p)
    $outPid = 0
    [Win32]::GetWindowThreadProcessId($hWnd, [ref]$outPid) | Out-Null
    if ($outPid -eq $proc.Id -and [Win32]::IsWindowVisible($hWnd)) {
        $r = New-Object Win32+RECT
        [Win32]::GetWindowRect($hWnd, [ref]$r) | Out-Null
        $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
        if ($area -gt $script:maxArea) {
            $script:maxArea = $area
            $script:targetHwnd = $hWnd
        }
    }
    return $true
}, [IntPtr]::Zero) | Out-Null

Write-Host "Window hwnd: $($script:targetHwnd)"

function Take-Pic($path) {
    if ($script:targetHwnd -eq [IntPtr]::Zero) { Write-Host "No hwnd for $path!"; return }
    $rect = New-Object Win32+RECT
    [Win32]::GetWindowRect($script:targetHwnd, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [Win32]::PrintWindow($script:targetHwnd, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save($path); $bmp.Dispose()
    Write-Host "Pic: $path"
}

# RPC connection AFTER window find
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

function rpc($method, $params, $id) {
    $msg = "{`"jsonrpc`": `"2.0`",`"id`":$id,`"method`":`"$method`",`"params`":$params}"
    $writer.WriteLine($msg)
    $writer.Flush()
    $stream.Flush()
    Start-Sleep -Milliseconds 200
    $r = $null
    if ($stream.DataAvailable) { $r = $reader.ReadLine() }
    return $r
}

Write-Host "Opening 3 files..."
rpc "open_file" '["src/main.zig"]' 1 | Out-Null
rpc "open_file" '["src/ui/mod.zig"]' 2 | Out-Null
rpc "open_file" '["src/ui/tab_bar.zig"]' 3 | Out-Null
Start-Sleep -Milliseconds 300

Write-Host "Before close - 3 tabs open..."
Take-Pic (Join-Path $ScreenDir "3tabs_open.png")

# Close tab 0 via RPC
Write-Host "Closing tab 0 via RPC..."
$r = rpc "close_tab" '[0]' 4
Write-Host "Result: $r"
Start-Sleep -Milliseconds 500

Write-Host "After RPC close..."
Take-Pic (Join-Path $ScreenDir "2tabs_after_rpc_close.png")

# Try clicking on close button of remaining tab
Write-Host "Clicking close button (x=200, y=18)..."
$r = rpc "click" '[200.0, 18.0]' 5
Write-Host "Click result: $r"
Start-Sleep -Milliseconds 500

Write-Host "After click..."
Take-Pic $OutPath

$client.Close()
$proc | Stop-Process -Force
Write-Host "Done!"