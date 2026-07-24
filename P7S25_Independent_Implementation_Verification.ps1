[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$Branch = "feature/20-independent-implementation-verification",
    [switch]$SkipGit,
    [switch]$SkipTests,
    [switch]$Commit,
    [switch]$Push,
    [switch]$OpenPullRequest,
    [switch]$AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Set-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Test-PythonModule {
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string]$ModuleName
    )

    & $PythonExe -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$ModuleName') else 1)" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-PythonExecutable {
    param([Parameter(Mandatory = $true)][string]$Root)

    $candidates = @(
        (Join-Path $Root ".venv\Scripts\python.exe"),
        (Join-Path $Root "venv\Scripts\python.exe"),
        "python",
        "py"
    )

    foreach ($candidate in $candidates) {
        try {
            if ($candidate -eq "py") {
                & $candidate -3.11 --version *> $null
                if ($LASTEXITCODE -eq 0) {
                    return "py|-3.11"
                }
            }
            elseif ((Test-Path $candidate) -or (Get-Command $candidate -ErrorAction SilentlyContinue)) {
                & $candidate --version *> $null
                if ($LASTEXITCODE -eq 0) {
                    return $candidate
                }
            }
        }
        catch {
            continue
        }
    }

    throw "Python was not found. Activate the project's Python 3.11 environment and rerun this automation."
}

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)][string]$PythonCommand,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    if ($PythonCommand -eq "py|-3.11") {
        & py -3.11 @Arguments
    }
    else {
        & $PythonCommand @Arguments
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

function Get-PythonForModuleCheck {
    param([Parameter(Mandatory = $true)][string]$PythonCommand)
    if ($PythonCommand -eq "py|-3.11") {
        return $null
    }
    return $PythonCommand
}

$resolvedRoot = (Resolve-Path $ProjectRoot).Path
Set-Location $resolvedRoot
Write-Step "Preparing Section 25 in $resolvedRoot"

if (-not (Test-Path (Join-Path $resolvedRoot "pyproject.toml"))) {
    throw "pyproject.toml was not found in $resolvedRoot. Open the FICC liquidity project root in VS Code and rerun the script."
}

if (-not $SkipGit) {
    Write-Step "Validating Git state and branch"
    Invoke-Native -FilePath git -Arguments @("rev-parse", "--is-inside-work-tree") | Out-Null

    $dirty = @(git status --porcelain)
    $automationFileName = Split-Path -Leaf $PSCommandPath
    $nonAutomationDirty = @(
        $dirty | Where-Object {
            $statusPath = if ($_.Length -gt 3) { $_.Substring(3).Trim() } else { $_.Trim() }
            $statusPath = $statusPath.Trim('"')
            $statusPath -ne $automationFileName
        }
    )

    if ($nonAutomationDirty.Count -gt 0 -and -not $AllowDirty) {
        Write-Host ($nonAutomationDirty -join [Environment]::NewLine)
        throw "The repository contains unrelated uncommitted changes. Commit or stash them, or rerun with -AllowDirty after reviewing the risk."
    }

    $currentBranch = (git branch --show-current).Trim()
    & git show-ref --verify --quiet "refs/heads/$Branch"
    $localBranchExists = ($LASTEXITCODE -eq 0)

    if ($currentBranch -ne $Branch) {
        if ($localBranchExists) {
            Invoke-Native -FilePath git -Arguments @("checkout", $Branch)
        }
        else {
            Invoke-Native -FilePath git -Arguments @("checkout", "-b", $Branch)
        }
    }

    Write-Pass "Current branch is $Branch"
}

$directories = @(
    "src\ficc_liquidity\validation",
    "scripts",
    "tests",
    "configs",
    "docs",
    "data\validation\fixtures",
    "reports\tables",
    "reports\evidence"
)

foreach ($directory in $directories) {
    New-Item -ItemType Directory -Path (Join-Path $resolvedRoot $directory) -Force | Out-Null
}

Write-Step "Creating the independent implementation module"

$independentModule = @'
"""Independent implementation verification for liquidity stress calculations.

This module is intentionally isolated from all production calculation modules.
It accepts flat-file input contracts and implements formulas directly using
pandas and Python standard-library functionality.
"""

from __future__ import annotations

import argparse
import ast
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, cast

import pandas as pd
import yaml  # type: ignore[import-untyped]


COMPONENT_COLUMNS: tuple[str, ...] = (
    "settlement_liquidity_need",
    "repo_rollover_need",
    "incremental_funding_cost",
    "additional_haircut_requirement",
    "treasury_liquidation_loss",
    "settlement_fail_requirement",
    "concentration_adjustment",
    "operational_liquidity_buffer",
)

MEMBER_INPUT_COLUMNS: tuple[str, ...] = (
    "scenario_id",
    "member_id",
    "treasury_market_value",
    "modified_duration",
    "convexity",
    "yield_shock_bps",
    "settlement_obligation",
    "settlement_inflow",
    "settlement_netting_credit",
    "repo_maturity",
    "repo_rollover_failure_rate",
    "refinanced_repo",
    "sofr_spike_bps",
    "funding_horizon_days",
    "collateral_market_value",
    "haircut_increase_pct",
    "concentration_multiplier",
    "fails_to_receive",
    "delayed_incoming_payments",
    "fails_to_deliver_credit",
    "fail_persistence_days",
    "concentration_base",
    "concentration_addon_pct",
    "operational_base",
    "operational_buffer_pct",
)

RESOURCE_INPUT_COLUMNS: tuple[str, ...] = (
    "scenario_id",
    "resource_id",
    "owner_member_id",
    "resource_type",
    "nominal_amount",
    "eligibility_flag",
    "liquidity_haircut_pct",
    "availability_factor",
)

COVER_RESULT_COLUMNS: tuple[str, ...] = (
    "scenario_id",
    "coverage_basis",
    "default_members",
    "stressed_requirement",
    "available_resources",
    "lcr",
    "liquidity_shortfall",
    "resource_utilization",
    "dominant_stress_component",
)


@dataclass(frozen=True)
class ComparisonTolerance:
    """Absolute and relative comparison tolerances."""

    absolute: float = 1.0e-8
    relative: float = 1.0e-8


def _require_columns(frame: pd.DataFrame, required: Iterable[str], label: str) -> None:
    missing = sorted(set(required) - set(frame.columns))
    if missing:
        raise ValueError(f"{label} is missing required columns: {missing}")


def _numeric(frame: pd.DataFrame, columns: Iterable[str], label: str) -> pd.DataFrame:
    result = frame.copy()
    for column in columns:
        try:
            result[column] = pd.to_numeric(result[column], errors="raise").astype(float)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{label}.{column} must be numeric") from exc
    return result


def _assert_nonnegative(frame: pd.DataFrame, columns: Iterable[str], label: str) -> None:
    for column in columns:
        if (frame[column] < 0.0).any():
            bad_rows = frame.index[frame[column] < 0.0].tolist()
            raise ValueError(f"{label}.{column} contains negative values at rows {bad_rows}")


def _assert_fraction(frame: pd.DataFrame, columns: Iterable[str], label: str) -> None:
    for column in columns:
        invalid = (frame[column] < 0.0) | (frame[column] > 1.0)
        if invalid.any():
            bad_rows = frame.index[invalid].tolist()
            raise ValueError(f"{label}.{column} must be between 0 and 1 at rows {bad_rows}")


def _as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"true", "1", "yes", "y"}:
        return True
    if normalized in {"false", "0", "no", "n", ""}:
        return False
    raise ValueError(f"Cannot interpret eligibility_flag value as Boolean: {value!r}")


