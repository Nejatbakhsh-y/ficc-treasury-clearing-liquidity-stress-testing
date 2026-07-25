<#
.SYNOPSIS
    Phase VIII, Section 30 monitoring thresholds and escalation automation.

.DESCRIPTION
    Creates the complete Section 30 implementation in the existing
    ficc-treasury-clearing-liquidity-stress-testing repository. The automation
    defines green, amber, and red thresholds; breach ownership; investigation
    and remediation requirements; model-change and revalidation triggers;
    monthly sign-off; annual independent validation; tests; SQL evidence
    structures; a deterministic demo run; and optional GitHub publication.

.EXAMPLE
    .\P8S30_FINAL_V3_Setup_Monitoring_Thresholds_Escalation.ps1

.EXAMPLE
    .\P8S30_FINAL_V3_Setup_Monitoring_Thresholds_Escalation.ps1 -Publish
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/21-monitoring-thresholds-escalation",
    [string]$BaseBranch = "main",
    [switch]$SkipGit,
    [switch]$SkipValidation,
    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
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
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    if (Test-Path -LiteralPath $destination) {
        $backup = Join-Path $BackupRoot $nativeRelativePath
        $backupParent = Split-Path -Parent $backup
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        Copy-Item -LiteralPath $destination -Destination $backup -Force
    }

    Set-Content -LiteralPath $destination -Value $Content -Encoding utf8
    Write-Host "WROTE  $RelativePath"
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

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Repository folder not found: $ProjectRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "pyproject.toml"))) {
    throw "pyproject.toml was not found. Confirm that ProjectRoot is the repository root."
}

Set-Location $ProjectRoot
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupRoot = Join-Path $ProjectRoot "reports\evidence\backups\section30_$timestamp"

$Section30ManagedPaths = @(
    "configs/monitoring_governance.yaml",
    "data/manifests/monitoring_threshold_register.csv",
    "docs/monitoring_thresholds_and_escalation.md",
    "src/ficc_liquidity/monitoring/__init__.py",
    "src/ficc_liquidity/monitoring/governance.py",
    "scripts/run_monitoring_governance.py",
    "tests/test_monitoring_governance.py",
    "sql/monitoring_governance.sql",
    "reports/monitoring/governance/.gitkeep"
)

if (-not $SkipGit) {
    Write-Step "Preparing Git branch $Branch"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git was not found. Install Git and reopen VS Code."
    }

    & git rev-parse --is-inside-work-tree | Out-Null
    Assert-LastExitCode "Git repository validation"

    $trackedPaths = @(
        @(& git diff --name-only) + @(& git diff --cached --name-only)
    ) | Where-Object { $_ } | Sort-Object -Unique

    if (@($trackedPaths).Count -gt 0) {
        $unrelatedTrackedPaths = @(
            $trackedPaths | Where-Object { $_ -notin $Section30ManagedPaths }
        )

        if (@($unrelatedTrackedPaths).Count -gt 0) {
            $details = $unrelatedTrackedPaths -join "`n"
            throw @"
Unrelated tracked changes already exist in the repository.
Commit, discard, or finish them before running Section 30.

$details
"@
        }

        Write-Step "Removing incomplete Section 30 changes from the previous run"
        foreach ($path in $trackedPaths) {
            & git restore --staged --worktree -- $path
            Assert-LastExitCode "Restoring incomplete Section 30 file $path"
            Write-Host "RESTORED $path"
        }
    }

    & git switch $BaseBranch
    Assert-LastExitCode "Switching to base branch $BaseBranch"

    & git pull --ff-only origin $BaseBranch
    Assert-LastExitCode "Updating base branch $BaseBranch"

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
            & git switch -c $Branch
            Assert-LastExitCode "Creating branch $Branch"
        }
    }
}

Write-Step "Creating Section 30 controlled files"

