# E2E Test: Tab wechseln - Editor-Inhalt ändert sich nicht?

# Schritt 1: Zwei verschiedene Dateien öffnen
Write-Output "=== Schritt 1: Tab 1 (test_data/app.log) öffnen ==="
$client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$writer.WriteLine('{"jsonrpc":"2.0","method":"open_folder","params":["test_data"],"id":1}')
$writer.Flush()
Start-Sleep -Milliseconds 500
$reader = New-Object System.IO.StreamReader($stream)
Write-Output "Response: $($reader.ReadLine())"
$client.Close()
Start-Sleep -Milliseconds 500

# Schritt 2: State prüfen - welche Tabs sind offen?
Write-Output "`n=== Schritt 2: State prüfen ==="
$client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$writer.WriteLine('{"jsonrpc":"2.0","method":"get_state","params":[],"id":2}')
$writer.Flush()
Start-Sleep -Milliseconds 500
$reader = New-Object System.IO.StreamReader($stream)
Write-Output "Response: $($reader.ReadLine())"
$client.Close()
Start-Sleep -Milliseconds 500

# Schritt 3: Datei im File Explorer öffnen (zweite Datei)
Write-Output "`n=== Schritt 3: Build.zig als zweiten Tab öffnen ==="
$client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$writer.WriteLine('{"jsonrpc":"2.0","method":"open_folder","params":["src"],"id":3}')
$writer.Flush()
Start-Sleep -Milliseconds 500
$reader = New-Object System.IO.StreamReader($stream)
Write-Output "Response: $($reader.ReadLine())"
$client.Close()
Start-Sleep -Milliseconds 500

# Schritt 4: State nach dem Öffnen
Write-Output "`n=== Schritt 4: State nach zweitem Öffnen ==="
$client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 9999)
$stream = $client.GetStream()
$writer = New-Object System.IO.StreamWriter($stream)
$writer.WriteLine('{"jsonrpc":"2.0","method":"get_state","params":[],"id":4}')
$writer.Flush()
Start-Sleep -Milliseconds 500
$reader = New-Object System.IO.StreamReader($stream)
Write-Output "Response: $($reader.ReadLine())"
$client.Close()
Start-Sleep -Milliseconds 500

Write-Output "`n=== Problem: Tab wechseln lädt Datei nicht in Editor ==="
Write-Output "Lösung: setActive muss Datei-Pfad an main.zig melden, damit Editor-Inhalt geladen wird"
