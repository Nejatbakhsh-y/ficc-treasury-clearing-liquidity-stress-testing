[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$Branch = "feature/21-sensitivity-analysis",
    [switch]$SkipGit,
    [switch]$SkipTests,
    [switch]$SkipFullSuite,
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
        [Parameter(Mandatory = $true)][string]$PythonCommand,
        [Parameter(Mandatory = $true)][string]$ModuleName
    )

    if ($PythonCommand -eq "py|-3.11") {
        & py -3.11 -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$ModuleName') else 1)" 2>$null
    }
    else {
        & $PythonCommand -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$ModuleName') else 1)" 2>$null
    }
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

$resolvedRoot = (Resolve-Path $ProjectRoot).Path
Set-Location $resolvedRoot
Write-Step "Preparing Phase VII Section 26 in $resolvedRoot"

if (-not (Test-Path (Join-Path $resolvedRoot "pyproject.toml"))) {
    throw "pyproject.toml was not found. Open the FICC liquidity project root in VS Code and rerun the script."
}

$requiredSection25Files = @(
    "src\ficc_liquidity\validation\independent_implementation.py",
    "data\validation\fixtures\section25_members.csv",
    "data\validation\fixtures\section25_resources.csv"
)
foreach ($requiredFile in $requiredSection25Files) {
    if (-not (Test-Path (Join-Path $resolvedRoot $requiredFile))) {
        throw "Required Section 25 dependency is missing: $requiredFile. Update main after PR #26 before running Section 26."
    }
}

$automationFileName = Split-Path -Leaf $PSCommandPath

if (-not $SkipGit) {
    Write-Step "Validating Git state and preparing $Branch"
    Invoke-Native -FilePath git -Arguments @("rev-parse", "--is-inside-work-tree") | Out-Null

    $dirty = @(git status --porcelain)
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

    Invoke-Native -FilePath git -Arguments @("fetch", "origin")
    & git show-ref --verify --quiet "refs/heads/$Branch"
    $localBranchExists = ($LASTEXITCODE -eq 0)
    & git show-ref --verify --quiet "refs/remotes/origin/$Branch"
    $remoteBranchExists = ($LASTEXITCODE -eq 0)

    if ($localBranchExists) {
        Invoke-Native -FilePath git -Arguments @("checkout", $Branch)
    }
    elseif ($remoteBranchExists) {
        Invoke-Native -FilePath git -Arguments @("checkout", "-b", $Branch, "--track", "origin/$Branch")
    }
    else {
        Invoke-Native -FilePath git -Arguments @("checkout", "main")
        Invoke-Native -FilePath git -Arguments @("pull", "--ff-only", "origin", "main")
        Invoke-Native -FilePath git -Arguments @("checkout", "-b", $Branch)
    }
    Write-Pass "Current branch is $Branch"
}

$directories = @(
    "src\ficc_liquidity\validation",
    "scripts",
    "tests",
    "configs",
    "docs",
    "reports\tables",
    "reports\evidence"
)
foreach ($directory in $directories) {
    New-Item -ItemType Directory -Path (Join-Path $resolvedRoot $directory) -Force | Out-Null
}

Write-Step "Creating the Section 26 sensitivity-analysis implementation"
$sensitivityModule = @'
"""Independent sensitivity analysis for FICC liquidity stress validation.

The analysis uses the Section 25 independent calculation path and flat-file
contracts. It does not call production stress-calculation functions.
"""

from __future__ import annotations

import argparse
import json
import math
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml

from ficc_liquidity.validation.independent_implementation import (
    COMPONENT_COLUMNS,
    calculate_member_stress,
    calculate_qualified_resources,
)

REQUIRED_SENSITIVITIES: tuple[str, ...] = (
    "yield_shocks",
    "duration_assumptions",
    "sofr_spikes",
    "rollover_failure_percentages",
    "haircut_increases",
    "settlement_fail_percentages",
    "member_concentration",
    "liquidation_horizon",
    "default_set_size",
    "available_resource_assumptions",
)

VALID_DIRECTIONS: frozenset[str] = frozenset(
    {"nondecreasing", "nonincreasing", "flat", "unconstrained"}
)


@dataclass(frozen=True)
class SensitivitySpec:
    """Controlled sensitivity specification."""

    name: str
    values: tuple[float, ...]
    baseline: float
    requirement_direction: str
    resource_direction: str
    lcr_direction: str
    description: str


def _require_columns(frame: pd.DataFrame, required: Iterable[str], label: str) -> None:
    missing = sorted(set(required) - set(frame.columns))
    if missing:
        raise ValueError(f"{label} is missing required columns: {missing}")


def _as_float_tuple(values: Any, name: str) -> tuple[float, ...]:
    if not isinstance(values, list) or not values:
        raise ValueError(f"Sensitivity {name!r} must define a nonempty values list")
    converted = tuple(float(value) for value in values)
    if any(not math.isfinite(value) for value in converted):
        raise ValueError(f"Sensitivity {name!r} contains a non-finite value")
    if tuple(sorted(set(converted))) != converted:
        raise ValueError(f"Sensitivity {name!r} values must be unique and increasing")
    return converted


