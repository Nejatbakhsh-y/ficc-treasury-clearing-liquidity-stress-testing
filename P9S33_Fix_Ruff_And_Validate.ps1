<#
.SYNOPSIS
    Fixes the remaining Section 33 Ruff errors and validates the dashboard.

.DESCRIPTION
    Applies automatic Ruff fixes, wraps the three known long dashboard strings,
    validates unique Streamlit page paths, runs focused Section 33 tests without
    the repository coverage gate, runs the complete repository test and coverage
    gate, and optionally publishes and launches the dashboard.

.EXAMPLE
    .\P9S33_Fix_Ruff_And_Validate.ps1 -Publish -Launch
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/21-dashboard",
    [string]$BaseBranch = "main",
    [switch]$Publish,
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Assert-ExitCode {
    param([Parameter(Mandatory = $true)][string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Repository folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

$Python = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
$App = Join-Path $ProjectRoot "dashboard\streamlit_app.py"

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Virtual-environment Python not found: $Python"
}

if (-not (Test-Path -LiteralPath $App -PathType Leaf)) {
    throw "Dashboard application not found: $App"
}

Write-Step "Confirming dashboard branch"

$currentBranch = (& git branch --show-current).Trim()
Assert-ExitCode "Reading current Git branch"

if ($currentBranch -ne $Branch) {
    throw "Current branch is '$currentBranch'. Switch to '$Branch' before running this file."
}

Write-Pass "Current branch is $Branch"

Write-Step "Backing up dashboard application"

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $ProjectRoot "reports\setup_backups\section33_ruff_fix_$timestamp"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Copy-Item -LiteralPath $App -Destination (Join-Path $backupRoot "streamlit_app.py") -Force

Write-Pass "Backup created"

Write-Step "Applying automatic Ruff fixes"

& $Python -m ruff check `
    "dashboard\streamlit_app.py" `
    "tests\test_dashboard.py" `
    --fix

if ($LASTEXITCODE -notin @(0, 1)) {
    throw "Ruff automatic fixing failed with exit code $LASTEXITCODE."
}

Write-Step "Wrapping known long dashboard strings"

$patcher = @'
from pathlib import Path

path = Path("dashboard/streamlit_app.py")
text = path.read_text(encoding="utf-8")

pairs = [
    (
        '        "Scenario-level and default-set liquidity adequacy relative to available qualified resources.",\n',
        '        "Scenario-level and default-set liquidity adequacy relative to "\n'
        '        "available qualified resources.",\n',
    ),
    (
        '        "Minimum individual and combined stresses that produce LCR failure or a liquidity shortfall.",\n',
        '        "Minimum individual and combined stresses that produce LCR failure "\n'
        '        "or a liquidity shortfall.",\n',
    ),
    (
        '        "Model-use restrictions, residual uncertainty, public-data limitations, and governance controls.",\n',
        '        "Model-use restrictions, residual uncertainty, public-data limitations, "\n'
        '        "and governance controls.",\n',
    ),
]

for old, new in pairs:
    text = text.replace(old, new)

if "lambda: scenario_page(" in text:
    raise SystemExit(
        "Anonymous scenario-page lambda definitions remain. "
        "Run the page-path fix before continuing."
    )

required = (
    'url_path="historical-stress-scenarios"',
    'url_path="hypothetical-scenarios"',
)
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit(f"Missing required Streamlit URL paths: {missing}")

path.write_text(text, encoding="utf-8", newline="\n")
'@

$patcher | & $Python -
Assert-ExitCode "Dashboard long-line patch"

Write-Pass "Known long lines wrapped"

Write-Step "Running Ruff formatting and linting"

& $Python -m ruff format `
    "dashboard\streamlit_app.py" `
    "tests\test_dashboard.py"
Assert-ExitCode "Ruff formatting"

& $Python -m ruff check `
    "dashboard\streamlit_app.py" `
    "tests\test_dashboard.py"
Assert-ExitCode "Ruff linting"

Write-Pass "Ruff validation"

Write-Step "Running focused Section 33 tests"

$focusedTests = @("tests\test_dashboard.py")

if (Test-Path -LiteralPath "tests\test_data_quality_policy_update.py") {
    $focusedTests += "tests\test_data_quality_policy_update.py"
}

& $Python -m pytest -q -o addopts="" $focusedTests
Assert-ExitCode "Focused Section 33 tests"

Write-Pass "Focused Section 33 tests"

Write-Step "Running complete repository test and coverage gate"

& $Python -m pytest -q
Assert-ExitCode "Complete repository test and coverage gate"

Write-Pass "Complete repository test and coverage gate"

if ($Publish) {
    Write-Step "Staging controlled Section 33 files"

    $controlledFiles = @(
        "P9S33_Fix_Ruff_And_Validate.ps1",
        "dashboard\streamlit_app.py",
        "tests\test_dashboard.py",
        "src\ficc_liquidity\validation\data_quality.py",
        "tests\test_data_quality_policy_update.py",
        ".streamlit\config.toml",
        "configs\dashboard.yaml",
        "docs\streamlit_dashboard.md",
        "scripts\run_dashboard.py",
        "src\ficc_liquidity\dashboard",
        "pyproject.toml",
        "README.md",
        "reports\dashboard"
    ) | Where-Object { Test-Path -LiteralPath $_ }

    & git add -- $controlledFiles
    Assert-ExitCode "Staging controlled Section 33 files"

    $stagedEvidence = & git diff --cached --name-only |
        Where-Object { $_ -like "reports/evidence_packages/*" }

    if ($stagedEvidence) {
        & git restore --staged -- "reports/evidence_packages"
        Assert-ExitCode "Removing Section 32 evidence files from the Section 33 commit"
    }

    & git diff --cached --check
    Assert-ExitCode "Checking staged diff"

    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
        & git commit -m "Phase IX Section 33: fix dashboard validation"
        Assert-ExitCode "Creating Section 33 commit"
        Write-Pass "Section 33 commit created"
    }
    elseif ($LASTEXITCODE -eq 0) {
        Write-Host "No new staged changes required a commit." -ForegroundColor Yellow
    }
    else {
        throw "Unable to inspect staged changes."
    }

    Write-Step "Pushing dashboard branch"

    & git push -u origin $Branch
    Assert-ExitCode "Pushing $Branch"

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh pr view $Branch --json url | Out-Null

        if ($LASTEXITCODE -ne 0) {
            $body = @'
Completes Phase IX, Section 33 Streamlit dashboard.

Implemented:
- Fourteen controlled dashboard pages
- Unique historical and hypothetical scenario URL paths
- Federal Reserve market-condition reporting
- Synthetic member exposures
- Cover 1 and Cover 2
- Historical and hypothetical scenarios
- Liquidity Coverage Ratio and shortfalls
- Component contributions
- Sensitivity analysis and reverse stress
- Model monitoring
- Findings, remediation, limitations, and governance

Validation:
- Ruff: PASS
- Focused Section 33 tests: PASS
- Full repository tests: PASS
- Coverage threshold: PASS

All participant-level records are fictional synthetic observations.
The dashboard does not represent actual FICC production outcomes.
'@

            & gh pr create `
                --base $BaseBranch `
                --head $Branch `
                --title "Phase IX Section 33: Streamlit dashboard" `
                --body $body
            Assert-ExitCode "Creating Section 33 pull request"
        }
        else {
            $url = (& gh pr view $Branch --json url --jq ".url").Trim()
            Write-Host "Pull request already exists: $url"
        }
    }
    else {
        Write-Host "GitHub CLI not found. Branch was pushed without creating a pull request." `
            -ForegroundColor Yellow
    }

    Write-Pass "Section 33 published"
}

Write-Step "Section 33 result"

Write-Host "Ruff:                 PASS"
Write-Host "Focused tests:         PASS"
Write-Host "Full repository tests: PASS"
Write-Host "Coverage gate:         PASS"
Write-Host ""
Write-Host "SECTION 33 VALIDATION PASS" -ForegroundColor Green

if ($Launch) {
    Write-Step "Launching Streamlit dashboard"

    & $Python -m streamlit run `
        "dashboard\streamlit_app.py" `
        "--browser.gatherUsageStats=false"

    Assert-ExitCode "Launching Streamlit dashboard"
}
