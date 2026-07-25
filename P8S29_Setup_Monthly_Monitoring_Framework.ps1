<#
.SYNOPSIS
    Phase VIII, Section 29 monthly monitoring framework automation.

.DESCRIPTION
    Creates the complete Section 29 implementation in the existing
    ficc-treasury-clearing-liquidity-stress-testing repository, runs the validation
    gates, creates a deterministic demo evidence package, and commits the controlled
    files. Use -Publish to push the branch and create a pull request.

.EXAMPLE
    .\P8S29_Setup_Monthly_Monitoring_Framework.ps1

.EXAMPLE
    .\P8S29_Setup_Monthly_Monitoring_Framework.ps1 -Publish
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/20-model-monitoring-governance",
    [string]$BaseBranch = "main",
    [switch]$SkipGit,
    [switch]$SkipValidation,
    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Assert-LastExitCode {
    param([string]$Operation)
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
$BackupRoot = Join-Path $ProjectRoot "reports\setup_backups\section29_$timestamp"

if (-not $SkipGit) {
    Write-Step "Preparing Git branch $Branch"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git was not found. Install Git and reopen VS Code."
    }
    & git rev-parse --is-inside-work-tree | Out-Null
    Assert-LastExitCode "Git repository validation"

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

Write-Step "Creating Section 29 controlled files"

Write-ManagedFile -RelativePath 'configs/monitoring.yaml' -Content @'
monitoring:
  frequency: monthly
  required_columns:
    - date
    - member_id
    - scenario
    - exposure
    - stressed_liquidity_requirement
    - available_resources
    - lcr
  numeric_columns:
    - exposure
    - stressed_liquidity_requirement
    - available_resources
    - lcr
  component_columns:
    - settlement_liquidity_need
    - repo_rollover_need
    - incremental_funding_cost
    - additional_haircut_requirement
    - treasury_liquidation_loss
    - settlement_fail_requirement
    - concentration_adjustment
    - operational_liquidity_buffer
  thresholds:
    data_completeness_warn: 0.995
    data_completeness_fail: 0.980
    missing_business_days_warn: 1
    missing_business_days_fail: 3
    historical_range_breach_rate_warn: 0.010
    historical_range_breach_rate_fail: 0.050
    historical_quantile_low: 0.001
    historical_quantile_high: 0.999
    parameter_relative_change_warn: 0.050
    parameter_relative_change_fail: 0.150
    largest_member_share_warn: 0.200
    largest_member_share_fail: 0.300
    exposure_hhi_warn: 0.180
    exposure_hhi_fail: 0.250
    lcr_p05_warn: 1.050
    lcr_p05_fail: 1.000
    lcr_breach_rate_warn: 0.001
    lcr_breach_rate_fail: 0.010
    lcr_mean_relative_change_warn: 0.100
    lcr_mean_relative_change_fail: 0.250
    scenario_rank_correlation_warn: 0.900
    scenario_rank_correlation_fail: 0.750
    component_share_drift_warn: 0.050
    component_share_drift_fail: 0.100
    sensitivity_relative_change_warn: 0.150
    sensitivity_relative_change_fail: 0.300
    reconciliation_failures_warn: 1
    reconciliation_failures_fail: 2
'@

Write-ManagedFile -RelativePath 'docs/monthly_monitoring_framework.md' -Content @'
# Section 29 Ã¢â‚¬â€ Monthly Monitoring Framework

## Objective

This framework provides repeatable monthly monitoring for the FICC Treasury clearing
liquidity stress-testing model. It is designed for synthetic member data and public-source
market inputs. It must not be represented as monitoring of actual FICC participants or
confidential FICC production outcomes.

## Monitoring controls

| Control | Primary measure | Governance purpose |
|---|---|---|
| Data completeness | Minimum non-null rate across required fields | Detect incomplete monthly inputs |
| Schema changes | Missing fields and invalid data types | Enforce the controlled data contract |
| Missing observations | Missing business dates | Identify breaks in input time series |
| Historical-range breaches | Share outside baseline quantile bounds | Detect unusual or potentially invalid values |
| Parameter changes | Maximum relative parameter change | Identify unapproved model/configuration changes |
| Exposure concentration | Largest-member share and HHI | Monitor synthetic portfolio concentration |
| LCR distribution | 5th percentile, breach rate, mean drift | Monitor lower-tail liquidity adequacy |
| Scenario rank stability | Correlation of scenario severity ranks | Detect unexpected scenario ordering changes |
| Component contribution drift | Maximum contribution-share change | Detect changes in stress drivers |
| Sensitivity changes | Maximum relative sensitivity change | Detect response-function instability |
| Reconciliation failures | Failed independent reconciliations | Detect implementation or aggregation breaks |

## Inputs

The monthly result dataset requires these fields:

- `date`
- `member_id`
- `scenario`
- `exposure`
- `stressed_liquidity_requirement`
- `available_resources`
- `lcr`

The component-drift control uses the eight Section 19 stress components when present.
The monitoring run also accepts a historical baseline, the previous monthly result set,
current and prior parameter snapshots, sensitivity snapshots, and reconciliation results.
CSV and Parquet tables are supported. Parameter snapshots may be YAML or JSON.

## Outputs

Each run writes:

1. A CSV control scorecard.
2. A JSON run summary.
3. A Markdown monitoring report.

Outputs are written under `reports/monitoring/monthly/` by default and use the as-of date
in each filename.

## Status and escalation

- **PASS**: retain the evidence package and continue the normal monitoring cycle.
- **WARN**: assign an owner, document the explanation and disposition, and resolve or
  escalate within 10 business days.
- **FAIL**: open a model-risk or data-quality issue before the next production-equivalent
  run. Assess whether model use should be restricted until remediation and independent
  verification are complete.

Any missing monitoring input is treated as a warning rather than silently passing.
Thresholds are controlled in `configs/monitoring.yaml`; all threshold changes must be
reviewed, approved, version-controlled, and included in the monthly evidence package.

## Monthly operating procedure

1. Freeze the current-month analytical dataset and record its lineage.
2. Retain the prior-month dataset and historical baseline used for comparison.
3. Export controlled model parameters and sensitivity results.
4. Run independent reconciliation checks from Section 25.
5. Execute `scripts/run_monthly_monitoring.py`.
6. Review all warnings and failures, assign owners, and document dispositions.
7. Archive the scorecard, summary, report, source hashes, configuration, and approval.
8. Present unresolved issues and trend changes to the model owner and model-risk function.

## Example command

```powershell
.\.venv\Scripts\python.exe scripts\run_monthly_monitoring.py `
  --current data\processed\monthly_results_2026_06.parquet `
  --previous data\processed\monthly_results_2026_05.parquet `
  --baseline data\processed\historical_monitoring_baseline.parquet `
  --current-parameters configs\parameters_2026_06.yaml `
  --previous-parameters configs\parameters_2026_05.yaml `
  --current-sensitivity reports\validation\sensitivity_2026_06.csv `
  --previous-sensitivity reports\validation\sensitivity_2026_05.csv `
  --reconciliation reports\validation\reconciliation_2026_06.csv `
  --as-of-date 2026-06-30
```

Use `--demo` for the deterministic synthetic smoke test.
'@

Write-ManagedFile -RelativePath 'src/ficc_liquidity/monitoring/__init__.py' -Content @'
"""Model monitoring package."""

from ficc_liquidity.monitoring.monthly import (
    MonitoringResult,
    MonitoringSummary,
    MonthlyMonitoringEngine,
    build_demo_inputs,
)

__all__ = [
    "MonitoringResult",
    "MonitoringSummary",
    "MonthlyMonitoringEngine",
    "build_demo_inputs",
]
'@

Write-ManagedFile -RelativePath 'src/ficc_liquidity/monitoring/monthly.py' -Content @'
"""Monthly model monitoring for FICC liquidity stress testing."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping

import numpy as np
import pandas as pd
import yaml


@dataclass(frozen=True)
class MonitoringResult:
    """One monitoring control result."""

    control: str
    metric: str
    value: float | int | str | None
    warning_threshold: float | int | str | None
    failure_threshold: float | int | str | None
    status: str
    severity: str
    message: str
    details: str = ""


@dataclass(frozen=True)
class MonitoringSummary:
    """Run-level monitoring summary."""

    as_of_date: str
    overall_status: str
    pass_count: int
    warning_count: int
    failure_count: int
    control_count: int


class MonthlyMonitoringEngine:
    """Execute the Section 29 monthly monitoring control suite."""

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.config = dict(config["monitoring"])
        self.thresholds = dict(self.config["thresholds"])
        self.required_columns = list(self.config["required_columns"])
        self.numeric_columns = list(self.config["numeric_columns"])
        self.component_columns = list(self.config["component_columns"])

    @classmethod
    def from_yaml(cls, path: str | Path) -> "MonthlyMonitoringEngine":
        with Path(path).open("r", encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
        return cls(config)

    def run(
        self,
        current: pd.DataFrame,
        *,
        baseline: pd.DataFrame | None = None,
        previous: pd.DataFrame | None = None,
        current_parameters: Mapping[str, Any] | None = None,
        previous_parameters: Mapping[str, Any] | None = None,
        current_sensitivity: pd.DataFrame | None = None,
        previous_sensitivity: pd.DataFrame | None = None,
        reconciliation: pd.DataFrame | None = None,
        as_of_date: str | None = None,
    ) -> tuple[pd.DataFrame, MonitoringSummary]:
        current = self._normalize_frame(current)
        baseline = self._normalize_optional_frame(baseline)
        previous = self._normalize_optional_frame(previous)

        results = [
            self._check_data_completeness(current),
            self._check_schema_changes(current),
            self._check_missing_observations(current),
            self._check_historical_range(current, baseline),
            self._check_parameter_changes(current_parameters, previous_parameters),
            self._check_exposure_concentration(current),
            self._check_lcr_distribution(current, previous),
            self._check_scenario_rank_stability(current, previous),
            self._check_component_contribution_drift(current, previous),
            self._check_sensitivity_changes(current_sensitivity, previous_sensitivity),
            self._check_reconciliation_failures(reconciliation),
        ]
        scorecard = pd.DataFrame(asdict(result) for result in results)
        status_counts = scorecard["status"].value_counts().to_dict()
        failure_count = int(status_counts.get("FAIL", 0))
        warning_count = int(status_counts.get("WARN", 0))
        pass_count = int(status_counts.get("PASS", 0))
        overall_status = "FAIL" if failure_count else "WARN" if warning_count else "PASS"
        resolved_date = as_of_date or self._resolve_as_of_date(current)
        summary = MonitoringSummary(
            as_of_date=resolved_date,
            overall_status=overall_status,
            pass_count=pass_count,
            warning_count=warning_count,
            failure_count=failure_count,
            control_count=len(results),
        )
        return scorecard, summary

    def write_outputs(
        self,
        scorecard: pd.DataFrame,
        summary: MonitoringSummary,
        output_dir: str | Path,
    ) -> dict[str, Path]:
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        stamp = summary.as_of_date.replace("-", "")
        scorecard_path = output_path / f"monthly_monitoring_scorecard_{stamp}.csv"
        summary_path = output_path / f"monthly_monitoring_summary_{stamp}.json"
        report_path = output_path / f"monthly_monitoring_report_{stamp}.md"

        scorecard.to_csv(scorecard_path, index=False)
        summary_path.write_text(
            json.dumps(asdict(summary), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        report_path.write_text(
            self._render_markdown(scorecard, summary),
            encoding="utf-8",
        )
        return {
            "scorecard": scorecard_path,
            "summary": summary_path,
            "report": report_path,
        }

    def _check_data_completeness(self, current: pd.DataFrame) -> MonitoringResult:
        missing_columns = sorted(set(self.required_columns) - set(current.columns))
        if missing_columns:
            return self._result(
                "data_completeness",
                "required_column_presence",
                len(missing_columns),
                0,
                0,
                "FAIL",
                "Critical",
                "Required monitoring fields are absent.",
                ", ".join(missing_columns),
            )
        completeness = float(current[self.required_columns].notna().mean().min())
        status = self._lower_is_worse_status(
            completeness,
            self.thresholds["data_completeness_warn"],
            self.thresholds["data_completeness_fail"],
        )
        return self._result(
            "data_completeness",
            "minimum_required_field_completeness",
            completeness,
            self.thresholds["data_completeness_warn"],
            self.thresholds["data_completeness_fail"],
            status,
            "High",
            "Minimum non-null ratio across required fields.",
        )

    def _check_schema_changes(self, current: pd.DataFrame) -> MonitoringResult:
        missing = sorted(set(self.required_columns) - set(current.columns))
        non_numeric = [
            name
            for name in self.numeric_columns
            if name in current.columns and not pd.api.types.is_numeric_dtype(current[name])
        ]
        date_problem = "date" in current.columns and not pd.api.types.is_datetime64_any_dtype(
            current["date"]
        )
        issues = missing + non_numeric + (["date:not_datetime"] if date_problem else [])
        status = "FAIL" if issues else "PASS"
        return self._result(
            "schema_changes",
            "schema_issue_count",
            len(issues),
            1,
            1,
            status,
            "Critical",
            "Required fields and data types are compared with the monitoring contract.",
            ", ".join(issues),
        )

    def _check_missing_observations(self, current: pd.DataFrame) -> MonitoringResult:
        if "date" not in current.columns or current["date"].dropna().empty:
            return self._unavailable(
                "missing_observations",
                "missing_business_days",
                "No valid date observations are available.",
            )
        dates = pd.DatetimeIndex(current["date"].dropna().dt.normalize().unique()).sort_values()
        expected = pd.bdate_range(dates.min(), dates.max())
        missing_count = int(len(expected.difference(dates)))
        status = self._higher_is_worse_status(
            missing_count,
            self.thresholds["missing_business_days_warn"],
            self.thresholds["missing_business_days_fail"],
        )
        return self._result(
            "missing_observations",
            "missing_business_days",
            missing_count,
            self.thresholds["missing_business_days_warn"],
            self.thresholds["missing_business_days_fail"],
            status,
            "High",
            "Missing business dates between the first and last observed dates.",
        )

    def _check_historical_range(
        self,
        current: pd.DataFrame,
        baseline: pd.DataFrame | None,
    ) -> MonitoringResult:
        if baseline is None or baseline.empty:
            return self._unavailable(
                "historical_range_breaches",
                "breach_rate",
                "Historical baseline data were not supplied.",
            )
        available = [
            name
            for name in self.numeric_columns
            if name in current.columns and name in baseline.columns
        ]
        if not available:
            return self._unavailable(
                "historical_range_breaches",
                "breach_rate",
                "No common numeric monitoring fields were found.",
            )
        low_q = float(self.thresholds["historical_quantile_low"])
        high_q = float(self.thresholds["historical_quantile_high"])
        breach_total = 0
        observation_total = 0
        detail_rows: list[str] = []
        for name in available:
            lower = float(baseline[name].quantile(low_q))
            upper = float(baseline[name].quantile(high_q))
            values = current[name].dropna()
            breaches = int(((values < lower) | (values > upper)).sum())
            breach_total += breaches
            observation_total += int(values.size)
            detail_rows.append(f"{name}={breaches}/{values.size}")
        breach_rate = breach_total / observation_total if observation_total else 0.0
        status = self._higher_is_worse_status(
            breach_rate,
            self.thresholds["historical_range_breach_rate_warn"],
            self.thresholds["historical_range_breach_rate_fail"],
        )
        return self._result(
            "historical_range_breaches",
            "breach_rate",
            breach_rate,
            self.thresholds["historical_range_breach_rate_warn"],
            self.thresholds["historical_range_breach_rate_fail"],
            status,
            "Medium",
            "Current values outside historical baseline quantile bounds.",
            "; ".join(detail_rows),
        )

    def _check_parameter_changes(
        self,
        current_parameters: Mapping[str, Any] | None,
        previous_parameters: Mapping[str, Any] | None,
    ) -> MonitoringResult:
        if not current_parameters or not previous_parameters:
            return self._unavailable(
                "parameter_changes",
                "maximum_relative_change",
                "Current and previous parameter snapshots were not both supplied.",
            )
        current_flat = self._flatten_mapping(current_parameters)
        previous_flat = self._flatten_mapping(previous_parameters)
        shared = sorted(set(current_flat) & set(previous_flat))
        numeric_changes: list[tuple[str, float]] = []
        categorical_changes: list[str] = []
        for name in shared:
            current_value = current_flat[name]
            previous_value = previous_flat[name]
            if self._is_number(current_value) and self._is_number(previous_value):
                denominator = max(abs(float(previous_value)), 1e-12)
                change = abs(float(current_value) - float(previous_value)) / denominator
                numeric_changes.append((name, change))
            elif current_value != previous_value:
                categorical_changes.append(name)
        added_or_removed = sorted(set(current_flat) ^ set(previous_flat))
        max_change = max((change for _, change in numeric_changes), default=0.0)
        status = self._higher_is_worse_status(
            max_change,
            self.thresholds["parameter_relative_change_warn"],
            self.thresholds["parameter_relative_change_fail"],
        )
        if categorical_changes or added_or_removed:
            status = "FAIL"
        details = [f"{name}={change:.4f}" for name, change in numeric_changes if change > 0]
        details.extend(f"categorical_change:{name}" for name in categorical_changes)
        details.extend(f"added_or_removed:{name}" for name in added_or_removed)
        return self._result(
            "parameter_changes",
            "maximum_relative_change",
            max_change,
            self.thresholds["parameter_relative_change_warn"],
            self.thresholds["parameter_relative_change_fail"],
            status,
            "High",
            "Maximum relative parameter change plus structural parameter changes.",
            "; ".join(details),
        )

    def _check_exposure_concentration(self, current: pd.DataFrame) -> MonitoringResult:
        if not {"member_id", "exposure"}.issubset(current.columns):
            return self._unavailable(
                "exposure_concentration",
                "largest_member_share",
                "Member and exposure fields are required.",
            )
        exposure = current.groupby("member_id", dropna=False)["exposure"].sum().abs()
        total = float(exposure.sum())
        if total <= 0:
            return self._unavailable(
                "exposure_concentration",
                "largest_member_share",
                "Total absolute exposure is zero.",
            )
        shares = exposure / total
        largest_share = float(shares.max())
        hhi = float(np.square(shares).sum())
        share_status = self._higher_is_worse_status(
            largest_share,
            self.thresholds["largest_member_share_warn"],
            self.thresholds["largest_member_share_fail"],
        )
        hhi_status = self._higher_is_worse_status(
            hhi,
            self.thresholds["exposure_hhi_warn"],
            self.thresholds["exposure_hhi_fail"],
        )
        status = self._worst_status(share_status, hhi_status)
        return self._result(
            "exposure_concentration",
            "largest_member_share",
            largest_share,
            self.thresholds["largest_member_share_warn"],
            self.thresholds["largest_member_share_fail"],
            status,
            "High",
            "Largest member share of absolute exposure; HHI is an auxiliary indicator.",
            f"hhi={hhi:.6f}",
        )

    def _check_lcr_distribution(
        self,
        current: pd.DataFrame,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        if "lcr" not in current.columns or current["lcr"].dropna().empty:
            return self._unavailable(
                "lcr_distribution",
                "lcr_5th_percentile",
                "No LCR observations are available.",
            )
        lcr = current["lcr"].dropna().astype(float)
        p05 = float(lcr.quantile(0.05))
        breach_rate = float((lcr < 1.0).mean())
        p05_status = self._lower_is_worse_status(
            p05,
            self.thresholds["lcr_p05_warn"],
            self.thresholds["lcr_p05_fail"],
        )
        breach_status = self._higher_is_worse_status(
            breach_rate,
            self.thresholds["lcr_breach_rate_warn"],
            self.thresholds["lcr_breach_rate_fail"],
        )
        mean_change = 0.0
        mean_change_status = "PASS"
        if previous is not None and "lcr" in previous.columns and previous["lcr"].notna().any():
            previous_mean = float(previous["lcr"].mean())
            denominator = max(abs(previous_mean), 1e-12)
            mean_change = abs(float(lcr.mean()) - previous_mean) / denominator
            mean_change_status = self._higher_is_worse_status(
                mean_change,
                self.thresholds["lcr_mean_relative_change_warn"],
                self.thresholds["lcr_mean_relative_change_fail"],
            )
        status = self._worst_status(p05_status, breach_status, mean_change_status)
        return self._result(
            "lcr_distribution",
            "lcr_5th_percentile",
            p05,
            self.thresholds["lcr_p05_warn"],
            self.thresholds["lcr_p05_fail"],
            status,
            "Critical",
            "Lower-tail LCR, LCR<1 breach rate, and month-over-month mean drift.",
            f"breach_rate={breach_rate:.6f}; mean_relative_change={mean_change:.6f}",
        )

    def _check_scenario_rank_stability(
        self,
        current: pd.DataFrame,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        required = {"scenario", "stressed_liquidity_requirement"}
        if previous is None or not required.issubset(current.columns) or not required.issubset(
            previous.columns
        ):
            return self._unavailable(
                "scenario_rank_stability",
                "rank_correlation",
                "Current and previous scenario results are required.",
            )
        current_rank = (
            current.groupby("scenario")["stressed_liquidity_requirement"].mean().rank()
        )
        previous_rank = (
            previous.groupby("scenario")["stressed_liquidity_requirement"].mean().rank()
        )
        shared = current_rank.index.intersection(previous_rank.index)
        if len(shared) < 2:
            return self._unavailable(
                "scenario_rank_stability",
                "rank_correlation",
                "At least two common scenarios are required.",
            )
        correlation = self._pearson(
            current_rank.loc[shared].to_numpy(dtype=float),
            previous_rank.loc[shared].to_numpy(dtype=float),
        )
        status = self._lower_is_worse_status(
            correlation,
            self.thresholds["scenario_rank_correlation_warn"],
            self.thresholds["scenario_rank_correlation_fail"],
        )
        return self._result(
            "scenario_rank_stability",
            "rank_correlation",
            correlation,
            self.thresholds["scenario_rank_correlation_warn"],
            self.thresholds["scenario_rank_correlation_fail"],
            status,
            "Medium",
            "Pearson correlation of average scenario severity ranks across months.",
            f"common_scenarios={len(shared)}",
        )

    def _check_component_contribution_drift(
        self,
        current: pd.DataFrame,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        if previous is None:
            return self._unavailable(
                "component_contribution_drift",
                "maximum_absolute_share_change",
                "Previous-month results were not supplied.",
            )
        components = [
            name
            for name in self.component_columns
            if name in current.columns and name in previous.columns
        ]
        if not components:
            return self._unavailable(
                "component_contribution_drift",
                "maximum_absolute_share_change",
                "No common stress-component columns are available.",
            )
        current_total = float(current[components].sum(axis=1).abs().sum())
        previous_total = float(previous[components].sum(axis=1).abs().sum())
        if current_total <= 0 or previous_total <= 0:
            return self._unavailable(
                "component_contribution_drift",
                "maximum_absolute_share_change",
                "Component totals must be positive.",
            )
        current_shares = current[components].abs().sum() / current_total
        previous_shares = previous[components].abs().sum() / previous_total
        changes = (current_shares - previous_shares).abs()
        max_change = float(changes.max())
        status = self._higher_is_worse_status(
            max_change,
            self.thresholds["component_share_drift_warn"],
            self.thresholds["component_share_drift_fail"],
        )
        details = "; ".join(f"{name}={changes[name]:.6f}" for name in components)
        return self._result(
            "component_contribution_drift",
            "maximum_absolute_share_change",
            max_change,
            self.thresholds["component_share_drift_warn"],
            self.thresholds["component_share_drift_fail"],
            status,
            "Medium",
            "Maximum absolute change in aggregate stress-component contribution share.",
            details,
        )

    def _check_sensitivity_changes(
        self,
        current: pd.DataFrame | None,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        required = {"parameter", "sensitivity"}
        if current is None or previous is None:
            return self._unavailable(
                "sensitivity_changes",
                "maximum_relative_change",
                "Current and previous sensitivity snapshots were not both supplied.",
            )
        if not required.issubset(current.columns) or not required.issubset(previous.columns):
            return self._unavailable(
                "sensitivity_changes",
                "maximum_relative_change",
                "Sensitivity snapshots require parameter and sensitivity fields.",
            )
        merged = current[list(required)].merge(
            previous[list(required)],
            on="parameter",
            suffixes=("_current", "_previous"),
        )
        if merged.empty:
            return self._unavailable(
                "sensitivity_changes",
                "maximum_relative_change",
                "No common sensitivity parameters were found.",
            )
        denominator = merged["sensitivity_previous"].abs().clip(lower=1e-12)
        changes = (
            merged["sensitivity_current"] - merged["sensitivity_previous"]
        ).abs() / denominator
        max_change = float(changes.max())
        status = self._higher_is_worse_status(
            max_change,
            self.thresholds["sensitivity_relative_change_warn"],
            self.thresholds["sensitivity_relative_change_fail"],
        )
        detail = "; ".join(
            f"{parameter}={change:.6f}"
            for parameter, change in zip(merged["parameter"], changes, strict=True)
        )
        return self._result(
            "sensitivity_changes",
            "maximum_relative_change",
            max_change,
            self.thresholds["sensitivity_relative_change_warn"],
            self.thresholds["sensitivity_relative_change_fail"],
            status,
            "High",
            "Maximum relative change in independently measured model sensitivity.",
            detail,
        )

    def _check_reconciliation_failures(
        self,
        reconciliation: pd.DataFrame | None,
    ) -> MonitoringResult:
        if reconciliation is None or reconciliation.empty:
            return self._unavailable(
                "reconciliation_failures",
                "failure_count",
                "Reconciliation results were not supplied.",
            )
        if "passed" in reconciliation.columns:
            failures = int((~reconciliation["passed"].fillna(False).astype(bool)).sum())
        elif {"difference", "tolerance"}.issubset(reconciliation.columns):
            failures = int(
                (reconciliation["difference"].abs() > reconciliation["tolerance"].abs()).sum()
            )
        else:
            return self._unavailable(
                "reconciliation_failures",
                "failure_count",
                "Reconciliation requires passed or difference/tolerance fields.",
            )
        status = self._higher_is_worse_status(
            failures,
            self.thresholds["reconciliation_failures_warn"],
            self.thresholds["reconciliation_failures_fail"],
        )
        return self._result(
            "reconciliation_failures",
            "failure_count",
            failures,
            self.thresholds["reconciliation_failures_warn"],
            self.thresholds["reconciliation_failures_fail"],
            status,
            "Critical",
            "Number of failed production-to-independent reconciliations.",
        )

    @staticmethod
    def _normalize_frame(frame: pd.DataFrame) -> pd.DataFrame:
        normalized = frame.copy()
        if "date" in normalized.columns:
            normalized["date"] = pd.to_datetime(normalized["date"], errors="coerce")
        return normalized

    def _normalize_optional_frame(self, frame: pd.DataFrame | None) -> pd.DataFrame | None:
        return None if frame is None else self._normalize_frame(frame)

    @staticmethod
    def _resolve_as_of_date(current: pd.DataFrame) -> str:
        if "date" in current.columns and current["date"].notna().any():
            return pd.Timestamp(current["date"].max()).date().isoformat()
        return pd.Timestamp.utcnow().date().isoformat()

    @staticmethod
    def _flatten_mapping(
        values: Mapping[str, Any],
        prefix: str = "",
    ) -> dict[str, Any]:
        flattened: dict[str, Any] = {}
        for key, value in values.items():
            name = f"{prefix}.{key}" if prefix else str(key)
            if isinstance(value, Mapping):
                flattened.update(MonthlyMonitoringEngine._flatten_mapping(value, name))
            else:
                flattened[name] = value
        return flattened

    @staticmethod
    def _is_number(value: Any) -> bool:
        return isinstance(value, (int, float, np.integer, np.floating)) and not isinstance(
            value, bool
        )

    @staticmethod
    def _pearson(x: np.ndarray, y: np.ndarray) -> float:
        if x.size != y.size or x.size < 2:
            return float("nan")
        x_centered = x - x.mean()
        y_centered = y - y.mean()
        denominator = float(np.sqrt(np.square(x_centered).sum() * np.square(y_centered).sum()))
        if denominator == 0:
            return 1.0 if np.allclose(x, y) else 0.0
        return float(np.dot(x_centered, y_centered) / denominator)

    @staticmethod
    def _higher_is_worse_status(value: float, warning: float, failure: float) -> str:
        if value >= failure:
            return "FAIL"
        if value >= warning:
            return "WARN"
        return "PASS"

    @staticmethod
    def _lower_is_worse_status(value: float, warning: float, failure: float) -> str:
        if value < failure:
            return "FAIL"
        if value < warning:
            return "WARN"
        return "PASS"

    @staticmethod
    def _worst_status(*statuses: str) -> str:
        ordering = {"PASS": 0, "WARN": 1, "FAIL": 2}
        return max(statuses, key=lambda status: ordering[status])

    @staticmethod
    def _result(
        control: str,
        metric: str,
        value: float | int | str | None,
        warning_threshold: float | int | str | None,
        failure_threshold: float | int | str | None,
        status: str,
        severity: str,
        message: str,
        details: str = "",
    ) -> MonitoringResult:
        return MonitoringResult(
            control=control,
            metric=metric,
            value=value,
            warning_threshold=warning_threshold,
            failure_threshold=failure_threshold,
            status=status,
            severity=severity,
            message=message,
            details=details,
        )

    def _unavailable(self, control: str, metric: str, message: str) -> MonitoringResult:
        return self._result(
            control,
            metric,
            None,
            None,
            None,
            "WARN",
            "Medium",
            message,
            "Input unavailable; governance review required.",
        )

    @staticmethod
    def _render_markdown(
        scorecard: pd.DataFrame,
        summary: MonitoringSummary,
    ) -> str:
        lines = [
            "# Monthly Model Monitoring Report",
            "",
            f"**As of:** {summary.as_of_date}",
            f"**Overall status:** {summary.overall_status}",
            f"**Controls:** {summary.control_count}",
            f"**PASS / WARN / FAIL:** {summary.pass_count} / "
            f"{summary.warning_count} / {summary.failure_count}",
            "",
            "| Control | Metric | Value | Status | Severity | Message |",
            "|---|---|---:|---|---|---|",
        ]
        for row in scorecard.itertuples(index=False):
            value = "" if pd.isna(row.value) else str(row.value)
            message = str(row.message).replace("|", "/")
            lines.append(
                f"| {row.control} | {row.metric} | {value} | {row.status} | "
                f"{row.severity} | {message} |"
            )
        lines.extend(
            [
                "",
                "## Governance action",
                "",
                "- FAIL: open a model-risk or data-quality issue before the next production run.",
                (
                    "- WARN: assign an owner, document disposition, and close or "
                    "escalate within 10 business days."
                ),
                "- PASS: retain evidence and continue the monthly monitoring cycle.",
                "",
            ]
        )
        return "\n".join(lines)


def _read_table(path: str | Path) -> pd.DataFrame:
    source = Path(path)
    if source.suffix.lower() == ".parquet":
        return pd.read_parquet(source)
    return pd.read_csv(source)


def _read_mapping(path: str | Path) -> dict[str, Any]:
    source = Path(path)
    text = source.read_text(encoding="utf-8")
    if source.suffix.lower() == ".json":
        return dict(json.loads(text))
    return dict(yaml.safe_load(text))


def build_demo_inputs(seed: int = 2026) -> dict[str, Any]:
    """Build deterministic synthetic inputs for a smoke test."""

    rng = np.random.default_rng(seed)
    dates = pd.bdate_range("2026-06-01", "2026-06-30")
    members = [f"SYNTH_MEMBER_{index:02d}" for index in range(1, 13)]
    scenarios = ["moderate", "severe", "extreme"]
    rows: list[dict[str, Any]] = []
    component_names = [
        "settlement_liquidity_need",
        "repo_rollover_need",
        "incremental_funding_cost",
        "additional_haircut_requirement",
        "treasury_liquidation_loss",
        "settlement_fail_requirement",
        "concentration_adjustment",
        "operational_liquidity_buffer",
    ]
    severity = {"moderate": 1.0, "severe": 1.4, "extreme": 1.9}
    for date in dates:
        for member_index, member in enumerate(members, start=1):
            base_exposure = 80_000_000 + member_index * 2_000_000
            for scenario in scenarios:
                components = rng.lognormal(mean=15.0, sigma=0.15, size=len(component_names))
                components = components * severity[scenario]
                requirement = float(components.sum())
                resources = requirement * rng.uniform(1.25, 1.45)
                row: dict[str, Any] = {
                    "date": date,
                    "member_id": member,
                    "scenario": scenario,
                    "exposure": base_exposure * rng.uniform(0.95, 1.05),
                    "stressed_liquidity_requirement": requirement,
                    "available_resources": resources,
                    "lcr": resources / requirement,
                }
                row.update(dict(zip(component_names, components, strict=True)))
                rows.append(row)
    current = pd.DataFrame(rows)
    previous = current.copy()
    previous["date"] = previous["date"] - pd.offsets.MonthBegin(1)
    previous["stressed_liquidity_requirement"] *= 0.98
    previous[component_names] *= 0.98
    previous["lcr"] *= 1.01
    baseline = pd.concat([previous, current], ignore_index=True)
    sensitivity = pd.DataFrame(
        {
            "parameter": ["yield_shock", "sofr_spike", "haircut_increase"],
            "sensitivity": [0.82, 0.67, 0.55],
        }
    )
    previous_sensitivity = sensitivity.copy()
    previous_sensitivity["sensitivity"] *= 0.98
    reconciliation = pd.DataFrame(
        {
            "check_name": ["requirement", "resources", "lcr"],
            "difference": [0.0, 0.0, 0.0],
            "tolerance": [1e-8, 1e-8, 1e-8],
            "passed": [True, True, True],
        }
    )
    return {
        "current": current,
        "previous": previous,
        "baseline": baseline,
        "current_parameters": {
            "liquidation_horizon_days": 5,
            "random_seed": seed,
            "cover_standard": "cover_2",
        },
        "previous_parameters": {
            "liquidation_horizon_days": 5,
            "random_seed": seed,
            "cover_standard": "cover_2",
        },
        "current_sensitivity": sensitivity,
        "previous_sensitivity": previous_sensitivity,
        "reconciliation": reconciliation,
    }


def _optional_table(path: str | None) -> pd.DataFrame | None:
    return None if path is None else _read_table(path)


def _optional_mapping(path: str | None) -> dict[str, Any] | None:
    return None if path is None else _read_mapping(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="configs/monitoring.yaml")
    parser.add_argument("--current")
    parser.add_argument("--baseline")
    parser.add_argument("--previous")
    parser.add_argument("--current-parameters")
    parser.add_argument("--previous-parameters")
    parser.add_argument("--current-sensitivity")
    parser.add_argument("--previous-sensitivity")
    parser.add_argument("--reconciliation")
    parser.add_argument("--output-dir", default="reports/monitoring/monthly")
    parser.add_argument("--as-of-date")
    parser.add_argument("--demo", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    engine = MonthlyMonitoringEngine.from_yaml(args.config)
    if args.demo:
        inputs = build_demo_inputs()
    else:
        if not args.current:
            raise SystemExit("--current is required unless --demo is used")
        inputs = {
            "current": _read_table(args.current),
            "baseline": _optional_table(args.baseline),
            "previous": _optional_table(args.previous),
            "current_parameters": _optional_mapping(args.current_parameters),
            "previous_parameters": _optional_mapping(args.previous_parameters),
            "current_sensitivity": _optional_table(args.current_sensitivity),
            "previous_sensitivity": _optional_table(args.previous_sensitivity),
            "reconciliation": _optional_table(args.reconciliation),
        }
    scorecard, summary = engine.run(**inputs, as_of_date=args.as_of_date)
    paths = engine.write_outputs(scorecard, summary, args.output_dir)
    print(json.dumps({name: str(path) for name, path in paths.items()}, indent=2))
    print(f"overall_status={summary.overall_status}")
    return 1 if summary.failure_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-ManagedFile -RelativePath 'scripts/run_monthly_monitoring.py' -Content @'
"""Command-line wrapper for the monthly monitoring framework."""

from ficc_liquidity.monitoring.monthly import main


if __name__ == "__main__":
    raise SystemExit(main())
'@

Write-ManagedFile -RelativePath 'tests/test_monthly_monitoring.py' -Content @'
from __future__ import annotations

from pathlib import Path

import pandas as pd

from ficc_liquidity.monitoring.monthly import MonthlyMonitoringEngine, build_demo_inputs


CONFIG = Path(__file__).parents[1] / "configs" / "monitoring.yaml"


def test_demo_run_executes_all_section_29_controls() -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    scorecard, summary = engine.run(**build_demo_inputs(), as_of_date="2026-06-30")

    assert summary.control_count == 11
    assert set(scorecard["control"]) == {
        "data_completeness",
        "schema_changes",
        "missing_observations",
        "historical_range_breaches",
        "parameter_changes",
        "exposure_concentration",
        "lcr_distribution",
        "scenario_rank_stability",
        "component_contribution_drift",
        "sensitivity_changes",
        "reconciliation_failures",
    }
    assert summary.failure_count == 0


def test_framework_detects_material_monitoring_failures() -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    inputs = build_demo_inputs()
    current = inputs["current"].copy()
    current.loc[current.index[:100], "lcr"] = 0.70
    current.loc[current["member_id"] != "SYNTH_MEMBER_01", "exposure"] = 1.0
    inputs["current"] = current
    inputs["reconciliation"] = pd.DataFrame(
        {"check_name": ["a", "b"], "passed": [False, False]}
    )

    scorecard, summary = engine.run(**inputs, as_of_date="2026-06-30")
    status_by_control = scorecard.set_index("control")["status"].to_dict()

    assert summary.overall_status == "FAIL"
    assert status_by_control["lcr_distribution"] == "FAIL"
    assert status_by_control["exposure_concentration"] == "FAIL"
    assert status_by_control["reconciliation_failures"] == "FAIL"


def test_outputs_are_persisted(tmp_path: Path) -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    scorecard, summary = engine.run(**build_demo_inputs(), as_of_date="2026-06-30")

    paths = engine.write_outputs(scorecard, summary, tmp_path)

    assert all(path.exists() for path in paths.values())
    assert "Monthly Model Monitoring Report" in paths["report"].read_text(encoding="utf-8")


def test_unavailable_inputs_schema_and_parameter_change_branches() -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    current = pd.DataFrame(
        {
            "member_id": ["SYNTH_MEMBER_01"],
            "scenario": ["moderate"],
            "exposure": [1.0],
        }
    )

    scorecard, summary = engine.run(
        current,
        baseline=pd.DataFrame(),
        current_parameters={"nested": {"alpha": 2.0}, "mode": "new"},
        previous_parameters={
            "nested": {"alpha": 1.0},
            "mode": "old",
            "removed": 1,
        },
        current_sensitivity=pd.DataFrame({"parameter": ["x"]}),
        previous_sensitivity=pd.DataFrame({"parameter": ["x"]}),
        reconciliation=pd.DataFrame(
            {"difference": [2.0], "tolerance": [1.0]}
        ),
    )

    statuses = scorecard.set_index("control")["status"].to_dict()
    assert summary.overall_status == "FAIL"
    assert statuses["data_completeness"] == "FAIL"
    assert statuses["schema_changes"] == "FAIL"
    assert statuses["parameter_changes"] == "FAIL"
    assert statuses["reconciliation_failures"] == "WARN"


def test_cli_demo_run(tmp_path: Path) -> None:
    from ficc_liquidity.monitoring.monthly import main

    exit_code = main(
        [
            "--config",
            str(CONFIG),
            "--demo",
            "--output-dir",
            str(tmp_path),
            "--as-of-date",
            "2026-06-30",
        ]
    )

    assert exit_code == 0
    assert list(tmp_path.glob("monthly_monitoring_report_*.md"))
'@

Write-ManagedFile -RelativePath 'sql/monthly_monitoring.sql' -Content @'
-- Section 29 monthly model-monitoring evidence tables for DuckDB.

CREATE TABLE IF NOT EXISTS monthly_monitoring_runs (
    run_id VARCHAR PRIMARY KEY,
    as_of_date DATE NOT NULL,
    executed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    overall_status VARCHAR NOT NULL,
    pass_count INTEGER NOT NULL,
    warning_count INTEGER NOT NULL,
    failure_count INTEGER NOT NULL,
    config_hash VARCHAR,
    input_manifest_path VARCHAR,
    report_path VARCHAR
);

CREATE TABLE IF NOT EXISTS monthly_monitoring_controls (
    run_id VARCHAR NOT NULL,
    control VARCHAR NOT NULL,
    metric VARCHAR NOT NULL,
    metric_value VARCHAR,
    warning_threshold VARCHAR,
    failure_threshold VARCHAR,
    status VARCHAR NOT NULL,
    severity VARCHAR NOT NULL,
    message VARCHAR NOT NULL,
    details VARCHAR,
    PRIMARY KEY (run_id, control),
    FOREIGN KEY (run_id) REFERENCES monthly_monitoring_runs(run_id)
);

CREATE TABLE IF NOT EXISTS monthly_monitoring_issues (
    issue_id VARCHAR PRIMARY KEY,
    run_id VARCHAR NOT NULL,
    control VARCHAR NOT NULL,
    owner VARCHAR,
    due_date DATE,
    issue_status VARCHAR NOT NULL,
    disposition VARCHAR,
    closure_evidence_path VARCHAR,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at TIMESTAMP,
    FOREIGN KEY (run_id) REFERENCES monthly_monitoring_runs(run_id)
);
'@

Write-ManagedFile -RelativePath 'reports/monitoring/monthly/.gitkeep' -Content @'

'@


if (-not $SkipValidation) {
    $Python = Resolve-ProjectPython

    Write-Step "Checking Section 29 Python dependencies"
    & $Python -c "import numpy, pandas, pytest, yaml"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing the project and validation dependencies..."
        & $Python -m pip install --upgrade pip
        Assert-LastExitCode "pip upgrade"

        & $Python -m pip install -e ".[dev]"
        if ($LASTEXITCODE -ne 0) {
            & $Python -m pip install -e . pytest pandas numpy pyyaml
            Assert-LastExitCode "Project dependency installation"
        }
    }

    & $Python -c "import importlib.util; raise SystemExit(0 if importlib.util.find_spec('ruff') else 1)"
    if ($LASTEXITCODE -eq 0) {
        Write-Step "Formatting and linting Section 29 code"
        & $Python -m ruff format `
            src/ficc_liquidity/monitoring `
            scripts/run_monthly_monitoring.py `
            tests/test_monthly_monitoring.py
        Assert-LastExitCode "Ruff formatting"

        & $Python -m ruff check --fix `
            src/ficc_liquidity/monitoring `
            scripts/run_monthly_monitoring.py `
            tests/test_monthly_monitoring.py
        Assert-LastExitCode "Ruff lint remediation"

        & $Python -m ruff check `
            src/ficc_liquidity/monitoring `
            scripts/run_monthly_monitoring.py `
            tests/test_monthly_monitoring.py
        Assert-LastExitCode "Ruff validation"
    }
    else {
        Write-Warning "Ruff is not installed in the active environment; pytest and compile gates will still run."
    }

    Write-Step "Running Section 29 automated tests"
    & $Python -m pytest `
        -o 'addopts=' `
        tests/test_monthly_monitoring.py `
        --cov=ficc_liquidity.monitoring `
        --cov-report=term-missing `
        --cov-fail-under=85 `
        -q
    Assert-LastExitCode "Section 29 pytest gate"

    Write-Step "Running Python compilation gate"
    & $Python -m compileall -q `
        src/ficc_liquidity/monitoring `
        scripts/run_monthly_monitoring.py `
        tests/test_monthly_monitoring.py
    Assert-LastExitCode "Section 29 compilation gate"

    Write-Step "Creating deterministic monthly monitoring demo evidence"
    $demoOutput = Join-Path $ProjectRoot "reports\monitoring\monthly\demo"
    New-Item -ItemType Directory -Path $demoOutput -Force | Out-Null
    & $Python scripts/run_monthly_monitoring.py `
        --demo `
        --as-of-date 2026-06-30 `
        --output-dir $demoOutput
    Assert-LastExitCode "Section 29 demo monitoring run"
}