def load_sensitivity_specs(config: Mapping[str, Any]) -> tuple[SensitivitySpec, ...]:
    """Validate and load all ten required sensitivity definitions."""

    analysis = config.get("analysis")
    if not isinstance(analysis, Mapping):
        raise ValueError("The Section 26 config must contain an analysis mapping")
    dimensions = analysis.get("dimensions")
    if not isinstance(dimensions, Mapping):
        raise ValueError("analysis.dimensions must be a mapping")

    missing = sorted(set(REQUIRED_SENSITIVITIES) - set(dimensions))
    extra = sorted(set(dimensions) - set(REQUIRED_SENSITIVITIES))
    if missing or extra:
        raise ValueError(f"Sensitivity dimension mismatch. Missing={missing}; extra={extra}")

    specs: list[SensitivitySpec] = []
    for name in REQUIRED_SENSITIVITIES:
        raw = dimensions[name]
        if not isinstance(raw, Mapping):
            raise ValueError(f"Sensitivity {name!r} must be a mapping")
        values = _as_float_tuple(raw.get("values"), name)
        baseline_raw = raw.get("baseline")
        if baseline_raw is None:
            raise ValueError(f"Sensitivity {name!r} baseline is required")
        baseline = float(cast(float | int | str, baseline_raw))
        if baseline not in values:
            raise ValueError(f"Sensitivity {name!r} baseline must be included in values")
        directions = {
            "requirement_direction": str(raw.get("requirement_direction", "unconstrained")),
            "resource_direction": str(raw.get("resource_direction", "unconstrained")),
            "lcr_direction": str(raw.get("lcr_direction", "unconstrained")),
        }
        invalid = sorted(set(directions.values()) - VALID_DIRECTIONS)
        if invalid:
            raise ValueError(f"Sensitivity {name!r} has invalid directions: {invalid}")
        specs.append(
            SensitivitySpec(
                name=name,
                values=values,
                baseline=baseline,
                requirement_direction=directions["requirement_direction"],
                resource_direction=directions["resource_direction"],
                lcr_direction=directions["lcr_direction"],
                description=str(raw.get("description", "")).strip(),
            )
        )
    return tuple(specs)


def apply_sensitivity(
    members: pd.DataFrame,
    resources: pd.DataFrame,
    spec: SensitivitySpec,
    value: float,
) -> tuple[pd.DataFrame, pd.DataFrame, int | None]:
    """Return shocked copies of member and resource inputs plus optional default-set size."""

    member_shock = members.copy(deep=True)
    resource_shock = resources.copy(deep=True)
    default_set_size: int | None = None

    multiplier_columns: dict[str, tuple[str, ...]] = {
        "yield_shocks": ("yield_shock_bps",),
        "duration_assumptions": ("modified_duration",),
        "sofr_spikes": ("sofr_spike_bps",),
        "rollover_failure_percentages": ("repo_rollover_failure_rate",),
        "haircut_increases": ("haircut_increase_pct",),
        "settlement_fail_percentages": ("fails_to_receive", "delayed_incoming_payments"),
    }

    if spec.name in multiplier_columns:
        for column in multiplier_columns[spec.name]:
            member_shock[column] = pd.to_numeric(member_shock[column], errors="raise") * value
        if spec.name == "rollover_failure_percentages":
            member_shock["repo_rollover_failure_rate"] = member_shock[
                "repo_rollover_failure_rate"
            ].clip(lower=0.0, upper=1.0)
        elif spec.name == "haircut_increases":
            member_shock["haircut_increase_pct"] = member_shock["haircut_increase_pct"].clip(
                lower=0.0, upper=1.0
            )
    elif spec.name == "member_concentration":
        member_shock["concentration_multiplier"] = (
            pd.to_numeric(member_shock["concentration_multiplier"], errors="raise") * value
        ).clip(lower=0.0)
        member_shock["concentration_addon_pct"] = (
            pd.to_numeric(member_shock["concentration_addon_pct"], errors="raise") * value
        ).clip(lower=0.0, upper=1.0)
    elif spec.name == "liquidation_horizon":
        horizon_factor = math.sqrt(value / spec.baseline)
        member_shock["yield_shock_bps"] = (
            pd.to_numeric(member_shock["yield_shock_bps"], errors="raise") * horizon_factor
        )
    elif spec.name == "default_set_size":
        default_set_size = int(value)
        if float(default_set_size) != value or default_set_size < 1:
            raise ValueError("default_set_size values must be positive integers")
    elif spec.name == "available_resource_assumptions":
        resource_shock["availability_factor"] = (
            pd.to_numeric(resource_shock["availability_factor"], errors="raise") * value
        ).clip(lower=0.0, upper=1.0)
    else:
        raise ValueError(f"Unsupported sensitivity: {spec.name}")

    return member_shock, resource_shock, default_set_size


def calculate_default_set_result(
    member_results: pd.DataFrame,
    qualified_resources: pd.DataFrame,
    scenario_id: str,
    default_set_size: int,
) -> dict[str, Any]:
    """Calculate a generalized Cover N result from independent member calculations."""

    _require_columns(
        member_results,
        ["scenario_id", "member_id", "stressed_liquidity_requirement", *COMPONENT_COLUMNS],
        "member_results",
    )
    scenario_members = member_results.loc[
        member_results["scenario_id"].astype(str).eq(str(scenario_id))
    ].copy()
    if scenario_members.empty:
        raise ValueError(f"No member results were found for scenario {scenario_id!r}")
    if default_set_size > len(scenario_members):
        raise ValueError(
            f"Default-set size {default_set_size} exceeds member count {len(scenario_members)} "
            f"for scenario {scenario_id!r}"
        )

    ranked = scenario_members.sort_values(
        ["stressed_liquidity_requirement", "member_id"],
        ascending=[False, True],
        kind="mergesort",
    )
    selected = ranked.head(default_set_size)
    default_members = selected["member_id"].astype(str).tolist()
    stressed_requirement = float(selected["stressed_liquidity_requirement"].sum())

    scenario_resources = qualified_resources.loc[
        qualified_resources["scenario_id"].astype(str).eq(str(scenario_id))
    ].copy()
    resource_available = scenario_resources["owner_member_id"].eq("") | ~scenario_resources[
        "owner_member_id"
    ].astype(str).isin(default_members)
    available_resources = float(
        scenario_resources.loc[resource_available, "qualified_resource_amount"].sum()
    )
    component_totals = selected.loc[:, list(COMPONENT_COLUMNS)].sum(axis=0)
    dominant_component = str(component_totals.sort_values(ascending=False).index[0])
    lcr = available_resources / stressed_requirement if stressed_requirement > 0.0 else math.inf
    shortfall = max(stressed_requirement - available_resources, 0.0)
    utilization = (
        stressed_requirement / available_resources
        if available_resources > 0.0
        else math.inf
    )

    return {
        "scenario_id": str(scenario_id),
        "default_set_size": default_set_size,
        "default_members": "|".join(default_members),
        "stressed_requirement": stressed_requirement,
        "available_resources": available_resources,
        "lcr": lcr,
        "liquidity_shortfall": shortfall,
        "resource_utilization": utilization,
        "dominant_stress_component": dominant_component,
    }


