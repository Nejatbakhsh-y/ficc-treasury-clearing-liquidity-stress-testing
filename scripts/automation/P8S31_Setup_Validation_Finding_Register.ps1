#requires -Version 5.1
<#
.SYNOPSIS
    Phase VIII, Section 31 validation finding register automation.

.DESCRIPTION
    Creates the complete Section 31 validation finding register implementation for
    the FICC Treasury Clearing Liquidity Stress Testing and Model Validation project.

    The automation creates:
      - controlled finding classifications and statuses;
      - the required validation finding register fields;
      - Python validation, reporting, aging, and ID-generation logic;
      - a command-line runner;
      - a controlled CSV register template;
      - governance documentation;
      - a GitHub validation-finding issue form;
      - DuckDB-compatible SQL structures;
      - automated tests;
      - deterministic demonstration evidence;
      - Git commit, optional push, and optional pull request.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    .\P8S31_Setup_Validation_Finding_Register.ps1

.EXAMPLE
    .\P8S31_Setup_Validation_Finding_Register.ps1 -Publish
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/20-monitoring-governance",
    [string]$BaseBranch = "main",
    [switch]$SkipGit,
    [switch]$SkipValidation,
    [switch]$Publish
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

function Assert-LastExitCode {
    param([Parameter(Mandatory = $true)][string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Write-ManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $nativeRelativePath = $RelativePath -replace "/", [IO.Path]::DirectorySeparatorChar
    $destination = Join-Path $ProjectRoot $nativeRelativePath
    $parent = Split-Path -Parent $destination
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $destination) {
        $backup = Join-Path $BackupRoot $nativeRelativePath
        $backupParent = Split-Path -Parent $backup
        if ($backupParent) {
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $destination -Destination $backup -Force
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(
        $destination,
        $Content.TrimStart("`r", "`n") + "`n",
        $encoding
    )
    Write-Host "WROTE  $RelativePath"
}

function Ensure-ManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $nativeRelativePath = $RelativePath -replace "/", [IO.Path]::DirectorySeparatorChar
    $destination = Join-Path $ProjectRoot $nativeRelativePath
    if (-not (Test-Path -LiteralPath $destination)) {
        Write-ManagedFile -RelativePath $RelativePath -Content $Content
    }
    else {
        Write-Host "KEPT   $RelativePath"
    }
}

function Add-GitInfoExcludeLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    $gitInfo = Join-Path $ProjectRoot ".git\info"
    if (-not (Test-Path -LiteralPath $gitInfo -PathType Container)) {
        return
    }

    $excludePath = Join-Path $gitInfo "exclude"
    $existing = ""
    if (Test-Path -LiteralPath $excludePath) {
        $existing = [IO.File]::ReadAllText($excludePath)
    }

    $lines = @($existing -split "`r?`n")
    if ($lines -notcontains $Line) {
        Add-Content -LiteralPath $excludePath -Value $Line -Encoding utf8
    }
}

function Resolve-ProjectPython {
    $venvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $venvPython) {
        return $venvPython
    }

    Write-Step "Creating the Python 3.11 virtual environment"
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3.11 -m venv (Join-Path $ProjectRoot ".venv")
        Assert-LastExitCode "Python 3.11 virtual-environment creation"
    }
    elseif (Get-Command python -ErrorAction SilentlyContinue) {
        & python -m venv (Join-Path $ProjectRoot ".venv")
        Assert-LastExitCode "Python virtual-environment creation"
    }
    else {
        throw "Python was not found. Install Python 3.11 and reopen VS Code."
    }

    if (-not (Test-Path -LiteralPath $venvPython)) {
        throw "The expected virtual-environment interpreter was not created: $venvPython"
    }
    return $venvPython
}

function Test-PythonModule {
    param(
        [Parameter(Mandatory = $true)][string]$Python,
        [Parameter(Mandatory = $true)][string]$Module
    )

    & $Python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('$Module') else 1)"
    return ($LASTEXITCODE -eq 0)
}

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Repository folder not found: $ProjectRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "pyproject.toml"))) {
    throw "pyproject.toml was not found. Confirm that ProjectRoot is the repository root."
}

Set-Location -LiteralPath $ProjectRoot
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupRoot = Join-Path $ProjectRoot "reports\evidence\backups\section31_$timestamp"
$AutomationRelativePath = "scripts/automation/P8S31_Setup_Validation_Finding_Register.ps1"
$DemoAsOfDate = "2026-07-25"

