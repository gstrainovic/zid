$ErrorActionPreference = "Continue"
$c = "C:\Users\g.strainovic\projects\ki\colibri\c"
Set-Location $c

$env:SNAP = "..\olmoe_merged"
$env:CHAT = "1"
$env:CTX = "2048"
$env:MAX_NEW = "220"
$env:TEMP = "0.2"
$env:NUCLEUS = "0.95"

$toolSys = @'
You are a tool-using agent. You have exactly these tools and no others:
read_file(path) / write_file(path, text) / list_dir(path) / run_shell(cmd) / search(pattern, path)
Reply with a single JSON object and nothing else: {"tool": "<name>", "args": {...}}
'@

$prompts = @(
    @{ name = "1-tool-call-json"; text = "$toolSys`n`nTask: Show me the contents of /etc/hosts." },
    @{ name = "2-code-python"; text = "Write a Python function quicksort(a) that returns a new sorted list. Output only code, no explanation." },
    @{ name = "3-instruction-strict"; text = "Answer with exactly one word, uppercase, nothing else: what is the capital of Switzerland?" },
    @{ name = "4-german"; text = "Erklaere in zwei Saetzen auf Deutsch, was ein Index in einer relationalen Datenbank bewirkt." },
    @{ name = "5-reasoning"; text = "A shop sells pens at 3 for 5 francs. I buy 21 pens and pay with a 50 franc note. How much change do I get? Think step by step, then give the final number after 'ANSWER:'." },
    @{ name = "6-agent-multistep"; text = "You are a coding agent. Tools: read_file(path), edit_file(path, old, new), run_tests(). Output a numbered plan of tool calls only, one per line, format: N. tool(args). No prose.`n`nThe test suite fails because utils.py has a typo: 'lenght' should be 'length'. Fix it and verify." }
)

foreach ($p in $prompts) {
    $tmp = [System.IO.Path]::GetTempFileName()
    # single line prompt: newlines inside would submit early, so flatten
    $flat = ($p.text -replace "\r?\n", " ")
    [System.IO.File]::WriteAllText($tmp, $flat + "`n", [System.Text.Encoding]::UTF8)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & cmd /c "type `"$tmp`" | .\olmoe.exe 64 8 2>&1"
    $sw.Stop()
    Remove-Item $tmp -Force

    "===== OLMoE-1B-7B(colibri) :: $($p.name) | $([math]::Round($sw.Elapsed.TotalSeconds,1))s wall (inkl. Laden)"
    ($out | Where-Object { $_ -notmatch '^\[OMP\]|^\[stop\]|^olmoe chat|type a message|resident weights' })
    ""
}