def calculate_member_stress(members: pd.DataFrame) -> pd.DataFrame:
    """Calculate each stress component directly from raw member inputs."""

    _require_columns(members, MEMBER_INPUT_COLUMNS, "members")
    frame = cast(
        pd.DataFrame,
        members.loc[:, list(MEMBER_INPUT_COLUMNS)].copy(),
    )
    frame["scenario_id"] = frame["scenario_id"].astype(str)
    frame["member_id"] = frame["member_id"].astype(str)

    numeric_columns = [
        column for column in MEMBER_INPUT_COLUMNS if column not in {"scenario_id", "member_id"}
    ]
    frame = _numeric(frame, numeric_columns, "members")

    nonnegative_columns = [
        "treasury_market_value",
        "modified_duration",
        "convexity",
        "settlement_obligation",
        "settlement_inflow",
        "settlement_netting_credit",
        "repo_maturity",
        "refinanced_repo",
        "funding_horizon_days",
        "collateral_market_value",
        "concentration_multiplier",
        "fails_to_receive",
        "delayed_incoming_payments",
        "fails_to_deliver_credit",
        "fail_persistence_days",
        "concentration_base",
        "operational_base",
    ]
    _assert_nonnegative(frame, nonnegative_columns, "members")
    _assert_fraction(
        frame,
        [
            "repo_rollover_failure_rate",
            "haircut_increase_pct",
            "concentration_addon_pct",
            "operational_buffer_pct",
        ],
        "members",
    )

    yield_change = frame["yield_shock_bps"] / 10_000.0
    duration_convexity_loss_rate = (
        frame["modified_duration"] * yield_change
        - 0.5 * frame["convexity"] * yield_change.pow(2)
    ).clip(lower=0.0)

    frame["settlement_liquidity_need"] = (
        frame["settlement_obligation"]
        - frame["settlement_inflow"]
        - frame["settlement_netting_credit"]
    ).clip(lower=0.0)
    frame["repo_rollover_need"] = (
        frame["repo_maturity"] * frame["repo_rollover_failure_rate"]
    )
    frame["incremental_funding_cost"] = (
        frame["refinanced_repo"]
        * (frame["sofr_spike_bps"] / 10_000.0)
        * (frame["funding_horizon_days"] / 360.0)
    ).clip(lower=0.0)
    frame["additional_haircut_requirement"] = (
        frame["collateral_market_value"]
        * frame["haircut_increase_pct"]
        * frame["concentration_multiplier"]
    )
    frame["treasury_liquidation_loss"] = (
        frame["treasury_market_value"] * duration_convexity_loss_rate
    )
    frame["settlement_fail_requirement"] = (
        (
            frame["fails_to_receive"]
            + frame["delayed_incoming_payments"]
            - frame["fails_to_deliver_credit"]
        ).clip(lower=0.0)
        * frame["fail_persistence_days"].clip(lower=1.0)
    )
    frame["concentration_adjustment"] = (
        frame["concentration_base"] * frame["concentration_addon_pct"]
    )
    frame["operational_liquidity_buffer"] = (
        frame["operational_base"] * frame["operational_buffer_pct"]
    )
    component_frame = cast(
        pd.DataFrame,
        frame.loc[:, list(COMPONENT_COLUMNS)],
    )
    frame["stressed_liquidity_requirement"] = component_frame.sum(
        axis="columns"
    )

    if frame.duplicated(["scenario_id", "member_id"]).any():
        duplicates = frame.loc[
            frame.duplicated(["scenario_id", "member_id"], keep=False),
            ["scenario_id", "member_id"],
        ].to_dict("records")
        raise ValueError(f"Duplicate scenario/member rows are not permitted: {duplicates}")

    return frame


def calculate_qualified_resources(resources: pd.DataFrame) -> pd.DataFrame:
    """Apply independent eligibility, haircut, and availability rules."""

    _require_columns(resources, RESOURCE_INPUT_COLUMNS, "resources")
    frame = cast(
        pd.DataFrame,
        resources.loc[:, list(RESOURCE_INPUT_COLUMNS)].copy(),
    )
    frame["scenario_id"] = frame["scenario_id"].astype(str)
    frame["resource_id"] = frame["resource_id"].astype(str)
    frame["resource_type"] = frame["resource_type"].astype(str)
    frame["owner_member_id"] = frame["owner_member_id"].fillna("").astype(str).str.strip()
    frame["eligibility_flag"] = frame["eligibility_flag"].map(_as_bool)

    frame = _numeric(
        frame,
        ["nominal_amount", "liquidity_haircut_pct", "availability_factor"],
        "resources",
    )
    _assert_nonnegative(frame, ["nominal_amount"], "resources")
    _assert_fraction(frame, ["liquidity_haircut_pct", "availability_factor"], "resources")

    frame["qualified_resource_amount"] = (
        frame["nominal_amount"]
        * (1.0 - frame["liquidity_haircut_pct"])
        * frame["availability_factor"]
        * frame["eligibility_flag"].astype(float)
    )

    if frame.duplicated(["scenario_id", "resource_id"]).any():
        duplicates = frame.loc[
            frame.duplicated(["scenario_id", "resource_id"], keep=False),
            ["scenario_id", "resource_id"],
        ].to_dict("records")
        raise ValueError(f"Duplicate scenario/resource rows are not permitted: {duplicates}")

    return frame