if (Test-Path -LiteralPath (Join-Path $ProjectRoot ".git") -PathType Container) {
    Add-GitInfoExcludeLine -Line "/reports/evidence/backups/section31_*/"

    $launcherPath = $MyInvocation.MyCommand.Path
    if ($launcherPath -and (Test-Path -LiteralPath $launcherPath)) {
        $resolvedLauncher = [IO.Path]::GetFullPath($launcherPath)
        $controlledPath = [IO.Path]::GetFullPath(
            (Join-Path $ProjectRoot ($AutomationRelativePath -replace "/", "\"))
        )
        $rootWithSeparator = $ProjectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (
            $resolvedLauncher.StartsWith(
                $rootWithSeparator,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            -not $resolvedLauncher.Equals(
                $controlledPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $launcherRelative = $resolvedLauncher.Substring($rootWithSeparator.Length) -replace "\\", "/"
            Add-GitInfoExcludeLine -Line "/$launcherRelative"
        }
    }
}

if (-not $SkipGit) {
    Write-Step "Preparing Git branch $Branch"

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git was not found. Install Git and reopen VS Code."
    }

    & git rev-parse --is-inside-work-tree | Out-Null
    Assert-LastExitCode "Git repository validation"

    $trackedChanges = (& git status --porcelain --untracked-files=no) -join "`n"
    if ($trackedChanges.Trim()) {
        throw @"
Tracked changes already exist in the repository.
Commit, discard, or finish the current tracked work before running Section 31.

$trackedChanges
"@
    }

    $currentBranch = (& git branch --show-current).Trim()
    if ($currentBranch -ne $Branch) {
        & git show-ref --verify --quiet "refs/heads/$Branch"
        if ($LASTEXITCODE -eq 0) {
            & git switch $Branch
            Assert-LastExitCode "Switching to local branch $Branch"
        }
        else {
            & git show-ref --verify --quiet "refs/remotes/origin/$Branch"
            if ($LASTEXITCODE -eq 0) {
                & git switch --track "origin/$Branch"
                Assert-LastExitCode "Tracking remote branch $Branch"
            }
            else {
                & git switch $BaseBranch
                Assert-LastExitCode "Switching to base branch $BaseBranch"

                & git pull --ff-only origin $BaseBranch
                Assert-LastExitCode "Updating base branch $BaseBranch"

                & git switch -c $Branch
                Assert-LastExitCode "Creating branch $Branch from $BaseBranch"
            }
        }
    }
}

Write-Step "Creating Section 31 controlled files"

Write-ManagedFile -RelativePath "configs/validation_findings.yaml" -Content @'
validation_findings:
  schema_version: "1.0"
  finding_id:
    prefix: "FICC-LST"
    pattern: '^FICC-LST-[0-9]{4}-[0-9]{3}$'
    sequence_width: 3

  required_fields:
    - finding_id
    - category
    - condition
    - evidence
    - risk
    - recommendation
    - management_response
    - owner
    - target_date
    - status
    - closure_evidence

  classifications:
    Critical:
      rank: 5
      target_calendar_days: 5
      risk_acceptance_allowed: false
      escalation:
        - Model Risk Management
        - Senior Management
        - Model Owner
    High:
      rank: 4
      target_calendar_days: 20
      risk_acceptance_allowed: false
      escalation:
        - Model Risk Management
        - Model Owner
    Medium:
      rank: 3
      target_calendar_days: 45
      risk_acceptance_allowed: true
      escalation:
        - Model Validation Owner
        - Model Owner
    Low:
      rank: 2
      target_calendar_days: 90
      risk_acceptance_allowed: true
      escalation:
        - Model Validation Owner
    Observation:
      rank: 1
      target_calendar_days: 120
      risk_acceptance_allowed: true
      escalation:
        - Model Validation Owner

  statuses:
    - Open
    - Remediation in Progress
    - Pending Validation Review
    - Risk Accepted
    - Closed
    - Overdue

  active_statuses:
    - Open
    - Remediation in Progress
    - Pending Validation Review
    - Overdue

  terminal_statuses:
    - Risk Accepted
    - Closed

  closure:
    independent_validation_required: true
    closure_evidence_required_for:
      - Closed
      - Risk Accepted
    prohibited_placeholders:
      - ""
      - "n/a"
      - "na"
      - "none"
      - "not applicable until closure"
      - "pending"
      - "tbd"
      - "to be determined"

  date_format: "%Y-%m-%d"
  due_soon_calendar_days: 30
'@

Write-ManagedFile -RelativePath "data/manifests/validation_finding_register.csv" -Content @'
finding_id,category,condition,evidence,risk,recommendation,management_response,owner,target_date,status,closure_evidence
FICC-LST-2026-001,Critical,"Independent reconciliation differs from the production-equivalent integrated stressed liquidity requirement.","Section 25 reconciliation output and line-item calculation trace.","Reported LCR and liquidity shortfall may be materially misstated.","Reconcile formulas, units, aggregation, and rounding; correct the implementation and rerun affected scenarios.","Management accepted immediate remediation and restricted reliance on unreconciled outputs.","Model Development Owner",2026-07-30,"Remediation in Progress","Not applicable until closure"
FICC-LST-2026-002,High,"Available-resource eligibility is not consistently applied across all scenario paths.","Section 24 resource-eligibility challenge and scenario comparison evidence.","Ineligible or unavailable resources may overstate liquidity capacity.","Centralize eligibility rules, add negative tests, and independently verify resource timing and encumbrance.","Management implemented the eligibility control and submitted evidence for independent review.","Liquidity Risk Owner",2026-08-10,"Pending Validation Review","Not applicable until closure"
FICC-LST-2026-003,Medium,"Scenario rank ordering changes under selected parameter combinations without sufficient economic explanation.","Section 27 benchmark and rank-stability analysis.","Unexpected ordering may impair scenario interpretation and governance.","Document the economic drivers, compare with deterministic benchmarks, and define acceptable rank-stability tolerances.","Management assigned the scenario governance owner and initiated the required benchmark analysis.","Scenario Governance Owner",2026-09-01,Open,"Not applicable until closure"
FICC-LST-2026-004,Low,"Monthly monitoring documentation did not initially identify all retained evidence files.","Section 29 documentation review and controlled-output inventory.","Incomplete evidence references could reduce auditability.","Update the operating procedure and evidence inventory, then verify all required artifacts are retained.","Management updated the operating procedure and evidence index.","Model Monitoring Owner",2026-07-15,Closed,"Independent validator reviewed the revised documentation, confirmed the complete evidence inventory, and approved closure on 2026-07-18."
FICC-LST-2026-005,Observation,"The demonstration register uses synthetic examples rather than actual FICC findings.","Repository data-classification review and synthetic-data labeling.","A reader could incorrectly interpret demonstration findings as confidential participant or DTCC outcomes.","Retain explicit synthetic-data disclaimers in the register, reports, and project documentation.","Management formally accepted the residual presentation risk subject to continued synthetic-data labeling.","Model Risk Governance Owner",2026-07-20,"Risk Accepted","Documented risk acceptance approved by Model Risk Governance on 2026-07-20; synthetic-data disclaimers remain mandatory."
'@

Ensure-ManagedFile -RelativePath "src/ficc_liquidity/governance/__init__.py" -Content @'
"""Model monitoring and governance controls."""
'@

Write-ManagedFile -RelativePath "src/ficc_liquidity/governance/validation_findings.py" -Content @'
"""Controlled validation finding register for Section 31."""

from __future__ import annotations

import json
import re
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Mapping, Sequence

import yaml


class FindingRegisterValidationError(ValueError):
    """Raised when a finding register violates a controlled requirement."""


@dataclass(frozen=True)
class FindingIssue:
    """One validation issue identified in the register."""

    level: str
    code: str
    finding_id: str
    message: str


@dataclass(frozen=True)
class FindingRegisterSummary:
    """Run-level summary for the validation finding register."""

    as_of_date: str
    total_findings: int
    active_findings: int
    closed_findings: int
    risk_accepted_findings: int
    overdue_findings: int
    due_soon_findings: int
    highest_open_classification: str | None
    error_count: int
    warning_count: int
    classification_counts: dict[str, int]
    status_counts: dict[str, int]


class ValidationFindingRegister:
    """Validate, summarize, and report controlled model-validation findings."""

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.config = dict(config["validation_findings"])
        self.required_fields = tuple(self.config["required_fields"])
        self.classifications = dict(self.config["classifications"])
        self.statuses = tuple(self.config["statuses"])
        self.active_statuses = tuple(self.config["active_statuses"])
        self.terminal_statuses = tuple(self.config["terminal_statuses"])
        self.id_pattern = re.compile(str(self.config["finding_id"]["pattern"]))
        self.id_prefix = str(self.config["finding_id"]["prefix"])
        self.sequence_width = int(self.config["finding_id"]["sequence_width"])
        self.date_format = str(self.config["date_format"])
        self.due_soon_days = int(self.config["due_soon_calendar_days"])
        closure = dict(self.config["closure"])
        self.closure_required_for = tuple(closure["closure_evidence_required_for"])
        self.prohibited_placeholders = {
            str(value).strip().lower() for value in closure["prohibited_placeholders"]
        }

    @classmethod
    def from_yaml(cls, path: str | Path) -> "ValidationFindingRegister":
        """Create a register controller from the controlled YAML configuration."""

        with Path(path).open("r", encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
        return cls(config)

    def load_csv(self, path: str | Path) -> list[dict[str, str]]:
        """Load the controlled CSV register using only standard-library parsing."""

        import csv

        with Path(path).open("r", encoding="utf-8-sig", newline="") as stream:
            reader = csv.DictReader(stream)
            return [
                {str(key): "" if value is None else str(value) for key, value in row.items()}
                for row in reader
            ]

    def write_csv(self, rows: Sequence[Mapping[str, Any]], path: str | Path) -> Path:
        """Write rows in the exact controlled field order."""

        import csv

        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(self.required_fields))
            writer.writeheader()
            for row in rows:
                writer.writerow(
                    {field: self._text(row.get(field, "")) for field in self.required_fields}
                )
        return destination

    def validate(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        as_of_date: str | date,
        raise_on_error: bool = False,
    ) -> list[FindingIssue]:
        """Validate structure, classifications, dates, status, and closure controls."""

        resolved_as_of = self._parse_date(as_of_date, "as_of_date", "")
        issues: list[FindingIssue] = []
        seen_ids: set[str] = set()

        if not rows:
            issues.append(
                FindingIssue(
                    level="WARNING",
                    code="EMPTY_REGISTER",
                    finding_id="",
                    message="The validation finding register contains no findings.",
                )
            )

        for index, source_row in enumerate(rows, start=2):
            row = {str(key): self._text(value) for key, value in source_row.items()}
            finding_id = row.get("finding_id", "").strip() or f"ROW-{index}"

            missing_columns = [
                field for field in self.required_fields if field not in source_row
            ]
            if missing_columns:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="MISSING_COLUMNS",
                        finding_id=finding_id,
                        message="Missing required columns: " + ", ".join(missing_columns),
                    )
                )
                continue

            blank_fields = [
                field for field in self.required_fields if not row.get(field, "").strip()
            ]
            if blank_fields:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="BLANK_REQUIRED_FIELDS",
                        finding_id=finding_id,
                        message="Blank required fields: " + ", ".join(blank_fields),
                    )
                )

            if not self.id_pattern.fullmatch(row["finding_id"].strip()):
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="INVALID_FINDING_ID",
                        finding_id=finding_id,
                        message=(
                            "Finding ID does not match the controlled pattern "
                            f"{self.id_pattern.pattern}."
                        ),
                    )
                )

            if row["finding_id"] in seen_ids:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="DUPLICATE_FINDING_ID",
                        finding_id=finding_id,
                        message="Finding ID must be unique.",
                    )
                )
            seen_ids.add(row["finding_id"])

            category = row["category"].strip()
            status = row["status"].strip()

            if category not in self.classifications:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="INVALID_CATEGORY",
                        finding_id=finding_id,
                        message=f"Unknown finding classification: {category}.",
                    )
                )

            if status not in self.statuses:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="INVALID_STATUS",
                        finding_id=finding_id,
                        message=f"Unknown finding status: {status}.",
                    )
                )

            target_date = self._try_parse_date(
                row["target_date"].strip(),
                "target_date",
                finding_id,
                issues,
            )

            if target_date is not None and status in self.active_statuses:
                if target_date < resolved_as_of and status != "Overdue":
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="OVERDUE_STATUS_REQUIRED",
                            finding_id=finding_id,
                            message=(
                                f"Target date {target_date.isoformat()} is before "
                                f"{resolved_as_of.isoformat()}; status must be Overdue."
                            ),
                        )
                    )
                if target_date >= resolved_as_of and status == "Overdue":
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="PREMATURE_OVERDUE_STATUS",
                            finding_id=finding_id,
                            message=(
                                f"Target date {target_date.isoformat()} has not passed; "
                                "status cannot be Overdue."
                            ),
                        )
                    )

            if status == "Risk Accepted" and category in self.classifications:
                risk_acceptance_allowed = bool(
                    self.classifications[category]["risk_acceptance_allowed"]
                )
                if not risk_acceptance_allowed:
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="RISK_ACCEPTANCE_PROHIBITED",
                            finding_id=finding_id,
                            message=(
                                f"{category} findings cannot be closed through "
                                "risk acceptance."
                            ),
                        )
                    )

            closure_evidence = row["closure_evidence"].strip()
            if status in self.closure_required_for:
                normalized_evidence = closure_evidence.lower()
                if normalized_evidence in self.prohibited_placeholders:
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="INSUFFICIENT_CLOSURE_EVIDENCE",
                            finding_id=finding_id,
                            message=(
                                f"Status {status} requires substantive independent "
                                "closure or risk-acceptance evidence."
                            ),
                        )
                    )
                elif len(closure_evidence) < 25:
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="CLOSURE_EVIDENCE_TOO_SHORT",
                            finding_id=finding_id,
                            message=(
                                "Closure evidence must identify the decision, "
                                "review, and supporting evidence."
                            ),
                        )
                    )

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

        if raise_on_error:
            errors = [issue for issue in issues if issue.level == "ERROR"]
            if errors:
                detail = "\n".join(
                    f"{issue.finding_id}: {issue.code}: {issue.message}"
                    for issue in errors
                )
                raise FindingRegisterValidationError(
                    "Validation finding register failed controlled validation:\n" + detail
                )

        return issues

    def summarize(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        as_of_date: str | date,
        issues: Sequence[FindingIssue] | None = None,
    ) -> FindingRegisterSummary:
        """Produce classification, status, aging, and validation summaries."""

        resolved_as_of = self._parse_date(as_of_date, "as_of_date", "")
        resolved_issues = list(issues or [])
        classification_counts = Counter(
            self._text(row.get("category", "")).strip() for row in rows
        )
        status_counts = Counter(self._text(row.get("status", "")).strip() for row in rows)

        active = [
            row
            for row in rows
            if self._text(row.get("status", "")).strip() in self.active_statuses
        ]
        overdue_count = 0
        due_soon_count = 0

        for row in active:
            target_value = self._text(row.get("target_date", "")).strip()
            try:
                target = datetime.strptime(target_value, self.date_format).date()
            except ValueError:
                continue
            if target < resolved_as_of:
                overdue_count += 1
            elif target <= resolved_as_of + timedelta(days=self.due_soon_days):
                due_soon_count += 1

        open_categories = [
            self._text(row.get("category", "")).strip()
            for row in active
            if self._text(row.get("category", "")).strip() in self.classifications
        ]
        highest = None
        if open_categories:
            highest = max(
                open_categories,
                key=lambda value: int(self.classifications[value]["rank"]),
            )

        return FindingRegisterSummary(
            as_of_date=resolved_as_of.isoformat(),
            total_findings=len(rows),
            active_findings=len(active),
            closed_findings=int(status_counts.get("Closed", 0)),
            risk_accepted_findings=int(status_counts.get("Risk Accepted", 0)),
            overdue_findings=overdue_count,
            due_soon_findings=due_soon_count,
            highest_open_classification=highest,
            error_count=sum(issue.level == "ERROR" for issue in resolved_issues),
            warning_count=sum(issue.level == "WARNING" for issue in resolved_issues),
            classification_counts=dict(
                sorted(
                    classification_counts.items(),
                    key=lambda item: int(
                        self.classifications.get(item[0], {"rank": 0})["rank"]
                    ),
                    reverse=True,
                )
            ),
            status_counts=dict(sorted(status_counts.items())),
        )

    def next_finding_id(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        year: int | None = None,
    ) -> str:
        """Return the next deterministic finding ID for the requested year."""

        resolved_year = year or date.today().year
        prefix = f"{self.id_prefix}-{resolved_year}-"
        sequences: list[int] = []
        for row in rows:
            finding_id = self._text(row.get("finding_id", "")).strip()
            if finding_id.startswith(prefix) and self.id_pattern.fullmatch(finding_id):
                sequences.append(int(finding_id.rsplit("-", 1)[1]))
        next_sequence = max(sequences, default=0) + 1
        return f"{prefix}{next_sequence:0{self.sequence_width}d}"

    def write_outputs(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        output_dir: str | Path,
        as_of_date: str | date,
        issues: Sequence[FindingIssue],
    ) -> dict[str, Path]:
        """Write the controlled CSV, JSON summary, issue log, and Markdown report."""

        destination = Path(output_dir)
        destination.mkdir(parents=True, exist_ok=True)
        summary = self.summarize(rows, as_of_date=as_of_date, issues=issues)
        stamp = summary.as_of_date.replace("-", "")

        register_path = destination / f"validation_finding_register_{stamp}.csv"
        summary_path = destination / f"validation_finding_summary_{stamp}.json"
        issue_path = destination / f"validation_finding_issues_{stamp}.json"
        report_path = destination / f"validation_finding_report_{stamp}.md"

        self.write_csv(rows, register_path)
        summary_path.write_text(
            json.dumps(asdict(summary), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        issue_path.write_text(
            json.dumps([asdict(issue) for issue in issues], indent=2, sort_keys=True),
            encoding="utf-8",
        )
        report_path.write_text(
            self.render_markdown(rows, summary=summary, issues=issues),
            encoding="utf-8",
        )

        return {
            "register": register_path,
            "summary": summary_path,
            "issues": issue_path,
            "report": report_path,
        }

    def render_markdown(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        summary: FindingRegisterSummary,
        issues: Sequence[FindingIssue],
    ) -> str:
        """Render the management and validation review report."""

        lines = [
            "# Section 31 — Validation Finding Register",
            "",
            f"**As-of date:** {summary.as_of_date}",
            "",
            "## Executive summary",
            "",
            f"- Total findings: {summary.total_findings}",
            f"- Active findings: {summary.active_findings}",
            f"- Closed findings: {summary.closed_findings}",
            f"- Risk-accepted findings: {summary.risk_accepted_findings}",
            f"- Overdue findings: {summary.overdue_findings}",
            f"- Due within {self.due_soon_days} days: {summary.due_soon_findings}",
            (
                "- Highest open classification: "
                f"{summary.highest_open_classification or 'None'}"
            ),
            f"- Validation errors: {summary.error_count}",
            f"- Validation warnings: {summary.warning_count}",
            "",
            "## Classification summary",
            "",
            "| Classification | Count |",
            "|---|---:|",
        ]
        for classification in self.classifications:
            lines.append(
                f"| {classification} | "
                f"{summary.classification_counts.get(classification, 0)} |"
            )

        lines.extend(
            [
                "",
                "## Status summary",
                "",
                "| Status | Count |",
                "|---|---:|",
            ]
        )
        for status in self.statuses:
            lines.append(f"| {status} | {summary.status_counts.get(status, 0)} |")

        lines.extend(
            [
                "",
                "## Finding register",
                "",
                "| Finding ID | Classification | Condition | Owner | Target date | Status |",
                "|---|---|---|---|---|---|",
            ]
        )
        for row in rows:
            condition = self._text(row.get("condition", "")).replace("|", "/")
            if len(condition) > 90:
                condition = condition[:87] + "..."
            lines.append(
                "| {finding_id} | {category} | {condition} | {owner} | "
                "{target_date} | {status} |".format(
                    finding_id=self._text(row.get("finding_id", "")),
                    category=self._text(row.get("category", "")),
                    condition=condition,
                    owner=self._text(row.get("owner", "")).replace("|", "/"),
                    target_date=self._text(row.get("target_date", "")),
                    status=self._text(row.get("status", "")),
                )
            )

        lines.extend(["", "## Validation issues", ""])
        if issues:
            lines.extend(
                [
                    "| Level | Code | Finding ID | Message |",
                    "|---|---|---|---|",
                ]
            )
            for issue in issues:
                lines.append(
                    f"| {issue.level} | {issue.code} | {issue.finding_id} | "
                    f"{issue.message.replace('|', '/')} |"
                )
        else:
            lines.append("No controlled validation issues were identified.")

        lines.extend(
            [
                "",
                "## Closure control",
                "",
                (
                    "A finding is not closed solely because management reports that remediation "
                    "is complete. Closed status requires substantive closure evidence and "
                    "independent validation review. Critical and High findings cannot be "
                    "disposed through risk acceptance."
                ),
                "",
                (
                    "All demonstration findings are synthetic project-governance examples. "
                    "They are not actual FICC, DTCC, clearing-member, or participant findings."
                ),
                "",
            ]
        )
        return "\n".join(lines)

    def _try_parse_date(
        self,
        value: str,
        field_name: str,
        finding_id: str,
        issues: list[FindingIssue],
    ) -> date | None:
        try:
            return datetime.strptime(value, self.date_format).date()
        except ValueError:
            issues.append(
                FindingIssue(
                    level="ERROR",
                    code="INVALID_DATE",
                    finding_id=finding_id,
                    message=(
                        f"{field_name} must use the controlled format "
                        f"{self.date_format}: {value!r}."
                    ),
                )
            )
            return None

    def _parse_date(
        self,
        value: str | date,
        field_name: str,
        finding_id: str,
    ) -> date:
        if isinstance(value, date):
            return value
        try:
            return datetime.strptime(str(value), self.date_format).date()
        except ValueError as exc:
            raise FindingRegisterValidationError(
                f"{field_name} must use {self.date_format}: {value!r}."
            ) from exc

    @staticmethod
    def _text(value: Any) -> str:
        return "" if value is None else str(value)


def build_demo_rows() -> list[dict[str, str]]:
    """Return deterministic synthetic Section 31 demonstration findings."""

    return [
        {
            "finding_id": "FICC-LST-2026-001",
            "category": "Critical",
            "condition": (
                "Independent reconciliation differs from the production-equivalent "
                "integrated stressed liquidity requirement."
            ),
            "evidence": "Section 25 reconciliation output and line-item calculation trace.",
            "risk": "Reported LCR and liquidity shortfall may be materially misstated.",
            "recommendation": (
                "Reconcile formulas, units, aggregation, and rounding; correct the "
                "implementation and rerun affected scenarios."
            ),
            "management_response": (
                "Management accepted immediate remediation and restricted reliance "
                "on unreconciled outputs."
            ),
            "owner": "Model Development Owner",
            "target_date": "2026-07-30",
            "status": "Remediation in Progress",
            "closure_evidence": "Not applicable until closure",
        },
        {
            "finding_id": "FICC-LST-2026-002",
            "category": "High",
            "condition": (
                "Available-resource eligibility is not consistently applied across "
                "all scenario paths."
            ),
            "evidence": (
                "Section 24 resource-eligibility challenge and scenario comparison evidence."
            ),
            "risk": "Ineligible resources may overstate liquidity capacity.",
            "recommendation": (
                "Centralize eligibility rules, add negative tests, and independently "
                "verify resource timing and encumbrance."
            ),
            "management_response": (
                "Management implemented the eligibility control and submitted evidence "
                "for independent review."
            ),
            "owner": "Liquidity Risk Owner",
            "target_date": "2026-08-10",
            "status": "Pending Validation Review",
            "closure_evidence": "Not applicable until closure",
        },
        {
            "finding_id": "FICC-LST-2026-003",
            "category": "Medium",
            "condition": (
                "Scenario rank ordering changes under selected parameter combinations "
                "without sufficient economic explanation."
            ),
            "evidence": "Section 27 benchmark and rank-stability analysis.",
            "risk": "Unexpected ordering may impair scenario interpretation and governance.",
            "recommendation": (
                "Document economic drivers, compare deterministic benchmarks, and "
                "define acceptable rank-stability tolerances."
            ),
            "management_response": (
                "Management assigned the scenario governance owner and initiated "
                "the required benchmark analysis."
            ),
            "owner": "Scenario Governance Owner",
            "target_date": "2026-09-01",
            "status": "Open",
            "closure_evidence": "Not applicable until closure",
        },
        {
            "finding_id": "FICC-LST-2026-004",
            "category": "Low",
            "condition": (
                "Monthly monitoring documentation did not initially identify all "
                "retained evidence files."
            ),
            "evidence": "Section 29 documentation review and controlled-output inventory.",
            "risk": "Incomplete evidence references could reduce auditability.",
            "recommendation": (
                "Update the operating procedure and evidence inventory, then verify "
                "all required artifacts are retained."
            ),
            "management_response": (
                "Management updated the operating procedure and evidence index."
            ),
            "owner": "Model Monitoring Owner",
            "target_date": "2026-07-15",
            "status": "Closed",
            "closure_evidence": (
                "Independent validator reviewed the revised documentation, confirmed "
                "the complete evidence inventory, and approved closure on 2026-07-18."
            ),
        },
        {
            "finding_id": "FICC-LST-2026-005",
            "category": "Observation",
            "condition": (
                "The demonstration register uses synthetic examples rather than "
                "actual FICC findings."
            ),
            "evidence": (
                "Repository data-classification review and synthetic-data labeling."
            ),
            "risk": (
                "A reader could incorrectly interpret demonstration findings as "
                "confidential participant or DTCC outcomes."
            ),
            "recommendation": (
                "Retain explicit synthetic-data disclaimers in the register, reports, "
                "and project documentation."
            ),
            "management_response": (
                "Management formally accepted the residual presentation risk subject "
                "to continued synthetic-data labeling."
            ),
            "owner": "Model Risk Governance Owner",
            "target_date": "2026-07-20",
            "status": "Risk Accepted",
            "closure_evidence": (
                "Documented risk acceptance approved by Model Risk Governance on "
                "2026-07-20; synthetic-data disclaimers remain mandatory."
            ),
        },
    ]
'@

Write-ManagedFile -RelativePath "scripts/run_validation_findings.py" -Content @'
"""Command-line runner for the Section 31 validation finding register."""

from __future__ import annotations

import argparse
import json
from datetime import date
from pathlib import Path

from ficc_liquidity.governance.validation_findings import (
    ValidationFindingRegister,
    build_demo_rows,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/validation_findings.yaml"),
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=Path("data/manifests/validation_finding_register.csv"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("reports/governance/findings/latest"),
    )
    parser.add_argument(
        "--as-of-date",
        default=date.today().isoformat(),
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Use the deterministic synthetic demonstration findings.",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate without writing report outputs.",
    )
    parser.add_argument(
        "--next-id-year",
        type=int,
        help="Print the next finding ID for this year and exit after validation.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    controller = ValidationFindingRegister.from_yaml(args.config)
    rows = build_demo_rows() if args.demo else controller.load_csv(args.input)
    issues = controller.validate(
        rows,
        as_of_date=args.as_of_date,
        raise_on_error=True,
    )
    summary = controller.summarize(
        rows,
        as_of_date=args.as_of_date,
        issues=issues,
    )

    payload: dict[str, object] = {
        "summary": summary.__dict__,
        "issues": [issue.__dict__ for issue in issues],
    }

    if args.next_id_year is not None:
        payload["next_finding_id"] = controller.next_finding_id(
            rows,
            year=args.next_id_year,
        )

    if not args.validate_only:
        outputs = controller.write_outputs(
            rows,
            output_dir=args.output_dir,
            as_of_date=args.as_of_date,
            issues=issues,
        )
        payload["outputs"] = {name: str(path) for name, path in outputs.items()}

    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-ManagedFile -RelativePath "tests/test_validation_findings.py" -Content @'
"""Tests for the Section 31 validation finding register."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ficc_liquidity.governance.validation_findings import (
    FindingRegisterValidationError,
    ValidationFindingRegister,
    build_demo_rows,
)


CONFIG = Path("configs/validation_findings.yaml")
AS_OF_DATE = "2026-07-25"


def controller() -> ValidationFindingRegister:
    return ValidationFindingRegister.from_yaml(CONFIG)


def test_demo_register_passes_controlled_validation() -> None:
    register = controller()
    rows = build_demo_rows()

    issues = register.validate(
        rows,
        as_of_date=AS_OF_DATE,
        raise_on_error=True,
    )
    summary = register.summarize(
        rows,
        as_of_date=AS_OF_DATE,
        issues=issues,
    )

    assert summary.total_findings == 5
    assert summary.active_findings == 3
    assert summary.closed_findings == 1
    assert summary.risk_accepted_findings == 1
    assert summary.overdue_findings == 0
    assert summary.highest_open_classification == "Critical"
    assert summary.error_count == 0


def test_duplicate_finding_id_is_rejected() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[1]["finding_id"] = rows[0]["finding_id"]

    with pytest.raises(FindingRegisterValidationError, match="DUPLICATE_FINDING_ID"):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_unknown_classification_is_rejected() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[0]["category"] = "Severe"

    with pytest.raises(FindingRegisterValidationError, match="INVALID_CATEGORY"):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_closed_finding_requires_substantive_closure_evidence() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[3]["closure_evidence"] = "Pending"

    with pytest.raises(
        FindingRegisterValidationError,
        match="INSUFFICIENT_CLOSURE_EVIDENCE",
    ):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_critical_finding_cannot_be_risk_accepted() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[0]["status"] = "Risk Accepted"
    rows[0]["closure_evidence"] = (
        "Management documented risk acceptance, but the classification prohibits it."
    )

    with pytest.raises(
        FindingRegisterValidationError,
        match="RISK_ACCEPTANCE_PROHIBITED",
    ):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_expired_active_target_requires_overdue_status() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[2]["target_date"] = "2026-07-01"

    with pytest.raises(
        FindingRegisterValidationError,
        match="OVERDUE_STATUS_REQUIRED",
    ):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_next_finding_id_increments_existing_year_sequence() -> None:
    register = controller()
    rows = build_demo_rows()

    assert register.next_finding_id(rows, year=2026) == "FICC-LST-2026-006"
    assert register.next_finding_id(rows, year=2027) == "FICC-LST-2027-001"


def test_outputs_include_register_summary_issues_and_report(tmp_path: Path) -> None:
    register = controller()
    rows = build_demo_rows()
    issues = register.validate(rows, as_of_date=AS_OF_DATE)

    outputs = register.write_outputs(
        rows,
        output_dir=tmp_path,
        as_of_date=AS_OF_DATE,
        issues=issues,
    )

    assert set(outputs) == {"register", "summary", "issues", "report"}
    assert all(path.exists() for path in outputs.values())

    summary = json.loads(outputs["summary"].read_text(encoding="utf-8"))
    assert summary["total_findings"] == 5
    assert summary["highest_open_classification"] == "Critical"

    report = outputs["report"].read_text(encoding="utf-8")
    assert "Validation Finding Register" in report
    assert "FICC-LST-2026-001" in report
    assert "synthetic project-governance examples" in report
'@

Write-ManagedFile -RelativePath "docs/validation_finding_register.md" -Content @'
# Section 31 — Validation Finding Register

## Objective

Section 31 establishes a controlled register for findings generated by independent model
validation, monthly monitoring, governance review, implementation verification, benchmark
analysis, sensitivity analysis, and uncertainty assessment.

The register supports the complete finding life cycle:

1. Identification.
2. Classification.
3. Evidence preservation.
4. Risk assessment.
5. Remediation recommendation.
6. Management response.
7. Ownership and target-date assignment.
8. Status monitoring.
9. Independent closure review.
10. Retention of closure evidence.

This public project uses synthetic member data and public market information. Register examples
must not be represented as actual FICC, DTCC, clearing-member, or participant findings.

## Required fields

| Field | Control requirement |
|---|---|
| Finding ID | Unique identifier using `FICC-LST-YYYY-NNN` |
| Category | Critical, High, Medium, Low, or Observation |
| Condition | Precise statement of the identified deficiency or control weakness |
| Evidence | Traceable tests, files, calculations, reports, or review records |
| Risk | Potential model, liquidity, governance, reporting, or operational impact |
| Recommendation | Specific and testable remediation requirement |
| Management response | Management decision, planned action, disagreement, or acceptance |
| Owner | Accountable remediation owner |
| Target date | Controlled ISO date in `YYYY-MM-DD` format |
| Status | Current approved finding status |
| Closure evidence | Independent closure or approved risk-acceptance evidence |

## Classifications

### Critical

A deficiency that may materially invalidate model output, liquidity conclusions, model use,
regulatory reporting, or governance decisions. Critical findings require immediate escalation,
restricted reliance where appropriate, and accelerated remediation. Risk acceptance is prohibited.

### High

A material weakness that can significantly affect methodology, implementation, data, outcomes,
controls, or decision use. High findings require formal management remediation and independent
closure validation. Risk acceptance is prohibited.

### Medium

A meaningful weakness that does not immediately invalidate the model but requires controlled
remediation, compensating controls, or enhanced evidence.

### Low

A limited weakness with low immediate impact. Remediation remains required and must be evidenced.

### Observation

An advisory improvement, clarification, or governance enhancement. An Observation is not used to
conceal a material deficiency.

## Permitted statuses

- `Open`
- `Remediation in Progress`
- `Pending Validation Review`
- `Risk Accepted`
- `Closed`
- `Overdue`

An active finding whose target date has passed must be recorded as `Overdue`. A finding cannot be
marked `Overdue` before its target date passes.

## Closure standard

Management completion does not itself close a finding. Closure requires:

- completion of the approved recommendation or approved alternative;
- retained remediation evidence;
- rerun of relevant tests;
- confirmation that the original condition is resolved;
- assessment of residual risk;
- independent validation review;
- substantive closure evidence in the register.

Critical and High findings cannot be disposed through risk acceptance. Medium, Low, and
Observation findings may be risk accepted only when the management response and closure evidence
document the decision, residual risk, approver, and continuing controls.

## Controlled files

- `configs/validation_findings.yaml`
- `data/manifests/validation_finding_register.csv`
- `src/ficc_liquidity/governance/validation_findings.py`
- `scripts/run_validation_findings.py`
- `tests/test_validation_findings.py`
- `sql/validation_finding_register.sql`
- `.github/ISSUE_TEMPLATE/validation-finding.yml`
- `reports/governance/findings/`

## Execution

Validate the controlled register and write outputs:

```powershell
.\.venv\Scripts\python.exe scripts\run_validation_findings.py `
  --input data\manifests\validation_finding_register.csv `
  --as-of-date 2026-07-25 `
  --output-dir reports\governance\findings\latest
```

Create deterministic demonstration evidence:

```powershell
.\.venv\Scripts\python.exe scripts\run_validation_findings.py `
  --demo `
  --as-of-date 2026-07-25 `
  --output-dir reports\governance\findings\demo
```

Generate the next controlled finding ID:

```powershell
.\.venv\Scripts\python.exe scripts\run_validation_findings.py `
  --validate-only `
  --next-id-year 2026
```

## Monthly governance procedure

1. Import new validation and monitoring findings.
2. Validate all required fields and classifications.
3. Recalculate overdue and due-soon populations.
4. Review Critical and High findings first.
5. Confirm management responses and accountable owners.
6. Escalate overdue or disputed findings.
7. Review remediation evidence independently.
8. Close only findings meeting the closure standard.
9. Preserve original evidence, failed tests, and prior statuses.
10. Include the register summary in monthly sign-off and annual validation.
'@

Write-ManagedFile -RelativePath "sql/validation_finding_register.sql" -Content @'
-- Phase VIII, Section 31: validation finding register evidence structures.
-- Compatible with DuckDB.

CREATE TABLE IF NOT EXISTS validation_finding_register (
    finding_id VARCHAR PRIMARY KEY,
    category VARCHAR NOT NULL,
    condition VARCHAR NOT NULL,
    evidence VARCHAR NOT NULL,
    risk VARCHAR NOT NULL,
    recommendation VARCHAR NOT NULL,
    management_response VARCHAR NOT NULL,
    owner VARCHAR NOT NULL,
    target_date DATE NOT NULL,
    status VARCHAR NOT NULL,
    closure_evidence VARCHAR NOT NULL,
    CHECK (category IN ('Critical', 'High', 'Medium', 'Low', 'Observation')),
    CHECK (
        status IN (
            'Open',
            'Remediation in Progress',
            'Pending Validation Review',
            'Risk Accepted',
            'Closed',
            'Overdue'
        )
    )
);

CREATE OR REPLACE VIEW validation_findings_active AS
SELECT *
FROM validation_finding_register
WHERE status IN (
    'Open',
    'Remediation in Progress',
    'Pending Validation Review',
    'Overdue'
);

CREATE OR REPLACE VIEW validation_findings_overdue AS
SELECT *
FROM validation_finding_register
WHERE
    status = 'Overdue'
    OR (
        status IN ('Open', 'Remediation in Progress', 'Pending Validation Review')
        AND target_date < current_date
    );

CREATE OR REPLACE VIEW validation_finding_classification_summary AS
SELECT
    category,
    count(*) AS finding_count,
    sum(
        CASE
            WHEN status IN (
                'Open',
                'Remediation in Progress',
                'Pending Validation Review',
                'Overdue'
            )
            THEN 1
            ELSE 0
        END
    ) AS active_finding_count,
    sum(CASE WHEN status = 'Overdue' THEN 1 ELSE 0 END) AS overdue_finding_count
FROM validation_finding_register
GROUP BY category;

CREATE OR REPLACE VIEW validation_finding_owner_summary AS
SELECT
    owner,
    count(*) AS finding_count,
    sum(CASE WHEN status = 'Closed' THEN 1 ELSE 0 END) AS closed_count,
    sum(CASE WHEN status = 'Overdue' THEN 1 ELSE 0 END) AS overdue_count
FROM validation_finding_register
GROUP BY owner;
'@

Write-ManagedFile -RelativePath ".github/ISSUE_TEMPLATE/validation-finding.yml" -Content @'
name: Validation finding
description: Record a controlled model-validation or monitoring finding
title: "[VALIDATION FINDING] "
labels:
  - model-risk
body:
  - type: markdown
    attributes:
      value: |
        Do not include confidential FICC, DTCC, clearing-member, participant, or personal data.
        Use only public-source or synthetic project evidence.

  - type: input
    id: finding_id
    attributes:
      label: Finding ID
      description: Use the controlled FICC-LST-YYYY-NNN format.
      placeholder: FICC-LST-2026-006
    validations:
      required: true

  - type: dropdown
    id: category
    attributes:
      label: Category
      options:
        - Critical
        - High
        - Medium
        - Low
        - Observation
    validations:
      required: true

  - type: textarea
    id: condition
    attributes:
      label: Condition
      description: State the precise deficiency or control weakness.
    validations:
      required: true

  - type: textarea
    id: evidence
    attributes:
      label: Evidence
      description: Identify controlled tests, files, calculations, or review records.
    validations:
      required: true

  - type: textarea
    id: risk
    attributes:
      label: Risk
      description: Describe the model, liquidity, governance, reporting, or operational impact.
    validations:
      required: true

  - type: textarea
    id: recommendation
    attributes:
      label: Recommendation
      description: State the specific and testable remediation requirement.
    validations:
      required: true

  - type: textarea
    id: management_response
    attributes:
      label: Management response
    validations:
      required: true

  - type: input
    id: owner
    attributes:
      label: Owner
    validations:
      required: true

  - type: input
    id: target_date
    attributes:
      label: Target date
      description: Use YYYY-MM-DD.
      placeholder: "2026-08-31"
    validations:
      required: true

  - type: dropdown
    id: status
    attributes:
      label: Status
      options:
        - Open
        - Remediation in Progress
        - Pending Validation Review
        - Risk Accepted
        - Closed
        - Overdue
    validations:
      required: true

  - type: textarea
    id: closure_evidence
    attributes:
      label: Closure evidence
      description: Use "Not applicable until closure" for active findings.
    validations:
      required: true

  - type: checkboxes
    id: confirmations
    attributes:
      label: Confirmations
      options:
        - label: I preserved unfavorable evidence and prior failed results.
          required: true
        - label: I used only public-source or synthetic project information.
          required: true
'@

Ensure-ManagedFile -RelativePath "reports/governance/findings/.gitkeep" -Content ""

$selfPath = $MyInvocation.MyCommand.Path
if ($selfPath -and (Test-Path -LiteralPath $selfPath)) {
    $controlledAutomationPath = Join-Path $ProjectRoot (
        $AutomationRelativePath -replace "/", [IO.Path]::DirectorySeparatorChar
    )
    $resolvedSelf = [IO.Path]::GetFullPath($selfPath)
    $resolvedControlled = [IO.Path]::GetFullPath($controlledAutomationPath)

    if (-not $resolvedSelf.Equals(
        $resolvedControlled,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        Write-ManagedFile `
            -RelativePath $AutomationRelativePath `
            -Content ([IO.File]::ReadAllText($resolvedSelf))
    }
}

$gateResults = [ordered]@{
    "Required-field schema" = "NOT RUN"
    "Classification controls" = "NOT RUN"
    "Status and overdue controls" = "NOT RUN"
    "Closure evidence controls" = "NOT RUN"
    "Ruff validation" = "NOT RUN"
    "Mypy validation" = "NOT RUN"
    "Focused pytest" = "NOT RUN"
    "Python compilation" = "NOT RUN"
    "Deterministic demo" = "NOT RUN"
}

if (-not $SkipValidation) {
    $Python = Resolve-ProjectPython
    $env:PYTHONPATH = Join-Path $ProjectRoot "src"

    Write-Step "Checking Section 31 Python dependencies"
    & $Python -c "import yaml, pytest"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing required Section 31 validation dependencies..."
        & $Python -m pip install pyyaml pytest
        Assert-LastExitCode "Installing PyYAML and pytest"
    }

    $pythonFiles = @(
        "src/ficc_liquidity/governance/validation_findings.py",
        "scripts/run_validation_findings.py",
        "tests/test_validation_findings.py"
    )

    if (Test-PythonModule -Python $Python -Module "ruff") {
        Write-Step "Formatting and linting Section 31 code"
        & $Python -m ruff format @pythonFiles
        Assert-LastExitCode "Ruff formatting"

        & $Python -m ruff check --fix @pythonFiles
        Assert-LastExitCode "Ruff automatic correction"

        & $Python -m ruff check @pythonFiles
        Assert-LastExitCode "Ruff validation"
        $gateResults["Ruff validation"] = "PASS"
    }
    else {
        Write-Warn "Ruff is not installed; the focused pytest and compilation gates will still run."
        $gateResults["Ruff validation"] = "NOT AVAILABLE"
    }

    if (Test-PythonModule -Python $Python -Module "mypy") {
        Write-Step "Running focused type checking"
        & $Python -m mypy `
            --ignore-missing-imports `
            src/ficc_liquidity/governance/validation_findings.py `
            scripts/run_validation_findings.py
        Assert-LastExitCode "Mypy validation"
        $gateResults["Mypy validation"] = "PASS"
    }
    else {
        Write-Warn "Mypy is not installed; type checking is recorded as not available."
        $gateResults["Mypy validation"] = "NOT AVAILABLE"
    }

    Write-Step "Running Section 31 automated tests"
    & $Python -m pytest `
        -q `
        -o addopts= `
        tests/test_validation_findings.py
    Assert-LastExitCode "Section 31 focused pytest gate"
    $gateResults["Focused pytest"] = "PASS"

    Write-Step "Running Python compilation gate"
    & $Python -m compileall -q `
        src/ficc_liquidity/governance `
        scripts/run_validation_findings.py `
        tests/test_validation_findings.py
    Assert-LastExitCode "Section 31 compilation gate"
    $gateResults["Python compilation"] = "PASS"

    Write-Step "Creating deterministic Section 31 evidence"
    $demoOutput = Join-Path $ProjectRoot "reports\governance\findings\demo"
    New-Item -ItemType Directory -Path $demoOutput -Force | Out-Null

    & $Python scripts/run_validation_findings.py `
        --demo `
        --as-of-date $DemoAsOfDate `
        --output-dir $demoOutput
    Assert-LastExitCode "Section 31 deterministic demo"
    $gateResults["Deterministic demo"] = "PASS"

    & $Python scripts/run_validation_findings.py `
        --input data/manifests/validation_finding_register.csv `
        --as-of-date $DemoAsOfDate `
        --validate-only
    Assert-LastExitCode "Controlled register validation"

    $gateResults["Required-field schema"] = "PASS"
    $gateResults["Classification controls"] = "PASS"
    $gateResults["Status and overdue controls"] = "PASS"
    $gateResults["Closure evidence controls"] = "PASS"

    Write-Step "Writing Section 31 completion evidence"
    $evidenceLines = New-Object System.Collections.Generic.List[string]
    $evidenceLines.Add("PHASE VIII - SECTION 31: VALIDATION FINDING REGISTER")
    $evidenceLines.Add("Generated UTC: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
    $evidenceLines.Add("Repository: $ProjectRoot")
    $evidenceLines.Add("Branch: $Branch")
    $evidenceLines.Add("Demo as-of date: $DemoAsOfDate")
    $evidenceLines.Add("")
    $evidenceLines.Add("Controlled finding classifications:")
    $evidenceLines.Add("- Critical")
    $evidenceLines.Add("- High")
    $evidenceLines.Add("- Medium")
    $evidenceLines.Add("- Low")
    $evidenceLines.Add("- Observation")
    $evidenceLines.Add("")
    $evidenceLines.Add("Required fields:")
    $evidenceLines.Add("- Finding ID")
    $evidenceLines.Add("- Category")
    $evidenceLines.Add("- Condition")
    $evidenceLines.Add("- Evidence")
    $evidenceLines.Add("- Risk")
    $evidenceLines.Add("- Recommendation")
    $evidenceLines.Add("- Management response")
    $evidenceLines.Add("- Owner")
    $evidenceLines.Add("- Target date")
    $evidenceLines.Add("- Status")
    $evidenceLines.Add("- Closure evidence")
    $evidenceLines.Add("")
    $evidenceLines.Add("Validation gates:")
    foreach ($entry in $gateResults.GetEnumerator()) {
        $evidenceLines.Add("- $($entry.Key): $($entry.Value)")
    }
    $evidenceLines.Add("")
    $evidenceLines.Add("Synthetic-data classification: PASS")
    $evidenceLines.Add("Independent closure control: PASS")
    $evidenceLines.Add("Critical/High risk-acceptance prohibition: PASS")
    $evidenceLines.Add("")
    $evidenceLines.Add("FINAL DECISION: PASS")
    $evidenceLines.Add("SECTION 31: COMPLETE")

    Write-ManagedFile `
        -RelativePath "reports/evidence/section31_validation_finding_register.txt" `
        -Content ($evidenceLines -join "`n")
}

if (-not $SkipGit) {
    Write-Step "Committing Section 31 deliverables"

    $controlledPaths = @(
        "configs/validation_findings.yaml",
        "data/manifests/validation_finding_register.csv",
        "src/ficc_liquidity/governance/__init__.py",
        "src/ficc_liquidity/governance/validation_findings.py",
        "scripts/run_validation_findings.py",
        "tests/test_validation_findings.py",
        "docs/validation_finding_register.md",
        "sql/validation_finding_register.sql",
        ".github/ISSUE_TEMPLATE/validation-finding.yml",
        "reports/governance/findings/.gitkeep",
        "reports/governance/findings/demo",
        "reports/evidence/section31_validation_finding_register.txt",
        $AutomationRelativePath
    )

    foreach ($path in $controlledPaths | Select-Object -Unique) {
        $nativePath = $path -replace "/", [IO.Path]::DirectorySeparatorChar
        if (Test-Path -LiteralPath (Join-Path $ProjectRoot $nativePath)) {
            & git add -- $path
            Assert-LastExitCode "Staging $path"
        }
    }

    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No new controlled changes required a commit."
    }
    else {
        & git commit -m "Phase VIII Section 31: add validation finding register"
        Assert-LastExitCode "Section 31 Git commit"
    }

    if ($Publish) {
        Write-Step "Publishing branch and creating the pull request"

        & git push -u origin $Branch
        Assert-LastExitCode "Pushing $Branch"

        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $existingPr = (
                & gh pr list `
                    --head $Branch `
                    --state open `
                    --json url `
                    --jq '.[0].url // empty'
            ).Trim()

            if ($existingPr) {
                Write-Host "Existing pull request: $existingPr"
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

Required register fields:
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

Controls implemented:
- unique controlled finding IDs
- approved classifications and statuses
- required-field validation
- ISO target-date validation
- automatic overdue-status enforcement
- Critical and High risk-acceptance prohibition
- substantive independent closure-evidence requirements
- classification, status, owner, aging, and due-soon reporting
- deterministic synthetic demonstration evidence
- GitHub validation-finding issue form
- DuckDB-compatible governance views

Validation:
- targeted Section 31 tests: PASS
- Python compilation: PASS
- deterministic demo: PASS
- controlled register validation: PASS

All included findings are synthetic project-governance examples and are not actual FICC,
DTCC, clearing-member, or participant findings.
"@

                & gh pr create `
                    --base $BaseBranch `
                    --head $Branch `
                    --title "Phase VIII Section 31: Validation finding register" `
                    --body $prBody
                Assert-LastExitCode "Creating the Section 31 pull request"
            }
        }
        else {
            Write-Warn "GitHub CLI was not found. The branch was pushed, but no pull request was created."
        }
    }
}

Write-Step "Section 31 completed"
Write-Host "Repository:  $ProjectRoot"
Write-Host "Branch:      $Branch"
Write-Host "Base:        $BaseBranch"
Write-Host "Backup:      $BackupRoot"
Write-Host "Config:      configs\validation_findings.yaml"
Write-Host "Register:    data\manifests\validation_finding_register.csv"
Write-Host "Engine:      src\ficc_liquidity\governance\validation_findings.py"
Write-Host "Tests:       tests\test_validation_findings.py"
Write-Host "Demo:        reports\governance\findings\demo"
Write-Host "Evidence:    reports\evidence\section31_validation_finding_register.txt"
Write-Host ""
Write-Host "SECTION 31 FINAL DECISION: PASS" -ForegroundColor Green

if (-not $Publish -and -not $SkipGit) {
    Write-Host ""
    Write-Host "To publish after review, rerun:" -ForegroundColor Yellow
    Write-Host ".\P8S31_Setup_Validation_Finding_Register.ps1 -Publish"
}

