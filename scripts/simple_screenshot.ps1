param(
    [string]$OutFile = "test.png",
    [string]$ExtraArgs = ""
)

$exePath = "zig-out\bin\vulkan-ed.exe"
$ScreenDir = "screenshots"
$OutPath = Join-Path $ScreenDir $OutFile

if (-Not (Test-Path $ScreenDir)) {
    New-Item -ItemType Directory -Path $ScreenDir | Out-Null
}

# Build
Write-Host "Building..."
& zig build 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed!"; exit 1 }

# Start
$proc = Start-Process -FilePath (Resolve-Path $exePath).Path -ArgumentList $ExtraArgs -PassThru -WindowStyle Normal
Write-Host "Started PID $($proc.Id), waiting..."

Start-Sleep -Milliseconds 4000

# Win32 API - same as original screenshot.ps1
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

Write-Host "Window: $($script:targetHwnd) area=$($script:maxArea)"

$rect = New-Object Win32+RECT
[Win32]::GetWindowRect($script:targetHwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
Write-Host "Size: ${w}x${h}"

if ($w -gt 0 -and $h -gt 0) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [Win32]::PrintWindow($script:targetHwnd, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $bmp.Save($OutPath)
    $bmp.Dispose()
    Write-Host "Saved: $OutPath"
} else {
    Write-Host "Invalid window size"
}

$proc | Stop-Process -Force
Write-Host "Done!"