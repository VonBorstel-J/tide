# The Sous Chef: decides which cook takes each order. One answer, one reason, every time, in well under a second for most orders.
# Cooks are suppliers: claude (Claude Code CLI on Jordan's plan), gemini (Gemini CLI on Jordan's Google plan), local (Ollama on this PC,
# free and private). A new supplier is one adapter in kitchen/cooks/<name>.ps1 plus an entry in kitchen.json "suppliers" and the menu.
#
# How it decides (each rule it applies is written into the decision, so Jordan can see why):
#  1. Privacy first. An order marked private, or whose text looks personal (emails, phone numbers, card or ID numbers, secrets, health
#     or money words, Jordan's own private words), may only go to the local cook. If the local cook can't do it, the order is HELD for
#     Jordan (exit 10 in the step), never quietly sent out. Jordan's yes on that hold lets a cloud cook take that one step.
#  2. What kind of order is it (plan, code, research, check, review, write, quick, big)? Set by role, tools and size; only an unclear
#     plain-text order asks the local judge model, with a hard time limit, and falls back to a fixed default.
#  3. The menu (kitchen.json) lists the cooks for each kind, best first. A cook is skipped if it is switched off, not signed in,
#     resting after hitting its plan's usage limit, at its run cap for the window, or can't do what the order needs (edit files,
#     use the web, read that much).
#  4. Pressure and learning: a cook near its usage cap goes behind the others; past 80% of the daily budget, cheap orders go local;
#     a cook that keeps failing the taster for a kind of order is moved down; a retry never repeats the cook that just failed and
#     steps up a tier.
#  5. Chef's override: an order that names a supplier or model gets exactly that, or waits / holds; it is never swapped silently.
# If nothing can cook now but something will soon (usage limits reset), the step WAITS (exit 11) without burning a retry.
#
#   sous-chef.ps1 pick -Role do -Prompt '...' [-Tools Read,Edit] [-Mode acceptEdits] [-Private] [-Supplier gemini] [-Model x] [-Json]
#   sous-chef.ps1 board [-Write]        every supplier's state, usage and track record (the Chef app shows it)
#   sous-chef.ps1 rest -Name gemini [-ForMin 60] -Why 'quota' [-Raw '<provider text>']   |   sous-chef.ps1 wake -Name gemini
# A rest keeps the provider's own words as .raw on the supplier's state (from -Raw, else the adapter's fresh last-limit-<name>.json).
# A rest whose words name no calendar date or clock time is capped at sous.maxParsedRestHours (24 h): one parsed number benched
# Gemini 164 h and Antigravity 148 h on 10-22 while both still answered. Once an hour (sous.restProbeMin), a cook resting more than an
# hour gets one 1-turn "Reply with exactly: OK" on its cheapest model through its own adapter: OK wakes it (supplier.woke event), a
# limit answer (or any other failure) keeps the rest (supplier.probe event). The probe runs inside pick/board, at most once an hour.
param(
    [Parameter(Position = 0)][ValidateSet('pick', 'board', 'rest', 'wake', 'usage')][string]$Action = 'pick',
    [string]$Prompt = '', [ValidateSet('plan', 'do', 'research', 'check', 'talk')][string]$Role = 'do', [string]$Tools = 'Read,Grep,Glob',
    [string]$Mode = 'plan', [string]$Supplier = 'auto', [string]$Model = '', [switch]$Private, [switch]$Public, [string]$Order = '', [int]$Attempt = -1, [int]$ContextChars = 0,
    [string]$Name = '', [int]$ForMin = 0, [string]$Why = '', [string]$Raw = '', [switch]$NoJudge, [switch]$Json, [switch]$Write,
    [ValidateSet('', 'S', 'M', 'L')][string]$Size = ''
)
$ErrorActionPreference = 'Stop'
$t0 = [Diagnostics.Stopwatch]::StartNew()
$root = [IO.Path]::GetFullPath($(if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$statePath = Join-Path $root 'suppliers-state.json'; $cachePath = Join-Path $root 'sous-cache.json'; $eventsPath = Join-Path $root 'events.jsonl'
$cooksDir = Join-Path $PSScriptRoot 'cooks'
$ollama = if ($env:KITCHEN_OLLAMA_URL) { $env:KITCHEN_OLLAMA_URL.TrimEnd('/') } else { 'http://127.0.0.1:11434' }
. (Join-Path $PSScriptRoot 'gpu-lease.ps1')   # the judges book the card before a load, like the local cook

# ---- settings: built-in defaults, then kitchen.json (repo), then kitchen.json (state folder) ----
$S = @{
    suppliers = [ordered]@{
        claude = @{ on = $true; plan = 'subscription'; tools = $true; web = $true; edits = $true; maxChars = 600000; restMin = 60; probeSec = 600
                    window = @{ hours = 5; maxRuns = 40 }; tiers = @{ strong = @('opus', 'high'); mid = @('sonnet', 'medium'); light = @('haiku', 'low') } }
        gemini = @{ on = $true; plan = 'subscription'; tools = $true; web = $true; edits = $true; maxChars = 1000000; restMin = 60; probeSec = 1800
                    window = @{ hours = 24; maxRuns = 150 }; tiers = @{ strong = @('gemini-3.8-flash-high', ''); mid = @('gemini-3.8-flash-medium', ''); light = @('gemini-3.8-flash-low', '') } }
        antigravity = @{ on = $true; plan = 'subscription'; tools = $true; web = $true; edits = $true; maxChars = 1000000; restMin = 60; probeSec = 1800
                    window = @{ hours = 5; maxRuns = 30 }; tiers = @{ strong = @('claude-opus-5-5-high', ''); mid = @('claude-sonnet-5-5-medium', ''); light = @('claude-sonnet-5-5-low', '') } }
        local  = @{ on = $true; plan = 'free'; tools = $false; web = $false; edits = $false; maxChars = 60000; restMin = 5; probeSec = 0
                    window = @{ hours = 1; maxRuns = 1000 }; tiers = @{ strong = @('qwen3.5:9b', ''); mid = @('qwen3.5:9b', ''); light = @('qwen2.5:3b', '') } }
    }
    menu = @{
        plan = @('claude:mid', 'antigravity:mid', 'gemini:strong'); code = @('antigravity:mid', 'claude:mid', 'gemini:strong'); research = @('gemini:mid', 'antigravity:mid', 'claude:mid')
        check = @('gemini:mid', 'claude:light', 'antigravity:light'); review = @('gemini:mid', 'claude:light', 'antigravity:mid')
        write = @('claude:mid', 'antigravity:mid', 'gemini:mid', 'local:strong'); quick = @('local:light', 'gemini:light', 'claude:light')
        big = @('gemini:strong', 'antigravity:mid', 'claude:mid'); private = @('local:strong', 'local:mid', 'local:light')
        talk = @('claude:mid', 'antigravity:mid', 'gemini:mid', 'local:strong')
    }
    sous = @{ decider = 'tev1:0.8b'; privateAt = 0.3; sureAt = 0.85; judge = 'qwen2.5:3b'; judgeGpu = 0; judgeTimeoutSec = 30; privacyJudge = $true; bigChars = 400000; nearCap = 0.75; budgetPressure = 0.8
              demoteBelow = 0.5; demoteMinRuns = 4; escalate = $true; privateWords = @(); maxParsedRestHours = 24; restProbeMin = 60; restProbeSec = 90; upgrades = @{ gemini = @('(?i)argon.*high', '(?i)argon', '(?i)^gemini-4') }; modelOwners = [ordered]@{ local = ':'; antigravity = '^(claude-[a-z]+-\d+-\d+-(low|medium|high)|gpt-oss)'; gemini = '^gemini'; claude = '^(claude|opus|sonnet|haiku|fable)' } }
    dailyBudgetUsd = 20
}
function Is-Map($x) { $x -is [Collections.IDictionary] }
foreach ($cp in (Join-Path $PSScriptRoot 'kitchen.json'), (Join-Path $root 'kitchen.json')) {
    if (-not (Test-Path -LiteralPath $cp)) { continue }
    try { $c = Get-Content -LiteralPath $cp -Raw | ConvertFrom-Json -AsHashtable } catch { continue }
    if (Is-Map $c.suppliers) { foreach ($n in $c.suppliers.Keys) {
        if (-not $S.suppliers.Contains($n)) { $S.suppliers[$n] = @{ on = $true; plan = 'subscription'; tools = $false; web = $false; edits = $false; maxChars = 100000; restMin = 60; probeSec = 0; window = @{ hours = 24; maxRuns = 100 }; tiers = @{} } }
        foreach ($k in $c.suppliers[$n].Keys) { $S.suppliers[$n][$k] = $c.suppliers[$n][$k] } } }
    if (Is-Map $c.menu) { foreach ($k in $c.menu.Keys) { $S.menu[$k] = @($c.menu[$k]) } }
    if (Is-Map $c.sous) { foreach ($k in $c.sous.Keys) { $S.sous[$k] = $c.sous[$k] } }
    if ($null -ne $c.dailyBudgetUsd) { $S.dailyBudgetUsd = [double]$c.dailyBudgetUsd }
}

# ---- small state files (a short named lock; losing a write here is never dangerous, only less informed) ----
function Read-JsonFile($p) { if (Test-Path -LiteralPath $p) { try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable) } catch { } }; @{} }
$lock = [Threading.Mutex]::new($false, ('Global\brain-kitchen-sous-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))).Substring(0, 12)))
function Update-JsonFile($p, [scriptblock]$change) {
    $got = $false; try { $got = $lock.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $got = $true }
    try { $d = Read-JsonFile $p; & $change $d; $t = "$p.tmp-$PID"; $d | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $t -Encoding utf8; Move-Item -LiteralPath $t -Destination $p -Force }
    finally { if ($got) { try { $lock.ReleaseMutex() } catch { } } }
}
function Now { [DateTime]::UtcNow }
function ToUtc($v) { if ($v -is [DateTime]) { $v.ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } }

# ---- what the kitchen remembers: cook outcomes (usage windows + track record) from the event log ----
$cookEvents = @()
if (Test-Path -LiteralPath $eventsPath) {
    $cookEvents = @(Get-Content -LiteralPath $eventsPath -Tail 5000 | Where-Object { $_ -match '"type":"(cook|cost)"' } | ForEach-Object { try { $_ | ConvertFrom-Json -AsHashtable } catch { } })
}
function Runs-InWindow([string]$sup) {
    $w = $S.suppliers[$sup].window; $since = (Now).AddHours(-[double]$w.hours)
    @($cookEvents | Where-Object { $_.type -eq 'cook' -and $_.supplier -eq $sup -and (ToUtc $_.ts) -gt $since }).Count
}
function Track([string]$sup, [string]$kind) {
    $e = @($cookEvents | Where-Object { $_.type -eq 'cook' -and $_.supplier -eq $sup -and $_.kind -eq $kind } | Select-Object -Last 20)
    @{ n = $e.Count; ok = @($e | Where-Object { $_.ok }).Count }
}
function Spent-Today { $d = (Get-Date).Date; $sum = 0.0; foreach ($e in $cookEvents) { if ($e.type -eq 'cost' -and (ToUtc $e.ts).ToLocalTime().Date -eq $d) { $sum += [double]$e.usd } }; $sum }

# ---- is a supplier able to cook right now? ----
$state = Read-JsonFile $statePath
function Probe([string]$sup) {
    $a = Join-Path $cooksDir "$sup.ps1"
    if (-not (Test-Path -LiteralPath $a)) { return @{ ready = $false; why = "no adapter cooks\$sup.ps1"; hard = $true } }
    $cfg = $S.suppliers[$sup]; $p = if ($state[$sup]) { $state[$sup].probe } else { $null }
    # a ready probe is trusted for probeSec; a failed one only for a minute (a PC waking before Wi-Fi must not bench a cook for 30 min)
    $ttl = if ($p -and -not $p.ready) { [math]::Min(60, [int]$cfg.probeSec) } else { [int]$cfg.probeSec }
    if ($p -and $ttl -gt 0 -and ((Now) - (ToUtc $p.at)).TotalSeconds -lt $ttl) { return $p }
    try { $r = & $a -Probe -Model ([string]$cfg.tiers.strong[0]) } catch { $r = @{ ready = $false; why = "probe failed: $($_.Exception.Message)" } }
    $r = @{ ready = [bool]$r.ready; why = [string]$r.why; hard = [bool]$r.hard; at = (Now).ToString('o') }
    if ([int]$cfg.probeSec -gt 0) { Update-JsonFile $statePath { param($d) if (-not $d[$sup]) { $d[$sup] = @{} }; $d[$sup].probe = $r } }
    $r
}
# an event line in the kitchen log (same shape as kitchen.ps1's Emit); never throws: a busy log only loses this one line
function Emit-Sous([string]$type, [hashtable]$data) {
    $e = [ordered]@{ ts = (Now).ToString('o'); type = $type; job = [string]$env:KITCHEN_JOB }; foreach ($k in $data.Keys) { $e[$k] = $data[$k] }
    $line = $e | ConvertTo-Json -Compress -Depth 5
    for ($i = 0; $i -lt 6; $i++) { try { Add-Content -LiteralPath $eventsPath -Value $line -Encoding utf8 -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds (50 + (Get-Random -Maximum 150)) } }
}
# A long rest is checked, not trusted: a cook resting more than an hour (its rest was set for over an hour) gets one tiny probe each
# hour since the rest began or since its last probe. The slot is claimed under the state lock first, so two picks at once never both
# probe and a second probe inside the hour is skipped. $true = it answered OK and is awake now.
function Probe-Rest([string]$sup) {
    $st = $state[$sup]; $cfg = $S.suppliers[$sup]; $every = [math]::Max(1, [int]$S.sous.restProbeMin)
    if (-not $st -or -not $st.restUntil -or -not $st.at) { return $false }
    $until = ToUtc $st.restUntil; $since = ToUtc $st.at
    if (($until - $since).TotalMinutes -le 60) { return $false }   # a short rest just runs out
    $a = Join-Path $cooksDir "$sup.ps1"; if (-not (Test-Path -LiteralPath $a)) { return $false }
    $claimed = $false; $mark = (Now).ToString('o')
    Update-JsonFile $statePath { param($d) $x = $d[$sup]; if (-not $x -or -not $x.restUntil) { return }
        $last = ToUtc $x.at; if ($x.restProbeAt -and (ToUtc $x.restProbeAt) -gt $last) { $last = ToUtc $x.restProbeAt }
        if (((Now) - $last).TotalMinutes -lt $every) { return }
        $x.restProbeAt = $mark; $script:probeClaim = $true }
    $claimed = [bool]$script:probeClaim; $script:probeClaim = $false
    if (-not $claimed) { return $false }
    $light = @($cfg.tiers.light); $m = [string]$light[0]; $ef = if ($light.Count -gt 1) { [string]$light[1] } else { '' }
    $run = $env:KITCHEN_RUN; $env:KITCHEN_RUN = $null   # the probe is not the step being picked for: nothing lands in its live view
    $res = try { & $a -Prompt 'Reply with exactly: OK' -Model $m -Effort $ef -Tools 'none' -MaxTurns 1 -TimeoutSec ([int]$S.sous.restProbeSec) -Role 'check' | Where-Object { $_ -is [Collections.IDictionary] } | Select-Object -Last 1 } catch { @{ ok = $false; error = "probe failed: $($_.Exception.Message)" } }
    finally { $env:KITCHEN_RUN = $run }
    if (-not $res) { $res = @{ ok = $false; error = 'the adapter returned nothing' } }
    $left = [math]::Round(($until - (Now)).TotalHours, 1)
    if ($res.ok) {
        Update-JsonFile $statePath { param($d) if ($d[$sup]) { $d[$sup].restUntil = $null; $d[$sup].wokeAt = $mark } }
        $state[$sup].restUntil = $null
        Emit-Sous 'supplier.woke' @{ supplier = $sup; model = $m; why = "answered OK to the hourly probe with $left h of its rest left ($($st.why))" }
        return $true
    }
    Emit-Sous 'supplier.probe' @{ supplier = $sup; model = $m; limit = [bool]$res.limit; why = "still resting ($left h left): $(if ($res.limit) { 'the probe hit the limit too' } else { [string]$res.error })"; raw = [string]$res.raw }
    $false
}
$script:probeClaim = $false
# the plan's own reading of its limits (Claude reports 5-hour and weekly use with every run; see cooks/claude.ps1), per supplier
# Fail closed: a reading that exists but can't be read (a claude run moving its new copy in, a broken file) is retried briefly and
# then counts as 'unreadable', which caps the cook instead of silently skipping every cap check
$planUsage = @{}; $planUsageBad = $false; $puPath = Join-Path $root 'plan-usage.json'
if (Test-Path -LiteralPath $puPath) { foreach ($try in 1..3) { try { $planUsage = Get-Content -LiteralPath $puPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable; $planUsageBad = -not (Is-Map $planUsage) } catch { $planUsageBad = $true }; if (-not $planUsageBad) { break }; Start-Sleep -Milliseconds 150 } }
if ($planUsageBad) { $planUsage = @{} }
# model family (opus, sonnet, haiku, argon, flash, gpt-oss, qwen...): a reviewer from the builder's family shares its blind spots
function Model-Family([string]$m) { if ($m -match '(?i)(opus|sonnet|haiku|fable|argon|flash|gpt-oss|qwen|tev)') { $Matches[1].ToLowerInvariant() } else { ([string]$m).ToLowerInvariant() } }
# which family built this job: the newest receipt (<job>-s<n>-a<k>.cost.json) of an earlier code step in this run folder, else ''
function Builder-Family {
    if (-not $env:KITCHEN_RUN -or $env:KITCHEN_RUN -notmatch '^(.*[\\/])?(J\d+)-s(\d+)-a\d+$') { return '' }
    $dir = Split-Path -Parent $env:KITCHEN_RUN; $job = $Matches[2]; $cur = [int]$Matches[3]
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return '' }
    $best = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter "$job-s*-a*.cost.json" -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch "^$job-s(\d+)-a(\d+)\.cost\.json$" -or [int]$Matches[1] -ge $cur) { continue }
        try { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { continue }
        if ([string]$r.kind -ne 'code' -or -not $r.model) { continue }
        if (-not $best -or $f.LastWriteTimeUtc -gt $best.t) { $best = @{ t = $f.LastWriteTimeUtc; m = [string]$r.model } }
    }
    if ($best) { Model-Family $best.m } else { '' }
}
# claude steps picked but not finished yet (a .sous.json with no receipt and no exit code): their use is not in the reading yet
function Running-Steps([string]$sup) {
    $rd = Join-Path $root 'run'; if (-not (Test-Path -LiteralPath $rd)) { return 0 }; $since = (Get-Date).AddMinutes(-50)
    @(Get-ChildItem -LiteralPath $rd -Filter '*.sous.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since -and $_.FullName -ne "$env:KITCHEN_RUN.sous.json" } | Where-Object {
        $b = $_.FullName -replace '\.sous\.json$', ''; -not (Test-Path -LiteralPath "$b.cost.json") -and -not (Test-Path -LiteralPath "$b.exit") -and
        $(try { $x = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; $x.action -eq 'cook' -and $x.supplier -eq $sup } catch { $false }) }).Count
}
function Plan-Use([string]$sup) {
    $p = $planUsage[$sup]; if (-not $p) { return $null }
    $live = { param($w) if ($w -and $w.resetsAt -and (ToUtc $w.resetsAt) -gt (Now)) { [double]$w.used } else { 0.0 } }
    $five = & $live $p.fiveHour; $week = & $live $p.sevenDay
    $worst = if ($week -ge $five) { @{ used = $week; window = 'weekly'; resetsAt = $p.sevenDay.resetsAt } } else { @{ used = $five; window = '5-hour'; resetsAt = $p.fiveHour.resetsAt } }
    @{ five = $five; week = $week; used = $worst.used; window = $worst.window; resetsAt = $worst.resetsAt; at = $p.at; status = [string]$p.status
       fiveResets = $p.fiveHour.resetsAt; weekResets = $p.sevenDay.resetsAt; overage = [string]$p.overage; usingOverage = [bool]$p.usingOverage }
}
# new models the moment the plan has them (staying current is unconditional): sous.upgrades = { supplier: [regex, ...] }, best first.
# The agy sign-in check saves the plan's model list (agy-models.json); the first match takes the strong tier, e.g. Gemini 4 Argon.
$planModels = @(); try { $planModels = @((Get-Content -LiteralPath (Join-Path $root 'agy-models.json') -Raw | ConvertFrom-Json).models) } catch { }
function Upgrade-Model([string]$sup, [string]$tier) {
    if ($tier -ne 'strong' -or -not $S.sous.upgrades -or -not $S.sous.upgrades[$sup]) { return $null }
    foreach ($rx in @($S.sous.upgrades[$sup])) { $hit = $planModels | Where-Object { $_ -match $rx } | Select-Object -First 1; if ($hit) { return [string]$hit } }
    $null
}
# status: ready | off | signed-out (hard: needs Jordan) | resting / busy / capped (soft: comes back by itself)
function Status([string]$sup) {
    $cfg = $S.suppliers[$sup]
    if (-not $cfg) { return @{ status = 'unknown'; why = "no supplier named $sup"; hard = $true } }
    if (-not $cfg.on) { return @{ status = 'off'; why = 'switched off in kitchen.json'; hard = $true } }
    $st = $state[$sup]
    if ($st -and $st.restUntil -and (Now) -lt (ToUtc $st.restUntil) -and -not (Probe-Rest $sup)) {
        $st = $state[$sup]
        return @{ status = 'resting'; why = "resting: $($st.why)"; hard = $false; backSec = [int]((ToUtc $st.restUntil) - (Now)).TotalSeconds }
    }
    $pu = Plan-Use $sup
    # MONEY: paid extra usage is on (or in use): nothing is cooked until the window resets, so nothing can be billed
    if ($pu -and ($pu.usingOverage -or $pu.overage -match '(?i)^allowed$')) { return @{ status = 'capped'; why = "paid extra usage is on ($(if ($pu.usingOverage) { 'in use' } else { $pu.overage })); waiting for the reset so nothing is billed"; hard = $false; backSec = [int][math]::Max(300, $(if ($pu.resetsAt) { ((ToUtc $pu.resetsAt) - (Now)).TotalSeconds } else { 0 })) } }
    # fail closed: Jordan's caps can only be kept with a reading the kitchen can trust (unreadable, missing or stale near a cap = wait)
    $hasCap = [bool]($cfg.capFive -or $cfg.capWeek)
    if ($planUsageBad -and ($sup -eq 'claude' -or $hasCap)) { return @{ status = 'capped'; why = 'the plan reading (plan-usage.json) could not be read; waiting for a fresh one'; hard = $false; backSec = 300 } }
    if ($hasCap -and -not $pu) { return @{ status = 'capped'; why = "Jordan's cap is set but there is no plan reading yet; waiting for one"; hard = $false; backSec = 300 } }
    if ($pu -and $pu.at) {
        $age = ((Now) - (ToUtc $pu.at)).TotalMinutes
        if ($age -gt 20) { foreach ($c in @(@{ used = $pu.five; cap = $cfg.capFive }, @{ used = $pu.week; cap = $cfg.capWeek }, @{ used = $pu.used; cap = 0.98 })) {
            if ($c.cap -and $c.used -ge [double]$c.cap - 0.15) { return @{ status = 'capped'; why = "the plan reading is $([int]$age) min old and $([math]::Round($c.used * 100))% is within 15 points of a $([math]::Round([double]$c.cap * 100))% cap; waiting for a fresh reading"; hard = $false; backSec = 300 } } } }
    }
    # paid extra usage switched on and the plan nearly used up: never let a kitchen run be the one that starts billing
    if ($pu -and $pu.overage -match '(?i)allowed|enabled' -and $pu.used -ge 0.9) { return @{ status = 'capped'; why = "extra usage is on ($($pu.overage)) and the plan is $([math]::Round($pu.used * 100))% used; waiting for the reset so nothing is billed"; hard = $false; backSec = [int][math]::Max(300, $(if ($pu.resetsAt) { ((ToUtc $pu.resetsAt) - (Now)).TotalSeconds } else { 0 })) } }
    # Jordan's own caps (suppliers.<x>.capFive / capWeek, fractions): the kitchen stops there and leaves the rest of the plan to him;
    # each step already cooking counts 2 points, since its use is not in the reading until it finishes
    $running = if ($pu -and $hasCap) { Running-Steps $sup } else { 0 }
    foreach ($c in @(@{ k = 'capFive'; used = $(if ($pu) { $pu.five } else { 0 }); w = '5-hour'; at = $(if ($pu) { $pu.fiveResets }) }, @{ k = 'capWeek'; used = $(if ($pu) { $pu.week } else { 0 }); w = 'weekly'; at = $(if ($pu) { $pu.weekResets }) })) {
        if ($pu -and $cfg[$c.k] -and $c.at -and $c.used + 0.02 * $running -ge [double]$cfg[$c.k]) {
            return @{ status = 'capped'; why = "Jordan's cap: $($c.w) window at $([math]::Round($c.used * 100))%$(if ($running) { " plus $running running" }) (cap $([math]::Round([double]$cfg[$c.k] * 100))%); resets $(([DateTime](ToUtc $c.at)).ToLocalTime().ToString('ddd HH:mm'))"; hard = $false; backSec = [int][math]::Max(60, ((ToUtc $c.at) - (Now)).TotalSeconds) }
        }
    }
    # pacing (suppliers.<x>.paceFive = slack, e.g. 0.15): spread the 5-hour window evenly so the kitchen reaches capFive right at the
    # reset instead of hitting it early and idling; allowed now = slack + capFive * (time elapsed in the window), never above capFive
    if ($pu -and $cfg.paceFive -and $cfg.capFive -and $pu.fiveResets) {
        $left = ((ToUtc $pu.fiveResets) - (Now)).TotalHours; $el = [math]::Min(1.0, [math]::Max(0.0, (5.0 - $left) / 5.0))
        $allow = [math]::Min([double]$cfg.capFive, [double]$cfg.paceFive + [double]$cfg.capFive * $el)
        if ($pu.five -ge $allow) {
            $catch = [math]::Max(60, [int](($pu.five - [double]$cfg.paceFive) / [double]$cfg.capFive * 5 * 3600 - (5 - $left) * 3600))
            return @{ status = 'capped'; why = "pacing the 5-hour window: $([math]::Round($pu.five * 100))% used, $([math]::Round($allow * 100))% allowed by now (reaches $([math]::Round([double]$cfg.capFive * 100))% at the reset)"; hard = $false; backSec = $catch }
        }
    }
    if ($pu -and $pu.used -ge 0.98) {   # the plan itself says the window is (almost) used up: wait for its reset, never push into extra usage
        return @{ status = 'capped'; why = "plan $($pu.window) window $([math]::Round($pu.used * 100))% used; resets $(([DateTime](ToUtc $pu.resetsAt)).ToLocalTime().ToString('ddd HH:mm'))"; hard = $false; backSec = [int][math]::Max(60, ((ToUtc $pu.resetsAt) - (Now)).TotalSeconds) }
    }
    $runs = Runs-InWindow $sup; $max = [int]$cfg.window.maxRuns
    if ($max -gt 0 -and $runs -ge $max) { return @{ status = 'capped'; why = "$runs runs in $($cfg.window.hours)h (cap $max)"; hard = $false; backSec = 1800 } }
    $p = Probe $sup
    if (-not $p.ready) { return @{ status = $(if ($p.hard) { 'signed-out' } else { 'busy' }); why = $p.why; hard = [bool]$p.hard; backSec = 300 } }
    @{ status = 'ready'; why = 'ready'; hard = $false; runs = $runs; max = $max }
}

