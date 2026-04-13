param(
    [string]$OutFile = "phase11_skeleton.png",
    [int]$WaitMs = 5000
)

$ScreenDir = "screenshots"
$ExePath = "libs\flow\zig-out\bin\flow-gui.exe"

if (-Not (Test-Path $ScreenDir)) {
    New-Item -ItemType Directory -Path $ScreenDir | Out-Null
}

$OutPath = Join-Path $ScreenDir $OutFile

Write-Host "=== Phase 11 Screenshot ==="
Write-Host "Output: $OutPath"
Write-Host "Binary: $ExePath"

if (-Not (Test-Path $ExePath)) {
    Write-Host "Executable not found! Build first: cd libs\flow && zig build -Drenderer=vulkan_ed"
    exit 1
}

# Win32 API for screenshot
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hDC, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc e, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr p);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

Write-Host "Launching flow-gui..."
$proc = Start-Process -FilePath (Resolve-Path $ExePath).Path -PassThru -WindowStyle Normal
Write-Host "Started PID $($proc.Id)..."

# Poll for window
$startTime = Get-Date
$targetHwnd = [IntPtr]::Zero
$maxArea = 0
while ((Get-Date).Subtract($startTime).TotalMilliseconds -lt $WaitMs) {
    if ($proc.HasExited) { break }
    $maxArea = 0
    [Win32]::EnumWindows({
        param($hWnd, $p)
        $outPid = 0
        [Win32]::GetWindowThreadProcessId($hWnd, [ref]$outPid) | Out-Null
        if ($outPid -eq $proc.Id -and [Win32]::IsWindowVisible($hWnd)) {
            $r = New-Object Win32+RECT
            [Win32]::GetWindowRect($hWnd, [ref]$r) | Out-Null
            $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
            if ($area -gt 50000 -and $area -gt $script:maxArea) {
                $script:maxArea = $area
                $script:targetHwnd = $hWnd
            }
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    $targetHwnd = $script:targetHwnd
    $maxArea = $script:maxArea
    if ($targetHwnd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 200
}

if ($targetHwnd -eq [IntPtr]::Zero) {
    Write-Host "No window found (process may have crashed)!"
    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    exit 1
}

Start-Sleep -Milliseconds 500

$rect = New-Object Win32+RECT
[Win32]::GetWindowRect($targetHwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
Write-Host "Window: ${w}x${h}"

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[Win32]::PrintWindow($targetHwnd, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()
$bmp.Save($OutPath)
$bmp.Dispose()
Write-Host "Saved: $OutPath"

$proc | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "Done!"
