$json = '{"jsonrpc": "2.0", "method": "open_file", "params": ["preview://AGENTS.md"], "id": 1}' + "`n"
$tcpClient = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 9999)
$stream = $tcpClient.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$writer.Write($json)
$writer.Flush()
$tcpClient.Close()
