#requires -Version 5.1
<#
.SYNOPSIS
    Finalizes Phase II Section 10 after calibration passed but Git refused
    to stage controlled report artifacts because of .gitignore rules.

.DESCRIPTION
    Run from the repository root in the VS Code PowerShell terminal while on:
        feature/08-historical-stress-calibration

    This script does not rerun the full calibration. It:
      1. Verifies the completed Section 10 outputs exist and are nonempty.
      2. Adds narrow .gitignore exceptions for the controlled Section 10 evidence.
      3. Stages the implementation and report deliverables.
      4. Commits the completed Section 10 work.
      5. Optionally pushes the branch and opens the pull request.

.PARAMETER Publish
    Push feature/08-historical-stress-calibration to origin.

.PARAMETER CreatePullRequest
    Open the Section 10 pull request after pushing. This implies -Publish.
#>

[CmdletBinding()]
param(
    [switch]$Publish,
    [switch]$CreatePullRequest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Write-Host "> $FilePath $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

Write-Step "Resolving repository and current branch"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is unavailable in PATH."
}

$repoRootRaw = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repoRootRaw) {
    throw "Open the repository in VS Code and run this script from its PowerShell terminal."
}

$RepoRoot = [System.IO.Path]::GetFullPath(($repoRootRaw | Select-Object -First 1).Trim())
Set-Location $RepoRoot

$TargetBranch = "feature/08-historical-stress-calibration"
$currentBranch = (& git branch --show-current).Trim()

if ($currentBranch -ne $TargetBranch) {
    throw "Current branch is '$currentBranch'. Switch to '$TargetBranch' before running this finalizer."
}

Write-Host "[PASS] Current branch: $TargetBranch" -ForegroundColor Green

$regularFiles = @(
    ".gitignore",
    "configs/historical_scenarios.yaml",
    "src/ficc_liquidity/analysis/__init__.py",
    "src/ficc_liquidity/analysis/historical_stress.py",
    "scripts/run_historical_stress_calibration.py",
    "tests/test_historical_stress.py",
    "docs/section_10_historical_stress_methodology.md",
    "scripts/automation/P2S10_Resume_After_Series_Resolution_Failure.ps1"
)

$controlledReportFiles = @(
    "reports/tables/historical_stress_windows.csv",
    "reports/tables/historical_stress_daily_scores.csv",
    "reports/evidence/historical_stress_calibration.txt"
)

Write-Step "Verifying completed Section 10 outputs"

$requiredFiles = @(
    "configs/historical_scenarios.yaml",
    "src/ficc_liquidity/analysis/historical_stress.py",
    "scripts/run_historical_stress_calibration.py",
    "tests/test_historical_stress.py",
    "docs/section_10_historical_stress_methodology.md"
) + $controlledReportFiles

foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $RepoRoot $relativePath
    if (-not (Test-Path $fullPath -PathType Leaf)) {
        throw "Required Section 10 file is missing: $relativePath"
    }
    if ((Get-Item $fullPath).Length -eq 0) {
        throw "Required Section 10 file is empty: $relativePath"
    }
}

$windowsPath = Join-Path $RepoRoot "reports/tables/historical_stress_windows.csv"
$windowRows = @(Import-Csv $windowsPath)
if ($windowRows.Count -lt 1) {
    throw "historical_stress_windows.csv contains no selected stress windows."
}

Write-Host "[PASS] Historical calibration contains $($windowRows.Count) selected stress window(s)." -ForegroundColor Green

Write-Step "Adding narrow .gitignore exceptions for controlled Section 10 artifacts"

$gitignorePath = Join-Path $RepoRoot ".gitignore"
if (-not (Test-Path $gitignorePath -PathType Leaf)) {
    throw ".gitignore is missing from the repository root."
}

$gitignoreContent = Get-Content $gitignorePath -Raw
$gitignoreLines = @(
    Get-Content $gitignorePath |
        ForEach-Object { $_.Trim() }
)
$exceptionLines = @(
    "!reports/tables/historical_stress_windows.csv",
    "!reports/tables/historical_stress_daily_scores.csv",
    "!reports/evidence/historical_stress_calibration.txt"
)

$missingExceptions = @(
    $exceptionLines | Where-Object {
        $gitignoreLines -notcontains $_
    }
)

