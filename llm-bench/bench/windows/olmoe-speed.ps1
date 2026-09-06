Set-Location "C:\Users\g.strainovic\projects\ki\colibri\c"

$env:SNAP = "..\olmoe_merged"
$env:CHAT = "1"
$env:CTX = "2048"
$env:TEMP = "0.7"
$env:NUCLEUS = "0.95"

$prompt = "Write a long detailed essay about the history of the Rhine river, at least 600 words."
$tmp = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmp, $prompt + "`n", [System.Text.Encoding]::UTF8)

$results = @{}
foreach ($n in @(40, 240)) {
    $env:MAX_NEW = "$n"
    $times = @()
    foreach ($rep in 1..2) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = & cmd /c "type `"$tmp`" | .\olmoe.exe 64 8 2>&1"
        $sw.Stop()
        $times += $sw.Elapsed.TotalSeconds
    }
    $results[$n] = ($times | Measure-Object -Minimum).Minimum
    "MAX_NEW=$n : $([math]::Round($results[$n],2)) s (bester von 2)"
}
Remove-Item $tmp -Force

$slope = ($results[240] - $results[40]) / 200.0
"Steady-State-Dekodierung: $([math]::Round(1.0/$slope, 2)) tok/s  ($([math]::Round($slope*1000,1)) ms/Token)"