def _percent_change(value: float, baseline: float) -> float:
    if math.isinf(value) and math.isinf(baseline):
        return 0.0
    if baseline == 0.0:
        return 0.0 if value == 0.0 else math.nan
    return (value - baseline) / abs(baseline)


def _elasticity(output_change: float, input_value: float, input_baseline: float) -> float:
    input_change = _percent_change(input_value, input_baseline)
    if input_change == 0.0 or math.isnan(input_change) or math.isnan(output_change):
        return math.nan
    return output_change / input_change


def run_sensitivity_grid(
    members: pd.DataFrame,
    resources: pd.DataFrame,
    specs: tuple[SensitivitySpec, ...],
) -> pd.DataFrame:
    """Run all sensitivity points for Cover 1, Cover 2, and variable default-set size."""

    member_scenarios = sorted(members["scenario_id"].astype(str).unique().tolist())
    resource_scenarios = sorted(resources["scenario_id"].astype(str).unique().tolist())
    if member_scenarios != resource_scenarios:
        raise ValueError(
            f"Member/resource scenario mismatch: members={member_scenarios}, "
            f"resources={resource_scenarios}"
        )

    records: list[dict[str, Any]] = []
    for spec in specs:
        for value in spec.values:
            shocked_members, shocked_resources, variable_size = apply_sensitivity(
                members, resources, spec, value
            )
            member_results = calculate_member_stress(shocked_members)
            qualified_resources = calculate_qualified_resources(shocked_resources)
            for scenario_id in member_scenarios:
                sizes_and_basis = (
                    ((1, "cover1"), (2, "cover2"))
                    if variable_size is None
                    else ((variable_size, "variable_default_set"),)
                )
                for default_size, coverage_basis in sizes_and_basis:
                    result = calculate_default_set_result(
                        member_results,
                        qualified_resources,
                        scenario_id,
                        default_size,
                    )
                    records.append(
                        {
                            "sensitivity_name": spec.name,
                            "sensitivity_value": value,
                            "baseline_value": spec.baseline,
                            "coverage_basis": coverage_basis,
                            **result,
                        }
                    )

    detailed = pd.DataFrame.from_records(records)
    baseline_columns = [
        "sensitivity_name",
        "scenario_id",
        "coverage_basis",
        "stressed_requirement",
        "available_resources",
        "lcr",
        "liquidity_shortfall",
        "default_members",
        "dominant_stress_component",
    ]
    baseline_mask = detailed["sensitivity_value"].eq(detailed["baseline_value"])
    baselines = detailed.loc[baseline_mask, baseline_columns].copy()
    baselines = baselines.rename(
        columns={
            "stressed_requirement": "baseline_stressed_requirement",
            "available_resources": "baseline_available_resources",
            "lcr": "baseline_lcr",
            "liquidity_shortfall": "baseline_liquidity_shortfall",
            "default_members": "baseline_default_members",
            "dominant_stress_component": "baseline_dominant_stress_component",
        }
    )
    if baselines.duplicated(["sensitivity_name", "scenario_id", "coverage_basis"]).any():
        raise ValueError("Each sensitivity group must have exactly one baseline result")

    detailed = detailed.merge(
        baselines,
        on=["sensitivity_name", "scenario_id", "coverage_basis"],
        how="left",
        validate="many_to_one",
    )
    detailed["requirement_change_pct"] = detailed.apply(
        lambda row: _percent_change(
            float(row["stressed_requirement"]), float(row["baseline_stressed_requirement"])
        ),
        axis=1,
    )
    detailed["resource_change_pct"] = detailed.apply(
        lambda row: _percent_change(
            float(row["available_resources"]), float(row["baseline_available_resources"])
        ),
        axis=1,
    )
    detailed["lcr_change_pct"] = detailed.apply(
        lambda row: _percent_change(float(row["lcr"]), float(row["baseline_lcr"])),
        axis=1,
    )
    detailed["requirement_elasticity"] = detailed.apply(
        lambda row: _elasticity(
            float(row["requirement_change_pct"]),
            float(row["sensitivity_value"]),
            float(row["baseline_value"]),
        ),
        axis=1,
    )
    detailed["lcr_elasticity"] = detailed.apply(
        lambda row: _elasticity(
            float(row["lcr_change_pct"]),
            float(row["sensitivity_value"]),
            float(row["baseline_value"]),
        ),
        axis=1,
    )
    detailed["default_set_changed"] = detailed["default_members"].ne(
        detailed["baseline_default_members"]
    )
    detailed["dominant_component_changed"] = detailed["dominant_stress_component"].ne(
        detailed["baseline_dominant_stress_component"]
    )
    detailed["lcr_below_one"] = detailed["lcr"].lt(1.0)
    detailed["shortfall_triggered"] = detailed["liquidity_shortfall"].gt(0.0)
    return detailed.sort_values(
        ["sensitivity_name", "scenario_id", "coverage_basis", "sensitivity_value"]
    ).reset_index(drop=True)


