# Cook adapter: a model on this PC through Ollama. Free, private, offline: the order never leaves the machine.
# Text in, text out (no tools): when a step needs files, the step attaches them with -Context and they arrive inside the prompt.
# One local cook at a time (one graphics card): a named lock queues them. Same contract as cooks/claude.ps1.
# Env: KITCHEN_OLLAMA_URL (default http://127.0.0.1:11434; only localhost / 127.0.0.1 / [::1] or 'off', anything else is refused), KITCHEN_NVSMI = 'none' to skip the graphics memory check, or a number of MB to fake the free memory (tests).
# OLLAMA_FLASH_ATTENTION=1 and OLLAMA_KV_CACHE_TYPE=q8_0 together (with room on the card) allow a 16384 window; otherwise 8192 is the most.
param([switch]$Probe, [string]$Prompt = '', [string]$Model = '', [string]$Effort = '', [string]$Tools = '', [string]$Mode = 'plan',
      [int]$MaxTurns = 1, [double]$MaxBudgetUsd = 0, [int]$TimeoutSec = 1500, [string]$Role = 'do')
$url = if ($env:KITCHEN_OLLAMA_URL) { $env:KITCHEN_OLLAMA_URL.TrimEnd('/') } else { 'http://127.0.0.1:11434' }
# private by construction: the address must be this PC (kitchen/loopback.ps1); anything else is refused before any request is made
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'loopback.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'gpu-lease.ps1')   # the card is booked before a load (kitchen/gpu-lease.ps1)
$offPc = if ($url -ne 'off' -and -not (Test-LoopbackUrl $url)) { Get-LoopbackRefusal $url } else { '' }
function KvFlags {   # Ollama's memory savers, read from this process's environment (advisory: the server may differ)
    @{ flash = ($env:OLLAMA_FLASH_ATTENTION -eq '1'); kv = ($env:OLLAMA_KV_CACHE_TYPE -eq 'q8_0') }
}
function FreeVramMB {
    if ($env:KITCHEN_NVSMI -eq 'none') { return $null }
    if ($env:KITCHEN_NVSMI -match '^\d+$') { return [int]$env:KITCHEN_NVSMI }   # test hook: fake free MB
    try { $v = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1; return [int]$v } catch { return $null }
}
if ($Probe) {
    if ($url -eq 'off') { return @{ ready = $false; why = 'switched off (KITCHEN_OLLAMA_URL=off)'; hard = $true } }
    if ($offPc) { return @{ ready = $false; why = "refused: $offPc"; hard = $true } }
    try { $tags = Invoke-RestMethod -Uri "$url/api/tags" -TimeoutSec 3 } catch { return @{ ready = $false; why = 'Ollama is not running'; hard = $false } }
    $kvf = KvFlags
    $adv = "flash attention $(if ($kvf.flash) { 'on' } else { 'off' }), KV cache q8_0 $(if ($kvf.kv) { 'on' } else { 'off' })"
    if (-not $Model) { return @{ ready = $true; why = "Ollama up; $adv" } }
    $m = @($tags.models | Where-Object { $_.name -eq $Model -or $_.model -eq $Model }) | Select-Object -First 1
    if (-not $m) { return @{ ready = $false; why = "model $Model is not pulled (ollama pull $Model)"; hard = $true } }
    # graphics memory Ollama holds for other models is not "busy": Ollama swaps them out when this model is asked for
    $loaded = $false; $ours = 0
    try { foreach ($x in @((Invoke-RestMethod -Uri "$url/api/ps" -TimeoutSec 3).models)) { if ($x.name -eq $Model) { $loaded = $true }; $ours += [double]$x.size_vram / 1MB } } catch { }
    $free = FreeVramMB; if ($null -ne $free) { $free = [int]($free + $ours) }; $need = [int]([double]$m.size / 1MB * 1.05)
    # busy only when the card is nearly full (a game, a render); short of room, Ollama runs part of the model on the processor (slower, still works)
    if (-not $loaded -and $null -ne $free -and $free -lt 1500) { return @{ ready = $false; why = "graphics card busy ($free MB free)"; hard = $false } }
    $note = if ($loaded) { 'warm (model loaded)' } elseif ($null -ne $free -and $free -lt $need) { "ready, partly on the processor ($free MB free, $Model wants about $need MB)" } else { 'ready (cold start)' }
    return @{ ready = $true; why = "$note; $adv" }
}
$r = @{ ok = $false; text = ''; usd = 0.0; turns = 1; inputTokens = 0; outputTokens = 0; cacheReadTokens = 0; cacheWriteTokens = 0; model = $Model; limit = $false; signedOut = $false; restMin = 0; error = '' }
if ($offPc) { $r.error = "local cook refused: $offPc"; return $r }
if (-not $Model) { $r.error = 'no local model named'; return $r }
$system = switch ($Role) {
    'plan' { 'You are the head chef: plan carefully and concretely. Follow the output format the order asks for exactly.' }
    'check' { 'You are the taster: review strictly and fairly. Follow the output format the order asks for exactly, including any final verdict line.' }
    default { 'You are a careful line cook. Do exactly what the order asks and follow its output format exactly.' }
}
# one model on the graphics card at a time; wait up to most of the step's time, showing a heartbeat while queued
$gpu = New-Object Threading.Mutex($false, 'Global\brain-kitchen-gpu'); $got = $false
$until = (Get-Date).AddSeconds([math]::Max(60, $TimeoutSec - 120))
while (-not $got -and (Get-Date) -lt $until) {
    try { $got = $gpu.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $got = $true }
    if ($env:KITCHEN_HEARTBEAT) { for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::WriteAllText($env:KITCHEN_HEARTBEAT, "$(Get-Date -Format o) quiet=$($TimeoutSec + 120)"); break } catch [IO.IOException] { Start-Sleep -Milliseconds 50 } } }   # the model call after the queue is bounded by TimeoutSec
}
if (-not $got) { $r.limit = $true; $r.restMin = 5; $r.error = 'graphics card busy with another local cook'; return $r }
$lease = $null
try {
    # the card is booked first (whole model, part of it, or the processor); nothing free in time: busy, the order waits
    $lease = Enter-GpuLease $url $Model "yard-local-$Role" -WaitSec ([math]::Min(300, [math]::Max(0, $TimeoutSec - 600))) -TtlSec ($TimeoutSec + 300)
    if ($lease.busy) { $r.limit = $true; $r.restMin = 5; $r.error = "graphics card and memory booked by other work ($($lease.why))"; return $r }
    # context sized to the prompt (about 3 characters a token plus room for the answer): 2048, 4096 or 8192 and no more, so the model stays whole on the card
    $need = [int]($Prompt.Length / 3) + 1024
    $ctx = if ($need -le 2048) { 2048 } elseif ($need -le 4096) { 4096 } else { 8192 }
    # 16384 only with a quantized KV cache and flash attention and at least 6000 MB known free; a tight card is held to 8192
    $freeNow = FreeVramMB; $kvf = KvFlags
    if ($need -gt 8192 -and $kvf.flash -and $kvf.kv -and $null -ne $freeNow -and $freeNow -ge 6000) { $ctx = 16384 }
    if ($null -ne $freeNow -and $freeNow -lt 6000 -and $ctx -gt 8192) { $ctx = 8192 }
    if ($ctx -ge 8192) {   # a full-size run: unload any other model (the decider) so this one is not pushed into system RAM
        try {
            foreach ($x in @((Invoke-RestMethod -Uri "$url/api/ps" -TimeoutSec 3).models)) {
                if ($x.name -ne $Model -and $x.model -ne $Model) { Invoke-RestMethod -Uri "$url/api/generate" -Method Post -Body (@{ model = [string]$x.name; keep_alive = 0 } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 | Out-Null }
            }
        } catch { }
    }
    # thinking models think only when planning (it is slow); a model without thinking ignores the switch or is asked again without it
    $b = @{ model = $Model; stream = $false; keep_alive = '2m'; think = ($Role -eq 'plan'); options = @{ temperature = 0.2; num_ctx = $ctx }
            messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $Prompt }) }
    Set-LeaseOnBody $b $lease   # under a lease: keep_alive 0 (unloaded right after) and the leased layer count
    $body = $b | ConvertTo-Json -Depth 6
    try { $res = Invoke-RestMethod -Uri "$url/api/chat" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec ([math]::Max(60, $TimeoutSec - 60)) }
    catch { if ("$_" -notmatch '(?i)think') { throw }; $b2 = $body | ConvertFrom-Json -AsHashtable; $b2.Remove('think'); $res = Invoke-RestMethod -Uri "$url/api/chat" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes(($b2 | ConvertTo-Json -Depth 6))) -ContentType 'application/json; charset=utf-8' -TimeoutSec ([math]::Max(60, $TimeoutSec - 60)) }
    $text = [string]$res.message.content
    $text = [regex]::Replace($text, '(?s)<think>.*?</think>\s*', '').Trim()   # reasoning models: keep only the answer
    $r.text = $text; $r.inputTokens = [int]$res.prompt_eval_count; $r.outputTokens = [int]$res.eval_count
    if (-not $text) { $r.error = 'the local model returned nothing'; return $r }
    $r.ok = $true
} catch {
    $msg = $_.Exception.Message
    if ($msg -match '(?i)out of memory|unable to allocate|actively refused|No connection could be made') { $r.limit = $true; $r.restMin = 5 }
    $r.error = "local cook: $msg"
} finally { Exit-GpuLease $lease $url $Model; if ($got) { try { $gpu.ReleaseMutex() } catch { } } }
$r
