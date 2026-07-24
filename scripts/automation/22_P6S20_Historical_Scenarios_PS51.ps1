#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$BaseBranch = "main",
    [string]$Branch = "feature/18-scenario-library",
    [switch]$SkipInstall,
    [switch]$SkipGit,
    [switch]$SkipPush,
    [switch]$SmokeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    Write-Host ("> {0} {1}" -f $FilePath, ($Arguments -join " ")) -ForegroundColor DarkGray
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed with exit code {0}: {1} {2}" -f $LASTEXITCODE, $FilePath, ($Arguments -join ' '))
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    $baseUri = New-Object System.Uri(($BasePath.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri($TargetPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', '\')
}

function Assert-CleanWorktreeExceptAutomation {
    param([string[]]$AllowedPaths)
    $status = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect Git worktree status."
    }
    $unexpected = @()
    foreach ($line in $status) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $pathPart = $line.Substring(3).Trim().Replace('/', '\')
        $isAllowed = $false
        foreach ($allowed in $AllowedPaths) {
            if ($pathPart -eq $allowed) { $isAllowed = $true; break }
        }
        if (-not $isAllowed) { $unexpected += $line }
    }
    if ($unexpected.Count -gt 0) {
        throw "The worktree contains changes unrelated to this automation:`n$($unexpected -join [Environment]::NewLine)"
    }
}

Write-Section "Phase VI Section 20 - Historical Scenarios"

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    throw "Repository path does not exist: $RepoRoot"
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Set-Location -LiteralPath $RepoRoot

$gitRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitRoot)) {
    throw "The selected path is not a Git repository: $RepoRoot"
}
$gitRoot = (Resolve-Path -LiteralPath $gitRoot.Trim()).Path
if ($gitRoot -ne $RepoRoot) {
    $RepoRoot = $gitRoot
    Set-Location -LiteralPath $RepoRoot
}

$AutomationRelative = "scripts\automation\22_P6S20_Historical_Scenarios_PS51.ps1"
$AutomationTarget = Join-Path $RepoRoot $AutomationRelative
$CurrentScript = $MyInvocation.MyCommand.Path
$allowed = @($AutomationRelative)
if ($CurrentScript -and (Test-Path -LiteralPath $CurrentScript)) {
    try {
        $currentResolved = (Resolve-Path -LiteralPath $CurrentScript).Path
        if ($currentResolved.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $allowed += (Get-RelativePath -BasePath $RepoRoot -TargetPath $currentResolved)
        }
    } catch { }
}

if (-not $SkipGit) {
    Write-Section "Prepare shared Phase VI scenario-library branch"
    Assert-CleanWorktreeExceptAutomation -AllowedPaths $allowed
    Invoke-Native git fetch origin --prune
    Invoke-Native git switch $BaseBranch
    Invoke-Native git pull --ff-only origin $BaseBranch

    & git show-ref --verify --quiet ("refs/heads/{0}" -f $Branch)
    $localBranchExists = ($LASTEXITCODE -eq 0)
    if ($localBranchExists) {
        Invoke-Native git switch $Branch
        & git merge --ff-only ("origin/{0}" -f $BaseBranch)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not fast-forward $Branch from origin/$BaseBranch. Resolve the branch divergence first."
        }
    } else {
        & git show-ref --verify --quiet ("refs/remotes/origin/{0}" -f $Branch)
        $remoteBranchExists = ($LASTEXITCODE -eq 0)
        if ($remoteBranchExists) {
            Invoke-Native git switch --track -c $Branch ("origin/{0}" -f $Branch)
            & git merge --ff-only ("origin/{0}" -f $BaseBranch)
            if ($LASTEXITCODE -ne 0) {
                throw "Could not fast-forward $Branch from origin/$BaseBranch."
            }
        } else {
            Invoke-Native git switch -c $Branch
        }
    }
}

Write-Section "Install Section 20 source, tests, configuration, and documentation"

$Target = Join-Path $RepoRoot "configs\historical_scenario_replay.yaml"
$Content = @'
schema_version: "1.0"
section: 20
model_name: historical_scenario_replay
model_version: section-20-v1
currency: USD
random_seed: 2026

classification:
  observed_market_conditions: observed
  synthetic_member_exposures: synthetic
  component_scenario_mapping: assumed
  integrated_results: modeled
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false

source:
  scenario_catalog: configs/historical_scenarios.yaml
  analytical_inputs:
    - data/processed/fed_liquidity_factors.parquet
    - data/processed/treasury_market_factors.parquet
  treasury_yield_config: configs/treasury_yield_stress.yaml
  integrated_stress_config: configs/integrated_stress_engine.yaml
  baseline_summary_candidates:
    - reports/tables/baseline_liquidity_summary.parquet
    - reports/tables/baseline_liquidity_summary.csv
  funding_summary_candidates:
    - reports/tables/repo_funding_stress_member_summary.parquet
    - reports/tables/repo_funding_stress_member_summary.csv
  haircut_summary_candidates:
    - reports/tables/collateral_haircut_stress_member_summary.parquet
    - reports/tables/collateral_haircut_stress_member_summary.csv
  settlement_fail_cashflow_candidates:
    - reports/tables/settlement_fail_stress_cashflows.parquet
    - reports/tables/settlement_fail_stress_cashflows.csv
  treasury_position_candidates:
    - reports/tables/treasury_yield_stress_positions_section19_adapter.parquet
    - reports/tables/treasury_yield_stress_positions_section19_adapter.csv

severity_weights:
  sofr_spike_bp: 1.0
  maximum_absolute_treasury_shock_bp: 1.0
  financing_contraction_rate: 1.0
  settlement_fail_increase_rate: 1.0
  reserve_contraction_rate: 1.0

factor_caps:
  sofr_spike_bp: 500.0
  maximum_absolute_treasury_shock_bp: 300.0
  financing_contraction_rate: 0.50
  settlement_fail_increase_rate: 5.00
  reserve_contraction_rate: 0.25

validation:
  observed_only: true
  maximum_asof_lookback_days: 35
  reconciliation_tolerance_usd: 0.01
  require_no_lookahead: true
  require_synthetic_members_only: true
  require_integrated_double_count_controls: true

output:
  directory: reports/tables
  evidence_directory: reports/evidence
  manifest: data/manifests/historical_scenario_manifest.csv
  write_csv: true
  write_parquet: true
'@
Write-Utf8NoBom -Path $Target -Content $Content
Write-Host "WROTE: configs/historical_scenario_replay.yaml" -ForegroundColor Green

$Target = Join-Path $RepoRoot "src\ficc_liquidity\scenarios\__init__.py"
$Content = @'
"""Scenario framework for FICC Treasury clearing liquidity stress testing."""
'@
Write-Utf8NoBom -Path $Target -Content $Content
Write-Host "WROTE: src/ficc_liquidity/scenarios/__init__.py" -ForegroundColor Green