def _direction_pass(values: pd.Series, direction: str, tolerance: float) -> bool:
    numeric = pd.to_numeric(values, errors="raise").astype(float)
    if direction == "unconstrained" or len(numeric) <= 1:
        return True
    differences = numeric.diff().dropna()
    scale = max(1.0, float(numeric.abs().max()))
    allowed = tolerance * scale
    if direction == "nondecreasing":
        return bool((differences >= -allowed).all())
    if direction == "nonincreasing":
        return bool((differences <= allowed).all())
    if direction == "flat":
        return bool((differences.abs() <= allowed).all())
    raise ValueError(f"Unsupported direction: {direction}")


def summarize_sensitivities(
    detailed: pd.DataFrame,
    specs: tuple[SensitivitySpec, ...],
    tolerance: float,
) -> pd.DataFrame:
    """Assess directionality, monotonicity, breaches, and rank/component changes."""

    spec_map = {spec.name: spec for spec in specs}
    records: list[dict[str, Any]] = []
    group_columns = ["sensitivity_name", "scenario_id", "coverage_basis"]
    for keys, group in detailed.groupby(group_columns, sort=True):
        sensitivity_name, scenario_id, coverage_basis = cast(tuple[str, str, str], keys)
        spec = spec_map[sensitivity_name]
        ordered = group.sort_values("sensitivity_value")
        requirement_pass = _direction_pass(
            ordered["stressed_requirement"], spec.requirement_direction, tolerance
        )
        resource_pass = _direction_pass(
            ordered["available_resources"], spec.resource_direction, tolerance
        )
        lcr_pass = _direction_pass(ordered["lcr"], spec.lcr_direction, tolerance)
        overall_pass = requirement_pass and resource_pass and lcr_pass
        finite_lcr_elasticity = pd.to_numeric(ordered["lcr_elasticity"], errors="coerce").dropna()
        finite_requirement_elasticity = pd.to_numeric(
            ordered["requirement_elasticity"], errors="coerce"
        ).dropna()
        baseline_row = ordered.loc[ordered["sensitivity_value"].eq(spec.baseline)].iloc[0]
        first = ordered.iloc[0]
        last = ordered.iloc[-1]
        records.append(
            {
                "sensitivity_name": sensitivity_name,
                "scenario_id": scenario_id,
                "coverage_basis": coverage_basis,
                "description": spec.description,
                "points_tested": len(ordered),
                "baseline_value": spec.baseline,
                "baseline_lcr": float(baseline_row["lcr"]),
                "minimum_lcr": float(ordered["lcr"].min()),
                "maximum_lcr": float(ordered["lcr"].max()),
                "endpoint_requirement_change_pct": _percent_change(
                    float(last["stressed_requirement"]), float(first["stressed_requirement"])
                ),
                "endpoint_resource_change_pct": _percent_change(
                    float(last["available_resources"]), float(first["available_resources"])
                ),
                "endpoint_lcr_change_pct": _percent_change(float(last["lcr"]), float(first["lcr"])),
                "maximum_absolute_requirement_elasticity": (
                    float(finite_requirement_elasticity.abs().max())
                    if not finite_requirement_elasticity.empty
                    else math.nan
                ),
                "maximum_absolute_lcr_elasticity": (
                    float(finite_lcr_elasticity.abs().max())
                    if not finite_lcr_elasticity.empty
                    else math.nan
                ),
                "lcr_breach_count": int(ordered["lcr_below_one"].sum()),
                "shortfall_count": int(ordered["shortfall_triggered"].sum()),
                "default_set_change_count": int(ordered["default_set_changed"].sum()),
                "dominant_component_change_count": int(
                    ordered["dominant_component_changed"].sum()
                ),
                "requirement_direction": spec.requirement_direction,
                "resource_direction": spec.resource_direction,
                "lcr_direction": spec.lcr_direction,
                "requirement_direction_status": "PASS" if requirement_pass else "FAIL",
                "resource_direction_status": "PASS" if resource_pass else "FAIL",
                "lcr_direction_status": "PASS" if lcr_pass else "FAIL",
                "overall_status": "PASS" if overall_pass else "FAIL",
            }
        )
    return pd.DataFrame.from_records(records).sort_values(group_columns).reset_index(drop=True)


def build_findings(summary: pd.DataFrame) -> pd.DataFrame:
    """Create a controlled findings register from sensitivity outcomes."""

    records: list[dict[str, Any]] = []
    for finding_number, (_, row) in enumerate(summary.iterrows(), start=1):
        failed = str(row["overall_status"]) == "FAIL"
        breach_count = int(row["lcr_breach_count"])
        if failed:
            severity = "High"
            status = "Open"
            observation = (
                "One or more expected directional relationships failed under the controlled "
                "sensitivity grid."
            )
            recommendation = (
                "Investigate model logic, clipping, default-set transitions, and resource "
                "exclusions before validation approval."
            )
        elif breach_count > 0:
            severity = "Medium"
            status = "Observation"
            observation = (
                f"The sensitivity grid produced {breach_count} LCR observations below 1.0 while "
                "maintaining expected directional behavior."
            )
            recommendation = (
                "Confirm that the breach thresholds and management actions are reflected in model "
                "governance and limit monitoring."
            )
        else:
            severity = "Observation"
            status = "Closed"
            observation = "Expected directional behavior was preserved and no LCR breach occurred."
            recommendation = (
                "Retain the tested range as regression evidence for future model changes."
            )
        records.append(
            {
                "finding_id": f"S26-{finding_number:03d}",
                "sensitivity_name": str(row["sensitivity_name"]),
                "scenario_id": str(row["scenario_id"]),
                "coverage_basis": str(row["coverage_basis"]),
                "severity": severity,
                "status": status,
                "observation": observation,
                "recommendation": recommendation,
            }
        )
    return pd.DataFrame.from_records(records)