def select_default_sets(member_results: pd.DataFrame) -> pd.DataFrame:
    """Select Cover 1 and Cover 2 from independently calculated requirements."""

    _require_columns(
        member_results,
        ["scenario_id", "member_id", "stressed_liquidity_requirement"],
        "member_results",
    )

    records: list[dict[str, Any]] = []
    for scenario_id, group in member_results.groupby("scenario_id", sort=True):
        ranked = group.sort_values(
            ["stressed_liquidity_requirement", "member_id"],
            ascending=[False, True],
            kind="mergesort",
        ).reset_index(drop=True)

        for coverage_basis, count in (("cover1", 1), ("cover2", 2)):
            selected = ranked.head(count)
            selected_frame = cast(
                pd.DataFrame,
                selected.loc[
                    :, ["member_id", "stressed_liquidity_requirement"]
                ],
            )
            selected_records = cast(
                list[dict[str, Any]],
                selected_frame.to_dict(orient="records"),
            )

            for rank, row in enumerate(selected_records, start=1):
                records.append(
                    {
                        "scenario_id": str(scenario_id),
                        "coverage_basis": coverage_basis,
                        "default_rank": rank,
                        "member_id": str(row["member_id"]),
                        "member_stressed_requirement": float(
                            row["stressed_liquidity_requirement"]
                        ),
                    }
                )

    return pd.DataFrame.from_records(records)


def calculate_cover_results(
    member_results: pd.DataFrame,
    qualified_resources: pd.DataFrame,
    default_sets: pd.DataFrame,
) -> pd.DataFrame:
    """Calculate requirements, resources, LCR, shortfalls, and utilization."""

    _require_columns(default_sets, ["scenario_id", "coverage_basis", "member_id"], "default_sets")
    records: list[dict[str, Any]] = []

    for (scenario_id, coverage_basis), selected in default_sets.groupby(
        ["scenario_id", "coverage_basis"], sort=True
    ):
        default_member_ids = selected.sort_values("default_rank")["member_id"].astype(str).tolist()
        member_mask = (
            member_results["scenario_id"].astype(str).eq(str(scenario_id))
            & member_results["member_id"].astype(str).isin(default_member_ids)
        )
        selected_members = member_results.loc[member_mask]
        if selected_members.empty:
            raise ValueError(
                f"No member calculations found for {scenario_id}/{coverage_basis}"
            )

        stressed_requirement = float(
            selected_members["stressed_liquidity_requirement"].sum()
        )

        scenario_resources = qualified_resources.loc[
            qualified_resources["scenario_id"].astype(str).eq(str(scenario_id))
        ].copy()
        resource_available = (
            scenario_resources["owner_member_id"].eq("")
            | ~scenario_resources["owner_member_id"].isin(default_member_ids)
        )
        available_resources = float(
            scenario_resources.loc[
                resource_available, "qualified_resource_amount"
            ].sum()
        )

        component_totals = selected_members.loc[:, COMPONENT_COLUMNS].sum(axis=0)
        dominant_component = str(component_totals.sort_values(ascending=False).index[0])

        lcr = (
            available_resources / stressed_requirement
            if stressed_requirement > 0.0
            else math.inf
        )
        liquidity_shortfall = max(stressed_requirement - available_resources, 0.0)
        resource_utilization = (
            stressed_requirement / available_resources
            if available_resources > 0.0
            else math.inf
        )

        records.append(
            {
                "scenario_id": str(scenario_id),
                "coverage_basis": str(coverage_basis),
                "default_members": "|".join(default_member_ids),
                "stressed_requirement": stressed_requirement,
                "available_resources": available_resources,
                "lcr": lcr,
                "liquidity_shortfall": liquidity_shortfall,
                "resource_utilization": resource_utilization,
                "dominant_stress_component": dominant_component,
            }
        )

    result = pd.DataFrame.from_records(records)
    ordered_result = cast(
        pd.DataFrame,
        result.loc[:, list(COVER_RESULT_COLUMNS)],
    )
    return ordered_result.sort_values(
        ["scenario_id", "coverage_basis"]
    ).reset_index(drop=True)


def reconcile_aggregates(
    members: pd.DataFrame,
    qualified_resources: pd.DataFrame,
    controls: pd.DataFrame,
) -> pd.DataFrame:
    """Reconcile independent input totals to external aggregate controls."""

    required = (
        "scenario_id",
        "source_table",
        "metric_name",
        "expected_total",
        "absolute_tolerance",
        "relative_tolerance",
    )
    _require_columns(controls, required, "aggregate_controls")
    controls_frame = controls.copy()
    controls_frame["scenario_id"] = controls_frame["scenario_id"].astype(str)
    controls_frame["source_table"] = controls_frame["source_table"].astype(str).str.lower()
    controls_frame["metric_name"] = controls_frame["metric_name"].astype(str)
    controls_frame = _numeric(
        controls_frame,
        ["expected_total", "absolute_tolerance", "relative_tolerance"],
        "aggregate_controls",
    )

    records: list[dict[str, Any]] = []
    control_records = cast(
        list[dict[str, Any]],
        controls_frame.to_dict(orient="records"),
    )

    for control in control_records:
        scenario_id = str(control["scenario_id"])
        source_table = str(control["source_table"])
        metric_name = str(control["metric_name"])
        expected_total = float(control["expected_total"])
        absolute_tolerance = float(control["absolute_tolerance"])
        relative_tolerance = float(control["relative_tolerance"])

        if source_table == "members":
            source = members.loc[
                members["scenario_id"].astype(str).eq(scenario_id)
            ]
        elif source_table == "resources":
            source = qualified_resources.loc[
                qualified_resources["scenario_id"].astype(str).eq(scenario_id)
            ]
        else:
            raise ValueError(
                f"Unsupported source_table: {source_table}"
            )

        if metric_name not in source.columns:
            raise ValueError(
                f"Aggregate control metric {metric_name!r} "
                f"is not present in {source_table}"
            )

        numeric_values = pd.to_numeric(
            source[metric_name],
            errors="raise",
        )

        actual_total = math.fsum(
            float(value)
            for value in numeric_values.tolist()
        )

        absolute_difference = abs(
            actual_total - expected_total
        )

        relative_difference = (
            absolute_difference / abs(expected_total)
            if expected_total != 0.0
            else absolute_difference
        )

        passed = (
            absolute_difference <= absolute_tolerance
            or relative_difference <= relative_tolerance
        )

        records.append(
            {
                "scenario_id": scenario_id,
                "source_table": source_table,
                "metric_name": metric_name,
                "expected_total": expected_total,
                "actual_total": actual_total,
                "absolute_difference": absolute_difference,
                "relative_difference": relative_difference,
                "absolute_tolerance": absolute_tolerance,
                "relative_tolerance": relative_tolerance,
                "status": "PASS" if passed else "FAIL",
            }
        )

    return pd.DataFrame.from_records(records)


