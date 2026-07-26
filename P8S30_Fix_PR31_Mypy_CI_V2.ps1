<#
.SYNOPSIS
    Completes the PR #31 Mypy repair after the Section 29 ndarray annotation failure.

.DESCRIPTION
    Preserves the previously corrected Section 30 governance.py changes, fixes the
    repository-wide NumPy ndarray annotation in monthly.py, runs Ruff, Mypy, and the
    complete Pytest/coverage gate, commits both repairs, and pushes the existing
    feature/21-monitoring-thresholds-escalation branch.

.EXAMPLE
    .\P8S30_Fix_PR31_Mypy_CI_V2.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/21-monitoring-thresholds-escalation",
    [int]$PullRequestNumber = 31,
    [switch]$SkipPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Assert-ExitCode {
    param([Parameter(Mandatory = $true)][string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Resolve-ProjectPython {
    $venvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"

    if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
        return $venvPython
    }

    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3.11 -m venv (Join-Path $ProjectRoot ".venv")
        Assert-ExitCode "Python 3.11 virtual-environment creation"
    }
    elseif (Get-Command python -ErrorAction SilentlyContinue) {
        & python -m venv (Join-Path $ProjectRoot ".venv")
        Assert-ExitCode "Python virtual-environment creation"
    }
    else {
        throw "Python 3.11 was not found."
    }

    if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
        throw "Virtual-environment interpreter was not created: $venvPython"
    }

    return $venvPython
}

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Repository folder was not found: $ProjectRoot"
}

Set-Location $ProjectRoot

Write-Step "Validating the repository and current branch"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found."
}

& git rev-parse --is-inside-work-tree | Out-Null
Assert-ExitCode "Git repository validation"

$currentBranch = (& git branch --show-current).Trim()

if ($currentBranch -ne $Branch) {
    throw "Current branch is '$currentBranch'. Switch to '$Branch' before running this repair."
}

$allowedTrackedPaths = @(
    "src/ficc_liquidity/monitoring/governance.py",
    "src/ficc_liquidity/monitoring/monthly.py"
)

$trackedChanges = @(& git status --porcelain --untracked-files=no)

foreach ($change in $trackedChanges) {
    if ([string]::IsNullOrWhiteSpace($change)) {
        continue
    }

    $path = $change.Substring(3).Trim()
    if ($path.Contains(" -> ")) {
        $path = ($path -split " -> ")[-1].Trim()
    }

    $normalizedPath = $path -replace "\\", "/"

    if ($normalizedPath -notin $allowedTrackedPaths) {
        Write-Host "Unexpected tracked change: $change" -ForegroundColor Red
        throw "Only the expected monitoring repair files may be modified before this repair runs."
    }
}

$governancePath = Join-Path $ProjectRoot "src\ficc_liquidity\monitoring\governance.py"
$monthlyPath = Join-Path $ProjectRoot "src\ficc_liquidity\monitoring\monthly.py"

if (-not (Test-Path -LiteralPath $governancePath -PathType Leaf)) {
    throw "Section 30 governance module was not found: $governancePath"
}