def _resolve(project_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else project_root / path


def _write_csv(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(path, index=False, float_format="%.12f")


def run_analysis(config_path: Path) -> dict[str, Any]:
    """Execute Section 26 and write auditable validation artifacts."""

    config_path = config_path.resolve()
    project_root = config_path.parent.parent
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(loaded, Mapping):
        raise ValueError("The Section 26 config must be a mapping")
    config = cast(Mapping[str, Any], loaded)
    specs = load_sensitivity_specs(config)

    inputs = config.get("inputs")
    outputs = config.get("outputs")
    analysis = config.get("analysis")
    if not isinstance(inputs, Mapping) or not isinstance(outputs, Mapping):
        raise ValueError("The Section 26 config must define inputs and outputs mappings")
    if not isinstance(analysis, Mapping):
        raise ValueError("The Section 26 config must define an analysis mapping")

    members_path = _resolve(project_root, str(inputs["members"]))
    resources_path = _resolve(project_root, str(inputs["resources"]))
    members = pd.read_csv(members_path)
    resources = pd.read_csv(resources_path, keep_default_na=False)
    tolerance = float(analysis.get("monotonic_tolerance", 1.0e-10))
    if tolerance < 0.0:
        raise ValueError("analysis.monotonic_tolerance must be nonnegative")

    detailed = run_sensitivity_grid(members, resources, specs)
    summary = summarize_sensitivities(detailed, specs, tolerance)
    findings = build_findings(summary)
    baselines = detailed.loc[
        detailed["sensitivity_value"].eq(detailed["baseline_value"])
    ].copy()

    detailed_path = _resolve(project_root, str(outputs["detailed_results"]))
    summary_path = _resolve(project_root, str(outputs["summary_table"]))
    baselines_path = _resolve(project_root, str(outputs["baseline_results"]))
    findings_path = _resolve(project_root, str(outputs["findings_register"]))
    evidence_json_path = _resolve(project_root, str(outputs["evidence_json"]))
    evidence_txt_path = _resolve(project_root, str(outputs["evidence_txt"]))

    _write_csv(detailed, detailed_path)
    _write_csv(summary, summary_path)
    _write_csv(baselines, baselines_path)
    _write_csv(findings, findings_path)

    failed_groups = int(summary["overall_status"].eq("FAIL").sum())
    sensitivity_impact = (
        summary.groupby("sensitivity_name", sort=True)["endpoint_lcr_change_pct"]
        .apply(lambda series: float(series.abs().max()))
        .sort_values(ascending=False)
    )
    most_sensitive = str(sensitivity_impact.index[0]) if not sensitivity_impact.empty else ""
    evidence: dict[str, Any] = {
        "section": 26,
        "name": "sensitivity_analysis",
        "overall_status": "PASS" if failed_groups == 0 else "FAIL",
        "required_sensitivities": list(REQUIRED_SENSITIVITIES),
        "sensitivities_executed": sorted(detailed["sensitivity_name"].unique().tolist()),
        "scenarios_tested": sorted(detailed["scenario_id"].unique().tolist()),
        "detailed_rows": len(detailed),
        "summary_groups": len(summary),
        "failed_directional_groups": failed_groups,
        "lcr_breach_observations": int(detailed["lcr_below_one"].sum()),
        "shortfall_observations": int(detailed["shortfall_triggered"].sum()),
        "default_set_changes": int(detailed["default_set_changed"].sum()),
        "dominant_component_changes": int(detailed["dominant_component_changed"].sum()),
        "most_lcr_sensitive_dimension": most_sensitive,
        "independence_boundary": (
            "Uses the Section 25 independent flat-file calculation path and does not call "
            "production stress functions."
        ),
    }
    evidence_json_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_json_path.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    lines = [
        "PHASE VII SECTION 26 - SENSITIVITY ANALYSIS",
        f"OVERALL STATUS: {evidence['overall_status']}",
        f"SENSITIVITIES EXECUTED: {len(evidence['sensitivities_executed'])}",
        f"SCENARIOS TESTED: {', '.join(evidence['scenarios_tested'])}",
        f"DETAILED ROWS: {evidence['detailed_rows']}",
        f"FAILED DIRECTIONAL GROUPS: {failed_groups}",
        f"LCR BREACH OBSERVATIONS: {evidence['lcr_breach_observations']}",
        f"SHORTFALL OBSERVATIONS: {evidence['shortfall_observations']}",
        f"MOST LCR-SENSITIVE DIMENSION: {most_sensitive}",
        "",
        "INDEPENDENCE BOUNDARY:",
        str(evidence["independence_boundary"]),
    ]
    evidence_txt_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_txt_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return evidence


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run Phase VII Section 26 sensitivity analysis")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/sensitivity_analysis.yaml"),
        help="Path to the controlled Section 26 YAML configuration",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    evidence = run_analysis(args.config)
    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0 if evidence["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "src\ficc_liquidity\validation\sensitivity_analysis.py") -Content $sensitivityModule

$runnerScript = @'
from ficc_liquidity.validation.sensitivity_analysis import main


if __name__ == "__main__":
    raise SystemExit(main())
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "scripts\run_section26_sensitivity_analysis.py") -Content $runnerScript

$sensitivityConfig = @'
schema_version: "1.0"
section: 26
name: sensitivity_analysis

inputs:
  members: data/validation/fixtures/section25_members.csv
  resources: data/validation/fixtures/section25_resources.csv

analysis:
  monotonic_tolerance: 1.0e-10
  dimensions:
    yield_shocks:
      values: [0.50, 0.75, 1.00, 1.25, 1.50, 2.00]
      baseline: 1.00
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Multipliers applied to Treasury yield shocks.
    duration_assumptions:
      values: [0.75, 0.90, 1.00, 1.10, 1.25, 1.50]
      baseline: 1.00
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Multipliers applied to modified-duration assumptions.
    sofr_spikes:
      values: [0.50, 0.75, 1.00, 1.50, 2.00, 3.00]
      baseline: 1.00
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Multipliers applied to stressed SOFR spikes.
    rollover_failure_percentages:
      values: [0.50, 0.75, 1.00, 1.25, 1.50, 2.00]
      baseline: 1.00
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Multipliers applied to repo rollover-failure percentages, capped at 100 percent.
    haircut_increases:
      values: [0.50, 0.75, 1.00, 1.50, 2.00, 3.00]
      baseline: 1.00
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Multipliers applied to collateral haircut increases, capped at 100 percent.
    settlement_fail_percentages:
      values: [0.50, 0.75, 1.00, 1.25, 1.50, 2.00]
      baseline: 1.00
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Multipliers applied to fails-to-receive and delayed-payment stress amounts.
    member_concentration:
      values: [0.50, 0.75, 1.00, 1.25, 1.50, 2.00]
      baseline: 1.00
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Multipliers applied to concentration multipliers and concentration add-on percentages.
    liquidation_horizon:
      values: [1, 3, 5, 7, 10]
      baseline: 5
      requirement_direction: nondecreasing
      resource_direction: unconstrained
      lcr_direction: nonincreasing
      description: Liquidation-horizon days using square-root-of-time scaling around the five-day baseline.
    default_set_size:
      values: [1, 2, 3]
      baseline: 2
      requirement_direction: nondecreasing
      resource_direction: nonincreasing
      lcr_direction: nonincreasing
      description: Generalized Cover N default-set size.
    available_resource_assumptions:
      values: [0.50, 0.75, 0.90, 1.00, 1.10, 1.25]
      baseline: 1.00
      requirement_direction: flat
      resource_direction: nondecreasing
      lcr_direction: nondecreasing
      description: Multipliers applied to qualified-resource availability factors, capped at 100 percent.

outputs:
  detailed_results: reports/tables/section26_sensitivity_detailed.csv
  summary_table: reports/tables/section26_sensitivity_summary.csv
  baseline_results: reports/tables/section26_sensitivity_baselines.csv
  findings_register: reports/tables/section26_sensitivity_findings.csv
  evidence_json: reports/evidence/section26_sensitivity_summary.json
  evidence_txt: reports/evidence/section26_sensitivity_analysis.txt
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "configs\sensitivity_analysis.yaml") -Content $sensitivityConfig

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
Set-Utf8File -Path (Join-Path $resolvedRoot "configs\mypy_section26.ini") -Content $mypyConfig