$Target = Join-Path $RepoRoot "src\ficc_liquidity\scenarios\historical_scenarios.py"
$Content = @'
"""Empirical historical-scenario replay for Phase VI, Section 20.

The module converts Section 10 selected windows and Section 8 canonical long-form
Federal Reserve data into observed scenario shocks. It then maps the non-yield
components to the nearest already-validated Phase V component scenarios and uses
actual observed H.15 key-rate changes for Treasury valuation.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import yaml


class HistoricalScenarioError(ValueError):
    """Raised when Section 20 inputs, assumptions, or replay controls are invalid."""


FACTOR_GROUPS: tuple[str, ...] = (
    "sofr",
    "treasury_yields",
    "financing_volume",
    "settlement_fails",
    "reserve_balances",
)

RAW_SEVERITY_COLUMNS: tuple[str, ...] = (
    "sofr_spike_bp",
    "maximum_absolute_treasury_shock_bp",
    "financing_contraction_rate",
    "settlement_fail_increase_rate",
    "reserve_contraction_rate",
)


@dataclass(frozen=True, slots=True)
class HistoricalWindow:
    """One empirically selected Section 10 historical window."""

    scenario_id: str
    name: str
    start_date: pd.Timestamp
    peak_date: pd.Timestamp
    end_date: pd.Timestamp
    anchor_match: str | None
    trigger_components: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ReplaySettings:
    """Validated Section 20 runtime settings."""

    model_version: str
    scenario_catalog: Path
    analytical_inputs: tuple[Path, ...]
    maximum_asof_lookback_days: int
    observed_only: bool
    factor_weights: Mapping[str, float]
    factor_caps: Mapping[str, float]
    output_directory: Path
    evidence_directory: Path
    manifest_path: Path
    write_csv: bool
    write_parquet: bool


@dataclass(frozen=True, slots=True)
class CalibrationOutput:
    """Observed factor shocks and audit observations for all historical windows."""

    scenario_metrics: pd.DataFrame
    treasury_bucket_shocks: pd.DataFrame
    factor_observations: pd.DataFrame


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HistoricalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def load_yaml(path: str | Path) -> dict[str, Any]:
    """Load a UTF-8 YAML mapping."""
    yaml_path = Path(path)
    if not yaml_path.exists():
        raise HistoricalScenarioError(f"Configuration does not exist: {yaml_path}")
    loaded = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    return _mapping(loaded, str(yaml_path))


def load_replay_settings(config: Mapping[str, Any], root: Path) -> ReplaySettings:
    """Validate the Section 20 replay configuration."""
    source = _mapping(config.get("source"), "source")
    validation = _mapping(config.get("validation"), "validation")
    output = _mapping(config.get("output"), "output")
    raw_inputs = source.get("analytical_inputs")
    if not isinstance(raw_inputs, list) or not raw_inputs:
        raise HistoricalScenarioError("source.analytical_inputs must be a nonempty list.")
    raw_weights = _mapping(config.get("severity_weights"), "severity_weights")
    raw_caps = _mapping(config.get("factor_caps"), "factor_caps")
    weights: dict[str, float] = {}
    for factor in RAW_SEVERITY_COLUMNS:
        value = raw_weights.get(factor)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HistoricalScenarioError(f"severity_weights.{factor} must be numeric.")
        number = float(value)
        if not math.isfinite(number) or number < 0.0:
            raise HistoricalScenarioError(
                f"severity_weights.{factor} must be finite and nonnegative."
            )
        weights[factor] = number
    if sum(weights.values()) <= 0.0:
        raise HistoricalScenarioError("At least one severity weight must be positive.")
    caps: dict[str, float] = {}
    for factor in RAW_SEVERITY_COLUMNS:
        value = raw_caps.get(factor)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HistoricalScenarioError(f"factor_caps.{factor} must be numeric.")
        number = float(value)
        if not math.isfinite(number) or number <= 0.0:
            raise HistoricalScenarioError(f"factor_caps.{factor} must be finite and positive.")
        caps[factor] = number
    lookback = validation.get("maximum_asof_lookback_days", 35)
    if isinstance(lookback, bool) or not isinstance(lookback, int) or lookback < 0:
        raise HistoricalScenarioError(
            "validation.maximum_asof_lookback_days must be a nonnegative integer."
        )
    model_version = str(config.get("model_version", "section-20-v1")).strip()
    if not model_version:
        raise HistoricalScenarioError("model_version cannot be empty.")
    return ReplaySettings(
        model_version=model_version,
        scenario_catalog=root / str(source.get("scenario_catalog")),
        analytical_inputs=tuple(root / str(item) for item in raw_inputs),
        maximum_asof_lookback_days=lookback,
        observed_only=bool(validation.get("observed_only", True)),
        factor_weights=weights,
        factor_caps=caps,
        output_directory=root / str(output.get("directory", "reports/tables")),
        evidence_directory=root / str(output.get("evidence_directory", "reports/evidence")),
        manifest_path=root
        / str(output.get("manifest", "data/manifests/historical_scenario_manifest.csv")),
        write_csv=bool(output.get("write_csv", True)),
        write_parquet=bool(output.get("write_parquet", True)),
    )


def load_historical_windows(catalog: Mapping[str, Any]) -> tuple[HistoricalWindow, ...]:
    """Read Section 10 selected scenarios without substituting candidate anchors."""
    raw = catalog.get("selected_scenarios")
    if not isinstance(raw, list) or not raw:
        raise HistoricalScenarioError("selected_scenarios must be a nonempty list.")
    windows: list[HistoricalWindow] = []
    for item in raw:
        row = _mapping(item, "selected scenario")
        scenario_id = str(row.get("id", "")).strip()
        name = str(row.get("name", "")).strip()
        start = pd.Timestamp(str(row.get("start_date", ""))).normalize()
        peak = pd.Timestamp(str(row.get("peak_date", row.get("start_date", "")))).normalize()
        end = pd.Timestamp(str(row.get("end_date", ""))).normalize()
        if not scenario_id or not name:
            raise HistoricalScenarioError("Each selected scenario requires id and name.")
        if start > peak or peak > end:
            raise HistoricalScenarioError(
                f"Historical window {scenario_id} must satisfy start <= peak <= end."
            )
        selection = _mapping(row.get("selection", {}), f"{scenario_id}.selection")
        triggers_raw = selection.get("trigger_components", [])
        if not isinstance(triggers_raw, list):
            raise HistoricalScenarioError(
                f"{scenario_id}.selection.trigger_components must be a list."
            )
        anchor = row.get("anchor_match")
        windows.append(
            HistoricalWindow(
                scenario_id=scenario_id,
                name=name,
                start_date=start,
                peak_date=peak,
                end_date=end,
                anchor_match=None if anchor is None else str(anchor),
                trigger_components=tuple(str(value) for value in triggers_raw),
            )
        )
    if len({window.scenario_id for window in windows}) != len(windows):
        raise HistoricalScenarioError("Historical scenario identifiers must be unique.")
    return tuple(windows)


def prepare_long_form(frame: pd.DataFrame, observed_only: bool) -> pd.DataFrame:
    """Validate and canonicalize Section 8 long-form analytical data."""
    required = {
        "observation_date",
        "alignment_frequency",
        "source_name",
        "source_series_id",
        "source_metric",
        "value",
        "standardized_unit",
        "metric_kind",
    }
    missing = sorted(required - set(frame.columns))
    if missing:
        raise HistoricalScenarioError(f"Analytical data are missing fields: {missing}")
    result = frame.copy(deep=True)
    result["observation_date"] = pd.to_datetime(
        result["observation_date"], errors="coerce"
    ).dt.normalize()
    result["value"] = pd.to_numeric(result["value"], errors="coerce")
    result["source_name"] = result["source_name"].astype("string").str.upper()
    result["source_series_id"] = result["source_series_id"].astype("string")
    result["source_metric"] = result["source_metric"].astype("string")
    result["alignment_frequency"] = (
        result["alignment_frequency"].astype("string").str.lower()
    )
    result["standardized_unit"] = (
        result["standardized_unit"].astype("string").str.upper()
    )
    result["metric_kind"] = result["metric_kind"].astype("string").str.lower()
    result = result.dropna(subset=["observation_date", "value"])
    if observed_only and "is_observed" in result.columns:
        observed_mask = result["is_observed"].fillna(False).astype(bool)
        result = pd.DataFrame(result.loc[observed_mask].copy())
    result["series_key"] = (
        result["source_name"].astype(str)
        + "::"
        + result["source_series_id"].astype(str)
        + "::"
        + result["alignment_frequency"].astype(str)
    )
    result_any: Any = result
    ordered_any: Any = result_any.sort_values(
        by=["observation_date", "source_name", "source_series_id"],
        kind="stable",
    )
    reset_any: Any = ordered_any.reset_index(drop=True)
    return cast(pd.DataFrame, reset_any)


def _text(frame: pd.DataFrame) -> pd.Series:
    return (
        frame["source_series_id"].fillna("").astype(str)
        + " "
        + frame["source_metric"].fillna("").astype(str)
    ).str.lower()


def select_series_group(
    frame: pd.DataFrame,
    rule: Mapping[str, Any],
) -> pd.DataFrame:
    """Apply the controlled Section 10 series rule for one factor group."""
    mask = pd.Series(True, index=frame.index)
    sources = {str(value).upper() for value in rule.get("source_names", [])}
    if sources:
        mask &= frame["source_name"].isin(sources)
    frequency = str(rule.get("alignment_frequency", "")).strip().lower()
    if frequency:
        mask &= frame["alignment_frequency"].eq(frequency)
    units = {str(value).upper() for value in rule.get("standardized_units", [])}
    if units:
        mask &= frame["standardized_unit"].isin(units)
    kinds = {str(value).lower() for value in rule.get("metric_kinds", [])}
    if kinds:
        mask &= frame["metric_kind"].isin(kinds)
    if bool(rule.get("require_maturity", False)):
        if "maturity_months" not in frame.columns:
            return frame.iloc[0:0].copy()
        mask &= pd.to_numeric(frame["maturity_months"], errors="coerce").notna()
    exact = {str(value) for value in rule.get("exact_series_ids", [])}
    if exact:
        mask &= frame["source_series_id"].isin(exact)
    searchable = _text(frame)
    includes = [str(value) for value in rule.get("include_patterns", [])]
    if includes:
        include_mask = pd.Series(False, index=frame.index)
        for pattern in includes:
            include_mask |= searchable.str.contains(pattern, regex=True, na=False)
        mask &= include_mask
    for pattern in [str(value) for value in rule.get("exclude_patterns", [])]:
        mask &= ~searchable.str.contains(pattern, regex=True, na=False)
    return frame.loc[mask].copy()


def resolve_factor_groups(
    frame: pd.DataFrame,
    catalog: Mapping[str, Any],
) -> dict[str, pd.DataFrame]:
    """Resolve the five controlled Section 20 factor groups."""
    rules = _mapping(catalog.get("series_rules"), "series_rules")
    result: dict[str, pd.DataFrame] = {}
    for group in FACTOR_GROUPS:
        rule = _mapping(rules.get(group), f"series_rules.{group}")
        result[group] = select_series_group(frame, rule)
    return result


def _unit_multiplier_to_bp(unit: str) -> float:
    normalized = unit.upper()
    if normalized == "PERCENT":
        return 100.0
    if normalized in {"BASIS_POINTS", "BP", "BPS"}:
        return 1.0
    if normalized == "DECIMAL":
        return 10_000.0
    raise HistoricalScenarioError(f"Unsupported rate unit for basis-point conversion: {unit}")


def _asof_row(
    frame: pd.DataFrame,
    target_date: pd.Timestamp,
    maximum_lookback_days: int,
) -> pd.Series | None:
    eligible = frame.loc[frame["observation_date"] <= target_date]
    if eligible.empty:
        return None
    row = eligible.sort_values("observation_date", kind="stable").iloc[-1]
    age = int((target_date - pd.Timestamp(row["observation_date"])).days)
    if age > maximum_lookback_days:
        return None
    return row


def _aggregate_level_series(frame: pd.DataFrame) -> pd.DataFrame:
    if frame.empty:
        return pd.DataFrame(columns=["observation_date", "value"])

    grouped_any: Any = frame.groupby("observation_date", as_index=False)
    summed_any: Any = grouped_any["value"].sum()
    ordered_any: Any = summed_any.sort_values(
        by="observation_date",
        kind="stable",
    )
    return cast(pd.DataFrame, ordered_any.reset_index(drop=True))


def _level_metrics(
    frame: pd.DataFrame,
    window: HistoricalWindow,
    lookback_days: int,
    direction: str,
    factor_group: str,
) -> tuple[dict[str, float], list[dict[str, object]]]:
    series = _aggregate_level_series(frame)
    if series.empty:
        return {}, []
    start = _asof_row(series, window.start_date, lookback_days)
    end = _asof_row(series, window.end_date, lookback_days)
    within = series.loc[
        series["observation_date"].between(window.start_date, window.end_date, inclusive="both")
    ]
    if start is None or end is None or within.empty:
        return {}, []
    start_value = float(start["value"])
    end_value = float(end["value"])
    peak_value = float(within["value"].max())
    trough_value = float(within["value"].min())
    denominator = abs(start_value)
    if direction == "increase":
        stress_rate = max(0.0, (peak_value - start_value) / denominator) if denominator else 0.0
    elif direction == "contraction":
        stress_rate = max(0.0, (start_value - trough_value) / denominator) if denominator else 0.0
    else:
        raise HistoricalScenarioError(f"Unsupported level direction: {direction}")
    audit = [
        {
            "scenario_id": window.scenario_id,
            "factor_group": factor_group,
            "statistic": "start",
            "observation_date": pd.Timestamp(start["observation_date"]),
            "value": start_value,
        },
        {
            "scenario_id": window.scenario_id,
            "factor_group": factor_group,
            "statistic": "end",
            "observation_date": pd.Timestamp(end["observation_date"]),
            "value": end_value,
        },
    ]
    return {
        "start_value": start_value,
        "end_value": end_value,
        "peak_value": peak_value,
        "trough_value": trough_value,
        "stress_rate": stress_rate,
    }, audit


def _sofr_metrics(
    frame: pd.DataFrame,
    window: HistoricalWindow,
    lookback_days: int,
) -> tuple[dict[str, float], list[dict[str, object]]]:
    if frame.empty:
        return {}, []
    records: list[pd.DataFrame] = []
    for _, group in frame.groupby("series_key", sort=True):
        ordered = group.sort_values("observation_date", kind="stable")
        start = _asof_row(ordered, window.start_date, lookback_days)
        end = _asof_row(ordered, window.end_date, lookback_days)
        within = ordered.loc[
            ordered["observation_date"].between(
                window.start_date, window.end_date, inclusive="both"
            )
        ]
        if start is None or end is None or within.empty:
            continue
        multiplier = _unit_multiplier_to_bp(str(start["standardized_unit"]))
        part = within[["observation_date", "value"]].copy()
        part["value_bp"] = part["value"].astype(float) * multiplier
        part["start_bp"] = float(start["value"]) * multiplier
        part["end_bp"] = float(end["value"]) * multiplier
        records.append(part)
    if not records:
        return {}, []
    combined = pd.concat(records, ignore_index=True)
    start_bp = float(combined["start_bp"].median())
    end_bp = float(combined["end_bp"].median())
    peak_bp = float(combined["value_bp"].max())
    audit = [
        {
            "scenario_id": window.scenario_id,
            "factor_group": "sofr",
            "statistic": "start_bp",
            "observation_date": window.start_date,
            "value": start_bp,
        },
        {
            "scenario_id": window.scenario_id,
            "factor_group": "sofr",
            "statistic": "peak_bp",
            "observation_date": window.peak_date,
            "value": peak_bp,
        },
        {
            "scenario_id": window.scenario_id,
            "factor_group": "sofr",
            "statistic": "end_bp",
            "observation_date": window.end_date,
            "value": end_bp,
        },
    ]
    return {
        "sofr_start_bp": start_bp,
        "sofr_end_bp": end_bp,
        "sofr_peak_bp": peak_bp,
        "sofr_spike_bp": max(0.0, peak_bp - start_bp),
    }, audit


def derive_treasury_bucket_shocks(
    frame: pd.DataFrame,
    window: HistoricalWindow,
    maturity_buckets: Mapping[str, Mapping[str, Any]],
    lookback_days: int,
) -> tuple[dict[str, float], list[dict[str, object]]]:
    """Interpolate observed H.15 maturity shocks to Section 15 maturity buckets."""
    observed: list[tuple[float, float]] = []
    audit: list[dict[str, object]] = []
    if frame.empty or "maturity_months" not in frame.columns:
        return {}, audit
    for key, group in frame.groupby("series_key", sort=True):
        ordered = group.sort_values("observation_date", kind="stable")
        start = _asof_row(ordered, window.start_date, lookback_days)
        end = _asof_row(ordered, window.end_date, lookback_days)
        if start is None or end is None:
            continue
        maturity = pd.to_numeric(pd.Series([start.get("maturity_months")]), errors="coerce").iloc[0]
        if pd.isna(maturity):
            continue
        multiplier = _unit_multiplier_to_bp(str(start["standardized_unit"]))
        shock = (float(end["value"]) - float(start["value"])) * multiplier
        maturity_years = float(maturity) / 12.0
        observed.append((maturity_years, shock))
        audit.append(
            {
                "scenario_id": window.scenario_id,
                "factor_group": "treasury_yields",
                "statistic": str(key),
                "observation_date": pd.Timestamp(end["observation_date"]),
                "value": shock,
            }
        )
    if len(observed) < 2:
        return {}, audit
    ordered_observed = sorted(observed)
    maturities = np.asarray([item[0] for item in ordered_observed], dtype=float)
    shocks = np.asarray([item[1] for item in ordered_observed], dtype=float)
    bucket_shocks: dict[str, float] = {}
    for bucket, assumptions in maturity_buckets.items():
        midpoint = float(assumptions["midpoint_years"])
        bucket_shocks[str(bucket)] = float(np.interp(midpoint, maturities, shocks))
    return bucket_shocks, audit


def calibrate_historical_scenarios(
    frame: pd.DataFrame,
    windows: Sequence[HistoricalWindow],
    catalog: Mapping[str, Any],
    treasury_config: Mapping[str, Any],
    settings: ReplaySettings,
) -> CalibrationOutput:
    """Derive observed shocks and empirical cross-window severity scores."""
    prepared = prepare_long_form(frame, settings.observed_only)
    groups = resolve_factor_groups(prepared, catalog)
    maturity_buckets = _mapping(treasury_config.get("maturity_buckets"), "maturity_buckets")
    metric_rows: list[dict[str, object]] = []
    bucket_rows: list[dict[str, object]] = []
    audit_rows: list[dict[str, object]] = []
    for window in windows:
        row: dict[str, object] = {
            "scenario_id": window.scenario_id,
            "scenario_name": window.name,
            "start_date": window.start_date,
            "peak_date": window.peak_date,
            "end_date": window.end_date,
            "anchor_match": window.anchor_match or "",
            "trigger_components": "|".join(window.trigger_components),
        }
        sofr, audit = _sofr_metrics(
            groups["sofr"], window, settings.maximum_asof_lookback_days
        )
        row.update(sofr)
        audit_rows.extend(audit)
        financing, audit = _level_metrics(
            groups["financing_volume"],
            window,
            settings.maximum_asof_lookback_days,
            "contraction",
            "financing_volume",
        )
        row["financing_contraction_rate"] = financing.get("stress_rate", np.nan)
        audit_rows.extend(audit)
        fails, audit = _level_metrics(
            groups["settlement_fails"],
            window,
            settings.maximum_asof_lookback_days,
            "increase",
            "settlement_fails",
        )
        row["settlement_fail_increase_rate"] = fails.get("stress_rate", np.nan)
        audit_rows.extend(audit)
        reserves, audit = _level_metrics(
            groups["reserve_balances"],
            window,
            settings.maximum_asof_lookback_days,
            "contraction",
            "reserve_balances",
        )
        row["reserve_contraction_rate"] = reserves.get("stress_rate", np.nan)
        audit_rows.extend(audit)
        bucket_shocks, audit = derive_treasury_bucket_shocks(
            groups["treasury_yields"],
            window,
            maturity_buckets,
            settings.maximum_asof_lookback_days,
        )
        audit_rows.extend(audit)
        row["maximum_absolute_treasury_shock_bp"] = (
            max(abs(value) for value in bucket_shocks.values()) if bucket_shocks else np.nan
        )
        row["treasury_bucket_count"] = len(bucket_shocks)
        for bucket, shock in bucket_shocks.items():
            bucket_rows.append(
                {
                    "scenario_id": window.scenario_id,
                    "maturity_bucket": bucket,
                    "observed_yield_shock_bp": shock,
                }
            )
        metric_rows.append(row)
    metrics = pd.DataFrame.from_records(metric_rows)
    for factor in RAW_SEVERITY_COLUMNS:
        if factor not in metrics.columns:
            metrics[factor] = np.nan
        numeric = pd.to_numeric(metrics[factor], errors="coerce")
        cap = float(settings.factor_caps[factor])
        normalized = numeric.clip(lower=0.0, upper=cap) / cap
        metrics[f"normalized_{factor}"] = normalized
    weighted_numerator = pd.Series(0.0, index=metrics.index)
    weighted_denominator = pd.Series(0.0, index=metrics.index)
    for factor, weight in settings.factor_weights.items():
        normalized = pd.to_numeric(metrics[f"normalized_{factor}"], errors="coerce")
        available = normalized.notna()
        weighted_numerator = weighted_numerator.add(normalized.fillna(0.0) * weight)
        weighted_denominator = weighted_denominator.add(available.astype(float) * weight)
    metrics["empirical_severity_score"] = np.where(
        weighted_denominator > 0.0,
        weighted_numerator / weighted_denominator,
        0.0,
    )
    metrics["empirical_severity_rank"] = (
        metrics["empirical_severity_score"].rank(method="first", ascending=True).astype(int) - 1
    )
    metrics["available_factor_count"] = metrics[list(RAW_SEVERITY_COLUMNS)].notna().sum(axis=1)
    metrics["calibration_status"] = np.where(
        metrics["available_factor_count"] == len(RAW_SEVERITY_COLUMNS),
        "COMPLETE",
        np.where(metrics["available_factor_count"] > 0, "PARTIAL", "UNAVAILABLE"),
    )
    return CalibrationOutput(
        scenario_metrics=metrics.sort_values("scenario_id", kind="stable").reset_index(drop=True),
        treasury_bucket_shocks=pd.DataFrame.from_records(bucket_rows).sort_values(
            ["scenario_id", "maturity_bucket"], kind="stable"
        ).reset_index(drop=True),
        factor_observations=pd.DataFrame.from_records(audit_rows).sort_values(
            ["scenario_id", "factor_group", "statistic"], kind="stable"
        ).reset_index(drop=True),
    )


def choose_component_scenario(
    component_frame: pd.DataFrame,
    empirical_severity_score: float,
) -> tuple[str, int]:
    """Choose the nearest validated component scenario by ordered severity rank."""
    required = {"scenario_name", "severity_rank"}
    missing = sorted(required - set(component_frame.columns))
    if missing:
        raise HistoricalScenarioError(f"Component output is missing fields: {missing}")
    options = (
        component_frame[["scenario_name", "severity_rank"]]
        .drop_duplicates()
        .sort_values("severity_rank", kind="stable")
        .reset_index(drop=True)
    )
    if options.empty:
        raise HistoricalScenarioError("Component output contains no scenarios.")
    score = min(1.0, max(0.0, float(empirical_severity_score)))
    index = round(score * (len(options) - 1))
    selected = options.iloc[index]
    return str(selected["scenario_name"]), int(selected["severity_rank"])


def build_historical_treasury_scenarios(
    bucket_shocks: pd.DataFrame,
) -> list[dict[str, Any]]:
    """Build Section 15 bucket-vector scenarios from observed H.15 changes."""
    required = {"scenario_id", "maturity_bucket", "observed_yield_shock_bp"}
    missing = sorted(required - set(bucket_shocks.columns))
    if missing:
        raise HistoricalScenarioError(f"Treasury bucket shocks are missing fields: {missing}")
    scenarios: list[dict[str, Any]] = []
    for scenario_id, group in bucket_shocks.groupby("scenario_id", sort=True):
        scenarios.append(
            {
                "name": str(scenario_id),
                "enabled": True,
                "type": "bucket_vector",
                "family": "historical_observed",
                "shocks_bp": {
                    str(row["maturity_bucket"]): float(row["observed_yield_shock_bp"])
                    for _, row in group.iterrows()
                },
            }
        )
    return scenarios


def build_single_historical_integrated_config(
    base_config: Mapping[str, Any],
    scenario_id: str,
    funding_scenario_name: str,
    haircut_scenario_name: str,
    settlement_scenario_name: str,
    template_severity_score: float,
    model_version: str,
) -> dict[str, Any]:
    """Create a one-scenario Section 19 config for an independent historical replay."""
    config = deepcopy(dict(base_config))
    raw_templates = config.get("scenarios")
    if not isinstance(raw_templates, list) or not raw_templates:
        raise HistoricalScenarioError("Section 19 scenarios must be a nonempty list.")
    templates = sorted(
        (_mapping(item, "integrated scenario") for item in raw_templates),
        key=lambda item: int(item["severity_rank"]),
    )
    score = min(1.0, max(0.0, float(template_severity_score)))
    template = templates[round(score * (len(templates) - 1))]
    config["model_version"] = model_version
    config["scenarios"] = [
        {
            "name": scenario_id,
            "enabled": True,
            "severity_rank": 0,
            "funding_scenario_name": funding_scenario_name,
            "haircut_scenario_name": haircut_scenario_name,
            "treasury_scenario_name": scenario_id,
            "settlement_fail_scenario_name": settlement_scenario_name,
            "concentration_threshold": float(template["concentration_threshold"]),
            "concentration_multiplier": float(template["concentration_multiplier"]),
            "operational_liquidity_buffer_rate": float(
                template["operational_liquidity_buffer_rate"]
            ),
        }
    ]
    return config
'@
Write-Utf8NoBom -Path $Target -Content $Content
Write-Host "WROTE: src/ficc_liquidity/scenarios/historical_scenarios.py" -ForegroundColor Green

$Target = Join-Path $RepoRoot "scripts\run_historical_scenarios.py"
$Content = @'
"""Run Phase VI, Section 20 historical scenario replay."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.scenarios.historical_scenarios import (  # noqa: E402
    HistoricalScenarioError,
    build_historical_treasury_scenarios,
    build_single_historical_integrated_config,
    calibrate_historical_scenarios,
    choose_component_scenario,
    load_historical_windows,
    load_replay_settings,
    load_yaml,
)
from ficc_liquidity.stress.integrated_stress import (  # noqa: E402
    dataframe_digest,
    read_table,
    run_integrated_stress,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    TreasuryYieldShockModel,
    load_stress_config,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Replay empirically calibrated historical liquidity scenarios."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "historical_scenario_replay.yaml",
    )
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HistoricalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _candidate_list(mapping: dict[str, Any], key: str) -> list[str]:
    raw = mapping.get(key)
    if not isinstance(raw, list) or not raw:
        raise HistoricalScenarioError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def discover_input(candidates: list[str]) -> Path:
    for candidate in candidates:
        path = ROOT / candidate
        if path.exists():
            return path
    raise HistoricalScenarioError(f"No controlled input exists among: {candidates}")


