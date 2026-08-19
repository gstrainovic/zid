param(
    [int]$Port = 8080,
    [string]$Label = "model"
)

$ErrorActionPreference = "Stop"
$uri = "http://127.0.0.1:$Port/v1/chat/completions"

$tests = @(
    @{
        name   = "1-tool-call-json"
        system = 'You are an agent with these tools:
{"name":"read_file","args":{"path":"string"}}
{"name":"run_shell","args":{"cmd":"string"}}
Reply with ONE JSON object only, no prose, no markdown: {"tool":"<name>","args":{...}}'
        user   = "Show me the contents of /etc/hosts."
    },
    @{
        name   = "2-code-python"
        system = "You are a coding assistant. Output only code, no explanation, no markdown fences."
        user   = "Write a Python function quicksort(a) that returns a new sorted list."
    },
    @{
        name   = "3-instruction-strict"
        system = "Follow the format exactly."
        user   = "Answer with exactly one word, uppercase, nothing else: what is the capital of Switzerland?"
    },
    @{
        name   = "4-german"
        system = "Du bist ein hilfreicher Assistent. Antworte auf Deutsch."
        user   = "Erklaere in zwei Saetzen, was ein Index in einer relationalen Datenbank bewirkt."
    },
    @{
        name   = "5-reasoning"
        system = "Think step by step, then give the final number after 'ANSWER:'."
        user   = "A shop sells pens at 3 for 5 francs. I buy 21 pens and pay with a 50 franc note. How much change do I get?"
    },
    @{
        name   = "6-agent-multistep"
        system = 'You are a coding agent. Available tools: read_file(path), edit_file(path, old, new), run_tests().
Output a numbered plan of tool calls only, one per line, format: N. tool(args). No prose.'
        user   = "The test suite fails because utils.py has a typo: 'lenght' should be 'length'. Fix it and verify."
    }
)

foreach ($t in $tests) {
    $body = @{
        model       = "local"
        messages    = @(
            @{ role = "system"; content = $t.system },
            @{ role = "user"; content = $t.user }
        )
        temperature = 0.2
        max_tokens  = 300
        stream      = $false
    } | ConvertTo-Json -Depth 6

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri $uri -Method POST -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 600
        $sw.Stop()
        $txt = $r.choices[0].message.content
        $ct = $r.usage.completion_tokens
        $pt = $r.usage.prompt_tokens
        $tps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($ct / $sw.Elapsed.TotalSeconds, 2) } else { 0 }
        "===== $Label :: $($t.name) | prompt=$pt gen=$ct | $([math]::Round($sw.Elapsed.TotalSeconds,1))s | $tps tok/s"
        $txt
        ""
    } catch {
        $sw.Stop()
        "===== $Label :: $($t.name) | FEHLER: $($_.Exception.Message)"
        ""
    }
}