$sectionTests = @'
from __future__ import annotations

from pathlib import Path

import pandas as pd
import pytest
import yaml

from ficc_liquidity.validation.independent_implementation import (
    calculate_member_stress,
    calculate_qualified_resources,
)
from ficc_liquidity.validation.sensitivity_analysis import (
    REQUIRED_SENSITIVITIES,
    apply_sensitivity,
    calculate_default_set_result,
    load_sensitivity_specs,
    run_analysis,
    run_sensitivity_grid,
    summarize_sensitivities,
)

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "configs" / "sensitivity_analysis.yaml"


def _load() -> tuple[dict[str, object], pd.DataFrame, pd.DataFrame]:
    config = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    members = pd.read_csv(ROOT / "data" / "validation" / "fixtures" / "section25_members.csv")
    resources = pd.read_csv(
        ROOT / "data" / "validation" / "fixtures" / "section25_resources.csv",
        keep_default_na=False,
    )
    return config, members, resources


def test_all_required_sensitivities_are_configured() -> None:
    config, _, _ = _load()
    specs = load_sensitivity_specs(config)
    assert tuple(spec.name for spec in specs) == REQUIRED_SENSITIVITIES


def test_baseline_reproduces_independent_cover_results() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    independent_members = calculate_member_stress(members)
    independent_resources = calculate_qualified_resources(resources)
    baseline = detailed.loc[
        detailed["sensitivity_name"].eq("yield_shocks")
        & detailed["sensitivity_value"].eq(1.0)
    ]
    for _, row in baseline.iterrows():
        size = 1 if row["coverage_basis"] == "cover1" else 2
        direct = calculate_default_set_result(
            independent_members, independent_resources, str(row["scenario_id"]), size
        )
        assert float(row["stressed_requirement"]) == pytest.approx(
            direct["stressed_requirement"], rel=1.0e-12
        )
        assert float(row["available_resources"]) == pytest.approx(
            direct["available_resources"], rel=1.0e-12
        )
        assert float(row["lcr"]) == pytest.approx(direct["lcr"], rel=1.0e-12)


def test_all_directional_controls_pass() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    summary = summarize_sensitivities(detailed, specs, 1.0e-10)
    assert summary["overall_status"].eq("PASS").all(), summary.loc[
        summary["overall_status"].eq("FAIL")
    ].to_dict("records")


def test_available_resource_assumption_leaves_requirement_flat() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    subset = detailed.loc[
        detailed["sensitivity_name"].eq("available_resource_assumptions")
    ]
    requirement_counts = subset.groupby(["scenario_id", "coverage_basis"])[
        "stressed_requirement"
    ].nunique()
    assert requirement_counts.eq(1).all()
    for _, group in subset.groupby(["scenario_id", "coverage_basis"]):
        ordered = group.sort_values("sensitivity_value")
        assert ordered["available_resources"].is_monotonic_increasing
        assert ordered["lcr"].is_monotonic_increasing