if (-not $SkipGit) {
    Write-Step "Committing Section 29 deliverables"
    $controlledPaths = @(
        "configs/monitoring.yaml",
        "docs/monthly_monitoring_framework.md",
        "src/ficc_liquidity/monitoring/__init__.py",
        "src/ficc_liquidity/monitoring/monthly.py",
        "scripts/run_monthly_monitoring.py",
        "tests/test_monthly_monitoring.py",
        "sql/monthly_monitoring.sql",
        "reports/monitoring/monthly/.gitkeep"
    )

    $scriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
    if ($scriptPath.StartsWith($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $scriptRelative = $scriptPath.Substring($ProjectRoot.Length).TrimStart("\", "/")
        if ($scriptRelative) {
            $controlledPaths += ($scriptRelative -replace "\\", "/")
        }
    }

    foreach ($path in $controlledPaths | Select-Object -Unique) {
        if (Test-Path -LiteralPath (Join-Path $ProjectRoot ($path -replace "/", "\"))) {
            & git add -- $path
            Assert-LastExitCode "Staging $path"
        }
    }

    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No new controlled changes required a commit."
    }
    else {
        & git commit -m "Phase VIII Section 29: monthly monitoring framework"
        Assert-LastExitCode "Section 29 Git commit"
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
Completes Phase VIII, Section 29 monthly monitoring framework.

Controls implemented:
- data completeness and schema changes
- missing observations and historical-range breaches
- parameter and exposure-concentration changes
- LCR distribution and scenario-rank stability
- component-contribution and sensitivity drift
- independent reconciliation failures

Deliverables include controlled YAML thresholds, Python monitoring engine, CLI,
DuckDB evidence schema, governance documentation, deterministic demo outputs, and tests.
"@
                & gh pr create `
                    --base $BaseBranch `
                    --head $Branch `
                    --title "Phase VIII Section 29: Monthly monitoring framework" `
                    --body $prBody
                Assert-LastExitCode "Creating the Section 29 pull request"
            }
        }
        else {
            Write-Warning "GitHub CLI was not found. The branch was pushed, but no pull request was created."
        }
    }
}

Write-Step "Section 29 completed"
Write-Host "Repository: $ProjectRoot"
Write-Host "Branch:     $Branch"
Write-Host "Base:       $BaseBranch"
Write-Host "Backup:     $BackupRoot"
Write-Host "Framework:  src\ficc_liquidity\monitoring\monthly.py"
Write-Host "Tests:      tests\test_monthly_monitoring.py"
Write-Host "Demo:       reports\monitoring\monthly\demo"
if (-not $Publish -and -not $SkipGit) {
    Write-Host "Publish when ready: git push -u origin $Branch"
}

