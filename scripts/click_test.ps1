param(
    [string]$OutFile = "click_test.png",
    [int]$WaitMs = 10000
)

$exePath = "zig-out\bin\vulkan-ed.exe"
$ScreenDir = "screenshots"

if (-Not (Test-Path $ScreenDir)) {
    New-Item -ItemType Directory -Path $ScreenDir | Out-Null
}

$OutPath = Join-Path $ScreenDir $OutFile

Write-Host "=== Click Test ==="
Write-Host "Building..."
& zig build 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!"
    exit 1
}

Write-Host "Launching in E2E mode..."
$proc = Start-Process -FilePath (Resolve-Path $exePath).Path -ArgumentList "`"--e2e`"" -PassThru -WindowStyle Normal
Write-Host "Started PID $($proc.Id)"

# Wait for window + RPC server
Start-Sleep -Milliseconds $WaitMs

# RPC Client
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

function Send-Rpc($method, $params, $id) {
    $msg = "{`"jsonrpc`": `"2.0`",`"id`":$id,`"method`":`"$method`",`"params`":$params}"
    $writer.WriteLine($msg)
    $writer.Flush()
    $stream.Flush()
    Start-Sleep -Milliseconds 300
    if ($stream.DataAvailable) {
        return $reader.ReadLine()
    }
    return $null
}

# Open 2 files so we have 2 tabs
Write-Host "Opening files..."
Send-Rpc "open_file" '["src/main.zig"]' 1 | Out-Null
Start-Sleep -Milliseconds 200
Send-Rpc "open_file" '["src/ui/mod.zig"]' 2 | Out-Null
Start-Sleep -Milliseconds 200

# Take screenshot before any clicking
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

function Take-Screenshot($path) {
    if ($script:targetHwnd -eq [IntPtr]::Zero) { return }
    $rect = New-Object Win32+RECT
    [Win32]::GetWindowRect($script:targetHwnd, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [Win32]::PrintWindow($script:targetHwnd, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $bmp.Save($path)
    $bmp.Dispose()
    Write-Host "Screenshot: $path"
}

Write-Host "Screenshot before click..."
Take-Screenshot (Join-Path $ScreenDir "before_click.png")

# Try clicking on tab area at different positions
# Tab bar is typically at top, tabs are 36px high
# Close button is usually at right edge of tab (around x=180-220 for first tab)

Write-Host "Clicking at tab close button (x=200, y=18)..."
Send-Rpc "click" '[200.0, 18.0]' 3 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "Screenshot after click at close button..."
Take-Screenshot (Join-Path $ScreenDir "after_close_click.png")

Write-Host "Clicking at tab area (x=100, y=18) - should switch tabs..."
Send-Rpc "click" '[100.0, 18.0]' 4 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "Screenshot after click at tab area..."
Take-Screenshot (Join-Path $ScreenDir "after_tab_click.png")

Write-Host "Clicking the + button (x=300, y=18) - should open menu..."
Send-Rpc "click" '[300.0, 18.0]' 5 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "Screenshot after clicking + button..."
Take-Screenshot $OutPath

$client.Close()
$proc | Stop-Process -Force
Write-Host "Done! Check screenshots/"