def test_default_set_size_is_nested_and_requirement_is_nondecreasing() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    subset = detailed.loc[detailed["sensitivity_name"].eq("default_set_size")]
    for _, group in subset.groupby("scenario_id"):
        ordered = group.sort_values("sensitivity_value")
        assert ordered["stressed_requirement"].is_monotonic_increasing
        prior: set[str] = set()
        for members_value in ordered["default_members"].astype(str):
            current = set(members_value.split("|"))
            assert prior.issubset(current)
            prior = current


def test_fraction_sensitivities_are_capped() -> None:
    config, members, resources = _load()
    specs = {spec.name: spec for spec in load_sensitivity_specs(config)}
    shocked, _, _ = apply_sensitivity(
        members, resources, specs["rollover_failure_percentages"], 2.0
    )
    assert shocked["repo_rollover_failure_rate"].max() <= 1.0
    shocked, _, _ = apply_sensitivity(members, resources, specs["haircut_increases"], 3.0)
    assert shocked["haircut_increase_pct"].max() <= 1.0
    _, shocked_resources, _ = apply_sensitivity(
        members, resources, specs["available_resource_assumptions"], 1.25
    )
    assert shocked_resources["availability_factor"].max() <= 1.0


def test_analysis_is_deterministic_and_inputs_are_immutable() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    members_before = members.copy(deep=True)
    resources_before = resources.copy(deep=True)
    first = run_sensitivity_grid(members, resources, specs)
    second = run_sensitivity_grid(members, resources, specs)
    pd.testing.assert_frame_equal(first, second)
    pd.testing.assert_frame_equal(members, members_before)
    pd.testing.assert_frame_equal(resources, resources_before)


def test_missing_dimension_is_rejected() -> None:
    config, _, _ = _load()
    dimensions = config["analysis"]["dimensions"]
    dimensions.pop("yield_shocks")
    with pytest.raises(ValueError, match="Missing"):
        load_sensitivity_specs(config)


def test_runner_writes_pass_evidence() -> None:
    evidence = run_analysis(CONFIG_PATH)
    assert evidence["overall_status"] == "PASS"
    assert evidence["failed_directional_groups"] == 0
    assert evidence["sensitivities_executed"] == sorted(REQUIRED_SENSITIVITIES)
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "tests\test_section26_sensitivity_analysis.py") -Content $sectionTests

$documentation = @'
# Section 26 — Sensitivity Analysis

## Objective

Section 26 independently challenges the stability and directional behavior of the liquidity stress model across ten material assumptions:

1. Treasury yield shocks.
2. Modified-duration assumptions.
3. SOFR spikes.
4. Repo rollover-failure percentages.
5. Collateral haircut increases.
6. Settlement-fail percentages.
7. Member concentration.
8. Liquidation horizon.
9. Default-set size.
10. Available qualified liquid-resource assumptions.

## Independence boundary

The Section 26 validator uses the flat-file calculation path established in Section 25. It imports only the Section 25 independent calculation functions and does not call the production stress engines. This preserves a calculation boundary between validation analysis and production implementation.

## Sensitivity design

Each sensitivity contains a controlled, ordered grid with an explicit baseline. The validator recalculates member stress, generalized Cover N default sets, qualified resources, LCR, liquidity shortfalls, resource utilization, and the dominant stress component.

For every sensitivity point, the analysis records:

- stressed liquidity requirement;
- available qualified liquid resources;
- LCR;
- liquidity shortfall;
- resource utilization;
- selected default members;
- dominant stress component;
- percentage change from baseline;
- requirement and LCR elasticity;
- LCR-breach and shortfall indicators;
- default-set and dominant-component changes.

## Directional expectations

The controlled configuration requires worsening member-stress assumptions to produce nondecreasing stressed requirements and nonincreasing LCRs. Increasing available-resource assumptions must leave the denominator unchanged while producing nondecreasing resources and LCR. Increasing default-set size must produce a nested default set, nondecreasing requirement, nonincreasing available resources, and nonincreasing LCR.

Resource direction is unconstrained for member-stress sensitivities because rank changes can alter which member-owned resources are excluded. The LCR direction remains explicitly tested.

## Liquidation-horizon assumption

The Section 25 flat-file contract does not contain a separate liquidation-horizon field. Section 26 therefore applies a transparent square-root-of-time scaling to the Treasury yield shock around a five-day baseline:

`effective shock = baseline shock × sqrt(test horizon / 5 days)`

This is a validation assumption, not a claim that the production model uses this exact scaling. It is documented so that future production-output comparisons can replace the proxy with the production liquidation-horizon implementation.

## Default-set-size analysis

The validator generalizes Cover 1 and Cover 2 to Cover N. Members are ranked by independently calculated stressed liquidity requirement with deterministic member-ID tie-breaking. Qualified resources owned by defaulting members are excluded.

## Outputs

- `reports/tables/section26_sensitivity_detailed.csv`
- `reports/tables/section26_sensitivity_summary.csv`
- `reports/tables/section26_sensitivity_baselines.csv`
- `reports/tables/section26_sensitivity_findings.csv`
- `reports/evidence/section26_sensitivity_summary.json`
- `reports/evidence/section26_sensitivity_analysis.txt`

## Acceptance criteria

- All ten required sensitivities are configured and executed.
- Baseline results reproduce the Section 25 independent calculation path.
- Directional and monotonicity controls pass.
- Default sets are deterministic and nested as size increases.
- Fraction-based assumptions remain within valid bounds.
- Available-resource shocks do not change stressed requirements.
- Repeated runs are deterministic.
- Source inputs remain unchanged.
- Evidence and findings are written for model-validation review.
'@
Set-Utf8File -Path (Join-Path $resolvedRoot "docs\section26_sensitivity_analysis.md") -Content $documentation

$pythonCommand = Resolve-PythonExecutable -Root $resolvedRoot
Write-Pass "Python command resolved: $pythonCommand"

