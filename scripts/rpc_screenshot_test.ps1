$client = New-Object System.Net.Sockets.TcpClient
$client.Connect('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

function Send-Cmd($method, $params, $id) {
    $msg = "{`"jsonrpc`": `"2.0`",`"id`":$id,`"method`":`"$method`",`"params`":$params}"
    $writer.WriteLine($msg)
    $writer.Flush()
    $stream.Flush()
    Start-Sleep -Milliseconds 200
    if ($stream.DataAvailable) {
        return $reader.ReadLine()
    }
    return $null
}

# Win32 API for screenshots
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
    $result = [IntPtr]::Zero
    $maxArea = 0
    [Win32]::EnumWindows({
        param($hWnd, $p)
        $outPid = 0
        [Win32]::GetWindowThreadProcessId($hWnd, [ref]$outPid) | Out-Null
        if ($outPid -eq $pid -and [Win32]::IsWindowVisible($hWnd)) {
            $r = New-Object Win32+RECT
            [Win32]::GetWindowRect($hWnd, [ref]$r) | Out-Null
            $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
            if ($area -gt $script:maxArea) {
                $script:maxArea = $area
                $result = $hWnd
            }
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    return $result
}

function Take-Screenshot($hwnd, $path) {
    $rect = New-Object Win32+RECT
    [Win32]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0 -or $h -le 0) { Write-Host "Invalid window size $w x $h"; return }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [Win32]::PrintWindow($hwnd, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $bmp.Save($path)
    $bmp.Dispose()
    Write-Host "Screenshot: $w x $h -> $path"
}

# Find our process
$procs = Get-Process | Where-Object { $_.Name -like "vulkan-ed" -and $_.Id -ne $PID }
if ($procs.Count -eq 0) {
    Write-Host "No vulkan-ed process found!"
    exit 1
}
$proc = $procs[0]
Write-Host "Found PID: $($proc.Id)"

$hwnd = Get-WindowHwnd $proc.Id
if ($hwnd -eq [IntPtr]::Zero) { Write-Host "No window found!"; exit 1 }
Write-Host "Window hwnd: $hwnd"

# Initial state
Write-Host "Taking initial screenshot..."
Take-Screenshot $hwnd "screenshots/rpc_test_initial.png"

# Open 3 tabs via RPC
Write-Host "Opening 3 tabs via RPC..."
Send-Cmd "open_file" '["src/main.zig"]' 1 | Out-Null
Start-Sleep -Milliseconds 300
Send-Cmd "open_file" '["src/ui/mod.zig"]' 2 | Out-Null
Start-Sleep -Milliseconds 300
Send-Cmd "open_file" '["src/ui/tab_bar.zig"]' 3 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "Screenshot with 3 tabs..."
Take-Screenshot $hwnd "screenshots/rpc_test_3tabs.png"

# Close tab 0 via RPC (this worked before)
Write-Host "Closing tab 0 via RPC..."
$result = Send-Cmd "close_tab" '[0]' 4
Write-Host "Close result: $result"
Start-Sleep -Milliseconds 500

Write-Host "Screenshot after RPC close..."
Take-Screenshot $hwnd "screenshots/rpc_test_after_close.png"

# Now try to click on close button area via RPC click
# The close button for tab 0 should be around x=200-220, y=10-30
Write-Host "Trying to click close button via RPC..."
$result = Send-Cmd "click" '[215.0, 18.0]' 5
Write-Host "Click result: $result"
Start-Sleep -Milliseconds 500

Write-Host "Screenshot after RPC click on close button..."
Take-Screenshot $hwnd "screenshots/rpc_test_after_click.png"

$client.Close()
Write-Host "Done!"