Write-ManagedFile -RelativePath 'configs/monitoring_governance.yaml' -Content @'
governance:
  schema_version: "1.0"
  status_mapping:
    PASS: GREEN
    WARN: AMBER
    FAIL: RED

  escalation_levels:
    GREEN:
      investigation_required: false
      use_restriction_assessment: false
      acknowledgment_business_days:
      investigation_business_days:
      remediation_business_days:
      escalation_route:
        - Monitoring Owner
    AMBER:
      investigation_required: true
      use_restriction_assessment: false
      acknowledgment_business_days: 2
      investigation_business_days: 5
      remediation_business_days: 20
      escalation_route:
        - Monitoring Owner
        - Model Owner
        - Model Risk Reviewer
    RED:
      investigation_required: true
      use_restriction_assessment: true
      acknowledgment_business_days: 1
      investigation_business_days: 2
      remediation_business_days: 10
      escalation_route:
        - Monitoring Owner
        - Model Owner
        - Model Risk Management
        - Senior Management

  control_ownership:
    default:
      primary_owner: Model Monitoring Owner
      secondary_owner: Model Owner
      investigation_requirements:
        - Reproduce the breach from frozen inputs
        - Validate source lineage and configuration
        - Quantify model and liquidity-risk impact
        - Document root cause and disposition
      required_evidence:
        - Frozen source data and hashes
        - Reproduction log
        - Root-cause memorandum
        - Closure verification
    data_completeness:
      primary_owner: Data Owner
      secondary_owner: Model Monitoring Owner
      red_remediation_business_days: 5
      investigation_requirements:
        - Identify missing fields, dates, or source files
        - Compare source delivery with the data contract
        - Determine whether calculations must be rerun
      required_evidence:
        - Data-quality exception report
        - Source lineage
        - Corrected dataset or approved waiver
    schema_changes:
      primary_owner: Data Owner
      secondary_owner: Model Developer
      red_remediation_business_days: 5
      investigation_requirements:
        - Compare the observed schema with the approved contract
        - Identify upstream or code changes
        - Test backward compatibility
      required_evidence:
        - Schema diff
        - Change approval
        - Regression-test evidence
    missing_observations:
      primary_owner: Data Owner
      secondary_owner: Model Monitoring Owner
      investigation_requirements:
        - Reconcile expected and observed business dates
        - Confirm publication-calendar exceptions
        - Assess interpolation or carry-forward use
      required_evidence:
        - Missing-date register
        - Source confirmation
        - Corrected data or approved treatment
    historical_range_breaches:
      primary_owner: Model Monitoring Owner
      secondary_owner: Market Risk Subject-Matter Expert
      investigation_requirements:
        - Distinguish market stress from data error
        - Compare with source publications and historical windows
        - Assess calibration and scenario implications
      required_evidence:
        - Outlier analysis
        - Source cross-check
        - Impact assessment
    parameter_changes:
      primary_owner: Model Owner
      secondary_owner: Model Risk Management
      red_remediation_business_days: 5
      investigation_requirements:
        - Reconcile current parameters with the approved inventory
        - Confirm authorization and implementation date
        - Quantify output impact
      required_evidence:
        - Parameter diff
        - Approval record
        - Impact and regression tests
    exposure_concentration:
      primary_owner: Liquidity Risk Owner
      secondary_owner: Model Owner
      investigation_requirements:
        - Identify concentration drivers
        - Recalculate Cover 1 and Cover 2 outcomes
        - Assess resource and scenario adequacy
      required_evidence:
        - Concentration attribution
        - Cover analysis
        - Management disposition
    lcr_distribution:
      primary_owner: Liquidity Risk Owner
      secondary_owner: Model Risk Management
      red_remediation_business_days: 5
      investigation_requirements:
        - Reconcile stressed requirement and available resources
        - Identify members and scenarios below threshold
        - Assess model-use restrictions and liquidity action
      required_evidence:
        - LCR tail analysis
        - Independent reconciliation
        - Use-restriction decision
    scenario_rank_stability:
      primary_owner: Model Owner
      secondary_owner: Scenario Governance Committee
      investigation_requirements:
        - Reconcile scenario definitions and parameters
        - Explain rank reversals economically
        - Test deterministic benchmark ordering
      required_evidence:
        - Scenario rank comparison
        - Parameter lineage
        - Economic rationale
    component_contribution_drift:
      primary_owner: Model Monitoring Owner
      secondary_owner: Model Developer
      investigation_requirements:
        - Attribute drift to exposures, inputs, or code
        - Reconcile Section 19 components
        - Test for double counting
      required_evidence:
        - Component attribution
        - Reconciliation output
        - Code or data change record
    sensitivity_changes:
      primary_owner: Model Validation Owner
      secondary_owner: Model Owner
      investigation_requirements:
        - Reproduce sensitivity results across seeds
        - Compare with deterministic benchmarks
        - Assess parameter instability or nonlinear response
      required_evidence:
        - Sensitivity comparison
        - Seed-stability results
        - Benchmark analysis
    reconciliation_failures:
      primary_owner: Model Validation Owner
      secondary_owner: Model Developer
      red_remediation_business_days: 3
      investigation_requirements:
        - Isolate production and independent implementation differences
        - Reconcile inputs, formulas, rounding, and aggregation
        - Determine whether reported results are reliable
      required_evidence:
        - Line-item reconciliation
        - Defect record
        - Independent closure test

  triggers:
    model_change_controls:
      - schema_changes
      - parameter_changes
      - lcr_distribution
      - scenario_rank_stability
      - component_contribution_drift
      - sensitivity_changes
      - reconciliation_failures
    amber_model_change_controls:
      - schema_changes
      - parameter_changes
      - reconciliation_failures
    red_repeat_lookback_months: 3
    red_occurrences_for_revalidation: 2
    amber_repeat_lookback_months: 6
    amber_occurrences_for_revalidation: 3

  monthly_sign_off:
    green_status: READY_FOR_SIGNATURE
    amber_status: CONDITIONAL_PENDING_BREACH_DISPOSITION
    red_status: BLOCKED_PENDING_RED_BREACH_DECISION
    due_business_days_after_month_end: 10
    required_roles:
      - Data Owner
      - Model Monitoring Owner
      - Model Owner
      - Model Risk Reviewer
    required_evidence:
      - Final Section 29 scorecard
      - Section 30 breach register
      - Investigation and remediation status
      - Approved parameter and code changes
      - Reconciliation evidence
      - Sign-off decisions

  annual_independent_validation:
    required: true
    maximum_interval_months: 12
    due_soon_calendar_days: 60
    independent_from_development: true
    minimum_scope:
      - Conceptual soundness
      - Independent implementation verification
      - Outcomes and benchmark analysis
      - Sensitivity analysis
      - Uncertainty and limitations
      - Monitoring performance and threshold effectiveness
      - Open findings and remediation validation
'@

Write-ManagedFile -RelativePath 'data/manifests/monitoring_threshold_register.csv' -Content @'
control,metric,direction,green,amber,red,primary_owner,secondary_owner,model_change_trigger,revalidation_trigger
data_completeness,minimum_required_field_completeness,lower_is_worse,">=0.995",">=0.980 and <0.995","<0.980",Data Owner,Model Monitoring Owner,false,"critical red or persistence"
schema_changes,schema_issue_count,higher_is_worse,"0",not_applicable,">=1",Data Owner,Model Developer,true,"critical red or persistence"
missing_observations,missing_business_days,higher_is_worse,"0","1-2",">=3",Data Owner,Model Monitoring Owner,false,"critical red or persistence"
historical_range_breaches,breach_rate,higher_is_worse,"<0.010",">=0.010 and <0.050",">=0.050",Model Monitoring Owner,Market Risk Subject-Matter Expert,false,"critical red or persistence"
parameter_changes,maximum_relative_change,higher_is_worse,"<0.050 and no structural change",">=0.050 and <0.150",">=0.150 or structural change",Model Owner,Model Risk Management,true,"critical red or persistence"
exposure_concentration,largest_member_share_and_hhi,higher_is_worse,"share<0.200 and HHI<0.180","share>=0.200 or HHI>=0.180","share>=0.300 or HHI>=0.250",Liquidity Risk Owner,Model Owner,false,"critical red or persistence"
lcr_distribution,lcr_tail_breach_and_drift,lower_or_higher_is_worse,"p05>1.050 and breach<0.001 and drift<0.100",intermediate,"p05<=1.000 or breach>=0.010 or drift>=0.250",Liquidity Risk Owner,Model Risk Management,true,"critical red or persistence"
scenario_rank_stability,rank_correlation,lower_is_worse,">0.900",">0.750 and <=0.900","<=0.750",Model Owner,Scenario Governance Committee,true,"critical red or persistence"
component_contribution_drift,maximum_absolute_share_change,higher_is_worse,"<0.050",">=0.050 and <0.100",">=0.100",Model Monitoring Owner,Model Developer,true,"critical red or persistence"
sensitivity_changes,maximum_relative_change,higher_is_worse,"<0.150",">=0.150 and <0.300",">=0.300",Model Validation Owner,Model Owner,true,"critical red or persistence"
reconciliation_failures,failure_count,higher_is_worse,"0","1",">=2",Model Validation Owner,Model Developer,true,"critical red or persistence"
'@

Write-ManagedFile -RelativePath 'docs/monitoring_thresholds_and_escalation.md' -Content @'
# Section 30 — Monitoring Thresholds and Escalation

## Objective

Section 30 converts the Section 29 monthly monitoring scorecard into a controlled governance
decision. It assigns green, amber, and red traffic lights; breach ownership; investigation and
remediation dates; model-change and revalidation triggers; monthly sign-off requirements; and
annual independent-validation status.

This project uses public market data and synthetic clearing-member portfolios. The thresholds
below are controlled benchmark thresholds for this repository. They are not represented as
confidential FICC production thresholds, actual participant outcomes, or DTCC policy.

## Controlled deliverables

- `configs/monitoring_governance.yaml`
- `data/manifests/monitoring_threshold_register.csv`
- `src/ficc_liquidity/monitoring/governance.py`
- `scripts/run_monitoring_governance.py`
- `tests/test_monitoring_governance.py`
- `sql/monitoring_governance.sql`
- `reports/monitoring/governance/`