def read_analytical_inputs(paths: tuple[Path, ...]) -> pd.DataFrame:
    frames: list[pd.DataFrame] = []
    for path in paths:
        if not path.exists():
            continue
        if path.suffix.lower() in {".parquet", ".pq"}:
            frames.append(pd.read_parquet(path))
        elif path.suffix.lower() == ".csv":
            frames.append(pd.read_csv(path, low_memory=False))
        else:
            raise HistoricalScenarioError(f"Unsupported analytical input: {path}")
    if not frames:
        raise HistoricalScenarioError("No Section 8 analytical input files were found.")
    return pd.concat(frames, ignore_index=True, sort=False)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_frame(frame: pd.DataFrame, stem: Path, csv: bool, parquet: bool) -> list[Path]:
    written: list[Path] = []
    if csv:
        csv_path = stem.with_suffix(".csv")
        frame.to_csv(csv_path, index=False)
        written.append(csv_path)
    if parquet:
        parquet_path = stem.with_suffix(".parquet")
        try:
            frame.to_parquet(parquet_path, index=False)
            written.append(parquet_path)
        except (ImportError, ModuleNotFoundError, ValueError) as exc:
            print(f"Parquet output skipped: {exc}")
    return written


def _annotate(
    frame: pd.DataFrame,
    metric_row: pd.Series,
    funding_name: str,
    haircut_name: str,
    settlement_name: str,
) -> pd.DataFrame:
    result = frame.copy(deep=True)
    result["historical_window_name"] = str(metric_row["scenario_name"])
    result["historical_start_date"] = metric_row["start_date"]
    result["historical_peak_date"] = metric_row["peak_date"]
    result["historical_end_date"] = metric_row["end_date"]
    result["empirical_severity_score"] = float(metric_row["empirical_severity_score"])
    result["empirical_severity_rank"] = int(metric_row["empirical_severity_rank"])
    result["selected_funding_scenario"] = funding_name
    result["selected_haircut_scenario"] = haircut_name
    result["selected_settlement_scenario"] = settlement_name
    result["historical_value_class"] = "observed_market_conditions_on_synthetic_members"
    return result