Write-Step "Installing the local package in editable mode"
Invoke-Python -PythonCommand $pythonCommand -Arguments @("-m", "pip", "install", "-e", ".", "--no-deps")

if (-not $SkipTests) {
    Write-Step "Compiling the Section 26 Python files"
    Invoke-Python -PythonCommand $pythonCommand -Arguments @(
        "-m", "py_compile",
        "src\ficc_liquidity\validation\sensitivity_analysis.py",
        "scripts\run_section26_sensitivity_analysis.py",
        "tests\test_section26_sensitivity_analysis.py"
    )
    Write-Pass "Python compilation"

    Write-Step "Running focused Section 26 tests"
    Invoke-Python -PythonCommand $pythonCommand -Arguments @(
        "-m", "pytest",
        "tests\test_section26_sensitivity_analysis.py",
        "-q",
        "-o", "addopts="
    )
    Write-Pass "Focused Section 26 tests"

    if (Test-PythonModule -PythonCommand $pythonCommand -ModuleName "ruff") {
        Write-Step "Running Ruff on Section 26 files"
        Invoke-Python -PythonCommand $pythonCommand -Arguments @(
            "-m", "ruff", "check",
            "src\ficc_liquidity\validation\sensitivity_analysis.py",
            "scripts\run_section26_sensitivity_analysis.py",
            "tests\test_section26_sensitivity_analysis.py"
        )
        Write-Pass "Ruff validation"
    }
    else {
        Write-Warn "Ruff is not installed; the Ruff check was skipped."
    }

    if (Test-PythonModule -PythonCommand $pythonCommand -ModuleName "mypy") {
        Write-Step "Running mypy on the Section 26 module"
        Invoke-Python -PythonCommand $pythonCommand -Arguments @(
            "-m", "mypy",
            "--config-file", "configs\mypy_section26.ini",
            "src\ficc_liquidity\validation\sensitivity_analysis.py"
        )
        Write-Pass "Mypy validation"
    }
    else {
        Write-Warn "mypy is not installed; the mypy check was skipped."
    }

    if (-not $SkipFullSuite) {
        Write-Step "Running the complete repository test suite"
        Invoke-Python -PythonCommand $pythonCommand -Arguments @("-m", "pytest", "-q")
        Write-Pass "Complete repository test suite"
    }
}

Write-Step "Executing the controlled Section 26 sensitivity analysis"
Invoke-Python -PythonCommand $pythonCommand -Arguments @(
    "scripts\run_section26_sensitivity_analysis.py",
    "--config", "configs\sensitivity_analysis.yaml"
)

$summaryPath = Join-Path $resolvedRoot "reports\evidence\section26_sensitivity_summary.json"
if (-not (Test-Path $summaryPath)) {
    throw "Section 26 evidence summary was not created: $summaryPath"
}
$summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
if ($summary.overall_status -ne "PASS") {
    throw "Section 26 directional controls did not pass. Review $summaryPath and reports\tables\section26_sensitivity_findings.csv."
}
if (@($summary.sensitivities_executed).Count -ne 10) {
    throw "Section 26 did not execute all ten required sensitivities."
}
Write-Pass "All ten sensitivity dimensions executed with passing directional controls"

if (-not $SkipGit) {
    Write-Step "Reviewing generated Git changes"
    git status --short

    if ($Commit) {
        $standardPaths = @(
            "configs\sensitivity_analysis.yaml",
            "configs\mypy_section26.ini",
            "docs\section26_sensitivity_analysis.md",
            "scripts\run_section26_sensitivity_analysis.py",
            "src\ficc_liquidity\validation\sensitivity_analysis.py",
            "tests\test_section26_sensitivity_analysis.py",
            $automationFileName
        )
        $ignoredReportPaths = @(
            "reports\tables\section26_sensitivity_detailed.csv",
            "reports\tables\section26_sensitivity_summary.csv",
            "reports\tables\section26_sensitivity_baselines.csv",
            "reports\tables\section26_sensitivity_findings.csv",
            "reports\evidence\section26_sensitivity_summary.json",
            "reports\evidence\section26_sensitivity_analysis.txt"
        )

        Invoke-Native -FilePath git -Arguments (@("add", "--") + $standardPaths)
        Invoke-Native -FilePath git -Arguments (@("add", "-f", "--") + $ignoredReportPaths)

        $staged = @(git diff --cached --name-only)
        if ($staged.Count -eq 0) {
            Write-Warn "No changes were staged; no commit was created."
        }
        else {
            Invoke-Native -FilePath git -Arguments @(
                "commit", "-m", "Phase VII Section 26: sensitivity analysis"
            )
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
                "pr", "create",
                "--base", "main",
                "--head", $Branch,
                "--title", "Phase VII Section 26: Sensitivity analysis",
                "--body", "Implements independent sensitivity analysis for Treasury yield shocks, duration assumptions, SOFR spikes, rollover failures, haircut increases, settlement fails, member concentration, liquidation horizon, default-set size, and available-resource assumptions. Includes baseline reconciliation to Section 25, monotonicity and directionality controls, elasticity metrics, Cover N analysis, LCR and shortfall transitions, deterministic tests, findings, and validation evidence."
            )
            Write-Pass "Pull request created"
        }
    }
}

Write-Host ""
Write-Host "SECTION 26 COMPLETE" -ForegroundColor Green
Write-Host "Branch: $Branch"
Write-Host "Detailed results: reports\tables\section26_sensitivity_detailed.csv"
Write-Host "Summary table: reports\tables\section26_sensitivity_summary.csv"
Write-Host "Findings: reports\tables\section26_sensitivity_findings.csv"
Write-Host "Evidence: reports\evidence\section26_sensitivity_summary.json"
Write-Host ""
