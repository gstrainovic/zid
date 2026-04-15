param(
    [string]$OutFile = "screenshot_active.png"
)

$ScreenDir = "screenshots"
if (-Not (Test-Path $ScreenDir)) { New-Item -ItemType Directory -Path $ScreenDir | Out-Null }
$OutPath = Join-Path $ScreenDir $OutFile

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hDC, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc e, IntPtr p);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr p);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$script:targetHwnd = [IntPtr]::Zero
[Win32]::EnumWindows({
    param($hWnd, $p)
    $sb = New-Object System.Text.StringBuilder(256)
    [Win32]::GetWindowText($hWnd, $sb, 256) | Out-Null
    if ($sb.ToString() -eq "vulkan-ed") {
        $script:targetHwnd = $hWnd
        return $false
    }
    return $true
}, [IntPtr]::Zero) | Out-Null

if ($script:targetHwnd -eq [IntPtr]::Zero) {
    Write-Host "Target window 'vulkan-ed' not found!"
    exit 1
}

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

$bmp.Save($OutPath)
$bmp.Dispose()
Write-Host "Screenshot saved to: $OutPath"