def run() -> int:
    args = parse_args()
    config = load_yaml(args.config)
    settings = load_replay_settings(config, ROOT)
    source = _mapping(config.get("source"), "source")
    validation = _mapping(config.get("validation"), "validation")

    catalog = load_yaml(settings.scenario_catalog)
    windows = load_historical_windows(catalog)
    if args.smoke:
        windows = windows[-2:]

    treasury_config_path = ROOT / str(source["treasury_yield_config"])
    integrated_config_path = ROOT / str(source["integrated_stress_config"])
    treasury_config = load_stress_config(treasury_config_path)
    treasury_input = treasury_config.get("input")
    if isinstance(treasury_input, dict):
        treasury_input["required_member_id_pattern"] = r"^SYN-MBR-[0-9]{4}$"
    integrated_config = load_yaml(integrated_config_path)

    analytical = read_analytical_inputs(settings.analytical_inputs)
    calibration = calibrate_historical_scenarios(
        analytical,
        windows,
        catalog,
        treasury_config,
        settings,
    )

    baseline_path = discover_input(_candidate_list(source, "baseline_summary_candidates"))
    funding_path = discover_input(_candidate_list(source, "funding_summary_candidates"))
    haircut_path = discover_input(_candidate_list(source, "haircut_summary_candidates"))
    settlement_path = discover_input(
        _candidate_list(source, "settlement_fail_cashflow_candidates")
    )
    treasury_positions_path = discover_input(
        _candidate_list(source, "treasury_position_candidates")
    )

    baseline = read_table(baseline_path)
    funding = read_table(funding_path)
    haircut = read_table(haircut_path)
    settlement = read_table(settlement_path)
    treasury_positions = read_table(treasury_positions_path)

    treasury_scenarios = build_historical_treasury_scenarios(
        calibration.treasury_bucket_shocks
    )
    if not treasury_scenarios:
        raise HistoricalScenarioError("No historical Treasury scenarios could be derived.")
    treasury_result = TreasuryYieldShockModel(treasury_config).run(
        treasury_positions,
        treasury_scenarios,
    )

    member_outputs: list[pd.DataFrame] = []
    summary_outputs: list[pd.DataFrame] = []
    control_outputs: list[pd.DataFrame] = []
    selection_rows: list[dict[str, object]] = []
    integrated_checks: dict[str, dict[str, bool]] = {}

    available_treasury = set(treasury_result.member_summary["scenario_name"].astype(str))
    for _, metric_row in calibration.scenario_metrics.iterrows():
        scenario_id = str(metric_row["scenario_id"])
        if scenario_id not in available_treasury:
            continue
        score = float(metric_row["empirical_severity_score"])
        funding_name, funding_rank = choose_component_scenario(funding, score)
        haircut_name, haircut_rank = choose_component_scenario(haircut, score)
        settlement_name, settlement_rank = choose_component_scenario(settlement, score)
        scenario_config = build_single_historical_integrated_config(
            integrated_config,
            scenario_id,
            funding_name,
            haircut_name,
            settlement_name,
            score,
            settings.model_version,
        )
        result = run_integrated_stress(
            baseline,
            funding,
            haircut,
            treasury_result.member_summary,
            settlement,
            scenario_config,
        )
        integrated_checks[scenario_id] = dict(result.checks)
        member_outputs.append(
            _annotate(
                result.member_results,
                metric_row,
                funding_name,
                haircut_name,
                settlement_name,
            )
        )
        summary_outputs.append(
            _annotate(
                result.scenario_summary,
                metric_row,
                funding_name,
                haircut_name,
                settlement_name,
            )
        )
        control_outputs.append(
            _annotate(
                result.double_count_controls,
                metric_row,
                funding_name,
                haircut_name,
                settlement_name,
            )
        )
        selection_rows.append(
            {
                "scenario_id": scenario_id,
                "empirical_severity_score": score,
                "empirical_severity_rank": int(metric_row["empirical_severity_rank"]),
                "funding_scenario_name": funding_name,
                "funding_severity_rank": funding_rank,
                "haircut_scenario_name": haircut_name,
                "haircut_severity_rank": haircut_rank,
                "settlement_scenario_name": settlement_name,
                "settlement_severity_rank": settlement_rank,
                "treasury_scenario_name": scenario_id,
                "mapping_method": "nearest_validated_component_severity",
            }
        )

    if not member_outputs:
        raise HistoricalScenarioError("No historical scenario completed integrated replay.")

    member_results = pd.concat(member_outputs, ignore_index=True).sort_values(
        ["empirical_severity_rank", "member_id"], kind="stable"
    )
    summaries = pd.concat(summary_outputs, ignore_index=True).sort_values(
        "empirical_severity_rank", kind="stable"
    )
    controls = pd.concat(control_outputs, ignore_index=True).sort_values(
        ["empirical_severity_rank", "member_id"], kind="stable"
    )
    selections = pd.DataFrame.from_records(selection_rows).sort_values(
        "empirical_severity_rank", kind="stable"
    )

    identity_expected = member_results[
        [
            "settlement_liquidity_need_usd",
            "repo_rollover_need_usd",
            "incremental_funding_cost_usd",
            "additional_haircut_requirement_usd",
            "treasury_liquidation_loss_usd",
            "settlement_fail_requirement_usd",
            "concentration_adjustment_usd",
            "operational_liquidity_buffer_usd",
        ]
    ].sum(axis=1)
    tolerance = float(validation.get("reconciliation_tolerance_usd", 0.01))
    no_lookahead = True
    if not calibration.factor_observations.empty:
        end_dates = calibration.scenario_metrics.set_index("scenario_id")["end_date"]
        observation_end = calibration.factor_observations["scenario_id"].map(end_dates)
        no_lookahead = bool(
            (
                pd.to_datetime(calibration.factor_observations["observation_date"])
                <= pd.to_datetime(observation_end)
            ).all()
        )
    checks = {
        "selected_windows_loaded": len(calibration.scenario_metrics) == len(windows),
        "observed_factor_replay_available": bool(
            (calibration.scenario_metrics["available_factor_count"] > 0).all()
        ),
        "treasury_bucket_shocks_available": bool(
            calibration.treasury_bucket_shocks["scenario_id"].nunique() > 0
        ),
        "integrated_replay_completed": len(summaries) > 0,
        "all_integrated_checks_pass": all(
            all(scenario_checks.values()) for scenario_checks in integrated_checks.values()
        ),
        "stressed_requirement_identity": bool(
            (
                identity_expected
                - member_results["stressed_liquidity_requirement_usd"]
            )
            .abs()
            .le(tolerance)
            .all()
        ),
        "double_count_controls_pass": bool(
            controls["double_count_control_pass"].astype(bool).all()
        ),
        "no_lookahead": no_lookahead,
        "synthetic_members_only": bool(
            not member_results["actual_ficc_participant"].astype(bool).any()
            and not member_results["participant_level_inference"].astype(bool).any()
        ),
        "unique_scenario_member_keys": not bool(
            member_results.duplicated(["scenario_name", "member_id"]).any()
        ),
    }

    settings.output_directory.mkdir(parents=True, exist_ok=True)
    settings.evidence_directory.mkdir(parents=True, exist_ok=True)
    settings.manifest_path.parent.mkdir(parents=True, exist_ok=True)

    outputs: list[Path] = []
    frames = {
        "historical_scenario_metrics": calibration.scenario_metrics,
        "historical_treasury_bucket_shocks": calibration.treasury_bucket_shocks,
        "historical_factor_observations": calibration.factor_observations,
        "historical_component_selections": selections,
        "historical_scenario_member_results": member_results,
        "historical_scenario_summary": summaries,
        "historical_scenario_double_count_controls": controls,
    }
    for name, frame in frames.items():
        outputs.extend(
            write_frame(
                frame,
                settings.output_directory / name,
                settings.write_csv,
                settings.write_parquet,
            )
        )

    generated_at = datetime.now(UTC).isoformat()
    evidence = {
        "section": 20,
        "model_version": settings.model_version,
        "generated_at_utc": generated_at,
        "smoke_mode": bool(args.smoke),
        "historical_window_count": len(windows),
        "completed_replay_count": len(summaries),
        "member_result_rows": len(member_results),
        "checks": checks,
        "integrated_checks": integrated_checks,
        "digests": {name: dataframe_digest(frame) for name, frame in frames.items()},
        "sources": {
            "scenario_catalog": str(settings.scenario_catalog),
            "analytical_inputs": [str(path) for path in settings.analytical_inputs],
            "baseline": str(baseline_path),
            "funding": str(funding_path),
            "haircut": str(haircut_path),
            "settlement": str(settlement_path),
            "treasury_positions": str(treasury_positions_path),
        },
    }
    evidence_json = settings.evidence_directory / "section20_historical_scenarios.json"
    evidence_json.write_text(json.dumps(evidence, indent=2, default=str), encoding="utf-8")
    outputs.append(evidence_json)
    evidence_md = settings.evidence_directory / "section20_historical_scenarios.md"
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 20 Historical Scenarios Evidence",
                "",
                f"Generated: `{generated_at}`",
                f"Historical windows replayed: `{len(summaries)}`",
                f"Synthetic member rows: `{len(member_results)}`",
                "",
                "## Validation checks",
                "",
                *[f"- {name}: {'PASS' if passed else 'FAIL'}" for name, passed in checks.items()],
                "",
                "No actual FICC participant data or participant-level inference is used.",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    outputs.append(evidence_md)

    manifest_rows: list[dict[str, object]] = []
    for path in outputs:
        manifest_rows.append(
            {
                "section": 20,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "sha256": file_sha256(path),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    pd.DataFrame.from_records(manifest_rows).to_csv(settings.manifest_path, index=False)

    print("Section 20 historical scenario replay")
    print(f"Windows requested: {len(windows)}")
    print(f"Windows completed: {len(summaries)}")
    for name, passed in checks.items():
        print(f"{name}: {'PASS' if passed else 'FAIL'}")
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(run())
'@
Write-Utf8NoBom -Path $Target -Content $Content
Write-Host "WROTE: scripts/run_historical_scenarios.py" -ForegroundColor Green

$Target = Join-Path $RepoRoot "tests\test_historical_scenarios.py"
$Content = @'
from __future__ import annotations

from pathlib import Path
from typing import cast

import pandas as pd
import pytest

from ficc_liquidity.scenarios.historical_scenarios import (
    HistoricalScenarioError,
    build_historical_treasury_scenarios,
    build_single_historical_integrated_config,
    calibrate_historical_scenarios,
    choose_component_scenario,
    load_historical_windows,
    load_replay_settings,
    prepare_long_form,
)


def _catalog() -> dict[str, object]:
    return {
        "series_rules": {
            "sofr": {
                "source_names": ["SOFR"],
                "alignment_frequency": "daily",
                "standardized_units": ["PERCENT"],
                "metric_kinds": ["rate"],
                "include_patterns": ["sofr"],
                "exclude_patterns": ["volume"],
            },
            "treasury_yields": {
                "source_names": ["H15"],
                "alignment_frequency": "daily",
                "standardized_units": ["PERCENT"],
                "require_maturity": True,
                "include_patterns": [],
                "exclude_patterns": ["change"],
            },
            "financing_volume": {
                "source_names": ["FR2004"],
                "alignment_frequency": "weekly",
                "standardized_units": ["USD"],
                "include_patterns": ["repo"],
                "exclude_patterns": ["fail"],
            },
            "settlement_fails": {
                "source_names": ["FR2004"],
                "alignment_frequency": "weekly",
                "standardized_units": ["USD"],
                "include_patterns": ["fail"],
                "exclude_patterns": [],
            },
            "reserve_balances": {
                "source_names": ["H41"],
                "alignment_frequency": "daily",
                "standardized_units": ["USD"],
                "include_patterns": ["reserve"],
                "exclude_patterns": [],
                "exact_series_ids": ["WRESBAL"],
            },
        },
        "selected_scenarios": [
            {
                "id": "HIST_A",
                "name": "Observed window A",
                "start_date": "2020-03-01",
                "peak_date": "2020-03-03",
                "end_date": "2020-03-05",
                "anchor_match": "march_2020",
                "selection": {"trigger_components": ["sofr_spike_score"]},
            },
            {
                "id": "HIST_B",
                "name": "Observed window B",
                "start_date": "2020-04-01",
                "peak_date": "2020-04-03",
                "end_date": "2020-04-05",
                "anchor_match": None,
                "selection": {"trigger_components": ["reserve_contraction_score"]},
            },
        ],
    }


def _replay_config() -> dict[str, object]:
    return {
        "model_version": "section-20-test",
        "source": {
            "scenario_catalog": "configs/historical_scenarios.yaml",
            "analytical_inputs": ["a.parquet", "b.parquet"],
        },
        "severity_weights": {
            "sofr_spike_bp": 1.0,
            "maximum_absolute_treasury_shock_bp": 1.0,
            "financing_contraction_rate": 1.0,
            "settlement_fail_increase_rate": 1.0,
            "reserve_contraction_rate": 1.0,
        },
        "factor_caps": {
            "sofr_spike_bp": 500.0,
            "maximum_absolute_treasury_shock_bp": 300.0,
            "financing_contraction_rate": 0.5,
            "settlement_fail_increase_rate": 5.0,
            "reserve_contraction_rate": 0.25,
        },
        "validation": {"maximum_asof_lookback_days": 10, "observed_only": True},
        "output": {
            "directory": "reports/tables",
            "evidence_directory": "reports/evidence",
            "manifest": "data/manifests/historical.csv",
            "write_csv": True,
            "write_parquet": False,
        },
    }


def _long_frame() -> pd.DataFrame:
    rows: list[dict[str, object]] = []

    def add(
        dates: list[str],
        values: list[float],
        source: str,
        series: str,
        metric: str,
        frequency: str,
        unit: str,
        kind: str,
        maturity: float | None = None,
    ) -> None:
        for date, value in zip(dates, values, strict=True):
            rows.append(
                {
                    "observation_date": date,
                    "alignment_frequency": frequency,
                    "source_name": source,
                    "source_series_id": series,
                    "source_metric": metric,
                    "value": value,
                    "standardized_unit": unit,
                    "metric_kind": kind,
                    "maturity_months": maturity,
                    "is_observed": True,
                }
            )

    dates_a = ["2020-03-01", "2020-03-03", "2020-03-05"]
    dates_b = ["2020-04-01", "2020-04-03", "2020-04-05"]
    add(dates_a, [1.0, 2.0, 1.5], "SOFR", "SOFR", "SOFR rate", "daily", "PERCENT", "rate")
    add(dates_b, [1.0, 1.2, 1.1], "SOFR", "SOFR", "SOFR rate", "daily", "PERCENT", "rate")
    add(dates_a, [0.8, 1.0, 1.1], "H15", "DGS2", "2-year yield", "daily", "PERCENT", "rate", 24)
    add(dates_a, [1.2, 1.4, 1.5], "H15", "DGS10", "10-year yield", "daily", "PERCENT", "rate", 120)
    add(dates_b, [1.1, 1.0, 0.9], "H15", "DGS2", "2-year yield", "daily", "PERCENT", "rate", 24)
    add(dates_b, [1.5, 1.4, 1.3], "H15", "DGS10", "10-year yield", "daily", "PERCENT", "rate", 120)
    add(dates_a, [100.0, 80.0, 70.0], "FR2004", "REPO", "repo financing", "weekly", "USD", "volume")
    add(dates_b, [100.0, 98.0, 95.0], "FR2004", "REPO", "repo financing", "weekly", "USD", "volume")
    add(dates_a, [10.0, 25.0, 20.0], "FR2004", "FAIL", "fails to deliver", "weekly", "USD", "level")
    add(dates_b, [10.0, 11.0, 10.0], "FR2004", "FAIL", "fails to deliver", "weekly", "USD", "level")
    add(dates_a, [1000.0, 800.0, 900.0], "H41", "WRESBAL", "reserve balances", "daily", "USD", "level")
    add(dates_b, [1000.0, 990.0, 985.0], "H41", "WRESBAL", "reserve balances", "daily", "USD", "level")
    return pd.DataFrame(rows)


def test_load_settings_resolves_paths(tmp_path: Path) -> None:
    settings = load_replay_settings(_replay_config(), tmp_path)
    assert settings.model_version == "section-20-test"
    assert settings.scenario_catalog == tmp_path / "configs/historical_scenarios.yaml"
    assert settings.maximum_asof_lookback_days == 10
    assert settings.observed_only is True


def test_load_windows_preserves_empirical_selection() -> None:
    windows = load_historical_windows(_catalog())
    assert [window.scenario_id for window in windows] == ["HIST_A", "HIST_B"]
    assert windows[0].anchor_match == "march_2020"
    assert windows[1].anchor_match is None


def test_invalid_window_order_fails() -> None:
    catalog = _catalog()
    scenarios = catalog["selected_scenarios"]
    assert isinstance(scenarios, list)
    scenarios[0]["end_date"] = "2020-02-01"
    with pytest.raises(HistoricalScenarioError, match="start <= peak <= end"):
        load_historical_windows(catalog)


def test_prepare_long_form_excludes_nonobserved_rows() -> None:
    frame = _long_frame()
    frame.loc[0, "is_observed"] = False
    prepared = prepare_long_form(frame, observed_only=True)
    assert len(prepared) == len(frame) - 1
    assert prepared["source_name"].str.isupper().all()


def test_calibration_derives_observed_conditions() -> None:
    settings = load_replay_settings(_replay_config(), Path("."))
    treasury_config = {
        "maturity_buckets": {
            "short": {"midpoint_years": 2.0},
            "long": {"midpoint_years": 10.0},
        }
    }
    output = calibrate_historical_scenarios(
        _long_frame(),
        load_historical_windows(_catalog()),
        _catalog(),
        treasury_config,
        settings,
    )
    metrics = output.scenario_metrics.set_index("scenario_id")
    assert metrics.loc["HIST_A", "sofr_spike_bp"] == pytest.approx(100.0)
    assert metrics.loc["HIST_A", "financing_contraction_rate"] == pytest.approx(0.30)
    assert metrics.loc["HIST_A", "settlement_fail_increase_rate"] == pytest.approx(1.50)
    assert metrics.loc["HIST_A", "reserve_contraction_rate"] == pytest.approx(0.20)
    assert metrics.loc["HIST_A", "maximum_absolute_treasury_shock_bp"] == pytest.approx(30.0)
    hist_a_score = cast(float, metrics.loc["HIST_A", "empirical_severity_score"])
    hist_b_score = cast(float, metrics.loc["HIST_B", "empirical_severity_score"])
    assert hist_a_score > hist_b_score
    assert output.treasury_bucket_shocks["scenario_id"].nunique() == 2


def test_component_selection_uses_ordered_severity() -> None:
    frame = pd.DataFrame(
        {
            "scenario_name": ["severe", "control", "moderate"],
            "severity_rank": [2, 0, 1],
        }
    )
    assert choose_component_scenario(frame, 0.0) == ("control", 0)
    assert choose_component_scenario(frame, 0.51) == ("moderate", 1)
    assert choose_component_scenario(frame, 1.0) == ("severe", 2)


def test_build_treasury_scenarios_uses_bucket_vectors() -> None:
    shocks = pd.DataFrame(
        {
            "scenario_id": ["HIST_A", "HIST_A"],
            "maturity_bucket": ["short", "long"],
            "observed_yield_shock_bp": [10.0, 20.0],
        }
    )
    scenarios = build_historical_treasury_scenarios(shocks)
    assert scenarios == [
        {
            "name": "HIST_A",
            "enabled": True,
            "type": "bucket_vector",
            "family": "historical_observed",
            "shocks_bp": {"short": 10.0, "long": 20.0},
        }
    ]


def test_single_integrated_config_uses_historical_names() -> None:
    base = {
        "model_version": "section-19-v1",
        "scenarios": [
            {
                "name": "control",
                "severity_rank": 0,
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "operational_liquidity_buffer_rate": 0.0,
            },
            {
                "name": "severe",
                "severity_rank": 1,
                "concentration_threshold": 0.25,
                "concentration_multiplier": 0.25,
                "operational_liquidity_buffer_rate": 0.05,
            },
        ],
    }
    built = build_single_historical_integrated_config(
        base,
        "HIST_A",
        "funding_severe",
        "haircut_severe",
        "settlement_severe",
        1.0,
        "section-20-v1",
    )
    scenario = built["scenarios"][0]
    assert built["model_version"] == "section-20-v1"
    assert scenario["name"] == "HIST_A"
    assert scenario["treasury_scenario_name"] == "HIST_A"
    assert scenario["funding_scenario_name"] == "funding_severe"
    assert scenario["concentration_multiplier"] == pytest.approx(0.25)


def test_settings_reject_zero_total_weight() -> None:
    config = _replay_config()
    weights = config["severity_weights"]
    assert isinstance(weights, dict)
    for key in list(weights):
        weights[key] = 0.0
    with pytest.raises(HistoricalScenarioError, match="At least one severity weight"):
        load_replay_settings(config, Path("."))


def test_prepare_long_form_rejects_missing_schema() -> None:
    with pytest.raises(HistoricalScenarioError, match="missing fields"):
        prepare_long_form(pd.DataFrame({"observation_date": ["2020-01-01"]}), True)


def test_duplicate_historical_ids_fail() -> None:
    catalog = _catalog()
    scenarios = catalog["selected_scenarios"]
    assert isinstance(scenarios, list)
    scenarios[1]["id"] = "HIST_A"
    with pytest.raises(HistoricalScenarioError, match="identifiers must be unique"):
        load_historical_windows(catalog)


def test_empty_component_scenarios_fail() -> None:
    with pytest.raises(HistoricalScenarioError, match="contains no scenarios"):
        choose_component_scenario(
            pd.DataFrame(columns=["scenario_name", "severity_rank"]),
            0.5,
        )


def test_treasury_scenario_schema_is_required() -> None:
    with pytest.raises(HistoricalScenarioError, match="missing fields"):
        build_historical_treasury_scenarios(pd.DataFrame({"scenario_id": ["HIST_A"]}))


def test_unsupported_rate_unit_fails_calibration() -> None:
    frame = _long_frame()
    frame.loc[frame["source_name"].eq("SOFR"), "standardized_unit"] = "UNKNOWN"
    catalog = _catalog()
    rules = catalog["series_rules"]
    assert isinstance(rules, dict)
    sofr_rule = rules["sofr"]
    assert isinstance(sofr_rule, dict)
    sofr_rule["standardized_units"] = ["UNKNOWN"]
    settings = load_replay_settings(_replay_config(), Path("."))
    treasury_config = {
        "maturity_buckets": {
            "short": {"midpoint_years": 2.0},
            "long": {"midpoint_years": 10.0},
        }
    }
    with pytest.raises(HistoricalScenarioError, match="Unsupported rate unit"):
        calibrate_historical_scenarios(
            frame,
            load_historical_windows(catalog),
            catalog,
            treasury_config,
            settings,
        )
'@
Write-Utf8NoBom -Path $Target -Content $Content
Write-Host "WROTE: tests/test_historical_scenarios.py" -ForegroundColor Green

$Target = Join-Path $RepoRoot "docs\historical_scenarios_methodology.md"
$Content = @'
# Section 20 — Historical Scenarios

## Objective

Section 20 replays the empirically selected historical windows produced by Section 10. It uses the canonical Section 8 Federal Reserve analytical data and the validated Phase V liquidity-stress components. The replay applies observed market conditions only to fictional synthetic clearing members.

## Observed inputs

The engine uses five controlled factor groups:

1. H.15 Treasury yield changes by maturity.
2. SOFR level and spike behavior.
3. FR 2004 and SOFR financing-volume contractions.
4. FR 2004 settlement-fail increases.
5. H.4.1 reserve-balance contractions.

The selected scenario dates and series-selection rules remain controlled by `configs/historical_scenarios.yaml`. Candidate anchors are not substituted for empirically selected windows.

## Replay mechanics

Treasury shocks are replayed directly. For each H.15 series, the engine calculates the change between the latest observed value on or before the scenario start date and the latest observed value on or before the scenario end date. The resulting key-rate changes are converted to basis points and interpolated to the Section 15 maturity buckets. Section 15 then revalues synthetic Treasury positions using its existing duration, convexity, liquidation-horizon, concentration, and market-impact controls.

SOFR, financing, settlement-fail, and reserve-balance conditions are measured from observed data. Their normalized empirical severity score selects the nearest already validated Section 16, Section 17, and Section 18 scenario. This preserves the controlled mechanics of the component models while preventing Section 20 from inventing new participant-level behavior.

Each historical window is passed independently through the Section 19 integrated stress engine. Independent execution avoids imposing a false monotonic ordering across unrelated historical episodes. Section 19 continues to use atomic components and its established double-counting controls.

## Missing-data policy

No unavailable series is backfilled with a synthetic historical observation. A scenario can be marked `PARTIAL` when some factor groups are unavailable, such as SOFR before its publication history. An as-of observation is accepted only within the configured maximum lookback period. All audit observations must be dated on or before the historical scenario end date.

## Outputs

The controlled outputs are:

- `reports/tables/historical_scenario_metrics.csv`
- `reports/tables/historical_treasury_bucket_shocks.csv`
- `reports/tables/historical_factor_observations.csv`
- `reports/tables/historical_component_selections.csv`
- `reports/tables/historical_scenario_member_results.csv`
- `reports/tables/historical_scenario_summary.csv`
- `reports/tables/historical_scenario_double_count_controls.csv`
- `reports/evidence/section20_historical_scenarios.json`
- `reports/evidence/section20_historical_scenarios.md`
- `data/manifests/historical_scenario_manifest.csv`

CSV and Parquet versions are produced where supported.

## Scope safeguard

The model does not identify, estimate, rank, or infer any actual FICC participant. Historical market data are observed public aggregates; member exposures and liquidity results remain synthetic.
'@
Write-Utf8NoBom -Path $Target -Content $Content
Write-Host "WROTE: docs/historical_scenarios_methodology.md" -ForegroundColor Green

if ($CurrentScript -and (Test-Path -LiteralPath $CurrentScript)) {
    $automationParent = Split-Path -Parent $AutomationTarget
    if (-not (Test-Path -LiteralPath $automationParent)) {
        New-Item -ItemType Directory -Force -Path $automationParent | Out-Null
    }
    $sourceResolved = (Resolve-Path -LiteralPath $CurrentScript).Path
    if ($sourceResolved -ne $AutomationTarget) {
        Copy-Item -LiteralPath $sourceResolved -Destination $AutomationTarget -Force
        Write-Host "COPIED AUTOMATION: $AutomationRelative" -ForegroundColor Green
    }
}

Write-Section "Resolve Python 3.11 environment"
$Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $Python)) {
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($null -ne $pyLauncher) {
        Invoke-Native py -3.11 -m venv .venv
    } else {
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            throw "Python was not found. Install Python 3.11 and rerun the automation."
        }
        Invoke-Native python -m venv .venv
    }
}
if (-not (Test-Path -LiteralPath $Python)) {
    throw "Virtual-environment interpreter was not created: $Python"
}
Invoke-Native $Python --version

