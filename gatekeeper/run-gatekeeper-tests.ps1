<#
PowerShell script to run Gatekeeper tests automatically.
Run from repo root with:
  powershell -NoProfile -ExecutionPolicy Bypass .\gatekeeper\run-gatekeeper-tests.ps1 [-Lab lab1-2|lab1-3|all]
#>

Param(
    [Parameter(Position=0)]
    [ValidateSet('lab1-2','lab1-3','all')]
    [string]$Lab = 'all'
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptDir

$testDefinitions = [ordered]@{
    'test-latest-image.yaml'    = @{ Expected = 'reject'; Description = 'Image :latest should be rejected' }
    'test-no-limits.yaml'       = @{ Expected = 'reject'; Description = 'Missing resources.limits should be rejected' }
    'test-root-user.yaml'       = @{ Expected = 'reject'; Description = 'runAsUser: 0 should be rejected' }
    'test-host-network.yaml'     = @{ Expected = 'reject'; Description = 'hostNetwork: true should be rejected' }
    'test-compliant.yaml'       = @{ Expected = 'pass';   Description = 'Valid pod should pass' }
    'test-violations.yaml'      = @{ Expected = 'reject'; Description = 'Multiple violations in a single manifest should be rejected' }
    'test-custom-replicas.yaml' = @{ Expected = 'reject'; Description = 'Deployment replicas > 5 should be rejected by custom policy' }
    'test-custom-label.yaml'    = @{ Expected = 'reject'; Description = 'Deployment missing owner label should be rejected by custom policy' }
    'test-custom-registry.yaml' = @{ Expected = 'reject'; Description = 'Deployment from disallowed registry should be rejected by custom policy' }
    'test-custom-pass.yaml'     = @{ Expected = 'pass';   Description = 'Valid deployment should pass custom policy' }
}

$labTests = @{
    'lab1-2' = @(
        'test-latest-image.yaml',
        'test-no-limits.yaml',
        'test-root-user.yaml',
        'test-host-network.yaml',
        'test-compliant.yaml',
        'test-violations.yaml'
    )
    'lab1-3' = @(
        'test-custom-replicas.yaml',
        'test-custom-label.yaml',
        'test-custom-registry.yaml',
        'test-custom-pass.yaml'
    )
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

function Test-KubectlResourceExists {
    param(
        [string]$Resource,
        [string]$Name
    )
    $result = kubectl get $Resource $Name -o name 2>$null
    return -not [string]::IsNullOrWhiteSpace($result)
}

function Ensure-GatekeeperCustomDeploymentConstraint {
    $constraintType = 'k8scustomdeploymentpolicy'
    $constraintName = 'custom-deployment-policy'
    $crdName = "$constraintType.constraints.gatekeeper.sh"
    $constraintFile = Join-Path -Path $scriptDir -ChildPath 'constraints\k8s-custom-deployment-policy.yaml'

    if (-not (Test-KubectlResourceExists -Resource 'crd' -Name $crdName)) {
        Write-Host "Applying Gatekeeper custom deployment template and waiting for CRD..." -ForegroundColor Cyan
        $output = & kubectl apply -f $constraintFile 2>&1
        $output | ForEach-Object { Write-Host $_ }

        for ($i = 0; $i -lt 30; $i++) {
            if (Test-KubectlResourceExists -Resource 'crd' -Name $crdName) {
                break
            }
            Start-Sleep -Seconds 1
        }

        if (-not (Test-KubectlResourceExists -Resource 'crd' -Name $crdName)) {
            Write-Host "CRD '$crdName' did not become available." -ForegroundColor Red
            exit 2
        }
    }

    if (-not (Test-KubectlResourceExists -Resource $constraintType -Name $constraintName)) {
        Write-Host "Applying Gatekeeper custom deployment constraint resource..." -ForegroundColor Cyan
        $output = & kubectl apply -f $constraintFile 2>&1
        $output | ForEach-Object { Write-Host $_ }
    }
}

$selectedLabs = if ($Lab -eq 'all') { $labTests.Keys } else { ,$Lab }
$tests = @()
foreach ($lab in $selectedLabs) {
    if (-not ($labTests.Keys -contains $lab)) {
        Write-Host "Unknown lab '$lab'. Valid values are lab1-2, lab1-3, all." -ForegroundColor Red
        exit 2
    }

    foreach ($file in $labTests[$lab]) {
        if (-not ($testDefinitions.Keys -contains $file)) {
            Write-Host "Test definition for '$file' not found." -ForegroundColor Red
            exit 2
        }

        $tests += [pscustomobject]@{
            Lab = $lab
            File = $file
            Expected = $testDefinitions[$file].Expected
            Description = $testDefinitions[$file].Description
            Path = Join-Path -Path $scriptDir -ChildPath (Join-Path -Path $lab -ChildPath $file)
        }
    }
}

Write-Host "Running Gatekeeper tests from: $scriptDir" -ForegroundColor Cyan
Write-Host "Selected lab(s): $($selectedLabs -join ', ')" -ForegroundColor Cyan
Ensure-Namespace -Namespace 'demo'
Ensure-GatekeeperLabel -Namespace 'demo'
Ensure-GatekeeperCustomDeploymentConstraint

$results = @()

foreach ($test in $tests) {
    $file = $test.File
    $expected = $test.Expected
    $description = $test.Description
    $path = $test.Path

    if (-not (Test-Path $path)) {
        Write-Result -Name "$($test.Lab)/$file" -Status 'SKIP' -Message "Test file not found"
        $results += [pscustomobject]@{ File = "$($test.Lab)/$file"; Result = 'SKIP'; Description = $description }
        continue
    }

    Write-Host "" -ForegroundColor DarkCyan
    Write-Host "==> Running test: $($test.Lab)/$file ($description)" -ForegroundColor DarkCyan

    kubectl delete -f $path --ignore-not-found | Out-Null

    $output = & kubectl apply -f $path 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }

    $invalidManifest = $output | Select-String -Pattern 'error parsing|error converting YAML to JSON|error validating' -SimpleMatch
    if ($invalidManifest -and $exitCode -ne 0) {
        Write-Result -Name "$($test.Lab)/$file" -Status 'FAIL' -Message "Invalid manifest: $($invalidManifest.Line.Trim())"
        $results += [pscustomobject]@{ File = "$($test.Lab)/$file"; Result = 'FAIL'; Description = $description }
        continue
    }

    if ($expected -eq 'reject') {
        if ($exitCode -ne 0) {
            Write-Result -Name "$($test.Lab)/$file" -Status 'PASS' -Message "Rejected as expected"
            $results += [pscustomobject]@{ File = "$($test.Lab)/$file"; Result = 'PASS'; Description = $description }
        } else {
            Write-Result -Name "$($test.Lab)/$file" -Status 'FAIL' -Message "Applied successfully but should be rejected"
            $results += [pscustomobject]@{ File = "$($test.Lab)/$file"; Result = 'FAIL'; Description = $description }
        }
    } else {
        if ($exitCode -eq 0) {
            Write-Result -Name "$($test.Lab)/$file" -Status 'PASS' -Message "Applied successfully as expected"
            $results += [pscustomobject]@{ File = "$($test.Lab)/$file"; Result = 'PASS'; Description = $description }
        } else {
            Write-Result -Name "$($test.Lab)/$file" -Status 'FAIL' -Message "Failed to apply but should pass"
            $results += [pscustomobject]@{ File = "$($test.Lab)/$file"; Result = 'FAIL'; Description = $description }
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