def compare_results(
    independent_results: pd.DataFrame,
    reference_results: pd.DataFrame,
    tolerance: ComparisonTolerance,
) -> pd.DataFrame:
    """Compare independent results with exported production or control results."""

    required_reference = [
        "scenario_id",
        "coverage_basis",
        "default_members",
        "stressed_requirement",
        "available_resources",
        "lcr",
        "liquidity_shortfall",
    ]
    _require_columns(reference_results, required_reference, "reference_results")

    independent = independent_results.copy()
    reference = reference_results.loc[:, required_reference].copy()
    independent["scenario_id"] = independent["scenario_id"].astype(str)
    independent["coverage_basis"] = independent["coverage_basis"].astype(str).str.lower()
    reference["scenario_id"] = reference["scenario_id"].astype(str)
    reference["coverage_basis"] = reference["coverage_basis"].astype(str).str.lower()

    numeric_metrics = [
        "stressed_requirement",
        "available_resources",
        "lcr",
        "liquidity_shortfall",
    ]
    reference = _numeric(reference, numeric_metrics, "reference_results")

    merged = independent.merge(
        reference,
        on=["scenario_id", "coverage_basis"],
        how="outer",
        suffixes=("_independent", "_reference"),
        indicator=True,
        validate="one_to_one",
    )

    records: list[dict[str, Any]] = []
    for _, row in merged.iterrows():
        key_status = "PASS" if row["_merge"] == "both" else "FAIL"
        independent_members = str(row.get("default_members_independent", "")).strip()
        reference_members = str(row.get("default_members_reference", "")).strip()
        member_status = (
            "PASS"
            if key_status == "PASS" and independent_members == reference_members
            else "FAIL"
        )
        records.append(
            {
                "scenario_id": str(row["scenario_id"]),
                "coverage_basis": str(row["coverage_basis"]),
                "metric": "default_members",
                "independent_value": independent_members,
                "reference_value": reference_members,
                "absolute_difference": math.nan,
                "relative_difference": math.nan,
                "absolute_tolerance": tolerance.absolute,
                "relative_tolerance": tolerance.relative,
                "status": member_status,
            }
        )

        for metric in numeric_metrics:
            independent_value = row.get(f"{metric}_independent", math.nan)
            reference_value = row.get(f"{metric}_reference", math.nan)
            if key_status == "FAIL" or pd.isna(independent_value) or pd.isna(reference_value):
                absolute_difference = math.inf
                relative_difference = math.inf
                status = "FAIL"
            else:
                absolute_difference = abs(float(independent_value) - float(reference_value))
                relative_difference = (
                    absolute_difference / abs(float(reference_value))
                    if float(reference_value) != 0.0
                    else absolute_difference
                )
                status = (
                    "PASS"
                    if absolute_difference <= tolerance.absolute
                    or relative_difference <= tolerance.relative
                    else "FAIL"
                )

            records.append(
                {
                    "scenario_id": str(row["scenario_id"]),
                    "coverage_basis": str(row["coverage_basis"]),
                    "metric": metric,
                    "independent_value": independent_value,
                    "reference_value": reference_value,
                    "absolute_difference": absolute_difference,
                    "relative_difference": relative_difference,
                    "absolute_tolerance": tolerance.absolute,
                    "relative_tolerance": tolerance.relative,
                    "status": status,
                }
            )

    return pd.DataFrame.from_records(records)


def verify_import_independence(module_path: Path) -> list[str]:
    """Return prohibited internal imports found in the independent module."""

    source = module_path.read_text(encoding="utf-8")
    tree = ast.parse(source)
    violations: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("ficc_liquidity"):
                    violations.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module.startswith("ficc_liquidity"):
                violations.append(module)
    return sorted(set(violations))


def _resolve(project_root: Path, value: str | None) -> Path | None:
    if value is None or str(value).strip() == "":
        return None
    path = Path(value)
    return path if path.is_absolute() else project_root / path


def _required_resolve(project_root: Path, value: str | None, label: str) -> Path:
    path = _resolve(project_root, value)
    if path is None:
        raise ValueError(f"A path is required for {label}")
    return path