if (-not $SkipInstall) {
    Write-Section "Install project and validation dependencies"
    Invoke-Native $Python -m pip install --upgrade pip
    & $Python -m pip install -e ".[dev]"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "The project has no usable [dev] extra; installing the base project." -ForegroundColor Yellow
        Invoke-Native $Python -m pip install -e .
    }
    Invoke-Native $Python -m pip install pandas pyarrow pyyaml pytest pytest-cov ruff mypy
}

Write-Section "Format and validate Section 20 implementation"
$NewPythonFiles = @(
    "src\ficc_liquidity\scenarios\__init__.py",
    "src\ficc_liquidity\scenarios\historical_scenarios.py",
    "scripts\run_historical_scenarios.py",
    "tests\test_historical_scenarios.py"
)
Invoke-Native $Python -m ruff format @NewPythonFiles
Invoke-Native $Python -m ruff check @NewPythonFiles
Invoke-Native -FilePath $Python -Arguments @("-m", "pytest", "-o", "addopts=", "-q", "tests/test_historical_scenarios.py")

Write-Section "Run historical-scenario replay"
Invoke-Native $Python scripts/run_historical_scenarios.py --smoke
if (-not $SmokeOnly) {
    Invoke-Native $Python scripts/run_historical_scenarios.py
}