## Traffic-light thresholds

Section 29 computes `PASS`, `WARN`, and `FAIL`. Section 30 maps those results to `GREEN`,
`AMBER`, and `RED` respectively. The controlled quantitative interpretation is:

| Control | Green | Amber | Red |
|---|---|---|---|
| Data completeness | Minimum required-field completeness at least 99.5% | At least 98.0% but below 99.5% | Below 98.0% |
| Schema changes | No schema issue | Not used | Any missing required field or invalid controlled type |
| Missing observations | 0 missing business days | 1–2 missing business days | 3 or more missing business days |
| Historical-range breaches | Breach rate below 1% | At least 1% but below 5% | At least 5% |
| Parameter changes | Relative change below 5% and no structural change | At least 5% but below 15% | At least 15%, or any categorical/add/remove change |
| Exposure concentration | Largest share below 20% and HHI below 0.18 | Largest share 20%–<30% or HHI 0.18–<0.25 | Largest share at least 30% or HHI at least 0.25 |
| LCR distribution | LCR fifth percentile above 1.05, breach rate below 0.1%, and mean drift below 10% | Intermediate range | Fifth percentile at or below 1.00, breach rate at least 1%, or mean drift at least 25% |
| Scenario-rank stability | Rank correlation above 0.90 | Above 0.75 through 0.90 | At or below 0.75 |
| Component-contribution drift | Maximum share change below 5% | At least 5% but below 10% | At least 10% |
| Sensitivity changes | Maximum relative change below 15% | At least 15% but below 30% | At least 30% |
| Reconciliation failures | 0 failures | 1 failure | 2 or more failures |

Where a control combines multiple measures, the worst applicable traffic light governs.

## Escalation standards

| Traffic light | Acknowledge | Investigation | Remediation target | Governance treatment |
|---|---:|---:|---:|---|
| Green | Not required | Not required | Not applicable | Retain evidence and proceed to monthly sign-off |
| Amber | 2 business days | 5 business days | 20 business days | Owner analysis, documented disposition, Model Owner and Model Risk review |
| Red | 1 business day | 2 business days | 10 business days, subject to tighter control-specific limits | Immediate escalation, model-use restriction assessment, management acceptance, and blocked sign-off until disposition |

The YAML file contains tighter red remediation dates for data completeness, schema changes,
parameter changes, LCR distribution, and reconciliation failures.

## Breach ownership

Each control has a named primary and secondary owner. Primary owners perform the investigation
and maintain the evidence package. Secondary owners challenge the analysis, approve the
disposition, and confirm whether model change, use restriction, or revalidation is required.

Every amber or red breach must document:

1. Reproduction from frozen source data and configuration.
2. Source-lineage, schema, parameter, and code-change checks.
3. Quantitative impact on stressed liquidity requirements, available resources, LCR, Cover 1,
   and Cover 2 where relevant.
4. Root cause, interim control, remediation owner, target date, and closure criteria.
5. Independent closure verification for high or critical issues.

## Model-change triggers

A controlled model-change assessment is required when an amber or red result indicates a
potential change to:

- Data schema or controlled input contract.
- Model parameters or parameter structure.
- Liquidity adequacy logic or available-resource treatment.
- Scenario definitions, severity, or rank ordering.
- Stress-component calculation or aggregation.
- Sensitivity behavior.
- Production-to-independent reconciliation.

Any approved change must be classified as non-material or material, version-controlled, tested,
approved before use, and entered in the change log.

## Revalidation triggers

Revalidation is required when any of the following occurs:

- A critical control is red.
- The same control is red twice within the configured three-month lookback.
- The same control is amber three times within the configured six-month lookback.
- A material model change is approved.
- Annual independent validation is overdue or cannot be evidenced.
- Model Risk Management determines that cumulative changes or unresolved findings are material.

Revalidation scope must be proportionate to the trigger. A targeted revalidation may be used for
a localized change; a full validation is required for material methodology, architecture, data,
scenario, or resource-eligibility changes.

## Monthly sign-off

Monthly sign-off is due within 10 business days after month-end and requires:

- Data Owner.
- Model Monitoring Owner.
- Model Owner.
- Model Risk Reviewer.

Green results are ready for signature. Amber results are conditional on documented breach
disposition. Red results block sign-off until the model-use decision, remediation plan, and
management acceptance are documented.

## Annual independent validation

Independent validation must occur at least every 12 months and remain independent from model
development. The minimum scope includes conceptual soundness, independent implementation,
outcomes and benchmarks, sensitivity, uncertainty and limitations, monitoring effectiveness,
and closure testing of prior findings.

The governance engine compares the as-of date with the last completed validation date and
classifies the annual cycle as `CURRENT`, `DUE_SOON`, `OVERDUE`, or `NOT_EVIDENCED`.

## Execution

```powershell
.\.venv\Scripts\python.exe scripts\run_monitoring_governance.py `
  --scorecard reports\monitoring\monthly\monthly_monitoring_scorecard_20260630.csv `
  --history reports\monitoring\governance\governance_history.csv `
  --change-log reports\monitoring\governance\approved_change_log.csv `
  --as-of-date 2026-06-30 `
  --last-validation-date 2026-01-15 `
  --output-dir reports\monitoring\governance
```

Use `--demo` for the deterministic synthetic smoke test. Use `--fail-on-red` when a red result
must return a nonzero process exit code for a CI or operating-control gate.
'@

Write-ManagedFile -RelativePath 'src/ficc_liquidity/monitoring/__init__.py' -Content @'
"""Model monitoring package."""

from ficc_liquidity.monitoring.governance import (
    GovernanceSummary,
    MonitoringGovernanceEngine,
)
from ficc_liquidity.monitoring.monthly import (
    MonitoringResult,
    MonitoringSummary,
    MonthlyMonitoringEngine,
    build_demo_inputs,
)

__all__ = [
    "GovernanceSummary",
    "MonitoringGovernanceEngine",
    "MonitoringResult",
    "MonitoringSummary",
    "MonthlyMonitoringEngine",
    "build_demo_inputs",
]
'@

Write-ManagedFile -RelativePath 'src/ficc_liquidity/monitoring/governance.py' -Content @'
"""Monitoring thresholds, escalation, and validation-governance controls."""

from __future__ import annotations

import argparse
import json
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, ClassVar

import pandas as pd
import yaml


TRAFFIC_ORDER = {"GREEN": 0, "AMBER": 1, "RED": 2}


@dataclass(frozen=True)
class GovernanceSummary:
    """Run-level governance decision."""

    as_of_date: str
    overall_traffic_light: str
    green_count: int
    amber_count: int
    red_count: int
    model_change_trigger_count: int
    revalidation_required: bool
    revalidation_reasons: tuple[str, ...]
    monthly_sign_off_status: str
    annual_validation_status: str
    annual_validation_due_date: str | None


