#requires -Version 5.1
<#
.SYNOPSIS
    Phase X, Section 35: final repository controls and evidence automation.

.DESCRIPTION
    Audits and, when requested, configures final GitHub repository controls for
    the FICC Treasury Clearing Liquidity Stress Testing and Model Validation
    project. The automation creates preventive CI controls, performs local and
    GitHub-backed verification, runs a clean-clone reproduction test, generates
    machine-readable evidence, and can publish the work through a feature branch
    and documented pull request.

.EXAMPLE
    .\P10S35_Final_Repository_Controls.ps1 -Publish -ConfigureGitHubControls
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$BranchName = "feature/22-final-repository-controls",
    [string]$BaseBranch = "main",
    [switch]$Publish,
    [switch]$ConfigureGitHubControls,
    [switch]$SkipFreshClone,
    [switch]$SkipGitHub,
    [switch]$AuditOnly,
    [switch]$CiMode,
    [switch]$KeepClone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "P10S35_Final_Repository_Controls.ps1"
$SectionTitle = "Phase X Section 35 - Final Repository Controls"
$DefaultWindowsRepo = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing"
$TimestampUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$DateStamp = [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss")
$script:Results = New-Object System.Collections.Generic.List[object]
$script:EvidenceLines = New-Object System.Collections.Generic.List[string]
$script:RepoSlug = ""
$script:RepoUrl = ""
$script:FreshClonePath = ""

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ""
    Write-Host ("=" * 86) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 86) -ForegroundColor DarkCyan
}

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Gray
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host "[PASS] $Text" -ForegroundColor Green
}

function Write-WarnMessage {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-FailMessage {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host "[FAIL] $Text" -ForegroundColor Red
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Control,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "WARN", "FAIL", "INFO")][string]$Status,
        [Parameter(Mandatory = $true)][string]$Evidence,
        [Parameter(Mandatory = $true)][string]$Remediation
    )

    $script:Results.Add([pscustomobject]@{
        Control     = $Control
        Status      = $Status
        Evidence    = $Evidence
        Remediation = $Remediation
        TimestampUtc = $TimestampUtc
    }) | Out-Null

    switch ($Status) {
        "PASS" { Write-Pass "$Control - $Evidence" }
        "WARN" { Write-WarnMessage "$Control - $Evidence" }
        "FAIL" { Write-FailMessage "$Control - $Evidence" }
        default { Write-Info "$Control - $Evidence" }
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Info ("Running: {0} {1}" -f $FilePath, ($Arguments -join " "))
    }

    # Native tools such as Git legitimately write informational messages to
    # stderr even when they return exit code 0. Temporarily prevent the script's
    # Stop preference from converting that stderr stream into a terminating
    # PowerShell error; command success is determined strictly by LASTEXITCODE.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $FilePath @Arguments 2>&1 |
            ForEach-Object { $_.ToString() } |
            Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $trimmed = $output.Trim()

    if (($exitCode -ne 0) -and -not $AllowFailure) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')`n$trimmed"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $trimmed
    }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-RepositoryRoot {
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }

    if (Test-Path -LiteralPath (Join-Path $DefaultWindowsRepo ".git")) {
        return (Resolve-Path -LiteralPath $DefaultWindowsRepo).Path
    }

    if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot ".git"))) {
        return (Resolve-Path -LiteralPath $PSScriptRoot).Path
    }

    $current = (Get-Location).Path
    if (Test-Path -LiteralPath (Join-Path $current ".git")) {
        return $current
    }

    throw "Repository not found. Run this file from the repository root or provide -RepoRoot."
}

function Get-PythonLauncher {
    if (Test-CommandAvailable "py") {
        $probe = Invoke-Native -FilePath "py" -Arguments @("-3.11", "-c", "import sys; print(sys.version_info[:2])") -AllowFailure -Quiet
        if ($probe.ExitCode -eq 0) {
            return [pscustomobject]@{ FilePath = "py"; Prefix = @("-3.11") }
        }
    }

    if (Test-CommandAvailable "python") {
        $probe = Invoke-Native -FilePath "python" -Arguments @("-c", "import sys; assert sys.version_info[:2] == (3, 11); print(sys.version)") -AllowFailure -Quiet
        if ($probe.ExitCode -eq 0) {
            return [pscustomobject]@{ FilePath = "python"; Prefix = @() }
        }
    }

    throw "Python 3.11 was not found. Install Python 3.11 and ensure 'py -3.11' or 'python' is available."
}

function Invoke-PythonLauncher {
    param(
        [Parameter(Mandatory = $true)]$Launcher,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Quiet
    )
    $allArguments = @($Launcher.Prefix) + $Arguments
    return Invoke-Native -FilePath $Launcher.FilePath -Arguments $allArguments -AllowFailure:$AllowFailure -Quiet:$Quiet
}

function Ensure-AutomationFileInRepository {
    if ($AuditOnly -or $CiMode) {
        return
    }

    $destination = Join-Path $script:RepositoryRoot $ScriptName
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        if (-not (Test-Path -LiteralPath $destination)) {
            throw "The automation file could not be located for controlled repository publication."
        }
        return
    }

    $source = (Resolve-Path -LiteralPath $PSCommandPath).Path
    $destinationFull = [System.IO.Path]::GetFullPath($destination)
    if (-not [string]::Equals($source, $destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Write-Info "Copied the automation into the repository root: $destination"
    }
}