if (-not (Test-Path -LiteralPath $monthlyPath -PathType Leaf)) {
    throw "Section 29 monitoring module was not found: $monthlyPath"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $ProjectRoot "reports\evidence\backups\section30_pr31_mypy_v2_$timestamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Copy-Item -LiteralPath $governancePath -Destination (Join-Path $backupDir "governance.py") -Force
Copy-Item -LiteralPath $monthlyPath -Destination (Join-Path $backupDir "monthly.py") -Force

Write-Step "Verifying the prior Section 30 Mypy corrections"

$governanceContent = Get-Content -LiteralPath $governancePath -Raw

$requiredGovernanceText = @(
    "from typing import Any, ClassVar, cast",
    'for raw_row in scorecard.to_dict(orient="records"):',
    "row = cast(dict[str, Any], raw_row)",
    'for raw_row in open_actions.to_dict(orient="records"):'
)

foreach ($requiredText in $requiredGovernanceText) {
    if (-not $governanceContent.Contains($requiredText)) {
        throw "The prior governance.py repair is missing: $requiredText"
    }
}

Write-Host "PASS: The two Section 30 pandas-record corrections are preserved." -ForegroundColor Green

Write-Step "Applying the NumPy ndarray type annotation correction"

$monthlyContent = Get-Content -LiteralPath $monthlyPath -Raw

if ($monthlyContent -notmatch '(?m)^import numpy\.typing as npt$') {
    $monthlyContent = $monthlyContent -replace `
        '(?m)^import numpy as np$', `
        "import numpy as np`nimport numpy.typing as npt"
}

$oldSignature = '    def _pearson(x: np.ndarray, y: np.ndarray) -> float:'
$newSignature = '    def _pearson(x: npt.NDArray[np.float64], y: npt.NDArray[np.float64]) -> float:'

if ($monthlyContent.Contains($oldSignature)) {
    $monthlyContent = $monthlyContent.Replace($oldSignature, $newSignature)
}
elseif (-not $monthlyContent.Contains($newSignature)) {
    throw "The _pearson signature did not match the expected source."
}

Set-Content -LiteralPath $monthlyPath -Value $monthlyContent -Encoding utf8

$monthlyVerification = Get-Content -LiteralPath $monthlyPath -Raw

if (-not $monthlyVerification.Contains("import numpy.typing as npt")) {
    throw "NumPy typing import correction was not applied."
}

if (-not $monthlyVerification.Contains($newSignature)) {
    throw "The typed _pearson signature was not applied."
}

Write-Host "PASS: The ndarray type arguments were added." -ForegroundColor Green

$Python = Resolve-ProjectPython

Write-Step "Ensuring development dependencies are installed"

& $Python -c "import mypy, pytest, ruff"
if ($LASTEXITCODE -ne 0) {
    & $Python -m pip install --upgrade pip
    Assert-ExitCode "pip upgrade"

    & $Python -m pip install -e ".[dev]"
    Assert-ExitCode "Project development dependency installation"
}

Write-Step "Running Ruff formatting"

& $Python -m ruff format `
    src/ficc_liquidity/monitoring/governance.py `
    src/ficc_liquidity/monitoring/monthly.py `
    tests/test_monitoring_governance.py `
    tests/test_monthly_monitoring.py `
    scripts/run_monitoring_governance.py `
    scripts/run_monthly_monitoring.py
Assert-ExitCode "Ruff formatting"

Write-Step "Running Ruff lint validation"

& $Python -m ruff check `
    src/ficc_liquidity/monitoring/governance.py `
    src/ficc_liquidity/monitoring/monthly.py `
    tests/test_monitoring_governance.py `
    tests/test_monthly_monitoring.py `
    scripts/run_monitoring_governance.py `
    scripts/run_monthly_monitoring.py
Assert-ExitCode "Ruff lint validation"

Write-Step "Running repository-wide Mypy validation"

& $Python -m mypy src tests
Assert-ExitCode "Mypy validation"

Write-Step "Running the complete Pytest and coverage gate"

& $Python -m pytest -q
Assert-ExitCode "Pytest and coverage validation"

Write-Step "Committing both CI corrections"

$pathsToStage = @(
    "src/ficc_liquidity/monitoring/governance.py",
    "src/ficc_liquidity/monitoring/monthly.py"
)

foreach ($path in $pathsToStage) {
    & git add -- $path
    Assert-ExitCode "Staging $path"
}

$scriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)

if ($scriptPath.StartsWith($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
    $scriptRelative = $scriptPath.Substring($ProjectRoot.Length).TrimStart("\", "/") -replace "\\", "/"

    if ($scriptRelative) {
        & git add -- $scriptRelative
        Assert-ExitCode "Staging the repair automation"
    }
}

& git diff --cached --quiet

if ($LASTEXITCODE -eq 0) {
    Write-Host "No new repair changes required a commit."
}
else {
    & git commit -m "Fix monitoring Mypy annotations"
    Assert-ExitCode "Creating the Mypy repair commit"
}

if (-not $SkipPublish) {
    Write-Step "Publishing the corrections to PR #31"

    & git push origin $Branch
    Assert-ExitCode "Pushing $Branch"

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh pr view $PullRequestNumber --web

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "The correction was pushed, but PR #$PullRequestNumber could not be opened automatically."
        }
    }
}

Write-Step "PR #31 Mypy repair completed"
Write-Host "Branch:       $Branch"
Write-Host "Pull request: #$PullRequestNumber"
Write-Host "Backup:       $backupDir"
Write-Host "Next action: wait for GitHub Actions and merge only when every check is green."