$judgeSys = @'
Sort an order by what it is about (about) and by the kind of work (kind: code = writing or fixing code; write = prose, plans, emails, docs; quick = a short answer or label; plan = designing an approach). Answer "personal" if it mentions the writer's own life or other real people: family, partner, friends, home or address, rent, job, boss, employer, interview, offer, pay, money, debts, health, feelings, therapy, legal trouble, or names of real people. Answer "technical" for code, software, systems or tools. Answer "general" for public knowledge questions with nothing about the writer.
Examples:
"Help me reply to my sister about the holidays" -> personal
"Fix the null check in parser.py" -> technical
"What is the capital of Peru" -> general
"Write a cover letter for the job at Acme" -> personal
'@
# ---- the local judge: a small model on this PC, fixed answer format, hard time limit, never sees the cloud ----
function Ask-Judge([string]$system, [string]$text, $schema) {
    if ($NoJudge -or -not $S.sous.judge -or $env:KITCHEN_OLLAMA_URL -eq 'off') { return $null }
    $snip = $text.Substring(0, [math]::Min(6000, $text.Length))
    $need = [int](($system.Length + $snip.Length) / 3) + 256   # context sized to the prompt: 2048, 4096 or 8192 at most
    $ctx = if ($need -le 2048) { 2048 } elseif ($need -le 4096) { 4096 } else { 8192 }
    $lease = Enter-GpuLease $ollama ([string]$S.sous.judge) 'yard-judge' -TtlSec ([int]$S.sous.judgeTimeoutSec + 120) -MaxGpu ([int]$S.sous.judgeGpu)
    if ($lease.busy) { return $null }   # card and memory booked: no answer, the caller fails closed
    $b = @{ model = [string]$S.sous.judge; stream = $false; think = $false; keep_alive = '1m'; format = $schema; options = @{ temperature = 0; num_predict = 24; num_ctx = $ctx; num_gpu = [int]$S.sous.judgeGpu }   # small context + short stay: little RAM, gone 1 min after use
            messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $snip }) }
    Set-LeaseOnBody $b $lease; $body = $b | ConvertTo-Json -Depth 8
    try {
        $r = Invoke-RestMethod -Uri "$ollama/api/chat" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec ([int]$S.sous.judgeTimeoutSec)
        return ($r.message.content | ConvertFrom-Json -AsHashtable)
    } catch { return $null } finally { Exit-GpuLease $lease $ollama ([string]$S.sous.judge) }
}
# One look at an order by the local judge: is it about Jordan's life (private), and what kind of work is it. Answers are cached.
# First choice: a decision model (Ollama /v1/systemone) that scores the options and returns probabilities in well under a second;
# an order is private when P(personal) >= sous.privateAt (0.3: on 28 test orders no private one got out). Fallback: a small chat
# model with a strict JSON answer. If neither answers in time, the caller fails closed.
function Judge-Order([string]$text) {
    if ($NoJudge -or $env:KITCHEN_OLLAMA_URL -eq 'off') { return $null }
    $ck = 'j3|' + $S.sous.privateAt + '|' + $S.sous.sureAt + '|' + $S.sous.decider + '|' + (Sha $text)   # a settings change never reuses an old verdict
    if ($script:judged.ContainsKey($ck)) { return $script:judged[$ck] }   # one look per order per pick (privacy and kind sorting both ask)
    $c = (Read-JsonFile $cachePath)[$ck]; if ($c) { $script:judged[$ck] = $c; return $c }   # the same order at the next step or retry: no 90 s re-judge
    $snip = $text.Substring(0, [math]::Min(6000, $text.Length)); $v = $null
    $dl = if ($S.sous.decider) { Enter-GpuLease $ollama ([string]$S.sous.decider) 'yard-decider' -TtlSec ([int]$S.sous.judgeTimeoutSec + 120) }   # booked like the judge
    if ($S.sous.decider -and -not $dl.busy) {
        $db = @{ model = [string]$S.sous.decider; keep_alive = '15m'; state = @{ order = $snip }; questions = @{
            about = @{ type = 'choice'; instructions = 'What is this order about?'; criteria = @{
                personal = "The writer's own life or other real people: family, partner, friends, home, rent, job, boss, employer, interview, offer, pay, money, debts, health, feelings, therapy, legal trouble, or named real people"
                technical = 'Code, software, systems, tools or the kitchen itself'; general = 'Public knowledge with nothing about the writer' } }
            kind = @{ type = 'choice'; instructions = 'What kind of work is it?'; criteria = @{ code = 'Writing or fixing code'; write = 'Prose: notes, messages, plans, docs, explanations'; quick = 'A short answer, a label or a yes/no'; plan = 'Designing an approach' } } } }
        Set-LeaseOnBody $db $dl; $body = $db | ConvertTo-Json -Depth 8
        try {
            $r = Invoke-RestMethod -Uri "$ollama/v1/systemone" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec ([int]$S.sous.judgeTimeoutSec)
            $pp = [double]$r.answers.about.probabilities.personal
            if ($null -ne $r.answers.about.choice) { $v = @{ private = ($pp -ge [double]$S.sous.privateAt); p = [math]::Round($pp, 3); kind = [string]$r.answers.kind.choice; by = 'decider' } }
        } catch { } finally { Exit-GpuLease $dl $ollama ([string]$S.sous.decider) }
    }
    # A close call (between privateAt and sureAt) with no personal details the patterns can see gets a second opinion from the
    # chat judge: private only if it also says personal. If the second judge can't answer, it stays private (fail closed).
    $sure = if ($S.sous.sureAt) { [double]$S.sous.sureAt } else { 0.85 }
    if ($v -and $v.private -and $v.p -lt $sure -and $S.sous.judge -and -not @(Private-Signs $text).Count) {
        $a = Ask-Judge $judgeSys $snip @{ type = 'object'; properties = @{ about = @{ type = 'string'; enum = @('personal', 'technical', 'general') } }; required = @('about') }
        if ($a -and $a.about -in 'technical', 'general') { $v.private = $false; $v.second = [string]$a.about }
        else { $v.second = $(if ($a) { [string]$a.about } else { 'none' }) }
    }
    if (-not $v -and $S.sous.judge) {
        $a = Ask-Judge $judgeSys $snip @{ type = 'object'; properties = @{ about = @{ type = 'string'; enum = @('personal', 'technical', 'general') }; kind = @{ type = 'string'; enum = @('code', 'write', 'quick', 'plan') } }; required = @('about', 'kind') }
        if ($a -and $a.about -in 'personal', 'technical', 'general') { $v = @{ private = ($a.about -eq 'personal'); p = $null; kind = [string]$a.kind; by = 'judge' } }
    }
    if ($v -and $v.second -ne 'none') { $v.at = (Now).ToString('o'); $vv = $v   # a fail-closed answer (judge timed out) is never cached
        Update-JsonFile $cachePath { param($d) $d[$ck] = $vv; if ($d.Count -gt 500) { foreach ($k in @($d.Keys | Sort-Object { [string]$d[$_].at } | Select-Object -First ($d.Count - 500))) { $d.Remove($k) } } } }
    $script:judged[$ck] = $v
    $v
}
$script:judged = @{}
function Sha([string]$t) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($t))).Substring(0, 16) }

