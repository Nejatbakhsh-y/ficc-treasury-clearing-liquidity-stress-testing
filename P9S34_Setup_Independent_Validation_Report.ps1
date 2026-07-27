#requires -Version 5.1
<#
.SYNOPSIS
    Phase IX, Section 34 automation for the FICC Treasury Clearing Liquidity
    Stress Testing and Model Validation project.

.DESCRIPTION
    Creates and validates the final independent validation report package.

    The automation:
      1. Verifies the Git repository and working-tree safety.
      2. Creates or checks out branch docs/22-final-validation-report.
      3. Inventories repository evidence and calculates SHA-256 hashes.
      4. Assesses evidence readiness across all Section 34 validation domains.
      5. Generates the complete independent validation report.
      6. Generates evidence indexes, readiness controls, a manifest, and tests.
      7. Updates README.md with controlled links.
      8. Runs focused and full repository quality gates.
      9. Optionally commits, pushes, and opens a draft or ready pull request.

.EXAMPLE
    .\P9S34_Setup_Independent_Validation_Report.ps1

.EXAMPLE
    .\P9S34_Setup_Independent_Validation_Report.ps1 -Publish

.EXAMPLE
    .\P9S34_Setup_Independent_Validation_Report.ps1 -Publish -ReadyForReview
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$BranchName = "docs/22-final-validation-report",
    [string]$BaseBranch = "main",
    [switch]$Publish,
    [switch]$ReadyForReview,
    [switch]$SkipQualityGates,
    [switch]$AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "P9S34_Setup_Independent_Validation_Report.ps1"
$CommitMessage = "Add Section 34 independent validation report"
$PrTitle = "Phase IX Section 34: Independent validation report"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Assert-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$InstallHint = ""
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        $message = "Required command '$Name' was not found."
        if ($InstallHint) {
            $message += " $InstallHint"
        }
        throw $message
    }
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Quiet
    )

    # Native tools such as Git may write informational text to STDERR while
    # returning exit code zero. Windows PowerShell can convert that successful
    # STDERR output into NativeCommandError when ErrorActionPreference is Stop.
    # Success is therefore determined strictly from the native exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable `
        -Name "PSNativeCommandUseErrorActionPreference" `
        -ErrorAction SilentlyContinue

    if ($null -ne $nativePreferenceVariable) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = "Continue"

        if ($null -ne $nativePreferenceVariable) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        $rawOutput = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference

        if ($null -ne $nativePreferenceVariable) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    $output = @(
        $rawOutput | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $_.Exception.Message
            }
            else {
                [string]$_
            }
        }
    )

    if (-not $Quiet -and $output.Count -gt 0) {
        $output | ForEach-Object { Write-Host $_ }
    }

    if ($exitCode -ne 0) {
        $display = "$Command " + ($Arguments -join " ")
        $details = ($output -join [Environment]::NewLine)
        throw "Command failed with exit code $exitCode`: $display`n$details"
    }

    return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Quiet
    )

    return Invoke-CheckedCommand -Command "git" -Arguments $Arguments -Quiet:$Quiet
}

function Test-GitRef {
    param([Parameter(Mandatory = $true)][string]$Ref)

    & git show-ref --verify --quiet $Ref
    return ($LASTEXITCODE -eq 0)
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-RepoRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]"\/")
    $filePath = [System.IO.Path]::GetFullPath($FullPath)

    if (-not $filePath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside repository root: $filePath"
    }

    return $filePath.Substring($rootPath.Length).TrimStart([char[]]"\/").Replace("\", "/")
}

function Escape-MarkdownCell {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return $Value.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
}

function Get-FirstExistingColumn {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string[]]$Candidates
    )

    $names = @($Row.PSObject.Properties.Name)
    foreach ($candidate in $Candidates) {
        foreach ($name in $names) {
            if ($name -ieq $candidate) {
                return $name
            }
        }
    }

    return $null
}

function Get-CategoryDescription {
    param([string]$Category)

    $descriptions = @{
        "Governance and scope" = "Purpose, scope, governance, model-use, and controlled project documentation."
        "Data sources and quality" = "Federal Reserve source contracts, lineage, processing, completeness, and data-quality evidence."
        "Synthetic portfolios" = "Synthetic member schema, allocation methodology, portfolio controls, and default-set construction."
        "Model methodology" = "Stress components, integrated liquidity requirement, resource treatment, and calculation methodology."
        "Scenario framework" = "Historical and hypothetical scenarios, Cover 1, Cover 2, and scenario parameterization."
        "Implementation verification" = "Independent calculations, reconciliation, benchmark, and implementation-verification evidence."
        "Sensitivity analysis" = "Parameter, scenario, concentration, resource, and liquidation-horizon sensitivity evidence."
        "Outcomes analysis" = "Plausibility, rank ordering, monotonicity, stability, tail behavior, and benchmark outcomes."
        "Reverse stress" = "Threshold-search and failure-condition evidence for LCR or liquidity shortfall breaches."
        "Monitoring" = "Monthly monitoring, thresholds, escalation, drift, sign-off, and revalidation controls."
        "Findings" = "Validation finding register, remediation, ownership, status, and closure evidence."
        "Limitations" = "Aggregate-data, synthetic-allocation, parameter, intraday, participant-level, legal, operational, and model-risk limitations."
        "Reproducibility" = "Runtime, configuration provenance, environment, testing, CI, and reproducible evidence package."
        "Other supporting evidence" = "Additional repository-controlled analytical, technical, or governance evidence."
    }

    if ($descriptions.ContainsKey($Category)) {
        return $descriptions[$Category]
    }

    return "Repository-controlled evidence."
}

function Format-EvidenceReferences {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)]$EvidenceRecords
    )

    $matches = @($EvidenceRecords | Where-Object { $_.Category -eq $Category } | Select-Object -First 6)
    if ($matches.Count -eq 0) {
        return "Automated evidence inventory: no qualifying artifact was identified for this domain."
    }

    $parts = @()
    foreach ($item in $matches) {
        $parts += "$($item.EvidenceId) ($($item.Path))"
    }

    return "Automated evidence inventory: " + ($parts -join "; ") + "."
}

function New-ReadinessRow {
    param(
        [string]$Category,
        [string]$ControlObjective,
        [Parameter(Mandatory = $true)]$EvidenceRecords
    )

    $matches = @($EvidenceRecords | Where-Object { $_.Category -eq $Category })
    $representative = ""
    if ($matches.Count -gt 0) {
        $representative = ($matches | Select-Object -First 3 | ForEach-Object { $_.Path }) -join "; "
    }

    [pscustomobject]@{
        Category = $Category
        Status = if ($matches.Count -gt 0) { "PASS" } else { "FAIL" }
        EvidenceCount = $matches.Count
        RepresentativeEvidence = $representative
        ControlObjective = $ControlObjective
    }
}

function Invoke-QualityGate {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)]$Results
    )

    try {
        Write-Info "Running quality gate: $Name"
        & $Action
        $Results.Add([pscustomobject]@{
            Name = $Name
            Status = "PASS"
            Details = "Completed successfully."
        })
        Write-Pass $Name
    }
    catch {
        $Results.Add([pscustomobject]@{
            Name = $Name
            Status = "FAIL"
            Details = $_.Exception.Message
        })
        Write-Warn "$Name failed."
    }
}


function Remove-Section34ReadmeBlock {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $normalized = $Text.Replace("`r`n", "`n")
    $pattern = "(?s)<!-- SECTION34:START -->.*?<!-- SECTION34:END -->"
    return ([regex]::Replace($normalized, $pattern, "")).Trim()
}

