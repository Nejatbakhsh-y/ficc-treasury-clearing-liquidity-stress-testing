#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase VIII, Section 31 Git staging, commit, push, and pull request.

.DESCRIPTION
    Use this after P8S31_Repair_SIM102_And_Complete.ps1 has passed the Section 31
    validation gates but stopped because the controlled evidence file is ignored
    by .gitignore.

    The automation:
      - confirms the Section 31 branch;
      - stages all controlled Section 31 files;
      - force-adds controlled files that are intentionally ignored;
      - commits the Section 31 implementation;
      - pushes feature/20-monitoring-governance;
      - creates the pull request when GitHub CLI authentication is available.

.EXAMPLE
    .\P8S31_Complete_Staging_And_Publish.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/20-monitoring-governance",
    [string]$BaseBranch = "main",
    [switch]$SkipPush,
    [switch]$SkipPullRequest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (Test-Path -LiteralPath "variable:PSNativeCommandUseErrorActionPreference") {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Assert-ExitCode {
    param([Parameter(Mandatory = $true)][string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Add-ControlledPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $nativePath = $RelativePath -replace "/", [IO.Path]::DirectorySeparatorChar
    $absolutePath = Join-Path $ProjectRoot $nativePath

    if (-not (Test-Path -LiteralPath $absolutePath)) {
        Write-Warn "Controlled path not found and skipped: $RelativePath"
        return
    }

    & git check-ignore -q -- $RelativePath
    $isIgnored = ($LASTEXITCODE -eq 0)

    if ($isIgnored) {
        Write-Host "FORCE  $RelativePath"
        & git add -f -- $RelativePath
        Assert-ExitCode "Force-staging ignored controlled path $RelativePath"
    }
    else {
        Write-Host "ADD    $RelativePath"
        & git add -- $RelativePath
        Assert-ExitCode "Staging controlled path $RelativePath"
    }
}

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Repository folder not found: $ProjectRoot"
}

Set-Location -LiteralPath $ProjectRoot

Write-Step "Confirming repository and Section 31 branch"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found. Install Git and reopen VS Code."
}

& git rev-parse --is-inside-work-tree | Out-Null
Assert-ExitCode "Git repository validation"

$currentBranch = (& git branch --show-current).Trim()

if ($currentBranch -ne $Branch) {
    & git show-ref --verify --quiet "refs/heads/$Branch"

    if ($LASTEXITCODE -eq 0) {
        & git switch $Branch
        Assert-ExitCode "Switching to $Branch"
    }
    else {
        throw "Expected branch $Branch was not found. Current branch: $currentBranch"
    }
}

Write-Pass "Current branch is $Branch."

Write-Step "Confirming required Section 31 completion evidence"

$requiredEvidence = Join-Path $ProjectRoot "reports\evidence\section31_validation_finding_register.txt"

if (-not (Test-Path -LiteralPath $requiredEvidence -PathType Leaf)) {
    throw @"
The Section 31 completion evidence file was not found:

$requiredEvidence

Rerun P8S31_Repair_SIM102_And_Complete.ps1 before using this completion script.
"@
}

$evidenceText = [IO.File]::ReadAllText($requiredEvidence)

if (-not $evidenceText.Contains("FINAL DECISION: PASS")) {
    throw "The Section 31 evidence file does not contain 'FINAL DECISION: PASS'."
}

if (-not $evidenceText.Contains("SECTION 31: COMPLETE")) {
    throw "The Section 31 evidence file does not contain 'SECTION 31: COMPLETE'."
}

Write-Pass "Section 31 completion evidence is present and records PASS."

Write-Step "Staging controlled Section 31 files"

$controlledPaths = @(
    ".github/ISSUE_TEMPLATE/validation-finding.yml",
    "configs/validation_findings.yaml",
    "data/manifests/validation_finding_register.csv",
    "docs/validation_finding_register.md",
    "src/ficc_liquidity/governance/__init__.py",
    "src/ficc_liquidity/governance/validation_findings.py",
    "scripts/run_validation_findings.py",
    "scripts/automation/P8S31_Setup_Validation_Finding_Register.ps1",
    "tests/test_validation_findings.py",
    "sql/validation_finding_register.sql",
    "reports/governance/findings/.gitkeep",
    "reports/governance/findings/demo",
    "reports/evidence/section31_validation_finding_register.txt",
    "P8S31_Setup_Validation_Finding_Register.ps1",
    "P8S31_Repair_SIM102_And_Complete.ps1",
    "P8S31_Complete_Staging_And_Publish.ps1"
)

foreach ($relativePath in $controlledPaths | Select-Object -Unique) {
    Add-ControlledPath -RelativePath $relativePath
}

Write-Step "Reviewing staged Section 31 changes"

& git diff --cached --stat
Assert-ExitCode "Reviewing staged changes"

& git diff --cached --quiet
$hasStagedChanges = ($LASTEXITCODE -ne 0)

if ($hasStagedChanges) {
    Write-Step "Committing Section 31"

    & git commit -m "Phase VIII Section 31: add validation finding register"
    Assert-ExitCode "Section 31 Git commit"

    Write-Pass "Section 31 changes committed."
}
else {
    Write-Warn "No staged changes required a new commit. The Section 31 work may already be committed."
}

if (-not $SkipPush) {
    Write-Step "Pushing the Section 31 branch"

    & git push -u origin $Branch
    Assert-ExitCode "Pushing $Branch"

    Write-Pass "Branch pushed successfully."
}

if (-not $SkipPullRequest) {
    Write-Step "Creating or locating the Section 31 pull request"

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warn "GitHub CLI is not installed. The branch was pushed, but the pull request was not created."
    }
    else {
        & gh auth status 2>$null

        if ($LASTEXITCODE -ne 0) {
            Write-Warn @"
GitHub CLI authentication is expired or unavailable.
The Section 31 branch has been pushed successfully.

Authenticate later with:
gh auth login
"@
        }
        else {
            $existingPr = (
                & gh pr list `
                    --head $Branch `
                    --state open `
                    --json url `
                    --jq '.[0].url // empty'
            ).Trim()

            if ($existingPr) {
                Write-Pass "Existing pull request: $existingPr"
            }
            else {
                $prBody = @"
Completes Phase VIII, Section 31 validation finding register.

Finding classifications:
- Critical
- High
- Medium
- Low
- Observation

Required fields:
- Finding ID
- Category
- Condition
- Evidence
- Risk
- Recommendation
- Management response
- Owner
- Target date
- Status
- Closure evidence

Implemented controls:
- unique controlled finding IDs
- approved classifications and statuses
- required-field validation
- target-date and overdue controls
- Critical and High risk-acceptance prohibition
- substantive independent closure evidence
- classification, status, aging, and due-soon reporting
- deterministic synthetic demonstration evidence
- GitHub validation-finding issue form
- DuckDB-compatible governance views

Validation:
- Ruff: PASS
- focused Section 31 tests: PASS
- Python compilation: PASS
- controlled register validation: PASS
- deterministic demonstration: PASS

All included findings are synthetic project-governance examples and are not
actual FICC, DTCC, clearing-member, or participant findings.
"@

                & gh pr create `
                    --base $BaseBranch `
                    --head $Branch `
                    --title "Phase VIII Section 31: Validation finding register" `
                    --body $prBody

                Assert-ExitCode "Creating the Section 31 pull request"
                Write-Pass "Pull request created."
            }
        }
    }
}

Write-Step "Section 31 completed"

Write-Host "Repository: $ProjectRoot"
Write-Host "Branch:     $Branch"
Write-Host "Evidence:   reports\evidence\section31_validation_finding_register.txt"
Write-Host ""
Write-Host "SECTION 31 FINAL DECISION: PASS" -ForegroundColor Green
Write-Host "SECTION 31: COMPLETE" -ForegroundColor Green