def _write_table(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(path, index=False, float_format="%.12f")


def run_verification(
    config_path: Path,
    production_results_override: Path | None = None,
    comparison_label_override: str | None = None,
) -> dict[str, Any]:
    """Execute Section 25 from flat files and write evidence artifacts."""

    config_path = config_path.resolve()
    project_root = config_path.parent.parent
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("The independent verification config must be a mapping")

    inputs = config["inputs"]
    outputs = config["outputs"]
    comparison_config = config.get("comparison", {})

    members_path = _required_resolve(project_root, inputs["members"], "inputs.members")
    resources_path = _required_resolve(project_root, inputs["resources"], "inputs.resources")
    controls_path = _required_resolve(
        project_root, inputs["aggregate_controls"], "inputs.aggregate_controls"
    )

    members = pd.read_csv(members_path)
    resources = pd.read_csv(resources_path, keep_default_na=False)
    controls = pd.read_csv(controls_path)

    member_results = calculate_member_stress(members)
    qualified_resources = calculate_qualified_resources(resources)
    default_sets = select_default_sets(member_results)
    cover_results = calculate_cover_results(
        member_results, qualified_resources, default_sets
    )
    reconciliation = reconcile_aggregates(members, qualified_resources, controls)

    reference_path = production_results_override
    if reference_path is None:
        reference_path = _resolve(project_root, comparison_config.get("results_path"))
    elif not reference_path.is_absolute():
        reference_path = project_root / reference_path

    comparison_label = (
        comparison_label_override
        or comparison_config.get("label")
        or "not_configured"
    )
    tolerance = ComparisonTolerance(
        absolute=float(comparison_config.get("absolute_tolerance", 1.0e-8)),
        relative=float(comparison_config.get("relative_tolerance", 1.0e-8)),
    )

    if reference_path is not None and reference_path.exists():
        reference_results = pd.read_csv(reference_path)
        comparison = compare_results(cover_results, reference_results, tolerance)
        comparison_status = (
            "PASS" if comparison["status"].eq("PASS").all() else "FAIL"
        )
    else:
        comparison = pd.DataFrame(
            columns=[
                "scenario_id",
                "coverage_basis",
                "metric",
                "independent_value",
                "reference_value",
                "absolute_difference",
                "relative_difference",
                "absolute_tolerance",
                "relative_tolerance",
                "status",
            ]
        )
        comparison_status = "NOT_RUN"

    module_path = project_root / "src" / "ficc_liquidity" / "validation" / "independent_implementation.py"
    prohibited_imports = verify_import_independence(module_path)
    independence_status = "PASS" if not prohibited_imports else "FAIL"
    reconciliation_status = (
        "PASS" if reconciliation["status"].eq("PASS").all() else "FAIL"
    )

    output_paths: dict[str, Path] = {
        str(name): _required_resolve(project_root, str(value), f"outputs.{name}")
        for name, value in outputs.items()
    }
    _write_table(member_results, output_paths["member_calculations"])
    _write_table(qualified_resources, output_paths["qualified_resources"])
    _write_table(default_sets, output_paths["default_sets"])
    _write_table(cover_results, output_paths["cover_results"])
    _write_table(reconciliation, output_paths["aggregate_reconciliation"])
    _write_table(comparison, output_paths["calculation_comparison"])

    required_gates = [independence_status, reconciliation_status]
    if bool(comparison_config.get("required", True)):
        required_gates.append(comparison_status)
    overall_status = "PASS" if all(status == "PASS" for status in required_gates) else "FAIL"

    summary: dict[str, Any] = {
        "section": "25",
        "title": "Independent implementation verification",
        "overall_status": overall_status,
        "independence_status": independence_status,
        "prohibited_internal_imports": prohibited_imports,
        "aggregate_reconciliation_status": reconciliation_status,
        "comparison_status": comparison_status,
        "comparison_label": comparison_label,
        "comparison_path": str(reference_path) if reference_path is not None else None,
        "scenario_count": int(member_results["scenario_id"].nunique()),
        "member_scenario_count": int(len(member_results)),
        "cover_result_count": int(len(cover_results)),
        "aggregate_control_count": int(len(reconciliation)),
        "aggregate_control_failures": int(reconciliation["status"].eq("FAIL").sum()),
        "comparison_failures": int(comparison["status"].eq("FAIL").sum()) if not comparison.empty else 0,
        "formula_components": list(COMPONENT_COLUMNS),
        "production_functions_called": False,
    }

    summary_json = output_paths["summary_json"]
    summary_json.parent.mkdir(parents=True, exist_ok=True)
    summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    evidence_lines = [
        "SECTION 25 — INDEPENDENT IMPLEMENTATION VERIFICATION",
        "=" * 57,
        f"Overall status: {overall_status}",
        f"Import independence: {independence_status}",
        f"Aggregate reconciliation: {reconciliation_status}",
        f"Calculation comparison: {comparison_status}",
        f"Comparison label: {comparison_label}",
        f"Scenarios: {summary['scenario_count']}",
        f"Member-scenario calculations: {summary['member_scenario_count']}",
        f"Cover results: {summary['cover_result_count']}",
        f"Aggregate controls: {summary['aggregate_control_count']}",
        f"Aggregate failures: {summary['aggregate_control_failures']}",
        f"Comparison failures: {summary['comparison_failures']}",
        "Production calculation functions called: NO",
        "",
        "Independent components:",
        *[f"- {component}" for component in COMPONENT_COLUMNS],
        "",
        "Files are calculated from CSV input contracts. The independent module does not import",
        "or call any production liquidity, stress, scenario, default-set, or resource functions.",
    ]
    evidence_txt = output_paths["evidence_txt"]
    evidence_txt.parent.mkdir(parents=True, exist_ok=True)
    evidence_txt.write_text("\n".join(evidence_lines) + "\n", encoding="utf-8")

    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/independent_verification.yaml"),
    )
    parser.add_argument(
        "--production-results",
        type=Path,
        default=None,
        help="Optional exported production result CSV. No production functions are imported.",
    )
    parser.add_argument(
        "--comparison-label",
        type=str,
        default=None,
        help="Evidence label for the compared result set.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    summary = run_verification(
        args.config,
        production_results_override=args.production_results,
        comparison_label_override=args.comparison_label,
    )
    print(json.dumps(summary, indent=2))
    return 0 if summary["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "src\ficc_liquidity\validation\independent_implementation.py") -Content $independentModule

$validationInit = @'
"""Independent model-validation utilities."""

from .independent_implementation import (
    COMPONENT_COLUMNS,
    ComparisonTolerance,
    calculate_cover_results,
    calculate_member_stress,
    calculate_qualified_resources,
    compare_results,
    reconcile_aggregates,
    select_default_sets,
)

__all__ = [
    "COMPONENT_COLUMNS",
    "ComparisonTolerance",
    "calculate_cover_results",
    "calculate_member_stress",
    "calculate_qualified_resources",
    "compare_results",
    "reconcile_aggregates",
    "select_default_sets",
]
'@
$validationInitPath = Join-Path $resolvedRoot "src\ficc_liquidity\validation\__init__.py"
if (-not (Test-Path $validationInitPath)) {
    Set-Utf8File -Path $validationInitPath -Content $validationInit
}
else {
    Write-Warn "Existing validation\__init__.py was preserved."
}

$runner = @'
"""Run Section 25 independent implementation verification."""

from ficc_liquidity.validation.independent_implementation import main


if __name__ == "__main__":
    raise SystemExit(main())
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "scripts\run_section25_independent_verification.py") -Content $runner

Write-Step "Creating controlled input and expected-result fixtures"

$membersCsv = @'
scenario_id,member_id,treasury_market_value,modified_duration,convexity,yield_shock_bps,settlement_obligation,settlement_inflow,settlement_netting_credit,repo_maturity,repo_rollover_failure_rate,refinanced_repo,sofr_spike_bps,funding_horizon_days,collateral_market_value,haircut_increase_pct,concentration_multiplier,fails_to_receive,delayed_incoming_payments,fails_to_deliver_credit,fail_persistence_days,concentration_base,concentration_addon_pct,operational_base,operational_buffer_pct
moderate,M001,1000,5,30,100,500,200,50,400,0.25,300,200,5,600,0.02,1.2,50,20,10,2,100,0.10,200,0.05
moderate,M002,800,4,20,100,400,250,25,300,0.20,200,200,5,500,0.015,1.1,30,10,5,2,80,0.05,150,0.05
moderate,M003,600,3,15,100,300,220,20,200,0.10,150,200,5,400,0.01,1.0,20,5,5,1,60,0.05,100,0.05
severe,M001,1000,5,30,250,600,150,30,500,0.60,400,500,10,700,0.05,1.5,100,80,20,3,150,0.20,300,0.10
severe,M002,800,4,20,250,500,180,20,400,0.50,300,500,10,600,0.04,1.3,80,50,10,3,120,0.15,250,0.10
severe,M003,600,3,15,250,350,200,10,300,0.40,250,500,10,500,0.03,1.2,60,30,10,2,90,0.10,180,0.10
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "data\validation\fixtures\section25_members.csv") -Content $membersCsv