function Test-ReadmeOnlySection34Change {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $currentReadmePath = Join-Path $RepositoryRoot "README.md"
    if (-not (Test-Path $currentReadmePath)) {
        return $false
    }

    $headReadmeOutput = & git show "HEAD:README.md" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $headReadme = ($headReadmeOutput -join "`n")
    $currentReadme = Get-Content -Path $currentReadmePath -Raw

    $headWithoutSection34 = Remove-Section34ReadmeBlock -Text $headReadme
    $currentWithoutSection34 = Remove-Section34ReadmeBlock -Text $currentReadme

    return [string]::Equals(
        $headWithoutSection34,
        $currentWithoutSection34,
        [System.StringComparison]::Ordinal
    )
}

Write-Step "Phase IX - Section 34: repository and branch controls"

Assert-Command -Name "git" -InstallHint "Install Git for Windows and restart VS Code."

if (-not (Test-Path $RepoRoot)) {
    throw "Repository path does not exist: $RepoRoot"
}

Set-Location $RepoRoot

if (-not (Test-Path (Join-Path $RepoRoot ".git"))) {
    throw "The selected folder is not a Git repository: $RepoRoot"
}

$section34GeneratedPaths = @(
    "reports/independent_validation_report.md",
    "reports/validation/section34_evidence_index.md",
    "reports/validation/section34_evidence_index.csv",
    "reports/validation/section34_report_readiness.csv",
    "reports/validation/section34_completion_checklist.md",
    "reports/validation/section34_report_manifest.json",
    "tests/test_section34_independent_validation_report.py"
)

$allowedSection34DirtyPaths = @($ScriptName) + $section34GeneratedPaths + @("README.md")
$initialStatus = Invoke-Git -Arguments @("status", "--porcelain=v1", "--untracked-files=all") -Quiet

