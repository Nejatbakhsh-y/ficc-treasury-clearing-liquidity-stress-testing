#requires -Version 5.1
<#
.SYNOPSIS
    Repairs the Section 31 Ruff SIM102 finding and completes validation/publishing.

.DESCRIPTION
    This repair automation:
      1. Patches the nested-if Ruff SIM102 violation in the generated Python engine.
      2. Patches the original Section 31 PowerShell automation so reruns do not
         recreate the violation.
      3. Runs Ruff, focused Mypy when available, Pytest, Python compilation,
         controlled-register validation, and the deterministic demonstration.
      4. Writes Section 31 completion evidence.
      5. Commits, pushes, and attempts to create the pull request.

.EXAMPLE
    .\P8S31_Repair_SIM102_And_Complete.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/20-monitoring-governance",
    [string]$BaseBranch = "main",
    [switch]$SkipPublish
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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Repair-Sim102Block {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warn "$Label was not found and was skipped: $Path"
        return $false
    }

    $text = [IO.File]::ReadAllText($Path)
    $normalized = $text -replace "`r`n", "`n"

    $oldBlock = @'
            if status in {"Pending Validation Review", "Closed"}:
                if "independent" not in closure_evidence.lower() and status == "Closed":
                    issues.append(
                        FindingIssue(
                            level="WARNING",
                            code="INDEPENDENCE_NOT_EXPLICIT",
                            finding_id=finding_id,
                            message=(
                                "Closed finding evidence should explicitly identify "
                                "independent validation review."
                            ),
                        )
                    )
'@

    $newBlock = @'
            if (
                status == "Closed"
                and "independent" not in closure_evidence.lower()
            ):
                issues.append(
                    FindingIssue(
                        level="WARNING",
                        code="INDEPENDENCE_NOT_EXPLICIT",
                        finding_id=finding_id,
                        message=(
                            "Closed finding evidence should explicitly identify "
                            "independent validation review."
                        ),
                    )
                )
'@

    if ($normalized.Contains($oldBlock)) {
        $normalized = $normalized.Replace($oldBlock, $newBlock)
        Write-Utf8NoBom -Path $Path -Content $normalized
        Write-Pass "$Label repaired."
        return $true
    }

    if ($normalized.Contains($newBlock)) {
        Write-Pass "$Label was already repaired."
        return $false
    }

    $nestedIfMarker = 'if status in {"Pending Validation Review", "Closed"}:'
    if ($normalized.Contains($nestedIfMarker)) {
        throw @"
$Label still contains the nested-if marker, but its surrounding text did not match
the controlled Section 31 block. Open this file and inspect the block:

$Path
"@
    }

    $correctedMarker = 'status == "Closed"'
    if ($normalized.Contains($correctedMarker) -and
        $normalized.Contains('INDEPENDENCE_NOT_EXPLICIT')) {
        Write-Pass "$Label contains an equivalent corrected implementation."
        return $false
    }

    throw "The controlled SIM102 block could not be located in $Label`: $Path"
}

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Repository folder not found: $ProjectRoot"
}

Set-Location -LiteralPath $ProjectRoot

Write-Step "Confirming Git branch"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found."
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

Write-Step "Locating the Python interpreter"
$Python = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Virtual-environment Python was not found: $Python"
}
Write-Pass "Python interpreter found."

Write-Step "Repairing the Section 31 SIM102 block"

$pythonEngine = Join-Path $ProjectRoot "src\ficc_liquidity\governance\validation_findings.py"
Repair-Sim102Block -Path $pythonEngine -Label "Generated Python finding-register engine" | Out-Null

$automationCandidates = @(
    (Join-Path $ProjectRoot "P8S31_Setup_Validation_Finding_Register.ps1"),
    (Join-Path $ProjectRoot "scripts\automation\P8S31_Setup_Validation_Finding_Register.ps1")
)

foreach ($candidate in $automationCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        Repair-Sim102Block -Path $candidate -Label "Section 31 source automation" | Out-Null
    }
}

$env:PYTHONPATH = Join-Path $ProjectRoot "src"

Write-Step "Running Ruff formatting"
& $Python -m ruff format `
    src/ficc_liquidity/governance/validation_findings.py `
    scripts/run_validation_findings.py `
    tests/test_validation_findings.py
Assert-ExitCode "Ruff formatting"
Write-Pass "Ruff formatting completed."

Write-Step "Running Ruff automatic correction"
& $Python -m ruff check --fix `
    src/ficc_liquidity/governance/validation_findings.py `
    scripts/run_validation_findings.py `
    tests/test_validation_findings.py
Assert-ExitCode "Ruff automatic correction"
Write-Pass "Ruff automatic correction completed."

Write-Step "Running final Ruff validation"
& $Python -m ruff check `
    src/ficc_liquidity/governance/validation_findings.py `
    scripts/run_validation_findings.py `
    tests/test_validation_findings.py
Assert-ExitCode "Final Ruff validation"
Write-Pass "Ruff validation passed."

Write-Step "Running focused Mypy validation when available"
& $Python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('mypy') else 1)"
if ($LASTEXITCODE -eq 0) {
    & $Python -m mypy `
        --ignore-missing-imports `
        src/ficc_liquidity/governance/validation_findings.py `
        scripts/run_validation_findings.py
    Assert-ExitCode "Focused Mypy validation"
    Write-Pass "Mypy validation passed."
}
else {
    Write-Warn "Mypy is not installed; this optional gate was skipped."
}

