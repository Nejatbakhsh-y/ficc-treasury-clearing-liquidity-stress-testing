#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase V, Section 16: repo funding-stress model.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.
    It updates main, creates feature/14-repo-funding-stress, writes the controlled
    configuration, Python model, runner, tests, methodology, manifest, evidence,
    and output tables; runs Ruff, strict Mypy, focused branch coverage, the actual
    Section 16 model, and the complete repository test suite; then commits, pushes,
    and opens a pull request.

    The model implements SOFR rate spikes, funding-cost increases, repo rollover
    failures, partial lender withdrawal, shorter refinancing horizons, increased
    collateral demands, and funding concentration. It operates only on fictional
    synthetic clearing members.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\18_P5S16_Repo_Funding_Stress_Model_PS51.ps1"

.EXAMPLE
    & "$env:USERPROFILE\Downloads\18_P5S16_Repo_Funding_Stress_Model_PS51.ps1" `
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
    [switch]$AllowDemo,

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
$BranchName = "feature/14-repo-funding-stress"
$CommitMessage = "Phase V Section 16: add repo funding-stress model"
$PullRequestTitle = "Phase V Section 16: Repo funding-stress model"
$AutomationRelativePath = "scripts\automation\18_P5S16_Repo_Funding_Stress_Model_PS51.ps1"

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
        [Parameter(Mandatory = $true)][string]$Content
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
Use -AllowDirty only when rerunning Section 16 on its feature branch.
"@
            }
            if ($currentBranch -ne $BranchName) {
                throw @"
-AllowDirty is safe only when the current branch is $BranchName.
The current branch is $currentBranch. Commit or stash the existing changes first.
"@
            }
            $skipBranchRefresh = $true
            Write-Warn "Dirty Section 16 branch retained; main refresh and branch merge were skipped."
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

    Write-Step "Confirming Section 12, Section 14, and Section 15 dependencies"
    $requiredDependencies = @(
        "data\synthetic\calibrated_member_portfolios.parquet",
        "configs\baseline_liquidity.yaml",
        "src\ficc_liquidity\liquidity\baseline_cashflow.py",
        "reports\tables\baseline_liquidity_cashflows.csv",
        "configs\treasury_yield_stress.yaml",
        "src\ficc_liquidity\stress\treasury_yield_shock.py"
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
    Write-Pass "Required prior-section model and data artifacts are available"

    Write-Step "Creating Section 16 directories and controlled files"
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
section: 16
model_name: repo_funding_stress
model_version: "section-16-v1"
currency: USD
random_seed: 2026

classification:
  baseline_cash_flows: modeled
  synthetic_member_profiles: synthetic
  sofr_observations: observed
  scenario_assumptions: assumed
  stress_results: modeled
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false

source:
  baseline_cashflow_candidates:
    - reports/tables/baseline_liquidity_cashflows.parquet
    - reports/tables/baseline_liquidity_cashflows.csv
  member_profile_candidates:
    - data/synthetic/calibrated_member_portfolios.parquet
    - data/synthetic/calibrated_member_portfolios.csv
    - data/synthetic/synthetic_members.parquet
    - data/synthetic/synthetic_members.csv
  synthetic_id_pattern: '^SYN-MBR-[0-9]{4}$'

sofr:
  mode: latest_available_or_assumed
  input_candidates:
    - data/processed/fed_liquidity_factors.parquet
    - data/processed/fed_liquidity_factors.csv
    - data/raw/nyfed_sofr.parquet
    - data/raw/nyfed_sofr.csv
  date_column_candidates:
    - observation_date
    - as_of_date
    - date
  value_column_candidates:
    - sofr_rate
    - sofr
    - rate
  unit: percent
  fallback_reference_percent: 4.50

assumptions:
  reference_sofr_percent: 4.50
  baseline_liquidity_horizon_hours: 48
  day_count_basis: 360

scenarios:
  - name: control
    enabled: true
    severity_rank: 0
    sofr_spike_bp: 0.0
    funding_spread_increase_bp: 0.0
    repo_rollover_failure_rate: 0.0
    lender_withdrawal_rate: 0.0
    refinancing_horizon_hours: 48
    collateral_haircut_increase: 0.0
    collateral_call_rate: 0.0
    concentration_threshold: 0.25
    concentration_multiplier: 0.0
    funding_dependency_multiplier: 0.0
    max_effective_unavailability_rate: 0.0

  - name: moderate_market_stress
    enabled: true
    severity_rank: 1
    sofr_spike_bp: 100.0
    funding_spread_increase_bp: 50.0
    repo_rollover_failure_rate: 0.10
    lender_withdrawal_rate: 0.10
    refinancing_horizon_hours: 24
    collateral_haircut_increase: 0.02
    collateral_call_rate: 0.03
    concentration_threshold: 0.25
    concentration_multiplier: 1.00
    funding_dependency_multiplier: 0.50
    max_effective_unavailability_rate: 0.60

  - name: severe_market_stress
    enabled: true
    severity_rank: 2
    sofr_spike_bp: 250.0
    funding_spread_increase_bp: 150.0
    repo_rollover_failure_rate: 0.30
    lender_withdrawal_rate: 0.25
    refinancing_horizon_hours: 12
    collateral_haircut_increase: 0.05
    collateral_call_rate: 0.08
    concentration_threshold: 0.20
    concentration_multiplier: 2.00
    funding_dependency_multiplier: 1.00
    max_effective_unavailability_rate: 0.85

  - name: concentrated_funding_freeze
    enabled: true
    severity_rank: 3
    sofr_spike_bp: 400.0
    funding_spread_increase_bp: 250.0
    repo_rollover_failure_rate: 0.55
    lender_withdrawal_rate: 0.40
    refinancing_horizon_hours: 6
    collateral_haircut_increase: 0.10
    collateral_call_rate: 0.15
    concentration_threshold: 0.15
    concentration_multiplier: 3.00
    funding_dependency_multiplier: 1.50
    max_effective_unavailability_rate: 0.98

validation:
  reconciliation_tolerance_usd: 0.01
  require_deterministic_reproduction: true
  require_synthetic_identifiers: true
  require_all_seven_stress_channels: true

output:
  directory: reports/tables
  evidence_directory: reports/evidence
  manifest: data/manifests/repo_funding_stress_manifest.csv
  write_csv: true
  write_parquet: true
'@
    $InitContent = @'
"""Stress-model components for FICC liquidity analysis."""

from ficc_liquidity.stress.repo_funding_stress import (
    RepoFundingScenario,
    RepoFundingStressError,
    RepoFundingStressSettings,
    calculate_repo_funding_stress,
    run_model,
)
from ficc_liquidity.stress.treasury_yield_shock import (
    TreasuryYieldShockModel,
    build_shock_vector,
    derive_h15_bucket_shocks,
    load_stress_config,
)

__all__ = [
    "RepoFundingScenario",
    "RepoFundingStressError",
    "RepoFundingStressSettings",
    "TreasuryYieldShockModel",
    "build_shock_vector",
    "calculate_repo_funding_stress",
    "derive_h15_bucket_shocks",
    "load_stress_config",
    "run_model",
]
'@
    $ModuleContent = @'
"""Repo funding-stress model for synthetic clearing-member liquidity analysis.

The model overlays configurable repo-market funding shocks on the controlled
Section 14 baseline liquidity cash flows. It operates only on fictional member
records and never identifies or infers actual FICC participants.
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class RepoFundingStressError(ValueError):
    """Raised when repo funding-stress inputs or assumptions are invalid."""


@dataclass(frozen=True, slots=True)
class RepoFundingScenario:
    """One controlled repo funding-stress scenario."""

    name: str
    severity_rank: int
    sofr_spike_bp: float
    funding_spread_increase_bp: float
    repo_rollover_failure_rate: float
    lender_withdrawal_rate: float
    refinancing_horizon_hours: int
    collateral_haircut_increase: float
    collateral_call_rate: float
    concentration_threshold: float
    concentration_multiplier: float
    funding_dependency_multiplier: float
    max_effective_unavailability_rate: float


@dataclass(frozen=True, slots=True)
class RepoFundingStressSettings:
    """Validated Section 16 assumptions and scenario definitions."""

    model_version: str
    reference_sofr_percent: float
    baseline_liquidity_horizon_hours: int
    day_count_basis: int
    tolerance_usd: float
    synthetic_id_pattern: str
    scenarios: tuple[RepoFundingScenario, ...]


@dataclass(frozen=True, slots=True)
class ValidationResult:
    """Structured Section 16 validation result."""

    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RepoFundingStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RepoFundingStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise RepoFundingStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise RepoFundingStressError(f"{key} must be an integer.")
    return int(value)


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise RepoFundingStressError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _bounded_rate(value: float, label: str, *, upper_inclusive: bool = True) -> None:
    upper_valid = value <= 1.0 if upper_inclusive else value < 1.0
    if value < 0.0 or not upper_valid:
        comparator = "between zero and one" if upper_inclusive else "at least zero and below one"
        raise RepoFundingStressError(f"{label} must be {comparator}.")


def _load_scenario(
    raw_scenario: Mapping[str, Any],
    baseline_horizon_hours: int,
) -> RepoFundingScenario:
    scenario = RepoFundingScenario(
        name=str(raw_scenario.get("name", "")).strip(),
        severity_rank=_integer(raw_scenario, "severity_rank"),
        sofr_spike_bp=_number(raw_scenario, "sofr_spike_bp"),
        funding_spread_increase_bp=_number(raw_scenario, "funding_spread_increase_bp"),
        repo_rollover_failure_rate=_number(raw_scenario, "repo_rollover_failure_rate"),
        lender_withdrawal_rate=_number(raw_scenario, "lender_withdrawal_rate"),
        refinancing_horizon_hours=_integer(raw_scenario, "refinancing_horizon_hours"),
        collateral_haircut_increase=_number(raw_scenario, "collateral_haircut_increase"),
        collateral_call_rate=_number(raw_scenario, "collateral_call_rate"),
        concentration_threshold=_number(raw_scenario, "concentration_threshold"),
        concentration_multiplier=_number(raw_scenario, "concentration_multiplier"),
        funding_dependency_multiplier=_number(raw_scenario, "funding_dependency_multiplier"),
        max_effective_unavailability_rate=_number(
            raw_scenario,
            "max_effective_unavailability_rate",
        ),
    )
    if not scenario.name:
        raise RepoFundingStressError("Every scenario must have a nonempty name.")
    if scenario.severity_rank < 0:
        raise RepoFundingStressError("severity_rank must be nonnegative.")
    if scenario.sofr_spike_bp < 0.0:
        raise RepoFundingStressError("sofr_spike_bp must be nonnegative.")
    if scenario.funding_spread_increase_bp < 0.0:
        raise RepoFundingStressError("funding_spread_increase_bp must be nonnegative.")
    for label, value in (
        ("repo_rollover_failure_rate", scenario.repo_rollover_failure_rate),
        ("lender_withdrawal_rate", scenario.lender_withdrawal_rate),
        ("collateral_haircut_increase", scenario.collateral_haircut_increase),
        ("collateral_call_rate", scenario.collateral_call_rate),
        ("concentration_threshold", scenario.concentration_threshold),
        (
            "max_effective_unavailability_rate",
            scenario.max_effective_unavailability_rate,
        ),
    ):
        _bounded_rate(value, label)
    if scenario.refinancing_horizon_hours <= 0:
        raise RepoFundingStressError("refinancing_horizon_hours must be positive.")
    if scenario.refinancing_horizon_hours > baseline_horizon_hours:
        raise RepoFundingStressError(
            "refinancing_horizon_hours cannot exceed the baseline liquidity horizon."
        )
    if scenario.concentration_multiplier < 0.0:
        raise RepoFundingStressError("concentration_multiplier must be nonnegative.")
    if scenario.funding_dependency_multiplier < 0.0:
        raise RepoFundingStressError("funding_dependency_multiplier must be nonnegative.")
    return scenario


def load_settings(config: Mapping[str, Any]) -> RepoFundingStressSettings:
    """Validate and convert the repo funding-stress configuration."""
    assumptions = _mapping(config.get("assumptions"), "assumptions")
    validation = _mapping(config.get("validation"), "validation")
    source = _mapping(config.get("source"), "source")
    raw_scenarios = config.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise RepoFundingStressError("scenarios must be a nonempty list.")

    baseline_horizon_hours = _integer(
        assumptions,
        "baseline_liquidity_horizon_hours",
    )
    if baseline_horizon_hours <= 0:
        raise RepoFundingStressError(
            "baseline_liquidity_horizon_hours must be positive."
        )

    scenarios: list[RepoFundingScenario] = []
    for raw_scenario in raw_scenarios:
        scenario_mapping = _mapping(raw_scenario, "scenario")
        if not bool(scenario_mapping.get("enabled", True)):
            continue
        scenarios.append(_load_scenario(scenario_mapping, baseline_horizon_hours))
    if not scenarios:
        raise RepoFundingStressError("At least one enabled scenario is required.")

    names = [scenario.name for scenario in scenarios]
    if len(set(names)) != len(names):
        raise RepoFundingStressError("Scenario names must be unique.")
    ranks = [scenario.severity_rank for scenario in scenarios]
    if len(set(ranks)) != len(ranks):
        raise RepoFundingStressError("Scenario severity ranks must be unique.")

    settings = RepoFundingStressSettings(
        model_version=str(config.get("model_version", "section-16-v1")).strip(),
        reference_sofr_percent=_number(assumptions, "reference_sofr_percent"),
        baseline_liquidity_horizon_hours=baseline_horizon_hours,
        day_count_basis=_integer(assumptions, "day_count_basis"),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        synthetic_id_pattern=str(
            source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")
        ),
        scenarios=tuple(sorted(scenarios, key=lambda item: item.severity_rank)),
    )
    if not settings.model_version:
        raise RepoFundingStressError("model_version must be populated.")
    if settings.reference_sofr_percent < 0.0:
        raise RepoFundingStressError("reference_sofr_percent must be nonnegative.")
    if settings.day_count_basis <= 0:
        raise RepoFundingStressError("day_count_basis must be positive.")
    if settings.tolerance_usd < 0.0:
        raise RepoFundingStressError("reconciliation_tolerance_usd must be nonnegative.")
    return settings


def read_table(path: str | Path) -> pd.DataFrame:
    """Read a CSV or Parquet table."""
    table_path = Path(path)
    if not table_path.exists():
        raise RepoFundingStressError(f"Input table does not exist: {table_path}")
    suffix = table_path.suffix.lower()
    if suffix == ".csv":
        return pd.read_csv(table_path)
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(table_path)
    raise RepoFundingStressError("Input tables must be CSV or Parquet.")


def _validate_synthetic_identity(
    frame: pd.DataFrame,
    synthetic_id_pattern: str,
) -> None:
    member_ids = frame["member_id"].astype("string").str.strip()
    if member_ids.isna().any():
        raise RepoFundingStressError("Synthetic member identifiers cannot be missing.")
    invalid = [
        member_id
        for member_id in member_ids.astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise RepoFundingStressError(
            f"Non-synthetic or invalid member identifiers detected: {sorted(set(invalid))}"
        )
    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise RepoFundingStressError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise RepoFundingStressError("Participant-level inference records are prohibited.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise RepoFundingStressError("Every member record must use value_class='synthetic'.")


def prepare_baseline(
    baseline: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    """Canonicalize and validate Section 14 baseline cash-flow records."""
    if baseline.empty:
        raise RepoFundingStressError("Baseline liquidity cash-flow input is empty.")
    required = {
        "member_id",
        "bucket_order",
        "time_bucket",
        "elapsed_hours",
        "liquidity_horizon_hours",
        "repo_maturity_usd",
        "repo_roll_amount_usd",
        "financing_outflow_usd",
        "total_cash_outflow_usd",
        "cumulative_net_liquidity_need_usd",
        "cumulative_available_resources_usd",
        "liquidity_headroom_usd",
        "liquidity_shortfall_usd",
    }
    missing = sorted(required - set(baseline.columns))
    if missing:
        raise RepoFundingStressError(
            f"Required baseline cash-flow columns are missing: {missing}"
        )

    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame.duplicated(["member_id", "time_bucket"]).any():
        raise RepoFundingStressError(
            "Baseline member and time-bucket combinations must be unique."
        )

    numeric_columns = sorted(required - {"member_id", "time_bucket"})
    for column in numeric_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise RepoFundingStressError(f"{column} contains missing or nonfinite values.")

    nonnegative = [
        column
        for column in numeric_columns
        if column not in {"liquidity_headroom_usd"}
    ]
    if (frame[nonnegative] < -settings.tolerance_usd).any().any():
        raise RepoFundingStressError(
            "Baseline nonnegative cash-flow components contain negative values."
        )
    if not frame["liquidity_horizon_hours"].eq(
        settings.baseline_liquidity_horizon_hours
    ).all():
        raise RepoFundingStressError(
            "Baseline liquidity-horizon values do not match the Section 16 configuration."
        )

    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values(
        ["member_id", "bucket_order"],
        kind="stable",
    ).reset_index(drop=True)


def _derive_member_ratios(frame: pd.DataFrame) -> pd.DataFrame:
    result = frame.copy(deep=True)
    treasury_columns = [
        column
        for column in result.columns
        if column.startswith("treasury_position_") and column.endswith("_usd")
    ]

    if "member_concentration_ratio" not in result.columns:
        if not treasury_columns:
            raise RepoFundingStressError(
                "member_concentration_ratio is missing and cannot be derived."
            )
        if "total_treasury_position_usd" not in result.columns:
            raise RepoFundingStressError(
                "total_treasury_position_usd is required to derive concentration."
            )
        total = pd.to_numeric(
            result["total_treasury_position_usd"],
            errors="coerce",
        )
        if total.isna().any() or (total <= 0.0).any():
            raise RepoFundingStressError(
                "total_treasury_position_usd is required to derive concentration."
            )
        result["member_concentration_ratio"] = (
            result[treasury_columns].apply(pd.to_numeric, errors="coerce").max(axis=1)
            / total
        )

    if "funding_dependency_ratio" not in result.columns:
        required = {"repo_financing_need_usd", "treasury_transaction_activity_usd"}
        if not required.issubset(result.columns):
            raise RepoFundingStressError(
                "funding_dependency_ratio is missing and cannot be derived."
            )
        activity = pd.to_numeric(
            result["treasury_transaction_activity_usd"],
            errors="coerce",
        )
        if activity.isna().any() or (activity <= 0.0).any():
            raise RepoFundingStressError(
                "treasury_transaction_activity_usd must be positive."
            )
        result["funding_dependency_ratio"] = (
            pd.to_numeric(result["repo_financing_need_usd"], errors="coerce")
            / activity
        )

    if "net_repo_dependency_ratio" not in result.columns:
        required = {"repo_financing_need_usd", "reverse_repo_position_usd"}
        if not required.issubset(result.columns):
            raise RepoFundingStressError(
                "net_repo_dependency_ratio is missing and cannot be derived."
            )
        repo = pd.to_numeric(result["repo_financing_need_usd"], errors="coerce")
        reverse = pd.to_numeric(
            result["reverse_repo_position_usd"],
            errors="coerce",
        )
        if repo.isna().any() or (repo <= 0.0).any():
            raise RepoFundingStressError("repo_financing_need_usd must be positive.")
        result["net_repo_dependency_ratio"] = (repo - reverse).clip(lower=0.0) / repo

    return result


def prepare_members(
    members: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    """Canonicalize member concentration and funding-dependency inputs."""
    if members.empty:
        raise RepoFundingStressError("Synthetic member profile input is empty.")
    if "member_id" not in members.columns:
        raise RepoFundingStressError("Synthetic member profiles require member_id.")

    frame = _derive_member_ratios(members)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame["member_id"].duplicated().any():
        raise RepoFundingStressError("Synthetic member identifiers must be unique.")

    ratio_columns = [
        "member_concentration_ratio",
        "funding_dependency_ratio",
        "net_repo_dependency_ratio",
    ]
    for column in ratio_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise RepoFundingStressError(f"{column} contains missing or nonfinite values.")
        if ((frame[column] < 0.0) | (frame[column] > 1.0)).any():
            raise RepoFundingStressError(f"{column} must be between zero and one.")

    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame[
        [
            "member_id",
            "member_concentration_ratio",
            "funding_dependency_ratio",
            "net_repo_dependency_ratio",
            "value_class",
            "actual_ficc_participant",
            "participant_level_inference",
        ]
    ].sort_values("member_id", kind="stable").reset_index(drop=True)


def _scenario_frame(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    scenario: RepoFundingScenario,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    frame = baseline.merge(
        members[
            [
                "member_id",
                "member_concentration_ratio",
                "funding_dependency_ratio",
                "net_repo_dependency_ratio",
            ]
        ],
        on="member_id",
        how="left",
        validate="many_to_one",
    )
    if frame[
        [
            "member_concentration_ratio",
            "funding_dependency_ratio",
            "net_repo_dependency_ratio",
        ]
    ].isna().any().any():
        raise RepoFundingStressError(
            "Every baseline member must have a matching synthetic member profile."
        )

    frame["scenario_name"] = scenario.name
    frame["severity_rank"] = scenario.severity_rank
    frame["reference_sofr_percent"] = settings.reference_sofr_percent
    frame["sofr_spike_bp"] = scenario.sofr_spike_bp
    frame["funding_spread_increase_bp"] = scenario.funding_spread_increase_bp
    frame["stressed_sofr_percent"] = (
        settings.reference_sofr_percent + scenario.sofr_spike_bp / 100.0
    )
    frame["stressed_all_in_rate_percent"] = (
        frame["stressed_sofr_percent"]
        + scenario.funding_spread_increase_bp / 100.0
    )
    frame["refinancing_horizon_hours"] = scenario.refinancing_horizon_hours
    frame["refinancing_cycle_multiplier"] = (
        settings.baseline_liquidity_horizon_hours
        / float(scenario.refinancing_horizon_hours)
    )

    concentration_excess = (
        frame["member_concentration_ratio"] - scenario.concentration_threshold
    ).clip(lower=0.0)
    frame["funding_concentration_factor"] = (
        1.0 + scenario.concentration_multiplier * concentration_excess
    )
    frame["funding_dependency_factor"] = (
        1.0
        + scenario.funding_dependency_multiplier
        * frame["funding_dependency_ratio"]
        * frame["net_repo_dependency_ratio"]
    )

    base_unavailability = 1.0 - (
        (1.0 - scenario.repo_rollover_failure_rate)
        * (1.0 - scenario.lender_withdrawal_rate)
    )
    per_cycle_unavailability = (
        base_unavailability
        * frame["funding_concentration_factor"]
        * frame["funding_dependency_factor"]
    ).clip(
        lower=0.0,
        upper=scenario.max_effective_unavailability_rate,
    )
    frame["per_cycle_funding_unavailability_rate"] = per_cycle_unavailability
    effective_unavailability = 1.0 - (
        1.0 - per_cycle_unavailability
    ) ** frame["refinancing_cycle_multiplier"]
    frame["effective_funding_unavailability_rate"] = effective_unavailability.clip(
        lower=0.0,
        upper=scenario.max_effective_unavailability_rate,
    )

    frame["repo_rollover_failure_outflow_usd"] = (
        frame["repo_roll_amount_usd"]
        * frame["effective_funding_unavailability_rate"]
    )
    frame["successful_repo_refinancing_usd"] = (
        frame["repo_roll_amount_usd"]
        - frame["repo_rollover_failure_outflow_usd"]
    ).clip(lower=0.0)
    frame["stressed_financing_outflow_usd"] = (
        frame["financing_outflow_usd"]
        + frame["repo_rollover_failure_outflow_usd"]
    )

    incremental_rate_decimal = (
        scenario.sofr_spike_bp + scenario.funding_spread_increase_bp
    ) / 10_000.0
    funding_days = settings.baseline_liquidity_horizon_hours / 24.0
    frame["incremental_funding_cost_usd"] = (
        frame["successful_repo_refinancing_usd"]
        * incremental_rate_decimal
        * funding_days
        / float(settings.day_count_basis)
    )

    frame["additional_haircut_collateral_demand_usd"] = (
        frame["successful_repo_refinancing_usd"]
        * scenario.collateral_haircut_increase
        * frame["funding_concentration_factor"]
    )
    frame["additional_margin_call_usd"] = (
        frame["repo_maturity_usd"]
        * scenario.collateral_call_rate
        * frame["funding_dependency_factor"]
    )
    frame["additional_collateral_demand_usd"] = (
        frame["additional_haircut_collateral_demand_usd"]
        + frame["additional_margin_call_usd"]
    )
    frame["incremental_repo_funding_stress_outflow_usd"] = (
        frame["repo_rollover_failure_outflow_usd"]
        + frame["incremental_funding_cost_usd"]
        + frame["additional_collateral_demand_usd"]
    )
    frame["cumulative_incremental_repo_funding_stress_outflow_usd"] = frame.groupby(
        "member_id",
        sort=False,
    )["incremental_repo_funding_stress_outflow_usd"].cumsum()
    frame["stressed_total_cash_outflow_usd"] = (
        frame["total_cash_outflow_usd"]
        + frame["incremental_repo_funding_stress_outflow_usd"]
    )
    frame["stressed_cumulative_net_liquidity_need_usd"] = (
        frame["cumulative_net_liquidity_need_usd"]
        + frame["cumulative_incremental_repo_funding_stress_outflow_usd"]
    )
    frame["stressed_liquidity_headroom_usd"] = (
        frame["cumulative_available_resources_usd"]
        - frame["stressed_cumulative_net_liquidity_need_usd"]
    )
    frame["stressed_liquidity_shortfall_usd"] = (
        -frame["stressed_liquidity_headroom_usd"]
    ).clip(lower=0.0)
    frame["repo_rollover_failure_rate"] = scenario.repo_rollover_failure_rate
    frame["lender_withdrawal_rate"] = scenario.lender_withdrawal_rate
    frame["collateral_haircut_increase"] = scenario.collateral_haircut_increase
    frame["collateral_call_rate"] = scenario.collateral_call_rate
    frame["concentration_threshold"] = scenario.concentration_threshold
    frame["concentration_multiplier"] = scenario.concentration_multiplier
    frame["funding_dependency_multiplier"] = scenario.funding_dependency_multiplier
    frame["model_version"] = settings.model_version
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame


def _member_summary(
    detailed: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for (scenario_name, member_id), group in detailed.groupby(
        ["scenario_name", "member_id"],
        sort=True,
    ):
        ordered = group.sort_values("bucket_order", kind="stable")
        baseline_roll = float(ordered["repo_roll_amount_usd"].sum())
        failed_roll = float(
            ordered["repo_rollover_failure_outflow_usd"].sum()
        )
        baseline_peak = float(
            ordered["cumulative_net_liquidity_need_usd"].max()
        )
        stressed_peak = float(
            ordered["stressed_cumulative_net_liquidity_need_usd"].max()
        )
        available_resources = float(
            ordered["cumulative_available_resources_usd"].max()
        )
        stressed_shortfall = float(
            ordered["stressed_liquidity_shortfall_usd"].max()
        )
        first_shortfall = ordered.loc[
            ordered["stressed_liquidity_shortfall_usd"] > settings.tolerance_usd,
            "time_bucket",
        ]
        rows.append(
            {
                "scenario_name": str(scenario_name),
                "severity_rank": int(ordered["severity_rank"].iloc[0]),
                "member_id": str(member_id),
                "reference_sofr_percent": float(
                    ordered["reference_sofr_percent"].iloc[0]
                ),
                "stressed_sofr_percent": float(
                    ordered["stressed_sofr_percent"].iloc[0]
                ),
                "stressed_all_in_rate_percent": float(
                    ordered["stressed_all_in_rate_percent"].iloc[0]
                ),
                "refinancing_horizon_hours": int(
                    ordered["refinancing_horizon_hours"].iloc[0]
                ),
                "member_concentration_ratio": float(
                    ordered["member_concentration_ratio"].iloc[0]
                ),
                "funding_dependency_ratio": float(
                    ordered["funding_dependency_ratio"].iloc[0]
                ),
                "net_repo_dependency_ratio": float(
                    ordered["net_repo_dependency_ratio"].iloc[0]
                ),
                "baseline_repo_maturity_usd": float(
                    ordered["repo_maturity_usd"].sum()
                ),
                "baseline_repo_roll_amount_usd": baseline_roll,
                "effective_funding_unavailability_rate": (
                    failed_roll / baseline_roll if baseline_roll > 0.0 else 0.0
                ),
                "repo_rollover_failure_outflow_usd": failed_roll,
                "incremental_funding_cost_usd": float(
                    ordered["incremental_funding_cost_usd"].sum()
                ),
                "additional_collateral_demand_usd": float(
                    ordered["additional_collateral_demand_usd"].sum()
                ),
                "incremental_repo_funding_stress_outflow_usd": float(
                    ordered["incremental_repo_funding_stress_outflow_usd"].sum()
                ),
                "baseline_peak_liquidity_need_usd": baseline_peak,
                "stressed_peak_liquidity_need_usd": stressed_peak,
                "available_resources_usd": available_resources,
                "baseline_minimum_liquidity_headroom_usd": float(
                    ordered["liquidity_headroom_usd"].min()
                ),
                "stressed_minimum_liquidity_headroom_usd": float(
                    ordered["stressed_liquidity_headroom_usd"].min()
                ),
                "maximum_stressed_liquidity_shortfall_usd": stressed_shortfall,
                "stressed_liquidity_coverage_ratio": (
                    available_resources / max(stressed_peak, 0.01)
                ),
                "first_stressed_shortfall_bucket": (
                    str(first_shortfall.iloc[0]) if not first_shortfall.empty else ""
                ),
                "funding_stress_status": (
                    "COVERED"
                    if stressed_shortfall <= settings.tolerance_usd
                    else "SHORTFALL"
                ),
                "model_version": settings.model_version,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(rows).sort_values(
        ["severity_rank", "member_id"],
        kind="stable",
    ).reset_index(drop=True)


def _scenario_summary(member_summary: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for scenario_name, group in member_summary.groupby("scenario_name", sort=True):
        rows.append(
            {
                "scenario_name": str(scenario_name),
                "severity_rank": int(group["severity_rank"].iloc[0]),
                "member_count": int(group["member_id"].nunique()),
                "reference_sofr_percent": float(
                    group["reference_sofr_percent"].iloc[0]
                ),
                "stressed_sofr_percent": float(
                    group["stressed_sofr_percent"].iloc[0]
                ),
                "stressed_all_in_rate_percent": float(
                    group["stressed_all_in_rate_percent"].iloc[0]
                ),
                "refinancing_horizon_hours": int(
                    group["refinancing_horizon_hours"].iloc[0]
                ),
                "baseline_repo_maturity_usd": float(
                    group["baseline_repo_maturity_usd"].sum()
                ),
                "repo_rollover_failure_outflow_usd": float(
                    group["repo_rollover_failure_outflow_usd"].sum()
                ),
                "incremental_funding_cost_usd": float(
                    group["incremental_funding_cost_usd"].sum()
                ),
                "additional_collateral_demand_usd": float(
                    group["additional_collateral_demand_usd"].sum()
                ),
                "incremental_repo_funding_stress_outflow_usd": float(
                    group["incremental_repo_funding_stress_outflow_usd"].sum()
                ),
                "aggregate_stressed_peak_liquidity_need_usd": float(
                    group["stressed_peak_liquidity_need_usd"].sum()
                ),
                "aggregate_maximum_stressed_shortfall_usd": float(
                    group["maximum_stressed_liquidity_shortfall_usd"].sum()
                ),
                "members_with_shortfall": int(
                    group["funding_stress_status"].eq("SHORTFALL").sum()
                ),
                "maximum_member_shortfall_usd": float(
                    group["maximum_stressed_liquidity_shortfall_usd"].max()
                ),
                "model_version": str(group["model_version"].iloc[0]),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(rows).sort_values(
        "severity_rank",
        kind="stable",
    ).reset_index(drop=True)


def calculate_repo_funding_stress(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Apply every enabled scenario to Section 14 baseline cash flows."""
    prepared_baseline = prepare_baseline(baseline, settings)
    prepared_members = prepare_members(members, settings)
    member_ids = set(prepared_members["member_id"].astype(str))
    missing_members = sorted(
        set(prepared_baseline["member_id"].astype(str)) - member_ids
    )
    if missing_members:
        raise RepoFundingStressError(
            f"Baseline members are missing from member profiles: {missing_members}"
        )

    scenario_frames = [
        _scenario_frame(
            prepared_baseline,
            prepared_members,
            scenario,
            settings,
        )
        for scenario in settings.scenarios
    ]
    detailed = pd.concat(scenario_frames, ignore_index=True).sort_values(
        ["severity_rank", "member_id", "bucket_order"],
        kind="stable",
    ).reset_index(drop=True)
    member_summary = _member_summary(detailed, settings)
    scenario_summary = _scenario_summary(member_summary)
    return detailed, member_summary, scenario_summary


def _within_tolerance(
    left: pd.Series,
    right: pd.Series,
    tolerance: float,
) -> bool:
    differences = (
        pd.to_numeric(left, errors="coerce")
        - pd.to_numeric(right, errors="coerce")
    ).abs()
    return bool(differences.le(tolerance).all())


def validate_results(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    detailed: pd.DataFrame,
    member_summary: pd.DataFrame,
    scenario_summary: pd.DataFrame,
    settings: RepoFundingStressSettings,
) -> ValidationResult:
    """Validate Section 16 mechanics, accounting identities, and scope controls."""
    prepared_baseline = prepare_baseline(baseline, settings)
    prepared_members = prepare_members(members, settings)
    expected_rows = len(prepared_baseline) * len(settings.scenarios)
    expected_member_rows = (
        prepared_baseline["member_id"].nunique() * len(settings.scenarios)
    )

    scenario_requirements = {
        "sofr_rate_spikes_implemented": any(
            scenario.sofr_spike_bp > 0.0 for scenario in settings.scenarios
        ),
        "funding_cost_increases_implemented": any(
            scenario.funding_spread_increase_bp > 0.0
            for scenario in settings.scenarios
        ),
        "repo_rollover_failures_implemented": any(
            scenario.repo_rollover_failure_rate > 0.0
            for scenario in settings.scenarios
        ),
        "partial_lender_withdrawal_implemented": any(
            scenario.lender_withdrawal_rate > 0.0
            for scenario in settings.scenarios
        ),
        "shorter_refinancing_horizons_implemented": any(
            scenario.refinancing_horizon_hours
            < settings.baseline_liquidity_horizon_hours
            for scenario in settings.scenarios
        ),
        "increased_collateral_demands_implemented": any(
            scenario.collateral_haircut_increase > 0.0
            or scenario.collateral_call_rate > 0.0
            for scenario in settings.scenarios
        ),
        "funding_concentration_implemented": any(
            scenario.concentration_multiplier > 0.0
            for scenario in settings.scenarios
        ),
    }

    nonnegative_columns = [
        "repo_rollover_failure_outflow_usd",
        "successful_repo_refinancing_usd",
        "stressed_financing_outflow_usd",
        "incremental_funding_cost_usd",
        "additional_haircut_collateral_demand_usd",
        "additional_margin_call_usd",
        "additional_collateral_demand_usd",
        "incremental_repo_funding_stress_outflow_usd",
        "cumulative_incremental_repo_funding_stress_outflow_usd",
        "stressed_cumulative_net_liquidity_need_usd",
        "stressed_liquidity_shortfall_usd",
    ]
    nonnegative = bool(
        (detailed[nonnegative_columns] >= -settings.tolerance_usd).all().all()
    )
    rate_identity = _within_tolerance(
        detailed["stressed_sofr_percent"],
        detailed["reference_sofr_percent"] + detailed["sofr_spike_bp"] / 100.0,
        1e-12,
    )
    all_in_rate_identity = _within_tolerance(
        detailed["stressed_all_in_rate_percent"],
        detailed["stressed_sofr_percent"]
        + detailed["funding_spread_increase_bp"] / 100.0,
        1e-12,
    )
    rollover_bounded = bool(
        (
            detailed["repo_rollover_failure_outflow_usd"]
            <= detailed["repo_roll_amount_usd"] + settings.tolerance_usd
        ).all()
    )
    decomposition = _within_tolerance(
        detailed["incremental_repo_funding_stress_outflow_usd"],
        detailed["repo_rollover_failure_outflow_usd"]
        + detailed["incremental_funding_cost_usd"]
        + detailed["additional_collateral_demand_usd"],
        settings.tolerance_usd,
    )
    stressed_need_identity = _within_tolerance(
        detailed["stressed_cumulative_net_liquidity_need_usd"],
        detailed["cumulative_net_liquidity_need_usd"]
        + detailed["cumulative_incremental_repo_funding_stress_outflow_usd"],
        settings.tolerance_usd,
    )
    stressed_need_not_below_baseline = bool(
        (
            detailed["stressed_cumulative_net_liquidity_need_usd"]
            + settings.tolerance_usd
            >= detailed["cumulative_net_liquidity_need_usd"]
        ).all()
    )
    headroom_identity = _within_tolerance(
        detailed["stressed_liquidity_headroom_usd"],
        detailed["cumulative_available_resources_usd"]
        - detailed["stressed_cumulative_net_liquidity_need_usd"],
        settings.tolerance_usd,
    )
    shortfall_identity = _within_tolerance(
        detailed["stressed_liquidity_shortfall_usd"],
        (-detailed["stressed_liquidity_headroom_usd"]).clip(lower=0.0),
        settings.tolerance_usd,
    )
    synthetic_only = bool(
        detailed["value_class"].eq("synthetic").all()
        and not detailed["actual_ficc_participant"].astype(bool).any()
        and not detailed["participant_level_inference"].astype(bool).any()
        and member_summary["value_class"].eq("synthetic").all()
        and scenario_summary["value_class"].eq("synthetic").all()
        and len(prepared_members) >= prepared_baseline["member_id"].nunique()
    )

    checks = {
        **scenario_requirements,
        "scenario_cashflow_rows_complete": len(detailed) == expected_rows,
        "member_scenario_rows_complete": len(member_summary) == expected_member_rows,
        "scenario_summary_complete": len(scenario_summary) == len(settings.scenarios),
        "unique_scenario_member_buckets": not detailed.duplicated(
            ["scenario_name", "member_id", "time_bucket"]
        ).any(),
        "nonnegative_stress_components": nonnegative,
        "sofr_rate_identity": rate_identity,
        "all_in_funding_rate_identity": all_in_rate_identity,
        "rollover_failure_bounded_by_roll_amount": rollover_bounded,
        "funding_stress_decomposition_identity": decomposition,
        "stressed_liquidity_need_identity": stressed_need_identity,
        "stressed_need_not_below_baseline": stressed_need_not_below_baseline,
        "stressed_headroom_identity": headroom_identity,
        "stressed_shortfall_identity": shortfall_identity,
        "synthetic_members_only": synthetic_only,
    }
    return ValidationResult(checks=checks)


def run_model(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, ValidationResult]:
    """Run the deterministic Section 16 model and validate all outputs."""
    settings = load_settings(config)
    detailed, member_summary, scenario_summary = calculate_repo_funding_stress(
        baseline,
        members,
        settings,
    )
    validation = validate_results(
        baseline,
        members,
        detailed,
        member_summary,
        scenario_summary,
        settings,
    )

    shuffled_baseline = baseline.sample(
        frac=1.0,
        random_state=2026,
    ).reset_index(drop=True)
    shuffled_members = members.sample(
        frac=1.0,
        random_state=2026,
    ).reset_index(drop=True)
    repeated = calculate_repo_funding_stress(
        shuffled_baseline,
        shuffled_members,
        settings,
    )
    deterministic = (
        detailed.equals(repeated[0])
        and member_summary.equals(repeated[1])
        and scenario_summary.equals(repeated[2])
    )
    checks = dict(validation.checks)
    checks["deterministic_reproduction"] = deterministic
    return detailed, member_summary, scenario_summary, ValidationResult(checks=checks)


__all__ = [
    "RepoFundingScenario",
    "RepoFundingStressError",
    "RepoFundingStressSettings",
    "ValidationResult",
    "calculate_repo_funding_stress",
    "load_config",
    "load_settings",
    "prepare_baseline",
    "prepare_members",
    "read_table",
    "run_model",
    "validate_results",
]
'@
    $RunnerContent = @'
"""Run Phase V Section 16 repo funding-stress analysis."""

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

from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    RepoFundingStressError,
    load_config,
    read_table,
    run_model,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Run Phase V Section 16 repo funding-stress analysis."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "repo_funding_stress.yaml",
    )
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--sofr-input", type=Path, default=None)
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
        default=ROOT / "data" / "manifests" / "repo_funding_stress_manifest.csv",
    )
    parser.add_argument(
        "--allow-demo",
        action="store_true",
        help="Use controlled synthetic smoke data when project inputs are unavailable.",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Label generated evidence as a controlled smoke-test run.",
    )
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RepoFundingStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing candidate path."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _demo_members() -> pd.DataFrame:
    """Create controlled fictional member profiles for smoke testing."""
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
            "as_of_date": ["2026-06-30"] * 3,
            "value_class": ["synthetic"] * 3,
            "actual_ficc_participant": [False] * 3,
            "participant_level_inference": [False] * 3,
            "member_concentration_ratio": [0.18, 0.35, 0.58],
            "funding_dependency_ratio": [0.30, 0.62, 0.88],
            "net_repo_dependency_ratio": [0.45, 0.70, 0.92],
        }
    )


def _demo_baseline() -> pd.DataFrame:
    """Create controlled Section 14-compatible cash flows for smoke testing."""
    rows: list[dict[str, object]] = []
    buckets = (
        ("day1_open", 0, 0.20),
        ("day1_midday", 6, 0.30),
        ("day1_close", 12, 0.30),
        ("day2_open", 24, 0.15),
        ("day2_close", 48, 0.05),
    )
    for member_number, scale in ((1, 1.00), (2, 1.35), (3, 1.80)):
        member_id = f"SYN-MBR-{member_number:04d}"
        cumulative_need = 0.0
        available_resources = 320_000_000.0 * scale
        for bucket_order, (bucket, elapsed_hours, weight) in enumerate(
            buckets,
            start=1,
        ):
            repo_maturity = 500_000_000.0 * scale * weight
            repo_roll = repo_maturity * 0.80
            financing_outflow = repo_maturity - repo_roll
            settlement_outflow = 65_000_000.0 * scale * weight
            total_outflow = financing_outflow + settlement_outflow
            cumulative_need += total_outflow
            headroom = available_resources - cumulative_need
            rows.append(
                {
                    "member_id": member_id,
                    "as_of_date": "2026-06-30",
                    "bucket_order": bucket_order,
                    "time_bucket": bucket,
                    "elapsed_hours": elapsed_hours,
                    "liquidity_horizon_hours": 48,
                    "repo_maturity_usd": repo_maturity,
                    "repo_roll_amount_usd": repo_roll,
                    "financing_outflow_usd": financing_outflow,
                    "total_cash_outflow_usd": total_outflow,
                    "cumulative_net_liquidity_need_usd": cumulative_need,
                    "cumulative_available_resources_usd": available_resources,
                    "liquidity_headroom_usd": headroom,
                    "liquidity_shortfall_usd": max(-headroom, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def _latest_sofr_from_table(
    frame: pd.DataFrame,
    date_candidates: list[str],
    value_candidates: list[str],
) -> tuple[float, str]:
    """Extract the latest nonmissing SOFR observation in percent units."""
    value_column = next(
        (column for column in value_candidates if column in frame.columns),
        None,
    )
    if value_column is None:
        raise RepoFundingStressError(
            f"No configured SOFR value column was found; candidates={value_candidates}."
        )

    date_column = next(
        (column for column in date_candidates if column in frame.columns),
        None,
    )
    working = frame.copy(deep=True)
    working[value_column] = pd.to_numeric(
        working[value_column],
        errors="coerce",
    )
    working = working.dropna(subset=[value_column])
    if working.empty:
        raise RepoFundingStressError("SOFR input has no usable numeric observations.")

    if date_column is not None:
        working[date_column] = pd.to_datetime(
            working[date_column],
            errors="coerce",
        )
        working = working.dropna(subset=[date_column]).sort_values(
            date_column,
            kind="stable",
        )
        if working.empty:
            raise RepoFundingStressError("SOFR input has no usable dated observations.")
        observation_label = str(working[date_column].iloc[-1].date())
    else:
        observation_label = "latest_row"

    value = float(working[value_column].iloc[-1])
    if value < 0.0:
        raise RepoFundingStressError("SOFR observations cannot be negative.")
    return value, f"{value_column}@{observation_label}"


def resolve_reference_sofr(
    config: dict[str, Any],
    explicit_path: Path | None,
) -> tuple[float, str]:
    """Resolve observed SOFR where available, otherwise use the controlled fallback."""
    sofr = _mapping(config.get("sofr"), "sofr")
    candidates = [str(item) for item in sofr.get("input_candidates", [])]
    path = explicit_path or discover_input(ROOT, candidates)
    fallback = float(sofr.get("fallback_reference_percent", 0.0))

    if path is None:
        return fallback, "ASSUMED_CONFIG_FALLBACK"
    try:
        value, observation = _latest_sofr_from_table(
            read_table(path),
            [str(item) for item in sofr.get("date_column_candidates", [])],
            [str(item) for item in sofr.get("value_column_candidates", [])],
        )
    except (RepoFundingStressError, ValueError, TypeError) as exc:
        print(f"SOFR observation fallback used: {exc}")
        return fallback, f"ASSUMED_CONFIG_FALLBACK_AFTER_{path.name}"
    return value, f"{path.resolve()}::{observation}"


def dataframe_hash(frame: pd.DataFrame) -> str:
    """Calculate a deterministic SHA-256 hash for a tabular result."""
    ordered = frame.sort_index(axis=1)
    sort_columns = [
        column
        for column in (
            "severity_rank",
            "scenario_name",
            "member_id",
            "bucket_order",
        )
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def file_hash(path: Path) -> str:
    """Calculate a file SHA-256 hash."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_frame(
    frame: pd.DataFrame,
    stem: Path,
    *,
    write_parquet: bool,
) -> list[Path]:
    """Write controlled CSV and optional Parquet outputs."""
    written: list[Path] = []
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


def write_manifest(
    manifest_path: Path,
    files: list[tuple[Path, str, int | None]],
) -> None:
    """Write source-lineage and output-integrity metadata."""
    records: list[dict[str, object]] = []
    for path, value_class, row_count in files:
        records.append(
            {
                "section": 16,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "value_class": value_class,
                "row_count": row_count if row_count is not None else "",
                "sha256": file_hash(path),
                "generated_at_utc": datetime.now(UTC).isoformat(),
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(records).to_csv(manifest_path, index=False)


def main() -> int:
    """Execute the controlled Section 16 workflow."""
    args = parse_args()
    config = load_config(args.config)
    source = _mapping(config.get("source"), "source")
    output = _mapping(config.get("output"), "output")

    baseline_path = args.baseline or discover_input(
        ROOT,
        [str(item) for item in source.get("baseline_cashflow_candidates", [])],
    )
    member_path = args.members or discover_input(
        ROOT,
        [str(item) for item in source.get("member_profile_candidates", [])],
    )

    if baseline_path is None or member_path is None:
        if not args.allow_demo:
            raise FileNotFoundError(
                "Section 14 baseline cash flows and Section 12 synthetic member profiles "
                "are required. Supply --baseline and --members, or use --allow-demo only "
                "for controlled smoke testing."
            )
        baseline = _demo_baseline()
        members = _demo_members()
        baseline_source = "CONTROLLED_SYNTHETIC_BASELINE_SMOKE_DATA"
        member_source = "CONTROLLED_SYNTHETIC_MEMBER_SMOKE_DATA"
    else:
        baseline = read_table(baseline_path)
        members = read_table(member_path)
        baseline_source = str(baseline_path.resolve())
        member_source = str(member_path.resolve())

    reference_sofr, sofr_source = resolve_reference_sofr(
        config,
        args.sofr_input,
    )
    assumptions = _mapping(config.get("assumptions"), "assumptions")
    assumptions["reference_sofr_percent"] = reference_sofr

    detailed, member_summary, scenario_summary, validation = run_model(
        baseline,
        members,
        config,
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    suffix = "_smoke" if args.smoke else ""
    write_parquet = bool(output.get("write_parquet", True))

    output_files: list[Path] = []
    output_files.extend(
        write_frame(
            detailed,
            args.output_dir / f"repo_funding_stress_cashflows{suffix}",
            write_parquet=write_parquet,
        )
    )
    output_files.extend(
        write_frame(
            member_summary,
            args.output_dir / f"repo_funding_stress_member_summary{suffix}",
            write_parquet=write_parquet,
        )
    )
    output_files.extend(
        write_frame(
            scenario_summary,
            args.output_dir / f"repo_funding_stress_scenario_summary{suffix}",
            write_parquet=write_parquet,
        )
    )

    gates = {
        label.replace("_", " ").title(): "PASS" if passed else "FAIL"
        for label, passed in validation.checks.items()
    }
    run_timestamp = datetime.now(UTC).isoformat()
    run_type = "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN"

    evidence = {
        "section": 16,
        "model": config.get("model_name", "repo_funding_stress"),
        "model_version": config.get("model_version", "section-16-v1"),
        "run_timestamp_utc": run_timestamp,
        "run_type": run_type,
        "baseline_source": baseline_source,
        "member_source": member_source,
        "sofr_source": sofr_source,
        "reference_sofr_percent": reference_sofr,
        "cashflow_rows": len(detailed),
        "member_scenario_rows": len(member_summary),
        "scenario_rows": len(scenario_summary),
        "scenario_names": scenario_summary["scenario_name"].tolist(),
        "result_sha256": dataframe_hash(detailed),
        "gates": gates,
        "limitations": [
            "All member-level records are synthetic and do not represent actual FICC participants.",
            (
                "SOFR spikes, lender withdrawal, rollover failure, collateral demand, "
                "and concentration parameters are explicit stress assumptions."
            ),
            (
                "Incremental funding costs use a simple annualized day-count approximation "
                "rather than contractual repricing."
            ),
            (
                "The model overlays Section 16 stress on Section 14 cash flows and does not "
                "infer bilateral lender identities."
            ),
        ],
    }

    evidence_json = args.evidence_dir / f"section16_repo_funding_stress{suffix}.json"
    evidence_json.write_text(
        json.dumps(evidence, indent=2),
        encoding="utf-8",
    )
    evidence_md = args.evidence_dir / f"section16_repo_funding_stress{suffix}.md"
    gate_lines = "\n".join(
        f"- {name}: **{status}**" for name, status in gates.items()
    )
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 16 Repo Funding-Stress Evidence",
                "",
                f"- Run timestamp (UTC): {run_timestamp}",
                f"- Run type: {run_type}",
                f"- Baseline source: `{baseline_source}`",
                f"- Synthetic member source: `{member_source}`",
                f"- SOFR source: `{sofr_source}`",
                f"- Reference SOFR: {reference_sofr:.4f} percent",
                f"- Cash-flow scenario rows: {len(detailed):,}",
                f"- Result SHA-256: `{evidence['result_sha256']}`",
                "",
                "## Completion gates",
                "",
                gate_lines,
                "",
                "## Scope limitation",
                "",
                "All member records are fictional and synthetic. No output identifies, "
                "represents, or infers an actual FICC participant or bilateral lender.",
                "",
            ]
        ),
        encoding="utf-8",
    )

    manifest_files: list[tuple[Path, str, int | None]] = [
        (args.config, "assumed", None),
        *[
            (
                path,
                "modeled",
                (
                    len(detailed)
                    if "cashflows" in path.name
                    else len(member_summary)
                    if "member_summary" in path.name
                    else len(scenario_summary)
                ),
            )
            for path in output_files
        ],
        (evidence_json, "modeled", None),
        (evidence_md, "modeled", None),
    ]
    if baseline_path is not None:
        manifest_files.append((baseline_path, "modeled", len(baseline)))
    if member_path is not None:
        manifest_files.append((member_path, "synthetic", len(members)))
    write_manifest(args.manifest, manifest_files)

    print(scenario_summary.to_string(index=False))
    print("")
    print("Completion gates:")
    for name, status in gates.items():
        print(f"  {name}: {status}")
    print(f"\nEvidence: {evidence_md}")
    print(f"Manifest: {args.manifest}")

    if any(status != "PASS" for status in gates.values()):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@
    $TestContent = @'
from __future__ import annotations

from copy import deepcopy
import math
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.stress import repo_funding_stress as model


def _config() -> dict[str, Any]:
    return cast(
        dict[str, Any],
        yaml.safe_load(
            (Path(__file__).parents[1] / "configs" / "repo_funding_stress.yaml").read_text(
                encoding="utf-8"
            )
        ),
    )


def _members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
            "member_concentration_ratio": [0.20, 0.55],
            "funding_dependency_ratio": [0.40, 0.85],
            "net_repo_dependency_ratio": [0.50, 0.90],
        }
    )


def _baseline() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for member_id, scale in (("SYN-MBR-0001", 1.0), ("SYN-MBR-0002", 1.4)):
        for bucket_order, (bucket, elapsed, repo, roll, financing, need, resources) in enumerate(
            (
                ("day1_open", 0, 100.0, 80.0, 20.0, 150.0, 120.0),
                ("day1_close", 12, 150.0, 120.0, 30.0, 240.0, 220.0),
                ("day2_close", 48, 250.0, 200.0, 50.0, 300.0, 350.0),
            ),
            start=1,
        ):
            baseline_need = need * scale
            available = resources * scale
            headroom = available - baseline_need
            rows.append(
                {
                    "member_id": member_id,
                    "bucket_order": bucket_order,
                    "time_bucket": bucket,
                    "elapsed_hours": elapsed,
                    "liquidity_horizon_hours": 48,
                    "repo_maturity_usd": repo * scale,
                    "repo_roll_amount_usd": roll * scale,
                    "financing_outflow_usd": financing * scale,
                    "total_cash_outflow_usd": (financing + 50.0) * scale,
                    "cumulative_net_liquidity_need_usd": baseline_need,
                    "cumulative_available_resources_usd": available,
                    "liquidity_headroom_usd": headroom,
                    "liquidity_shortfall_usd": max(-headroom, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def test_model_runs_all_scenarios_and_passes_validation() -> None:
    detailed, members, scenarios, validation = model.run_model(
        _baseline(),
        _members(),
        _config(),
    )

    assert validation.passed
    assert len(detailed) == len(_baseline()) * 4
    assert len(members) == 8
    assert len(scenarios) == 4
    assert scenarios["scenario_name"].tolist() == [
        "control",
        "moderate_market_stress",
        "severe_market_stress",
        "concentrated_funding_freeze",
    ]


def test_control_scenario_preserves_baseline_liquidity_need() -> None:
    detailed, _, _, _ = model.run_model(_baseline(), _members(), _config())
    control = detailed.loc[detailed["scenario_name"] == "control"]

    assert control["incremental_repo_funding_stress_outflow_usd"].eq(0.0).all()
    assert control["stressed_cumulative_net_liquidity_need_usd"].tolist() == pytest.approx(
        control["cumulative_net_liquidity_need_usd"].tolist()
    )


def test_rate_spike_and_funding_spread_are_translated_to_costs() -> None:
    detailed, _, _, _ = model.run_model(_baseline(), _members(), _config())
    severe = detailed.loc[detailed["scenario_name"] == "severe_market_stress"]

    assert severe["stressed_sofr_percent"].eq(7.0).all()
    assert severe["stressed_all_in_rate_percent"].eq(8.5).all()
    assert (severe["incremental_funding_cost_usd"] > 0.0).all()


def test_rollover_failure_withdrawal_and_shorter_horizon_raise_unavailability() -> None:
    _, member_summary, _, _ = model.run_model(_baseline(), _members(), _config())
    pivot = member_summary.pivot(
        index="member_id",
        columns="scenario_name",
        values="effective_funding_unavailability_rate",
    )

    assert (
        pivot["moderate_market_stress"] < pivot["severe_market_stress"]
    ).all()
    assert (
        pivot["severe_market_stress"] < pivot["concentrated_funding_freeze"]
    ).all()


def test_concentrated_dependent_member_has_larger_stress_rate() -> None:
    _, member_summary, _, _ = model.run_model(_baseline(), _members(), _config())
    moderate = member_summary.loc[
        member_summary["scenario_name"] == "moderate_market_stress"
    ].set_index("member_id")

    member_2_rate = cast(
        float,
        moderate.at[
            "SYN-MBR-0002",
            "effective_funding_unavailability_rate",
        ],
    )
    member_1_rate = cast(
        float,
        moderate.at[
            "SYN-MBR-0001",
            "effective_funding_unavailability_rate",
        ],
    )

    assert member_2_rate > member_1_rate


def test_collateral_demands_are_added_to_funding_stress() -> None:
    detailed, _, _, _ = model.run_model(_baseline(), _members(), _config())
    stressed = detailed.loc[detailed["scenario_name"] != "control"]

    assert (stressed["additional_collateral_demand_usd"] > 0.0).all()
    assert stressed["incremental_repo_funding_stress_outflow_usd"].tolist() == pytest.approx(
        (
            stressed["repo_rollover_failure_outflow_usd"]
            + stressed["incremental_funding_cost_usd"]
            + stressed["additional_collateral_demand_usd"]
        ).tolist()
    )


def test_model_is_deterministic_for_input_row_order() -> None:
    first = model.run_model(_baseline(), _members(), _config())
    second = model.run_model(
        _baseline().iloc[::-1].reset_index(drop=True),
        _members().iloc[::-1].reset_index(drop=True),
        _config(),
    )

    assert first[0].equals(second[0])
    assert first[1].equals(second[1])
    assert first[2].equals(second[2])
    assert first[3].passed and second[3].passed


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("repo_rollover_failure_rate", 1.1, "between zero and one"),
        ("lender_withdrawal_rate", -0.1, "between zero and one"),
        ("refinancing_horizon_hours", 72, "cannot exceed"),
        ("funding_spread_increase_bp", -1.0, "nonnegative"),
        ("severity_rank", -1, "nonnegative"),
    ],
)
def test_invalid_scenario_assumptions_are_rejected(
    field: str,
    value: object,
    message: str,
) -> None:
    config = deepcopy(_config())
    config["scenarios"][1][field] = value

    with pytest.raises(model.RepoFundingStressError, match=message):
        model.load_settings(config)


def test_duplicate_scenario_names_and_ranks_are_rejected() -> None:
    duplicate_name = deepcopy(_config())
    duplicate_name["scenarios"][1]["name"] = "control"
    with pytest.raises(model.RepoFundingStressError, match="names must be unique"):
        model.load_settings(duplicate_name)

    duplicate_rank = deepcopy(_config())
    duplicate_rank["scenarios"][1]["severity_rank"] = 0
    with pytest.raises(model.RepoFundingStressError, match="ranks must be unique"):
        model.load_settings(duplicate_rank)


@pytest.mark.parametrize(
    ("target", "column", "value", "message"),
    [
        ("baseline", "member_id", "REAL-MEMBER", "Non-synthetic"),
        ("members", "actual_ficc_participant", True, "Actual FICC"),
        ("members", "funding_dependency_ratio", 1.1, "between zero and one"),
        ("baseline", "repo_roll_amount_usd", -1.0, "negative"),
    ],
)
def test_invalid_inputs_are_rejected(
    target: str,
    column: str,
    value: object,
    message: str,
) -> None:
    baseline = _baseline()
    members = _members()
    if target == "baseline":
        baseline.loc[0, column] = cast(Any, value)
    else:
        members.loc[0, column] = cast(Any, value)

    with pytest.raises(model.RepoFundingStressError, match=message):
        model.run_model(baseline, members, _config())


def test_missing_member_profile_is_rejected() -> None:
    members = _members().iloc[:1].copy()
    with pytest.raises(model.RepoFundingStressError, match="missing from member profiles"):
        model.run_model(_baseline(), members, _config())


def test_member_ratios_can_be_derived_from_synthetic_source_fields() -> None:
    members = pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "treasury_position_bills_0_1y_usd": [60.0, 40.0],
            "treasury_position_notes_1_3y_usd": [40.0, 60.0],
            "total_treasury_position_usd": [100.0, 100.0],
            "repo_financing_need_usd": [50.0, 80.0],
            "reverse_repo_position_usd": [10.0, 20.0],
            "treasury_transaction_activity_usd": [100.0, 100.0],
        }
    )
    settings = model.load_settings(_config())
    prepared = model.prepare_members(members, settings)

    assert prepared["member_concentration_ratio"].tolist() == pytest.approx([0.6, 0.6])
    assert prepared["funding_dependency_ratio"].tolist() == pytest.approx([0.5, 0.8])
    assert prepared["net_repo_dependency_ratio"].tolist() == pytest.approx([0.8, 0.75])


def test_read_table_supports_csv_and_rejects_other_formats(tmp_path: Path) -> None:
    csv_path = tmp_path / "input.csv"
    _members().to_csv(csv_path, index=False)
    assert len(model.read_table(csv_path)) == 2

    invalid_path = tmp_path / "input.txt"
    invalid_path.write_text("x", encoding="utf-8")
    with pytest.raises(model.RepoFundingStressError, match="CSV or Parquet"):
        model.read_table(invalid_path)


def test_configuration_loader_rejects_missing_and_nonmapping_files(tmp_path: Path) -> None:
    missing = tmp_path / "missing.yaml"
    with pytest.raises(model.RepoFundingStressError, match="does not exist"):
        model.load_config(missing)

    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(model.RepoFundingStressError, match="must be a YAML mapping"):
        model.load_config(invalid)


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda config: config.update({"scenarios": []}), "nonempty list"),
        (
            lambda config: config["assumptions"].update(
                {"baseline_liquidity_horizon_hours": 0}
            ),
            "must be positive",
        ),
        (
            lambda config: [
                scenario.update({"enabled": False}) for scenario in config["scenarios"]
            ],
            "enabled scenario",
        ),
        (
            lambda config: config.update({"model_version": ""}),
            "model_version",
        ),
        (
            lambda config: config["assumptions"].update(
                {"reference_sofr_percent": -0.1}
            ),
            "reference_sofr_percent",
        ),
        (
            lambda config: config["assumptions"].update({"day_count_basis": 0}),
            "day_count_basis",
        ),
        (
            lambda config: config["validation"].update(
                {"reconciliation_tolerance_usd": -0.1}
            ),
            "reconciliation_tolerance",
        ),
        (
            lambda config: config["scenarios"][1].update({"name": ""}),
            "nonempty name",
        ),
        (
            lambda config: config["scenarios"][1].update({"sofr_spike_bp": -1.0}),
            "sofr_spike_bp",
        ),
        (
            lambda config: config["scenarios"][1].update(
                {"refinancing_horizon_hours": 0}
            ),
            "must be positive",
        ),
        (
            lambda config: config["scenarios"][1].update(
                {"concentration_multiplier": -1.0}
            ),
            "concentration_multiplier",
        ),
        (
            lambda config: config["scenarios"][1].update(
                {"funding_dependency_multiplier": -1.0}
            ),
            "funding_dependency_multiplier",
        ),
        (
            lambda config: config["scenarios"][1].update(
                {"funding_spread_increase_bp": math.nan}
            ),
            "must be finite",
        ),
        (
            lambda config: config["scenarios"][1].update(
                {"severity_rank": 1.5}
            ),
            "must be an integer",
        ),
    ],
)
def test_additional_invalid_configurations_are_rejected(
    mutation: Any,
    message: str,
) -> None:
    config = deepcopy(_config())
    mutation(config)
    with pytest.raises(model.RepoFundingStressError, match=message):
        model.load_settings(config)


def test_disabled_scenario_is_excluded() -> None:
    config = deepcopy(_config())
    config["scenarios"][3]["enabled"] = False
    settings = model.load_settings(config)
    assert [scenario.name for scenario in settings.scenarios] == [
        "control",
        "moderate_market_stress",
        "severe_market_stress",
    ]


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda frame: frame.drop(frame.index), "input is empty"),
        (
            lambda frame: frame.drop(columns="repo_maturity_usd"),
            "Required baseline",
        ),
        (
            lambda frame: pd.concat([frame, frame.iloc[[0]]], ignore_index=True),
            "must be unique",
        ),
        (
            lambda frame: frame.assign(repo_maturity_usd=float("nan")),
            "missing or nonfinite",
        ),
        (
            lambda frame: frame.assign(liquidity_horizon_hours=24),
            "do not match",
        ),
        (
            lambda frame: frame.assign(participant_level_inference=True),
            "Participant-level inference",
        ),
        (
            lambda frame: frame.assign(value_class="observed"),
            "value_class",
        ),
    ],
)
def test_additional_invalid_baselines_are_rejected(
    mutation: Any,
    message: str,
) -> None:
    settings = model.load_settings(_config())
    with pytest.raises(model.RepoFundingStressError, match=message):
        model.prepare_baseline(mutation(_baseline()), settings)


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda frame: frame.drop(frame.index), "input is empty"),
        (lambda frame: frame.drop(columns="member_id"), "require member_id"),
        (
            lambda frame: pd.concat([frame, frame.iloc[[0]]], ignore_index=True),
            "must be unique",
        ),
        (
            lambda frame: frame.assign(member_concentration_ratio=float("nan")),
            "missing or nonfinite",
        ),
        (
            lambda frame: frame.assign(participant_level_inference=True),
            "Participant-level inference",
        ),
        (
            lambda frame: frame.assign(value_class="assumed"),
            "value_class",
        ),
    ],
)
def test_additional_invalid_member_profiles_are_rejected(
    mutation: Any,
    message: str,
) -> None:
    settings = model.load_settings(_config())
    with pytest.raises(model.RepoFundingStressError, match=message):
        model.prepare_members(mutation(_members()), settings)


def test_ratio_derivation_requires_source_fields() -> None:
    settings = model.load_settings(_config())

    no_treasury = _members().drop(columns="member_concentration_ratio")
    with pytest.raises(model.RepoFundingStressError, match="cannot be derived"):
        model.prepare_members(no_treasury, settings)

    incomplete = _members().drop(columns="funding_dependency_ratio")
    with pytest.raises(model.RepoFundingStressError, match="cannot be derived"):
        model.prepare_members(incomplete, settings)

    incomplete_net = _members().drop(columns="net_repo_dependency_ratio")
    with pytest.raises(model.RepoFundingStressError, match="cannot be derived"):
        model.prepare_members(incomplete_net, settings)


def test_read_table_rejects_missing_path(tmp_path: Path) -> None:
    with pytest.raises(model.RepoFundingStressError, match="does not exist"):
        model.read_table(tmp_path / "missing.csv")
'@
    $MethodologyContent = @'
# Repo Funding-Stress Model Methodology

## Purpose

Phase V, Section 16 overlays repo-market funding stress on the controlled
Section 14 baseline liquidity cash-flow engine. The model measures how higher
SOFR, wider funding spreads, failed repo rollovers, lender withdrawal, shorter
refinancing horizons, collateral calls, and member funding concentration alter
time-bucketed liquidity needs, headroom, and shortfalls.

The model operates only on fictional synthetic clearing-member records. It does
not identify, represent, rank, or infer any actual FICC participant or bilateral
repo lender.

## Controlled inputs

The runner uses:

- `reports/tables/baseline_liquidity_cashflows.csv` or Parquet from Section 14;
- `data/synthetic/calibrated_member_portfolios.parquet` from Section 12;
- the latest usable SOFR observation in the processed Federal Reserve dataset,
  when available;
- `configs/repo_funding_stress.yaml` for explicit scenario assumptions.

When a usable SOFR observation is unavailable, the runner uses the separately
identified assumed fallback in the configuration and records that fallback in
the evidence file.

## Stress mechanics

For member \(i\), time bucket \(t\), and scenario \(s\), the model starts from
the Section 14 repo amount expected to roll, \(R_{i,t}\).

### Funding unavailability

The base one-cycle funding-unavailability probability combines rollover failure
and lender withdrawal:

\[
u_s = 1 - (1-f_s)(1-w_s),
\]

where \(f_s\) is the repo-rollover failure rate and \(w_s\) is the lender
withdrawal rate.

The model then applies explicit member concentration and funding-dependency
multipliers:

\[
\tilde u_{i,s} =
\min\left(
u_s C_{i,s} D_{i,s},
u_s^{\max}
\right).
\]

The refinancing-cycle multiplier is the baseline liquidity horizon divided by
the stressed refinancing horizon. Effective unavailability is:

\[
U_{i,s} =
\min\left(
1-(1-\tilde u_{i,s})^{N_s},
u_s^{\max}
\right).
\]

The failed rollover outflow is \(R_{i,t}U_{i,s}\).

### SOFR and funding-cost shock

The stressed reference rate is the reference SOFR plus the scenario SOFR shock.
The stressed all-in rate also includes the scenario funding-spread increase.
Incremental funding cost is calculated on successfully refinanced repo using an
annualized Actual/360-style approximation over the baseline liquidity horizon.

### Increased collateral demand

Additional collateral demand includes:

1. an increased haircut applied to successfully refinanced repo and amplified
   by the concentration factor; and
2. an additional collateral or margin call applied to repo maturities and
   amplified by funding dependency.

### Liquidity aggregation

Incremental repo funding-stress outflow is the sum of:

- failed rollover outflow;
- incremental funding cost; and
- additional collateral demand.

The model accumulates this incremental outflow through the Section 14 payment
buckets and recalculates stressed liquidity need, headroom, shortfall, and
coverage.

## Controlled scenarios

The default configuration includes:

- a zero-shock control;
- moderate market stress;
- severe market stress; and
- a concentrated funding freeze.

All parameters are configurable. Scenario ranks, names, and enabled states are
validated, and no enabled scenario can use a refinancing horizon longer than
the baseline horizon.

## Validation controls

The Section 16 implementation validates:

- all seven required stress channels;
- complete scenario-member-time-bucket output;
- unique scenario/member/time-bucket keys;
- nonnegative stress components;
- SOFR and all-in rate identities;
- rollover failure bounded by the baseline roll amount;
- exact stress-component decomposition;
- stressed need, headroom, and shortfall identities;
- deterministic reproduction independent of input row order; and
- synthetic-only member identity controls.

## Limitations

- The model is a deterministic scenario overlay, not a behavioral equilibrium
  model of the repo market.
- Funding costs use a simplified day-count approximation rather than
  instrument-level contractual repricing.
- Bilateral lender identities, contractual haircuts, maturity terms, and
  participant-specific liquidity resources are unavailable in public aggregate
  data.
- Concentration and dependency multipliers are model assumptions requiring
  sensitivity analysis and independent validation.
- Section 16 results must not be interpreted as estimates for any actual FICC
  participant.
'@

    Write-Utf8File -Path "configs\repo_funding_stress.yaml" -Content $ConfigContent
    Write-Utf8File -Path "src\ficc_liquidity\stress\__init__.py" -Content $InitContent
    Write-Utf8File `
        -Path "src\ficc_liquidity\stress\repo_funding_stress.py" `
        -Content $ModuleContent
    Write-Utf8File -Path "scripts\run_repo_funding_stress.py" -Content $RunnerContent
    Write-Utf8File -Path "tests\test_repo_funding_stress.py" -Content $TestContent
    Write-Utf8File `
        -Path "docs\repo_funding_stress_methodology.md" `
        -Content $MethodologyContent

    Write-Pass "Section 16 source, configuration, tests, runner, and methodology created"

    Write-Step "Resolving the Python 3.11 project environment"
    $Python = Join-Path $RepoPath ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw @"
The project virtual environment was not found:
$Python

Open the repository in VS Code and restore the Section 3 environment first.
"@
    }

    Invoke-Checked -FilePath $Python `
        -ArgumentList @("--version") `
        -FailureMessage "The project Python interpreter is unavailable."

    $versionText = & $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect the project Python version."
    }
    if (([string]$versionText).Trim() -ne "3.11") {
        throw "Section 16 requires Python 3.11. Found: $versionText"
    }
    Write-Pass "Python 3.11 virtual environment confirmed"

    $newPythonFiles = @(
        "src\ficc_liquidity\stress\__init__.py",
        "src\ficc_liquidity\stress\repo_funding_stress.py",
        "scripts\run_repo_funding_stress.py",
        "tests\test_repo_funding_stress.py"
    )

    Write-Step "Formatting and linting the Section 16 implementation"
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "format") + $newPythonFiles) `
        -FailureMessage "Ruff formatting failed."
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "check", "--fix") + $newPythonFiles) `
        -FailureMessage "Ruff automatic fixes failed."
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "check") + $newPythonFiles) `
        -FailureMessage "Ruff validation failed."
    Write-Pass "Ruff formatting and linting passed"

    Write-Step "Running strict Mypy validation"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "mypy",
            "src\ficc_liquidity\stress\repo_funding_stress.py",
            "tests\test_repo_funding_stress.py"
        ) `
        -FailureMessage "Strict Mypy validation failed."
    Write-Pass "Strict Mypy validation passed"

    Write-Step "Running focused Section 16 tests and branch coverage"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "pytest",
            "-q",
            "tests\test_repo_funding_stress.py",
            "-o", "addopts=",
            "--strict-config",
            "--strict-markers",
            "--cov=ficc_liquidity.stress.repo_funding_stress",
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under=85"
        ) `
        -FailureMessage "Focused Section 16 tests or coverage failed."
    Write-Pass "Focused Section 16 tests and coverage passed"

    Write-Step "Executing the controlled Section 16 repo funding-stress model"
    $runnerArguments = @(
        "scripts\run_repo_funding_stress.py",
        "--config", "configs\repo_funding_stress.yaml",
        "--output-dir", "reports\tables",
        "--evidence-dir", "reports\evidence",
        "--manifest", "data\manifests\repo_funding_stress_manifest.csv"
    )
    if ($AllowDemo) {
        $runnerArguments += "--allow-demo"
        $runnerArguments += "--smoke"
        Write-Warn "Controlled demo mode was explicitly enabled."
    }
    Invoke-Checked -FilePath $Python `
        -ArgumentList $runnerArguments `
        -FailureMessage "Section 16 model execution failed."
    Write-Pass "Section 16 model outputs, manifest, and validation evidence created"

    if (-not $SkipFullTests) {
        Write-Step "Running complete repository quality gates"
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("-m", "ruff", "check", ".") `
            -FailureMessage "Repository-wide Ruff validation failed."
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("-m", "mypy") `
            -FailureMessage "Repository-wide strict Mypy validation failed."
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("-m", "pytest") `
            -FailureMessage "Complete repository tests or coverage failed."
        Write-Pass "Complete repository Ruff, Mypy, Pytest, and coverage gates passed"
    }
    else {
        Write-Warn "Complete repository tests were skipped by request."
    }

    if (-not $SkipGit) {
        Write-Step "Staging controlled Section 16 deliverables"

        $regularPaths = @(
            $AutomationRelativePath,
            "configs\repo_funding_stress.yaml",
            "data\manifests\repo_funding_stress_manifest.csv",
            "docs\repo_funding_stress_methodology.md",
            "scripts\run_repo_funding_stress.py",
            "src\ficc_liquidity\stress\__init__.py",
            "src\ficc_liquidity\stress\repo_funding_stress.py",
            "tests\test_repo_funding_stress.py"
        )
        Invoke-Checked -FilePath "git" `
            -ArgumentList (@("add", "--") + $regularPaths) `
            -FailureMessage "Unable to stage Section 16 source deliverables."

        $generatedPaths = @(
            "reports\evidence\section16_repo_funding_stress.json",
            "reports\evidence\section16_repo_funding_stress.md",
            "reports\tables\repo_funding_stress_cashflows.csv",
            "reports\tables\repo_funding_stress_member_summary.csv",
            "reports\tables\repo_funding_stress_scenario_summary.csv"
        )
        if ($AllowDemo) {
            $generatedPaths = @(
                "reports\evidence\section16_repo_funding_stress_smoke.json",
                "reports\evidence\section16_repo_funding_stress_smoke.md",
                "reports\tables\repo_funding_stress_cashflows_smoke.csv",
                "reports\tables\repo_funding_stress_member_summary_smoke.csv",
                "reports\tables\repo_funding_stress_scenario_summary_smoke.csv"
            )
        }

        foreach ($generatedPath in $generatedPaths) {
            if (-not (Test-Path -LiteralPath $generatedPath -PathType Leaf)) {
                throw "Expected generated Section 16 artifact is missing: $generatedPath"
            }
        }
        Invoke-Checked -FilePath "git" `
            -ArgumentList (@("add", "-f", "--") + $generatedPaths) `
            -FailureMessage "Unable to force-stage controlled Section 16 generated evidence."

        Invoke-Checked -FilePath "git" `
            -ArgumentList @("diff", "--cached", "--check") `
            -FailureMessage "Staged Section 16 changes failed whitespace validation."

        $stagedNames = @(& git diff --cached --name-only)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect staged Section 16 changes."
        }
        if ($stagedNames.Count -eq 0) {
            Write-Warn "No new staged changes were detected; the branch may already contain Section 16."
        }
        else {
            Write-Host ""
            Write-Host "Staged files:" -ForegroundColor Cyan
            $stagedNames | ForEach-Object { Write-Host "  $_" }
        }

        if (-not $NoCommit -and $stagedNames.Count -gt 0) {
            Write-Step "Committing Section 16"
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("commit", "-m", $CommitMessage) `
                -FailureMessage "Unable to commit Section 16 changes."
            Write-Pass "Section 16 commit created"
        }
        elseif ($NoCommit) {
            Write-Warn "Commit was skipped by request; changes remain staged."
        }

        if (-not $SkipPush -and -not $NoCommit) {
            Write-Step "Pushing $BranchName"
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("push", "-u", "origin", $BranchName) `
                -FailureMessage "Unable to push $BranchName."
            Write-Pass "Feature branch pushed"
        }
        elseif ($SkipPush) {
            Write-Warn "Push was skipped by request."
        }

        $pullRequestUrl = ""
        if (-not $SkipPullRequest -and -not $SkipPush -and -not $NoCommit) {
            Assert-Command -Name "gh"
            Invoke-Checked -FilePath "gh" `
                -ArgumentList @("auth", "status") `
                -FailureMessage "GitHub CLI authentication is unavailable."

            $existingPrJson = & gh pr list `
                --repo $RepoFullName `
                --head $BranchName `
                --state open `
                --json url `
                --limit 1
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect existing pull requests for $BranchName."
            }
            $existingPr = @($existingPrJson | ConvertFrom-Json)
            if ($existingPr.Count -gt 0) {
                $pullRequestUrl = [string]$existingPr[0].url
                Write-Warn "An open pull request already exists: $pullRequestUrl"
            }
            else {
                Write-Step "Opening the Section 16 pull request"
                $PullRequestBody = @"
## Summary

Completes Phase V, Section 16: repo funding-stress model.

## Implemented stress channels

- SOFR rate spikes
- Funding-cost increases
- Repo rollover failures
- Partial lender withdrawal
- Shorter refinancing horizons
- Increased collateral demands
- Funding concentration and dependency amplification

## Model integration

- Uses Section 14 baseline liquidity cash flows.
- Uses Section 12 synthetic-member concentration and funding-dependency fields.
- Uses the latest processed SOFR observation when available, with an explicitly
  identified configuration fallback.
- Preserves synthetic-only controls and prohibits participant-level inference.

## Validation

- Ruff formatting and linting
- Strict Mypy
- Focused Pytest and branch coverage
- Deterministic reproduction
- Accounting and liquidity identities
- Complete repository quality gates
"@
                $pullRequestUrl = & gh pr create `
                    --repo $RepoFullName `
                    --base main `
                    --head $BranchName `
                    --title $PullRequestTitle `
                    --body $PullRequestBody
                if ($LASTEXITCODE -ne 0) {
                    throw "Unable to create the Section 16 pull request."
                }
                $pullRequestUrl = ([string]$pullRequestUrl).Trim()
                Write-Pass "Pull request created: $pullRequestUrl"
            }

            if ($WatchChecks) {
                Write-Step "Watching Section 16 pull-request checks"
                Invoke-Checked -FilePath "gh" `
                    -ArgumentList @(
                        "pr", "checks", $pullRequestUrl,
                        "--repo", $RepoFullName,
                        "--watch"
                    ) `
                    -FailureMessage "Section 16 pull-request checks did not pass."
                Write-Pass "Section 16 pull-request checks passed"
            }
        }
        elseif ($SkipPullRequest) {
            Write-Warn "Pull-request creation was skipped by request."
        }
    }

    Write-Step "Section 16 completion decision"
    Write-Pass "SOFR rate spikes: implemented"
    Write-Pass "Funding-cost increases: implemented"
    Write-Pass "Repo rollover failures: implemented"
    Write-Pass "Partial lender withdrawal: implemented"
    Write-Pass "Shorter refinancing horizons: implemented"
    Write-Pass "Increased collateral demands: implemented"
    Write-Pass "Funding concentration: implemented"
    Write-Pass "Synthetic-only and deterministic controls: implemented"
    Write-Host ""
    Write-Host "FINAL DECISION: SECTION 16 COMPLETE" -ForegroundColor Green
    Write-Host "Branch: $BranchName"
    Write-Host "Evidence: reports\evidence\section16_repo_funding_stress.md"
    Write-Host "Scenario summary: reports\tables\repo_funding_stress_scenario_summary.csv"
}
catch {
    Write-Host ""
    Write-Host "SECTION 16 AUTOMATION FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
