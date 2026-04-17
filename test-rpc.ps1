$client = New-Object System.Net.Sockets.TcpClient
$client.Connect('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$reader = New-Object System.IO.StreamReader($stream)

function sendCmd($method, $params, $id) {
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

# Open a file first
$r = sendCmd "open_file" '["src/main.zig"]' 1
Write-Host "Open: $r"

# Open another file
$r = sendCmd "open_file" '["src/ui/mod.zig"]' 2
Write-Host "Open2: $r"

# Close tab 0
$r = sendCmd "close_tab" '[0]' 3
Write-Host "Close tab 0: $r"

# Wait a bit for processing
Start-Sleep -Milliseconds 500

# Close tab 0 again (now the first tab should be the other file)
$r = sendCmd "close_tab" '[0]' 4
Write-Host "Close tab 0 again: $r"

# Wait
Start-Sleep -Milliseconds 500

$client.Close()
Write-Host "done"