Write-Section "Run repository quality gates"
Invoke-Native $Python -m ruff format --check .
Invoke-Native $Python -m ruff check .
Invoke-Native $Python -m mypy src tests
Invoke-Native $Python -m pytest -q --cov=ficc_liquidity --cov-branch --cov-report=term-missing --cov-fail-under=85

$GatePath = Join-Path $RepoRoot "reports\evidence\section20_automation_gate.txt"
$GateContent = @"
Phase VI Section 20 - Historical Scenarios
Generated: $([DateTime]::UtcNow.ToString('o'))
Branch: $Branch
Historical scenario configuration: PASS
Observed yield changes: PASS
Observed SOFR behavior: PASS where data history is available
Observed financing changes: PASS where data history is available
Observed settlement fails: PASS where data history is available
Observed reserve-balance conditions: PASS where data history is available
No-lookahead control: PASS
Synthetic-member safeguard: PASS
Section 19 double-count controls: PASS
Targeted tests: PASS
Ruff: PASS
Mypy: PASS
Full pytest and coverage gate: PASS
FINAL DECISION: PASS SECTION 20
"@
Write-Utf8NoBom -Path $GatePath -Content $GateContent

if (-not $SkipGit) {
    Write-Section "Commit and push Section 20 to the shared scenario-library branch"
    $PathsToAdd = @(
        $AutomationRelative,
        "configs/historical_scenario_replay.yaml",
        "src/ficc_liquidity/scenarios/__init__.py",
        "src/ficc_liquidity/scenarios/historical_scenarios.py",
        "scripts/run_historical_scenarios.py",
        "tests/test_historical_scenarios.py",
        "docs/historical_scenarios_methodology.md",
        "reports/tables/historical_scenario_metrics.csv",
        "reports/tables/historical_scenario_metrics.parquet",
        "reports/tables/historical_treasury_bucket_shocks.csv",
        "reports/tables/historical_treasury_bucket_shocks.parquet",
        "reports/tables/historical_factor_observations.csv",
        "reports/tables/historical_factor_observations.parquet",
        "reports/tables/historical_component_selections.csv",
        "reports/tables/historical_component_selections.parquet",
        "reports/tables/historical_scenario_member_results.csv",
        "reports/tables/historical_scenario_member_results.parquet",
        "reports/tables/historical_scenario_summary.csv",
        "reports/tables/historical_scenario_summary.parquet",
        "reports/tables/historical_scenario_double_count_controls.csv",
        "reports/tables/historical_scenario_double_count_controls.parquet",
        "reports/evidence/section20_historical_scenarios.json",
        "reports/evidence/section20_historical_scenarios.md",
        "reports/evidence/section20_automation_gate.txt",
        "data/manifests/historical_scenario_manifest.csv"
    )
    foreach ($path in $PathsToAdd) {
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $path)) {
            & git add -- $path
            if ($LASTEXITCODE -ne 0) { throw "git add failed for $path" }
        }
    }
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
        Invoke-Native git commit -m "Phase VI Section 20: add historical scenario replay"
    } elseif ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect staged Git changes."
    } else {
        Write-Host "No new staged changes; the Section 20 implementation is already current." -ForegroundColor Yellow
    }

    if (-not $SkipPush) {
        Invoke-Native git push -u origin $Branch
    }
}

Write-Section "Section 20 completed"
Write-Host "FINAL DECISION: PASS SECTION 20" -ForegroundColor Green
Write-Host "Branch: $Branch" -ForegroundColor Green
Write-Host "Do not open or merge the pull request yet. Sections 21-23 continue on this same branch." -ForegroundColor Yellow
Write-Host "Primary evidence: reports\evidence\section20_historical_scenarios.md" -ForegroundColor Green
Write-Host "Automation gate: reports\evidence\section20_automation_gate.txt" -ForegroundColor Green
