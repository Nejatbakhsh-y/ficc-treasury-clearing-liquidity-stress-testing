<#
.SYNOPSIS
    Final Phase IX, Section 33 dashboard repair, validation, publication, and launch.

.DESCRIPTION
    This single automation file:
      1. Confirms branch feature/21-dashboard.
      2. Repairs the Ruff SIM102 violation using Ruff unsafe fixes.
      3. Ensures unique Streamlit page functions and URL paths.
      4. Removes trailing whitespace and normalizes controlled text files to LF.
      5. Runs Ruff, Mypy, focused Section 33 tests, and the complete coverage gate.
      6. Stages only controlled Section 33 files.
      7. Excludes reports/evidence_packages from the Section 33 commit.
      8. Commits, pushes, and creates or confirms the pull request.
      9. Optionally launches the Streamlit dashboard.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\P9S33_FINAL.ps1" -Launch
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/21-dashboard",
    [string]$BaseBranch = "main",
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

function Normalize-TextFile {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $ProjectRoot $RelativePath

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return
    }

    $text = [IO.File]::ReadAllText($path)
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"

    $lines = $text -split "`n", -1
    $cleanLines = foreach ($line in $lines) {
        $line -replace "[ `t]+$", ""
    }

    $cleanText = (($cleanLines -join "`n").TrimEnd("`n")) + "`n"

    [IO.File]::WriteAllText(
        $path,
        $cleanText,
        [Text.UTF8Encoding]::new($false)
    )
}

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Repository folder not found: $ProjectRoot"
}

Set-Location $ProjectRoot

$Python = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
$CoreFile = "src\ficc_liquidity\dashboard\core.py"
$AppFile = "dashboard\streamlit_app.py"
$DashboardTests = "tests\test_dashboard.py"

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Virtual-environment Python not found: $Python"
}

foreach ($requiredFile in @($CoreFile, $AppFile, $DashboardTests)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required Section 33 file not found: $requiredFile"
    }
}

Write-Step "Confirming Git branch"

$currentBranch = (& git branch --show-current).Trim()
Assert-ExitCode "Reading current Git branch"

if ($currentBranch -ne $Branch) {
    throw "Current branch is '$currentBranch'. Expected '$Branch'."
}

Write-Pass "Current branch is $Branch"

Write-Step "Creating safety backup"

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $env:TEMP "ficc_section33_final_$timestamp"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

Copy-Item -LiteralPath $CoreFile -Destination (Join-Path $backupRoot "core.py") -Force
Copy-Item -LiteralPath $AppFile -Destination (Join-Path $backupRoot "streamlit_app.py") -Force
Copy-Item -LiteralPath "README.md" -Destination (Join-Path $backupRoot "README.md") -Force

Write-Pass "Safety backup created at $backupRoot"

Write-Step "Repairing Ruff SIM102"