function Ensure-FeatureBranch {
    if ($AuditOnly -or $CiMode) {
        return
    }

    Write-Section "Prepare controlled feature branch"
    $currentBranch = (Invoke-Native -FilePath "git" -Arguments @("branch", "--show-current") -Quiet).Output
    $trackedChanges = (Invoke-Native -FilePath "git" -Arguments @("status", "--porcelain", "--untracked-files=no") -Quiet).Output

    if (-not [string]::IsNullOrWhiteSpace($trackedChanges)) {
        if ($currentBranch -ne $BranchName) {
            throw "Tracked working-tree changes already exist outside '$BranchName'. Commit, stash, or discard them before running Section 35."
        }
        Write-Info "Resuming an interrupted Section 35 run on $BranchName; existing controlled working-tree changes will be validated and regenerated."
    }

    Invoke-Native -FilePath "git" -Arguments @("fetch", "origin", "--prune") | Out-Null
    $branchExists = (Invoke-Native -FilePath "git" -Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$BranchName") -AllowFailure -Quiet).ExitCode -eq 0

    if ($currentBranch -ne $BaseBranch -and $currentBranch -ne $BranchName) {
        $remoteRef = "origin/$currentBranch"
        $remoteExists = (Invoke-Native -FilePath "git" -Arguments @("show-ref", "--verify", "--quiet", "refs/remotes/$remoteRef") -AllowFailure -Quiet).ExitCode -eq 0
        $candidateRef = $currentBranch
        if ($remoteExists) {
            $candidateRef = $remoteRef
        }
        $merged = (Invoke-Native -FilePath "git" -Arguments @("merge-base", "--is-ancestor", $candidateRef, "origin/$BaseBranch") -AllowFailure -Quiet).ExitCode -eq 0
        if (-not $merged) {
            throw "The current branch '$currentBranch' is not merged into origin/$BaseBranch. Merge the preceding section pull request before starting final repository controls."
        }
    }

    if ($currentBranch -eq $BranchName) {
        Write-Info "Already on $BranchName."
        return
    }

    if ($branchExists) {
        Invoke-Native -FilePath "git" -Arguments @("checkout", $BranchName) | Out-Null
        return
    }

    Invoke-Native -FilePath "git" -Arguments @("checkout", $BaseBranch) | Out-Null
    Invoke-Native -FilePath "git" -Arguments @("pull", "--ff-only", "origin", $BaseBranch) | Out-Null
    Invoke-Native -FilePath "git" -Arguments @("checkout", "-b", $BranchName) | Out-Null
}

function Ensure-GitIgnoreControls {
    if ($AuditOnly -or $CiMode) {
        return
    }

    $gitIgnorePath = Join-Path $script:RepositoryRoot ".gitignore"
    $existing = ""
    if (Test-Path -LiteralPath $gitIgnorePath) {
        $existing = Get-Content -LiteralPath $gitIgnorePath -Raw
    }

    $startMarker = "# BEGIN SECTION 35 CONTROLLED OUTPUTS"
    $endMarker = "# END SECTION 35 CONTROLLED OUTPUTS"
    $block = @"
$startMarker
# Python and test runtime
.venv/
venv/
__pycache__/
*.py[cod]
.pytest_cache/
.mypy_cache/
.ruff_cache/
.coverage
coverage.xml
htmlcov/

# Local secrets and credentials
.env
.env.*
!.env.example
*.pem
*.key
credentials.json
secrets.json

# Data and analytical runtime outputs
data/raw/
data/interim/
data/processed/
data/external/
*.parquet
*.duckdb
*.db
*.sqlite
*.sqlite3
*.feather
*.pickle
*.pkl

# Generated evidence and application outputs
artifacts/
outputs/
logs/
.streamlit/secrets.toml
reports/generated/
reports/runtime/
reports/dashboard_exports/
$endMarker
"@

    if ($existing -match [regex]::Escape($startMarker)) {
        $pattern = "(?s)" + [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
        $updated = [regex]::Replace($existing, $pattern, $block.Trim())
    }
    else {
        $separator = ""
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            $separator = "`r`n`r`n"
        }
        $updated = $existing.TrimEnd() + $separator + $block.Trim() + "`r`n"
    }

    Write-Utf8NoBom -Path $gitIgnorePath -Content $updated
}

function Ensure-ReadmeInstallationSection {
    if ($AuditOnly -or $CiMode) {
        return
    }

    $readmePath = Join-Path $script:RepositoryRoot "README.md"
    if (-not (Test-Path -LiteralPath $readmePath)) {
        throw "README.md is missing."
    }

    $content = Get-Content -LiteralPath $readmePath -Raw
    $startMarker = "<!-- BEGIN SECTION 35 INSTALLATION -->"
    $endMarker = "<!-- END SECTION 35 INSTALLATION -->"
    $section = @'
<!-- BEGIN SECTION 35 INSTALLATION -->
## Installation and fresh-clone reproduction

The controlled development environment uses Python 3.11. From Windows PowerShell in a fresh clone:

```powershell
git clone https://github.com/nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing.git
Set-Location ficc-treasury-clearing-liquidity-stress-testing
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m mypy src tests
```

Repository data controls prohibit raw, confidential, participant-level, and runtime-generated datasets from being committed. The public analytical package uses official public data, documented transformations, and synthetic clearing-member representations only.
<!-- END SECTION 35 INSTALLATION -->
'@

    if ($content -match [regex]::Escape($startMarker)) {
        $pattern = "(?s)" + [regex]::Escape($startMarker) + ".*?" + [regex]::Escape($endMarker)
        $updated = [regex]::Replace($content, $pattern, $section.Trim())
    }
    else {
        $updated = $content.TrimEnd() + "`r`n`r`n" + $section.Trim() + "`r`n"
    }

    Write-Utf8NoBom -Path $readmePath -Content $updated
}

function Ensure-FinalControlsWorkflow {
    if ($AuditOnly -or $CiMode) {
        return
    }

    $workflowPath = Join-Path $script:RepositoryRoot ".github\workflows\final-repository-controls.yml"
    $workflow = @'
name: Final Repository Controls

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  security-events: write

jobs:
  quality-security:
    name: section35-quality-security
    runs-on: ubuntu-latest
    steps:
      - name: Checkout full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Python 3.11
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: pip

      - name: Install project and audit tools
        run: |
          python -m pip install --upgrade pip
          python -m pip install -e ".[dev]"
          python -m pip install pip-audit bandit

      - name: Unit tests
        run: python -m pytest -q

      - name: Ruff validation
        run: python -m ruff check .

      - name: Mypy validation
        run: python -m mypy src tests

      - name: Installed-package consistency
        run: python -m pip check

      - name: Dependency vulnerability audit
        run: python -m pip_audit

      - name: Static security analysis
        run: python -m bandit -r src -q -ll

  repository-controls:
    name: section35-repository-controls
    runs-on: ubuntu-latest
    steps:
      - name: Checkout full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run Section 35 repository audit
        shell: pwsh
        run: ./P10S35_Final_Repository_Controls.ps1 -AuditOnly -SkipGitHub -SkipFreshClone -CiMode

  dependency-review:
    name: section35-dependency-review
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
      - name: Review dependency changes
        uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: moderate

  codeql:
    name: section35-codeql
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      packages: read
      actions: read
      contents: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
      - name: Initialize CodeQL
        uses: github/codeql-action/init@v3
        with:
          languages: python
      - name: Analyze
        uses: github/codeql-action/analyze@v3
'@
    Write-Utf8NoBom -Path $workflowPath -Content ($workflow.Trim() + "`n")
}

function Ensure-ControlPolicyDocument {
    if ($AuditOnly -or $CiMode) {
        return
    }

    $policyPath = Join-Path $script:RepositoryRoot "docs\final_repository_controls.md"
    $policy = @"
# Final Repository Controls

## Purpose

This control standard closes Phase X, Section 35 for the FICC Treasury Clearing Liquidity Stress Testing and Model Validation repository. It governs source control, pull-request evidence, continuous integration, information security, data handling, reproducibility, dependency security, and public-portfolio publication.

## Mandatory controls

1. All substantive work enters through branches named ``feature/*``, ``fix/*``, ``data/*``, ``docs/*``, ``chore/*``, or ``dependabot/*``.
2. Pull requests require a descriptive title, scope, validation evidence, and limitations or remediation notes.
3. The protected ``main`` branch prohibits force pushes and deletion and requires pull-request entry.
4. Required CI and security checks must complete successfully before merge.
5. Secrets, credentials, private keys, tokens, and local environment files are prohibited from Git history.
6. Raw, participant-level, confidential, proprietary, and non-public FICC or DTCC information is prohibited.
7. Only official public market data, controlled metadata, configuration, documentation, and synthetic member representations may be published.
8. Generated datasets, DuckDB files, Parquet files, logs, caches, dashboard exports, and other runtime outputs remain outside Git.
9. README installation commands must be executable from a fresh Python 3.11 clone.
10. A fresh-clone test must install the package and pass Pytest, Ruff, Mypy, dependency consistency, dependency vulnerability, and static security checks.
11. Section 35 evidence is retained under ``reports/evidence/final_repository_controls``; only concise control evidence, not bulky runtime output, is versioned.

## Evidence interpretation

- **PASS**: objective evidence satisfies the control.
- **WARN**: the control could not be verified completely because a GitHub feature, permission, or service was unavailable.
- **FAIL**: objective evidence contradicts the control or a mandatory gate failed.

A WARN or FAIL must not be presented as successful completion. Any exception requires documented rationale, owner, target date, and closure evidence.
"@
    Write-Utf8NoBom -Path $policyPath -Content ($policy.Trim() + "`r`n")
}

function Get-GitHubRepositoryContext {
    if ($SkipGitHub) {
        return $false
    }

    if (-not (Test-CommandAvailable "gh")) {
        Add-Result -Control "GitHub authentication and repository access" -Status "WARN" -Evidence "GitHub CLI is not installed." -Remediation "Install GitHub CLI, run 'gh auth login', and rerun the automation."
        return $false
    }

    $auth = Invoke-Native -FilePath "gh" -Arguments @("auth", "status") -AllowFailure -Quiet
    if ($auth.ExitCode -ne 0) {
        Add-Result -Control "GitHub authentication and repository access" -Status "WARN" -Evidence "GitHub CLI authentication is unavailable." -Remediation "Run 'gh auth login' and rerun the automation."
        return $false
    }

    $repoView = Invoke-Native -FilePath "gh" -Arguments @("repo", "view", "--json", "nameWithOwner,url,defaultBranchRef") -AllowFailure -Quiet
    if ($repoView.ExitCode -ne 0) {
        Add-Result -Control "GitHub authentication and repository access" -Status "WARN" -Evidence "The connected GitHub repository could not be resolved." -Remediation "Confirm the origin remote and GitHub CLI repository access."
        return $false
    }

    $repoData = $repoView.Output | ConvertFrom-Json
    $script:RepoSlug = [string]$repoData.nameWithOwner
    $script:RepoUrl = [string]$repoData.url
    Add-Result -Control "GitHub authentication and repository access" -Status "PASS" -Evidence "Authenticated repository: $($script:RepoSlug)." -Remediation "None."
    return $true
}

function Enable-GitHubSecurityFeatures {
    if (-not $ConfigureGitHubControls -or $SkipGitHub -or [string]::IsNullOrWhiteSpace($script:RepoSlug)) {
        return
    }

    Write-Section "Configure GitHub security controls"

    $vulnerabilityAlerts = Invoke-Native -FilePath "gh" -Arguments @("api", "--method", "PUT", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/vulnerability-alerts") -AllowFailure -Quiet
    if ($vulnerabilityAlerts.ExitCode -eq 0) {
        Write-Pass "Dependabot vulnerability alerts enabled."
    }
    else {
        Write-WarnMessage "Dependabot vulnerability alerts could not be enabled automatically: $($vulnerabilityAlerts.Output)"
    }

    $automatedFixes = Invoke-Native -FilePath "gh" -Arguments @("api", "--method", "PUT", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/automated-security-fixes") -AllowFailure -Quiet
    if ($automatedFixes.ExitCode -eq 0) {
        Write-Pass "Dependabot automated security fixes enabled."
    }
    else {
        Write-WarnMessage "Dependabot automated security fixes could not be enabled automatically: $($automatedFixes.Output)"
    }

    $securityPayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) "section35_security_$DateStamp.json"
    $securityPayload = @{
        security_and_analysis = @{
            secret_scanning = @{ status = "enabled" }
            secret_scanning_push_protection = @{ status = "enabled" }
        }
    } | ConvertTo-Json -Depth 6
    Write-Utf8NoBom -Path $securityPayloadPath -Content $securityPayload

    $secretFeatures = Invoke-Native -FilePath "gh" -Arguments @("api", "--method", "PATCH", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)", "--input", $securityPayloadPath) -AllowFailure -Quiet
    Remove-Item -LiteralPath $securityPayloadPath -Force -ErrorAction SilentlyContinue
    if ($secretFeatures.ExitCode -eq 0) {
        Write-Pass "Secret scanning and push protection enabled."
    }
    else {
        Write-WarnMessage "Secret scanning settings were not changed automatically. GitHub plan or permission limitations may apply."
    }
}

function Ensure-BranchProtection {
    if (-not $ConfigureGitHubControls -or $SkipGitHub -or [string]::IsNullOrWhiteSpace($script:RepoSlug)) {
        return
    }

    Write-Section "Configure main-branch protection"
    $branch = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/branches/$BaseBranch") -AllowFailure -Quiet
    if ($branch.ExitCode -ne 0) {
        Write-WarnMessage "Unable to inspect branch protection: $($branch.Output)"
        return
    }

    $branchData = $branch.Output | ConvertFrom-Json
    if ([bool]$branchData.protected) {
        Write-Pass "$BaseBranch is already protected; existing settings were preserved."
        return
    }

    $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) "section35_branch_protection_$DateStamp.json"
    $payload = @{
        required_status_checks = $null
        enforce_admins = $true
        required_pull_request_reviews = @{
            dismiss_stale_reviews = $false
            require_code_owner_reviews = $false
            required_approving_review_count = 0
            require_last_push_approval = $false
        }
        restrictions = $null
        required_linear_history = $true
        allow_force_pushes = $false
        allow_deletions = $false
        required_conversation_resolution = $true
    } | ConvertTo-Json -Depth 8
    Write-Utf8NoBom -Path $payloadPath -Content $payload

    $protect = Invoke-Native -FilePath "gh" -Arguments @("api", "--method", "PUT", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/branches/$BaseBranch/protection", "--input", $payloadPath) -AllowFailure -Quiet
    Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue

    if ($protect.ExitCode -eq 0) {
        Write-Pass "$BaseBranch branch protection enabled with pull-request entry, administrator enforcement, linear history, conversation resolution, and force-push/deletion restrictions."
    }
    else {
        Write-WarnMessage "Branch protection could not be enabled automatically: $($protect.Output)"
    }
}

function Test-BranchAndPullRequestControls {
    if ($SkipGitHub -or [string]::IsNullOrWhiteSpace($script:RepoSlug)) {
        Add-Result -Control "Feature-branch entry and documented pull requests" -Status "WARN" -Evidence "GitHub verification was skipped or unavailable." -Remediation "Rerun with authenticated GitHub CLI access."
        return
    }

    Write-Section "Audit feature branches and pull requests"
    $prsCommand = Invoke-Native -FilePath "gh" -Arguments @("pr", "list", "--state", "merged", "--limit", "200", "--json", "number,title,body,headRefName,baseRefName,mergedAt,url") -AllowFailure -Quiet
    if ($prsCommand.ExitCode -ne 0) {
        Add-Result -Control "Feature-branch entry and documented pull requests" -Status "WARN" -Evidence "Merged pull requests could not be queried." -Remediation "Confirm GitHub CLI permissions and rerun."
        return
    }

    $prs = @($prsCommand.Output | ConvertFrom-Json)
    $badBranchPrs = @($prs | Where-Object {
        $_.baseRefName -eq $BaseBranch -and
        $_.headRefName -notmatch '^(feature|fix|data|docs|chore|dependabot)/'
    })
    $undocumentedPrs = @($prs | Where-Object {
        $_.baseRefName -eq $BaseBranch -and
        ([string]::IsNullOrWhiteSpace([string]$_.title) -or [string]::IsNullOrWhiteSpace([string]$_.body))
    })

    $commitsCommand = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/commits?sha=$BaseBranch&per_page=100") -AllowFailure -Quiet
    $directCommits = New-Object System.Collections.Generic.List[object]
    if ($commitsCommand.ExitCode -eq 0) {
        $commits = @($commitsCommand.Output | ConvertFrom-Json)
        foreach ($commit in $commits) {
            if (@($commit.parents).Count -eq 0) {
                continue
            }
            $sha = [string]$commit.sha
            $pullsCommand = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/commits/$sha/pulls") -AllowFailure -Quiet
            if ($pullsCommand.ExitCode -eq 0) {
                $associatedPrs = @($pullsCommand.Output | ConvertFrom-Json)
                $mergedToBase = @($associatedPrs | Where-Object { $_.base.ref -eq $BaseBranch -and $null -ne $_.merged_at })
                if ($mergedToBase.Count -eq 0) {
                    $directCommits.Add([pscustomobject]@{
                        Sha = $sha.Substring(0, [Math]::Min(8, $sha.Length))
                        Message = [string]$commit.commit.message
                        Date = [string]$commit.commit.author.date
                    }) | Out-Null
                }
            }
        }
    }

    if ($badBranchPrs.Count -eq 0 -and $undocumentedPrs.Count -eq 0 -and $directCommits.Count -eq 0) {
        Add-Result -Control "Feature-branch entry and documented pull requests" -Status "PASS" -Evidence "$($prs.Count) merged pull requests reviewed; branch naming, PR documentation, and sampled main-branch commit association passed." -Remediation "None."
    }
    else {
        $detail = "Nonconforming PR branches=$($badBranchPrs.Count); undocumented PRs=$($undocumentedPrs.Count); main commits without associated merged PR=$($directCommits.Count)."
        Add-Result -Control "Feature-branch entry and documented pull requests" -Status "FAIL" -Evidence $detail -Remediation "Document approved historical exceptions or remediate workflow governance before final sign-off."
    }

    $prEvidence = [pscustomobject]@{
        merged_pull_requests = $prs
        nonconforming_branch_pull_requests = $badBranchPrs
        undocumented_pull_requests = $undocumentedPrs
        direct_main_commits = $directCommits.ToArray()
        sampled_commit_limit = 100
    }
    $prEvidencePath = Join-Path $script:EvidenceDir "pull_request_evidence.json"
    Write-Utf8NoBom -Path $prEvidencePath -Content ($prEvidence | ConvertTo-Json -Depth 10)
}

function Test-CiChecks {
    if ($SkipGitHub -or [string]::IsNullOrWhiteSpace($script:RepoSlug)) {
        Add-Result -Control "CI checks passed" -Status "WARN" -Evidence "GitHub CI verification was skipped or unavailable." -Remediation "Rerun with authenticated GitHub CLI access."
        return
    }

    Write-Section "Audit GitHub Actions and check runs"
    $checkCommand = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/commits/$BaseBranch/check-runs?per_page=100") -AllowFailure -Quiet
    if ($checkCommand.ExitCode -ne 0) {
        Add-Result -Control "CI checks passed" -Status "WARN" -Evidence "Check runs for $BaseBranch could not be queried." -Remediation "Confirm Actions permissions and rerun."
        return
    }

    $checkData = $checkCommand.Output | ConvertFrom-Json
    $checks = @($checkData.check_runs)
    $badChecks = @($checks | Where-Object {
        $_.status -ne "completed" -or $_.conclusion -notin @("success", "neutral", "skipped")
    })

    $runsCommand = Invoke-Native -FilePath "gh" -Arguments @("run", "list", "--branch", $BaseBranch, "--limit", "50", "--json", "workflowName,status,conclusion,createdAt,url,headSha") -AllowFailure -Quiet
    $runs = @()
    if ($runsCommand.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($runsCommand.Output)) {
        $runs = @($runsCommand.Output | ConvertFrom-Json)
    }

    if ($checks.Count -gt 0 -and $badChecks.Count -eq 0) {
        Add-Result -Control "CI checks passed" -Status "PASS" -Evidence "$($checks.Count) checks on $BaseBranch completed successfully, neutrally, or as intentionally skipped." -Remediation "None."
    }
    elseif ($checks.Count -eq 0) {
        Add-Result -Control "CI checks passed" -Status "FAIL" -Evidence "No GitHub check runs were found on $BaseBranch." -Remediation "Run and pass the CI workflow before final sign-off."
    }
    else {
        $names = ($badChecks | ForEach-Object { "$($_.name):$($_.status)/$($_.conclusion)" }) -join "; "
        Add-Result -Control "CI checks passed" -Status "FAIL" -Evidence "Non-passing checks: $names" -Remediation "Open the failed Actions runs, remediate root causes, and rerun."
    }

    $ciEvidence = [pscustomobject]@{
        base_branch = $BaseBranch
        check_runs = $checks
        recent_workflow_runs = $runs
    }
    Write-Utf8NoBom -Path (Join-Path $script:EvidenceDir "ci_evidence.json") -Content ($ciEvidence | ConvertTo-Json -Depth 10)
}

function Test-BranchProtection {
    if ($SkipGitHub -or [string]::IsNullOrWhiteSpace($script:RepoSlug)) {
        Add-Result -Control "Branch protection active" -Status "WARN" -Evidence "GitHub branch-protection verification was skipped or unavailable." -Remediation "Rerun with authenticated GitHub CLI access."
        return
    }

    Write-Section "Verify branch protection"
    $branchCommand = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/branches/$BaseBranch") -AllowFailure -Quiet
    if ($branchCommand.ExitCode -ne 0) {
        Add-Result -Control "Branch protection active" -Status "WARN" -Evidence "The $BaseBranch branch could not be queried." -Remediation "Confirm repository administration/read access."
        return
    }

    $branchData = $branchCommand.Output | ConvertFrom-Json
    if ([bool]$branchData.protected) {
        $detailCommand = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/branches/$BaseBranch/protection") -AllowFailure -Quiet
        if ($detailCommand.ExitCode -eq 0) {
            Write-Utf8NoBom -Path (Join-Path $script:EvidenceDir "branch_protection.json") -Content $detailCommand.Output
        }
        Add-Result -Control "Branch protection active" -Status "PASS" -Evidence "$BaseBranch is protected by a branch-protection rule or ruleset." -Remediation "None."
    }
    else {
        Add-Result -Control "Branch protection active" -Status "FAIL" -Evidence "$BaseBranch is not protected." -Remediation "Rerun with -ConfigureGitHubControls or enable an active GitHub ruleset manually."
    }
}

function Test-SecretControls {
    Write-Section "Audit secrets and credentials"
    $trackedFiles = @((Invoke-Native -FilePath "git" -Arguments @("ls-files") -Quiet).Output -split "`r?`n" | Where-Object { $_ })
    $sensitiveFiles = @($trackedFiles | Where-Object {
        $_ -match '(^|/)(\.env($|\.)|credentials\.json$|secrets\.json$|id_rsa$|id_ed25519$|\.pypirc$)' -or
        $_ -match '\.(pem|key|p12|pfx)$'
    })

    $secretPatterns = [ordered]@{
        github_pat = 'github_pat_[A-Za-z0-9_]{40,}'
        github_classic_pat = 'gh[pousr]_[A-Za-z0-9]{30,}'
        aws_access_key = 'AKIA[0-9A-Z]{16}'
        google_api_key = 'AIza[0-9A-Za-z\-_]{35}'
        openai_style_key = 'sk-[A-Za-z0-9]{20,}'
        private_key_header = '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
        slack_token = 'xox[baprs]-[0-9A-Za-z-]{20,}'
    }

    $historyHits = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $secretPatterns.GetEnumerator()) {
        $historySearch = Invoke-Native -FilePath "git" -Arguments @("log", "--all", "--format=%H", "-G", $entry.Value, "--", ".") -AllowFailure -Quiet
        $commits = @($historySearch.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -Unique)
        if ($commits.Count -gt 0) {
            $historyHits.Add([pscustomobject]@{ Pattern = $entry.Key; CommitCount = $commits.Count; Commits = $commits }) | Out-Null
        }
    }

    $githubAlertStatus = "not_checked"
    $openAlerts = @()
    if (-not $SkipGitHub -and -not [string]::IsNullOrWhiteSpace($script:RepoSlug)) {
        $alertsCommand = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/secret-scanning/alerts?state=open&per_page=100") -AllowFailure -Quiet
        if ($alertsCommand.ExitCode -eq 0) {
            $githubAlertStatus = "available"
            if (-not [string]::IsNullOrWhiteSpace($alertsCommand.Output)) {
                $openAlerts = @($alertsCommand.Output | ConvertFrom-Json)
            }
        }
        else {
            $githubAlertStatus = "unavailable"
        }
    }

    if ($sensitiveFiles.Count -eq 0 -and $historyHits.Count -eq 0 -and $openAlerts.Count -eq 0) {
        $suffix = ""
        if ($githubAlertStatus -eq "unavailable") {
            $suffix = " GitHub native secret-scanning alerts were unavailable; local full-history high-confidence scanning passed."
        }
        Add-Result -Control "No secrets committed" -Status "PASS" -Evidence "No prohibited credential files, high-confidence secret patterns in Git history, or open accessible secret-scanning alerts were found.$suffix" -Remediation "None."
    }
    else {
        Add-Result -Control "No secrets committed" -Status "FAIL" -Evidence "Sensitive files=$($sensitiveFiles.Count); history pattern groups=$($historyHits.Count); open GitHub alerts=$($openAlerts.Count)." -Remediation "Revoke exposed credentials, remove them from Git history, rotate affected secrets, and close verified alerts."
    }

    $secretEvidence = [pscustomobject]@{
        sensitive_tracked_files = $sensitiveFiles
        history_pattern_hits = $historyHits.ToArray()
        github_secret_scanning_status = $githubAlertStatus
        open_github_secret_alerts = $openAlerts
    }
    Write-Utf8NoBom -Path (Join-Path $script:EvidenceDir "secret_scan_evidence.json") -Content ($secretEvidence | ConvertTo-Json -Depth 10)
}

function Test-DataAndConfidentialityControls {
    Write-Section "Audit raw data, confidential information, and runtime outputs"
    $trackedFiles = @((Invoke-Native -FilePath "git" -Arguments @("ls-files") -Quiet).Output -split "`r?`n" | Where-Object { $_ })
    $historyObjects = @((Invoke-Native -FilePath "git" -Arguments @("rev-list", "--objects", "--all") -Quiet).Output -split "`r?`n" | Where-Object { $_ })
    $historyPaths = @($historyObjects | ForEach-Object {
        $parts = $_ -split " ", 2
        if ($parts.Count -eq 2) { $parts[1] }
    } | Where-Object { $_ })

    $rawPathRegex = '(^|/)(data/(raw|interim|processed|external)/|raw_data/|participant_data/)|\.(parquet|duckdb|sqlite3?|feather|pickle|pkl)$'
    $rawCurrent = @($trackedFiles | Where-Object { $_ -match $rawPathRegex })
    $rawHistory = @($historyPaths | Where-Object { $_ -match $rawPathRegex } | Select-Object -Unique)

    $runtimeRegex = '(^|/)(artifacts/|outputs/|logs/|reports/(generated|runtime|dashboard_exports)/|htmlcov/|\.pytest_cache/|\.mypy_cache/|\.ruff_cache/|__pycache__/)|(^|/)\.coverage$|coverage\.xml$'
    $runtimeTracked = @($trackedFiles | Where-Object { $_ -match $runtimeRegex })

    $confidentialPatterns = [ordered]@{
        dtcc_confidential = 'DTCC[ \t_-]+CONFIDENTIAL'
        ficc_confidential = 'FICC[ \t_-]+CONFIDENTIAL'
        proprietary_confidential = 'PROPRIETARY[ \t]+AND[ \t]+CONFIDENTIAL'
        internal_use_only = 'INTERNAL[ \t]+USE[ \t]+ONLY'
        non_public_ficc = 'NON[- \t]+PUBLIC[ \t]+FICC'
    }
    $confidentialHits = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $confidentialPatterns.GetEnumerator()) {
        $historySearch = Invoke-Native -FilePath "git" -Arguments @("log", "--all", "--format=%H", "-G", $entry.Value, "--", ".") -AllowFailure -Quiet
        $commits = @($historySearch.Output -split "`r?`n" | Where-Object { $_ } | Select-Object -Unique)
        if ($commits.Count -gt 0) {
            $confidentialHits.Add([pscustomobject]@{ Pattern = $entry.Key; CommitCount = $commits.Count; Commits = $commits }) | Out-Null
        }
    }

    $readmePath = Join-Path $script:RepositoryRoot "README.md"
    $readmeText = ""
    if (Test-Path -LiteralPath $readmePath) {
        $readmeText = Get-Content -LiteralPath $readmePath -Raw
    }
    $syntheticDisclaimerPresent = $readmeText -match '(?i)synthetic' -and $readmeText -match '(?i)(public data|official public|participant-level)'

    if ($rawCurrent.Count -eq 0 -and $rawHistory.Count -eq 0) {
        Add-Result -Control "No raw data committed" -Status "PASS" -Evidence "No prohibited raw/processed analytical data paths or binary analytical data formats were found in the current tree or Git object history." -Remediation "None."
    }
    else {
        Add-Result -Control "No raw data committed" -Status "FAIL" -Evidence "Current prohibited data paths=$($rawCurrent.Count); historical prohibited data paths=$($rawHistory.Count)." -Remediation "Remove data artifacts from Git history and retain only contracts, manifests, metadata, and approved small test fixtures."
    }

    if ($confidentialHits.Count -eq 0 -and $syntheticDisclaimerPresent) {
        Add-Result -Control "No confidential FICC information" -Status "PASS" -Evidence "No high-risk confidentiality markers were detected in Git history, and the README states the public/synthetic data boundary." -Remediation "None."
    }
    elseif ($confidentialHits.Count -eq 0) {
        Add-Result -Control "No confidential FICC information" -Status "WARN" -Evidence "No high-risk markers were detected, but the README public/synthetic-data disclaimer was incomplete." -Remediation "Add an explicit statement that no actual FICC participant or confidential information is used."
    }
    else {
        Add-Result -Control "No confidential FICC information" -Status "FAIL" -Evidence "$($confidentialHits.Count) confidentiality-marker groups were detected in Git history." -Remediation "Review every hit, remove prohibited content from history, and document any verified false positive."
    }

    $gitIgnorePath = Join-Path $script:RepositoryRoot ".gitignore"
    $gitIgnoreText = ""
    if (Test-Path -LiteralPath $gitIgnorePath) {
        $gitIgnoreText = Get-Content -LiteralPath $gitIgnorePath -Raw
    }
    $requiredIgnoreTokens = @(".venv/", "__pycache__/", ".pytest_cache/", ".mypy_cache/", ".ruff_cache/", "data/raw/", "data/processed/", "*.parquet", "*.duckdb", "logs/", "reports/runtime/")
    $missingIgnoreTokens = @($requiredIgnoreTokens | Where-Object { $gitIgnoreText -notmatch [regex]::Escape($_) })

    if ($runtimeTracked.Count -eq 0 -and $missingIgnoreTokens.Count -eq 0) {
        Add-Result -Control "Runtime outputs properly controlled" -Status "PASS" -Evidence "No prohibited runtime outputs are tracked, and mandatory ignore patterns are present." -Remediation "None."
    }
    else {
        Add-Result -Control "Runtime outputs properly controlled" -Status "FAIL" -Evidence "Tracked runtime outputs=$($runtimeTracked.Count); missing ignore patterns=$($missingIgnoreTokens.Count)." -Remediation "Untrack generated outputs and complete the .gitignore control block."
    }

    $dataEvidence = [pscustomobject]@{
        raw_current = $rawCurrent
        raw_history = $rawHistory
        runtime_tracked = $runtimeTracked
        missing_gitignore_tokens = $missingIgnoreTokens
        confidentiality_history_hits = $confidentialHits.ToArray()
        synthetic_disclaimer_present = $syntheticDisclaimerPresent
    }
    Write-Utf8NoBom -Path (Join-Path $script:EvidenceDir "data_confidentiality_runtime_evidence.json") -Content ($dataEvidence | ConvertTo-Json -Depth 10)
}

function Test-ReadmeInstructions {
    Write-Section "Audit README installation instructions"
    $readmePath = Join-Path $script:RepositoryRoot "README.md"
    if (-not (Test-Path -LiteralPath $readmePath)) {
        Add-Result -Control "README installation instructions tested" -Status "FAIL" -Evidence "README.md is missing." -Remediation "Create and test controlled installation instructions."
        return
    }

    $content = Get-Content -LiteralPath $readmePath -Raw
    $requiredPatterns = [ordered]@{
        python311 = '(?i)Python 3\.11|py -3\.11'
        virtual_environment = '(?i)(venv|virtual environment)'
        package_install = '(?i)pip install -e'
        pytest = '(?i)pytest'
        ruff = '(?i)ruff check'
        mypy = '(?i)mypy'
    }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $requiredPatterns.GetEnumerator()) {
        if ($content -notmatch $entry.Value) {
            $missing.Add($entry.Key) | Out-Null
        }
    }

    if ($missing.Count -eq 0) {
        Add-Result -Control "README installation instructions tested" -Status "PASS" -Evidence "README contains Python 3.11 environment, editable installation, Pytest, Ruff, and Mypy commands; execution is validated by the fresh-clone gate." -Remediation "None."
    }
    else {
        Add-Result -Control "README installation instructions tested" -Status "FAIL" -Evidence "Missing instruction elements: $($missing -join ', ')." -Remediation "Complete the controlled installation and validation instructions."
    }
}

function Invoke-FreshCloneReproduction {
    if ($SkipFreshClone) {
        Add-Result -Control "Fresh-clone reproduction tested" -Status "WARN" -Evidence "Fresh-clone reproduction was explicitly skipped." -Remediation "Rerun without -SkipFreshClone before final sign-off."
        Add-Result -Control "Security and dependency checks passed" -Status "WARN" -Evidence "Fresh-clone security and dependency checks were explicitly skipped." -Remediation "Rerun without -SkipFreshClone before final sign-off."
        return
    }

    Write-Section "Run clean-clone reproduction and security gates"
    $launcher = Get-PythonLauncher
    $remoteCommand = Invoke-Native -FilePath "git" -Arguments @("remote", "get-url", "origin") -AllowFailure -Quiet
    if ($remoteCommand.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($remoteCommand.Output)) {
        Add-Result -Control "Fresh-clone reproduction tested" -Status "FAIL" -Evidence "The origin remote could not be resolved." -Remediation "Configure the origin remote and rerun."
        Add-Result -Control "Security and dependency checks passed" -Status "FAIL" -Evidence "Security checks could not run because fresh cloning failed." -Remediation "Configure the origin remote and rerun."
        return
    }

    $cloneParent = Join-Path ([System.IO.Path]::GetTempPath()) "ficc_section35_$DateStamp"
    $clonePath = Join-Path $cloneParent "repo"
    $script:FreshClonePath = $clonePath
    New-Item -ItemType Directory -Path $cloneParent -Force | Out-Null
    $logPath = Join-Path $script:EvidenceDir "fresh_clone_reproduction.log"
    $log = New-Object System.Collections.Generic.List[string]
    $cloneSucceeded = $false
    $qualitySucceeded = $false
    $securitySucceeded = $false

    try {
        $clone = Invoke-Native -FilePath "git" -Arguments @("clone", "--depth", "1", "--branch", $BaseBranch, $remoteCommand.Output, $clonePath) -AllowFailure -Quiet
        $log.Add("CLONE EXIT: $($clone.ExitCode)") | Out-Null
        $log.Add($clone.Output) | Out-Null
        if ($clone.ExitCode -ne 0) {
            throw "Fresh clone failed."
        }
        $cloneSucceeded = $true

        Push-Location $clonePath
        try {
            $venv = Invoke-PythonLauncher -Launcher $launcher -Arguments @("-m", "venv", ".venv") -AllowFailure -Quiet
            $log.Add("VENV EXIT: $($venv.ExitCode)") | Out-Null
            $log.Add($venv.Output) | Out-Null
            if ($venv.ExitCode -ne 0) { throw "Virtual environment creation failed." }

            if ($env:OS -eq "Windows_NT") {
                $venvPython = Join-Path $clonePath ".venv\Scripts\python.exe"
            }
            else {
                $venvPython = Join-Path $clonePath ".venv/bin/python"
            }
            if (-not (Test-Path -LiteralPath $venvPython)) {
                throw "Virtual-environment Python executable was not found."
            }

            $commands = @(
                @("-m", "pip", "install", "--upgrade", "pip"),
                @("-m", "pip", "install", "-e", ".[dev]"),
                @("-c", "import ficc_liquidity; print('ficc_liquidity import PASS')"),
                @("-m", "pytest", "-q"),
                @("-m", "ruff", "check", "."),
                @("-m", "mypy", "src", "tests"),
                @("-m", "pip", "check")
            )

            $qualitySucceeded = $true
            foreach ($args in $commands) {
                $result = Invoke-Native -FilePath $venvPython -Arguments $args -AllowFailure -Quiet
                $log.Add("COMMAND: $venvPython $($args -join ' ')") | Out-Null
                $log.Add("EXIT: $($result.ExitCode)") | Out-Null
                $log.Add($result.Output) | Out-Null
                if ($result.ExitCode -ne 0) {
                    $qualitySucceeded = $false
                    break
                }
            }

            $installSecurity = Invoke-Native -FilePath $venvPython -Arguments @("-m", "pip", "install", "pip-audit", "bandit") -AllowFailure -Quiet
            $log.Add("SECURITY TOOL INSTALL EXIT: $($installSecurity.ExitCode)") | Out-Null
            $log.Add($installSecurity.Output) | Out-Null

            if ($installSecurity.ExitCode -eq 0) {
                $pipAudit = Invoke-Native -FilePath $venvPython -Arguments @("-m", "pip_audit") -AllowFailure -Quiet
                $bandit = Invoke-Native -FilePath $venvPython -Arguments @("-m", "bandit", "-r", "src", "-q", "-ll") -AllowFailure -Quiet
                $log.Add("PIP-AUDIT EXIT: $($pipAudit.ExitCode)") | Out-Null
                $log.Add($pipAudit.Output) | Out-Null
                $log.Add("BANDIT EXIT: $($bandit.ExitCode)") | Out-Null
                $log.Add($bandit.Output) | Out-Null
                $securitySucceeded = ($pipAudit.ExitCode -eq 0 -and $bandit.ExitCode -eq 0)
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        $log.Add("ERROR: $($_.Exception.Message)") | Out-Null
    }
    finally {
        Write-Utf8NoBom -Path $logPath -Content (($log -join "`r`n") + "`r`n")
        if (-not $KeepClone -and (Test-Path -LiteralPath $cloneParent)) {
            Remove-Item -LiteralPath $cloneParent -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($cloneSucceeded -and $qualitySucceeded) {
        Add-Result -Control "Fresh-clone reproduction tested" -Status "PASS" -Evidence "A depth-one clone of origin/$BaseBranch created Python 3.11, installed the project, imported the package, and passed Pytest, Ruff, Mypy, and pip check." -Remediation "None."
    }
    else {
        Add-Result -Control "Fresh-clone reproduction tested" -Status "FAIL" -Evidence "The clean-clone installation or quality gate failed. See fresh_clone_reproduction.log." -Remediation "Correct README/package/environment issues and rerun from a clean clone."
    }

    if ($securitySucceeded) {
        Add-Result -Control "Security and dependency checks passed" -Status "PASS" -Evidence "pip-audit and Bandit completed successfully in the isolated fresh-clone environment." -Remediation "None."
    }
    else {
        Add-Result -Control "Security and dependency checks passed" -Status "FAIL" -Evidence "pip-audit or Bandit failed, or the tools could not be installed. See fresh_clone_reproduction.log." -Remediation "Remediate vulnerable dependencies or static security findings and rerun."
    }
}

function Test-DependabotAlerts {
    if ($SkipGitHub -or [string]::IsNullOrWhiteSpace($script:RepoSlug)) {
        return
    }

    $alertsCommand = Invoke-Native -FilePath "gh" -Arguments @("api", "-H", "Accept: application/vnd.github+json", "repos/$($script:RepoSlug)/dependabot/alerts?state=open&per_page=100") -AllowFailure -Quiet
    $status = "unavailable"
    $alerts = @()
    if ($alertsCommand.ExitCode -eq 0) {
        $status = "available"
        if (-not [string]::IsNullOrWhiteSpace($alertsCommand.Output)) {
            $alerts = @($alertsCommand.Output | ConvertFrom-Json)
        }
    }
    $evidence = [pscustomobject]@{
        api_status = $status
        open_alert_count = $alerts.Count
        open_alerts = $alerts
    }
    Write-Utf8NoBom -Path (Join-Path $script:EvidenceDir "dependabot_alerts.json") -Content ($evidence | ConvertTo-Json -Depth 12)

    if ($alerts.Count -gt 0) {
        $existing = @($script:Results | Where-Object { $_.Control -eq "Security and dependency checks passed" })
        if ($existing.Count -gt 0) {
            foreach ($item in $existing) {
                $item.Status = "FAIL"
                $item.Evidence = "$($item.Evidence) GitHub reports $($alerts.Count) open Dependabot alert(s)."
                $item.Remediation = "Remediate or dismiss with documented rationale every open Dependabot alert, then rerun."
            }
            Write-FailMessage "Security and dependency checks passed - GitHub reports $($alerts.Count) open Dependabot alert(s)."
        }
    }
}

function Write-EvidencePackage {
    Write-Section "Generate Section 35 evidence package"
    $jsonPath = Join-Path $script:EvidenceDir "final_repository_controls_results.json"
    $csvPath = Join-Path $script:EvidenceDir "final_repository_controls_results.csv"
    $mdPath = Join-Path $script:EvidenceDir "final_repository_controls_report.md"

    $summary = [pscustomobject]@{
        section = $SectionTitle
        generated_at_utc = $TimestampUtc
        repository = $script:RepoSlug
        repository_url = $script:RepoUrl
        branch = (Invoke-Native -FilePath "git" -Arguments @("branch", "--show-current") -Quiet).Output
        base_branch = $BaseBranch
        commit = (Invoke-Native -FilePath "git" -Arguments @("rev-parse", "HEAD") -Quiet).Output
        pass_count = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count
        warn_count = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count
        fail_count = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
        controls = $script:Results.ToArray()
    }
    Write-Utf8NoBom -Path $jsonPath -Content ($summary | ConvertTo-Json -Depth 12)
    $script:Results | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($result in $script:Results) {
        $evidence = ([string]$result.Evidence).Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
        $remediation = ([string]$result.Remediation).Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
        $rows.Add("| $($result.Control) | $($result.Status) | $evidence | $remediation |") | Out-Null
    }

    $overall = "PASS"
    if ($summary.fail_count -gt 0) {
        $overall = "FAIL"
    }
    elseif ($summary.warn_count -gt 0) {
        $overall = "WARN"
    }

    $report = @"
# Final Repository Controls Evidence Report

- **Section:** $SectionTitle
- **Generated:** $TimestampUtc
- **Repository:** $($script:RepoSlug)
- **Base branch:** $BaseBranch
- **Overall status:** **$overall**
- **PASS:** $($summary.pass_count)
- **WARN:** $($summary.warn_count)
- **FAIL:** $($summary.fail_count)

## Control results

| Control | Status | Evidence | Required remediation |
|---|---:|---|---|
$($rows -join "`r`n")

## Scope and limitations

This evidence package combines local Git-tree and full-history pattern checks, GitHub API evidence where permissions allow, clean-clone execution, dependency auditing, and static security analysis. Pattern scans are preventive controls, not a substitute for human review of intellectual property, confidentiality, licensing, or data-release authorization.

No WARN or FAIL may be represented as full Section 35 completion. Close each exception with dated evidence before merging the final sign-off pull request.
"@
    Write-Utf8NoBom -Path $mdPath -Content ($report.Trim() + "`r`n")

    Write-Info "Evidence directory: $($script:EvidenceDir)"
    Write-Info "Overall status: $overall"
}

function Publish-ControlBranch {
    if (-not $Publish -or $AuditOnly -or $CiMode) {
        return
    }

    Write-Section "Commit, push, and create documented pull request"
    $prBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "section35_pr_body_$DateStamp.md"
    $failCount = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
    $warnCount = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count
    $passCount = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count
    $prBody = @"
## Scope

Completes Phase X, Section 35 final repository controls for the FICC Treasury Clearing Liquidity Stress Testing and Model Validation project.

## Controls implemented and tested

- Feature-branch and pull-request governance evidence
- GitHub Actions quality, dependency, static-security, repository-control, and CodeQL gates
- Main-branch protection verification/configuration
- Git-history secret, raw-data, confidential-marker, and runtime-output scans
- Controlled README installation instructions
- Python 3.11 fresh-clone reproduction
- Pytest, Ruff, Mypy, pip check, pip-audit, and Bandit evidence
- Machine-readable JSON/CSV evidence and a Markdown validation report

## Gate summary

- PASS: $passCount
- WARN: $warnCount
- FAIL: $failCount

See ``reports/evidence/final_repository_controls/final_repository_controls_report.md`` for the complete results and limitations.

## Data and confidentiality attestation

This public repository contains no actual FICC participant representation and is designed for official public data, controlled metadata, and synthetic member analysis only. No confidential FICC or DTCC information is authorized for publication.
"@
    Write-Utf8NoBom -Path $prBodyPath -Content ($prBody.Trim() + "`r`n")

    Invoke-Native -FilePath "git" -Arguments @(
        "add",
        ".gitignore",
        "README.md",
        ".github/workflows/final-repository-controls.yml",
        "docs/final_repository_controls.md",
        $ScriptName
    ) | Out-Null

    # The Section 35 evidence package is intentionally version controlled.
    Invoke-Native -FilePath "git" -Arguments @(
        "add",
        "-f",
        "reports/evidence/final_repository_controls"
    ) | Out-Null

    $status = (Invoke-Native -FilePath "git" -Arguments @("status", "--porcelain") -Quiet).Output
    if ([string]::IsNullOrWhiteSpace($status)) {
        Write-WarnMessage "No changes were detected; no commit was created."
    }
    else {
        Invoke-Native -FilePath "git" -Arguments @("commit", "-m", "Phase X Section 35: finalize repository controls") | Out-Null
    }

    Invoke-Native -FilePath "git" -Arguments @("push", "--set-upstream", "origin", $BranchName) | Out-Null

    $existingPr = Invoke-Native -FilePath "gh" -Arguments @("pr", "view", $BranchName, "--json", "number,url,state") -AllowFailure -Quiet
    if ($existingPr.ExitCode -eq 0) {
        $prData = $existingPr.Output | ConvertFrom-Json
        Write-Pass "Pull request already exists: $($prData.url)"
        $prNumber = [string]$prData.number
    }
    else {
        $createPr = Invoke-Native -FilePath "gh" -Arguments @(
            "pr", "create",
            "--base", $BaseBranch,
            "--head", $BranchName,
            "--title", "Phase X Section 35: Final repository controls",
            "--body-file", $prBodyPath
        ) -AllowFailure
        if ($createPr.ExitCode -ne 0) {
            throw "Pull request creation failed: $($createPr.Output)"
        }
        Write-Pass "Pull request created: $($createPr.Output)"
        $prView = Invoke-Native -FilePath "gh" -Arguments @("pr", "view", $BranchName, "--json", "number,url") -Quiet
        $prData = $prView.Output | ConvertFrom-Json
        $prNumber = [string]$prData.number
    }

    if (-not [string]::IsNullOrWhiteSpace($prNumber)) {
        Write-Info "Monitoring pull-request checks. The command exits when checks finish or a check fails."
        $checks = Invoke-Native -FilePath "gh" -Arguments @("pr", "checks", $prNumber, "--watch", "--fail-fast", "--interval", "10") -AllowFailure
        if ($checks.ExitCode -eq 0) {
            Write-Pass "All available pull-request checks passed."
        }
        else {
            Write-FailMessage "One or more pull-request checks failed or remained unavailable. Review the PR before merge."
        }
    }
    Remove-Item -LiteralPath $prBodyPath -Force -ErrorAction SilentlyContinue
}

function Assert-CiModeLocalControls {
    if (-not $CiMode) {
        return
    }

    $fails = @($script:Results | Where-Object { $_.Status -eq "FAIL" })
    if ($fails.Count -gt 0) {
        Write-FailMessage "CI repository-control audit failed with $($fails.Count) failed control(s)."
        exit 1
    }
    Write-Pass "CI repository-control audit passed."
}

try {
    Write-Section $SectionTitle
    $script:RepositoryRoot = Resolve-RepositoryRoot
    Set-Location -LiteralPath $script:RepositoryRoot
    Write-Info "Repository root: $($script:RepositoryRoot)"

    if (-not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot ".git"))) {
        throw "The selected path is not a Git repository."
    }
    if (-not (Test-CommandAvailable "git")) {
        throw "Git is not installed or is not available on PATH."
    }

    Ensure-FeatureBranch
    Ensure-AutomationFileInRepository

    $script:EvidenceDir = Join-Path $script:RepositoryRoot "reports\evidence\final_repository_controls"
    New-Item -ItemType Directory -Path $script:EvidenceDir -Force | Out-Null

    Ensure-GitIgnoreControls
    Ensure-ReadmeInstallationSection
    Ensure-FinalControlsWorkflow
    Ensure-ControlPolicyDocument

    $githubAvailable = Get-GitHubRepositoryContext
    if ($Publish -and -not $githubAvailable) {
        throw "Publishing requires authenticated GitHub CLI access. Run 'gh auth login' and rerun."
    }
    if ($githubAvailable) {
        Enable-GitHubSecurityFeatures
        Ensure-BranchProtection
    }

    Test-BranchAndPullRequestControls
    Test-CiChecks
    Test-BranchProtection
    Test-SecretControls
    Test-DataAndConfidentialityControls
    Test-ReadmeInstructions
    Invoke-FreshCloneReproduction
    Test-DependabotAlerts
    Write-EvidencePackage
    Publish-ControlBranch
    Assert-CiModeLocalControls

    $failCount = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
    $warnCount = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count
    $passCount = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count

    Write-Section "Section 35 execution summary"
    Write-Host "PASS: $passCount" -ForegroundColor Green
    Write-Host "WARN: $warnCount" -ForegroundColor Yellow
    Write-Host "FAIL: $failCount" -ForegroundColor Red
    Write-Host "Evidence: $($script:EvidenceDir)" -ForegroundColor Cyan

    if ($failCount -gt 0) {
        Write-FailMessage "Section 35 is not yet eligible for final PASS. Review the evidence report and remediate each failed control."
        exit 1
    }
    elseif ($warnCount -gt 0) {
        Write-WarnMessage "Section 35 completed with warnings. Resolve or formally document each warning before final sign-off."
        exit 0
    }
    else {
        Write-Pass "Phase X Section 35 final repository controls: PASS."
        exit 0
    }
}
catch {
    Write-Host ""
    Write-FailMessage $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