# ---- privacy: code first (fast, certain), the local judge as a second opinion ----
function Luhn([string]$d) { $s = 0; $alt = $false; for ($i = $d.Length - 1; $i -ge 0; $i--) { $n = [int][string]$d[$i]; if ($alt) { $n *= 2; if ($n -gt 9) { $n -= 9 } }; $s += $n; $alt = -not $alt }; $s % 10 -eq 0 }
# The private words cleared for the repo of the order being picked for (KITCHEN_JOB -> its job file's vars.repo), lower-cased.
# No job, no repo, or no entry: none cleared (fail closed).
function Get-PrivateWordsOkHere {
    $map = $S.sous.privateWordsOkIn; if (-not $map -or $env:KITCHEN_JOB -notmatch '^J\d+$') { return @() }
    $jf = Join-Path $root "jobs\$($env:KITCHEN_JOB).json"
    $repo = try { [string](Get-Content -LiteralPath $jf -Raw | ConvertFrom-Json).vars.repo } catch { '' }
    if (-not $repo) { return @() }
    $norm = { param($p) try { [IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant() } catch { '' } }
    $want = & $norm $repo; if (-not $want) { return @() }
    $isDict = $map -is [Collections.IDictionary]
    $keys = if ($isDict) { @($map.Keys) } else { @($map.PSObject.Properties.Name) }
    foreach ($k in $keys) {
        if ((& $norm $k) -eq $want) { return @(@($(if ($isDict) { $map[$k] } else { $map.$k })) | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    }
    @()
}
function Private-Signs([string]$t) {
    $found = @()
    # an email address, but not the made-up ones code and tests are full of (example.com, .test, localhost, noreply senders)
    foreach ($m in [regex]::Matches($t, '[\w.+-]+@([\w-]+(?:\.[\w-]+)+)')) {
        # version pins (react@18.3.1) and ssh remotes (git@github.com) are not addresses: a real one ends in a letter TLD
        if ($m.Groups[1].Value -notmatch '\.[A-Za-z]{2,}$' -or $m.Value -match '(?i)^git@' -or $m.Value -match '(?i)^no-?reply@' -or $m.Groups[1].Value -match '(?i)(^|\.)(example\.(com|org|net)|example|test|invalid|localhost|users\.noreply\.github\.com)$') { continue }
        $found += 'an email address'; break
    }
    if ($t -match '(?<![\d.])(\+?1[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}(?![\d.])') { $found += 'a phone number' }
    if ($t -match '\b\d{3}-\d{2}-\d{4}\b') { $found += 'an ID number' }
    # a card number: 15 or 16 digits from a card network (Amex 3, Visa 4, Mastercard 2/5, Discover 6) passing the Luhn check;
    # timestamps and ids in code (epoch milliseconds start with 1) are not cards
    foreach ($m in [regex]::Matches($t, '\b(?:\d[ -]?){15,16}\b')) { $d = $m.Value -replace '\D', ''; if ($d.Length -in 15, 16 -and $d[0] -in [char[]]'23456' -and (Luhn $d)) { $found += 'a card number'; break } }
    if ($t -match '(?i)\b(password|passwd|api[_ -]?key|secret|access[_ -]?token|private[_ -]?key)\s*[:=]|\bsk-[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY') { $found += 'a secret' }
    if ($t -match '(?i)\b(prescription|medical|medication|therapy|therapist|diagnosed|social security|bank account|routing number|salary|paycheck|paystub|tax return|passport|credit score|my rent|mortgage|landlord|(?<!technical )debts?|divorce|lawyer|lawsuit)\b|\b\d{2,3}k (salary|offer|a year)\b') { $found += 'health or money details' }
    # a private word Jordan cleared for one repo (sous.privateWordsOkIn: { "<repo path>": ["word"] }, e.g. "Demo Project" in the synthetic
    # demo-project repo, 2026-10-21) is not a sign for that repo's orders; every other check above still runs on them
    $okHere = @(Get-PrivateWordsOkHere)
    foreach ($w in @($S.sous.privateWords)) { if ($w -and $okHere -notcontains ([string]$w).ToLowerInvariant() -and $t -match ('(?i)\b' + [regex]::Escape([string]$w) + '\b')) { $found += "your private word '$w'"; break } }
    $found
}

# =====================================================================================================================
switch ($Action) {
'rest' {
    if (-not $S.suppliers.Contains($Name)) { Write-Output "ERROR: no supplier named $Name"; exit 2 }
    $min = [math]::Max(1, $(if ($ForMin -gt 0) { $ForMin } else { [int]$S.suppliers[$Name].restMin }))
    # the provider's words: -Raw, else the adapter's own record of its last limit (fresh: written in the last 10 minutes)
    $raw = $Raw; $dated = $null
    if (-not $raw) {
        $lf = Read-JsonFile (Join-Path $root "last-limit-$Name.json")
        if ($lf.raw -and $lf.at -and ((Now) - (ToUtc $lf.at)).TotalMinutes -lt 10) { $raw = [string]$lf.raw; $dated = [bool]$lf.dated }
    }
    if ($null -eq $dated -and $raw) { $dated = $raw -match '(?i)\b\d{4}-\d{2}-\d{2}\b|\b(Jan(uary)?|Feb(ruary)?|Mar(ch)?|Apr(il)?|May|June?|July?|Aug(ust)?|Sep(t(ember)?)?|Oct(ober)?|Nov(ember)?|Dec(ember)?)\.?\s+\d{1,2}\b|\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*[ap]\.?m\b' }
    $note = ''; $capH = [double]$S.sous.maxParsedRestHours
    if ($raw -and -not $dated -and $capH -gt 0 -and $min -gt $capH * 60) { $note = " (rest of $([math]::Round($min / 60, 1)) h capped at $capH h: its text names no date or time)"; $min = [int]($capH * 60) }
    $until = (Now).AddMinutes($min).ToString('o'); $w = $(if ($Why) { $Why } else { 'set by hand' }) + $note
    Update-JsonFile $statePath { param($d) if (-not $d[$Name]) { $d[$Name] = @{} }; $d[$Name].restUntil = $until; $d[$Name].why = $w; $d[$Name].at = (Now).ToString('o'); $d[$Name].restProbeAt = $null
        $d[$Name].raw = $(if ($raw) { $raw } else { $null }) }
    Write-Output "$Name rests until $until$note"; exit 0
}
'usage' {
    # refresh the Claude plan reading (5-hour and weekly use) with the smallest possible run: haiku, one turn, no tools
    if (-not $S.suppliers.claude.on) { Write-Output 'claude is off'; exit 0 }
    $p = Probe 'claude'; if (-not $p.ready) { Write-Output "claude not ready: $($p.why)"; exit 0 }
    $res = & (Join-Path $cooksDir 'claude.ps1') -Prompt 'Reply with exactly: OK' -Model 'haiku' -Tools 'Read' -MaxTurns 1 -TimeoutSec 120 | Where-Object { $_ -is [Collections.IDictionary] } | Select-Object -Last 1
    if ($res.plan) { Write-Output ("claude plan: 5-hour {0:P0} (resets {1}), weekly {2:P0} (resets {3}), extra usage {4}" -f $res.plan.fiveHour.used, $res.plan.fiveHour.resetsAt, $res.plan.sevenDay.used, $res.plan.sevenDay.resetsAt, $res.plan.overage); exit 0 }
    Write-Output "no plan reading: $($res.error)"; exit 1
}
'wake' {
    Update-JsonFile $statePath { param($d) if ($d[$Name]) { $d[$Name].restUntil = $null; $d[$Name].probe = $null; $d[$Name].restProbeAt = $null } }
    Write-Output "$Name is back on the line"; exit 0
}
'board' {
    $kinds = @($S.menu.Keys | Sort-Object)
    $b = [ordered]@{ at = (Now).ToString('o'); spentToday = [math]::Round((Spent-Today), 4); dailyBudgetUsd = $S.dailyBudgetUsd; suppliers = [ordered]@{}
                     judge = [ordered]@{ decider = [string]$S.sous.decider; privateAt = [double]$S.sous.privateAt; fallback = [string]$S.sous.judge; privateWords = @($S.sous.privateWords).Count }
                     menu = $S.menu }
    foreach ($n in $S.suppliers.Keys) {
        $cfg = $S.suppliers[$n]; $st = Status $n
        $track = [ordered]@{}; foreach ($k in $kinds) { $t = Track $n $k; if ($t.n) { $track[$k] = "$($t.ok)/$($t.n)" } }
        $b.suppliers[$n] = [ordered]@{ status = $st.status; why = $st.why; plan = $cfg.plan; runs = (Runs-InWindow $n); maxRuns = [int]$cfg.window.maxRuns
            windowHours = $cfg.window.hours; models = @(foreach ($tier in 'strong', 'mid', 'light') { $m = $cfg.tiers[$tier]; if ($m) { $(if ($m[0]) { $m[0] } else { '(default)' }) } }) | Select-Object -Unique
            track = $track; planUse = (Plan-Use $n) }
    }
    if ($Write) { $p = Join-Path $root 'suppliers-board.json'; $b | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$p.tmp" -Encoding utf8; Move-Item -LiteralPath "$p.tmp" -Destination $p -Force }
    if ($Json -or $Write) { if (-not $Write) { $b | ConvertTo-Json -Depth 6 } }
    else { foreach ($n in $b.suppliers.Keys) { $x = $b.suppliers[$n]; Write-Output ("{0,-8} {1,-11} {2,3}/{3,-4} runs in {4}h  {5}  {6}" -f $n, $x.status, $x.runs, $x.maxRuns, $x.windowHours, ($x.models -join ', '), $(if ($x.status -ne 'ready') { $x.why } else { '' })) } }
    exit 0
}
'pick' {
    $reasons = [Collections.Generic.List[string]]::new(); $by = 'rules'
    $toolList = @(([string]$Tools -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'none' })
    $needs = @{ edits = ($Mode -eq 'acceptEdits' -or [bool]($toolList | Where-Object { $_ -in 'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Bash' }))
                web = [bool]($toolList | Where-Object { $_ -in 'WebSearch', 'WebFetch' }); tools = $toolList.Count -gt 0 }
    $chars = $Prompt.Length   # ContextChars = how much of the prompt is attached files (lets a cook without tools take a files order)
    $approved = $env:KITCHEN_APPROVED -eq '1'
    $cache = Read-JsonFile $cachePath; $key = Sha "$Role|$Prompt"; $hit = $cache[$key]

    # 1. privacy
    $orderText = if ($Order) { $Order } else { ($Prompt -replace '(?ms)^Attached files \(read-only copies\):.*?(?=\r?\n\r?\nGoal:\s|\z)', '').Trim() }
    if (-not $orderText) { $orderText = $Prompt }
    # the privacy patterns read EVERY word that would leave this PC (the order, attachments, chat history): a card number in an attached
    # file or an earlier message is as private as one in the order. Only the judge (slow, and fooled by recipe boilerplate) reads orderText.
    $signs = @(@(Private-Signs $Prompt) + @(if ($Order) { Private-Signs $Order }) | Select-Object -Unique)
    $isPrivate = [bool]$Private -or $signs.Count -gt 0
    if ($Private) { $reasons.Add('marked private') } elseif ($signs.Count) { $reasons.Add("looks private (found $($signs -join ', '))") }
    elseif ($Public) { $reasons.Add('a public kitchen order (written by the kitchen itself): the life judge skips it; the privacy patterns still read every word') }
    elseif ($S.sous.privacyJudge -and $Supplier -ne 'local') {
        # the judge reads what Jordan (or a bot) actually asked for, not the recipe's fixed instructions around it
        $v = Judge-Order $orderText
        if ($v) { $by = "rules+$($v.by)" }
        if ($v -and $v.private) { $isPrivate = $true; $reasons.Add("the local judge says it is about your life$(if ($null -ne $v.p) { ' ({0:P0})' -f $v.p })$(if ($v.second -eq 'personal') { ', and a second local judge agreed' } elseif ($v.second -eq 'none') { '; the second judge did not answer, so it stays private' })") }
        elseif ($v -and $v.second) { $reasons.Add("the local judge was unsure ({0:P0}); a second local judge says it is $($v.second), so it may leave this PC" -f $v.p) }
        # fail closed for every order, tools or not: no answer from the judge is not a clearance. A plain-text order stays with the
        # local cook; a tool order (no local cook can use tools) waits for the judge to come back, or holds when the judge is switched off
        elseif (-not $v) { $isPrivate = $true; $judgeDown = $true; $reasons.Add('the local judge could not clear it, so this order stays on this PC until the judge answers or you say yes') }
    }
    # 2. kind
    if ($chars -gt [int]$S.sous.bigChars) { $kind = 'big'; $reasons.Add("big order ($chars characters)") }
    elseif ($Role -eq 'talk') { $kind = 'talk' }   # a chat message from the Talk tab: a conversational cook, no tools
    elseif ($Role -eq 'plan') { $kind = 'plan' } elseif ($Role -eq 'check') { $kind = 'check' }
    elseif ($Role -eq 'research' -or $needs.web) { $kind = 'research' }
    elseif ($needs.edits) { $kind = 'code' }
    elseif ($needs.tools) { $kind = 'review' }
    elseif ($Prompt.Length -lt 400 -and $Prompt -match '(?i)^\s*(is|are|does|do|can|should|which|what|classify|label|summari[sz]e|yes or no|true or false)\b') { $kind = 'quick' }
    else {
        $v = Judge-Order $orderText
        if ($v -and $v.kind -in 'code', 'write', 'quick', 'plan') { $kind = [string]$v.kind; $by = "rules+$($v.by)"; $reasons.Add("the local judge sorted it as $kind") } else { $kind = 'write' }
        if ($kind -eq 'code') { $kind = 'write' }   # without edit tools, code comes back as text
    }
    # 3. candidates from the menu (or the chef's override)
    function Cand([string]$sup, [string]$tier) {
        $cfg = $S.suppliers[$sup]; $m = if ($cfg -and $cfg.tiers[$tier]) { @($cfg.tiers[$tier]) } else { @('', '') }
        $up = Upgrade-Model $sup $tier; if ($up) { $m = @($up, $m[1]) }
        @{ supplier = $sup; tier = $tier; model = [string]$m[0]; effort = $(if ($m.Count -gt 1) { [string]$m[1] } else { '' }) }
    }
    $menuKind = if ($isPrivate -and -not $approved) { 'private' } else { $kind }
    $list = @(foreach ($e in @($S.menu[$menuKind])) { $p = ([string]$e) -split ':'; Cand $p[0] $(if ($p.Count -gt 1) { $p[1] } else { 'mid' }) })
    # a private taster never drops to the local model: a 9b model can't open files, and its SHIP could let a change merge unreviewed
    if ($kind -eq 'check' -and $menuKind -eq 'private') { $list = @(); $preNotes += 'the local model is never the taster (its SHIP could merge a change no real reviewer read)' }
    if ($isPrivate -and $approved) { $reasons.Add('Jordan said yes: a cloud cook may take this private step') }
    if ($Model -and $Supplier -eq 'auto') {
        foreach ($o in $S.sous.modelOwners.Keys) { if ($Model -match [string]$S.sous.modelOwners[$o]) { $Supplier = $o; break } }
        if ($Supplier -eq 'auto') { $d = @{ ok = $false; action = 'hold'; why = "no supplier is known for model '$Model' (add it to sous.modelOwners in kitchen.json)"; kind = $kind; private = $isPrivate; reasons = @($reasons) } ; if ($Json) { $d | ConvertTo-Json -Depth 5 -Compress } else { "HOLD: $($d.why)" }; exit 0 }
    }
    $override = $Supplier -ne 'auto'
    if ($override) {
        if ($isPrivate -and -not $approved -and $Supplier -ne 'local') {
            $d = @{ ok = $false; action = 'hold'; kind = $kind; private = $true; reasons = @($reasons); why = "this order looks private and you asked for $Supplier, a cloud cook. Say yes to send it there, or order it from the local cook." }
            if ($Json) { $d | ConvertTo-Json -Depth 5 -Compress } else { "HOLD: $($d.why)" }; exit 0
        }
        $tier = ($list | Where-Object { $_.supplier -eq $Supplier } | Select-Object -First 1).tier; if (-not $tier) { $tier = 'mid' }
        $c = Cand $Supplier $tier; if ($Model) { $c.model = $Model }
        $list = @($c); $reasons.Add("Jordan asked for $Supplier$(if ($Model) { " ($Model)" })")
    }

    # 4. pressure, learning, escalation (order only; never adds a cook the menu or Jordan did not name)
    if (-not $override) {
        $prev = $null
        if ($Attempt -lt 0 -and $env:KITCHEN_ATTEMPT) { $Attempt = [int]$env:KITCHEN_ATTEMPT }
        if ($Attempt -ge 1 -and $env:KITCHEN_RUN) {
            $pr = $env:KITCHEN_RUN -replace '-a\d+$', "-a$($Attempt - 1)"
            if (Test-Path -LiteralPath "$pr.cost.json") { try { $prev = Get-Content -LiteralPath "$pr.cost.json" -Raw | ConvertFrom-Json -AsHashtable } catch { } }
            if (-not $prev -and (Test-Path -LiteralPath "$pr.sous.json")) { try { $prev = Get-Content -LiteralPath "$pr.sous.json" -Raw | ConvertFrom-Json -AsHashtable } catch { } }
        }
        # a large order (size L) may use Claude's strong tier for its plan and build (Jordan 2026-10-22, Max plan; scoreboard judges it)
        if ($Size -eq 'L' -and $kind -in 'plan', 'code') {
            $list = @(foreach ($c in $list) { if ($c.supplier -eq 'claude' -and $c.tier -eq 'mid') { Cand 'claude' 'strong' } else { $c } })
            $reasons.Add('size L: Claude strong tier for the plan and build')
        }
        # the reviewer is never the builder: a check or review step avoids the model family that built this job (tide/08 rule 2)
        $builder = Builder-Family
        $score = @{}; $i = 0
        foreach ($c in $list) {
            $sc = $i * 10; $i++; $cfg = $S.suppliers[$c.supplier]
            if ($builder -and $kind -in 'check', 'review' -and (Model-Family $c.model) -eq $builder) { $sc += 60; $reasons.Add("$($c.supplier) $($c.model) is the builder's model family ($builder); a different reviewer first") }
            $pu = Plan-Use $c.supplier
            if ($pu -and $pu.used -ge [double]$S.sous.nearCap) { $sc += 25; $reasons.Add("$($c.supplier) is near its usage cap ($([math]::Round($pu.used * 100))% of its $($pu.window) plan window); others first") }
            elseif (-not $pu -and $cfg -and [int]$cfg.window.maxRuns -gt 0 -and (Runs-InWindow $c.supplier) -ge [double]$S.sous.nearCap * [int]$cfg.window.maxRuns) { $sc += 25; $reasons.Add("$($c.supplier) is near its usage cap; others first") }
            $t = Track $c.supplier $kind
            if ($t.n -ge [int]$S.sous.demoteMinRuns -and ($t.ok / $t.n) -lt [double]$S.sous.demoteBelow) { $sc += 40; $reasons.Add("$($c.supplier) passed only $($t.ok) of its last $($t.n) $kind orders; moved down") }
            if ($kind -in 'check', 'quick', 'write' -and $c.supplier -eq 'local' -and (Spent-Today) -ge [double]$S.sous.budgetPressure * $S.dailyBudgetUsd) { $sc -= 40; $reasons.Add('over 80% of today''s budget: local first') }
            if ($prev -and $prev.supplier -eq $c.supplier -and $prev.model -eq $c.model) { $sc += 100; $reasons.Add("retry: not $($c.supplier) $($c.model) again") }
            $score[$c] = $sc
        }
        $list = @($list | Sort-Object { $score[$_] })
        if ($Attempt -ge 1 -and $S.sous.escalate) {
            $up = @{ light = 'mid'; mid = 'strong'; strong = 'strong' }
            $list = @(foreach ($c in $list) { if ($c.supplier -ne 'local' -and $c.tier -ne 'strong') { $n = Cand $c.supplier $up[$c.tier]; $n } else { $c } })
            $reasons.Add("retry $Attempt`: stepping up a tier")
        }
    }

    # 5. who can actually cook it now
    $able = @(); $notes = @($preNotes); $soft = @()
    foreach ($c in $list) {
        $cfg = $S.suppliers[$c.supplier]
        if (-not $cfg) { $notes += "$($c.supplier): unknown"; continue }
        $can = $true; $miss = @()
        if ($needs.edits -and -not $cfg.edits) { $can = $false; $miss += 'edit files' }
        if ($needs.web -and -not $cfg.web) { $can = $false; $miss += 'use the web' }
        if ($needs.tools -and -not $cfg.tools -and -not ($ContextChars -gt 0 -and -not $needs.edits -and -not $needs.web)) { $can = $false; $miss += 'open files (give it -Context instead)' }
        if ($chars -gt [int]$cfg.maxChars) { $can = $false; $miss += "read $chars characters" }
        if (-not $can) { $notes += "$($c.supplier) can't $($miss -join ' or ')"; continue }
        $st = Status $c.supplier
        if ($st.status -ne 'ready') { $notes += "$($c.supplier) $($st.why)"; if (-not $st.hard) { $soft += $st }; continue }
        $able += $c
    }
    $notes = @($notes | Select-Object -Unique)
    $picked = $able | Select-Object -First 1
    $d = [ordered]@{ ok = [bool]$picked; action = 'cook'; supplier = ''; model = ''; effort = ''; tier = ''; kind = $kind; private = $isPrivate
                     why = ''; reasons = @($reasons); skipped = @($notes); fallbacks = @($able | Select-Object -Skip 1 | Select-Object -First 2); by = $by; ms = 0 }
    if ($picked) {
        $d.supplier = $picked.supplier; $d.model = $picked.model; $d.effort = $picked.effort; $d.tier = $picked.tier
        $d.why = "$kind order -> $($picked.supplier)$(if ($picked.model) { " $($picked.model)" }) ($($picked.tier))" + $(if ($reasons.Count) { '; ' + ($reasons -join '; ') } else { '' }) + $(if ($notes.Count) { '; skipped: ' + ($notes -join '; ') } else { '' })
    } elseif ($soft.Count -or ($judgeDown -and -not $approved -and -not $NoJudge -and $env:KITCHEN_OLLAMA_URL -ne 'off')) {
        # the judge was tried and did not answer (Ollama starting, busy or crashed): it comes back by itself, so wait (the kitchen
        # sets the step aside after 200 waits); a judge switched off can't come back, so that holds for Jordan instead
        if ($judgeDown -and -not $approved) { $soft += @{ backSec = 300 }; $notes += 'the local privacy judge did not answer' }
        $d.action = 'wait'; $d.waitSec = [int](($soft | ForEach-Object { [int]$_.backSec } | Measure-Object -Minimum).Minimum); if ($d.waitSec -lt 60) { $d.waitSec = 60 }
        $d.why = "no cook free for this $kind order right now ($($notes -join '; ')); trying again in $([math]::Ceiling($d.waitSec / 60)) min"
    } else {
        $d.action = 'hold'
        $d.why = $(if ($isPrivate -and -not $approved) { "this order looks private ($(if ($Private) { 'marked private' } elseif ($signs.Count) { 'it has ' + ($signs -join ', ') } else { (@($reasons | Where-Object { $_ -match 'judge' }) + 'the local judge says so')[0] })), so only the local cook may take it, but $($notes -join '; '). Say yes to let a cloud cook take this step." }
                   else { "no cook can take this $kind order: $($notes -join '; ')" })
    }
    $d.ms = [int]$t0.ElapsedMilliseconds
    if ($env:KITCHEN_RUN) { try { $d | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$env:KITCHEN_RUN.sous.json" -Encoding utf8 } catch { } }
    if ($Json) { $d | ConvertTo-Json -Depth 6 -Compress } else { Write-Output "SOUS: $($d.action.ToUpper()) $($d.why)" }
    exit 0
}
}