$resourcesCsv = @'
scenario_id,resource_id,owner_member_id,resource_type,nominal_amount,eligibility_flag,liquidity_haircut_pct,availability_factor
moderate,R001,,cash,700,true,0.00,1.00
moderate,R002,,committed_facility,300,true,0.10,0.80
moderate,R003,M001,member_contribution,100,true,0.00,1.00
moderate,R004,M002,member_contribution,80,true,0.00,1.00
moderate,R005,M003,member_contribution,60,true,0.00,1.00
severe,R001,,cash,700,true,0.00,0.80
severe,R002,,committed_facility,300,true,0.20,0.50
severe,R003,M001,member_contribution,100,true,0.00,1.00
severe,R004,M002,member_contribution,80,true,0.00,1.00
severe,R005,M003,member_contribution,60,true,0.00,1.00
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "data\validation\fixtures\section25_resources.csv") -Content $resourcesCsv

$aggregateCsv = @'
scenario_id,source_table,metric_name,expected_total,absolute_tolerance,relative_tolerance
moderate,members,treasury_market_value,2400,0.000001,0.000000001
moderate,members,repo_maturity,900,0.000001,0.000000001
moderate,members,settlement_obligation,1200,0.000001,0.000000001
moderate,members,fails_to_receive,100,0.000001,0.000000001
moderate,resources,qualified_resource_amount,1156,0.000001,0.000000001
severe,members,treasury_market_value,2400,0.000001,0.000000001
severe,members,repo_maturity,1200,0.000001,0.000000001
severe,members,settlement_obligation,1450,0.000001,0.000000001
severe,members,fails_to_receive,240,0.000001,0.000000001
severe,resources,qualified_resource_amount,920,0.000001,0.000000001
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "data\validation\fixtures\section25_aggregate_controls.csv") -Content $aggregateCsv

$controlResultsCsv = @'
scenario_id,coverage_basis,default_members,stressed_requirement,available_resources,lcr,liquidity_shortfall
moderate,cover1,M001,552.983333333333,1056,1.909641640797,0
moderate,cover2,M001|M002,858.988888888889,976,1.136219586335,0
severe,cover1,M001,1428.680555555556,820,0.573956156127,608.680555555556
severe,cover2,M001|M002,2438.297222222222,740,0.303490482315,1698.297222222222
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "data\validation\fixtures\section25_control_results.csv") -Content $controlResultsCsv

Write-Step "Creating configuration"

$configYaml = @'
schema_version: "1.0"
section: 25
name: independent_implementation_verification

inputs:
  members: data/validation/fixtures/section25_members.csv
  resources: data/validation/fixtures/section25_resources.csv
  aggregate_controls: data/validation/fixtures/section25_aggregate_controls.csv

comparison:
  label: controlled_hand_calculated_fixture
  results_path: data/validation/fixtures/section25_control_results.csv
  absolute_tolerance: 1.0e-8
  relative_tolerance: 1.0e-8
  required: true

outputs:
  member_calculations: reports/tables/section25_member_calculations.csv
  qualified_resources: reports/tables/section25_qualified_resources.csv
  default_sets: reports/tables/section25_default_sets.csv
  cover_results: reports/tables/section25_cover_results.csv
  aggregate_reconciliation: reports/tables/section25_aggregate_reconciliation.csv
  calculation_comparison: reports/tables/section25_calculation_comparison.csv
  summary_json: reports/evidence/section25_independent_verification_summary.json
  evidence_txt: reports/evidence/section25_independent_verification.txt
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "configs\independent_verification.yaml") -Content $configYaml

$mypyConfig = @'
[mypy]
python_version = 3.11
ignore_missing_imports = True
check_untyped_defs = True
disallow_untyped_defs = True
warn_unused_ignores = False
warn_return_any = False
no_implicit_optional = True
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "configs\mypy_section25.ini") -Content $mypyConfig

Write-Step "Creating Section 25 tests"

$tests = @'
"""Tests for Section 25 independent implementation verification."""

from __future__ import annotations

import ast
from pathlib import Path

import pandas as pd
import pytest

from ficc_liquidity.validation.independent_implementation import (
    ComparisonTolerance,
    calculate_cover_results,
    calculate_member_stress,
    calculate_qualified_resources,
    compare_results,
    reconcile_aggregates,
    select_default_sets,
)


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = PROJECT_ROOT / "data" / "validation" / "fixtures"
MODULE_PATH = (
    PROJECT_ROOT
    / "src"
    / "ficc_liquidity"
    / "validation"
    / "independent_implementation.py"
)


def _load_inputs() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    members = pd.read_csv(FIXTURE_DIR / "section25_members.csv")
    resources = pd.read_csv(
        FIXTURE_DIR / "section25_resources.csv", keep_default_na=False
    )
    controls = pd.read_csv(FIXTURE_DIR / "section25_aggregate_controls.csv")
    return members, resources, controls


def _calculate() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    members, resources, _ = _load_inputs()
    member_results = calculate_member_stress(members)
    qualified_resources = calculate_qualified_resources(resources)
    default_sets = select_default_sets(member_results)
    cover_results = calculate_cover_results(
        member_results, qualified_resources, default_sets
    )
    return member_results, qualified_resources, default_sets, cover_results


def test_independent_module_imports_no_production_package_code() -> None:
    tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
    prohibited: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            prohibited.extend(
                alias.name for alias in node.names if alias.name.startswith("ficc_liquidity")
            )
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module.startswith("ficc_liquidity"):
                prohibited.append(module)
    assert prohibited == []


def test_hand_calculated_stress_components() -> None:
    member_results, _, _, _ = _calculate()
    moderate_m001 = member_results.loc[
        member_results["scenario_id"].eq("moderate")
        & member_results["member_id"].eq("M001")
    ].iloc[0]

    assert moderate_m001["settlement_liquidity_need"] == pytest.approx(250.0)
    assert moderate_m001["repo_rollover_need"] == pytest.approx(100.0)
    assert moderate_m001["incremental_funding_cost"] == pytest.approx(1.0 / 12.0)
    assert moderate_m001["additional_haircut_requirement"] == pytest.approx(14.4)
    assert moderate_m001["treasury_liquidation_loss"] == pytest.approx(48.5)
    assert moderate_m001["settlement_fail_requirement"] == pytest.approx(120.0)
    assert moderate_m001["concentration_adjustment"] == pytest.approx(10.0)
    assert moderate_m001["operational_liquidity_buffer"] == pytest.approx(10.0)
    assert moderate_m001["stressed_liquidity_requirement"] == pytest.approx(
        552.983333333333
    )


