# Tests for kitchen/gpu-lease.ps1 (local models book the graphics card first): no lease tool leaves Ollama as before; the ladder (whole
# model, part of it, the processor under a RAM lease, busy); a failing tool means the processor; a lease ends with the model unloaded. Self-cleaning.
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
$d = Join-Path ([IO.Path]::GetTempPath()) ('gpu-lease-' + [guid]::NewGuid().ToString('N'))
$saved = @{ BRAIN_KITCHEN = $env:BRAIN_KITCHEN; KITCHEN_LEASE = $env:KITCHEN_LEASE }
try {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $env:BRAIN_KITCHEN = $d; $env:KITCHEN_LEASE = $null
    . (Join-Path $PSScriptRoot '..\kitchen\gpu-lease.ps1')
    # stand-ins: the model's shape, the lease tool (refuses what $script:fit does not allow), Ollama's unload calls
    $script:shape = @{ mb = 4000; blocks = 32 }; $script:fit = @(); $script:calls = @(); $script:code = 75; $script:ps = @()
    function Get-ModelShape([string]$Url, [string]$Model) { $script:shape }
    function Invoke-LeaseTool([string[]]$Cmd, [string[]]$LeaseArgs) {
        $script:calls += , $LeaseArgs
        if ($LeaseArgs[0] -eq 'release') { return @{ code = 0; text = "released $($LeaseArgs[1])" } }
        $key = "$($LeaseArgs[1]):$($LeaseArgs[5])"
        if ($script:fit -contains $key) { return @{ code = 0; text = 'abc123def456' } }
        @{ code = $script:code; text = "lease refused: GPU budget: no room for $key" }
    }
    function Invoke-RestMethod { param($Uri, $Method, $Body, $ContentType, $TimeoutSec) $script:calls += , @('ollama', [string]$Uri); if ($Uri -like '*/api/ps') { return @{ models = $script:ps } }; @{} }

    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'
    $b = @{ keep_alive = '2m'; options = @{ num_ctx = 2048 } }; Set-LeaseOnBody $b $l
    Check 'no lease tool: Ollama decides as before' ($null -eq $l.numGpu -and -not $l.busy -and $b.keep_alive -eq '2m' -and -not $b.options.ContainsKey('num_gpu') -and -not $script:calls.Count)

    Set-Content -LiteralPath (Join-Path $d 'gpu-lease.json') -Value '{"cmd": ["leasetool"]}'
    $script:fit = @('gpu:4800')
    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'
    $b = @{ keep_alive = '2m'; options = @{ num_ctx = 2048 } }; Set-LeaseOnBody $b $l
    Check 'whole model fits: gpu lease, every layer, unloaded right after' ($l.id -eq 'abc123def456' -and $l.kind -eq 'gpu' -and $l.mb -eq 4800 -and $b.options.num_gpu -eq 999 -and $b.keep_alive -eq 0)

    $script:fit = @('gpu:1536'); $script:calls = @()
    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'
    Check 'card short: a smaller lease and only the layers it holds' ($l.kind -eq 'gpu' -and $l.mb -eq 1536 -and $l.numGpu -eq 8 -and $script:calls.Count -eq 2)

    $script:fit = @('heavy:4400')
    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'
    Check 'card full: the processor under a RAM lease' ($l.kind -eq 'heavy' -and $l.numGpu -eq 0 -and -not $l.busy)

    $script:fit = @()
    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'
    Check 'card and memory full: busy with the reason' ($l.busy -and $null -eq $l.id -and $l.why -match 'GPU budget')

    $script:fit = @('heavy:4400'); $script:calls = @()
    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'judge' -MaxGpu 0
    Check 'judge set to the processor: no gpu ask at all' ($l.kind -eq 'heavy' -and $script:calls.Count -eq 1 -and $script:calls[0][1] -eq 'heavy')

    $script:code = 1; $script:fit = @()
    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'
    Check 'a broken lease tool: the processor, never the card unbooked' ($l.numGpu -eq 0 -and -not $l.busy -and $l.why -match 'failed')

    $script:code = 75; $script:fit = @('gpu:4800'); $script:calls = @()
    $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'; Exit-GpuLease $l 'http://127.0.0.1:1' 'm:9b'
    $flat = @($script:calls | ForEach-Object { $_ -join ' ' })
    $iu = [array]::IndexOf($flat, 'ollama http://127.0.0.1:1/api/generate'); $ir = [array]::IndexOf($flat, 'release abc123def456')
    Check 'the lease ends after the model is unloaded' ($iu -ge 0 -and $ir -gt $iu)

    $env:KITCHEN_LEASE = 'off'; $l = Enter-GpuLease 'http://127.0.0.1:1' 'm:9b' 'job'
    Check 'KITCHEN_LEASE=off: no lease' ($null -eq $l.numGpu)
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "GpuLease tests: $script:pass passed, $script:fail failed"
exit ([int]($script:fail -ne 0))
