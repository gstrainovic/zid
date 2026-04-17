param(
    [string]$OutFile = "tabs_test.png",
    [int]$WaitMs = 8000
)

$exePath = "zig-out\bin\vulkan-ed.exe"
$ScreenDir = "screenshots"

if (-Not (Test-Path $ScreenDir)) {
    New-Item -ItemType Directory -Path $ScreenDir | Out-Null
}

$OutPath = Join-Path $ScreenDir $OutFile

Write-Host "=== Tab Test ==="
Write-Host "Building..."
& zig build 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!"
    exit 1
}
Write-Host "Build successful."

if (-Not (Test-Path $exePath)) {
    Write-Host "Executable not found at $exePath!"
    exit 1
}

Write-Host "Launching in E2E mode..."
$proc = Start-Process -FilePath (Resolve-Path $exePath).Path -ArgumentList "`"--e2e`"" -PassThru -WindowStyle Normal
Write-Host "Started PID $($proc.Id), waiting for window..."

Start-Sleep -Milliseconds $WaitMs

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

if ($script:targetHwnd -eq [IntPtr]::Zero) {
    Write-Host "No window found!"
    $proc | Stop-Process -Force
    exit 1
}

$rect = New-Object Win32+RECT
[Win32]::GetWindowRect($script:targetHwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top

Write-Host "Window: ${w}x${h}"

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[Win32]::PrintWindow($script:targetHwnd, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()

$bmp.Save($OutPath)
$bmp.Dispose()
Write-Host "Saved: $OutPath"

$proc | Stop-Process -Force
Write-Host "Done!"