if ($missingExceptions.Count -gt 0) {
    $appendBlock = @"

# Controlled Phase II Section 10 calibration deliverables
$($missingExceptions -join "`n")
"@
    $updatedContent = $gitignoreContent.TrimEnd("`r", "`n") + "`n" + $appendBlock.TrimStart("`r", "`n") + "`n"
    Write-Utf8NoBom -Path $gitignorePath -Content $updatedContent
    Write-Host "[PASS] Added Section 10 report exceptions to .gitignore." -ForegroundColor Green
}
else {
    Write-Host "[PASS] Required .gitignore exceptions already exist." -ForegroundColor Green
}

Write-Step "Preserving this finalizer under scripts/automation"

$automationRelative = "scripts/automation/P2S10_Finalize_After_GitIgnore.ps1"
$automationPath = Join-Path $RepoRoot $automationRelative
if ([System.IO.Path]::GetFullPath($PSCommandPath) -ne [System.IO.Path]::GetFullPath($automationPath)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $automationPath) -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $automationPath -Force
}

if ($regularFiles -notcontains $automationRelative) {
    $regularFiles += $automationRelative
}

Write-Step "Staging implementation and controlled evidence"

$existingRegularFiles = @(
    $regularFiles | Where-Object {
        Test-Path (Join-Path $RepoRoot $_) -PathType Leaf
    }
)

Invoke-Native -FilePath "git" -Arguments (@("add", "--") + $existingRegularFiles)

# Force-add is intentional and limited to the three controlled Section 10 artifacts.
Invoke-Native -FilePath "git" -Arguments (@("add", "-f", "--") + $controlledReportFiles)

$stagedFiles = @(& git diff --cached --name-only)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect staged files."
}

if ($stagedFiles.Count -eq 0) {
    Write-Host "[INFO] No new staged changes were found; the Section 10 commit may already exist." -ForegroundColor Yellow
}
else {
    Write-Host "Staged files:" -ForegroundColor Green
    $stagedFiles | ForEach-Object { Write-Host "  $_" }

    Write-Step "Committing Section 10"
    Invoke-Native -FilePath "git" -Arguments @(
        "commit",
        "-m",
        "feat: complete Section 10 historical stress calibration"
    )
}

if ($CreatePullRequest) {
    $Publish = $true
}

if ($Publish) {
    Write-Step "Pushing feature branch"
    Invoke-Native -FilePath "git" -Arguments @(
        "push",
        "-u",
        "origin",
        $TargetBranch
    )
}

if ($CreatePullRequest) {
    Write-Step "Creating or locating the Section 10 pull request"

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI is unavailable. Install or authenticate gh, then rerun with -CreatePullRequest."
    }

    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' and rerun this finalizer."
    }

    $existingPr = & gh pr list `
        --head $TargetBranch `
        --base main `
        --state open `
        --json url `
        --jq ".[0].url"

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query existing pull requests."
    }

    $existingPr = ($existingPr | Out-String).Trim()

    if ($existingPr) {
        Write-Host "[PASS] Existing pull request: $existingPr" -ForegroundColor Green
    }
    else {
        $prBody = @"
## Summary

Completes Phase II, Section 10 — Historical stress-window identification.

## Objective calibration channels

- SOFR spikes
- Treasury yield shocks
- Settlement-fail increases
- Financing-volume disruptions
- Reserve-balance contractions
- Combined market-stress indicator

## Deliverables

- reports/tables/historical_stress_windows.csv
- configs/historical_scenarios.yaml
- reports/evidence/historical_stress_calibration.txt
- reports/tables/historical_stress_daily_scores.csv
- controlled calibration implementation, tests, and methodology documentation

## Validation

- Local quality gates: PASS
- Historical calibration execution: PASS
- Selected historical stress windows: $($windowRows.Count)
- Section 10 final decision: COMPLETE
"@

        Invoke-Native -FilePath "gh" -Arguments @(
            "pr",
            "create",
            "--base",
            "main",
            "--head",
            $TargetBranch,
            "--title",
            "Phase II Section 10: Historical stress-window identification",
            "--body",
            $prBody
        )
    }
}

Write-Step "Final status"

$commitSha = (& git rev-parse --short HEAD).Trim()
Write-Host "[PASS] Section 10 commit: $commitSha" -ForegroundColor Green
Write-Host "[PASS] Historical stress windows: $($windowRows.Count)" -ForegroundColor Green

$status = @(& git status --short)
if ($status.Count -eq 0) {
    Write-Host "[PASS] Working tree is clean." -ForegroundColor Green
}
else {
    Write-Host "[INFO] Remaining unstaged or untracked items:" -ForegroundColor Yellow
    $status | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

Write-Host "`nSection 10 finalization completed successfully." -ForegroundColor Green