& $Python -m ruff check `
    $CoreFile `
    --fix `
    --unsafe-fixes
Assert-ExitCode "Ruff SIM102 repair"

& $Python -m ruff check $CoreFile
Assert-ExitCode "Ruff SIM102 verification"

Write-Pass "SIM102 repaired"

Write-Step "Ensuring unique Streamlit page paths"

$pagePathFix = @'
from pathlib import Path
import re

path = Path("dashboard/streamlit_app.py")
text = path.read_text(encoding="utf-8")

wrapper = """def historical_stress_scenarios_page() -> None:
    scenario_page(
        "historical_scenarios",
        "Historical Stress Scenarios",
        "Historical market episodes used for plausibility and severity assessment.",
    )


def hypothetical_scenarios_page() -> None:
    scenario_page(
        "hypothetical_scenarios",
        "Hypothetical Scenarios",
        (
            "Moderate, severe, extreme, curve, funding, haircut, fail, "
            "and combined stresses."
        ),
    )


"""

marker = 'PAGES: dict[str, list[st.Page]] = {'

if "def historical_stress_scenarios_page() -> None:" not in text:
    if marker not in text:
        raise SystemExit("PAGES dictionary marker was not found.")
    text = text.replace(marker, wrapper + marker, 1)

historical_pattern = re.compile(
    r"""(?ms)^[ \t]*st\.Page\(
[ \t]*lambda:[ \t]*scenario_page\(
[ \t]*"historical_scenarios",.*?
[ \t]*title="Historical stress scenarios",
[ \t]*\),"""
)

historical_replacement = """        st.Page(
            historical_stress_scenarios_page,
            title="Historical stress scenarios",
            url_path="historical-stress-scenarios",
        ),"""

text = historical_pattern.sub(historical_replacement, text, count=1)

hypothetical_pattern = re.compile(
    r"""(?ms)^[ \t]*st\.Page\(
[ \t]*lambda:[ \t]*scenario_page\(
[ \t]*"hypothetical_scenarios",.*?
[ \t]*title="Hypothetical scenarios",
[ \t]*\),"""
)

hypothetical_replacement = """        st.Page(
            hypothetical_scenarios_page,
            title="Hypothetical scenarios",
            url_path="hypothetical-scenarios",
        ),"""

text = hypothetical_pattern.sub(hypothetical_replacement, text, count=1)

long_line_replacements = {
    (
        '        "Scenario-level and default-set liquidity adequacy relative '
        'to available qualified resources.",\n'
    ): (
        '        "Scenario-level and default-set liquidity adequacy relative to "\n'
        '        "available qualified resources.",\n'
    ),
    (
        '        "Minimum individual and combined stresses that produce LCR '
        'failure or a liquidity shortfall.",\n'
    ): (
        '        "Minimum individual and combined stresses that produce LCR failure "\n'
        '        "or a liquidity shortfall.",\n'
    ),
    (
        '        "Model-use restrictions, residual uncertainty, public-data '
        'limitations, and governance controls.",\n'
    ): (
        '        "Model-use restrictions, residual uncertainty, public-data limitations, "\n'
        '        "and governance controls.",\n'
    ),
}

for old, new in long_line_replacements.items():
    text = text.replace(old, new)

if "lambda: scenario_page(" in text:
    raise SystemExit("Anonymous scenario-page lambda definitions remain.")

required = (
    'url_path="historical-stress-scenarios"',
    'url_path="hypothetical-scenarios"',
)

missing = [value for value in required if value not in text]
if missing:
    raise SystemExit(f"Missing required page paths: {missing}")

path.write_text(text, encoding="utf-8", newline="\n")
'@

$pagePathFix | & $Python -
Assert-ExitCode "Streamlit page-path repair"

Write-Pass "Unique Streamlit page paths confirmed"

Write-Step "Normalizing controlled Section 33 text files"

$filesToNormalize = @(
    "P9S33_FINAL.ps1",
    ".streamlit\config.toml",
    "configs\dashboard.yaml",
    $AppFile,
    "docs\streamlit_dashboard.md",
    "scripts\run_dashboard.py",
    "src\ficc_liquidity\dashboard\__init__.py",
    $CoreFile,
    $DashboardTests,
    "src\ficc_liquidity\validation\data_quality.py",
    "tests\test_data_quality_policy_update.py",
    "pyproject.toml",
    "README.md",
    "reports\dashboard\section33_validation.json"
)

foreach ($file in $filesToNormalize) {
    Normalize-TextFile -RelativePath $file
}

Write-Pass "Controlled text files normalized"

Write-Step "Running Ruff formatting"

& $Python -m ruff format `
    "src\ficc_liquidity\dashboard" `
    $AppFile `
    "scripts\run_dashboard.py" `
    $DashboardTests
Assert-ExitCode "Ruff formatting"

Write-Pass "Ruff formatting"

Write-Step "Running Ruff linting"

& $Python -m ruff check `
    "src\ficc_liquidity\dashboard" `
    $AppFile `
    "scripts\run_dashboard.py" `
    $DashboardTests
Assert-ExitCode "Ruff linting"

Write-Pass "Ruff linting"

Write-Step "Running Mypy"

& $Python -m mypy `
    "src\ficc_liquidity\dashboard" `
    "scripts\run_dashboard.py"
Assert-ExitCode "Mypy validation"

Write-Pass "Mypy validation"

Write-Step "Running focused Section 33 tests"

$focusedTests = @($DashboardTests)

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

Write-Step "Staging controlled Section 33 files"

$controlledPaths = @(
    "P9S33_FINAL.ps1",
    ".streamlit\config.toml",
    "configs\dashboard.yaml",
    $AppFile,
    "docs\streamlit_dashboard.md",
    "scripts\run_dashboard.py",
    "src\ficc_liquidity\dashboard",
    $DashboardTests,
    "src\ficc_liquidity\validation\data_quality.py",
    "tests\test_data_quality_policy_update.py",
    "pyproject.toml",
    "README.md",
    "reports\dashboard"
) | Where-Object { Test-Path -LiteralPath $_ }

& git add -- $controlledPaths
Assert-ExitCode "Staging controlled Section 33 files"

$stagedEvidencePackages = @(
    & git diff --cached --name-only |
        Where-Object { $_ -like "reports/evidence_packages/*" }
)

if ($stagedEvidencePackages.Count -gt 0) {
    & git restore --staged -- "reports/evidence_packages"
    Assert-ExitCode "Removing Section 32 evidence packages from the Section 33 commit"
}

Write-Step "Validating staged diff"

& git diff --cached --check
Assert-ExitCode "Staged whitespace validation"

Write-Pass "Staged diff validation"

Write-Step "Creating Section 33 commit"

& git diff --cached --quiet

if ($LASTEXITCODE -eq 1) {
    & git commit -m "Phase IX Section 33: complete Streamlit dashboard"
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
Assert-ExitCode "Pushing dashboard branch"

Write-Pass "Dashboard branch pushed"

if (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Step "Creating or confirming pull request"

    & gh pr view $Branch --json url | Out-Null

    if ($LASTEXITCODE -ne 0) {
        $body = @'
Completes Phase IX, Section 33 Streamlit dashboard.

Implemented:
- Fourteen controlled dashboard pages
- Federal Reserve market conditions
- Synthetic member exposures
- Cover 1 and Cover 2
- Historical and hypothetical scenarios
- Liquidity Coverage Ratio and shortfalls
- Component contributions
- Sensitivity analysis and reverse stress
- Model monitoring
- Findings and remediation
- Limitations and governance
- Unique Streamlit page URL paths
- Repository evidence discovery and lineage
- Clearly labelled deterministic fallback data

Validation:
- Ruff: PASS
- Mypy: PASS
- Focused Section 33 tests: PASS
- Full repository test and coverage gate: PASS
- Staged whitespace validation: PASS

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

    Write-Pass "Pull request confirmed"
}
else {
    Write-Host "GitHub CLI was not found. The branch was pushed without creating a pull request." `
        -ForegroundColor Yellow
}

Write-Step "Section 33 final result"

Write-Host "SIM102 repair:         PASS"
Write-Host "Streamlit page paths:  PASS"
Write-Host "Ruff:                  PASS"
Write-Host "Mypy:                  PASS"
Write-Host "Focused tests:         PASS"
Write-Host "Full repository gate:  PASS"
Write-Host "Whitespace validation: PASS"
Write-Host "Branch push:           PASS"
Write-Host ""
Write-Host "SECTION 33 PUBLISHED" -ForegroundColor Green

if ($Launch) {
    Write-Step "Launching Streamlit dashboard"

    & $Python -m streamlit run `
        $AppFile `
        "--browser.gatherUsageStats=false"

    Assert-ExitCode "Launching Streamlit dashboard"
}
