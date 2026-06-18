<#
PowerShell script to run all Gatekeeper tests automatically.
Run from repo root with:
  powershell -NoProfile -ExecutionPolicy Bypass .\gatekeeper\run-gatekeeper-tests.ps1
#>

Param()

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir

$tests = [ordered]@{
    "test-latest-image.yaml" = @{ Expected = 'reject'; Description = 'Image :latest should be rejected' }
    "test-no-limits.yaml" = @{ Expected = 'reject'; Description = 'Missing resources.limits should be rejected' }
    "test-root-user.yaml" = @{ Expected = 'reject'; Description = 'runAsUser: 0 should be rejected' }
    "test-host-network.yaml" = @{ Expected = 'reject'; Description = 'hostNetwork: true should be rejected' }
    "test-compliant.yaml" = @{ Expected = 'pass'; Description = 'Valid pod should pass' }
}

function Write-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Message
    )
    $color = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
    Write-Host "[$Status] $Name - $Message" -ForegroundColor $color
}

function Ensure-Namespace {
    param([string]$Namespace)
    $exists = kubectl get namespace $Namespace -o name 2>$null
    if (-not $exists) {
        Write-Host "Namespace '$Namespace' does not exist. Creating it..." -ForegroundColor Cyan
        kubectl create namespace $Namespace | Out-Null
    }
}

function Ensure-GatekeeperLabel {
    param([string]$Namespace)
    $label = kubectl get namespace $Namespace -o jsonpath='{.metadata.labels.gatekeeper}' 2>$null
    if ($label -ne 'enabled') {
        Write-Host "Labeling namespace '$Namespace' with gatekeeper=enabled..." -ForegroundColor Cyan
        kubectl label namespace $Namespace gatekeeper=enabled --overwrite | Out-Null
    }
}

Write-Host "Running Gatekeeper tests from: $scriptDir" -ForegroundColor Cyan
Ensure-Namespace -Namespace 'demo'
Ensure-GatekeeperLabel -Namespace 'demo'

$results = @()

foreach ($file in $tests.Keys) {
    $expected = $tests[$file].Expected
    $description = $tests[$file].Description
    $path = Join-Path $scriptDir $file

    if (-not (Test-Path $path)) {
        Write-Result -Name $file -Status 'SKIP' -Message "Test file not found"
        $results += [pscustomobject]@{ File = $file; Result = 'SKIP'; Description = $description }
        continue
    }

    Write-Host "" -ForegroundColor DarkCyan
    Write-Host "==> Running test: $file ($description)" -ForegroundColor DarkCyan

    try {
        kubectl delete -f $path --ignore-not-found | Out-Null
    } catch {
        # ignore delete errors
    }

    $exitCode = 0
    try {
        kubectl apply -f $path 2>&1 | ForEach-Object { Write-Host $_ }
        $exitCode = 0
    } catch {
        $exitCode = 1
    }

    if ($expected -eq 'reject') {
        if ($exitCode -ne 0) {
            Write-Result -Name $file -Status 'PASS' -Message "Rejected as expected"
            $results += [pscustomobject]@{ File = $file; Result = 'PASS'; Description = $description }
        } else {
            Write-Result -Name $file -Status 'FAIL' -Message "Applied successfully but should be rejected"
            $results += [pscustomobject]@{ File = $file; Result = 'FAIL'; Description = $description }
        }
    } else {
        if ($exitCode -eq 0) {
            Write-Result -Name $file -Status 'PASS' -Message "Applied successfully as expected"
            $results += [pscustomobject]@{ File = $file; Result = 'PASS'; Description = $description }
        } else {
            Write-Result -Name $file -Status 'FAIL' -Message "Failed to apply but should pass"
            $results += [pscustomobject]@{ File = $file; Result = 'FAIL'; Description = $description }
        }
    }
}

Write-Host "" -ForegroundColor Cyan
Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$failCount = ($results | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Host "" -ForegroundColor Red
    Write-Host "Some tests failed. Check the output above." -ForegroundColor Red
    exit 1
} else {
    Write-Host "" -ForegroundColor Green
    Write-Host "All Gatekeeper tests passed." -ForegroundColor Green
    exit 0
}
