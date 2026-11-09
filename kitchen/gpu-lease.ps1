# Owns the graphics-card lease for local models: every Ollama load takes a lease from the PC's lease tool first, or runs on the processor.
# Dot-sourced by kitchen/cooks/local.ps1, kitchen/sous-chef.ps1 (the judges) and kitchen/stations/lead-pitch.ps1.
# The PC may run other GPU work (a live model server) that owns most of the card. A lease tool keeps the book: `<cmd> take gpu|heavy
# --job NAME --mb N --ttl S --pid P` prints a lease id (exit 0) or why not (exit 75); `<cmd> release ID`. Where it is: gpu-lease.json
# in the state folder ({"cmd": ["exe", "arg", ...]}), never in the repo. No file, or KITCHEN_LEASE=off: no lease, Ollama decides as before.
# The ladder: the whole model on the card; else part of it (a smaller GPU lease, fewer layers); else the processor under a RAM (heavy)
# lease; else wait and try again until WaitSec is spent. A model loaded under a lease is unloaded (keep_alive 0) before the lease goes.

function Get-GpuLeaseCmd {
    if ($env:KITCHEN_LEASE -eq 'off') { return $null }
    $state = if ($env:BRAIN_KITCHEN) { $env:BRAIN_KITCHEN } else { Join-Path $env:LOCALAPPDATA 'brain-kitchen' }
    $p = Join-Path $state 'gpu-lease.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $c = @((Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).cmd | ForEach-Object { [string]$_ }) } catch { return $null }
    if (-not $c.Count -or -not $c[0]) { return $null }
    , $c
}

function Invoke-LeaseTool([string[]]$Cmd, [string[]]$LeaseArgs) {
    $rest = @($Cmd | Select-Object -Skip 1) + $LeaseArgs
    $out = & $Cmd[0] @rest 2>&1 | Out-String
    @{ code = $LASTEXITCODE; text = $out.Trim() }
}

# -> @{ mb; blocks } for a pulled model: its file size and layer count (from /api/show), $null when Ollama does not say
function Get-ModelShape([string]$Url, [string]$Model) {
    $mb = $null; $blocks = $null
    try { $m = @((Invoke-RestMethod -Uri "$Url/api/tags" -TimeoutSec 3).models | Where-Object { $_.name -eq $Model -or $_.model -eq $Model }) | Select-Object -First 1; if ($m) { $mb = [int]([double]$m.size / 1MB) } } catch { }
    try {
        $info = (Invoke-RestMethod -Uri "$Url/api/show" -Method Post -Body (@{ model = $Model } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 5).model_info
        foreach ($p in @($info.PSObject.Properties)) { if ($p.Name -like '*.block_count') { $blocks = [int]$p.Value; break } }
    } catch { }
    @{ mb = $mb; blocks = $blocks }
}

# -> @{ id; kind; mb; numGpu; busy; why }: numGpu $null = no lease tool (Ollama decides), 0 = processor, N = layers on the card.
# busy = nothing fit within WaitSec (the caller answers busy and the order waits). A lease tool that fails: the processor, no lease.
function Enter-GpuLease([string]$Url, [string]$Model, [string]$Job, [int]$WaitSec = 0, [int]$TtlSec = 3600, [int]$MaxGpu = 999) {
    $cmd = Get-GpuLeaseCmd
    if (-not $cmd) { return @{ id = $null; kind = ''; mb = 0; numGpu = $null; busy = $false; why = '' } }
    $shape = Get-ModelShape $Url $Model
    $weights = if ($shape.mb) { [int]($shape.mb * 1.1) } else { 0 }
    $full = $weights + 400    # 400 MB: the compute buffers and the KV cache of a context of 8192 or less
    $rungs = @()
    if ($weights -and $MaxGpu -gt 0) {
        $rungs += , @{ kind = 'gpu'; mb = $full; numGpu = 999 }
        if ($shape.blocks) {
            foreach ($mb in 1536, 1024) {
                if ($mb -ge $full) { continue }
                $n = [int][math]::Floor($shape.blocks * ($mb - 400) / $weights)
                if ($n -ge 1) { $rungs += , @{ kind = 'gpu'; mb = $mb; numGpu = $n } }
            }
        }
    }
    $rungs += , @{ kind = 'heavy'; mb = [math]::Max(512, $weights); numGpu = 0 }
    $until = (Get-Date).AddSeconds([math]::Max(0, $WaitSec)); $why = ''
    while ($true) {
        foreach ($r in $rungs) {
            $res = Invoke-LeaseTool $cmd @('take', $r.kind, '--job', $Job, '--mb', [string]$r.mb, '--ttl', [string]$TtlSec, '--pid', [string]$PID)
            if ($res.code -eq 0 -and $res.text -match '^[0-9a-f]{6,}$') {
                $ng = if ($r.numGpu -gt $MaxGpu) { $MaxGpu } else { $r.numGpu }
                return @{ id = $res.text; kind = $r.kind; mb = $r.mb; numGpu = $ng; busy = $false; why = '' }
            }
            $why = ($res.text -replace '^lease refused:\s*', '')
            if ($res.code -ne 75) { return @{ id = $null; kind = ''; mb = 0; numGpu = 0; busy = $false; why = "lease tool failed: $why" } }   # never the card unbooked
        }
        if ((Get-Date) -ge $until) { break }
        Start-Sleep -Seconds 15
    }
    @{ id = $null; kind = ''; mb = 0; numGpu = 0; busy = $true; why = $why }
}

# Unload the model (keep_alive 0, then wait up to 15 s until Ollama lists it gone), then release the lease.
function Exit-GpuLease($Lease, [string]$Url, [string]$Model) {
    if (-not $Lease -or -not $Lease.id) { return }
    try {
        Invoke-RestMethod -Uri "$Url/api/generate" -Method Post -Body (@{ model = $Model; keep_alive = 0 } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 | Out-Null
        $until = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $until) {
            $up = @((Invoke-RestMethod -Uri "$Url/api/ps" -TimeoutSec 3).models | Where-Object { $_.name -eq $Model -or $_.model -eq $Model })
            if (-not $up.Count) { break }
            Start-Sleep -Milliseconds 500
        }
    } catch { }
    $cmd = Get-GpuLeaseCmd
    if ($cmd) { Invoke-LeaseTool $cmd @('release', [string]$Lease.id) | Out-Null }
}

# Set the request's keep_alive and options.num_gpu from a lease (a hashtable body); no lease tool: the body is left as it was.
function Set-LeaseOnBody([hashtable]$Body, $Lease) {
    if ($null -eq $Lease.numGpu) { return }
    $Body.keep_alive = 0
    if (-not $Body.ContainsKey('options') -or $null -eq $Body.options) { $Body.options = @{} }
    $Body.options.num_gpu = [int]$Lease.numGpu
}
