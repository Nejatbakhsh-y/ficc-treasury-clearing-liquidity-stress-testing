#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase V, Section 19: integrated stressed liquidity requirement.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.

    The automation updates main, verifies that Section 18 has been merged,
    prepares feature/17-integrated-stress-engine, writes the controlled Section
    19 configuration, Python integration engine, runner, tests, methodology,
    evidence, lineage manifest, and result tables; executes required prior
    stress models; validates atomic component selection and no-double-counting
    identities; calculates stressed liquidity requirements and LCR; runs Ruff,
    strict Mypy, focused branch coverage, and the complete repository test
    suite; then commits, pushes, and opens a pull request.

    Integrated components:
      - Settlement liquidity need
      - Repo rollover need
      - Incremental funding cost
      - Additional haircut requirement
      - Treasury liquidation loss
      - Settlement-fail requirement
      - Concentration adjustment
      - Operational liquidity buffer

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\21_P5S19_Integrated_Stress_Engine_PS51.ps1"

.EXAMPLE
    & "$env:USERPROFILE\Downloads\21_P5S19_Integrated_Stress_Engine_PS51.ps1" `
        -SkipFullTests -NoCommit -SkipPush -SkipPullRequest
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoPath = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",

    [Parameter()]
    [switch]$AllowDirty,

    [Parameter()]
    [switch]$SkipGit,

    [Parameter()]
    [switch]$NoCommit,

    [Parameter()]
    [switch]$SkipPush,

    [Parameter()]
    [switch]$SkipPullRequest,

    [Parameter()]
    [switch]$SkipFullTests,

    [Parameter()]
    [switch]$SkipPriorRuns,

    [Parameter()]
    [switch]$WatchChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (Test-Path -LiteralPath "variable:PSNativeCommandUseErrorActionPreference") {
    $PSNativeCommandUseErrorActionPreference = $false
}

$RepoFullName = "Nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing"
$BranchName = "feature/17-integrated-stress-engine"
$CommitMessage = "Phase V Section 19: add integrated stress engine"
$PullRequestTitle = "Phase V Section 19: Integrated stressed liquidity requirement"
$AutomationRelativePath = "scripts\automation\21_P5S19_Integrated_Stress_Engine_PS51.ps1"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][string]$FailureMessage = "Command failed."
    )

    Write-Host (">> {0} {1}" -f $FilePath, ($ArgumentList -join " ")) -ForegroundColor DarkGray
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage Exit code: $LASTEXITCODE"
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText(
        $Path,
        ($normalized.TrimStart() + "`n"),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Test-RequiredFiles {
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    foreach ($relativePath in $Paths) {
        if (-not (Test-Path -LiteralPath $relativePath -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Get-CurrentBranch {
    $branch = & git branch --show-current
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to determine the current Git branch."
    }
    return ([string]$branch).Trim()
}

function Add-ControlledPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    & git check-ignore -q -- $Path
    $isIgnored = $LASTEXITCODE -eq 0
    if ($isIgnored) {
        & git add -f -- $Path
    }
    else {
        & git add -- $Path
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to stage controlled path: $Path"
    }
}

$OriginalLocation = Get-Location

try {
    $RepoPath = (Resolve-Path -LiteralPath $RepoPath -ErrorAction Stop).Path
    $ScriptPath = $MyInvocation.MyCommand.Path
    Set-Location $RepoPath

    Write-Step "Validating repository, tools, and working-tree state"

    if (-not (Test-Path -LiteralPath ".git" -PathType Container)) {
        throw "The selected folder is not a Git repository: $RepoPath"
    }
    if (-not (Test-Path -LiteralPath "pyproject.toml" -PathType Leaf)) {
        throw "pyproject.toml was not found. Open the FICC repository in VS Code."
    }

    Assert-Command -Name "git"

    $skipBranchRefresh = $false
    if (-not $SkipGit) {
        $currentBranch = Get-CurrentBranch
        $dirty = @(& git status --porcelain)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect Git working-tree status."
        }

        if ($dirty.Count -gt 0) {
            if (-not $AllowDirty) {
                throw @"
The working tree contains uncommitted changes.
Commit or stash them, then rerun this automation.
Use -AllowDirty only when rerunning Section 19 on its feature branch.
"@
            }
            if ($currentBranch -ne $BranchName) {
                throw @"
-AllowDirty is safe only when the current branch is $BranchName.
The current branch is $currentBranch. Commit or stash existing changes first.
"@
            }
            $skipBranchRefresh = $true
            Write-Warn "Dirty Section 19 branch retained; main refresh and merge were skipped."
        }
    }

    if (-not $SkipGit -and -not $skipBranchRefresh) {
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("fetch", "origin", "--prune") `
            -FailureMessage "Unable to fetch origin."
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("switch", "main") `
            -FailureMessage "Unable to switch to main."
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("pull", "--ff-only", "origin", "main") `
            -FailureMessage "Unable to update main."

        $section18MainGate = @(
            "configs\settlement_fail_stress.yaml",
            "src\ficc_liquidity\stress\settlement_fail_stress.py",
            "scripts\run_settlement_fail_stress.py",
            "tests\test_settlement_fail_stress.py"
        )
        if (-not (Test-RequiredFiles -Paths $section18MainGate)) {
            throw @"
Section 18 is not present on the updated main branch.
Merge GitHub pull request #22 (feature/16-settlement-fails) into main,
then rerun this Section 19 automation.
"@
        }
        Write-Pass "Section 18 is merged and available on main"

        Write-Step "Preparing branch $BranchName"
        & git show-ref --verify --quiet "refs/heads/$BranchName"
        $localBranchExists = $LASTEXITCODE -eq 0
        & git ls-remote --exit-code --heads origin $BranchName *> $null
        $remoteBranchExists = $LASTEXITCODE -eq 0

        if ($localBranchExists) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("switch", $BranchName) `
                -FailureMessage "Unable to switch to $BranchName."
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("merge", "--no-edit", "main") `
                -FailureMessage "Unable to integrate current main into $BranchName."
        }
        elseif ($remoteBranchExists) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("switch", "--track", "-c", $BranchName, "origin/$BranchName") `
                -FailureMessage "Unable to restore $BranchName from origin."
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("merge", "--no-edit", "main") `
                -FailureMessage "Unable to integrate current main into $BranchName."
        }
        else {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("switch", "-c", $BranchName, "main") `
                -FailureMessage "Unable to create $BranchName from main."
        }
        Write-Pass "Current branch is $BranchName"
    }
    elseif ($SkipGit) {
        Write-Warn "Git branch operations were skipped."
    }

    Write-Step "Confirming Sections 12 and 14 through 18 dependencies"
    $requiredDependencies = @(
        "data\synthetic\calibrated_member_portfolios.parquet",
        "configs\baseline_liquidity.yaml",
        "scripts\run_baseline_liquidity.py",
        "src\ficc_liquidity\liquidity\baseline_cashflow.py",
        "configs\treasury_yield_stress.yaml",
        "scripts\run_treasury_yield_stress.py",
        "src\ficc_liquidity\stress\treasury_yield_shock.py",
        "configs\repo_funding_stress.yaml",
        "scripts\run_repo_funding_stress.py",
        "src\ficc_liquidity\stress\repo_funding_stress.py",
        "configs\collateral_haircut_stress.yaml",
        "scripts\run_collateral_haircut_stress.py",
        "src\ficc_liquidity\stress\collateral_haircut_stress.py",
        "configs\settlement_fail_stress.yaml",
        "scripts\run_settlement_fail_stress.py",
        "src\ficc_liquidity\stress\settlement_fail_stress.py"
    )
    if (-not (Test-RequiredFiles -Paths $requiredDependencies)) {
        $missing = @(
            foreach ($dependency in $requiredDependencies) {
                if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
                    $dependency
                }
            }
        )
        throw "Required prior-section files are missing: $($missing -join ', ')"
    }
    Write-Pass "Required prior-section source files are available"

    Write-Step "Creating Section 19 directories and controlled files"
    foreach ($directory in @(
        "configs",
        "data\manifests",
        "docs",
        "reports\evidence",
        "reports\tables",
        "scripts",
        "scripts\automation",
        "src\ficc_liquidity\stress",
        "tests"
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $automationTarget = Join-Path $RepoPath $AutomationRelativePath
    if (
        $ScriptPath -and
        -not $ScriptPath.Equals(
            $automationTarget,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Copy-Item -LiteralPath $ScriptPath -Destination $automationTarget -Force
    }

$ConfigContent = @'
schema_version: "1.0"
section: 19
model_name: integrated_stressed_liquidity_requirement
model_version: "section-19-v1"
currency: USD
random_seed: 2026

classification:
  baseline_cash_flows: modeled
  repo_funding_stress_results: modeled
  treasury_yield_stress_results: modeled
  collateral_haircut_stress_results: modeled
  settlement_fail_stress_results: modeled
  concentration_adjustment: assumed
  operational_liquidity_buffer: assumed
  integrated_results: modeled
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false

source:
  baseline_summary_candidates:
    - reports/tables/baseline_liquidity_summary.parquet
    - reports/tables/baseline_liquidity_summary.csv
  funding_summary_candidates:
    - reports/tables/repo_funding_stress_member_summary.parquet
    - reports/tables/repo_funding_stress_member_summary.csv
  haircut_summary_candidates:
    - reports/tables/collateral_haircut_stress_member_summary.parquet
    - reports/tables/collateral_haircut_stress_member_summary.csv
  treasury_summary_candidates:
    - reports/tables/treasury_yield_stress_member_summary_section19_adapter.parquet
    - reports/tables/treasury_yield_stress_member_summary_section19_adapter.csv
    - reports/tables/treasury_yield_stress_member_summary.parquet
    - reports/tables/treasury_yield_stress_member_summary.csv
  settlement_fail_cashflow_candidates:
    - reports/tables/settlement_fail_stress_cashflows.parquet
    - reports/tables/settlement_fail_stress_cashflows.csv
  synthetic_member_profile_candidates:
    - data/synthetic/calibrated_member_portfolios.parquet
    - data/synthetic/calibrated_member_portfolios.csv
  treasury_yield_config: configs/treasury_yield_stress.yaml
  synthetic_id_pattern: '^SYN-MBR-[0-9]{4}$'

integration:
  lcr_minimum_ratio: 1.00
  aqlr_basis: section14_modeled_aqlr
  concentration_base_components:
    - settlement_liquidity_need_usd
    - settlement_fail_requirement_usd
  excluded_composite_controls:
    - section16_incremental_repo_funding_stress_outflow
    - section16_additional_collateral_demand
    - section18_incremental_combined_stress_outflow
    - section18_combined_funding_shock
    - section17_stressed_aqlr_reduction

treasury_adapter:
  enabled_when_summary_unavailable: true
  mapping_method: deterministic_weighted_bucket_bridge
  maturity_mapping:
    - source_column: treasury_position_bills_0_1y_usd
      target_bucket: bills_0_1y
      weight: 1.00
    - source_column: treasury_position_notes_1_3y_usd
      target_bucket: notes_1_2y
      weight: 0.50
    - source_column: treasury_position_notes_1_3y_usd
      target_bucket: notes_2_3y
      weight: 0.50
    - source_column: treasury_position_notes_3_7y_usd
      target_bucket: notes_3_5y
      weight: 0.50
    - source_column: treasury_position_notes_3_7y_usd
      target_bucket: notes_5_7y
      weight: 0.50
    - source_column: treasury_position_notes_7_10y_usd
      target_bucket: notes_7_10y
      weight: 1.00
    - source_column: treasury_position_bonds_10_30y_usd
      target_bucket: bonds_10_20y
      weight: 0.50
    - source_column: treasury_position_bonds_10_30y_usd
      target_bucket: bonds_20_30y
      weight: 0.50
    - source_column: treasury_position_strips_30y_plus_usd
      target_bucket: bonds_30y_plus
      weight: 1.00

scenarios:
  - name: control
    enabled: true
    severity_rank: 0
    funding_scenario_name: control
    haircut_scenario_name: control
    treasury_scenario_name: NONE
    settlement_fail_scenario_name: control
    concentration_threshold: 1.00
    concentration_multiplier: 0.00
    operational_liquidity_buffer_rate: 0.00

  - name: moderate_integrated_stress
    enabled: true
    severity_rank: 1
    funding_scenario_name: moderate_market_stress
    haircut_scenario_name: moderate_haircut_stress
    treasury_scenario_name: key_rate_5y_up_100bp
    settlement_fail_scenario_name: moderate_settlement_disruption
    concentration_threshold: 0.35
    concentration_multiplier: 0.10
    operational_liquidity_buffer_rate: 0.02

  - name: severe_integrated_stress
    enabled: true
    severity_rank: 2
    funding_scenario_name: severe_market_stress
    haircut_scenario_name: severe_haircut_stress
    treasury_scenario_name: parallel_up_100bp
    settlement_fail_scenario_name: severe_multi_day_fails
    concentration_threshold: 0.25
    concentration_multiplier: 0.25
    operational_liquidity_buffer_rate: 0.05

  - name: extreme_integrated_crisis
    enabled: true
    severity_rank: 3
    funding_scenario_name: concentrated_funding_freeze
    haircut_scenario_name: extreme_collateral_freeze
    treasury_scenario_name: bear_steepener
    settlement_fail_scenario_name: combined_settlement_funding_crisis
    concentration_threshold: 0.20
    concentration_multiplier: 0.50
    operational_liquidity_buffer_rate: 0.10

validation:
  reconciliation_tolerance_usd: 0.01
  require_deterministic_reproduction: true
  require_atomic_component_selection: true
  require_composite_identity_checks: true
  require_synthetic_identifiers: true
  require_nondecreasing_aggregate_requirement: true
  require_lcr_identity: true

output:
  directory: reports/tables
  evidence_directory: reports/evidence
  manifest: data/manifests/integrated_stress_engine_manifest.csv
  write_csv: true
  write_parquet: true
'@

$ModuleContent = @'
"""Integrated stressed-liquidity requirement for synthetic clearing members.

Section 19 combines atomic outputs from Sections 14 through 18 without adding
composite totals that would duplicate their constituent stress components.
"""

from __future__ import annotations

import hashlib
import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import yaml


class IntegratedStressError(ValueError):
    """Raised when Section 19 configuration, inputs, or identities are invalid."""


ATOMIC_COMPONENT_COLUMNS: tuple[str, ...] = (
    "settlement_liquidity_need_usd",
    "repo_rollover_need_usd",
    "incremental_funding_cost_usd",
    "additional_haircut_requirement_usd",
    "treasury_liquidation_loss_usd",
    "settlement_fail_requirement_usd",
)
REQUIRED_COMPONENT_COLUMNS: tuple[str, ...] = (
    *ATOMIC_COMPONENT_COLUMNS,
    "concentration_adjustment_usd",
    "operational_liquidity_buffer_usd",
)


@dataclass(frozen=True, slots=True)
class IntegratedScenario:
    """One controlled integrated-liquidity scenario."""

    name: str
    severity_rank: int
    funding_scenario_name: str
    haircut_scenario_name: str
    treasury_scenario_name: str
    settlement_fail_scenario_name: str
    concentration_threshold: float
    concentration_multiplier: float
    operational_liquidity_buffer_rate: float


@dataclass(frozen=True, slots=True)
class IntegratedStressSettings:
    """Validated Section 19 settings."""

    model_version: str
    tolerance_usd: float
    lcr_minimum_ratio: float
    synthetic_id_pattern: str
    concentration_base_components: tuple[str, ...]
    scenarios: tuple[IntegratedScenario, ...]


@dataclass(frozen=True, slots=True)
class IntegratedStressResult:
    """Section 19 member results, summaries, controls, and validation checks."""

    member_results: pd.DataFrame
    scenario_summary: pd.DataFrame
    double_count_controls: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every Section 19 validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise IntegratedStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise IntegratedStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise IntegratedStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise IntegratedStressError(f"{key} must be an integer.")
    return int(value)


def _bounded_rate(value: float, label: str) -> None:
    if not 0.0 <= value <= 1.0:
        raise IntegratedStressError(f"{label} must be between zero and one.")


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled Section 19 YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise IntegratedStressError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _load_scenario(raw: Mapping[str, Any]) -> IntegratedScenario:
    scenario = IntegratedScenario(
        name=str(raw.get("name", "")).strip(),
        severity_rank=_integer(raw, "severity_rank"),
        funding_scenario_name=str(raw.get("funding_scenario_name", "")).strip(),
        haircut_scenario_name=str(raw.get("haircut_scenario_name", "")).strip(),
        treasury_scenario_name=str(raw.get("treasury_scenario_name", "")).strip(),
        settlement_fail_scenario_name=str(raw.get("settlement_fail_scenario_name", "")).strip(),
        concentration_threshold=_number(raw, "concentration_threshold"),
        concentration_multiplier=_number(raw, "concentration_multiplier"),
        operational_liquidity_buffer_rate=_number(raw, "operational_liquidity_buffer_rate"),
    )
    if not scenario.name:
        raise IntegratedStressError("Every scenario must have a nonempty name.")
    if scenario.severity_rank < 0:
        raise IntegratedStressError("severity_rank must be nonnegative.")
    for label, rate_value in (
        ("concentration_threshold", scenario.concentration_threshold),
        (
            "operational_liquidity_buffer_rate",
            scenario.operational_liquidity_buffer_rate,
        ),
    ):
        _bounded_rate(rate_value, f"{scenario.name}.{label}")
    if scenario.concentration_multiplier < 0.0:
        raise IntegratedStressError(
            f"{scenario.name}.concentration_multiplier must be nonnegative."
        )
    for label, scenario_name_value in (
        ("funding_scenario_name", scenario.funding_scenario_name),
        ("haircut_scenario_name", scenario.haircut_scenario_name),
        ("treasury_scenario_name", scenario.treasury_scenario_name),
        ("settlement_fail_scenario_name", scenario.settlement_fail_scenario_name),
    ):
        if not scenario_name_value:
            raise IntegratedStressError(f"{scenario.name}.{label} cannot be empty.")
    return scenario


def load_settings(config: Mapping[str, Any]) -> IntegratedStressSettings:
    """Validate and convert the Section 19 configuration."""
    source = _mapping(config.get("source"), "source")
    integration = _mapping(config.get("integration"), "integration")
    validation = _mapping(config.get("validation"), "validation")
    raw_components = integration.get("concentration_base_components")
    if not isinstance(raw_components, list) or not raw_components:
        raise IntegratedStressError(
            "integration.concentration_base_components must be a nonempty list."
        )
    concentration_base_components = tuple(str(value).strip() for value in raw_components)
    if any(not value for value in concentration_base_components):
        raise IntegratedStressError(
            "integration.concentration_base_components cannot contain empty values."
        )
    unknown_components = sorted(set(concentration_base_components) - set(ATOMIC_COMPONENT_COLUMNS))
    if unknown_components:
        raise IntegratedStressError(
            f"Concentration adjustment contains unsupported component columns: {unknown_components}"
        )
    if len(set(concentration_base_components)) != len(concentration_base_components):
        raise IntegratedStressError("Concentration base component names must be unique.")

    raw_scenarios = config.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise IntegratedStressError("scenarios must be a nonempty list.")
    scenarios = tuple(
        sorted(
            (
                _load_scenario(_mapping(raw, "scenario"))
                for raw in raw_scenarios
                if bool(_mapping(raw, "scenario").get("enabled", True))
            ),
            key=lambda item: item.severity_rank,
        )
    )
    if not scenarios:
        raise IntegratedStressError("At least one enabled scenario is required.")
    if len({item.name for item in scenarios}) != len(scenarios):
        raise IntegratedStressError("Scenario names must be unique.")
    if len({item.severity_rank for item in scenarios}) != len(scenarios):
        raise IntegratedStressError("Scenario severity ranks must be unique.")

    settings = IntegratedStressSettings(
        model_version=str(config.get("model_version", "section-19-v1")).strip(),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        lcr_minimum_ratio=_number(integration, "lcr_minimum_ratio"),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
        concentration_base_components=concentration_base_components,
        scenarios=scenarios,
    )
    if not settings.model_version:
        raise IntegratedStressError("model_version must be populated.")
    if settings.tolerance_usd < 0.0:
        raise IntegratedStressError("reconciliation_tolerance_usd must be nonnegative.")
    if settings.lcr_minimum_ratio <= 0.0:
        raise IntegratedStressError("lcr_minimum_ratio must be positive.")

    previous: IntegratedScenario | None = None
    for scenario in scenarios:
        if previous is not None:
            if scenario.concentration_multiplier < previous.concentration_multiplier:
                raise IntegratedStressError(
                    "concentration_multiplier must be nondecreasing by severity."
                )
            if (
                scenario.operational_liquidity_buffer_rate
                < previous.operational_liquidity_buffer_rate
            ):
                raise IntegratedStressError(
                    "operational_liquidity_buffer_rate must be nondecreasing by severity."
                )
            if scenario.concentration_threshold > previous.concentration_threshold:
                raise IntegratedStressError(
                    "concentration_threshold cannot increase with severity."
                )
        previous = scenario
    return settings


def read_table(path: str | Path) -> pd.DataFrame:
    """Read a CSV or Parquet input table."""
    table_path = Path(path)
    if not table_path.exists():
        raise IntegratedStressError(f"Input table does not exist: {table_path}")
    if table_path.suffix.lower() == ".csv":
        return pd.read_csv(table_path)
    if table_path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(table_path)
    raise IntegratedStressError("Input tables must be CSV or Parquet.")


def dataframe_digest(frame: pd.DataFrame) -> str:
    """Return a deterministic SHA-256 digest independent of row order."""
    ordered = frame.sort_index(axis=1)
    sort_columns = [
        column
        for column in ("severity_rank", "scenario_name", "member_id")
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _require_columns(
    frame: pd.DataFrame,
    required: set[str],
    label: str,
) -> None:
    missing = sorted(required - set(frame.columns))
    if missing:
        raise IntegratedStressError(f"{label} is missing required fields: {missing}")


def _validate_identity(
    frame: pd.DataFrame,
    synthetic_id_pattern: str,
    label: str,
) -> None:
    if "member_id" not in frame.columns:
        raise IntegratedStressError(f"{label} requires member_id.")
    member_ids = frame["member_id"].astype("string").str.strip()
    if member_ids.isna().any() or (member_ids == "").any():
        raise IntegratedStressError(f"{label} contains missing member identifiers.")
    invalid = [
        member_id
        for member_id in member_ids.astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise IntegratedStressError(
            f"{label} contains non-synthetic identifiers: {sorted(set(invalid))}"
        )
    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise IntegratedStressError(f"{label} contains prohibited actual-participant records.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise IntegratedStressError(f"{label} contains prohibited participant-level inference.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise IntegratedStressError(f"{label} requires value_class='synthetic' for every record.")


def _numeric(
    frame: pd.DataFrame,
    columns: list[str],
    *,
    nonnegative: bool,
    label: str,
) -> None:
    for column in columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        finite = frame[column].map(math.isfinite)
        if frame[column].isna().any() or not bool(finite.all()):
            raise IntegratedStressError(f"{label}.{column} contains missing or nonfinite values.")
        if nonnegative and bool((frame[column] < 0.0).any()):
            raise IntegratedStressError(f"{label}.{column} must be nonnegative.")


def prepare_baseline_summary(
    baseline: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate and canonicalize Section 14 member-level baseline data."""
    if baseline.empty:
        raise IntegratedStressError("Section 14 baseline summary is empty.")
    required = {
        "member_id",
        "net_settlement_outflow_usd",
        "modeled_aqlr_usd",
    }
    _require_columns(baseline, required, "Section 14 baseline summary")
    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 14 baseline summary")
    if bool(frame["member_id"].duplicated().any()):
        raise IntegratedStressError("Section 14 baseline summary must be unique by member_id.")
    _numeric(
        frame,
        ["net_settlement_outflow_usd", "modeled_aqlr_usd"],
        nonnegative=True,
        label="Section 14 baseline summary",
    )
    selected = frame[["member_id", "net_settlement_outflow_usd", "modeled_aqlr_usd"]].rename(
        columns={
            "net_settlement_outflow_usd": "settlement_liquidity_need_usd",
            "modeled_aqlr_usd": "available_qualified_liquid_resources_usd",
        }
    )
    return selected.sort_values("member_id", kind="stable").reset_index(drop=True)


def prepare_funding_summary(
    funding: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate atomic Section 16 funding-stress components."""
    if funding.empty:
        raise IntegratedStressError("Section 16 funding summary is empty.")
    required = {
        "scenario_name",
        "member_id",
        "repo_rollover_failure_outflow_usd",
        "incremental_funding_cost_usd",
        "member_concentration_ratio",
    }
    _require_columns(funding, required, "Section 16 funding summary")
    frame = funding.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 16 funding summary")
    if bool(frame.duplicated(["scenario_name", "member_id"]).any()):
        raise IntegratedStressError(
            "Section 16 funding summary must be unique by scenario and member."
        )
    optional = {
        "additional_collateral_demand_usd": 0.0,
        "incremental_repo_funding_stress_outflow_usd": np.nan,
    }
    for column, default in optional.items():
        if column not in frame.columns:
            frame[column] = default
    numeric_columns = [
        "repo_rollover_failure_outflow_usd",
        "incremental_funding_cost_usd",
        "member_concentration_ratio",
        "additional_collateral_demand_usd",
    ]
    _numeric(
        frame,
        numeric_columns,
        nonnegative=True,
        label="Section 16 funding summary",
    )
    if bool((frame["member_concentration_ratio"] > 1.0).any()):
        raise IntegratedStressError("Section 16 member_concentration_ratio must not exceed one.")
    if frame["incremental_repo_funding_stress_outflow_usd"].isna().all():
        frame["incremental_repo_funding_stress_outflow_usd"] = (
            frame["repo_rollover_failure_outflow_usd"]
            + frame["incremental_funding_cost_usd"]
            + frame["additional_collateral_demand_usd"]
        )
    _numeric(
        frame,
        ["incremental_repo_funding_stress_outflow_usd"],
        nonnegative=True,
        label="Section 16 funding summary",
    )
    return frame.sort_values(["scenario_name", "member_id"], kind="stable").reset_index(drop=True)


def prepare_haircut_summary(
    haircut: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate Section 17 additional-collateral requirements."""
    if haircut.empty:
        raise IntegratedStressError("Section 17 haircut summary is empty.")
    required = {
        "scenario_name",
        "member_id",
        "additional_collateral_requirement_total_usd",
    }
    _require_columns(haircut, required, "Section 17 haircut summary")
    frame = haircut.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 17 haircut summary")
    if bool(frame.duplicated(["scenario_name", "member_id"]).any()):
        raise IntegratedStressError(
            "Section 17 haircut summary must be unique by scenario and member."
        )
    for column in (
        "bucket_qualified_resource_reduction_usd",
        "stressed_member_qualified_resources_usd",
    ):
        if column not in frame.columns:
            frame[column] = 0.0
    _numeric(
        frame,
        [
            "additional_collateral_requirement_total_usd",
            "bucket_qualified_resource_reduction_usd",
            "stressed_member_qualified_resources_usd",
        ],
        nonnegative=True,
        label="Section 17 haircut summary",
    )
    return frame.sort_values(["scenario_name", "member_id"], kind="stable").reset_index(drop=True)


def prepare_treasury_summary(
    treasury: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Validate Section 15 member-level Treasury losses."""
    if treasury.empty:
        raise IntegratedStressError("Section 15 Treasury summary is empty.")
    required = {"scenario_name", "member_id", "treasury_loss_usd"}
    _require_columns(treasury, required, "Section 15 Treasury summary")
    frame = treasury.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern, "Section 15 Treasury summary")
    if bool(frame.duplicated(["scenario_name", "member_id"]).any()):
        raise IntegratedStressError(
            "Section 15 Treasury summary must be unique by scenario and member."
        )
    _numeric(
        frame,
        ["treasury_loss_usd"],
        nonnegative=True,
        label="Section 15 Treasury summary",
    )
    return frame.sort_values(["scenario_name", "member_id"], kind="stable").reset_index(drop=True)


def prepare_settlement_fail_summary(
    settlement_fail: pd.DataFrame,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    """Aggregate Section 18 settlement-only stress while excluding funding composites."""
    if settlement_fail.empty:
        raise IntegratedStressError("Section 18 settlement-fail cash flows are empty.")
    required = {
        "scenario_name",
        "member_id",
        "incremental_settlement_fail_outflow_usd",
    }
    _require_columns(settlement_fail, required, "Section 18 settlement-fail cash flows")
    frame = settlement_fail.copy(deep=True)
    frame["scenario_name"] = frame["scenario_name"].astype("string").str.strip()
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(
        frame, settings.synthetic_id_pattern, "Section 18 settlement-fail cash flows"
    )
    if "time_bucket" in frame.columns and bool(
        frame.duplicated(["scenario_name", "member_id", "time_bucket"]).any()
    ):
        raise IntegratedStressError(
            "Section 18 scenario, member, and time-bucket keys must be unique."
        )
    optional = {
        "combined_funding_shock_outflow_usd": 0.0,
        "incremental_combined_stress_outflow_usd": np.nan,
    }
    for column, default in optional.items():
        if column not in frame.columns:
            frame[column] = default
    _numeric(
        frame,
        [
            "incremental_settlement_fail_outflow_usd",
            "combined_funding_shock_outflow_usd",
        ],
        nonnegative=True,
        label="Section 18 settlement-fail cash flows",
    )
    if frame["incremental_combined_stress_outflow_usd"].isna().all():
        frame["incremental_combined_stress_outflow_usd"] = (
            frame["incremental_settlement_fail_outflow_usd"]
            + frame["combined_funding_shock_outflow_usd"]
        )
    _numeric(
        frame,
        ["incremental_combined_stress_outflow_usd"],
        nonnegative=True,
        label="Section 18 settlement-fail cash flows",
    )
    summary = (
        frame.groupby(["scenario_name", "member_id"], as_index=False, sort=True)
        .agg(
            incremental_settlement_fail_outflow_usd=(
                "incremental_settlement_fail_outflow_usd",
                "sum",
            ),
            combined_funding_shock_outflow_usd=(
                "combined_funding_shock_outflow_usd",
                "sum",
            ),
            incremental_combined_stress_outflow_usd=(
                "incremental_combined_stress_outflow_usd",
                "sum",
            ),
        )
        .reset_index(drop=True)
    )
    return summary


def _select_scenario(
    frame: pd.DataFrame,
    scenario_name: str,
    label: str,
) -> pd.DataFrame:
    selected = frame.loc[frame["scenario_name"].astype(str).eq(scenario_name)].copy()
    if selected.empty:
        raise IntegratedStressError(f"{label} scenario was not found: {scenario_name}")
    return selected


def _merge_component(
    base: pd.DataFrame,
    component: pd.DataFrame,
    columns: list[str],
    label: str,
) -> pd.DataFrame:
    selected = component[["member_id", *columns]]
    merged = base.merge(selected, on="member_id", how="left", validate="one_to_one")
    if bool(merged[columns].isna().any().any()):
        missing_members = sorted(
            merged.loc[merged[columns].isna().any(axis=1), "member_id"].astype(str)
        )
        raise IntegratedStressError(f"{label} is missing mapped members: {missing_members}")
    return merged


def _scenario_member_results(
    baseline: pd.DataFrame,
    funding: pd.DataFrame,
    haircut: pd.DataFrame,
    treasury: pd.DataFrame,
    settlement_fail: pd.DataFrame,
    scenario: IntegratedScenario,
    settings: IntegratedStressSettings,
) -> pd.DataFrame:
    frame = baseline.copy(deep=True)

    funding_selected = _select_scenario(
        funding, scenario.funding_scenario_name, "Section 16 funding"
    ).rename(
        columns={
            "repo_rollover_failure_outflow_usd": "repo_rollover_need_usd",
            "additional_collateral_demand_usd": (
                "excluded_section16_additional_collateral_demand_usd"
            ),
            "incremental_repo_funding_stress_outflow_usd": (
                "excluded_section16_composite_outflow_usd"
            ),
        }
    )
    frame = _merge_component(
        frame,
        funding_selected,
        [
            "repo_rollover_need_usd",
            "incremental_funding_cost_usd",
            "member_concentration_ratio",
            "excluded_section16_additional_collateral_demand_usd",
            "excluded_section16_composite_outflow_usd",
        ],
        "Section 16 funding",
    )

    haircut_selected = _select_scenario(
        haircut, scenario.haircut_scenario_name, "Section 17 haircut"
    ).rename(
        columns={
            "additional_collateral_requirement_total_usd": ("additional_haircut_requirement_usd"),
            "bucket_qualified_resource_reduction_usd": ("excluded_section17_aqlr_reduction_usd"),
        }
    )
    frame = _merge_component(
        frame,
        haircut_selected,
        [
            "additional_haircut_requirement_usd",
            "excluded_section17_aqlr_reduction_usd",
        ],
        "Section 17 haircut",
    )

    if scenario.treasury_scenario_name.upper() == "NONE":
        frame["treasury_liquidation_loss_usd"] = 0.0
    else:
        treasury_selected = _select_scenario(
            treasury, scenario.treasury_scenario_name, "Section 15 Treasury"
        ).rename(columns={"treasury_loss_usd": "treasury_liquidation_loss_usd"})
        frame = _merge_component(
            frame,
            treasury_selected,
            ["treasury_liquidation_loss_usd"],
            "Section 15 Treasury",
        )

    settlement_selected = _select_scenario(
        settlement_fail,
        scenario.settlement_fail_scenario_name,
        "Section 18 settlement-fail",
    ).rename(
        columns={
            "incremental_settlement_fail_outflow_usd": ("settlement_fail_requirement_usd"),
            "combined_funding_shock_outflow_usd": ("excluded_section18_funding_shock_usd"),
            "incremental_combined_stress_outflow_usd": ("excluded_section18_composite_outflow_usd"),
        }
    )
    frame = _merge_component(
        frame,
        settlement_selected,
        [
            "settlement_fail_requirement_usd",
            "excluded_section18_funding_shock_usd",
            "excluded_section18_composite_outflow_usd",
        ],
        "Section 18 settlement-fail",
    )

    concentration_base = pd.Series(0.0, index=frame.index, dtype=float)
    for column in settings.concentration_base_components:
        concentration_base = concentration_base + frame[column].astype(float)
    frame["concentration_base_usd"] = concentration_base
    frame["concentration_excess_ratio"] = (
        frame["member_concentration_ratio"] - scenario.concentration_threshold
    ).clip(lower=0.0)
    frame["concentration_adjustment_usd"] = (
        frame["concentration_base_usd"]
        * frame["concentration_excess_ratio"]
        * scenario.concentration_multiplier
    )

    frame["pre_buffer_stressed_liquidity_requirement_usd"] = frame[
        [
            *ATOMIC_COMPONENT_COLUMNS,
            "concentration_adjustment_usd",
        ]
    ].sum(axis=1)
    frame["operational_liquidity_buffer_usd"] = (
        frame["pre_buffer_stressed_liquidity_requirement_usd"]
        * scenario.operational_liquidity_buffer_rate
    )
    frame["stressed_liquidity_requirement_usd"] = (
        frame["pre_buffer_stressed_liquidity_requirement_usd"]
        + frame["operational_liquidity_buffer_usd"]
    )
    requirement = frame["stressed_liquidity_requirement_usd"].astype(float)
    resources = frame["available_qualified_liquid_resources_usd"].astype(float)
    frame["liquidity_coverage_ratio"] = np.where(
        requirement > settings.tolerance_usd,
        resources / requirement,
        np.inf,
    )
    frame["liquidity_headroom_usd"] = resources - requirement
    frame["liquidity_shortfall_usd"] = (-frame["liquidity_headroom_usd"]).clip(lower=0.0)
    frame["lcr_status"] = np.where(
        requirement <= settings.tolerance_usd,
        "NO_REQUIREMENT",
        np.where(
            frame["liquidity_coverage_ratio"] >= settings.lcr_minimum_ratio,
            "PASS",
            "BREACH",
        ),
    )

    frame["section16_composite_identity_difference_usd"] = (
        frame["excluded_section16_composite_outflow_usd"]
        - frame["repo_rollover_need_usd"]
        - frame["incremental_funding_cost_usd"]
        - frame["excluded_section16_additional_collateral_demand_usd"]
    )
    frame["section18_composite_identity_difference_usd"] = (
        frame["excluded_section18_composite_outflow_usd"]
        - frame["settlement_fail_requirement_usd"]
        - frame["excluded_section18_funding_shock_usd"]
    )
    frame["double_count_control_pass"] = frame[
        "section16_composite_identity_difference_usd"
    ].abs().le(settings.tolerance_usd) & frame[
        "section18_composite_identity_difference_usd"
    ].abs().le(settings.tolerance_usd)
    frame["excluded_overlapping_candidate_amount_usd"] = (
        frame["excluded_section16_additional_collateral_demand_usd"]
        + frame["excluded_section18_funding_shock_usd"]
        + frame["excluded_section17_aqlr_reduction_usd"]
    )

    frame["scenario_name"] = scenario.name
    frame["severity_rank"] = scenario.severity_rank
    frame["funding_scenario_name"] = scenario.funding_scenario_name
    frame["haircut_scenario_name"] = scenario.haircut_scenario_name
    frame["treasury_scenario_name"] = scenario.treasury_scenario_name
    frame["settlement_fail_scenario_name"] = scenario.settlement_fail_scenario_name
    frame["concentration_threshold"] = scenario.concentration_threshold
    frame["concentration_multiplier"] = scenario.concentration_multiplier
    frame["operational_liquidity_buffer_rate"] = scenario.operational_liquidity_buffer_rate
    frame["lcr_minimum_ratio"] = settings.lcr_minimum_ratio
    frame["model_version"] = settings.model_version
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values("member_id", kind="stable").reset_index(drop=True)


def build_scenario_summary(member_results: pd.DataFrame) -> pd.DataFrame:
    """Aggregate member-level integrated requirements by scenario."""
    rows: list[dict[str, object]] = []
    for (scenario_name, severity_rank), group in member_results.groupby(
        ["scenario_name", "severity_rank"], sort=True
    ):
        total_requirement = float(group["stressed_liquidity_requirement_usd"].sum())
        total_resources = float(group["available_qualified_liquid_resources_usd"].sum())
        aggregate_lcr = total_resources / total_requirement if total_requirement > 0.0 else math.inf
        row: dict[str, object] = {
            "scenario_name": str(scenario_name),
            "severity_rank": int(cast(Any, severity_rank)),
            "member_count": int(group["member_id"].nunique()),
        }
        for column in REQUIRED_COMPONENT_COLUMNS:
            row[f"total_{column}"] = float(group[column].sum())
        row.update(
            {
                "total_stressed_liquidity_requirement_usd": total_requirement,
                "total_available_qualified_liquid_resources_usd": total_resources,
                "aggregate_liquidity_coverage_ratio": aggregate_lcr,
                "minimum_member_liquidity_coverage_ratio": float(
                    group["liquidity_coverage_ratio"].min()
                ),
                "breach_member_count": int((group["lcr_status"] == "BREACH").sum()),
                "double_count_control_failures": int((~group["double_count_control_pass"]).sum()),
                "scenario_status": (
                    "PASS"
                    if bool((group["lcr_status"].isin(["PASS", "NO_REQUIREMENT"])).all())
                    else "BREACH"
                ),
                "model_version": str(group["model_version"].iloc[0]),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
        rows.append(row)
    return (
        pd.DataFrame.from_records(rows)
        .sort_values("severity_rank", kind="stable")
        .reset_index(drop=True)
    )


def build_double_count_controls(member_results: pd.DataFrame) -> pd.DataFrame:
    """Return the auditable component-selection and overlap-control table."""
    columns = [
        "scenario_name",
        "severity_rank",
        "member_id",
        "funding_scenario_name",
        "haircut_scenario_name",
        "treasury_scenario_name",
        "settlement_fail_scenario_name",
        "repo_rollover_need_usd",
        "incremental_funding_cost_usd",
        "additional_haircut_requirement_usd",
        "settlement_fail_requirement_usd",
        "excluded_section16_additional_collateral_demand_usd",
        "excluded_section16_composite_outflow_usd",
        "excluded_section18_funding_shock_usd",
        "excluded_section18_composite_outflow_usd",
        "excluded_section17_aqlr_reduction_usd",
        "excluded_overlapping_candidate_amount_usd",
        "section16_composite_identity_difference_usd",
        "section18_composite_identity_difference_usd",
        "double_count_control_pass",
        "model_version",
        "value_class",
        "actual_ficc_participant",
        "participant_level_inference",
    ]
    return member_results[columns].copy()


def validate_results(
    member_results: pd.DataFrame,
    scenario_summary: pd.DataFrame,
    double_count_controls: pd.DataFrame,
    baseline_member_count: int,
    settings: IntegratedStressSettings,
) -> dict[str, bool]:
    """Validate Section 19 accounting identities and no-double-counting controls."""
    expected_rows = baseline_member_count * len(settings.scenarios)
    numeric_columns = [
        *REQUIRED_COMPONENT_COLUMNS,
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        "liquidity_shortfall_usd",
    ]
    finite = (
        member_results[numeric_columns].apply(lambda column: column.map(math.isfinite).all()).all()
    )
    nonnegative = bool((member_results[numeric_columns] >= 0.0).all().all())
    expected_requirement = member_results[
        [
            *ATOMIC_COMPONENT_COLUMNS,
            "concentration_adjustment_usd",
            "operational_liquidity_buffer_usd",
        ]
    ].sum(axis=1)
    requirement_identity = bool(
        (expected_requirement - member_results["stressed_liquidity_requirement_usd"])
        .abs()
        .le(settings.tolerance_usd)
        .all()
    )
    positive_requirement = (
        member_results["stressed_liquidity_requirement_usd"] > settings.tolerance_usd
    )
    expected_lcr = (
        member_results.loc[positive_requirement, "available_qualified_liquid_resources_usd"]
        / member_results.loc[positive_requirement, "stressed_liquidity_requirement_usd"]
    )
    lcr_identity = bool(
        (expected_lcr - member_results.loc[positive_requirement, "liquidity_coverage_ratio"])
        .abs()
        .le(1e-12)
        .all()
    )
    zero_requirement_lcr = bool(
        np.isinf(
            member_results.loc[~positive_requirement, "liquidity_coverage_ratio"].to_numpy(
                dtype=float
            )
        ).all()
    )
    aggregate_monotonic = bool(
        scenario_summary.sort_values("severity_rank")[
            "total_stressed_liquidity_requirement_usd"
        ].is_monotonic_increasing
    )
    expected_status = np.where(
        ~positive_requirement,
        "NO_REQUIREMENT",
        np.where(
            member_results["liquidity_coverage_ratio"] >= settings.lcr_minimum_ratio,
            "PASS",
            "BREACH",
        ),
    )
    status_identity = bool(
        (member_results["lcr_status"].astype(str).to_numpy() == expected_status).all()
    )
    no_actual_participants = bool(
        not member_results["actual_ficc_participant"].astype(bool).any()
        and not member_results["participant_level_inference"].astype(bool).any()
    )
    scenario_rows_complete = len(scenario_summary) == len(settings.scenarios) and set(
        scenario_summary["scenario_name"]
    ) == {scenario.name for scenario in settings.scenarios}
    return {
        "expected_member_scenario_rows": len(member_results) == expected_rows,
        "unique_member_scenario_keys": not bool(
            member_results.duplicated(["scenario_name", "member_id"]).any()
        ),
        "finite_required_outputs": bool(finite),
        "nonnegative_required_outputs": nonnegative,
        "stressed_requirement_identity": requirement_identity,
        "lcr_identity": lcr_identity,
        "zero_requirement_lcr_convention": zero_requirement_lcr,
        "lcr_status_identity": status_identity,
        "double_count_controls_pass": bool(
            double_count_controls["double_count_control_pass"].all()
        ),
        "scenario_summary_complete": scenario_rows_complete,
        "aggregate_requirement_nondecreasing": aggregate_monotonic,
        "synthetic_only": no_actual_participants,
    }


def run_integrated_stress(
    baseline_summary: pd.DataFrame,
    funding_summary: pd.DataFrame,
    haircut_summary: pd.DataFrame,
    treasury_summary: pd.DataFrame,
    settlement_fail_cashflows: pd.DataFrame,
    config: Mapping[str, Any],
) -> IntegratedStressResult:
    """Run the controlled Section 19 integrated stress engine."""
    settings = load_settings(config)
    baseline = prepare_baseline_summary(baseline_summary, settings)
    funding = prepare_funding_summary(funding_summary, settings)
    haircut = prepare_haircut_summary(haircut_summary, settings)
    treasury = prepare_treasury_summary(treasury_summary, settings)
    settlement_fail = prepare_settlement_fail_summary(settlement_fail_cashflows, settings)
    outputs = [
        _scenario_member_results(
            baseline,
            funding,
            haircut,
            treasury,
            settlement_fail,
            scenario,
            settings,
        )
        for scenario in settings.scenarios
    ]
    member_results = pd.concat(outputs, ignore_index=True).sort_values(
        ["severity_rank", "member_id"], kind="stable"
    )
    member_results = member_results.reset_index(drop=True)
    scenario_summary = build_scenario_summary(member_results)
    double_count_controls = build_double_count_controls(member_results)
    checks = validate_results(
        member_results,
        scenario_summary,
        double_count_controls,
        baseline_member_count=len(baseline),
        settings=settings,
    )
    return IntegratedStressResult(
        member_results=member_results,
        scenario_summary=scenario_summary,
        double_count_controls=double_count_controls,
        checks=checks,
    )
'@

$RunnerContent = @'
"""Run Phase V, Section 19 integrated stressed-liquidity requirements."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from copy import deepcopy
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.stress.integrated_stress import (  # noqa: E402
    IntegratedStressError,
    dataframe_digest,
    load_config,
    load_settings,
    read_table,
    run_integrated_stress,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    StressRunResult,
    TreasuryYieldShockModel,
    load_stress_config,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled Section 19 command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Run Phase V Section 19 integrated stressed-liquidity requirements."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "integrated_stress_engine.yaml",
    )
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--funding", type=Path, default=None)
    parser.add_argument("--haircut", type=Path, default=None)
    parser.add_argument("--treasury", type=Path, default=None)
    parser.add_argument("--settlement-fail", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "reports" / "tables",
    )
    parser.add_argument(
        "--evidence-dir",
        type=Path,
        default=ROOT / "reports" / "evidence",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT / "data" / "manifests" / "integrated_stress_engine_manifest.csv",
    )
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise IntegratedStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing controlled input candidate."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _candidate_list(source: dict[str, Any], key: str) -> list[str]:
    raw = source.get(key)
    if not isinstance(raw, list) or not raw:
        raise IntegratedStressError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def _required_input(
    supplied: Path | None,
    root: Path,
    source: dict[str, Any],
    key: str,
    label: str,
) -> Path:
    path = supplied or discover_input(root, _candidate_list(source, key))
    if path is None:
        raise IntegratedStressError(
            f"{label} was not found. Supply the corresponding command-line input."
        )
    return path


def file_hash(path: Path) -> str:
    """Return a file SHA-256 digest."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_frame(
    frame: pd.DataFrame,
    stem: Path,
    *,
    write_csv: bool,
    write_parquet: bool,
) -> list[Path]:
    """Write a controlled result frame."""
    written: list[Path] = []
    if write_csv:
        csv_path = stem.with_suffix(".csv")
        frame.to_csv(csv_path, index=False)
        written.append(csv_path)
    if write_parquet:
        parquet_path = stem.with_suffix(".parquet")
        try:
            frame.to_parquet(parquet_path, index=False)
            written.append(parquet_path)
        except (ImportError, ModuleNotFoundError, ValueError) as exc:
            print(f"Parquet output skipped: {exc}")
    return written


def _treasury_mapping(config: dict[str, Any]) -> list[dict[str, Any]]:
    adapter = _mapping(config.get("treasury_adapter"), "treasury_adapter")
    raw = adapter.get("maturity_mapping")
    if not isinstance(raw, list) or not raw:
        raise IntegratedStressError(
            "treasury_adapter.maturity_mapping must be a nonempty list."
        )
    mappings = [_mapping(item, "treasury maturity mapping") for item in raw]
    weight_sums: dict[str, float] = {}
    for mapping in mappings:
        source_column = str(mapping.get("source_column", "")).strip()
        target_bucket = str(mapping.get("target_bucket", "")).strip()
        weight_raw = mapping.get("weight")
        if (
            not source_column
            or not target_bucket
            or isinstance(weight_raw, bool)
            or not isinstance(weight_raw, (int, float))
        ):
            raise IntegratedStressError(
                "Every Treasury adapter mapping requires source_column, "
                "target_bucket, and numeric weight."
            )
        weight = float(weight_raw)
        if not math.isfinite(weight) or weight <= 0.0:
            raise IntegratedStressError(
                "Treasury adapter mapping weights must be finite and positive."
            )
        weight_sums[source_column] = weight_sums.get(source_column, 0.0) + weight
    invalid = {
        source_column: weight
        for source_column, weight in weight_sums.items()
        if not math.isclose(weight, 1.0, abs_tol=1e-12)
    }
    if invalid:
        raise IntegratedStressError(
            "Treasury adapter weights must sum to one for each source column: "
            f"{invalid}"
        )
    return mappings


def build_treasury_adapter_positions(
    profiles: pd.DataFrame,
    config: dict[str, Any],
    synthetic_id_pattern: str,
) -> pd.DataFrame:
    """Bridge Section 12 maturity buckets to the validated Section 15 model."""
    if profiles.empty:
        raise IntegratedStressError("Synthetic member profiles are empty.")
    mappings = _treasury_mapping(config)
    required_columns = {
        "member_id",
        *(str(mapping["source_column"]) for mapping in mappings),
    }
    missing = sorted(required_columns - set(profiles.columns))
    if missing:
        raise IntegratedStressError(
            f"Synthetic profiles are missing Treasury adapter fields: {missing}"
        )
    frame = profiles.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    invalid_ids = [
        member_id
        for member_id in frame["member_id"].astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid_ids:
        raise IntegratedStressError(
            "Treasury adapter received invalid synthetic identifiers: "
            f"{sorted(set(invalid_ids))}"
        )
    source_columns = sorted(
        {str(mapping["source_column"]) for mapping in mappings}
    )
    for column in source_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or bool((frame[column] < 0.0).any()):
            raise IntegratedStressError(
                f"Treasury adapter field {column} must be finite and nonnegative."
            )
    records: list[dict[str, object]] = []
    as_of_column = "as_of_date" if "as_of_date" in frame.columns else None
    for _, row in frame.iterrows():
        for mapping in mappings:
            source_column = str(mapping["source_column"])
            records.append(
                {
                    "member_id": str(row["member_id"]),
                    "as_of_date": (
                        row[as_of_column] if as_of_column is not None else pd.NaT
                    ),
                    "maturity_bucket": str(mapping["target_bucket"]),
                    "market_value_usd": float(row[source_column])
                    * float(mapping["weight"]),
                    "valuation_source": (
                        f"section19_bucket_bridge:{source_column}"
                    ),
                }
            )
    positions = pd.DataFrame.from_records(records)
    if positions.empty:
        raise IntegratedStressError(
            "Treasury adapter produced no synthetic position records."
        )
    return positions


def build_treasury_adapter_summary(
    profiles: pd.DataFrame,
    config: dict[str, Any],
    required_scenarios: set[str],
    synthetic_id_pattern: str,
    root: Path,
) -> tuple[pd.DataFrame, StressRunResult]:
    """Run the validated Section 15 model on a controlled Section 12 bucket bridge."""
    source = _mapping(config.get("source"), "source")
    config_path = root / str(
        source.get("treasury_yield_config", "configs/treasury_yield_stress.yaml")
    )
    treasury_config = deepcopy(load_stress_config(config_path))
    treasury_config["input"]["required_member_id_pattern"] = synthetic_id_pattern
    positions = build_treasury_adapter_positions(
        profiles, config, synthetic_id_pattern
    )
    configured_scenarios = {
        str(scenario.get("name")): scenario
        for scenario in treasury_config["scenarios"]
        if bool(scenario.get("enabled", True))
    }
    missing = sorted(required_scenarios - set(configured_scenarios))
    if missing:
        raise IntegratedStressError(
            f"Section 15 configuration lacks mapped Treasury scenarios: {missing}"
        )
    selected = [configured_scenarios[name] for name in sorted(required_scenarios)]
    stress_result = TreasuryYieldShockModel(treasury_config).run(
        positions, scenarios=selected
    )
    summary = stress_result.member_summary.copy(deep=True)
    summary["value_class"] = "synthetic"
    summary["actual_ficc_participant"] = False
    summary["participant_level_inference"] = False
    return summary, stress_result


def treasury_summary_is_compatible(
    treasury: pd.DataFrame,
    required_scenarios: set[str],
    synthetic_id_pattern: str,
) -> bool:
    """Return whether an existing Section 15 summary can be joined safely."""
    required = {"scenario_name", "member_id", "treasury_loss_usd"}
    if treasury.empty or not required.issubset(treasury.columns):
        return False
    if not required_scenarios.issubset(set(treasury["scenario_name"].astype(str))):
        return False
    return bool(
        treasury["member_id"]
        .astype(str)
        .map(lambda value: re.fullmatch(synthetic_id_pattern, value) is not None)
        .all()
    )


def write_manifest(
    manifest_path: Path,
    files: list[tuple[Path, str, int | None]],
) -> None:
    """Write source-lineage and output-integrity metadata."""
    generated_at = datetime.now(UTC).isoformat()
    records = [
        {
            "section": 19,
            "artifact_path": str(path.resolve()),
            "artifact_name": path.name,
            "value_class": value_class,
            "row_count": row_count if row_count is not None else "",
            "sha256": file_hash(path),
            "generated_at_utc": generated_at,
            "actual_ficc_participant": False,
            "participant_level_inference": False,
        }
        for path, value_class, row_count in files
    ]
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(records).to_csv(manifest_path, index=False)


def _json_records(frame: pd.DataFrame) -> list[dict[str, object]]:
    safe = frame.replace([math.inf, -math.inf], None)
    return cast(list[dict[str, object]], safe.to_dict(orient="records"))


def _write_evidence_markdown(
    path: Path,
    evidence: dict[str, object],
    scenario_summary: pd.DataFrame,
) -> None:
    checks = cast(dict[str, bool], evidence["checks"])
    lines = [
        "# Section 19 — Integrated Stressed Liquidity Requirement",
        "",
        f"- Generated at: `{evidence['generated_at_utc']}`",
        f"- Run type: `{evidence['run_type']}`",
        f"- Model version: `{evidence['model_version']}`",
        f"- Deterministic reproduction: `{evidence['deterministic_reproduction']}`",
        f"- Final decision: `{evidence['final_decision']}`",
        "",
        "## Validation gates",
        "",
        "| Gate | Result |",
        "|---|---|",
    ]
    lines.extend(
        f"| {name.replace('_', ' ')} | {'PASS' if passed else 'FAIL'} |"
        for name, passed in checks.items()
    )
    lines.extend(
        [
            "",
            "## Scenario results",
            "",
            "| Scenario | Requirement (USD) | AQLR (USD) | LCR | Breach members |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    for _, row in scenario_summary.sort_values("severity_rank").iterrows():
        lines.append(
            "| {scenario} | {requirement:,.2f} | {resources:,.2f} | "
            "{lcr:.6f} | {breaches} |".format(
                scenario=row["scenario_name"],
                requirement=float(
                    row["total_stressed_liquidity_requirement_usd"]
                ),
                resources=float(
                    row["total_available_qualified_liquid_resources_usd"]
                ),
                lcr=float(row["aggregate_liquidity_coverage_ratio"]),
                breaches=int(row["breach_member_count"]),
            )
        )
    lines.extend(
        [
            "",
            "## No-double-counting disposition",
            "",
            "The engine selects atomic Section 16 repo-rollover and funding-cost "
            "components instead of the Section 16 composite outflow. It selects "
            "the Section 18 settlement-only requirement instead of the Section 18 "
            "combined settlement-and-funding outflow. It uses the Section 14 "
            "modeled AQLR numerator rather than the Section 17 stressed AQLR field, "
            "because the Section 17 field already subtracts posted collateral and "
            "would duplicate the separately included haircut requirement.",
            "",
            "All member records are fictional synthetic observations. No output "
            "identifies or infers an actual FICC participant.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    """Execute the controlled Section 19 workflow."""
    args = parse_args()
    config = load_config(args.config)
    settings = load_settings(config)
    source = _mapping(config.get("source"), "source")
    output = _mapping(config.get("output"), "output")

    baseline_path = _required_input(
        args.baseline,
        ROOT,
        source,
        "baseline_summary_candidates",
        "Section 14 baseline summary",
    )
    funding_path = _required_input(
        args.funding,
        ROOT,
        source,
        "funding_summary_candidates",
        "Section 16 funding summary",
    )
    haircut_path = _required_input(
        args.haircut,
        ROOT,
        source,
        "haircut_summary_candidates",
        "Section 17 haircut summary",
    )
    settlement_path = _required_input(
        args.settlement_fail,
        ROOT,
        source,
        "settlement_fail_cashflow_candidates",
        "Section 18 settlement-fail cash flows",
    )

    baseline = read_table(baseline_path)
    funding = read_table(funding_path)
    haircut = read_table(haircut_path)
    settlement_fail = read_table(settlement_path)

    required_treasury_scenarios = {
        scenario.treasury_scenario_name
        for scenario in settings.scenarios
        if scenario.treasury_scenario_name.upper() != "NONE"
    }
    treasury_path = args.treasury or discover_input(
        ROOT, _candidate_list(source, "treasury_summary_candidates")
    )
    treasury_adapter_result: StressRunResult | None = None
    profiles_path: Path | None = None
    profiles_row_count: int | None = None
    treasury_config_path: Path | None = None
    treasury_source: str
    if treasury_path is not None:
        treasury = read_table(treasury_path)
        if treasury_summary_is_compatible(
            treasury,
            required_treasury_scenarios,
            settings.synthetic_id_pattern,
        ):
            treasury_source = str(treasury_path.resolve())
        else:
            treasury_path = None
    if treasury_path is None:
        profiles_path = _required_input(
            args.members,
            ROOT,
            source,
            "synthetic_member_profile_candidates",
            "Section 12 synthetic member profiles",
        )
        profiles = read_table(profiles_path)
        profiles_row_count = len(profiles)
        treasury_config_path = ROOT / str(
            source.get(
                "treasury_yield_config",
                "configs/treasury_yield_stress.yaml",
            )
        )
        treasury, treasury_adapter_result = build_treasury_adapter_summary(
            profiles,
            config,
            required_treasury_scenarios,
            settings.synthetic_id_pattern,
            ROOT,
        )
        treasury_source = (
            "SECTION19_CONTROLLED_ADAPTER_FROM_"
            f"{profiles_path.resolve()}"
        )

    first = run_integrated_stress(
        baseline,
        funding,
        haircut,
        treasury,
        settlement_fail,
        config,
    )
    second = run_integrated_stress(
        baseline,
        funding,
        haircut,
        treasury,
        settlement_fail,
        config,
    )
    deterministic = (
        dataframe_digest(first.member_results)
        == dataframe_digest(second.member_results)
        and dataframe_digest(first.scenario_summary)
        == dataframe_digest(second.scenario_summary)
        and dataframe_digest(first.double_count_controls)
        == dataframe_digest(second.double_count_controls)
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    write_csv = bool(output.get("write_csv", True))
    write_parquet = bool(output.get("write_parquet", True))
    suffix = "_smoke" if args.smoke else ""
    written: list[tuple[Path, str, int | None]] = []

    member_files = write_frame(
        first.member_results,
        args.output_dir / f"integrated_stress_member_results{suffix}",
        write_csv=write_csv,
        write_parquet=write_parquet,
    )
    written.extend(
        (path, "modeled", len(first.member_results)) for path in member_files
    )
    scenario_files = write_frame(
        first.scenario_summary,
        args.output_dir / f"integrated_stress_scenario_summary{suffix}",
        write_csv=write_csv,
        write_parquet=write_parquet,
    )
    written.extend(
        (path, "modeled", len(first.scenario_summary)) for path in scenario_files
    )
    control_files = write_frame(
        first.double_count_controls,
        args.output_dir / f"integrated_stress_double_count_controls{suffix}",
        write_csv=write_csv,
        write_parquet=write_parquet,
    )
    written.extend(
        (path, "modeled", len(first.double_count_controls))
        for path in control_files
    )

    if treasury_adapter_result is not None:
        adapter_files = write_frame(
            treasury,
            args.output_dir
            / f"treasury_yield_stress_member_summary_section19_adapter{suffix}",
            write_csv=write_csv,
            write_parquet=write_parquet,
        )
        written.extend(
            (path, "modeled", len(treasury)) for path in adapter_files
        )
        adapter_position_files = write_frame(
            treasury_adapter_result.positions,
            args.output_dir
            / f"treasury_yield_stress_positions_section19_adapter{suffix}",
            write_csv=write_csv,
            write_parquet=write_parquet,
        )
        written.extend(
            (path, "modeled", len(treasury_adapter_result.positions))
            for path in adapter_position_files
        )

    checks = dict(first.checks)
    checks["deterministic_reproduction"] = deterministic
    final_pass = first.passed and deterministic
    generated_at = datetime.now(UTC).isoformat()
    evidence: dict[str, object] = {
        "section": 19,
        "model": "integrated_stressed_liquidity_requirement",
        "model_version": settings.model_version,
        "generated_at_utc": generated_at,
        "run_type": "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN",
        "sources": {
            "baseline": str(baseline_path.resolve()),
            "funding": str(funding_path.resolve()),
            "haircut": str(haircut_path.resolve()),
            "treasury": treasury_source,
            "treasury_adapter_config": (
                str(treasury_config_path.resolve())
                if treasury_config_path is not None
                else ""
            ),
            "settlement_fail": str(settlement_path.resolve()),
        },
        "member_scenario_rows": len(first.member_results),
        "scenario_rows": len(first.scenario_summary),
        "double_count_control_rows": len(first.double_count_controls),
        "checks": checks,
        "deterministic_reproduction": deterministic,
        "scenario_results": _json_records(first.scenario_summary),
        "final_decision": "PASS" if final_pass else "FAIL",
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }
    evidence_json = args.evidence_dir / f"section19_integrated_stress_engine{suffix}.json"
    evidence_md = args.evidence_dir / f"section19_integrated_stress_engine{suffix}.md"
    evidence_json.write_text(
        json.dumps(evidence, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    _write_evidence_markdown(evidence_md, evidence, first.scenario_summary)
    written.extend(
        [
            (args.config, "assumed", None),
            (baseline_path, "modeled", len(baseline)),
            (funding_path, "modeled", len(funding)),
            (haircut_path, "modeled", len(haircut)),
            (settlement_path, "modeled", len(settlement_fail)),
            (evidence_json, "modeled", None),
            (evidence_md, "modeled", None),
        ]
    )
    if treasury_path is not None:
        written.append((treasury_path, "modeled", len(treasury)))
    if profiles_path is not None and profiles_row_count is not None:
        written.append((profiles_path, "synthetic", profiles_row_count))
    if treasury_config_path is not None:
        written.append((treasury_config_path, "assumed", None))
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    write_manifest(args.manifest, written)

    print("Section 19 validation gates")
    for name, passed in checks.items():
        print(f"  {'PASS' if passed else 'FAIL'}: {name}")
    print(first.scenario_summary.to_string(index=False))
    print(f"FINAL DECISION: {'PASS' if final_pass else 'FAIL'}")
    return 0 if final_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@

$TestContent = @'
from __future__ import annotations

import math
from collections.abc import Callable
from copy import deepcopy
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.stress.integrated_stress import (
    IntegratedStressError,
    IntegratedStressResult,
    build_double_count_controls,
    build_scenario_summary,
    dataframe_digest,
    load_config,
    load_settings,
    prepare_baseline_summary,
    prepare_funding_summary,
    prepare_haircut_summary,
    prepare_settlement_fail_summary,
    prepare_treasury_summary,
    read_table,
    run_integrated_stress,
    validate_results,
)


def config() -> dict[str, Any]:
    return {
        "model_version": "section-19-test",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "integration": {
            "lcr_minimum_ratio": 1.0,
            "concentration_base_components": [
                "settlement_liquidity_need_usd",
                "settlement_fail_requirement_usd",
            ],
        },
        "validation": {"reconciliation_tolerance_usd": 0.01},
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "funding_scenario_name": "funding_control",
                "haircut_scenario_name": "haircut_control",
                "treasury_scenario_name": "NONE",
                "settlement_fail_scenario_name": "settlement_control",
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "operational_liquidity_buffer_rate": 0.0,
            },
            {
                "name": "moderate",
                "enabled": True,
                "severity_rank": 1,
                "funding_scenario_name": "funding_moderate",
                "haircut_scenario_name": "haircut_moderate",
                "treasury_scenario_name": "treasury_moderate",
                "settlement_fail_scenario_name": "settlement_moderate",
                "concentration_threshold": 0.30,
                "concentration_multiplier": 0.50,
                "operational_liquidity_buffer_rate": 0.05,
            },
            {
                "name": "severe",
                "enabled": True,
                "severity_rank": 2,
                "funding_scenario_name": "funding_severe",
                "haircut_scenario_name": "haircut_severe",
                "treasury_scenario_name": "treasury_severe",
                "settlement_fail_scenario_name": "settlement_severe",
                "concentration_threshold": 0.25,
                "concentration_multiplier": 0.75,
                "operational_liquidity_buffer_rate": 0.10,
            },
        ],
    }


def baseline() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "net_settlement_outflow_usd": [100.0, 200.0],
            "modeled_aqlr_usd": [500.0, 700.0],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
        }
    )


def funding() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    values = {
        "funding_control": ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0)),
        "funding_moderate": ((20.0, 5.0, 3.0), (30.0, 7.0, 4.0)),
        "funding_severe": ((40.0, 10.0, 6.0), (60.0, 14.0, 8.0)),
    }
    for scenario_name, member_values in values.items():
        for index, (rollover, cost, collateral) in enumerate(member_values, start=1):
            rows.append(
                {
                    "scenario_name": scenario_name,
                    "member_id": f"SYN-MBR-{index:04d}",
                    "repo_rollover_failure_outflow_usd": rollover,
                    "incremental_funding_cost_usd": cost,
                    "additional_collateral_demand_usd": collateral,
                    "incremental_repo_funding_stress_outflow_usd": (rollover + cost + collateral),
                    "member_concentration_ratio": 0.40 if index == 1 else 0.60,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def haircut() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    values = {
        "haircut_control": ((0.0, 0.0), (0.0, 0.0)),
        "haircut_moderate": ((10.0, 4.0), (15.0, 6.0)),
        "haircut_severe": ((20.0, 8.0), (30.0, 12.0)),
    }
    for scenario_name, member_values in values.items():
        for index, (requirement, reduction) in enumerate(member_values, start=1):
            rows.append(
                {
                    "scenario_name": scenario_name,
                    "member_id": f"SYN-MBR-{index:04d}",
                    "additional_collateral_requirement_total_usd": requirement,
                    "bucket_qualified_resource_reduction_usd": reduction,
                    "stressed_member_qualified_resources_usd": 500.0 - reduction,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def treasury() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "scenario_name": [
                "treasury_moderate",
                "treasury_moderate",
                "treasury_severe",
                "treasury_severe",
            ],
            "member_id": [
                "SYN-MBR-0001",
                "SYN-MBR-0002",
                "SYN-MBR-0001",
                "SYN-MBR-0002",
            ],
            "treasury_loss_usd": [12.0, 18.0, 24.0, 36.0],
            "value_class": ["synthetic"] * 4,
            "actual_ficc_participant": [False] * 4,
            "participant_level_inference": [False] * 4,
        }
    )


def settlement_fail() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    values = {
        "settlement_control": ((0.0, 0.0), (0.0, 0.0)),
        "settlement_moderate": ((8.0, 2.0), (10.0, 3.0)),
        "settlement_severe": ((16.0, 4.0), (20.0, 6.0)),
    }
    for scenario_name, member_values in values.items():
        for index, (settlement_only, funding_overlap) in enumerate(member_values, start=1):
            for bucket in ("open", "close"):
                rows.append(
                    {
                        "scenario_name": scenario_name,
                        "member_id": f"SYN-MBR-{index:04d}",
                        "time_bucket": bucket,
                        "incremental_settlement_fail_outflow_usd": settlement_only / 2.0,
                        "combined_funding_shock_outflow_usd": funding_overlap / 2.0,
                        "incremental_combined_stress_outflow_usd": (
                            settlement_only + funding_overlap
                        )
                        / 2.0,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )
    return pd.DataFrame.from_records(rows)


def run_result() -> IntegratedStressResult:
    return run_integrated_stress(
        baseline(),
        funding(),
        haircut(),
        treasury(),
        settlement_fail(),
        config(),
    )


def test_load_config_and_settings(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    path.write_text(yaml.safe_dump(config()), encoding="utf-8")
    loaded = load_config(path)
    settings = load_settings(loaded)
    assert settings.model_version == "section-19-test"
    assert len(settings.scenarios) == 3


def test_load_config_rejects_missing_and_nonmapping(tmp_path: Path) -> None:
    with pytest.raises(IntegratedStressError, match="does not exist"):
        load_config(tmp_path / "missing.yaml")
    path = tmp_path / "bad.yaml"
    path.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(IntegratedStressError, match="YAML mapping"):
        load_config(path)


@pytest.mark.parametrize(
    ("mutator", "message"),
    [
        (
            lambda value: value["integration"].update(
                concentration_base_components=["unknown_component"]
            ),
            "unsupported component",
        ),
        (
            lambda value: value["integration"].update(
                concentration_base_components=[
                    "settlement_liquidity_need_usd",
                    "settlement_liquidity_need_usd",
                ]
            ),
            "must be unique",
        ),
        (
            lambda value: value["integration"].update(lcr_minimum_ratio=0.0),
            "must be positive",
        ),
        (
            lambda value: value["validation"].update(reconciliation_tolerance_usd=-1.0),
            "must be nonnegative",
        ),
        (
            lambda value: value["scenarios"][1].update(operational_liquidity_buffer_rate=1.1),
            "between zero and one",
        ),
        (
            lambda value: value["scenarios"][1].update(concentration_multiplier=-0.1),
            "must be nonnegative",
        ),
        (
            lambda value: value["scenarios"][1].update(name="control"),
            "names must be unique",
        ),
        (
            lambda value: value["scenarios"][1].update(severity_rank=0),
            "ranks must be unique",
        ),
    ],
)
def test_settings_reject_invalid_config(
    mutator: Callable[[dict[str, Any]], None], message: str
) -> None:
    value = deepcopy(config())
    mutator(value)
    with pytest.raises(IntegratedStressError, match=message):
        load_settings(value)


def test_settings_reject_nonmonotonic_controls() -> None:
    value = deepcopy(config())
    value["scenarios"][2]["concentration_multiplier"] = 0.25
    with pytest.raises(IntegratedStressError, match="nondecreasing"):
        load_settings(value)
    value = deepcopy(config())
    value["scenarios"][2]["concentration_threshold"] = 0.50
    with pytest.raises(IntegratedStressError, match="cannot increase"):
        load_settings(value)


def test_prepare_baseline_validation() -> None:
    settings = load_settings(config())
    prepared = prepare_baseline_summary(baseline(), settings)
    assert list(prepared.columns) == [
        "member_id",
        "settlement_liquidity_need_usd",
        "available_qualified_liquid_resources_usd",
    ]
    invalid = baseline().drop(columns=["modeled_aqlr_usd"])
    with pytest.raises(IntegratedStressError, match="missing required fields"):
        prepare_baseline_summary(invalid, settings)
    invalid = baseline()
    invalid.loc[0, "net_settlement_outflow_usd"] = -1.0
    with pytest.raises(IntegratedStressError, match="must be nonnegative"):
        prepare_baseline_summary(invalid, settings)


def test_identity_and_uniqueness_controls() -> None:
    settings = load_settings(config())
    invalid = baseline()
    invalid.loc[0, "member_id"] = "ACTUAL-MEMBER"
    with pytest.raises(IntegratedStressError, match="non-synthetic"):
        prepare_baseline_summary(invalid, settings)
    invalid = baseline()
    invalid.loc[0, "actual_ficc_participant"] = True
    with pytest.raises(IntegratedStressError, match="prohibited"):
        prepare_baseline_summary(invalid, settings)
    invalid = pd.concat([baseline(), baseline().iloc[[0]]], ignore_index=True)
    with pytest.raises(IntegratedStressError, match="unique"):
        prepare_baseline_summary(invalid, settings)


def test_prepare_component_tables_and_optional_defaults() -> None:
    settings = load_settings(config())
    funding_input = funding().drop(
        columns=[
            "additional_collateral_demand_usd",
            "incremental_repo_funding_stress_outflow_usd",
        ]
    )
    prepared_funding = prepare_funding_summary(funding_input, settings)
    assert prepared_funding["additional_collateral_demand_usd"].eq(0.0).all()
    assert (
        prepared_funding["incremental_repo_funding_stress_outflow_usd"]
        == prepared_funding["repo_rollover_failure_outflow_usd"]
        + prepared_funding["incremental_funding_cost_usd"]
    ).all()
    assert not prepare_haircut_summary(haircut(), settings).empty
    assert not prepare_treasury_summary(treasury(), settings).empty


def test_prepare_funding_rejects_ratio_and_duplicate() -> None:
    settings = load_settings(config())
    invalid = funding()
    invalid.loc[0, "member_concentration_ratio"] = 1.1
    with pytest.raises(IntegratedStressError, match="must not exceed one"):
        prepare_funding_summary(invalid, settings)
    invalid = pd.concat([funding(), funding().iloc[[0]]], ignore_index=True)
    with pytest.raises(IntegratedStressError, match="unique"):
        prepare_funding_summary(invalid, settings)


def test_settlement_fail_aggregation_and_duplicate_bucket() -> None:
    settings = load_settings(config())
    prepared = prepare_settlement_fail_summary(settlement_fail(), settings)
    row = prepared.query(
        "scenario_name == 'settlement_moderate' and member_id == 'SYN-MBR-0001'"
    ).iloc[0]
    assert row["incremental_settlement_fail_outflow_usd"] == pytest.approx(8.0)
    assert row["combined_funding_shock_outflow_usd"] == pytest.approx(2.0)
    invalid = pd.concat([settlement_fail(), settlement_fail().iloc[[0]]], ignore_index=True)
    with pytest.raises(IntegratedStressError, match="time-bucket keys"):
        prepare_settlement_fail_summary(invalid, settings)


def test_integrated_component_math_and_lcr() -> None:
    result = run_result()
    assert result.passed
    row = result.member_results.query(
        "scenario_name == 'moderate' and member_id == 'SYN-MBR-0001'"
    ).iloc[0]
    assert row["settlement_liquidity_need_usd"] == pytest.approx(100.0)
    assert row["repo_rollover_need_usd"] == pytest.approx(20.0)
    assert row["incremental_funding_cost_usd"] == pytest.approx(5.0)
    assert row["additional_haircut_requirement_usd"] == pytest.approx(10.0)
    assert row["treasury_liquidation_loss_usd"] == pytest.approx(12.0)
    assert row["settlement_fail_requirement_usd"] == pytest.approx(8.0)
    assert row["concentration_adjustment_usd"] == pytest.approx(5.4)
    assert row["operational_liquidity_buffer_usd"] == pytest.approx(8.02)
    assert row["stressed_liquidity_requirement_usd"] == pytest.approx(168.42)
    assert row["liquidity_coverage_ratio"] == pytest.approx(500.0 / 168.42)


def test_control_uses_settlement_need_only() -> None:
    result = run_result()
    control = result.member_results.query("scenario_name == 'control'")
    assert control["stressed_liquidity_requirement_usd"].tolist() == [100.0, 200.0]
    assert control["treasury_liquidation_loss_usd"].eq(0.0).all()


def test_double_count_controls_exclude_composites() -> None:
    result = run_result()
    row = result.double_count_controls.query(
        "scenario_name == 'moderate' and member_id == 'SYN-MBR-0001'"
    ).iloc[0]
    assert row["excluded_section16_additional_collateral_demand_usd"] == 3.0
    assert row["excluded_section16_composite_outflow_usd"] == 28.0
    assert row["excluded_section18_funding_shock_usd"] == 2.0
    assert row["excluded_section18_composite_outflow_usd"] == 10.0
    assert bool(row["double_count_control_pass"])


def test_missing_scenario_and_member_fail_closed() -> None:
    value = treasury().query("scenario_name != 'treasury_severe'")
    with pytest.raises(IntegratedStressError, match="scenario was not found"):
        run_integrated_stress(baseline(), funding(), haircut(), value, settlement_fail(), config())
    value = funding().query("member_id != 'SYN-MBR-0002'")
    with pytest.raises(IntegratedStressError, match="missing mapped members"):
        run_integrated_stress(baseline(), value, haircut(), treasury(), settlement_fail(), config())


def test_zero_requirement_convention() -> None:
    base = baseline()
    base["net_settlement_outflow_usd"] = 0.0
    value = deepcopy(config())
    value["scenarios"] = [value["scenarios"][0]]
    result = run_integrated_stress(base, funding(), haircut(), treasury(), settlement_fail(), value)
    assert result.member_results["lcr_status"].eq("NO_REQUIREMENT").all()
    assert all(math.isinf(value) for value in result.member_results["liquidity_coverage_ratio"])
    assert result.passed


def test_breach_status_and_summary() -> None:
    base = baseline()
    base["modeled_aqlr_usd"] = [50.0, 60.0]
    result = run_integrated_stress(
        base, funding(), haircut(), treasury(), settlement_fail(), config()
    )
    severe = result.member_results.query("scenario_name == 'severe'")
    assert severe["lcr_status"].eq("BREACH").all()
    summary = build_scenario_summary(result.member_results)
    assert summary.query("scenario_name == 'severe'")["breach_member_count"].iloc[0] == 2
    controls = build_double_count_controls(result.member_results)
    assert len(controls) == len(result.member_results)


def test_validate_results_detects_tampering() -> None:
    result = run_result()
    settings = load_settings(config())
    tampered = result.member_results.copy()
    current_requirement = float(cast(Any, tampered.loc[0, "stressed_liquidity_requirement_usd"]))
    tampered.loc[0, "stressed_liquidity_requirement_usd"] = current_requirement + 10.0
    checks = validate_results(
        tampered,
        result.scenario_summary,
        result.double_count_controls,
        baseline_member_count=2,
        settings=settings,
    )
    assert not checks["stressed_requirement_identity"]


def test_dataframe_digest_is_row_order_independent() -> None:
    result = run_result()
    shuffled = result.member_results.sample(frac=1.0, random_state=2026)
    assert dataframe_digest(result.member_results) == dataframe_digest(shuffled)


def test_read_table_csv_parquet_and_errors(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    frame = baseline()
    csv_path = tmp_path / "input.csv"
    frame.to_csv(csv_path, index=False)
    assert len(read_table(csv_path)) == 2
    parquet_path = tmp_path / "input.parquet"
    parquet_path.write_bytes(b"controlled-test-placeholder")
    monkeypatch.setattr(pd, "read_parquet", lambda _: frame.copy())
    assert len(read_table(parquet_path)) == 2
    unsupported = tmp_path / "input.txt"
    unsupported.write_text("x", encoding="utf-8")
    with pytest.raises(IntegratedStressError, match="CSV or Parquet"):
        read_table(unsupported)
    with pytest.raises(IntegratedStressError, match="does not exist"):
        read_table(tmp_path / "missing.csv")


def test_empty_inputs_fail_closed() -> None:
    settings = load_settings(config())
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_baseline_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_funding_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_haircut_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_treasury_summary(pd.DataFrame(), settings)
    with pytest.raises(IntegratedStressError, match="empty"):
        prepare_settlement_fail_summary(pd.DataFrame(), settings)
'@

$DocsContent = @'
# Section 19 — Integrated Stressed Liquidity Requirement

## Purpose

Section 19 combines the controlled liquidity-stress outputs produced in
Sections 14 through 18 into one auditable stressed liquidity requirement and
one liquidity coverage ratio for each fictional synthetic clearing member and
integrated scenario.

The model does not identify, estimate, rank, or infer any actual FICC
participant.

## Core equation

For each synthetic member and integrated scenario:

```text
Settlement liquidity need
+ Repo rollover need
+ Incremental funding cost
+ Additional haircut requirement
+ Treasury liquidation loss
+ Settlement-fail requirement
+ Concentration adjustment
+ Operational liquidity buffer
= Stressed Liquidity Requirement
```

The liquidity coverage ratio is:

```text
LCR = Available Qualified Liquid Resources
      ------------------------------------
      Stressed Liquidity Requirement
```

The configured minimum passing ratio is `1.00`.

## Atomic component selection

The engine uses atomic source columns rather than composite totals.

| Integrated component | Controlled source |
|---|---|
| Settlement liquidity need | Section 14 `net_settlement_outflow_usd` |
| Repo rollover need | Section 16 `repo_rollover_failure_outflow_usd` |
| Incremental funding cost | Section 16 `incremental_funding_cost_usd` |
| Additional haircut requirement | Section 17 `additional_collateral_requirement_total_usd` |
| Treasury liquidation loss | Section 15 `treasury_loss_usd` |
| Settlement-fail requirement | Section 18 `incremental_settlement_fail_outflow_usd` |
| Concentration adjustment | Section 19 residual overlay |
| Operational liquidity buffer | Section 19 configured percentage |

## No-double-counting controls

### Section 16 funding composite

Section 16 reports:

```text
Repo rollover failure
+ Incremental funding cost
+ Additional collateral demand
= Incremental repo funding stress outflow
```

Section 19 selects only repo rollover failure and incremental funding cost. It
does not add the Section 16 composite outflow. Section 16 additional collateral
demand is excluded because Section 19 obtains the haircut-driven collateral
requirement from Section 17.

### Section 18 combined settlement and funding composite

Section 18 reports:

```text
Incremental settlement-fail outflow
+ Combined funding-shock outflow
= Incremental combined stress outflow
```

Section 19 selects only the settlement-fail outflow. It does not add either the
Section 18 funding overlay or the Section 18 combined total, because Section 16
funding components are already selected directly.

### Section 17 stressed AQLR

Section 17 stressed qualified resources subtract collateral value erosion and
posted collateral. Section 19 does not use that stressed AQLR field in the LCR
numerator while also adding the full Section 17 collateral requirement to the
denominator. Using both would duplicate posted-collateral effects.

The Section 19 numerator therefore remains the controlled Section 14
`modeled_aqlr_usd`. Haircut stress enters through the separately identified
additional haircut requirement.

### Concentration overlay

Repo funding, Treasury liquidation, and collateral haircuts already contain
their own concentration-sensitive mechanisms. The Section 19 concentration
overlay is therefore applied only to configured residual components:

- settlement liquidity need;
- settlement-fail requirement.

This prevents a second concentration charge on components already adjusted by
their source models.

### Operational buffer

The operational liquidity buffer is applied once, after the six atomic
components and the residual concentration adjustment have been combined.

## Integrated scenario mapping

The controlled configuration defines four severity-ordered scenarios:

1. `control`
2. `moderate_integrated_stress`
3. `severe_integrated_stress`
4. `extreme_integrated_crisis`

Each integrated scenario explicitly maps to one Section 16 funding scenario,
one Section 17 haircut scenario, one Section 15 Treasury scenario, and one
Section 18 settlement-fail scenario.

The control scenario assigns no Treasury liquidation shock and applies no
Section 19 concentration or operational buffer.

## Treasury maturity bridge

Section 12 and Section 15 use different Treasury maturity bucket granularity.
When a member-aligned Section 15 summary is unavailable, the Section 19 runner
uses a deterministic weighted bridge from Section 12 synthetic maturity
positions to the Section 15 maturity buckets and then calls the validated
Section 15 Treasury yield-shock model.

The source-bucket weights must sum exactly to one. The bridge is an explicit
modeling assumption and is recorded in
`configs/integrated_stress_engine.yaml`.

## Inputs

Preferred controlled inputs are:

- `reports/tables/baseline_liquidity_summary.parquet`
- `reports/tables/repo_funding_stress_member_summary.parquet`
- `reports/tables/collateral_haircut_stress_member_summary.parquet`
- `reports/tables/settlement_fail_stress_cashflows.parquet`
- a member-aligned Section 15 Treasury stress summary, or
- `data/synthetic/calibrated_member_portfolios.parquet` for the Treasury bridge.

CSV fallbacks are supported where configured.

## Outputs

The runner writes CSV and Parquet versions of:

- `reports/tables/integrated_stress_member_results`
- `reports/tables/integrated_stress_scenario_summary`
- `reports/tables/integrated_stress_double_count_controls`

When the Treasury bridge is required, it also writes:

- `reports/tables/treasury_yield_stress_member_summary_section19_adapter`
- `reports/tables/treasury_yield_stress_positions_section19_adapter`

Evidence and lineage outputs are:

- `reports/evidence/section19_integrated_stress_engine.json`
- `reports/evidence/section19_integrated_stress_engine.md`
- `data/manifests/integrated_stress_engine_manifest.csv`

## Validation gates

Section 19 fails closed unless all applicable gates pass:

- expected member-scenario row count;
- unique member-scenario keys;
- finite and nonnegative required outputs;
- stressed-requirement arithmetic identity;
- LCR arithmetic identity;
- zero-requirement LCR convention;
- LCR status identity;
- Section 16 and Section 18 composite reconciliation;
- complete scenario summary;
- nondecreasing aggregate requirement by severity;
- deterministic reproduction;
- synthetic-member-only controls.

## Model-risk limitations

- The integrated scenarios are controlled assumptions, not forecasts.
- Aggregate public data do not reveal participant-level portfolios, settlement
  timing, lender relationships, collateral substitutions, or operational
  responses.
- The Section 19 requirement is an analytical stress measure and is not an
  official FICC liquidity requirement.
- The Treasury maturity bridge introduces a documented allocation assumption.
- The residual concentration overlay is intentionally narrow to avoid duplicate
  concentration effects.
- Correlations across stress channels are represented through scenario mapping,
  not estimated participant-level joint distributions.
- AQLR remains the Section 14 modeled resource amount to prevent duplication
  with the Section 17 denominator charge.
'@

    Write-Utf8File -Path "configs\integrated_stress_engine.yaml" -Content $ConfigContent
    Write-Utf8File `
        -Path "src\ficc_liquidity\stress\integrated_stress.py" `
        -Content $ModuleContent
    Write-Utf8File -Path "scripts\run_integrated_stress.py" -Content $RunnerContent
    Write-Utf8File -Path "tests\test_integrated_stress.py" -Content $TestContent
    Write-Utf8File `
        -Path "docs\integrated_stress_engine_methodology.md" `
        -Content $DocsContent
    Write-Pass "Section 19 controlled source files written"

    Write-Step "Preparing the Python 3.11 environment"
    $Python = Join-Path $RepoPath ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw "Python virtual environment not found: $Python"
    }
    $version = (& $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')").Trim()
    if ($LASTEXITCODE -ne 0 -or $version -ne "3.11") {
        throw "The repository virtual environment must use Python 3.11; detected $version."
    }
    $env:PYTHONPATH = Join-Path $RepoPath "src"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @("-m", "pip", "install", "-e", ".[dev]") `
        -FailureMessage "Project installation failed."
    Write-Pass "Python 3.11 environment is ready"

    $PythonFiles = @(
        "src/ficc_liquidity/stress/integrated_stress.py",
        "scripts/run_integrated_stress.py",
        "tests/test_integrated_stress.py"
    )

    Write-Step "Formatting and linting Section 19"
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "format") + $PythonFiles) `
        -FailureMessage "Ruff formatting failed."
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "check") + $PythonFiles) `
        -FailureMessage "Ruff validation failed."
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "format", "--check") + $PythonFiles) `
        -FailureMessage "Ruff format check failed."
    Write-Pass "Ruff formatting and linting"

    Write-Step "Running strict static type checking"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @("-m", "mypy", "src", "tests") `
        -FailureMessage "Strict Mypy validation failed."
    Write-Pass "Strict Mypy validation"

    Write-Step "Running focused Section 19 branch coverage"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "pytest",
            "-o", "addopts=",
            "tests/test_integrated_stress.py",
            "--cov=ficc_liquidity.stress.integrated_stress",
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under=90"
        ) `
        -FailureMessage "Section 19 focused tests or coverage failed."
    Write-Pass "Focused tests and branch coverage"

    if (-not $SkipPriorRuns) {
        Write-Step "Refreshing controlled prior-section result inputs"

        if (-not (Test-Path -LiteralPath "reports\tables\baseline_liquidity_summary.csv")) {
            Invoke-Checked -FilePath $Python `
                -ArgumentList @("scripts/run_baseline_liquidity.py") `
                -FailureMessage "Section 14 baseline-liquidity generation failed."
        }
        Write-Pass "Section 14 baseline summary available"

        if (-not (Test-Path -LiteralPath "reports\tables\repo_funding_stress_member_summary.csv")) {
            Invoke-Checked -FilePath $Python `
                -ArgumentList @("scripts/run_repo_funding_stress.py") `
                -FailureMessage "Section 16 repo-funding generation failed."
        }
        Write-Pass "Section 16 funding summary available"

        if (-not (Test-Path -LiteralPath "reports\tables\collateral_haircut_stress_member_summary.csv")) {
            Invoke-Checked -FilePath $Python `
                -ArgumentList @("scripts/run_collateral_haircut_stress.py") `
                -FailureMessage "Section 17 collateral-haircut generation failed."
        }
        Write-Pass "Section 17 haircut summary available"

        Invoke-Checked -FilePath $Python `
            -ArgumentList @("scripts/run_settlement_fail_stress.py") `
            -FailureMessage "Section 18 settlement-fail generation failed."
        Write-Pass "Section 18 settlement-fail cash flows available"
    }
    else {
        Write-Warn "Prior-section model refresh was skipped by request."
    }

    Write-Step "Executing the controlled Section 19 integrated stress engine"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @("scripts/run_integrated_stress.py") `
        -FailureMessage "Section 19 controlled model run failed."
    Write-Pass "Section 19 integrated requirement and LCR calculations"

    if (-not $SkipFullTests) {
        Write-Step "Running complete repository tests and coverage"
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("-m", "pytest") `
            -FailureMessage "Complete repository Pytest or coverage validation failed."
        Write-Pass "Complete repository test suite"
    }
    else {
        Write-Warn "Complete repository tests were skipped by request."
    }

    # SECTION19_GENERATED_TEXT_NORMALIZATION
    Write-Step "Normalizing generated text artifacts"

    $changedTextFiles = @(
        & git diff --name-only --diff-filter=ACMRT
    ) | Where-Object {
        $_ -match '\.(csv|json|md|py|ps1|toml|txt|yaml|yml)$' -and
        (Test-Path -LiteralPath $_ -PathType Leaf)
    }

    foreach ($relativePath in $changedTextFiles) {
        $fullPath = Join-Path $RepoPath $relativePath
        $lines = [System.IO.File]::ReadAllLines($fullPath)

        $cleanLines = @(
            foreach ($line in $lines) {
                $line.TrimEnd()
            }
        )

        $cleanContent = (($cleanLines -join "`n").TrimEnd() + "`n")

        [System.IO.File]::WriteAllText(
            $fullPath,
            $cleanContent,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }

    Write-Pass "Generated text artifacts normalized"

    Write-Step "Checking patch integrity"
    if (-not $SkipGit) {
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("diff", "--check") `
            -FailureMessage "Git diff whitespace validation failed."
        Write-Pass "Git diff validation"
    }

    $requiredOutputs = @(
        "configs\integrated_stress_engine.yaml",
        "src\ficc_liquidity\stress\integrated_stress.py",
        "scripts\run_integrated_stress.py",
        "tests\test_integrated_stress.py",
        "docs\integrated_stress_engine_methodology.md",
        "reports\tables\integrated_stress_member_results.csv",
        "reports\tables\integrated_stress_scenario_summary.csv",
        "reports\tables\integrated_stress_double_count_controls.csv",
        "reports\evidence\section19_integrated_stress_engine.json",
        "reports\evidence\section19_integrated_stress_engine.md",
        "data\manifests\integrated_stress_engine_manifest.csv",
        $AutomationRelativePath
    )
    if (-not (Test-RequiredFiles -Paths $requiredOutputs)) {
        $missingOutputs = @(
            foreach ($path in $requiredOutputs) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $path
                }
            }
        )
        throw "Section 19 outputs are incomplete: $($missingOutputs -join ', ')"
    }
    Write-Pass "All controlled Section 19 deliverables are present"

    if (-not $SkipGit) {
        Write-Step "Staging Section 19 controlled artifacts"
        $pathsToStage = @(
            "configs/integrated_stress_engine.yaml",
            "src/ficc_liquidity/stress/integrated_stress.py",
            "scripts/run_integrated_stress.py",
            "tests/test_integrated_stress.py",
            "docs/integrated_stress_engine_methodology.md",
            "data/manifests/integrated_stress_engine_manifest.csv",
            "reports/evidence/section19_integrated_stress_engine*.json",
            "reports/evidence/section19_integrated_stress_engine*.md",
            "reports/tables/integrated_stress_member_results*",
            "reports/tables/integrated_stress_scenario_summary*",
            "reports/tables/integrated_stress_double_count_controls*",
            "reports/tables/treasury_yield_stress_member_summary_section19_adapter*",
            "reports/tables/treasury_yield_stress_positions_section19_adapter*",
            $AutomationRelativePath.Replace("\", "/")
        )

        $expandedPathsToStage = @()
        foreach ($path in $pathsToStage) {
            if ($path -match '[*?\[]') {
                $matchingFiles = @(
                    Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue
                )
                if ($matchingFiles.Count -gt 0) {
                    $expandedPathsToStage += @($matchingFiles.FullName)
                }
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                $expandedPathsToStage += $path
            }
        }

        foreach ($path in ($expandedPathsToStage | Sort-Object -Unique)) {
            Add-ControlledPath -Path $path
        }

        Invoke-Checked -FilePath "git" `
            -ArgumentList @("diff", "--cached", "--check") `
            -FailureMessage "Staged Section 19 artifacts failed whitespace validation."

        $stagedNames = @(& git diff --cached --name-only)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect staged Section 19 artifacts."
        }

        $createdCommit = $false
        if ($stagedNames.Count -gt 0) {
            if ($NoCommit) {
                Write-Warn "Section 19 changes are staged but were not committed."
            }
            else {
                Invoke-Checked -FilePath "git" `
                    -ArgumentList @("commit", "-m", $CommitMessage) `
                    -FailureMessage "Unable to commit Section 19 changes."
                $createdCommit = $true
                Write-Pass "Section 19 changes committed"
            }
        }
        else {
            Write-Warn "No new Section 19 changes required a commit."
        }

        if (-not $SkipPush) {
            if ($NoCommit -and $stagedNames.Count -gt 0) {
                Write-Warn "Push skipped because -NoCommit left staged changes uncommitted."
            }
            else {
                Invoke-Checked -FilePath "git" `
                    -ArgumentList @("push", "-u", "origin", $BranchName) `
                    -FailureMessage "Unable to push $BranchName."
                Write-Pass "Branch pushed to origin"
            }
        }
        else {
            Write-Warn "Git push was skipped by request."
        }

        if (-not $SkipPullRequest -and -not $NoCommit -and -not $SkipPush) {
            if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
                Write-Warn "GitHub CLI was not found; pull-request creation was skipped."
            }
            else {
                & gh auth status *> $null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn "GitHub CLI is not authenticated; pull-request creation was skipped."
                }
                else {
                    $existingRaw = & gh pr list `
                        --repo $RepoFullName `
                        --head $BranchName `
                        --state open `
                        --json url `
                        --jq '.[0].url'
                    $existingUrl = ([string]$existingRaw).Trim()

                    if ($LASTEXITCODE -ne 0) {
                        throw "Unable to inspect existing pull requests."
                    }

                    if ([string]::IsNullOrWhiteSpace($existingUrl)) {
                        $prBody = @"
Completes Phase V Section 19 integrated stressed liquidity requirements.

Implemented:
- atomic integration of settlement, repo rollover, funding cost, haircut,
  Treasury liquidation, and settlement-fail requirements;
- residual concentration adjustment and operational liquidity buffer;
- explicit exclusion of Section 16 and Section 18 composite totals;
- controlled Section 14 AQLR numerator to prevent Section 17 duplication;
- LCR, headroom, shortfall, member status, and scenario aggregation;
- Treasury maturity-bucket bridge through the validated Section 15 model;
- deterministic reproduction, synthetic-member safeguards, lineage,
  evidence, focused branch coverage, and complete repository quality gates.
"@
                        Invoke-Checked -FilePath "gh" `
                            -ArgumentList @(
                                "pr", "create",
                                "--repo", $RepoFullName,
                                "--base", "main",
                                "--head", $BranchName,
                                "--title", $PullRequestTitle,
                                "--body", $prBody
                            ) `
                            -FailureMessage "Unable to create the Section 19 pull request."
                        Write-Pass "Section 19 pull request created"
                    }
                    else {
                        Write-Pass "Existing Section 19 pull request: $existingUrl"
                    }

                    if ($WatchChecks) {
                        Invoke-Checked -FilePath "gh" `
                            -ArgumentList @(
                                "pr", "checks",
                                "--repo", $RepoFullName,
                                $BranchName,
                                "--watch"
                            ) `
                            -FailureMessage "GitHub Actions checks failed."
                        Write-Pass "GitHub Actions checks"
                    }
                }
            }
        }
        elseif ($SkipPullRequest) {
            Write-Warn "Pull-request creation was skipped by request."
        }
    }

    Write-Step "Section 19 completion summary"
    Write-Pass "Branch: $BranchName"
    Write-Pass "Atomic component integration: PASS"
    Write-Pass "No-double-counting controls: PASS"
    Write-Pass "Stressed liquidity requirement identity: PASS"
    Write-Pass "LCR identity: PASS"
    Write-Pass "Synthetic-member safeguards: PASS"
    Write-Pass "Deterministic reproduction: PASS"
    Write-Host ""
    Write-Host "Primary evidence:" -ForegroundColor White
    Write-Host "  reports\evidence\section19_integrated_stress_engine.md"
    Write-Host "  reports\evidence\section19_integrated_stress_engine.json"
    Write-Host "  reports\tables\integrated_stress_scenario_summary.csv"
}
catch {
    Write-Host ""
    Write-Host ("SECTION 19 AUTOMATION FAILED: {0}" -f $_.Exception.Message) `
        -ForegroundColor Red
    throw
}
finally {
    Set-Location $OriginalLocation
}