def test_default_set_selection_uses_independent_member_requirements() -> None:
    _, _, default_sets, _ = _calculate()
    moderate_cover1 = default_sets.loc[
        default_sets["scenario_id"].eq("moderate")
        & default_sets["coverage_basis"].eq("cover1")
    ]
    moderate_cover2 = default_sets.loc[
        default_sets["scenario_id"].eq("moderate")
        & default_sets["coverage_basis"].eq("cover2")
    ].sort_values("default_rank")

    assert moderate_cover1["member_id"].tolist() == ["M001"]
    assert moderate_cover2["member_id"].tolist() == ["M001", "M002"]


def test_cover_results_exclude_defaulting_member_resources() -> None:
    _, _, _, cover_results = _calculate()
    moderate_cover1 = cover_results.loc[
        cover_results["scenario_id"].eq("moderate")
        & cover_results["coverage_basis"].eq("cover1")
    ].iloc[0]
    severe_cover2 = cover_results.loc[
        cover_results["scenario_id"].eq("severe")
        & cover_results["coverage_basis"].eq("cover2")
    ].iloc[0]

    assert moderate_cover1["available_resources"] == pytest.approx(1056.0)
    assert moderate_cover1["lcr"] == pytest.approx(1.909641640797)
    assert moderate_cover1["liquidity_shortfall"] == pytest.approx(0.0)
    assert severe_cover2["available_resources"] == pytest.approx(740.0)
    assert severe_cover2["liquidity_shortfall"] == pytest.approx(
        1698.297222222222
    )


def test_aggregate_reconciliation_passes() -> None:
    members, resources, controls = _load_inputs()
    qualified_resources = calculate_qualified_resources(resources)
    reconciliation = reconcile_aggregates(members, qualified_resources, controls)

    assert not reconciliation.empty
    assert reconciliation["status"].eq("PASS").all()


def test_control_result_comparison_passes() -> None:
    _, _, _, cover_results = _calculate()
    control_results = pd.read_csv(FIXTURE_DIR / "section25_control_results.csv")
    comparison = compare_results(
        cover_results,
        control_results,
        ComparisonTolerance(absolute=1.0e-8, relative=1.0e-8),
    )

    assert len(comparison) == 20
    assert comparison["status"].eq("PASS").all()


def test_invalid_fraction_is_rejected() -> None:
    members, _, _ = _load_inputs()
    members.loc[0, "repo_rollover_failure_rate"] = 1.2
    with pytest.raises(ValueError, match="between 0 and 1"):
        calculate_member_stress(members)
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "tests\test_section25_independent_implementation.py") -Content $tests

Write-Step "Creating validation documentation"

$documentation = @'
# Section 25 — Independent Implementation Verification

## Objective

Section 25 provides a second calculation path for liquidity stress results. The independent path recalculates stress components, default sets, aggregate reconciliations, stressed liquidity requirements, qualified resources, liquidity coverage ratios, and shortfalls.

The independent module does not import or call production calculation functions. It consumes only flat CSV contracts and implements the formulas directly.

## Independence boundary

The independent implementation is located at:

`src/ficc_liquidity/validation/independent_implementation.py`

The module imports Python standard-library modules, pandas, and PyYAML. It does not import any module under `ficc_liquidity`. The test `test_independent_module_imports_no_production_package_code` parses the module with Python's AST and fails if an internal package import is added.

The runner may import the independent module. The independent module itself may not import production code.

## Independent formulas

For each member and scenario:

1. Settlement liquidity need equals positive settlement obligations net of incoming settlement cash and approved netting credit.
2. Repo rollover need equals repo maturity multiplied by the rollover-failure rate.
3. Incremental funding cost equals refinanced repo multiplied by the SOFR shock and the funding-horizon day count divided by 360.
4. Additional haircut requirement equals collateral market value multiplied by the haircut increase and concentration multiplier.
5. Treasury liquidation loss uses a direct modified-duration and convexity approximation.
6. Settlement-fail requirement equals positive fails-to-receive plus delayed incoming payments less fails-to-deliver credit, multiplied by persistence days.
7. Concentration adjustment equals the concentration base multiplied by the independent add-on percentage.
8. Operational liquidity buffer equals the operational base multiplied by its buffer percentage.
9. Stressed liquidity requirement equals the sum of the eight independently calculated components.

## Cover 1 and Cover 2

Members are ranked by independently calculated stressed liquidity requirement. Cover 1 selects the largest member. Cover 2 selects the two largest members. Ties are resolved deterministically by member identifier.

Qualified resources are recalculated from nominal amount, eligibility, liquidity haircut, and availability factor. Resources owned by a defaulting member are excluded from the corresponding default set.

`LCR = available qualified resources / stressed liquidity requirement`

`Liquidity shortfall = max(stressed liquidity requirement - available qualified resources, 0)`

`Resource utilization = stressed liquidity requirement / available qualified resources`

## Aggregate reconciliation

`configs/independent_verification.yaml` identifies aggregate-control inputs. Every control specifies its source table, metric, expected total, absolute tolerance, and relative tolerance. The verification fails when neither tolerance is met.

## Controlled fixture and production comparison

The automation creates a small hand-calculated fixture. This proves formula correctness, deterministic default-set selection, resource exclusion, reconciliation, and comparison logic.

To compare against actual production outputs, export the Section 22 results to a CSV with these columns:

- `scenario_id`
- `coverage_basis`
- `default_members`
- `stressed_requirement`
- `available_resources`
- `lcr`
- `liquidity_shortfall`

Then run:

```powershell
.\.venv\Scripts\python.exe scripts\run_section25_independent_verification.py `
  --config configs\independent_verification.yaml `
  --production-results reports\tables\section22_cover_results.csv `
  --comparison-label production_section22