if ($initialStatus) {
    $readmeIsDirty = $false
    foreach ($statusLine in ($initialStatus -split "`r?`n")) {
        if ($statusLine.Length -ge 4) {
            $candidatePath = $statusLine.Substring(3).Trim().Trim('"')
            if ($candidatePath -match " -> ") {
                $candidatePath = ($candidatePath -split " -> ")[-1].Trim().Trim('"')
            }
            if ($candidatePath.Replace("\", "/") -eq "README.md") {
                $readmeIsDirty = $true
                break
            }
        }
    }

    if ($readmeIsDirty -and -not (Test-ReadmeOnlySection34Change -RepositoryRoot $RepoRoot)) {
        throw @"
README.md contains changes outside the controlled Section 34 marker block.
The automation will not stage README.md because doing so could include unrelated
work. Commit or stash the existing README.md changes, then rerun this file.
"@
    }
}

if ($initialStatus -and -not $AllowDirty) {
    $unrelatedChanges = New-Object System.Collections.Generic.List[string]

    foreach ($statusLine in ($initialStatus -split "`r?`n")) {
        if (-not $statusLine -or $statusLine.Length -lt 4) {
            continue
        }

        $pathPart = $statusLine.Substring(3).Trim().Trim('"')
        if ($pathPart -match " -> ") {
            $pathPart = ($pathPart -split " -> ")[-1].Trim().Trim('"')
        }

        $normalizedPath = $pathPart.Replace("\", "/")
        $isAllowed = $allowedSection34DirtyPaths -contains $normalizedPath

        if ($normalizedPath -eq "README.md" -and $isAllowed) {
            $isAllowed = Test-ReadmeOnlySection34Change -RepositoryRoot $RepoRoot
        }

        if (-not $isAllowed) {
            $unrelatedChanges.Add($statusLine)
        }
    }

    if ($unrelatedChanges.Count -gt 0) {
        $changeList = ($unrelatedChanges | ForEach-Object { "  $_" }) -join [Environment]::NewLine
        throw @"
The working tree contains changes outside the controlled Section 34 file set.
The automation stopped to avoid staging unrelated work.

Unrelated changes:
$changeList

Review the repository with:
    git status

Commit or stash unrelated changes, then rerun this file. Use -AllowDirty only
when the existing changes are intentional and must remain in the working tree.
"@
    }

    Write-Info "Existing Section 34 files were detected and will be regenerated safely."
}


Invoke-Git -Arguments @("fetch", "origin", "--prune") | Out-Null

$currentBranch = Invoke-Git -Arguments @("branch", "--show-current") -Quiet
if ($currentBranch -ne $BranchName) {
    if (Test-GitRef -Ref "refs/heads/$BranchName") {
        Invoke-Git -Arguments @("checkout", $BranchName) | Out-Null
    }
    elseif (Test-GitRef -Ref "refs/remotes/origin/$BranchName") {
        Invoke-Git -Arguments @("checkout", "-b", $BranchName, "--track", "origin/$BranchName") | Out-Null
    }
    else {
        if (Test-GitRef -Ref "refs/heads/$BaseBranch") {
            Invoke-Git -Arguments @("checkout", $BaseBranch) | Out-Null
        }
        elseif (Test-GitRef -Ref "refs/remotes/origin/$BaseBranch") {
            Invoke-Git -Arguments @("checkout", "-b", $BaseBranch, "--track", "origin/$BaseBranch") | Out-Null
        }
        else {
            throw "Base branch '$BaseBranch' was not found locally or on origin."
        }

        Invoke-Git -Arguments @("pull", "--ff-only", "origin", $BaseBranch) | Out-Null
        Invoke-Git -Arguments @("checkout", "-b", $BranchName) | Out-Null
    }
}

$currentBranch = Invoke-Git -Arguments @("branch", "--show-current") -Quiet
if ($currentBranch -ne $BranchName) {
    throw "Branch control failed. Expected '$BranchName' but found '$currentBranch'."
}

$headCommit = Invoke-Git -Arguments @("rev-parse", "HEAD") -Quiet
$shortCommit = Invoke-Git -Arguments @("rev-parse", "--short", "HEAD") -Quiet
$remoteUrl = Invoke-Git -Arguments @("remote", "get-url", "origin") -Quiet

Write-Pass "Active branch: $currentBranch"
Write-Info "Starting commit: $shortCommit"

Write-Step "Inventorying controlled validation evidence"

$reportPath = Join-Path $RepoRoot "reports\independent_validation_report.md"
$validationDir = Join-Path $RepoRoot "reports\validation"
$evidenceMarkdownPath = Join-Path $validationDir "section34_evidence_index.md"
$evidenceCsvPath = Join-Path $validationDir "section34_evidence_index.csv"
$readinessCsvPath = Join-Path $validationDir "section34_report_readiness.csv"
$checklistPath = Join-Path $validationDir "section34_completion_checklist.md"
$manifestPath = Join-Path $validationDir "section34_report_manifest.json"
$testPath = Join-Path $RepoRoot "tests\test_section34_independent_validation_report.py"
$readmePath = Join-Path $RepoRoot "README.md"

New-Item -ItemType Directory -Path (Split-Path -Parent $reportPath) -Force | Out-Null
New-Item -ItemType Directory -Path $validationDir -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $testPath) -Force | Out-Null

$generatedRelativePaths = $section34GeneratedPaths

$excludedDirectoryNames = @(
    ".git",
    ".venv",
    "venv",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "node_modules",
    "site-packages"
)

$allowedExtensions = @(
    ".md", ".csv", ".json", ".yaml", ".yml", ".toml", ".txt", ".log",
    ".py", ".ps1", ".sql", ".ipynb",
    ".parquet", ".duckdb", ".db",
    ".html", ".pdf", ".png", ".svg"
)

$categoryDefinitions = [ordered]@{
    "Findings" = @(
        "finding[_ -]?register",
        "validation[_ -]?findings?",
        "remediation"
    )
    "Reverse stress" = @(
        "reverse[_ -]?stress",
        "failure[_ -]?threshold",
        "breach[_ -]?threshold"
    )
    "Sensitivity analysis" = @(
        "sensitivity",
        "parameter[_ -]?shock"
    )
    "Implementation verification" = @(
        "independent[_ -]?implementation",
        "implementation[_ -]?verification",
        "component[_ -]?reconciliation",
        "independent[_ -]?calculation",
        "deterministic[_ -]?benchmark"
    )
    "Outcomes analysis" = @(
        "outcomes?",
        "benchmark[_ -]?analysis",
        "rank[_ -]?ordering",
        "monotonic",
        "tail[_ -]?behavior",
        "seed[_ -]?stability",
        "historical[_ -]?plausibility"
    )
    "Limitations" = @(
        "uncertainty",
        "limitations?",
        "model[_ -]?risk"
    )
    "Monitoring" = @(
        "monthly[_ -]?monitoring",
        "monitoring[_ -]?threshold",
        "escalation",
        "revalidation",
        "sign[_ -]?off",
        "contribution[_ -]?drift"
    )
    "Synthetic portfolios" = @(
        "synthetic",
        "member[_ -]?schema",
        "member[_ -]?portfolio",
        "default[_ -]?set",
        "portfolio[_ -]?allocation"
    )
    "Scenario framework" = @(
        "scenario",
        "cover[_ -]?1",
        "cover[_ -]?2",
        "historical[_ -]?stress",
        "hypothetical[_ -]?stress",
        "systemic[_ -]?stress"
    )
    "Model methodology" = @(
        "integrated[_ -]?stress",
        "liquidity[_ -]?requirement",
        "settlement[_ -]?fail",
        "rollover",
        "haircut",
        "liquidation",
        "funding[_ -]?cost",
        "concentration[_ -]?adjustment",
        "available[_ -]?resources",
        "liquidity[_ -]?coverage"
    )
    "Data sources and quality" = @(
        "data[_ -]?source",
        "source[_ -]?contract",
        "data[_ -]?catalog",
        "data[_ -]?quality",
        "federal[_ -]?reserve",
        "fr[_ -]?2004",
        "sofr",
        "h[._ -]?15",
        "h[._ -]?4[._ -]?1",
        "processed[_ -]?data",
        "lineage",
        "manifest"
    )
    "Governance and scope" = @(
        "governance",
        "model[_ -]?purpose",
        "intended[_ -]?use",
        "scope",
        "readme",
        "project\.ya?ml",
        "contributing",
        "security",
        "citation"
    )
    "Reproducibility" = @(
        "evidence[_ -]?package",
        "runtime",
        "environment",
        "provenance",
        "pyproject",
        "requirements",
        "workflow",
        "ci\.ya?ml",
        "automation",
        "setup_",
        "p9s34",
        "test_",
        "tests/"
    )
}

function Resolve-EvidenceCategory {
    param([string]$RelativePath)

    $normalized = $RelativePath.ToLowerInvariant()
    foreach ($entry in $categoryDefinitions.GetEnumerator()) {
        foreach ($pattern in $entry.Value) {
            if ($normalized -match $pattern) {
                return $entry.Key
            }
        }
    }

    return "Other supporting evidence"
}

$files = Get-ChildItem -Path $RepoRoot -Recurse -File -Force | Where-Object {
    $relative = Get-RepoRelativePath -FullPath $_.FullName -Root $RepoRoot
    $segments = $relative -split "/"
    $excluded = $false

    foreach ($segment in $segments) {
        if ($excludedDirectoryNames -contains $segment) {
            $excluded = $true
            break
        }
    }

    (-not $excluded) -and
    ($allowedExtensions -contains $_.Extension.ToLowerInvariant()) -and
    ($generatedRelativePaths -notcontains $relative)
}

$evidenceRecords = New-Object System.Collections.Generic.List[object]
$sequence = 1

foreach ($file in ($files | Sort-Object FullName)) {
    $relativePath = Get-RepoRelativePath -FullPath $file.FullName -Root $RepoRoot
    $category = Resolve-EvidenceCategory -RelativePath $relativePath
    $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

    $evidenceRecords.Add([pscustomobject]@{
        EvidenceId = ("EV-{0:D4}" -f $sequence)
        Category = $category
        Path = $relativePath
        Extension = $file.Extension.ToLowerInvariant()
        SizeBytes = $file.Length
        ModifiedUtc = $file.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        Sha256 = $hash
        Description = Get-CategoryDescription -Category $category
        FullPath = $file.FullName
    })

    $sequence += 1
}

if ($evidenceRecords.Count -eq 0) {
    throw "No repository evidence files were identified. Section 34 cannot be generated."
}

$evidenceRecords |
    Select-Object EvidenceId, Category, Path, Extension, SizeBytes, ModifiedUtc, Sha256, Description |
    Export-Csv -Path $evidenceCsvPath -NoTypeInformation -Encoding UTF8

Write-Pass "Evidence files inventoried: $($evidenceRecords.Count)"

Write-Step "Assessing Section 34 report readiness"

$readinessControls = @(
    [pscustomobject]@{
        Category = "Governance and scope"
        Objective = "Document model purpose, intended use, scope, governance, and validation boundaries."
    },
    [pscustomobject]@{
        Category = "Data sources and quality"
        Objective = "Demonstrate controlled official-source contracts, lineage, processing, and data-quality validation."
    },
    [pscustomobject]@{
        Category = "Synthetic portfolios"
        Objective = "Demonstrate controlled synthetic-member methodology without representing actual FICC participants."
    },
    [pscustomobject]@{
        Category = "Model methodology"
        Objective = "Document stress components, aggregation, resources, LCR, and shortfall calculations."
    },
    [pscustomobject]@{
        Category = "Scenario framework"
        Objective = "Document historical and hypothetical scenarios plus Cover 1 and Cover 2 analysis."
    },
    [pscustomobject]@{
        Category = "Implementation verification"
        Objective = "Provide an independent calculation path, reconciliation, and benchmark evidence."
    },
    [pscustomobject]@{
        Category = "Sensitivity analysis"
        Objective = "Demonstrate sensitivity to material market, funding, settlement, concentration, horizon, and resource assumptions."
    },
    [pscustomobject]@{
        Category = "Outcomes analysis"
        Objective = "Demonstrate plausibility, monotonicity, scenario ordering, stability, reconciliation, and economic interpretation."
    },
    [pscustomobject]@{
        Category = "Reverse stress"
        Objective = "Identify conditions that breach liquidity coverage or produce a liquidity shortfall."
    },
    [pscustomobject]@{
        Category = "Monitoring"
        Objective = "Document monthly monitoring, thresholds, escalation, model-change, and revalidation controls."
    },
    [pscustomobject]@{
        Category = "Findings"
        Objective = "Provide a controlled finding register with severity, ownership, remediation, status, and closure evidence."
    },
    [pscustomobject]@{
        Category = "Limitations"
        Objective = "Assess aggregate-data, synthetic-allocation, scenario, parameter, intraday, participant-level, legal, operational, and liquidation-model uncertainty."
    },
    [pscustomobject]@{
        Category = "Reproducibility"
        Objective = "Provide configuration, runtime, testing, CI, provenance, and reproducibility evidence."
    }
)

$readinessRows = New-Object System.Collections.Generic.List[object]
foreach ($control in $readinessControls) {
    $readinessRows.Add(
        (New-ReadinessRow `
            -Category $control.Category `
            -ControlObjective $control.Objective `
            -EvidenceRecords $evidenceRecords)
    )
}

$readinessRows | Export-Csv -Path $readinessCsvPath -NoTypeInformation -Encoding UTF8

$missingCategories = @($readinessRows | Where-Object { $_.Status -eq "FAIL" })
$passedCategories = @($readinessRows | Where-Object { $_.Status -eq "PASS" })

Write-Info "Readiness domains passed: $($passedCategories.Count) / $($readinessRows.Count)"
if ($missingCategories.Count -gt 0) {
    Write-Warn ("Missing evidence domains: " + (($missingCategories | ForEach-Object { $_.Category }) -join ", "))
}

Write-Step "Summarizing validation findings"

$findingSummary = [ordered]@{
    Critical = 0
    High = 0
    Medium = 0
    Low = 0
    Observation = 0
    Unknown = 0
}

$openCritical = 0
$openHigh = 0
$findingRegisterPath = ""
$findingRows = @()

$findingCandidate = $evidenceRecords |
    Where-Object {
        $_.Extension -eq ".csv" -and
        ($_.Path -match "(?i)finding[_ -]?register|validation[_ -]?findings?")
    } |
    Select-Object -First 1

if ($findingCandidate) {
    $findingRegisterPath = $findingCandidate.Path

    try {
        $findingRows = @(Import-Csv -Path $findingCandidate.FullPath)
        if ($findingRows.Count -gt 0) {
            $severityColumn = Get-FirstExistingColumn `
                -Row $findingRows[0] `
                -Candidates @("Classification", "Severity", "Rating", "Priority", "Finding Classification")
            $statusColumn = Get-FirstExistingColumn `
                -Row $findingRows[0] `
                -Candidates @("Status", "Finding Status", "State", "Closure Status")

            foreach ($row in $findingRows) {
                $severity = "Unknown"
                if ($severityColumn) {
                    $rawSeverity = [string]$row.$severityColumn
                    switch -Regex ($rawSeverity.Trim()) {
                        "(?i)^critical$" { $severity = "Critical"; break }
                        "(?i)^high$" { $severity = "High"; break }
                        "(?i)^medium$" { $severity = "Medium"; break }
                        "(?i)^low$" { $severity = "Low"; break }
                        "(?i)^observation$" { $severity = "Observation"; break }
                        default { $severity = "Unknown" }
                    }
                }

                $findingSummary[$severity] += 1

                $isClosed = $false
                if ($statusColumn) {
                    $rawStatus = ([string]$row.$statusColumn).Trim()
                    if ($rawStatus -match "(?i)^(closed|complete|completed|resolved|validated)$") {
                        $isClosed = $true
                    }
                }

                if (-not $isClosed -and $severity -eq "Critical") {
                    $openCritical += 1
                }

                if (-not $isClosed -and $severity -eq "High") {
                    $openHigh += 1
                }
            }
        }
    }
    catch {
        Write-Warn "The finding register was identified but could not be parsed: $($_.Exception.Message)"
    }
}
else {
    Write-Warn "No CSV finding register was identified."
}

if ($missingCategories.Count -gt 0) {
    $validationConclusion = "NOT READY FOR FINAL SIGN-OFF"
    $conclusionRationale = "One or more mandatory validation evidence domains failed the automated readiness gate."
}
elseif ($openCritical -gt 0) {
    $validationConclusion = "UNSATISFACTORY"
    $conclusionRationale = "At least one open Critical validation finding remains."
}
elseif ($openHigh -gt 0) {
    $validationConclusion = "CONDITIONALLY SATISFACTORY WITH HIGH-PRIORITY REMEDIATION"
    $conclusionRationale = "The evidence inventory is complete, but open High findings require controlled remediation."
}
else {
    $validationConclusion = "CONDITIONALLY SATISFACTORY"
    $conclusionRationale = "Required evidence domains are present and no open Critical or High finding was identified by the automated register review."
}

Write-Info "Automated validation conclusion: $validationConclusion"

Write-Step "Generating the independent validation report"

$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$generatedDate = (Get-Date).ToString("MMMM d, yyyy")

$governanceEvidence = Format-EvidenceReferences -Category "Governance and scope" -EvidenceRecords $evidenceRecords
$dataEvidence = Format-EvidenceReferences -Category "Data sources and quality" -EvidenceRecords $evidenceRecords
$syntheticEvidence = Format-EvidenceReferences -Category "Synthetic portfolios" -EvidenceRecords $evidenceRecords
$methodEvidence = Format-EvidenceReferences -Category "Model methodology" -EvidenceRecords $evidenceRecords
$scenarioEvidence = Format-EvidenceReferences -Category "Scenario framework" -EvidenceRecords $evidenceRecords
$implementationEvidence = Format-EvidenceReferences -Category "Implementation verification" -EvidenceRecords $evidenceRecords
$sensitivityEvidence = Format-EvidenceReferences -Category "Sensitivity analysis" -EvidenceRecords $evidenceRecords
$outcomesEvidence = Format-EvidenceReferences -Category "Outcomes analysis" -EvidenceRecords $evidenceRecords
$reverseEvidence = Format-EvidenceReferences -Category "Reverse stress" -EvidenceRecords $evidenceRecords
$monitoringEvidence = Format-EvidenceReferences -Category "Monitoring" -EvidenceRecords $evidenceRecords
$findingsEvidence = Format-EvidenceReferences -Category "Findings" -EvidenceRecords $evidenceRecords
$limitationsEvidence = Format-EvidenceReferences -Category "Limitations" -EvidenceRecords $evidenceRecords
$reproEvidence = Format-EvidenceReferences -Category "Reproducibility" -EvidenceRecords $evidenceRecords

$readinessTableLines = New-Object System.Collections.Generic.List[string]
$readinessTableLines.Add("| Validation domain | Status | Evidence count |")
$readinessTableLines.Add("|---|---:|---:|")
foreach ($row in $readinessRows) {
    $readinessTableLines.Add(
        "| $(Escape-MarkdownCell $row.Category) | $($row.Status) | $($row.EvidenceCount) |"
    )
}
$readinessTable = $readinessTableLines -join [Environment]::NewLine

$findingTableLines = New-Object System.Collections.Generic.List[string]
$findingTableLines.Add("| Classification | Count |")
$findingTableLines.Add("|---|---:|")
foreach ($key in @("Critical", "High", "Medium", "Low", "Observation", "Unknown")) {
    $findingTableLines.Add("| $key | $($findingSummary[$key]) |")
}
$findingTable = $findingTableLines -join [Environment]::NewLine

$missingText = "None."
if ($missingCategories.Count -gt 0) {
    $missingText = ($missingCategories | ForEach-Object { $_.Category }) -join ", "
}

$findingRegisterDisplay = "No controlled finding register was identified."
if ($findingRegisterPath) {
    $findingRegisterDisplay = $findingRegisterPath
}

$reportContent = @"
# FICC Treasury Clearing Liquidity Stress Testing and Model Validation

## Independent Validation Report

| Report field | Value |
|---|---|
| Report ID | IVR-P9-S34 |
| Report date | $generatedDate |
| Generated UTC | $generatedAtUtc |
| Repository branch | $BranchName |
| Starting commit | $headCommit |
| Evidence files inventoried | $($evidenceRecords.Count) |
| Evidence readiness | $($passedCategories.Count) of $($readinessRows.Count) domains passed |
| Validation conclusion | **$validationConclusion** |

## 1. Executive summary

This independent validation assesses the conceptual soundness, data controls,
implementation, outcomes, sensitivity, reverse-stress behavior, limitations,
findings, and governance of the FICC Treasury Clearing Liquidity Stress Testing
and Model Validation project.

The model is a public-data analytical framework. It uses aggregate Federal
Reserve data and synthetic clearing-member portfolios. It does not reproduce
FICC's proprietary liquidity stress-testing model, does not use confidential
participant positions, and must not identify a synthetic member as an actual
FICC participant.

The automated report-readiness result is **$validationConclusion**.
$conclusionRationale The evidence inventory identified $($evidenceRecords.Count)
controlled artifacts. Mandatory evidence domains passed:
$($passedCategories.Count) of $($readinessRows.Count). Missing domains:
$missingText

$readinessTable

## 2. Model purpose and intended use

The model's purpose is to estimate stressed liquidity requirements associated
with Treasury clearing, repo financing, settlement obligations, member default,
market liquidation, collateral haircut, concentration, operational, and
settlement-fail stresses. The framework evaluates resource adequacy through
Cover 1, Cover 2, Liquidity Coverage Ratio, liquidity shortfall, resource
utilization, and component-contribution measures.

Permitted uses include independent model-risk analysis, scenario comparison,
methodology challenge, sensitivity analysis, reverse stress, monitoring, and
governance reporting. Prohibited uses include representing the framework as
FICC's production model, treating synthetic members as real participants, or
using the results as a substitute for proprietary clearing-house, supervisory,
legal, or intraday liquidity information.

$governanceEvidence

## 3. Scope

The validation scope includes:

- Federal Reserve source contracts, ingestion, processing, lineage, and quality.
- Synthetic clearing-member schema, portfolio allocation, concentration, and
  default-set construction.
- Settlement, repo rollover, funding-cost, haircut, Treasury liquidation,
  settlement-fail, concentration, operational-buffer, and available-resource
  calculations.
- Historical, hypothetical, Cover 1, Cover 2, sensitivity, and reverse-stress
  analyses.
- Independent implementation verification, component reconciliation,
  deterministic benchmarks, scenario ordering, stability, and tail behavior.
- Monitoring thresholds, escalation, validation findings, remediation, and
  reproducibility controls.

The validation does not cover proprietary FICC participant data, contractual
liquidity facilities, confidential operational procedures, actual default
management results, or legal enforceability opinions.

$governanceEvidence

## 4. Data sources

The controlled public-data design uses the following official source families:

- FR 2004 Primary Dealer Statistics for Treasury positions, transactions,
  financing activity, and settlement-fail information.
- New York Fed SOFR data for secured overnight funding rates, distributional
  statistics, and transaction volume.
- Federal Reserve H.15 data for Treasury yields by maturity.
- Federal Reserve H.4.1 data for reserve balances and systemwide liquidity
  conditions.

Validation expectations include documented identifiers, definitions, units,
frequency, publication calendar, history, revision policy, intended model use,
known limitations, standardized dates and units, maturity mappings, missing-data
controls, and source lineage.

$dataEvidence

## 5. Synthetic portfolio methodology

Synthetic members must be generated from controlled rules rather than copied
from, named after, or represented as actual FICC participants. The synthetic
schema should cover Treasury positions by maturity, transaction activity, repo
and reverse-repo positions, settlement obligations and fails, collateral
inventory, available qualified liquid resources, concentration, funding
dependency, and liquidity-risk characteristics.

Validation criteria include deterministic random seeds, reproducible allocation,
aggregate reconciliation, bounded values, internally consistent balance and
resource relationships, configurable concentration, and explicit construction
of largest-member, Cover 1, largest-two-member, Cover 2, concentrated, and
correlated default sets.

$syntheticEvidence

## 6. Model methodology

The integrated stressed liquidity requirement is defined as the controlled
aggregation of:

1. Settlement liquidity need.
2. Repo rollover need.
3. Incremental funding cost.
4. Additional haircut requirement.
5. Treasury liquidation loss.
6. Settlement-fail requirement.
7. Concentration adjustment.
8. Operational liquidity buffer.

The aggregation must prevent double counting. Available qualified liquid
resources are compared with the stressed liquidity requirement. The Liquidity
Coverage Ratio is available qualified liquid resources divided by stressed
liquidity requirement. Liquidity shortfall is the positive excess of stressed
requirement over available resources.

Validation requires unit consistency, sign controls, boundary behavior,
component reconciliation, transparent assumptions, deterministic execution,
and traceability from scenario parameters through component outputs to the final
LCR and shortfall.

$methodEvidence

## 7. Scenario framework

The scenario framework should include historical and hypothetical stresses,
moderate, severe, and extreme-but-plausible calibration, parallel Treasury
shocks, curve steepening and flattening, SOFR spikes, repo rollover failure,
haircut increases, settlement-fail increases, concentration shocks, and combined
systemic stress.

For every scenario, the framework should calculate Cover 1 and Cover 2 stressed
requirements, available resources, LCR, shortfall, resource utilization, and the
dominant stress component. Scenario identifiers, parameters, provenance, and
severity ordering must be controlled and reproducible.

$scenarioEvidence

## 8. Conceptual soundness

The conceptual design is sound when the model:

- Links market, funding, collateral, settlement, concentration, and operational
  stresses to liquidity requirements through economically interpretable
  mechanisms.
- Separates stressed requirements from available resources.
- Preserves component additivity without double counting.
- Applies Cover 1 and Cover 2 default-set logic consistently.
- Produces monotonic responses to more severe adverse assumptions, except where
  a documented nonlinear resource or portfolio interaction explains otherwise.
- Uses assumptions proportionate to public aggregate data and synthetic
  portfolios.
- Exposes limitations rather than implying participant-level or intraday
  precision.

Conceptual soundness remains conditional on empirical calibration, independent
implementation results, sensitivity behavior, reverse-stress thresholds, and
closure of material validation findings.

$methodEvidence

## 9. Data validation

Data validation should demonstrate schema conformance, type controls,
standardized dates and units, frequency alignment, maturity mapping, missing
observation treatment, duplicate detection, range and sign checks, revision
awareness, lineage, reproducible processed datasets, and reconciliation to
source-level aggregates where feasible.

Aggregate public data support market-condition and plausibility analysis but do
not identify participant-specific exposures. Synthetic allocation therefore
introduces an additional modeled layer that must be validated separately from
source-data quality.

$dataEvidence

## 10. Implementation verification

Independent implementation verification must use a calculation path that does
not call production calculation functions. It should independently calculate
stress components, default-set selection, aggregate reconciliation, stressed
liquidity requirement, available resources, LCR, and shortfalls.

Required comparisons include exact or tolerance-based reconciliation, component
differences, exception reporting, deterministic benchmark comparisons, boundary
tests, and investigation of unexplained discrepancies. A passing result requires
all material differences to be explained, accepted, or remediated.

$implementationEvidence

## 11. Sensitivity analysis

Sensitivity testing should cover Treasury yield shocks, duration assumptions,
SOFR spikes, rollover-failure percentages, haircut increases, settlement-fail
percentages, member concentration, liquidation horizon, default-set size, and
available-resource assumptions.

The expected outcome is economically coherent directionality, identifiable
nonlinearities, stable rank ordering where appropriate, and clear attribution
of changes to affected stress components. Discontinuities, non-monotonic
responses, or excessive parameter dependence require documented investigation.

$sensitivityEvidence

## 12. Outcomes analysis

Because actual FICC outcomes are unavailable, outcomes validation should rely on
historical plausibility, scenario rank ordering, monotonicity, independent
benchmarks, component reconciliation, stability across seeds, comparison with
simpler deterministic benchmarks, tail behavior, and economic interpretation.

Validation should distinguish evidence of computational correctness from
evidence of real-world predictive accuracy. Aggregate-data plausibility cannot
establish participant-level forecast accuracy, and synthetic-member results
must be interpreted as controlled analytical experiments.

$outcomesEvidence

## 13. Reverse stress

Reverse-stress analysis should identify combinations of market, funding,
haircut, settlement-fail, concentration, liquidation-horizon, default-set, and
resource assumptions that cause LCR to fall below the controlled threshold or
produce a positive liquidity shortfall.

Results should identify the first breach, dominant component, parameter
combination, available-resource dependency, and distance from baseline. Reverse
stress should support risk appetite, monitoring thresholds, escalation, and
scenario design rather than claim a probability for the breach unless a
separate probability model is validated.

$reverseEvidence

## 14. Limitations

The principal limitations are:

1. Aggregate-data uncertainty: public series may not align exactly with cleared
   portfolios, obligations, settlement timing, or eligible resources.
2. Synthetic allocation uncertainty: participant exposures and dependencies are
   modeled rather than observed.
3. Scenario-selection uncertainty: historical and hypothetical scenarios may
   omit relevant combinations or structural breaks.
4. Parameter uncertainty: duration, funding, haircut, fail, liquidation, and
   concentration assumptions are estimated or judgmental.
5. Missing intraday information: daily or weekly aggregates cannot represent
   peak intraday payment and settlement needs.
6. Participant-level data limitations: the framework cannot validate member
   heterogeneity against confidential FICC records.
7. Operational and legal assumptions: resource availability, timing,
   enforceability, and operational execution are simplified.
8. Simplified liquidation functions: market depth, price impact, wrong-way
   effects, execution delays, and feedback loops may be understated.
9. Model-form uncertainty: additive components and deterministic rules may not
   capture nonlinear dependencies.
10. Outcome limitations: public data and synthetic portfolios cannot establish
    actual FICC performance or default-management outcomes.

These limitations require conservative interpretation, explicit disclosure,
sensitivity analysis, reverse stress, monitoring, and periodic revalidation.

$limitationsEvidence

## 15. Findings

Controlled finding register: $findingRegisterDisplay

$findingTable

Open Critical findings identified by the automated register review:
$openCritical

Open High findings identified by the automated register review:
$openHigh

Finding severity alone is not sufficient for closure. Each finding should
include condition, evidence, risk, recommendation, management response, owner,
target date, status, and closure evidence. Critical and High findings require
formal remediation or documented risk acceptance before unconditional reliance.

$findingsEvidence

## 16. Validation conclusion

**Conclusion: $validationConclusion**

$conclusionRationale

The conclusion is inherently conditional because the model is based on public
aggregate data and synthetic portfolios. Even when all automated evidence gates
pass, the framework should be used as an independent analytical and validation
tool rather than represented as FICC's proprietary production liquidity model.

Final approval requires review of the underlying evidence, confirmation that
quantitative results are current, closure or formal acceptance of material
findings, and approval by the designated model owner and independent validator.

$reproEvidence

## 17. Recommendations

1. Close all Critical and High findings before unconditional sign-off.
2. Preserve strict independence between production and verification calculation
   paths.
3. Retain deterministic seeds, configuration snapshots, source lineage, runtime
   evidence, and SHA-256 hashes for every released evidence package.
4. Expand participant-level and intraday validation when authorized data become
   available.
5. Challenge liquidation, market-depth, funding, haircut, settlement, legal,
   and operational assumptions through sensitivity and reverse stress.
6. Reconcile all scenario outputs to component calculations and simpler
   deterministic benchmarks.
7. Calibrate monitoring thresholds to observed drift, historical ranges,
   scenario-order stability, LCR distributions, and contribution changes.
8. Require monthly monitoring sign-off and annual independent revalidation, with
   earlier revalidation after material model, data, or market-structure change.
9. Freeze the final report version and evidence manifest at approval.
10. Maintain explicit disclosure that synthetic members are not actual FICC
    participants.

$monitoringEvidence

## 18. Appendices and evidence index

The controlled Section 34 package consists of:

- Final report: reports/independent_validation_report.md
- Markdown evidence index:
  reports/validation/section34_evidence_index.md
- Machine-readable evidence index:
  reports/validation/section34_evidence_index.csv
- Readiness assessment:
  reports/validation/section34_report_readiness.csv
- Completion checklist:
  reports/validation/section34_completion_checklist.md
- Report manifest:
  reports/validation/section34_report_manifest.json
- Automated report test:
  tests/test_section34_independent_validation_report.py

Evidence records use repository-relative paths and SHA-256 hashes. The evidence
index is the authoritative map from validation domains to controlled artifacts.

$reproEvidence
"@

Write-Utf8NoBom -Path $reportPath -Content ($reportContent.Trim() + [Environment]::NewLine)

$evidenceMarkdownLines = New-Object System.Collections.Generic.List[string]
$evidenceMarkdownLines.Add("# Section 34 Independent Validation Evidence Index")
$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add("Generated UTC: $generatedAtUtc")
$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add("Repository branch: $BranchName")
$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add("Starting commit: $headCommit")
$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add("Evidence count: $($evidenceRecords.Count)")
$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add("| Evidence ID | Category | Repository path | Size (bytes) | Modified UTC | SHA-256 |")
$evidenceMarkdownLines.Add("|---|---|---|---:|---|---|")

foreach ($item in $evidenceRecords) {
    $evidenceMarkdownLines.Add(
        "| $($item.EvidenceId) | $(Escape-MarkdownCell $item.Category) | $(Escape-MarkdownCell $item.Path) | $($item.SizeBytes) | $($item.ModifiedUtc) | $($item.Sha256) |"
    )
}

$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add("## Readiness summary")
$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add($readinessTable)
$evidenceMarkdownLines.Add("")
$evidenceMarkdownLines.Add("The index records repository-relative paths and SHA-256 hashes. Generated")
$evidenceMarkdownLines.Add("Section 34 outputs are excluded from the source evidence inventory to prevent")
$evidenceMarkdownLines.Add("self-referential evidence.")

Write-Utf8NoBom `
    -Path $evidenceMarkdownPath `
    -Content (($evidenceMarkdownLines -join [Environment]::NewLine) + [Environment]::NewLine)

$requiredSections = @(
    "Executive summary",
    "Model purpose and intended use",
    "Scope",
    "Data sources",
    "Synthetic portfolio methodology",
    "Model methodology",
    "Scenario framework",
    "Conceptual soundness",
    "Data validation",
    "Implementation verification",
    "Sensitivity analysis",
    "Outcomes analysis",
    "Reverse stress",
    "Limitations",
    "Findings",
    "Validation conclusion",
    "Recommendations",
    "Appendices and evidence index"
)

$checklistLines = New-Object System.Collections.Generic.List[string]
$checklistLines.Add("# Phase IX - Section 34 Completion Checklist")
$checklistLines.Add("")
$checklistLines.Add("| Required report section | Status |")
$checklistLines.Add("|---|---|")
foreach ($section in $requiredSections) {
    $checklistLines.Add("| $(Escape-MarkdownCell $section) | PASS |")
}
$checklistLines.Add("")
$checklistLines.Add("## Evidence readiness")
$checklistLines.Add("")
$checklistLines.Add($readinessTable)
$checklistLines.Add("")
$checklistLines.Add("## Automated conclusion")
$checklistLines.Add("")
$checklistLines.Add("**$validationConclusion**")
$checklistLines.Add("")
$checklistLines.Add($conclusionRationale)

Write-Utf8NoBom `
    -Path $checklistPath `
    -Content (($checklistLines -join [Environment]::NewLine) + [Environment]::NewLine)

$testContent = @'
from __future__ import annotations

import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports" / "independent_validation_report.md"
EVIDENCE_CSV = ROOT / "reports" / "validation" / "section34_evidence_index.csv"
EVIDENCE_MD = ROOT / "reports" / "validation" / "section34_evidence_index.md"
READINESS_CSV = ROOT / "reports" / "validation" / "section34_report_readiness.csv"
CHECKLIST = ROOT / "reports" / "validation" / "section34_completion_checklist.md"
MANIFEST = ROOT / "reports" / "validation" / "section34_report_manifest.json"

REQUIRED_HEADINGS = [
    "## 1. Executive summary",
    "## 2. Model purpose and intended use",
    "## 3. Scope",
    "## 4. Data sources",
    "## 5. Synthetic portfolio methodology",
    "## 6. Model methodology",
    "## 7. Scenario framework",
    "## 8. Conceptual soundness",
    "## 9. Data validation",
    "## 10. Implementation verification",
    "## 11. Sensitivity analysis",
    "## 12. Outcomes analysis",
    "## 13. Reverse stress",
    "## 14. Limitations",
    "## 15. Findings",
    "## 16. Validation conclusion",
    "## 17. Recommendations",
    "## 18. Appendices and evidence index",
]


def test_section34_required_files_exist() -> None:
    for path in [
        REPORT,
        EVIDENCE_CSV,
        EVIDENCE_MD,
        READINESS_CSV,
        CHECKLIST,
        MANIFEST,
    ]:
        assert path.is_file(), f"Missing Section 34 artifact: {path}"


def test_independent_validation_report_has_all_required_sections() -> None:
    text = REPORT.read_text(encoding="utf-8")
    missing = [heading for heading in REQUIRED_HEADINGS if heading not in text]
    assert not missing, f"Missing required report headings: {missing}"
    assert not re.search(r"\b(?:TODO|TBD|FILL[_ -]?ME)\b", text, re.IGNORECASE)


def test_evidence_index_is_controlled_and_hashed() -> None:
    with EVIDENCE_CSV.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    assert rows, "Evidence index must contain at least one evidence record."
    required_columns = {
        "EvidenceId",
        "Category",
        "Path",
        "Extension",
        "SizeBytes",
        "ModifiedUtc",
        "Sha256",
        "Description",
    }
    assert required_columns.issubset(rows[0])
    assert len({row["EvidenceId"] for row in rows}) == len(rows)
    assert all(re.fullmatch(r"EV-\d{4}", row["EvidenceId"]) for row in rows)
    assert all(re.fullmatch(r"[0-9a-f]{64}", row["Sha256"]) for row in rows)
    assert all(not Path(row["Path"]).is_absolute() for row in rows)


def test_readiness_control_is_complete() -> None:
    with READINESS_CSV.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    assert len(rows) == 13
    assert {row["Status"] for row in rows}.issubset({"PASS", "FAIL"})
    assert all(row["ControlObjective"].strip() for row in rows)


def test_report_manifest_is_valid() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert manifest["section"] == 34
    assert manifest["phase"] == 9
    assert manifest["branch"] == "docs/22-final-validation-report"
    assert manifest["evidence_count"] > 0
    assert manifest["validation_conclusion"]
    assert manifest["outputs"]
'@

Write-Utf8NoBom -Path $testPath -Content ($testContent.Trim() + [Environment]::NewLine)

Write-Step "Updating README.md"

$readmeBlock = @"
<!-- SECTION34:START -->
## Phase IX - Section 34: Independent Validation Report

The controlled final validation package is available at:

- [Independent validation report](reports/independent_validation_report.md)
- [Evidence index](reports/validation/section34_evidence_index.md)
- [Report readiness](reports/validation/section34_report_readiness.csv)
- [Completion checklist](reports/validation/section34_completion_checklist.md)
- [Report manifest](reports/validation/section34_report_manifest.json)

Automated conclusion: **$validationConclusion**
<!-- SECTION34:END -->
"@

if (Test-Path $readmePath) {
    $readme = Get-Content -Path $readmePath -Raw
}
else {
    $readme = "# FICC Treasury Clearing Liquidity Stress Testing and Model Validation`r`n"
}

$markerPattern = "(?s)<!-- SECTION34:START -->.*?<!-- SECTION34:END -->"
if ($readme -match $markerPattern) {
    $readme = [regex]::Replace($readme, $markerPattern, $readmeBlock.Trim())
}
else {
    $readme = $readme.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $readmeBlock.Trim()
}

Write-Utf8NoBom -Path $readmePath -Content ($readme.TrimEnd() + [Environment]::NewLine)

Write-Step "Creating the report manifest"

$outputPaths = @(
    $reportPath,
    $evidenceMarkdownPath,
    $evidenceCsvPath,
    $readinessCsvPath,
    $checklistPath,
    $testPath,
    $readmePath
)

$scriptRepoPath = Join-Path $RepoRoot $ScriptName
if (Test-Path $scriptRepoPath) {
    $outputPaths += $scriptRepoPath
}

$outputRecords = New-Object System.Collections.Generic.List[object]
foreach ($path in $outputPaths) {
    if (Test-Path $path) {
        $outputRecords.Add([pscustomobject]@{
            Path = Get-RepoRelativePath -FullPath $path -Root $RepoRoot
            Sha256 = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
            SizeBytes = (Get-Item $path).Length
        })
    }
}

$qualityGateResults = New-Object System.Collections.Generic.List[object]

$manifestObject = [ordered]@{
    project = "FICC Treasury Clearing Liquidity Stress Testing and Model Validation"
    phase = 9
    section = 34
    report_id = "IVR-P9-S34"
    generated_utc = $generatedAtUtc
    repository_root = $RepoRoot
    remote = $remoteUrl
    branch = $BranchName
    base_branch = $BaseBranch
    starting_commit = $headCommit
    evidence_count = $evidenceRecords.Count
    readiness_domains_passed = $passedCategories.Count
    readiness_domains_total = $readinessRows.Count
    missing_domains = @($missingCategories | ForEach-Object { $_.Category })
    finding_register = $findingRegisterPath
    open_critical_findings = $openCritical
    open_high_findings = $openHigh
    validation_conclusion = $validationConclusion
    outputs = [object[]]$outputRecords.ToArray()
    quality_gates = @()
}

Write-Utf8NoBom `
    -Path $manifestPath `
    -Content (($manifestObject | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

if (-not $SkipQualityGates) {
    Write-Step "Running Section 34 and repository quality gates"

    $pythonCommand = "python"
    $venvPython = Join-Path $RepoRoot ".venv\Scripts\python.exe"
    if (Test-Path $venvPython) {
        $pythonCommand = $venvPython
    }
    else {
        Assert-Command -Name "python" -InstallHint "Activate or create the Python 3.11 project environment."
    }

    Invoke-QualityGate `
        -Name "Section 34 focused pytest" `
        -Results $qualityGateResults `
        -Action {
            Invoke-CheckedCommand `
                -Command $pythonCommand `
                -Arguments @(
                    "-m",
                    "pytest",
                    "tests/test_section34_independent_validation_report.py",
                    "-q",
                    "-o",
                    "addopts="
                ) |
                Out-Null
        }

    Invoke-QualityGate `
        -Name "Full pytest suite" `
        -Results $qualityGateResults `
        -Action {
            Invoke-CheckedCommand `
                -Command $pythonCommand `
                -Arguments @("-m", "pytest", "-q") |
                Out-Null
        }

    Invoke-QualityGate `
        -Name "Ruff validation" `
        -Results $qualityGateResults `
        -Action {
            Invoke-CheckedCommand `
                -Command $pythonCommand `
                -Arguments @("-m", "ruff", "check", ".") |
                Out-Null
        }

    $mypyTarget = Join-Path $RepoRoot "src\ficc_liquidity"
    if (Test-Path $mypyTarget) {
        Invoke-QualityGate `
            -Name "Mypy validation" `
            -Results $qualityGateResults `
            -Action {
                Invoke-CheckedCommand `
                    -Command $pythonCommand `
                    -Arguments @("-m", "mypy", "src/ficc_liquidity") |
                    Out-Null
            }
    }
    else {
        $qualityGateResults.Add([pscustomobject]@{
            Name = "Mypy validation"
            Status = "SKIP"
            Details = "src/ficc_liquidity was not found."
        })
        Write-Warn "Mypy validation skipped because src/ficc_liquidity was not found."
    }
}
else {
    $qualityGateResults.Add([pscustomobject]@{
        Name = "Quality gates"
        Status = "SKIP"
        Details = "Skipped by -SkipQualityGates."
    })
    Write-Warn "Quality gates were skipped by request."
}

$manifestObject["quality_gates"] = [object[]]$qualityGateResults.ToArray()
Write-Utf8NoBom `
    -Path $manifestPath `
    -Content (($manifestObject | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

$failedGates = @($qualityGateResults.ToArray() | Where-Object { $_.Status -eq "FAIL" })
if ($failedGates.Count -gt 0) {
    Write-Host ""
    Write-Warn "One or more quality gates failed. The report package was generated, but publishing is blocked."
    foreach ($failed in $failedGates) {
        Write-Host "  - $($failed.Name): $($failed.Details)" -ForegroundColor Yellow
    }
    throw "Section 34 quality gates failed. Correct the failures and rerun the automation."
}

Write-Pass "All required Section 34 quality gates completed."

Write-Step "Staging controlled Section 34 files"

$pathsToStage = @(
    "reports/independent_validation_report.md",
    "reports/validation/section34_evidence_index.md",
    "reports/validation/section34_evidence_index.csv",
    "reports/validation/section34_report_readiness.csv",
    "reports/validation/section34_completion_checklist.md",
    "reports/validation/section34_report_manifest.json",
    "tests/test_section34_independent_validation_report.py",
    "README.md"
)

if (Test-Path (Join-Path $RepoRoot $ScriptName)) {
    $pathsToStage += $ScriptName
}

Invoke-Git -Arguments (@("add", "--") + $pathsToStage) | Out-Null

$stagedNames = Invoke-Git -Arguments @("diff", "--cached", "--name-only") -Quiet
if (-not $stagedNames) {
    Write-Warn "No Section 34 changes were detected. Nothing was committed."
}
else {
    Write-Info "Staged files:"
    $stagedNames -split "`r?`n" | ForEach-Object { Write-Host "  - $_" }

    if ($Publish) {
        Write-Step "Committing and publishing Section 34"

        Assert-Command -Name "gh" -InstallHint "Install GitHub CLI, then run: gh auth login"
        Invoke-CheckedCommand -Command "gh" -Arguments @("auth", "status") | Out-Null

        Invoke-Git -Arguments @("commit", "-m", $CommitMessage) | Out-Null
        Invoke-Git -Arguments @("push", "-u", "origin", $BranchName) | Out-Null

        $prBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "p9s34_pr_body.md"
        $gateSummary = @($qualityGateResults.ToArray() | ForEach-Object {
            "- $($_.Name): $($_.Status)"
        }) -join [Environment]::NewLine

        $prBody = @"
## Summary

Completes Phase IX, Section 34 by generating the controlled independent
validation report and its reproducible evidence package.

## Deliverables

- Final independent validation report with all required sections.
- SHA-256 evidence index.
- Evidence-readiness assessment across 13 validation domains.
- Findings summary and automated validation conclusion.
- Completion checklist and machine-readable report manifest.
- Automated pytest controls for report completeness and evidence integrity.
- Reusable single-file PowerShell automation.
- README links to the final validation package.

## Validation

$gateSummary

## Model-risk boundary

The report explicitly states that the framework uses public aggregate Federal
Reserve data and synthetic clearing-member portfolios. Synthetic members are
not actual FICC participants, and the framework is not represented as FICC's
proprietary production liquidity model.
"@

        Write-Utf8NoBom -Path $prBodyPath -Content ($prBody.Trim() + [Environment]::NewLine)

        $existingPrUrl = Invoke-CheckedCommand `
            -Command "gh" `
            -Arguments @(
                "pr", "list",
                "--head", $BranchName,
                "--base", $BaseBranch,
                "--state", "open",
                "--json", "url",
                "--jq", ".[0].url"
            ) `
            -Quiet

        if ($existingPrUrl) {
            Write-Warn "An open pull request already exists: $existingPrUrl"
        }
        else {
            $prArguments = @(
                "pr", "create",
                "--base", $BaseBranch,
                "--head", $BranchName,
                "--title", $PrTitle,
                "--body-file", $prBodyPath
            )

            if (-not $ReadyForReview) {
                $prArguments += "--draft"
            }

            $createdPrUrl = Invoke-CheckedCommand `
                -Command "gh" `
                -Arguments $prArguments `
                -Quiet

            Write-Pass "Pull request created: $createdPrUrl"
        }
    }
    else {
        Write-Host ""
        Write-Info "Files are staged but not committed or pushed."
        Write-Info "Review them with:"
        Write-Host "    git diff --cached" -ForegroundColor White
        Write-Info "Then publish with:"
        Write-Host "    .\$ScriptName -Publish" -ForegroundColor White
    }
}

Write-Step "Section 34 automation completed"

Write-Host "Branch:              $BranchName"
Write-Host "Validation status:   $validationConclusion"
Write-Host "Evidence files:      $($evidenceRecords.Count)"
Write-Host "Readiness passed:    $($passedCategories.Count) / $($readinessRows.Count)"
Write-Host "Final report:        reports\independent_validation_report.md"
Write-Host "Evidence index:      reports\validation\section34_evidence_index.md"
Write-Host "Readiness control:   reports\validation\section34_report_readiness.csv"
Write-Host "Manifest:            reports\validation\section34_report_manifest.json"

if (-not $Publish) {
    Write-Host ""
    Write-Host "The report package is generated and staged. It has not been committed or pushed." -ForegroundColor Yellow
}