class MonitoringGovernanceEngine:
    """Translate Section 29 monitoring results into controlled governance actions."""

    required_scorecard_columns: ClassVar[set[str]] = {
        "control",
        "metric",
        "value",
        "warning_threshold",
        "failure_threshold",
        "status",
        "severity",
        "message",
        "details",
    }

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.config = dict(config["governance"])
        self.status_mapping = {
            str(key).upper(): str(value).upper()
            for key, value in dict(self.config["status_mapping"]).items()
        }
        self.levels = {
            str(key).upper(): dict(value)
            for key, value in dict(self.config["escalation_levels"]).items()
        }
        self.ownership = {
            str(key): dict(value)
            for key, value in dict(self.config["control_ownership"]).items()
        }
        self.trigger_config = dict(self.config["triggers"])
        self.sign_off_config = dict(self.config["monthly_sign_off"])
        self.validation_config = dict(self.config["annual_independent_validation"])

    @classmethod
    def from_yaml(cls, path: str | Path) -> MonitoringGovernanceEngine:
        """Create the engine from the controlled YAML file."""
        with Path(path).open("r", encoding="utf-8-sig") as stream:
            config = yaml.safe_load(stream)
        return cls(config)

    def evaluate(
        self,
        scorecard: pd.DataFrame,
        *,
        as_of_date: str,
        history: pd.DataFrame | None = None,
        last_validation_date: str | None = None,
        change_log: pd.DataFrame | None = None,
    ) -> tuple[pd.DataFrame, GovernanceSummary]:
        """Create a breach-action register and governance summary."""
        missing = sorted(self.required_scorecard_columns - set(scorecard.columns))
        if missing:
            raise ValueError(f"Scorecard is missing required columns: {', '.join(missing)}")

        as_of = pd.Timestamp(as_of_date).normalize()
        normalized_history = self._normalize_history(history)
        material_change = self._has_material_change(change_log)

        actions: list[dict[str, Any]] = []
        revalidation_reasons: set[str] = set()
        for row in scorecard.to_dict(orient="records"):
            action = self._build_action(
                row,
                as_of=as_of,
                history=normalized_history,
            )
            actions.append(action)
            if bool(action["revalidation_trigger"]):
                revalidation_reasons.add(str(action["revalidation_reason"]))

        annual_status, annual_due = self._annual_validation_status(
            as_of=as_of,
            last_validation_date=last_validation_date,
        )
        if annual_status in {"OVERDUE", "NOT_EVIDENCED"}:
            revalidation_reasons.add(f"annual_independent_validation:{annual_status.lower()}")
        if material_change:
            revalidation_reasons.add("approved_material_model_change")

        action_frame = pd.DataFrame(actions)
        light_counts = action_frame["traffic_light"].value_counts().to_dict()
        red_count = int(light_counts.get("RED", 0))
        amber_count = int(light_counts.get("AMBER", 0))
        green_count = int(light_counts.get("GREEN", 0))
        overall = max(
            (str(value) for value in action_frame["traffic_light"]),
            key=lambda value: TRAFFIC_ORDER[value],
        )
        model_change_count = int(action_frame["model_change_trigger"].astype(bool).sum())
        sign_off_status = self._monthly_sign_off_status(red_count, amber_count)

        summary = GovernanceSummary(
            as_of_date=as_of.date().isoformat(),
            overall_traffic_light=overall,
            green_count=green_count,
            amber_count=amber_count,
            red_count=red_count,
            model_change_trigger_count=model_change_count,
            revalidation_required=bool(revalidation_reasons),
            revalidation_reasons=tuple(sorted(revalidation_reasons)),
            monthly_sign_off_status=sign_off_status,
            annual_validation_status=annual_status,
            annual_validation_due_date=annual_due,
        )
        return action_frame, summary

    def write_outputs(
        self,
        actions: pd.DataFrame,
        summary: GovernanceSummary,
        output_dir: str | Path,
    ) -> dict[str, Path]:
        """Write the controlled governance evidence package."""
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        stamp = summary.as_of_date.replace("-", "")

        register_path = output_path / f"monitoring_breach_register_{stamp}.csv"
        summary_path = output_path / f"monitoring_governance_summary_{stamp}.json"
        report_path = output_path / f"monitoring_escalation_report_{stamp}.md"
        signoff_path = output_path / f"monthly_signoff_template_{stamp}.csv"

        actions.to_csv(register_path, index=False)
        summary_path.write_text(
            json.dumps(asdict(summary), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        report_path.write_text(
            self._render_markdown(actions, summary),
            encoding="utf-8",
        )
        self._build_signoff_template(summary).to_csv(signoff_path, index=False)
        return {
            "breach_register": register_path,
            "summary": summary_path,
            "report": report_path,
            "signoff_template": signoff_path,
        }

    def _build_action(
        self,
        row: Mapping[str, Any],
        *,
        as_of: pd.Timestamp,
        history: pd.DataFrame | None,
    ) -> dict[str, Any]:
        status = str(row["status"]).upper()
        if status not in self.status_mapping:
            raise ValueError(f"Unsupported monitoring status: {status}")
        traffic_light = self.status_mapping[status]
        level = self.levels[traffic_light]
        control = str(row["control"])
        owner = self.ownership.get(control, self.ownership["default"])
        severity = str(row["severity"])

        investigation_required = bool(level["investigation_required"])
        model_change_trigger = self._model_change_trigger(control, traffic_light)
        repeated_trigger, repeated_reason = self._repeated_breach_trigger(
            control=control,
            traffic_light=traffic_light,
            as_of=as_of,
            history=history,
        )
        critical_red = traffic_light == "RED" and severity.lower() == "critical"
        revalidation_trigger = critical_red or repeated_trigger
        revalidation_reason = ""
        if critical_red:
            revalidation_reason = f"{control}:critical_red_breach"
        elif repeated_trigger:
            revalidation_reason = repeated_reason

        return {
            "as_of_date": as_of.date().isoformat(),
            "control": control,
            "metric": str(row["metric"]),
            "value": row["value"],
            "warning_threshold": row["warning_threshold"],
            "failure_threshold": row["failure_threshold"],
            "monitoring_status": status,
            "traffic_light": traffic_light,
            "severity": severity,
            "primary_owner": str(owner["primary_owner"]),
            "secondary_owner": str(owner["secondary_owner"]),
            "escalation_route": " -> ".join(str(item) for item in level["escalation_route"]),
            "acknowledgment_due_date": self._due_date(
                as_of,
                level.get("acknowledgment_business_days"),
                traffic_light,
            ),
            "investigation_due_date": self._due_date(
                as_of,
                level.get("investigation_business_days"),
                traffic_light,
            ),
            "remediation_due_date": self._remediation_due_date(
                as_of=as_of,
                level=level,
                owner=owner,
                traffic_light=traffic_light,
            ),
            "investigation_required": investigation_required,
            "use_restriction_assessment": bool(level["use_restriction_assessment"]),
            "model_change_trigger": model_change_trigger,
            "revalidation_trigger": revalidation_trigger,
            "revalidation_reason": revalidation_reason,
            "required_investigation": " | ".join(
                str(item) for item in owner["investigation_requirements"]
            ),
            "required_evidence": " | ".join(str(item) for item in owner["required_evidence"]),
            "message": str(row["message"]),
            "details": str(row["details"]),
            "disposition_status": "NO_ACTION" if traffic_light == "GREEN" else "OPEN",
            "management_acceptance_required": traffic_light == "RED",
        }

    def _model_change_trigger(self, control: str, traffic_light: str) -> bool:
        if traffic_light == "GREEN":
            return False
        controls = set(str(item) for item in self.trigger_config["model_change_controls"])
        amber_controls = set(
            str(item) for item in self.trigger_config["amber_model_change_controls"]
        )
        return control in controls and (traffic_light == "RED" or control in amber_controls)

    def _repeated_breach_trigger(
        self,
        *,
        control: str,
        traffic_light: str,
        as_of: pd.Timestamp,
        history: pd.DataFrame | None,
    ) -> tuple[bool, str]:
        if history is None or history.empty or traffic_light == "GREEN":
            return False, ""

        same_control = history.loc[history["control"].astype(str) == control].copy()
        if same_control.empty:
            return False, ""

        if traffic_light == "RED":
            lookback = int(self.trigger_config["red_repeat_lookback_months"])
            start = as_of - pd.DateOffset(months=lookback)
            prior_red = same_control.loc[
                (same_control["as_of_date"] >= start)
                & (same_control["as_of_date"] < as_of)
                & (same_control["traffic_light"].astype(str).str.upper() == "RED")
            ]
            threshold = int(self.trigger_config["red_occurrences_for_revalidation"]) - 1
            if len(prior_red) >= threshold:
                return True, f"{control}:repeated_red_breach"

        if traffic_light == "AMBER":
            lookback = int(self.trigger_config["amber_repeat_lookback_months"])
            start = as_of - pd.DateOffset(months=lookback)
            prior_amber = same_control.loc[
                (same_control["as_of_date"] >= start)
                & (same_control["as_of_date"] < as_of)
                & (same_control["traffic_light"].astype(str).str.upper() == "AMBER")
            ]
            threshold = int(self.trigger_config["amber_occurrences_for_revalidation"]) - 1
            if len(prior_amber) >= threshold:
                return True, f"{control}:persistent_amber_breach"

        return False, ""

    def _annual_validation_status(
        self,
        *,
        as_of: pd.Timestamp,
        last_validation_date: str | None,
    ) -> tuple[str, str | None]:
        if not last_validation_date:
            return "NOT_EVIDENCED", None
        last_validation = pd.Timestamp(last_validation_date).normalize()
        interval = int(self.validation_config["maximum_interval_months"])
        due = last_validation + pd.DateOffset(months=interval)
        due_date = due.date().isoformat()
        if as_of > due:
            return "OVERDUE", due_date
        warning_days = int(self.validation_config["due_soon_calendar_days"])
        if (due - as_of).days <= warning_days:
            return "DUE_SOON", due_date
        return "CURRENT", due_date

    def _monthly_sign_off_status(self, red_count: int, amber_count: int) -> str:
        if red_count:
            return str(self.sign_off_config["red_status"])
        if amber_count:
            return str(self.sign_off_config["amber_status"])
        return str(self.sign_off_config["green_status"])

    def _build_signoff_template(self, summary: GovernanceSummary) -> pd.DataFrame:
        roles = [str(item) for item in self.sign_off_config["required_roles"]]
        return pd.DataFrame(
            {
                "as_of_date": [summary.as_of_date] * len(roles),
                "role": roles,
                "signer_name": [""] * len(roles),
                "decision": ["PENDING"] * len(roles),
                "signature_date": [""] * len(roles),
                "comments": [""] * len(roles),
                "governance_status": [summary.monthly_sign_off_status] * len(roles),
            }
        )

    def _render_markdown(
        self,
        actions: pd.DataFrame,
        summary: GovernanceSummary,
    ) -> str:
        lines = [
            "# Monthly Monitoring Threshold and Escalation Report",
            "",
            f"- As-of date: {summary.as_of_date}",
            f"- Overall traffic light: **{summary.overall_traffic_light}**",
            f"- Green controls: {summary.green_count}",
            f"- Amber controls: {summary.amber_count}",
            f"- Red controls: {summary.red_count}",
            f"- Monthly sign-off status: **{summary.monthly_sign_off_status}**",
            f"- Revalidation required: **{summary.revalidation_required}**",
            f"- Annual independent validation: **{summary.annual_validation_status}**",
            "",
            "## Open breaches",
            "",
        ]
        open_actions = actions.loc[actions["traffic_light"] != "GREEN"]
        if open_actions.empty:
            lines.append("No amber or red breaches were identified.")
        else:
            lines.extend(
                [
                    "| Control | Light | Severity | Owner | Investigation due | Remediation due |",
                    "|---|---|---|---|---|---|",
                ]
            )
            for row in open_actions.to_dict(orient="records"):
                lines.append(
                    "| {control} | {traffic_light} | {severity} | {primary_owner} | "
                    "{investigation_due_date} | {remediation_due_date} |".format(**row)
                )

        lines.extend(["", "## Revalidation reasons", ""])
        if summary.revalidation_reasons:
            lines.extend(f"- {reason}" for reason in summary.revalidation_reasons)
        else:
            lines.append("- None.")

        lines.extend(
            [
                "",
                "## Required governance disposition",
                "",
                "All amber and red items require documented root-cause analysis, evidence, "
                "owner assignment, target dates, and closure verification. Red items additionally "
                "require a model-use restriction assessment and management acceptance before "
                "monthly sign-off.",
                "",
                "The thresholds in this project are controlled benchmark thresholds for a "
                "public-data, synthetic-member implementation. They are not represented as "
                "confidential FICC production thresholds or participant outcomes.",
                "",
            ]
        )
        return "\n".join(lines)

    @staticmethod
    def _normalize_history(history: pd.DataFrame | None) -> pd.DataFrame | None:
        if history is None:
            return None
        required = {"as_of_date", "control", "traffic_light"}
        missing = sorted(required - set(history.columns))
        if missing:
            raise ValueError(f"History is missing required columns: {', '.join(missing)}")
        normalized = history.copy()
        normalized["as_of_date"] = pd.to_datetime(
            normalized["as_of_date"],
            errors="coerce",
        )
        return normalized.dropna(subset=["as_of_date"])

    @staticmethod
    def _has_material_change(change_log: pd.DataFrame | None) -> bool:
        if change_log is None or change_log.empty:
            return False
        if "material_change" not in change_log.columns:
            raise ValueError("Change log requires a material_change column.")
        values = change_log["material_change"]
        if pd.api.types.is_bool_dtype(values):
            return bool(values.fillna(False).any())
        normalized = values.astype(str).str.strip().str.lower()
        return bool(normalized.isin({"true", "1", "yes", "y"}).any())

    @staticmethod
    def _due_date(
        as_of: pd.Timestamp,
        business_days: Any,
        traffic_light: str,
    ) -> str:
        if traffic_light == "GREEN" or business_days is None:
            return ""
        due = as_of + pd.offsets.BDay(int(business_days))
        return due.date().isoformat()

    @staticmethod
    def _remediation_due_date(
        *,
        as_of: pd.Timestamp,
        level: Mapping[str, Any],
        owner: Mapping[str, Any],
        traffic_light: str,
    ) -> str:
        if traffic_light == "GREEN":
            return ""
        override_key = f"{traffic_light.lower()}_remediation_business_days"
        business_days = owner.get(
            override_key,
            level.get("remediation_business_days"),
        )
        due = as_of + pd.offsets.BDay(int(business_days))
        return due.date().isoformat()


def _read_table(path: str | Path) -> pd.DataFrame:
    source = Path(path)
    suffix = source.suffix.lower()
    if suffix == ".csv":
        return pd.read_csv(source)
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(source)
    raise ValueError(f"Unsupported table format: {source}")


def build_demo_scorecard() -> pd.DataFrame:
    """Build deterministic monitoring results for the governance smoke test."""
    return pd.DataFrame(
        [
            {
                "control": "data_completeness",
                "metric": "minimum_required_field_completeness",
                "value": 0.997,
                "warning_threshold": 0.995,
                "failure_threshold": 0.980,
                "status": "PASS",
                "severity": "High",
                "message": "Minimum non-null ratio across required fields.",
                "details": "",
            },
            {
                "control": "exposure_concentration",
                "metric": "largest_member_share",
                "value": 0.225,
                "warning_threshold": 0.200,
                "failure_threshold": 0.300,
                "status": "WARN",
                "severity": "High",
                "message": "Largest member share of absolute exposure.",
                "details": "hhi=0.185000",
            },
            {
                "control": "lcr_distribution",
                "metric": "lcr_5th_percentile",
                "value": 0.98,
                "warning_threshold": 1.05,
                "failure_threshold": 1.00,
                "status": "FAIL",
                "severity": "Critical",
                "message": "Lower-tail LCR control.",
                "details": "breach_rate=0.012",
            },
        ]
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Apply Section 30 monitoring thresholds and escalation governance."
    )
    parser.add_argument("--scorecard", help="Section 29 scorecard CSV or Parquet.")
    parser.add_argument(
        "--config",
        default="configs/monitoring_governance.yaml",
        help="Controlled governance YAML.",
    )
    parser.add_argument("--history", help="Prior governance history CSV or Parquet.")
    parser.add_argument("--change-log", help="Approved change log CSV or Parquet.")
    parser.add_argument("--as-of-date", required=False)
    parser.add_argument("--last-validation-date")
    parser.add_argument(
        "--output-dir",
        default="reports/monitoring/governance",
    )
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--fail-on-red", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.demo:
        scorecard = build_demo_scorecard()
        as_of_date = args.as_of_date or "2026-06-30"
        last_validation_date = args.last_validation_date or "2026-01-15"
    else:
        if not args.scorecard:
            raise ValueError("--scorecard is required unless --demo is used.")
        if not args.as_of_date:
            raise ValueError("--as-of-date is required unless --demo is used.")
        scorecard = _read_table(args.scorecard)
        as_of_date = args.as_of_date
        last_validation_date = args.last_validation_date

    history = _read_table(args.history) if args.history else None
    change_log = _read_table(args.change_log) if args.change_log else None
    engine = MonitoringGovernanceEngine.from_yaml(args.config)
    actions, summary = engine.evaluate(
        scorecard,
        as_of_date=as_of_date,
        history=history,
        last_validation_date=last_validation_date,
        change_log=change_log,
    )
    paths = engine.write_outputs(actions, summary, args.output_dir)
    print(json.dumps({key: str(value) for key, value in paths.items()}, indent=2))
    print(json.dumps(asdict(summary), indent=2))
    return 2 if args.fail_on_red and summary.red_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-ManagedFile -RelativePath 'scripts/run_monitoring_governance.py' -Content @'
"""Command-line wrapper for Section 30 monitoring governance."""

from ficc_liquidity.monitoring.governance import main


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-ManagedFile -RelativePath 'tests/test_monitoring_governance.py' -Content @'
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

from ficc_liquidity.monitoring.governance import (
    MonitoringGovernanceEngine,
    build_demo_scorecard,
    main,
)


CONFIG_PATH = Path("configs/monitoring_governance.yaml")


def test_green_amber_red_mapping_and_due_dates() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    actions, summary = engine.evaluate(
        build_demo_scorecard(),
        as_of_date="2026-06-30",
        last_validation_date="2026-01-15",
    )

    by_control = actions.set_index("control")
    assert by_control.loc["data_completeness", "traffic_light"] == "GREEN"
    assert by_control.loc["exposure_concentration", "traffic_light"] == "AMBER"
    assert by_control.loc["lcr_distribution", "traffic_light"] == "RED"
    assert by_control.loc["exposure_concentration", "acknowledgment_due_date"] == "2026-07-02"
    assert by_control.loc["lcr_distribution", "remediation_due_date"] == "2026-07-07"
    assert summary.overall_traffic_light == "RED"
    assert summary.monthly_sign_off_status == "BLOCKED_PENDING_RED_BREACH_DECISION"
    assert summary.revalidation_required is True


def test_repeated_amber_triggers_revalidation() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    scorecard = build_demo_scorecard().query("control == 'exposure_concentration'")
    history = pd.DataFrame(
        {
            "as_of_date": ["2026-03-31", "2026-04-30"],
            "control": ["exposure_concentration", "exposure_concentration"],
            "traffic_light": ["AMBER", "AMBER"],
        }
    )

    actions, summary = engine.evaluate(
        scorecard,
        as_of_date="2026-06-30",
        history=history,
        last_validation_date="2026-01-15",
    )

    assert bool(actions.iloc[0]["revalidation_trigger"]) is True
    assert "exposure_concentration:persistent_amber_breach" in summary.revalidation_reasons


def test_material_change_and_overdue_validation_trigger_revalidation() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    scorecard = build_demo_scorecard().query("control == 'data_completeness'")
    change_log = pd.DataFrame({"material_change": [True]})

    _, summary = engine.evaluate(
        scorecard,
        as_of_date="2026-06-30",
        last_validation_date="2025-01-01",
        change_log=change_log,
    )

    assert summary.annual_validation_status == "OVERDUE"
    assert summary.revalidation_required is True
    assert "approved_material_model_change" in summary.revalidation_reasons


def test_write_outputs(tmp_path: Path) -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    actions, summary = engine.evaluate(
        build_demo_scorecard(),
        as_of_date="2026-06-30",
        last_validation_date="2026-01-15",
    )

    paths = engine.write_outputs(actions, summary, tmp_path)

    assert all(path.exists() for path in paths.values())
    payload = json.loads(paths["summary"].read_text(encoding="utf-8"))
    assert payload["overall_traffic_light"] == "RED"
    signoff = pd.read_csv(paths["signoff_template"])
    assert set(signoff["decision"]) == {"PENDING"}


def test_demo_cli(tmp_path: Path) -> None:
    exit_code = main(
        [
            "--demo",
            "--config",
            str(CONFIG_PATH),
            "--output-dir",
            str(tmp_path),
        ]
    )

    assert exit_code == 0
    assert list(tmp_path.glob("monitoring_breach_register_*.csv"))


def test_validation_errors_and_string_material_change() -> None:
    import pytest

    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    with pytest.raises(ValueError, match="Scorecard is missing required columns"):
        engine.evaluate(pd.DataFrame(), as_of_date="2026-06-30")

    bad_status = build_demo_scorecard().iloc[[0]].copy()
    bad_status.loc[:, "status"] = "UNKNOWN"
    with pytest.raises(ValueError, match="Unsupported monitoring status"):
        engine.evaluate(bad_status, as_of_date="2026-06-30")

    bad_history = pd.DataFrame({"control": ["data_completeness"]})
    with pytest.raises(ValueError, match="History is missing required columns"):
        engine.evaluate(
            build_demo_scorecard().iloc[[0]],
            as_of_date="2026-06-30",
            history=bad_history,
        )

    with pytest.raises(ValueError, match="material_change"):
        engine.evaluate(
            build_demo_scorecard().iloc[[0]],
            as_of_date="2026-06-30",
            change_log=pd.DataFrame({"other": [True]}),
        )

    _, summary = engine.evaluate(
        build_demo_scorecard().iloc[[0]],
        as_of_date="2026-06-30",
        last_validation_date="2026-01-15",
        change_log=pd.DataFrame({"material_change": ["yes"]}),
    )
    assert "approved_material_model_change" in summary.revalidation_reasons


def test_green_reporting_and_annual_validation_states(tmp_path: Path) -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    green = build_demo_scorecard().query("control == 'data_completeness'")

    actions, not_evidenced = engine.evaluate(green, as_of_date="2026-06-30")
    assert not_evidenced.annual_validation_status == "NOT_EVIDENCED"
    assert not_evidenced.monthly_sign_off_status == "READY_FOR_SIGNATURE"
    paths = engine.write_outputs(actions, not_evidenced, tmp_path / "not_evidenced")
    report = paths["report"].read_text(encoding="utf-8")
    assert "No amber or red breaches were identified." in report

    _, due_soon = engine.evaluate(
        green,
        as_of_date="2026-06-30",
        last_validation_date="2025-08-15",
    )
    assert due_soon.annual_validation_status == "DUE_SOON"

    _, current = engine.evaluate(
        green,
        as_of_date="2026-06-30",
        last_validation_date="2025-10-15",
    )
    assert current.annual_validation_status == "CURRENT"
    assert current.revalidation_reasons == ()


def test_repeated_red_and_unmatched_history_paths() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    red = build_demo_scorecard().query("control == 'lcr_distribution'").copy()
    red.loc[:, "severity"] = "High"
    red_history = pd.DataFrame(
        {
            "as_of_date": ["2026-05-31"],
            "control": ["lcr_distribution"],
            "traffic_light": ["RED"],
        }
    )
    actions, summary = engine.evaluate(
        red,
        as_of_date="2026-06-30",
        history=red_history,
        last_validation_date="2026-01-15",
    )
    assert bool(actions.iloc[0]["revalidation_trigger"]) is True
    assert "lcr_distribution:repeated_red_breach" in summary.revalidation_reasons

    amber = build_demo_scorecard().query("control == 'exposure_concentration'")
    unrelated_history = pd.DataFrame(
        {
            "as_of_date": ["2026-05-31"],
            "control": ["different_control"],
            "traffic_light": ["AMBER"],
        }
    )
    actions, _ = engine.evaluate(
        amber,
        as_of_date="2026-06-30",
        history=unrelated_history,
        last_validation_date="2026-01-15",
    )
    assert bool(actions.iloc[0]["revalidation_trigger"]) is False


def test_non_demo_cli_and_required_argument_errors(tmp_path: Path) -> None:
    import pytest

    scorecard_path = tmp_path / "scorecard.csv"
    history_path = tmp_path / "history.csv"
    change_path = tmp_path / "change.csv"
    build_demo_scorecard().to_csv(scorecard_path, index=False)
    pd.DataFrame(
        {
            "as_of_date": ["2026-05-31"],
            "control": ["lcr_distribution"],
            "traffic_light": ["RED"],
        }
    ).to_csv(history_path, index=False)
    pd.DataFrame({"material_change": [True]}).to_csv(change_path, index=False)

    exit_code = main(
        [
            "--scorecard",
            str(scorecard_path),
            "--history",
            str(history_path),
            "--change-log",
            str(change_path),
            "--as-of-date",
            "2026-06-30",
            "--last-validation-date",
            "2026-01-15",
            "--output-dir",
            str(tmp_path / "outputs"),
            "--fail-on-red",
        ]
    )
    assert exit_code == 2

    with pytest.raises(ValueError, match="--scorecard"):
        main(["--as-of-date", "2026-06-30"])
    with pytest.raises(ValueError, match="--as-of-date"):
        main(["--scorecard", str(scorecard_path)])

'@

Write-ManagedFile -RelativePath 'sql/monitoring_governance.sql' -Content @'
-- Phase VIII Section 30 monitoring-governance evidence tables for DuckDB.

CREATE TABLE IF NOT EXISTS monitoring_governance_runs (
    run_id VARCHAR PRIMARY KEY,
    as_of_date DATE NOT NULL,
    overall_traffic_light VARCHAR NOT NULL,
    green_count INTEGER NOT NULL,
    amber_count INTEGER NOT NULL,
    red_count INTEGER NOT NULL,
    model_change_trigger_count INTEGER NOT NULL,
    revalidation_required BOOLEAN NOT NULL,
    monthly_sign_off_status VARCHAR NOT NULL,
    annual_validation_status VARCHAR NOT NULL,
    annual_validation_due_date DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS monitoring_breach_actions (
    run_id VARCHAR NOT NULL,
    as_of_date DATE NOT NULL,
    control_name VARCHAR NOT NULL,
    metric_name VARCHAR NOT NULL,
    monitoring_status VARCHAR NOT NULL,
    traffic_light VARCHAR NOT NULL,
    severity VARCHAR NOT NULL,
    primary_owner VARCHAR NOT NULL,
    secondary_owner VARCHAR NOT NULL,
    acknowledgment_due_date DATE,
    investigation_due_date DATE,
    remediation_due_date DATE,
    investigation_required BOOLEAN NOT NULL,
    use_restriction_assessment BOOLEAN NOT NULL,
    model_change_trigger BOOLEAN NOT NULL,
    revalidation_trigger BOOLEAN NOT NULL,
    revalidation_reason VARCHAR,
    disposition_status VARCHAR NOT NULL,
    management_acceptance_required BOOLEAN NOT NULL,
    message VARCHAR,
    details VARCHAR,
    PRIMARY KEY (run_id, control_name, metric_name),
    FOREIGN KEY (run_id) REFERENCES monitoring_governance_runs(run_id)
);

CREATE TABLE IF NOT EXISTS monitoring_monthly_signoffs (
    run_id VARCHAR NOT NULL,
    as_of_date DATE NOT NULL,
    role_name VARCHAR NOT NULL,
    signer_name VARCHAR,
    decision VARCHAR NOT NULL,
    signature_date DATE,
    comments VARCHAR,
    governance_status VARCHAR NOT NULL,
    PRIMARY KEY (run_id, role_name),
    FOREIGN KEY (run_id) REFERENCES monitoring_governance_runs(run_id)
);

CREATE TABLE IF NOT EXISTS monitoring_annual_validations (
    validation_id VARCHAR PRIMARY KEY,
    validation_start_date DATE,
    validation_completion_date DATE,
    validation_due_date DATE NOT NULL,
    validation_status VARCHAR NOT NULL,
    independent_validator VARCHAR,
    scope_statement VARCHAR,
    report_location VARCHAR,
    open_high_or_critical_findings INTEGER DEFAULT 0,
    management_acceptance_date DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
'@

Write-ManagedFile -RelativePath 'reports/monitoring/governance/.gitkeep' -Content @'

'@


if (-not $SkipValidation) {
    $Python = Resolve-ProjectPython

    Write-Step "Checking Section 30 Python dependencies"
    & $Python -c "import pandas, pytest, yaml"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing the project and validation dependencies..."
        & $Python -m pip install --upgrade pip
        Assert-LastExitCode "pip upgrade"

        & $Python -m pip install -e ".[dev]"
        if ($LASTEXITCODE -ne 0) {
            & $Python -m pip install -e . pytest pytest-cov pandas pyyaml
            Assert-LastExitCode "Project dependency installation"
        }
    }

    & $Python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('ruff') else 1)"
    if ($LASTEXITCODE -eq 0) {
        Write-Step "Formatting and linting Section 30 code"
        & $Python -m ruff format `
            src/ficc_liquidity/monitoring/__init__.py `
            src/ficc_liquidity/monitoring/governance.py `
            scripts/run_monitoring_governance.py `
            tests/test_monitoring_governance.py
        Assert-LastExitCode "Ruff formatting"

        & $Python -m ruff check --fix `
            src/ficc_liquidity/monitoring/__init__.py `
            src/ficc_liquidity/monitoring/governance.py `
            scripts/run_monitoring_governance.py `
            tests/test_monitoring_governance.py
        Assert-LastExitCode "Ruff lint remediation"

        & $Python -m ruff check `
            src/ficc_liquidity/monitoring/__init__.py `
            src/ficc_liquidity/monitoring/governance.py `
            scripts/run_monitoring_governance.py `
            tests/test_monitoring_governance.py
        Assert-LastExitCode "Ruff validation"
    }
    else {
        Write-Warning "Ruff is not installed; pytest and compilation gates will still run."
    }

    Write-Step "Running Section 30 automated tests"
    & $Python -m pytest `
        -o 'addopts=' `
        tests/test_monitoring_governance.py `
        --cov=ficc_liquidity.monitoring.governance `
        --cov-report=term-missing `
        --cov-fail-under=85 `
        -q
    Assert-LastExitCode "Section 30 pytest gate"

    Write-Step "Running Python compilation gate"
    & $Python -m compileall -q `
        src/ficc_liquidity/monitoring `
        scripts/run_monitoring_governance.py `
        tests/test_monitoring_governance.py
    Assert-LastExitCode "Section 30 compilation gate"

    Write-Step "Creating deterministic Section 30 demo evidence"
    $demoOutput = Join-Path $ProjectRoot "reports\evidence\section30_monitoring_governance_demo"
    if (Test-Path -LiteralPath $demoOutput) {
        Remove-Item -LiteralPath $demoOutput -Recurse -Force
    }
    New-Item -ItemType Directory -Path $demoOutput -Force | Out-Null

    & $Python scripts/run_monitoring_governance.py `
        --demo `
        --as-of-date 2026-06-30 `
        --last-validation-date 2026-01-15 `
        --output-dir $demoOutput
    Assert-LastExitCode "Section 30 demo governance run"
}

if (-not $SkipGit) {
    Write-Step "Committing Section 30 deliverables"
    $controlledPaths = @(
        "configs/monitoring_governance.yaml",
        "data/manifests/monitoring_threshold_register.csv",
        "docs/monitoring_thresholds_and_escalation.md",
        "src/ficc_liquidity/monitoring/__init__.py",
        "src/ficc_liquidity/monitoring/governance.py",
        "scripts/run_monitoring_governance.py",
        "tests/test_monitoring_governance.py",
        "sql/monitoring_governance.sql",
        "reports/monitoring/governance/.gitkeep"
    )

    $scriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
    if ($scriptPath.StartsWith($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $scriptRelative = $scriptPath.Substring($ProjectRoot.Length).TrimStart("\", "/")
        if ($scriptRelative) {
            $controlledPaths += ($scriptRelative -replace "\\", "/")
        }
    }

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
        & git commit -m "Phase VIII Section 30: monitoring thresholds and escalation"
        Assert-LastExitCode "Section 30 Git commit"
    }

    if ($Publish) {
        Write-Step "Publishing branch and creating the pull request"
        & git push -u origin $Branch
        Assert-LastExitCode "Pushing $Branch"

        if (Get-Command gh -ErrorAction SilentlyContinue) {
            $existingPr = (& gh pr list --head $Branch --state open --json url --jq '.[0].url').Trim()
            if ($existingPr) {
                Write-Host "Existing pull request: $existingPr"
            }
            else {
                $prBody = @"
Completes Phase VIII, Section 30 monitoring thresholds and escalation.

Implemented:
- controlled green, amber, and red threshold register
- control-level breach ownership and evidence requirements
- acknowledgment, investigation, and remediation dates
- model-change and revalidation triggers
- monthly sign-off status and signature template
- annual independent-validation due-date control
- governance CLI, DuckDB schema, documentation, tests, and demo evidence

The implementation builds on the merged Section 29 monthly monitoring scorecard and
uses only public-data and synthetic-member project assumptions.
"@
                & gh pr create `
                    --base $BaseBranch `
                    --head $Branch `
                    --title "Phase VIII Section 30: Monitoring thresholds and escalation" `
                    --body $prBody
                Assert-LastExitCode "Creating the Section 30 pull request"
            }
        }
        else {
            Write-Warning "GitHub CLI was not found. The branch was pushed without a pull request."
        }
    }
}

Write-Step "Section 30 completed"
Write-Host "Repository: $ProjectRoot"
Write-Host "Branch:     $Branch"
Write-Host "Base:       $BaseBranch"
Write-Host "Backup:     $BackupRoot"
Write-Host "Config:     configs\monitoring_governance.yaml"
Write-Host "Thresholds: data\manifests\monitoring_threshold_register.csv"
Write-Host "Engine:     src\ficc_liquidity\monitoring\governance.py"
Write-Host "Tests:      tests\test_monitoring_governance.py"
Write-Host "Demo:       reports\evidence\section30_monitoring_governance_demo"
if (-not $Publish -and -not $SkipGit) {
    Write-Host "Publish later with: git push -u origin $Branch"
}