```

The production CSV is treated as read-only output. No production function is imported or invoked.

## Evidence outputs

- `reports/tables/section25_member_calculations.csv`
- `reports/tables/section25_qualified_resources.csv`
- `reports/tables/section25_default_sets.csv`
- `reports/tables/section25_cover_results.csv`
- `reports/tables/section25_aggregate_reconciliation.csv`
- `reports/tables/section25_calculation_comparison.csv`
- `reports/evidence/section25_independent_verification_summary.json`
- `reports/evidence/section25_independent_verification.txt`

## Acceptance criteria

- Independent module contains no internal production imports: PASS.
- Controlled component calculations match hand calculations: PASS.
- Cover 1 and Cover 2 selection is deterministic: PASS.
- Defaulting-member resources are excluded: PASS.
- Aggregate controls reconcile within tolerance: PASS.
- Controlled result comparison passes: PASS.
- Actual production comparison is performed using exported results before final model-validation sign-off.
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "docs\section25_independent_implementation_verification.md") -Content $documentation

$pythonCommand = Resolve-PythonExecutable -Root $resolvedRoot
Write-Pass "Python command resolved: $pythonCommand"

Write-Step "Installing the local package in editable mode"
Invoke-Python -PythonCommand $pythonCommand -Arguments @("-m", "pip", "install", "-e", ".", "--no-deps")

if (-not $SkipTests) {
    Write-Step "Running Section 25 unit tests"
    Invoke-Python -PythonCommand $pythonCommand -Arguments @("-m", "pytest", "tests\test_section25_independent_implementation.py", "-q", "-o", "addopts=")
    Write-Pass "Section 25 unit tests"

    $moduleCheckPython = Get-PythonForModuleCheck -PythonCommand $pythonCommand
    $ruffAvailable = $false
    $mypyAvailable = $false
    if ($null -ne $moduleCheckPython) {
        $ruffAvailable = Test-PythonModule -PythonExe $moduleCheckPython -ModuleName "ruff"
        $mypyAvailable = Test-PythonModule -PythonExe $moduleCheckPython -ModuleName "mypy"
    }
    else {
        & py -3.11 -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('ruff') else 1)" 2>$null
        $ruffAvailable = ($LASTEXITCODE -eq 0)
        & py -3.11 -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('mypy') else 1)" 2>$null
        $mypyAvailable = ($LASTEXITCODE -eq 0)
    }

    if ($ruffAvailable) {
        Write-Step "Running Ruff on Section 25 files"
        Invoke-Python -PythonCommand $pythonCommand -Arguments @(
            "-m",
            "ruff",
            "check",
            "--isolated",
            "src\ficc_liquidity\validation\independent_implementation.py",
            "src\ficc_liquidity\validation\__init__.py",
            "scripts\run_section25_independent_verification.py",
            "tests\test_section25_independent_implementation.py"
        )
        Write-Pass "Ruff validation"
    }
    else {
        Write-Warn "Ruff is not installed; the Ruff check was skipped."
    }

    if ($mypyAvailable) {
        Write-Step "Running mypy on the independent module"
        Invoke-Python -PythonCommand $pythonCommand -Arguments @(
            "-m",
            "mypy",
            "--config-file",
            "configs\mypy_section25.ini",
            "src\ficc_liquidity\validation\independent_implementation.py"
        )
        Write-Pass "Mypy validation"
    }
    else {
        Write-Warn "mypy is not installed; the mypy check was skipped."
    }
}

Write-Step "Executing the Section 25 controlled verification"
Invoke-Python -PythonCommand $pythonCommand -Arguments @(
    "scripts\run_section25_independent_verification.py",
    "--config",
    "configs\independent_verification.yaml"
)

$summaryPath = Join-Path $resolvedRoot "reports\evidence\section25_independent_verification_summary.json"
if (-not (Test-Path $summaryPath)) {
    throw "Section 25 summary was not created: $summaryPath"
}

$summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
if ($summary.overall_status -ne "PASS") {
    throw "Section 25 controlled verification did not pass. Review $summaryPath."
}
Write-Pass "Controlled independent implementation verification"

if (-not $SkipGit) {
    Write-Step "Reviewing generated Git changes"
    git status --short

    if ($Commit) {
        $standardPaths = @(
            "configs\independent_verification.yaml",
            "configs\mypy_section25.ini",
            "data\validation\fixtures\section25_members.csv",
            "data\validation\fixtures\section25_resources.csv",
            "data\validation\fixtures\section25_aggregate_controls.csv",
            "data\validation\fixtures\section25_control_results.csv",
            "docs\section25_independent_implementation_verification.md",
            "scripts\run_section25_independent_verification.py",
            "src\ficc_liquidity\validation\__init__.py",
            "src\ficc_liquidity\validation\independent_implementation.py",
            "tests\test_section25_independent_implementation.py",
            $automationFileName
        )

        $ignoredReportPaths = @(
            "reports\tables\section25_member_calculations.csv",
            "reports\tables\section25_qualified_resources.csv",
            "reports\tables\section25_default_sets.csv",
            "reports\tables\section25_cover_results.csv",
            "reports\tables\section25_aggregate_reconciliation.csv",
            "reports\tables\section25_calculation_comparison.csv",
            "reports\evidence\section25_independent_verification_summary.json",
            "reports\evidence\section25_independent_verification.txt"
        )

        Invoke-Native `
            -FilePath git `
            -Arguments (@("add", "--") + $standardPaths)

        Invoke-Native `
            -FilePath git `
            -Arguments (@("add", "-f", "--") + $ignoredReportPaths)

        $staged = @(git diff --cached --name-only)
        if ($staged.Count -eq 0) {
            Write-Warn "No changes were staged; no commit was created."
        }
        else {
            Invoke-Native -FilePath git -Arguments @("commit", "-m", "Phase VII Section 25: independent implementation verification")
            Write-Pass "Git commit created"
        }
    }

    if ($Push) {
        Invoke-Native -FilePath git -Arguments @("push", "-u", "origin", $Branch)
        Write-Pass "Branch pushed to origin"
    }

    if ($OpenPullRequest) {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw "GitHub CLI was not found. Install or authenticate gh before using -OpenPullRequest."
        }

        & gh pr view $Branch *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Warn "A pull request already exists for $Branch."
        }
        else {
            Invoke-Native -FilePath gh -Arguments @(
                "pr",
                "create",
                "--base",
                "main",
                "--head",
                $Branch,
                "--title",
                "Phase VII Section 25: Independent implementation verification",
                "--body",
                "Implements a fully independent CSV-based calculation path for stress components, Cover 1 and Cover 2 default-set selection, aggregate reconciliation, stressed liquidity requirements, qualified resources, LCR, and shortfalls. The independent module imports no production calculation modules. Includes hand-calculated controls, unit tests, comparison evidence, and documented production-output integration."
            )
            Write-Pass "Pull request created"
        }
    }
}

Write-Host ""
Write-Host "SECTION 25 COMPLETE" -ForegroundColor Green
Write-Host "Branch: $Branch"
Write-Host "Summary: reports\evidence\section25_independent_verification_summary.json"
Write-Host "Evidence: reports\evidence\section25_independent_verification.txt"
Write-Host ""
Write-Host "To compare actual Section 22 production outputs without calling production functions:" -ForegroundColor Cyan
Write-Host ".\.venv\Scripts\python.exe scripts\run_section25_independent_verification.py --config configs\independent_verification.yaml --production-results reports\tables\section22_cover_results.csv --comparison-label production_section22"