Write-Step "Running focused Section 31 tests"
& $Python -m pytest `
    -q `
    -o addopts= `
    tests/test_validation_findings.py
Assert-ExitCode "Focused Section 31 Pytest"
Write-Pass "Focused Section 31 tests passed."

Write-Step "Running Python compilation"
& $Python -m compileall -q `
    src/ficc_liquidity/governance `
    scripts/run_validation_findings.py `
    tests/test_validation_findings.py
Assert-ExitCode "Python compilation"
Write-Pass "Python compilation passed."

Write-Step "Validating the controlled finding register"
& $Python scripts/run_validation_findings.py `
    --input data/manifests/validation_finding_register.csv `
    --as-of-date 2026-07-25 `
    --validate-only
Assert-ExitCode "Controlled finding-register validation"
Write-Pass "Controlled register validation passed."

Write-Step "Generating deterministic Section 31 evidence"
$demoOutput = Join-Path $ProjectRoot "reports\governance\findings\demo"
New-Item -ItemType Directory -Path $demoOutput -Force | Out-Null

& $Python scripts/run_validation_findings.py `
    --demo `
    --as-of-date 2026-07-25 `
    --output-dir $demoOutput
Assert-ExitCode "Deterministic Section 31 demonstration"
Write-Pass "Deterministic demonstration passed."

Write-Step "Writing completion evidence"
$evidencePath = Join-Path $ProjectRoot "reports\evidence\section31_validation_finding_register.txt"
New-Item -ItemType Directory -Path (Split-Path -Parent $evidencePath) -Force | Out-Null

$evidence = @"
PHASE VIII - SECTION 31: VALIDATION FINDING REGISTER
Generated UTC: $([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
Repository: $ProjectRoot
Branch: $Branch
Demo as-of date: 2026-07-25

REPAIR CONTROL
- Ruff SIM102 nested-if violation: FIXED
- Generated Python engine: VERIFIED
- Source automation: VERIFIED WHEN PRESENT

VALIDATION GATES
- Required-field schema: PASS
- Classification controls: PASS
- Status and overdue controls: PASS
- Closure evidence controls: PASS
- Ruff formatting: PASS
- Ruff validation: PASS
- Focused Pytest: PASS
- Python compilation: PASS
- Controlled register validation: PASS
- Deterministic demonstration: PASS

FINDING CLASSIFICATIONS
- Critical
- High
- Medium
- Low
- Observation

REQUIRED FIELDS
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

FINAL DECISION: PASS
SECTION 31: COMPLETE
"@

Write-Utf8NoBom -Path $evidencePath -Content $evidence
Write-Pass "Completion evidence written."

Write-Step "Staging controlled Section 31 files"
$controlledPaths = @(
    "configs/validation_findings.yaml",
    "data/manifests/validation_finding_register.csv",
    "docs/validation_finding_register.md",
    "src/ficc_liquidity/governance/__init__.py",
    "src/ficc_liquidity/governance/validation_findings.py",
    "scripts/run_validation_findings.py",
    "scripts/automation/P8S31_Setup_Validation_Finding_Register.ps1",
    "tests/test_validation_findings.py",
    "sql/validation_finding_register.sql",
    ".github/ISSUE_TEMPLATE/validation-finding.yml",
    "reports/governance/findings/demo",
    "reports/evidence/section31_validation_finding_register.txt",
    "P8S31_Setup_Validation_Finding_Register.ps1",
    "P8S31_Repair_SIM102_And_Complete.ps1"
)

foreach ($relativePath in $controlledPaths) {
    $nativePath = $relativePath -replace "/", [IO.Path]::DirectorySeparatorChar
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot $nativePath)) {
        & git add -- $relativePath
        Assert-ExitCode "Staging $relativePath"
    }
}

& git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Warn "No staged changes required a new commit."
}
else {
    & git commit -m "Fix Section 31 finding register validation"
    Assert-ExitCode "Section 31 repair commit"
    Write-Pass "Section 31 repair committed."
}

if (-not $SkipPublish) {
    Write-Step "Pushing the Section 31 branch"
    & git push -u origin $Branch
    Assert-ExitCode "Pushing $Branch"
    Write-Pass "Branch pushed."

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        Write-Step "Checking for an existing pull request"
        & gh auth status | Out-Null
        if ($LASTEXITCODE -eq 0) {
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
Completes Phase VIII, Section 31 validation finding register and repairs the
Ruff SIM102 nested-if violation.

Implemented controls:
- Critical, High, Medium, Low, and Observation classifications
- all required finding-register fields
- unique controlled finding IDs
- approved statuses and overdue enforcement
- substantive independent closure evidence
- Critical and High risk-acceptance prohibition
- deterministic demonstration reporting
- focused automated tests
- DuckDB-compatible governance views
- GitHub validation-finding issue form

Validation:
- Ruff: PASS
- focused Pytest: PASS
- Python compilation: PASS
- controlled register validation: PASS
- deterministic demonstration: PASS

All included findings are synthetic project-governance examples.
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
        else {
            Write-Warn @"
GitHub CLI authentication is unavailable. The branch was pushed successfully.
Run 'gh auth login' later, then create the pull request.
"@
        }
    }
    else {
        Write-Warn "GitHub CLI was not found. The branch was pushed without creating a pull request."
    }
}

Write-Step "Section 31 repair completed"
Write-Host "Repository: $ProjectRoot"
Write-Host "Branch:     $Branch"
Write-Host "Evidence:   $evidencePath"
Write-Host ""
Write-Host "SECTION 31 FINAL DECISION: PASS" -ForegroundColor Green
Write-Host "SECTION 31: COMPLETE" -ForegroundColor Green
