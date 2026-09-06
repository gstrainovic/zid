param(
    [int]$Port = 8080,
    [string]$Label = "model"
)

$ErrorActionPreference = "Stop"
$uri = "http://127.0.0.1:$Port/v1/chat/completions"

$sys = @'
You are a tool-using agent. You have exactly these tools and no others:

read_file(path)          - read a file
write_file(path, text)   - write a file
list_dir(path)           - list a directory
run_shell(cmd)           - run a shell command
search(pattern, path)    - grep for a pattern

Reply with a single JSON object and nothing else:
{"tool": "<one of the five names above>", "args": {...}}
'@

# task -> expected tool name
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

$valid = 0
$correct = 0
$n = 0
$lines = @()

foreach ($c in $cases) {
    $n++
    $body = @{
        model       = "local"
        messages    = @(
            @{ role = "system"; content = $sys },
            @{ role = "user"; content = $c.q }
        )
        temperature = 0
        max_tokens  = 120
    } | ConvertTo-Json -Depth 6

    try {
        $r = Invoke-RestMethod -Uri $uri -Method POST -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 600
        $txt = $r.choices[0].message.content.Trim()
    } catch {
        $lines += "  $n. REQUEST-FEHLER: $($_.Exception.Message)"
        continue
    }

    # strip markdown fences if present
    $clean = $txt -replace '(?s)^```[a-zA-Z]*\s*', '' -replace '(?s)\s*```\s*$', ''
    # take the first {...} block
    $m = [regex]::Match($clean, '(?s)\{.*\}')
    $tool = $null
    $isJson = $false
    if ($m.Success) {
        try {
            $obj = $m.Value | ConvertFrom-Json
            $isJson = $true
            $tool = $obj.tool
        } catch { $isJson = $false }
    }

    if ($isJson) { $valid++ }
    $hit = ($isJson -and $tool -eq $c.want)
    if ($hit) { $correct++ }

    $mark = if ($hit) { "OK  " } elseif ($isJson) { "TOOL" } else { "JSON" }
    $short = ($txt -replace "\r?\n", " ")
    if ($short.Length -gt 110) { $short = $short.Substring(0, 110) + "..." }
    $lines += ("  {0,2}. [{1}] erwartet={2,-10} bekommen={3,-14} | {4}" -f $n, $mark, $c.want, ($tool -replace '^$', '-'), $short)
}

"===== $Label :: Agent-Tauglichkeit ($n Aufgaben, temp=0)"
$lines
""
"  gueltiges JSON:        $valid / $n"
"  richtiges Werkzeug:    $correct / $n"
""
