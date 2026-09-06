Set-Location "C:\Users\g.strainovic\projects\ki\colibri\c"

$env:SNAP = "..\olmoe_merged"
$env:CHAT = "1"
$env:CTX = "2048"
$env:MAX_NEW = "120"
$env:TEMP = "0"
$env:NUCLEUS = "0.95"

# identical wording to agent-eval.ps1, flattened to one line (newline = submit in CHAT mode)
$sys = "You are a tool-using agent. You have exactly these tools and no others: " +
       "read_file(path) - read a file; " +
       "write_file(path, text) - write a file; " +
       "list_dir(path) - list a directory; " +
       "run_shell(cmd) - run a shell command; " +
       "search(pattern, path) - grep for a pattern. " +
       'Reply with a single JSON object and nothing else: {"tool": "<one of the five names above>", "args": {...}}'

$cases = @(
    @{ q = "What is inside README.md?"; want = "read_file" },
    @{ q = "Which files are in the src folder?"; want = "list_dir" },
    @{ q = "Create a file notes.txt containing the word hello."; want = "write_file" },
    @{ q = "Find every place where the string TODO appears under ./app."; want = "search" },
    @{ q = "Run the unit tests with pytest."; want = "run_shell" },
    @{ q = "Show me the contents of config/settings.yaml."; want = "read_file" },
    @{ q = "List everything in the current directory."; want = "list_dir" },
    @{ q = "Save the text 'build ok' into status.log."; want = "write_file" },
    @{ q = "Where is the function parse_args defined in this repo?"; want = "search" },
    @{ q = "Install the dependencies with npm install."; want = "run_shell" }
)

$valid = 0; $correct = 0; $n = 0
$lines = @()

foreach ($c in $cases) {
    $n++
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, "$sys Task: $($c.q)`n", [System.Text.Encoding]::UTF8)

    $raw = & cmd /c "type `"$tmp`" | .\olmoe.exe 64 8 2>&1"
    Remove-Item $tmp -Force

    $txt = ($raw | Where-Object {
        $_ -notmatch '^\[OMP\]|^\[stop\]|^olmoe chat|type a message|resident weights|^== Streaming'
    }) -join "`n"
    $txt = ($txt -replace '(?m)^>\s?', '').Trim()

    $clean = $txt -replace '(?s)^```[a-zA-Z]*\s*', '' -replace '(?s)\s*```\s*$', ''
    $m = [regex]::Match($clean, '(?s)\{.*\}')
    $tool = $null; $isJson = $false
    if ($m.Success) {
        try { $obj = $m.Value | ConvertFrom-Json; $isJson = $true; $tool = $obj.tool } catch { $isJson = $false }
    }

    if ($isJson) { $valid++ }
    $hit = ($isJson -and $tool -eq $c.want)
    if ($hit) { $correct++ }

    $mark = if ($hit) { "OK  " } elseif ($isJson) { "TOOL" } else { "JSON" }
    $short = ($txt -replace "\r?\n", " ")
    if ($short.Length -gt 110) { $short = $short.Substring(0, 110) + "..." }
    $lines += ("  {0,2}. [{1}] erwartet={2,-10} bekommen={3,-14} | {4}" -f $n, $mark, $c.want, ($tool -replace '^$', '-'), $short)
}

"===== OLMoE-1B-7B(colibri) :: Agent-Tauglichkeit ($n Aufgaben, TEMP=0)"
$lines
""
"  gueltiges JSON:        $valid / $n"
"  richtiges Werkzeug:    $correct / $n"
""
