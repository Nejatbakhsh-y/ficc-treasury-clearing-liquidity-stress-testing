#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase V, Section 17: collateral haircut stress.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.

    The automation updates main, creates feature/15-haircut-stress, writes the
    controlled configuration, Python model, runner, tests, methodology, lineage
    manifest, evidence, and output tables; runs Ruff, strict Mypy, focused branch
    coverage, the actual Section 17 model, and the complete repository quality
    gates; then commits, pushes, and opens a pull request.

    Implemented channels:
      - Treasury haircut increases
      - Maturity-dependent haircuts
      - Stress-dependent haircuts
      - Concentration multipliers
      - Additional collateral requirements
      - Available-collateral constraints

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\19_P5S17_Collateral_Haircut_Stress_PS51.ps1"

.EXAMPLE
    & "$env:USERPROFILE\Downloads\19_P5S17_Collateral_Haircut_Stress_PS51.ps1" `
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
$BranchName = "feature/15-haircut-stress"
$CommitMessage = "Phase V Section 17: add collateral haircut stress"
$PullRequestTitle = "Phase V Section 17: Collateral haircut stress"
$AutomationRelativePath = "scripts\automation\19_P5S17_Collateral_Haircut_Stress_PS51.ps1"

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
Use -AllowDirty only when rerunning Section 17 on its feature branch.
"@
            }
            if ($currentBranch -ne $BranchName) {
                throw @"
-AllowDirty is safe only when the current branch is $BranchName.
The current branch is $currentBranch. Commit or stash the existing changes first.
"@
            }
            $skipBranchRefresh = $true
            Write-Warn "Dirty Section 17 branch retained; main refresh and branch merge were skipped."
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

    Write-Step "Confirming prior-section dependencies"
    $requiredDependencies = @(
        "data\synthetic\calibrated_member_portfolios.parquet",
        "configs\baseline_liquidity.yaml",
        "src\ficc_liquidity\liquidity\baseline_cashflow.py",
        "reports\tables\baseline_liquidity_cashflows.csv",
        "configs\treasury_yield_stress.yaml",
        "src\ficc_liquidity\stress\treasury_yield_shock.py",
        "configs\repo_funding_stress.yaml",
        "src\ficc_liquidity\stress\repo_funding_stress.py"
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
    Write-Pass "Sections 12, 14, 15, and 16 dependencies are available"

    Write-Step "Creating Section 17 directories and controlled files"
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
section: 17
model_name: collateral_haircut_stress
model_version: "section-17-v1"
currency: USD
random_seed: 2026

classification:
  baseline_cash_flows: modeled
  synthetic_member_profiles: synthetic
  maturity_haircuts: assumed
  scenario_haircuts: assumed
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

maturity_buckets:
  bills_0_1y:
    source_columns:
      - treasury_position_bills_0_1y_usd
    base_haircut_rate: 0.010
    eligibility_factor: 1.00
  notes_1_3y:
    source_columns:
      - treasury_position_notes_1_3y_usd
    base_haircut_rate: 0.015
    eligibility_factor: 1.00
  notes_3_7y:
    source_columns:
      - treasury_position_notes_3_7y_usd
    base_haircut_rate: 0.025
    eligibility_factor: 0.98
  notes_7_10y:
    source_columns:
      - treasury_position_notes_7_10y_usd
    base_haircut_rate: 0.035
    eligibility_factor: 0.96
  bonds_10_30y:
    source_columns:
      - treasury_position_bonds_10_30y_usd
    base_haircut_rate: 0.060
    eligibility_factor: 0.92
  strips_30y_plus:
    source_columns:
      - treasury_position_strips_30y_plus_usd
    base_haircut_rate: 0.100
    eligibility_factor: 0.85

scenarios:
  - name: control
    enabled: true
    severity_rank: 0
    stress_multiplier: 1.00
    additive_haircut_rate: 0.000
    bucket_addons:
      bills_0_1y: 0.000
      notes_1_3y: 0.000
      notes_3_7y: 0.000
      notes_7_10y: 0.000
      bonds_10_30y: 0.000
      strips_30y_plus: 0.000
    concentration_threshold: 1.00
    concentration_multiplier: 0.00
    additional_collateral_call_rate: 0.000
    inventory_availability_rate: 1.00
    maximum_haircut_rate: 0.50

  - name: moderate_haircut_stress
    enabled: true
    severity_rank: 1
    stress_multiplier: 1.25
    additive_haircut_rate: 0.005
    bucket_addons:
      bills_0_1y: 0.000
      notes_1_3y: 0.001
      notes_3_7y: 0.002
      notes_7_10y: 0.004
      bonds_10_30y: 0.008
      strips_30y_plus: 0.015
    concentration_threshold: 0.35
    concentration_multiplier: 0.10
    additional_collateral_call_rate: 0.010
    inventory_availability_rate: 0.95
    maximum_haircut_rate: 0.50

  - name: severe_haircut_stress
    enabled: true
    severity_rank: 2
    stress_multiplier: 1.75
    additive_haircut_rate: 0.015
    bucket_addons:
      bills_0_1y: 0.002
      notes_1_3y: 0.004
      notes_3_7y: 0.008
      notes_7_10y: 0.012
      bonds_10_30y: 0.025
      strips_30y_plus: 0.040
    concentration_threshold: 0.25
    concentration_multiplier: 0.30
    additional_collateral_call_rate: 0.030
    inventory_availability_rate: 0.80
    maximum_haircut_rate: 0.50

  - name: extreme_collateral_freeze
    enabled: true
    severity_rank: 3
    stress_multiplier: 2.50
    additive_haircut_rate: 0.030
    bucket_addons:
      bills_0_1y: 0.005
      notes_1_3y: 0.010
      notes_3_7y: 0.018
      notes_7_10y: 0.030
      bonds_10_30y: 0.050
      strips_30y_plus: 0.075
    concentration_threshold: 0.20
    concentration_multiplier: 0.50
    additional_collateral_call_rate: 0.080
    inventory_availability_rate: 0.60
    maximum_haircut_rate: 0.50

validation:
  reconciliation_tolerance_usd: 0.01
  require_deterministic_reproduction: true
  require_synthetic_identifiers: true
  require_maturity_dependent_haircuts: true
  require_stress_dependent_haircuts: true
  require_concentration_multiplier: true
  require_available_collateral_constraints: true

output:
  directory: reports/tables
  evidence_directory: reports/evidence
  manifest: data/manifests/collateral_haircut_stress_manifest.csv
  write_csv: true
  write_parquet: true
'@

$ModuleContent = @'
"""Collateral haircut-stress model for synthetic clearing-member liquidity analysis.

Section 17 applies maturity-dependent, scenario-dependent, and concentration-
sensitive Treasury haircuts to fictional clearing-member collateral. The model
calculates additional collateral requirements, enforces available-collateral
constraints, and translates collateral deficits and resource erosion into
stressed liquidity coverage. It never identifies or infers an actual FICC
participant.
"""

from __future__ import annotations

import hashlib
import math
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class CollateralHaircutStressError(ValueError):
    """Raised when Section 17 inputs or assumptions are invalid."""


@dataclass(frozen=True, slots=True)
class MaturityHaircut:
    """Controlled maturity-bucket haircut assumptions."""

    name: str
    source_columns: tuple[str, ...]
    base_haircut_rate: float
    eligibility_factor: float


@dataclass(frozen=True, slots=True)
class HaircutScenario:
    """One controlled collateral haircut-stress scenario."""

    name: str
    severity_rank: int
    stress_multiplier: float
    additive_haircut_rate: float
    bucket_addons: Mapping[str, float]
    concentration_threshold: float
    concentration_multiplier: float
    additional_collateral_call_rate: float
    inventory_availability_rate: float
    maximum_haircut_rate: float


@dataclass(frozen=True, slots=True)
class CollateralHaircutStressSettings:
    """Validated Section 17 settings."""

    model_version: str
    tolerance_usd: float
    synthetic_id_pattern: str
    maturity_buckets: tuple[MaturityHaircut, ...]
    scenarios: tuple[HaircutScenario, ...]


@dataclass(frozen=True, slots=True)
class CollateralHaircutStressResult:
    """Section 17 model outputs and validation status."""

    bucket_results: pd.DataFrame
    member_summary: pd.DataFrame
    scenario_summary: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CollateralHaircutStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CollateralHaircutStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise CollateralHaircutStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise CollateralHaircutStressError(f"{key} must be an integer.")
    return int(value)


def _bounded_rate(value: float, label: str) -> None:
    if not 0.0 <= value <= 1.0:
        raise CollateralHaircutStressError(f"{label} must be between zero and one.")


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled Section 17 YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise CollateralHaircutStressError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _load_maturity_bucket(name: str, raw: Mapping[str, Any]) -> MaturityHaircut:
    source_columns_raw = raw.get("source_columns")
    if not isinstance(source_columns_raw, list) or not source_columns_raw:
        raise CollateralHaircutStressError(
            f"maturity_buckets.{name}.source_columns must be a nonempty list."
        )
    source_columns = tuple(str(value).strip() for value in source_columns_raw)
    if any(not value for value in source_columns):
        raise CollateralHaircutStressError(
            f"maturity_buckets.{name}.source_columns contains an empty value."
        )
    bucket = MaturityHaircut(
        name=name,
        source_columns=source_columns,
        base_haircut_rate=_number(raw, "base_haircut_rate"),
        eligibility_factor=_number(raw, "eligibility_factor"),
    )
    _bounded_rate(bucket.base_haircut_rate, f"{name}.base_haircut_rate")
    _bounded_rate(bucket.eligibility_factor, f"{name}.eligibility_factor")
    if bucket.base_haircut_rate >= 1.0:
        raise CollateralHaircutStressError(
            f"{name}.base_haircut_rate must be below one."
        )
    return bucket


def _load_scenario(
    raw: Mapping[str, Any],
    bucket_names: tuple[str, ...],
) -> HaircutScenario:
    name = str(raw.get("name", "")).strip()
    if not name:
        raise CollateralHaircutStressError("Every scenario must have a nonempty name.")

    addons_raw = _mapping(raw.get("bucket_addons", {}), f"{name}.bucket_addons")
    unknown = sorted(set(addons_raw) - set(bucket_names))
    if unknown:
        raise CollateralHaircutStressError(
            f"{name}.bucket_addons contains unknown maturity buckets: {unknown}"
        )
    addons = {bucket: float(addons_raw.get(bucket, 0.0)) for bucket in bucket_names}
    if any(not math.isfinite(value) or value < 0.0 for value in addons.values()):
        raise CollateralHaircutStressError(
            f"{name}.bucket_addons must contain finite nonnegative rates."
        )

    scenario = HaircutScenario(
        name=name,
        severity_rank=_integer(raw, "severity_rank"),
        stress_multiplier=_number(raw, "stress_multiplier"),
        additive_haircut_rate=_number(raw, "additive_haircut_rate"),
        bucket_addons=addons,
        concentration_threshold=_number(raw, "concentration_threshold"),
        concentration_multiplier=_number(raw, "concentration_multiplier"),
        additional_collateral_call_rate=_number(
            raw, "additional_collateral_call_rate"
        ),
        inventory_availability_rate=_number(raw, "inventory_availability_rate"),
        maximum_haircut_rate=_number(raw, "maximum_haircut_rate"),
    )
    if scenario.severity_rank < 0:
        raise CollateralHaircutStressError("severity_rank must be nonnegative.")
    for label, value in (
        ("additive_haircut_rate", scenario.additive_haircut_rate),
        ("concentration_threshold", scenario.concentration_threshold),
        ("additional_collateral_call_rate", scenario.additional_collateral_call_rate),
        ("inventory_availability_rate", scenario.inventory_availability_rate),
        ("maximum_haircut_rate", scenario.maximum_haircut_rate),
    ):
        _bounded_rate(value, f"{name}.{label}")
    if scenario.maximum_haircut_rate >= 1.0:
        raise CollateralHaircutStressError(
            f"{name}.maximum_haircut_rate must be below one."
        )
    if scenario.stress_multiplier < 1.0:
        raise CollateralHaircutStressError(
            f"{name}.stress_multiplier must be at least one."
        )
    if scenario.concentration_multiplier < 0.0:
        raise CollateralHaircutStressError(
            f"{name}.concentration_multiplier must be nonnegative."
        )
    return scenario


def load_settings(config: Mapping[str, Any]) -> CollateralHaircutStressSettings:
    """Validate and convert the Section 17 configuration."""
    maturity_raw = _mapping(config.get("maturity_buckets"), "maturity_buckets")
    if not maturity_raw:
        raise CollateralHaircutStressError("At least one maturity bucket is required.")
    maturity_buckets = tuple(
        _load_maturity_bucket(str(name), _mapping(raw, f"maturity_buckets.{name}"))
        for name, raw in maturity_raw.items()
    )
    bucket_names = tuple(bucket.name for bucket in maturity_buckets)

    scenarios_raw = config.get("scenarios")
    if not isinstance(scenarios_raw, list) or not scenarios_raw:
        raise CollateralHaircutStressError("scenarios must be a nonempty list.")
    scenarios = tuple(
        _load_scenario(_mapping(raw, "scenario"), bucket_names)
        for raw in scenarios_raw
        if bool(_mapping(raw, "scenario").get("enabled", True))
    )
    if not scenarios:
        raise CollateralHaircutStressError("At least one enabled scenario is required.")
    names = [scenario.name for scenario in scenarios]
    ranks = [scenario.severity_rank for scenario in scenarios]
    if len(set(names)) != len(names):
        raise CollateralHaircutStressError("Scenario names must be unique.")
    if len(set(ranks)) != len(ranks):
        raise CollateralHaircutStressError("Scenario severity ranks must be unique.")

    validation = _mapping(config.get("validation"), "validation")
    source = _mapping(config.get("source"), "source")
    settings = CollateralHaircutStressSettings(
        model_version=str(config.get("model_version", "section-17-v1")).strip(),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        synthetic_id_pattern=str(
            source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")
        ),
        maturity_buckets=maturity_buckets,
        scenarios=tuple(sorted(scenarios, key=lambda item: item.severity_rank)),
    )
    if not settings.model_version:
        raise CollateralHaircutStressError("model_version must be populated.")
    if settings.tolerance_usd < 0.0:
        raise CollateralHaircutStressError(
            "reconciliation_tolerance_usd must be nonnegative."
        )

    previous: HaircutScenario | None = None
    for scenario in settings.scenarios:
        maximum_base = max(bucket.base_haircut_rate for bucket in maturity_buckets)
        if scenario.maximum_haircut_rate < maximum_base:
            raise CollateralHaircutStressError(
                f"{scenario.name}.maximum_haircut_rate cannot be below a base haircut."
            )
        if previous is not None:
            if scenario.stress_multiplier < previous.stress_multiplier:
                raise CollateralHaircutStressError(
                    "Scenario stress_multiplier must be nondecreasing by severity."
                )
            if scenario.additive_haircut_rate < previous.additive_haircut_rate:
                raise CollateralHaircutStressError(
                    "Scenario additive_haircut_rate must be nondecreasing by severity."
                )
            if (
                scenario.additional_collateral_call_rate
                < previous.additional_collateral_call_rate
            ):
                raise CollateralHaircutStressError(
                    "Additional collateral calls must be nondecreasing by severity."
                )
            if (
                scenario.inventory_availability_rate
                > previous.inventory_availability_rate
            ):
                raise CollateralHaircutStressError(
                    "Inventory availability cannot improve as severity increases."
                )
        previous = scenario
    return settings


def read_table(path: str | Path) -> pd.DataFrame:
    """Read a CSV or Parquet table."""
    table_path = Path(path)
    if not table_path.exists():
        raise CollateralHaircutStressError(f"Input table does not exist: {table_path}")
    if table_path.suffix.lower() == ".csv":
        return pd.read_csv(table_path)
    if table_path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(table_path)
    raise CollateralHaircutStressError("Input tables must be CSV or Parquet.")


def dataframe_digest(frame: pd.DataFrame) -> str:
    """Return a deterministic digest independent of input row order."""
    ordered_columns = sorted(str(column) for column in frame.columns)
    ordered = frame[ordered_columns].copy()
    sort_columns = [
        column
        for column in (
            "scenario_name",
            "member_id",
            "maturity_bucket",
            "bucket_order",
        )
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _validate_identity(
    frame: pd.DataFrame,
    synthetic_id_pattern: str,
) -> None:
    if "member_id" not in frame.columns:
        raise CollateralHaircutStressError("Synthetic inputs require member_id.")
    member_ids = frame["member_id"].astype("string").str.strip()
    if member_ids.isna().any() or (member_ids == "").any():
        raise CollateralHaircutStressError(
            "Synthetic member identifiers cannot be missing."
        )
    invalid = [
        member_id
        for member_id in member_ids.astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise CollateralHaircutStressError(
            f"Non-synthetic or invalid member identifiers detected: {sorted(set(invalid))}"
        )
    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise CollateralHaircutStressError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise CollateralHaircutStressError(
            "Participant-level inference records are prohibited."
        )
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise CollateralHaircutStressError(
            "Every member record must use value_class='synthetic'."
        )


def _numeric_nonnegative(frame: pd.DataFrame, columns: list[str]) -> None:
    for column in columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise CollateralHaircutStressError(
                f"{column} contains missing or nonfinite values."
            )
        if (frame[column] < 0.0).any():
            raise CollateralHaircutStressError(f"{column} must be nonnegative.")


def _find_source_column(
    frame: pd.DataFrame,
    candidates: tuple[str, ...],
    bucket_name: str,
) -> str:
    lookup = {str(column).lower(): str(column) for column in frame.columns}
    for candidate in candidates:
        found = lookup.get(candidate.lower())
        if found is not None:
            return found
    raise CollateralHaircutStressError(
        f"No source column was found for maturity bucket {bucket_name}. "
        f"Expected one of {list(candidates)}."
    )


def prepare_members(
    members: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> pd.DataFrame:
    """Validate synthetic members and convert maturity positions to long form."""
    if members.empty:
        raise CollateralHaircutStressError("Synthetic member input is empty.")
    frame = members.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern)
    if frame["member_id"].duplicated().any():
        raise CollateralHaircutStressError("Synthetic member identifiers must be unique.")

    required_member_fields = [
        "repo_financing_need_usd",
        "collateral_inventory_usd",
        "available_qualified_liquid_resources_usd",
    ]
    missing = sorted(set(required_member_fields) - set(frame.columns))
    if missing:
        raise CollateralHaircutStressError(
            f"Required synthetic-member fields are missing: {missing}"
        )
    _numeric_nonnegative(frame, required_member_fields)

    source_by_bucket = {
        bucket.name: _find_source_column(frame, bucket.source_columns, bucket.name)
        for bucket in settings.maturity_buckets
    }
    _numeric_nonnegative(frame, list(source_by_bucket.values()))

    total_position = sum(
        (frame[source] for source in source_by_bucket.values()),
        start=pd.Series(0.0, index=frame.index),
    )
    if (total_position <= 0.0).any():
        raise CollateralHaircutStressError(
            "Every member must have a positive Treasury collateral position."
        )
    if "total_treasury_position_usd" in frame.columns:
        reported = pd.to_numeric(
            frame["total_treasury_position_usd"], errors="coerce"
        )
        if reported.isna().any():
            raise CollateralHaircutStressError(
                "total_treasury_position_usd contains invalid values."
            )
        difference = (reported - total_position).abs()
        if (difference > max(settings.tolerance_usd, 5.0)).any():
            raise CollateralHaircutStressError(
                "Treasury maturity positions do not reconcile to the reported total."
            )

    parts: list[pd.DataFrame] = []
    for order, bucket in enumerate(settings.maturity_buckets, start=1):
        source = source_by_bucket[bucket.name]
        part = frame[
            [
                "member_id",
                "repo_financing_need_usd",
                "collateral_inventory_usd",
                "available_qualified_liquid_resources_usd",
            ]
        ].copy()
        part["maturity_bucket"] = bucket.name
        part["bucket_order"] = order
        part["source_column"] = source
        part["market_value_usd"] = frame[source].to_numpy()
        part["total_treasury_position_usd"] = total_position.to_numpy()
        part["bucket_weight"] = (
            part["market_value_usd"] / part["total_treasury_position_usd"]
        )
        part["base_haircut_rate"] = bucket.base_haircut_rate
        part["eligibility_factor"] = bucket.eligibility_factor
        parts.append(part)

    long = pd.concat(parts, ignore_index=True)
    long["member_concentration_ratio"] = long.groupby("member_id")[
        "bucket_weight"
    ].transform("max")
    long["repo_exposure_allocated_usd"] = (
        long["repo_financing_need_usd"] * long["bucket_weight"]
    )
    long["collateral_inventory_allocated_usd"] = (
        long["collateral_inventory_usd"] * long["bucket_weight"]
    ).clip(upper=long["market_value_usd"])
    long["qualified_resources_allocated_usd"] = (
        long["available_qualified_liquid_resources_usd"] * long["bucket_weight"]
    )
    long["value_class"] = "synthetic"
    long["actual_ficc_participant"] = False
    long["participant_level_inference"] = False

    weight_sums = long.groupby("member_id")["bucket_weight"].sum()
    if not weight_sums.map(lambda value: math.isclose(value, 1.0, abs_tol=1e-10)).all():
        raise CollateralHaircutStressError(
            "Maturity-bucket weights do not reconcile to one."
        )
    return long.sort_values(
        ["member_id", "bucket_order"], kind="stable"
    ).reset_index(drop=True)


def prepare_baseline(
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> pd.DataFrame:
    """Select and validate the final Section 14 liquidity-horizon row per member."""
    if baseline.empty:
        raise CollateralHaircutStressError("Baseline liquidity input is empty.")
    required = {
        "member_id",
        "bucket_order",
        "time_bucket",
        "cumulative_net_liquidity_need_usd",
        "cumulative_available_resources_usd",
        "eligible_collateral_liquidity_usd",
        "available_cash_usd",
        "liquidity_headroom_usd",
        "liquidity_shortfall_usd",
    }
    missing = sorted(required - set(baseline.columns))
    if missing:
        raise CollateralHaircutStressError(
            f"Required baseline liquidity fields are missing: {missing}"
        )
    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_identity(frame, settings.synthetic_id_pattern)
    numeric = sorted(required - {"member_id", "time_bucket"})
    _numeric_nonnegative(
        frame,
        [
            column
            for column in numeric
            if column not in {"liquidity_headroom_usd"}
        ],
    )
    frame["liquidity_headroom_usd"] = pd.to_numeric(
        frame["liquidity_headroom_usd"], errors="coerce"
    )
    if frame["liquidity_headroom_usd"].isna().any():
        raise CollateralHaircutStressError(
            "liquidity_headroom_usd contains invalid values."
        )
    frame = frame.sort_values(
        ["member_id", "bucket_order"], kind="stable"
    ).drop_duplicates("member_id", keep="last")
    if frame["member_id"].duplicated().any():
        raise CollateralHaircutStressError(
            "Final baseline rows must be unique by member."
        )

    expected_headroom = (
        frame["cumulative_available_resources_usd"]
        - frame["cumulative_net_liquidity_need_usd"]
    )
    if (
        (expected_headroom - frame["liquidity_headroom_usd"]).abs()
        > settings.tolerance_usd
    ).any():
        raise CollateralHaircutStressError(
            "Baseline liquidity headroom identity failed."
        )
    expected_shortfall = (-expected_headroom).clip(lower=0.0)
    if (
        (expected_shortfall - frame["liquidity_shortfall_usd"]).abs()
        > settings.tolerance_usd
    ).any():
        raise CollateralHaircutStressError(
            "Baseline liquidity shortfall identity failed."
        )

    selected = frame[
        [
            "member_id",
            "bucket_order",
            "time_bucket",
            "cumulative_net_liquidity_need_usd",
            "cumulative_available_resources_usd",
            "eligible_collateral_liquidity_usd",
            "available_cash_usd",
            "liquidity_headroom_usd",
            "liquidity_shortfall_usd",
        ]
    ].rename(
        columns={
            "bucket_order": "baseline_final_bucket_order",
            "time_bucket": "baseline_final_time_bucket",
            "cumulative_net_liquidity_need_usd": "baseline_liquidity_need_usd",
            "cumulative_available_resources_usd": "baseline_available_resources_usd",
            "eligible_collateral_liquidity_usd": "baseline_eligible_collateral_liquidity_usd",
            "available_cash_usd": "baseline_available_cash_usd",
            "liquidity_headroom_usd": "baseline_liquidity_headroom_usd",
            "liquidity_shortfall_usd": "baseline_liquidity_shortfall_usd",
        }
    )
    return selected.sort_values("member_id", kind="stable").reset_index(drop=True)


def _scenario_bucket_results(
    member_buckets: pd.DataFrame,
    scenario: HaircutScenario,
) -> pd.DataFrame:
    frame = member_buckets.copy(deep=True)
    frame["scenario_name"] = scenario.name
    frame["severity_rank"] = scenario.severity_rank
    frame["stress_multiplier"] = scenario.stress_multiplier
    frame["additive_haircut_rate"] = scenario.additive_haircut_rate
    frame["bucket_haircut_addon"] = frame["maturity_bucket"].map(
        scenario.bucket_addons
    )
    concentration_excess = (
        frame["bucket_weight"] - scenario.concentration_threshold
    ).clip(lower=0.0)
    frame["concentration_threshold"] = scenario.concentration_threshold
    frame["concentration_excess"] = concentration_excess
    frame["concentration_haircut_addon"] = (
        concentration_excess * scenario.concentration_multiplier
    )
    frame["raw_stressed_haircut_rate"] = (
        frame["base_haircut_rate"] * scenario.stress_multiplier
        + scenario.additive_haircut_rate
        + frame["bucket_haircut_addon"]
        + frame["concentration_haircut_addon"]
    )
    frame["maximum_haircut_rate"] = scenario.maximum_haircut_rate
    frame["stressed_haircut_rate"] = frame[
        ["raw_stressed_haircut_rate", "base_haircut_rate"]
    ].max(axis=1).clip(upper=scenario.maximum_haircut_rate)
    frame["haircut_increase_rate"] = (
        frame["stressed_haircut_rate"] - frame["base_haircut_rate"]
    )

    frame["baseline_required_collateral_usd"] = (
        frame["repo_exposure_allocated_usd"]
        / (1.0 - frame["base_haircut_rate"])
    )
    frame["stressed_required_collateral_before_call_usd"] = (
        frame["repo_exposure_allocated_usd"]
        / (1.0 - frame["stressed_haircut_rate"])
    )
    frame["haircut_driven_collateral_call_usd"] = (
        frame["stressed_required_collateral_before_call_usd"]
        - frame["baseline_required_collateral_usd"]
    ).clip(lower=0.0)
    frame["additional_collateral_call_rate"] = (
        scenario.additional_collateral_call_rate
    )
    frame["scenario_additional_collateral_call_usd"] = (
        frame["repo_exposure_allocated_usd"]
        * scenario.additional_collateral_call_rate
    )
    frame["additional_collateral_requirement_usd"] = (
        frame["haircut_driven_collateral_call_usd"]
        + frame["scenario_additional_collateral_call_usd"]
    )

    frame["baseline_excess_collateral_inventory_usd"] = (
        frame["collateral_inventory_allocated_usd"]
        - frame["baseline_required_collateral_usd"]
    ).clip(lower=0.0)
    frame["baseline_eligible_excess_collateral_usd"] = (
        frame["baseline_excess_collateral_inventory_usd"]
        * frame["eligibility_factor"]
    )
    frame["inventory_availability_rate"] = scenario.inventory_availability_rate
    valuation_factor = (
        (1.0 - frame["stressed_haircut_rate"])
        / (1.0 - frame["base_haircut_rate"])
    ).clip(lower=0.0, upper=1.0)
    frame["stressed_available_collateral_usd"] = (
        frame["baseline_eligible_excess_collateral_usd"]
        * scenario.inventory_availability_rate
        * valuation_factor
    )
    frame["collateral_posted_usd"] = frame[
        [
            "additional_collateral_requirement_usd",
            "stressed_available_collateral_usd",
        ]
    ].min(axis=1)
    frame["collateral_shortfall_usd"] = (
        frame["additional_collateral_requirement_usd"]
        - frame["collateral_posted_usd"]
    ).clip(lower=0.0)

    frame["haircut_market_value_loss_usd"] = (
        frame["market_value_usd"] * frame["haircut_increase_rate"]
    )
    frame["inventory_unavailability_loss_usd"] = (
        frame["baseline_eligible_excess_collateral_usd"]
        - frame["stressed_available_collateral_usd"]
    ).clip(lower=0.0)
    frame["gross_collateral_resource_reduction_usd"] = (
        frame["haircut_market_value_loss_usd"]
        + frame["inventory_unavailability_loss_usd"]
        + frame["collateral_posted_usd"]
    )
    frame["qualified_resource_reduction_usd"] = frame[
        [
            "gross_collateral_resource_reduction_usd",
            "qualified_resources_allocated_usd",
        ]
    ].min(axis=1)
    frame["stressed_qualified_resources_allocated_usd"] = (
        frame["qualified_resources_allocated_usd"]
        - frame["qualified_resource_reduction_usd"]
    ).clip(lower=0.0)
    frame["model_version"] = ""
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame


def _build_member_summary(
    bucket_results: pd.DataFrame,
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> pd.DataFrame:
    sum_columns = [
        "market_value_usd",
        "repo_exposure_allocated_usd",
        "collateral_inventory_allocated_usd",
        "qualified_resources_allocated_usd",
        "baseline_required_collateral_usd",
        "stressed_required_collateral_before_call_usd",
        "haircut_driven_collateral_call_usd",
        "scenario_additional_collateral_call_usd",
        "additional_collateral_requirement_usd",
        "baseline_excess_collateral_inventory_usd",
        "stressed_available_collateral_usd",
        "collateral_posted_usd",
        "collateral_shortfall_usd",
        "haircut_market_value_loss_usd",
        "inventory_unavailability_loss_usd",
        "gross_collateral_resource_reduction_usd",
        "qualified_resource_reduction_usd",
        "stressed_qualified_resources_allocated_usd",
    ]
    grouped = (
        bucket_results.groupby(
            ["scenario_name", "severity_rank", "member_id"],
            as_index=False,
            sort=True,
        )[sum_columns]
        .sum()
        .rename(
            columns={
                "market_value_usd": "total_treasury_collateral_market_value_usd",
                "repo_exposure_allocated_usd": "total_repo_exposure_usd",
                "collateral_inventory_allocated_usd": "treasury_collateral_inventory_usd",
                "qualified_resources_allocated_usd": "member_qualified_resources_usd",
                "baseline_required_collateral_usd": "baseline_required_collateral_total_usd",
                "stressed_required_collateral_before_call_usd": (
                    "stressed_required_collateral_total_usd"
                ),
                "additional_collateral_requirement_usd": (
                    "additional_collateral_requirement_total_usd"
                ),
                "stressed_available_collateral_usd": "available_collateral_to_meet_calls_usd",
                "collateral_posted_usd": "collateral_posted_total_usd",
                "collateral_shortfall_usd": "collateral_shortfall_total_usd",
                "qualified_resource_reduction_usd": "bucket_qualified_resource_reduction_usd",
                "stressed_qualified_resources_allocated_usd": (
                    "stressed_member_qualified_resources_usd"
                ),
            }
        )
    )
    summary = grouped.merge(
        baseline,
        on="member_id",
        how="left",
        validate="many_to_one",
    )
    if summary["baseline_liquidity_need_usd"].isna().any():
        raise CollateralHaircutStressError(
            "Every synthetic member must have a final baseline liquidity row."
        )

    summary["collateral_resource_reduction_usd"] = summary[
        [
            "bucket_qualified_resource_reduction_usd",
            "baseline_eligible_collateral_liquidity_usd",
        ]
    ].min(axis=1)
    summary["stressed_eligible_collateral_liquidity_usd"] = (
        summary["baseline_eligible_collateral_liquidity_usd"]
        - summary["collateral_resource_reduction_usd"]
    ).clip(lower=0.0)
    summary["stressed_available_resources_usd"] = (
        summary["baseline_available_resources_usd"]
        - summary["collateral_resource_reduction_usd"]
    ).clip(lower=0.0)
    summary["stressed_liquidity_need_usd"] = (
        summary["baseline_liquidity_need_usd"]
        + summary["collateral_shortfall_total_usd"]
    )
    summary["stressed_liquidity_headroom_usd"] = (
        summary["stressed_available_resources_usd"]
        - summary["stressed_liquidity_need_usd"]
    )
    summary["stressed_liquidity_shortfall_usd"] = (
        -summary["stressed_liquidity_headroom_usd"]
    ).clip(lower=0.0)
    denominator = summary["stressed_liquidity_need_usd"].replace(0.0, math.nan)
    summary["stressed_liquidity_coverage_ratio"] = (
        summary["stressed_available_resources_usd"] / denominator
    ).fillna(math.inf)
    summary["model_version"] = settings.model_version
    summary["value_class"] = "synthetic"
    summary["actual_ficc_participant"] = False
    summary["participant_level_inference"] = False
    return summary.sort_values(
        ["severity_rank", "member_id"], kind="stable"
    ).reset_index(drop=True)


def _build_scenario_summary(member_summary: pd.DataFrame) -> pd.DataFrame:
    sum_columns = [
        "additional_collateral_requirement_total_usd",
        "collateral_posted_total_usd",
        "collateral_shortfall_total_usd",
        "collateral_resource_reduction_usd",
        "baseline_available_resources_usd",
        "stressed_available_resources_usd",
        "baseline_liquidity_need_usd",
        "stressed_liquidity_need_usd",
        "baseline_liquidity_shortfall_usd",
        "stressed_liquidity_shortfall_usd",
    ]
    summary = member_summary.groupby(
        ["scenario_name", "severity_rank"],
        as_index=False,
        sort=True,
    )[sum_columns].sum()
    member_metrics = member_summary.groupby(
        ["scenario_name", "severity_rank"], as_index=False, sort=True
    ).agg(
        member_count=("member_id", "nunique"),
        members_with_collateral_shortfall=(
            "collateral_shortfall_total_usd",
            lambda series: int((series > 0.0).sum()),
        ),
        members_with_liquidity_shortfall=(
            "stressed_liquidity_shortfall_usd",
            lambda series: int((series > 0.0).sum()),
        ),
        minimum_liquidity_coverage_ratio=(
            "stressed_liquidity_coverage_ratio",
            "min",
        ),
    )
    return summary.merge(
        member_metrics,
        on=["scenario_name", "severity_rank"],
        how="left",
        validate="one_to_one",
    ).sort_values("severity_rank", kind="stable").reset_index(drop=True)


def validate_results(
    bucket_results: pd.DataFrame,
    member_summary: pd.DataFrame,
    scenario_summary: pd.DataFrame,
    member_buckets: pd.DataFrame,
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> dict[str, bool]:
    """Run Section 17 accounting, constraint, and identity checks."""
    tolerance = settings.tolerance_usd
    expected_bucket_rows = (
        len(member_buckets) * len(settings.scenarios)
    )
    expected_member_rows = (
        member_buckets["member_id"].nunique() * len(settings.scenarios)
    )

    key_unique = not bucket_results.duplicated(
        ["scenario_name", "member_id", "maturity_bucket"]
    ).any()
    numeric_nonnegative = [
        "market_value_usd",
        "repo_exposure_allocated_usd",
        "collateral_inventory_allocated_usd",
        "baseline_required_collateral_usd",
        "stressed_required_collateral_before_call_usd",
        "additional_collateral_requirement_usd",
        "stressed_available_collateral_usd",
        "collateral_posted_usd",
        "collateral_shortfall_usd",
        "qualified_resource_reduction_usd",
    ]
    nonnegative = (bucket_results[numeric_nonnegative] >= -tolerance).all().all()
    finite = bucket_results[numeric_nonnegative].apply(
        lambda series: series.map(math.isfinite)
    ).all().all()

    haircut_bounds = (
        (
            bucket_results["stressed_haircut_rate"]
            >= bucket_results["base_haircut_rate"] - 1e-12
        )
        & (
            bucket_results["stressed_haircut_rate"]
            <= bucket_results["maximum_haircut_rate"] + 1e-12
        )
        & (bucket_results["stressed_haircut_rate"] < 1.0)
    ).all()

    requirement_identity = (
        (
            bucket_results["additional_collateral_requirement_usd"]
            - bucket_results["haircut_driven_collateral_call_usd"]
            - bucket_results["scenario_additional_collateral_call_usd"]
        ).abs()
        <= tolerance
    ).all()
    constraint_identity = (
        (
            bucket_results["collateral_posted_usd"]
            <= bucket_results["stressed_available_collateral_usd"] + tolerance
        )
        & (
            (
                bucket_results["collateral_shortfall_usd"]
                - (
                    bucket_results["additional_collateral_requirement_usd"]
                    - bucket_results["collateral_posted_usd"]
                )
            ).abs()
            <= tolerance
        )
    ).all()

    member_liquidity_identity = (
        (
            member_summary["stressed_liquidity_headroom_usd"]
            - (
                member_summary["stressed_available_resources_usd"]
                - member_summary["stressed_liquidity_need_usd"]
            )
        ).abs()
        <= tolerance
    ).all() and (
        (
            member_summary["stressed_liquidity_shortfall_usd"]
            - (-member_summary["stressed_liquidity_headroom_usd"]).clip(lower=0.0)
        ).abs()
        <= tolerance
    ).all()

    control = member_summary.loc[member_summary["severity_rank"] == 0]
    control_zero = (
        not control.empty
        and (control["additional_collateral_requirement_total_usd"].abs() <= tolerance).all()
        and (control["collateral_resource_reduction_usd"].abs() <= tolerance).all()
        and (
            (
                control["stressed_available_resources_usd"]
                - control["baseline_available_resources_usd"]
            ).abs()
            <= tolerance
        ).all()
    )

    haircut_monotonic = True
    for _, group in bucket_results.sort_values("severity_rank").groupby(
        ["member_id", "maturity_bucket"], sort=False
    ):
        if (group["stressed_haircut_rate"].diff().dropna() < -1e-12).any():
            haircut_monotonic = False
            break

    synthetic_only = (
        bucket_results["member_id"]
        .astype(str)
        .map(lambda value: re.fullmatch(settings.synthetic_id_pattern, value) is not None)
        .all()
        and not bucket_results["actual_ficc_participant"].astype(bool).any()
        and not bucket_results["participant_level_inference"].astype(bool).any()
    )

    scenario_aggregates = (
        len(scenario_summary) == len(settings.scenarios)
        and scenario_summary["scenario_name"].nunique() == len(settings.scenarios)
    )
    baseline_complete = set(member_buckets["member_id"]) == set(baseline["member_id"])

    return {
        "complete_bucket_matrix": len(bucket_results) == expected_bucket_rows,
        "complete_member_matrix": len(member_summary) == expected_member_rows,
        "unique_bucket_keys": key_unique,
        "finite_nonnegative_amounts": bool(finite and nonnegative),
        "haircut_bounds": bool(haircut_bounds),
        "additional_requirement_identity": bool(requirement_identity),
        "available_collateral_constraint": bool(constraint_identity),
        "liquidity_identities": bool(member_liquidity_identity),
        "zero_shock_control": bool(control_zero),
        "severity_monotonicity": bool(haircut_monotonic),
        "scenario_aggregation_complete": bool(scenario_aggregates),
        "baseline_member_coverage": bool(baseline_complete),
        "synthetic_identity_controls": bool(synthetic_only),
    }


def calculate_collateral_haircut_stress(
    members: pd.DataFrame,
    baseline: pd.DataFrame,
    settings: CollateralHaircutStressSettings,
) -> CollateralHaircutStressResult:
    """Calculate controlled Section 17 haircut stress."""
    member_buckets = prepare_members(members, settings)
    baseline_final = prepare_baseline(baseline, settings)

    scenario_frames = [
        _scenario_bucket_results(member_buckets, scenario)
        for scenario in settings.scenarios
    ]
    bucket_results = pd.concat(scenario_frames, ignore_index=True)
    bucket_results["model_version"] = settings.model_version
    bucket_results = bucket_results.sort_values(
        ["severity_rank", "member_id", "bucket_order"], kind="stable"
    ).reset_index(drop=True)

    member_summary = _build_member_summary(
        bucket_results,
        baseline_final,
        settings,
    )
    scenario_summary = _build_scenario_summary(member_summary)
    checks = validate_results(
        bucket_results,
        member_summary,
        scenario_summary,
        member_buckets,
        baseline_final,
        settings,
    )
    return CollateralHaircutStressResult(
        bucket_results=bucket_results,
        member_summary=member_summary,
        scenario_summary=scenario_summary,
        checks=checks,
    )


def run_model(
    members: pd.DataFrame,
    baseline: pd.DataFrame,
    config: Mapping[str, Any],
) -> CollateralHaircutStressResult:
    """Load settings and execute the Section 17 model."""
    return calculate_collateral_haircut_stress(
        members,
        baseline,
        load_settings(config),
    )
'@

$RunnerContent = @'
"""Run Phase V, Section 17 collateral haircut stress."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    CollateralHaircutStressResult,
    dataframe_digest,
    load_config,
    read_table,
    run_model,
)


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Run Section 17 collateral haircut stress."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "collateral_haircut_stress.yaml",
    )
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--baseline", type=Path, default=None)
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
        default=ROOT / "data" / "manifests" / "collateral_haircut_stress_manifest.csv",
    )
    parser.add_argument(
        "--allow-demo",
        action="store_true",
        help="Allow controlled synthetic smoke inputs when prior-section files are absent.",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Label generated outputs as smoke-test artifacts.",
    )
    return parser.parse_args()


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing candidate path."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def demo_members() -> pd.DataFrame:
    """Return controlled fictional members for smoke testing only."""
    records: list[dict[str, object]] = []
    maturity_scales = [
        (0.30, 0.22, 0.18, 0.12, 0.12, 0.06),
        (0.12, 0.16, 0.19, 0.18, 0.23, 0.12),
        (0.72, 0.08, 0.06, 0.05, 0.05, 0.04),
    ]
    for number, weights in enumerate(maturity_scales, start=1):
        total = 1_000_000_000.0 * (1.0 - 0.18 * (number - 1))
        positions = [total * weight for weight in weights]
        repo_need = total * (0.42 + 0.04 * number)
        collateral_inventory = total * (0.78 + 0.03 * number)
        qlr = collateral_inventory * 0.62
        records.append(
            {
                "member_id": f"SYN-MBR-{number:04d}",
                "treasury_position_bills_0_1y_usd": positions[0],
                "treasury_position_notes_1_3y_usd": positions[1],
                "treasury_position_notes_3_7y_usd": positions[2],
                "treasury_position_notes_7_10y_usd": positions[3],
                "treasury_position_bonds_10_30y_usd": positions[4],
                "treasury_position_strips_30y_plus_usd": positions[5],
                "total_treasury_position_usd": total,
                "repo_financing_need_usd": repo_need,
                "collateral_inventory_usd": collateral_inventory,
                "available_qualified_liquid_resources_usd": qlr,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(records)


def demo_baseline(members: pd.DataFrame) -> pd.DataFrame:
    """Return controlled final-horizon liquidity rows for smoke testing."""
    records: list[dict[str, object]] = []
    for index, row in members.reset_index(drop=True).iterrows():
        resources = float(row["available_qualified_liquid_resources_usd"]) + (
            120_000_000.0 - 10_000_000.0 * index
        )
        need = resources * (0.80 + 0.04 * index)
        headroom = resources - need
        records.append(
            {
                "member_id": row["member_id"],
                "bucket_order": 5,
                "time_bucket": "day2_close",
                "cumulative_net_liquidity_need_usd": need,
                "cumulative_available_resources_usd": resources,
                "eligible_collateral_liquidity_usd": row[
                    "available_qualified_liquid_resources_usd"
                ],
                "available_cash_usd": resources
                - float(row["available_qualified_liquid_resources_usd"]),
                "liquidity_headroom_usd": headroom,
                "liquidity_shortfall_usd": max(-headroom, 0.0),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(records)


def file_sha256(path: Path) -> str:
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
    """Write controlled tabular outputs."""
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


def result_gates(
    result: CollateralHaircutStressResult,
    deterministic: bool,
) -> dict[str, str]:
    """Translate model checks into completion gates."""
    gates = {
        name.replace("_", " ").title(): "PASS" if passed else "FAIL"
        for name, passed in result.checks.items()
    }
    gates["Deterministic Reproduction"] = "PASS" if deterministic else "FAIL"
    required_columns = {
        "base_haircut_rate",
        "stressed_haircut_rate",
        "concentration_haircut_addon",
        "additional_collateral_requirement_usd",
        "stressed_available_collateral_usd",
        "collateral_shortfall_usd",
    }
    gates["All Required Stress Channels"] = (
        "PASS"
        if required_columns.issubset(result.bucket_results.columns)
        else "FAIL"
    )
    return gates


def manifest_rows(
    paths: list[tuple[Path, str, int | None]],
    generated_at: str,
) -> pd.DataFrame:
    """Create controlled artifact lineage rows."""
    rows: list[dict[str, object]] = []
    for path, value_class, row_count in paths:
        rows.append(
            {
                "section": 17,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "value_class": value_class,
                "row_count": row_count,
                "sha256": file_sha256(path),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(rows)


def main() -> int:
    """Run Section 17 and return a process exit code."""
    args = parse_args()
    config = load_config(args.config)
    source = config["source"]

    member_path = args.members or discover_input(
        ROOT, list(source["member_profile_candidates"])
    )
    baseline_path = args.baseline or discover_input(
        ROOT, list(source["baseline_cashflow_candidates"])
    )

    if member_path is None or baseline_path is None:
        if not args.allow_demo:
            missing = []
            if member_path is None:
                missing.append("synthetic member profiles")
            if baseline_path is None:
                missing.append("baseline liquidity cash flows")
            raise FileNotFoundError(
                "Required prior-section inputs were not found: "
                + ", ".join(missing)
                + ". Supply explicit paths or use --allow-demo only for smoke testing."
            )
        members = demo_members()
        baseline = demo_baseline(members)
        member_source = "CONTROLLED_SYNTHETIC_SMOKE_DATA"
        baseline_source = "CONTROLLED_BASELINE_SMOKE_DATA"
    else:
        members = read_table(member_path)
        baseline = read_table(baseline_path)
        member_source = str(member_path.resolve())
        baseline_source = str(baseline_path.resolve())

    first = run_model(members, baseline, config)
    second = run_model(
        members.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        baseline.sample(frac=1.0, random_state=2027).reset_index(drop=True),
        config,
    )
    deterministic = (
        dataframe_digest(first.bucket_results)
        == dataframe_digest(second.bucket_results)
        and dataframe_digest(first.member_summary)
        == dataframe_digest(second.member_summary)
        and dataframe_digest(first.scenario_summary)
        == dataframe_digest(second.scenario_summary)
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)

    suffix = "_smoke" if args.smoke else ""
    output = config["output"]
    written: list[Path] = []
    written.extend(
        write_frame(
            first.bucket_results,
            args.output_dir / f"collateral_haircut_stress_bucket_results{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.member_summary,
            args.output_dir / f"collateral_haircut_stress_member_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.scenario_summary,
            args.output_dir / f"collateral_haircut_stress_scenario_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )

    gates = result_gates(first, deterministic)
    generated_at = datetime.now(UTC).isoformat()
    evidence = {
        "section": 17,
        "model": config["model_name"],
        "model_version": config["model_version"],
        "generated_at_utc": generated_at,
        "run_type": "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN",
        "member_source": member_source,
        "baseline_source": baseline_source,
        "bucket_rows": len(first.bucket_results),
        "member_scenario_rows": len(first.member_summary),
        "scenario_rows": len(first.scenario_summary),
        "scenario_names": first.scenario_summary["scenario_name"].tolist(),
        "bucket_result_sha256": dataframe_digest(first.bucket_results),
        "member_summary_sha256": dataframe_digest(first.member_summary),
        "gates": gates,
        "limitations": [
            "Haircuts are controlled model assumptions, not participant-level contractual terms.",
            "Public aggregate data do not disclose actual FICC member collateral inventories.",
            "Treasury positions and members are fictional synthetic records.",
            "The model is a deterministic scenario overlay and not a market equilibrium model.",
        ],
    }

    evidence_json = (
        args.evidence_dir / f"section17_collateral_haircut_stress{suffix}.json"
    )
    evidence_json.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    evidence_md = (
        args.evidence_dir / f"section17_collateral_haircut_stress{suffix}.md"
    )
    gate_lines = "\n".join(
        f"- {name}: **{status}**" for name, status in gates.items()
    )
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 17 Collateral Haircut-Stress Evidence",
                "",
                f"- Generated at (UTC): {generated_at}",
                f"- Run type: {evidence['run_type']}",
                f"- Synthetic member source: `{member_source}`",
                f"- Baseline liquidity source: `{baseline_source}`",
                f"- Bucket-scenario rows: {len(first.bucket_results):,}",
                f"- Member-scenario rows: {len(first.member_summary):,}",
                f"- Result SHA-256: `{evidence['bucket_result_sha256']}`",
                "",
                "## Completion gates",
                "",
                gate_lines,
                "",
                "## Scope limitation",
                "",
                "All member records are fictional and synthetic. No output identifies, "
                "represents, ranks, or infers an actual FICC participant.",
                "",
            ]
        ),
        encoding="utf-8",
    )

    lineage: list[tuple[Path, str, int | None]] = [
        (args.config, "assumed", None),
        *[
            (
                path,
                "modeled",
                (
                    len(first.bucket_results)
                    if "bucket_results" in path.name
                    else len(first.member_summary)
                    if "member_summary" in path.name
                    else len(first.scenario_summary)
                ),
            )
            for path in written
        ],
        (evidence_json, "modeled", None),
        (evidence_md, "modeled", None),
    ]
    if member_path is not None:
        lineage.append((member_path, "synthetic", len(members)))
    if baseline_path is not None:
        lineage.append((baseline_path, "modeled", len(baseline)))
    manifest = manifest_rows(lineage, generated_at)
    manifest.to_csv(args.manifest, index=False)

    print(first.scenario_summary.to_string(index=False))
    print("\nCompletion gates:")
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
# mypy: ignore-errors
"""Tests for Phase V, Section 17 collateral haircut stress."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any

import pandas as pd
import pytest

from ficc_liquidity.stress.collateral_haircut_stress import (
    CollateralHaircutStressError,
    dataframe_digest,
    load_settings,
    prepare_baseline,
    prepare_members,
    read_table,
    run_model,
)


def config() -> dict[str, Any]:
    """Return a compact valid Section 17 configuration."""
    return {
        "model_version": "section-17-test",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "maturity_buckets": {
            "short": {
                "source_columns": ["treasury_short_usd"],
                "base_haircut_rate": 0.01,
                "eligibility_factor": 1.00,
            },
            "long": {
                "source_columns": ["treasury_long_usd"],
                "base_haircut_rate": 0.08,
                "eligibility_factor": 0.90,
            },
        },
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "stress_multiplier": 1.0,
                "additive_haircut_rate": 0.0,
                "bucket_addons": {"short": 0.0, "long": 0.0},
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "additional_collateral_call_rate": 0.0,
                "inventory_availability_rate": 1.0,
                "maximum_haircut_rate": 0.50,
            },
            {
                "name": "moderate",
                "enabled": True,
                "severity_rank": 1,
                "stress_multiplier": 1.25,
                "additive_haircut_rate": 0.01,
                "bucket_addons": {"short": 0.0, "long": 0.02},
                "concentration_threshold": 0.60,
                "concentration_multiplier": 0.20,
                "additional_collateral_call_rate": 0.02,
                "inventory_availability_rate": 0.90,
                "maximum_haircut_rate": 0.50,
            },
            {
                "name": "severe",
                "enabled": True,
                "severity_rank": 2,
                "stress_multiplier": 2.0,
                "additive_haircut_rate": 0.03,
                "bucket_addons": {"short": 0.01, "long": 0.05},
                "concentration_threshold": 0.40,
                "concentration_multiplier": 0.50,
                "additional_collateral_call_rate": 0.08,
                "inventory_availability_rate": 0.50,
                "maximum_haircut_rate": 0.50,
            },
        ],
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


def members() -> pd.DataFrame:
    """Return fictional synthetic member profiles."""
    return pd.DataFrame(
        [
            {
                "member_id": "SYN-MBR-0001",
                "treasury_short_usd": 700.0,
                "treasury_long_usd": 300.0,
                "total_treasury_position_usd": 1000.0,
                "repo_financing_need_usd": 400.0,
                "collateral_inventory_usd": 900.0,
                "available_qualified_liquid_resources_usd": 600.0,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            },
            {
                "member_id": "SYN-MBR-0002",
                "treasury_short_usd": 200.0,
                "treasury_long_usd": 800.0,
                "total_treasury_position_usd": 1000.0,
                "repo_financing_need_usd": 650.0,
                "collateral_inventory_usd": 720.0,
                "available_qualified_liquid_resources_usd": 450.0,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            },
        ]
    )


def baseline() -> pd.DataFrame:
    """Return two time buckets per fictional member."""
    rows: list[dict[str, object]] = []
    for member_id, resources, need, eligible, cash in (
        ("SYN-MBR-0001", 700.0, 500.0, 600.0, 100.0),
        ("SYN-MBR-0002", 500.0, 475.0, 450.0, 50.0),
    ):
        rows.extend(
            [
                {
                    "member_id": member_id,
                    "bucket_order": 1,
                    "time_bucket": "open",
                    "cumulative_net_liquidity_need_usd": need * 0.5,
                    "cumulative_available_resources_usd": resources,
                    "eligible_collateral_liquidity_usd": eligible,
                    "available_cash_usd": cash,
                    "liquidity_headroom_usd": resources - need * 0.5,
                    "liquidity_shortfall_usd": 0.0,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                },
                {
                    "member_id": member_id,
                    "bucket_order": 2,
                    "time_bucket": "close",
                    "cumulative_net_liquidity_need_usd": need,
                    "cumulative_available_resources_usd": resources,
                    "eligible_collateral_liquidity_usd": eligible,
                    "available_cash_usd": cash,
                    "liquidity_headroom_usd": resources - need,
                    "liquidity_shortfall_usd": max(need - resources, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                },
            ]
        )
    return pd.DataFrame.from_records(rows)


def test_settings_validate_and_order_scenarios() -> None:
    settings = load_settings(config())
    assert [item.name for item in settings.scenarios] == [
        "control",
        "moderate",
        "severe",
    ]
    assert [item.name for item in settings.maturity_buckets] == ["short", "long"]


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("maturity_buckets", "short", "base_haircut_rate"), 1.0),
        (("scenarios", 1, "stress_multiplier"), 0.9),
        (("scenarios", 1, "inventory_availability_rate"), 1.1),
        (("validation", "reconciliation_tolerance_usd"), -1.0),
    ],
)
def test_invalid_settings_are_rejected(
    path: tuple[object, ...],
    value: object,
) -> None:
    raw = deepcopy(config())
    target: Any = raw
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    with pytest.raises(CollateralHaircutStressError):
        load_settings(raw)


def test_complete_model_passes_all_controls() -> None:
    result = run_model(members(), baseline(), config())
    assert result.passed
    assert all(result.checks.values())
    assert len(result.bucket_results) == 12
    assert len(result.member_summary) == 6
    assert len(result.scenario_summary) == 3


def test_control_scenario_is_zero_incremental_stress() -> None:
    result = run_model(members(), baseline(), config())
    control = result.member_summary.query("scenario_name == 'control'")
    assert control["additional_collateral_requirement_total_usd"].eq(0.0).all()
    assert control["collateral_resource_reduction_usd"].eq(0.0).all()
    assert (
        control["stressed_available_resources_usd"]
        == control["baseline_available_resources_usd"]
    ).all()


def test_haircuts_are_maturity_and_stress_dependent() -> None:
    result = run_model(members(), baseline(), config())
    member = result.bucket_results.query("member_id == 'SYN-MBR-0001'")
    control = member.query("scenario_name == 'control'").set_index("maturity_bucket")
    severe = member.query("scenario_name == 'severe'").set_index("maturity_bucket")
    assert control.loc["long", "base_haircut_rate"] > control.loc[
        "short", "base_haircut_rate"
    ]
    assert severe.loc["short", "stressed_haircut_rate"] > control.loc[
        "short", "stressed_haircut_rate"
    ]
    assert severe.loc["long", "stressed_haircut_rate"] > severe.loc[
        "short", "stressed_haircut_rate"
    ]


def test_concentration_multiplier_increases_haircut() -> None:
    result = run_model(members(), baseline(), config())
    severe = result.bucket_results.query("scenario_name == 'severe'")
    concentrated = severe.query(
        "member_id == 'SYN-MBR-0002' and maturity_bucket == 'long'"
    ).iloc[0]
    less_concentrated = severe.query(
        "member_id == 'SYN-MBR-0001' and maturity_bucket == 'long'"
    ).iloc[0]
    assert concentrated["bucket_weight"] > less_concentrated["bucket_weight"]
    assert (
        concentrated["concentration_haircut_addon"]
        > less_concentrated["concentration_haircut_addon"]
    )


def test_additional_collateral_requirement_decomposes() -> None:
    result = run_model(members(), baseline(), config())
    severe = result.bucket_results.query("scenario_name == 'severe'")
    expected = (
        severe["haircut_driven_collateral_call_usd"]
        + severe["scenario_additional_collateral_call_usd"]
    )
    pd.testing.assert_series_equal(
        severe["additional_collateral_requirement_usd"].reset_index(drop=True),
        expected.reset_index(drop=True),
        check_names=False,
    )


def test_available_collateral_constraint_creates_shortfall() -> None:
    constrained = members()
    constrained.loc[:, "collateral_inventory_usd"] = 300.0
    result = run_model(constrained, baseline(), config())
    severe = result.member_summary.query("scenario_name == 'severe'")
    assert (severe["collateral_shortfall_total_usd"] > 0.0).any()
    bucket = result.bucket_results.query("scenario_name == 'severe'")
    assert (
        bucket["collateral_posted_usd"]
        <= bucket["stressed_available_collateral_usd"] + 0.01
    ).all()


def test_more_inventory_reduces_collateral_shortfall() -> None:
    low = members()
    low.loc[:, "collateral_inventory_usd"] = 300.0
    high = members()
    high.loc[:, "collateral_inventory_usd"] = 1500.0
    low_result = run_model(low, baseline(), config())
    high_result = run_model(high, baseline(), config())
    low_shortfall = low_result.scenario_summary.query(
        "scenario_name == 'severe'"
    )["collateral_shortfall_total_usd"].iloc[0]
    high_shortfall = high_result.scenario_summary.query(
        "scenario_name == 'severe'"
    )["collateral_shortfall_total_usd"].iloc[0]
    assert high_shortfall <= low_shortfall


def test_synthetic_identity_controls_reject_actual_or_invalid_members() -> None:
    invalid = members()
    invalid.loc[0, "member_id"] = "ACTUAL-MEMBER"
    with pytest.raises(CollateralHaircutStressError):
        run_model(invalid, baseline(), config())

    actual = members()
    actual.loc[0, "actual_ficc_participant"] = True
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(actual, load_settings(config()))


def test_missing_required_inputs_are_rejected() -> None:
    missing_member_field = members().drop(columns=["collateral_inventory_usd"])
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(missing_member_field, load_settings(config()))

    missing_baseline_field = baseline().drop(
        columns=["cumulative_available_resources_usd"]
    )
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(missing_baseline_field, load_settings(config()))


def test_deterministic_under_input_row_reordering() -> None:
    first = run_model(members(), baseline(), config())
    second = run_model(
        members().sample(frac=1.0, random_state=10).reset_index(drop=True),
        baseline().sample(frac=1.0, random_state=11).reset_index(drop=True),
        config(),
    )
    assert dataframe_digest(first.bucket_results) == dataframe_digest(
        second.bucket_results
    )
    assert dataframe_digest(first.member_summary) == dataframe_digest(
        second.member_summary
    )


def test_csv_read_table_and_unsupported_extension(tmp_path: Path) -> None:
    csv_path = tmp_path / "members.csv"
    members().to_csv(csv_path, index=False)
    loaded = read_table(csv_path)
    assert len(loaded) == len(members())

    unsupported = tmp_path / "members.txt"
    unsupported.write_text("not a table", encoding="utf-8")
    with pytest.raises(CollateralHaircutStressError):
        read_table(unsupported)


def test_config_and_table_path_errors(tmp_path: Path) -> None:
    from ficc_liquidity.stress.collateral_haircut_stress import load_config

    with pytest.raises(CollateralHaircutStressError):
        load_config(tmp_path / "missing.yaml")
    with pytest.raises(CollateralHaircutStressError):
        read_table(tmp_path / "missing.csv")


def test_position_reconciliation_and_source_column_errors() -> None:
    settings = load_settings(config())
    mismatched = members()
    mismatched.loc[0, "total_treasury_position_usd"] = 9999.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(mismatched, settings)

    missing_bucket = members().drop(columns=["treasury_long_usd"])
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(missing_bucket, settings)


def test_baseline_accounting_identity_errors() -> None:
    settings = load_settings(config())
    bad_headroom = baseline()
    bad_headroom.loc[
        bad_headroom["bucket_order"] == 2, "liquidity_headroom_usd"
    ] += 10.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(bad_headroom, settings)

    bad_shortfall = baseline()
    bad_shortfall.loc[
        bad_shortfall["bucket_order"] == 2, "liquidity_shortfall_usd"
    ] = 10.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(bad_shortfall, settings)


def test_disabled_scenarios_and_duplicate_scenarios_are_rejected() -> None:
    no_enabled = deepcopy(config())
    for scenario in no_enabled["scenarios"]:
        scenario["enabled"] = False
    with pytest.raises(CollateralHaircutStressError):
        load_settings(no_enabled)

    duplicate = deepcopy(config())
    duplicate["scenarios"][2]["name"] = "moderate"
    with pytest.raises(CollateralHaircutStressError):
        load_settings(duplicate)


def test_more_configuration_validation_branches() -> None:
    unknown_bucket = deepcopy(config())
    unknown_bucket["scenarios"][1]["bucket_addons"]["unknown"] = 0.01
    with pytest.raises(CollateralHaircutStressError):
        load_settings(unknown_bucket)

    duplicate_rank = deepcopy(config())
    duplicate_rank["scenarios"][2]["severity_rank"] = 1
    with pytest.raises(CollateralHaircutStressError):
        load_settings(duplicate_rank)

    nonmonotonic = deepcopy(config())
    nonmonotonic["scenarios"][2]["additional_collateral_call_rate"] = 0.01
    with pytest.raises(CollateralHaircutStressError):
        load_settings(nonmonotonic)


def test_member_numeric_and_classification_controls() -> None:
    settings = load_settings(config())
    negative = members()
    negative.loc[0, "repo_financing_need_usd"] = -1.0
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(negative, settings)

    wrong_class = members()
    wrong_class.loc[0, "value_class"] = "observed"
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(wrong_class, settings)

    duplicate = pd.concat([members(), members().iloc[[0]]], ignore_index=True)
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(duplicate, settings)


def test_baseline_identity_and_numeric_controls() -> None:
    settings = load_settings(config())
    nonnumeric = baseline()
    nonnumeric["available_cash_usd"] = nonnumeric["available_cash_usd"].astype(object)
    nonnumeric.loc[0, "available_cash_usd"] = "bad"
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(nonnumeric, settings)

    actual = baseline()
    actual.loc[0, "participant_level_inference"] = True
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(actual, settings)


def test_empty_inputs_are_rejected() -> None:
    settings = load_settings(config())
    with pytest.raises(CollateralHaircutStressError):
        prepare_members(pd.DataFrame(), settings)
    with pytest.raises(CollateralHaircutStressError):
        prepare_baseline(pd.DataFrame(), settings)
'@

$MethodologyContent = @'
# Collateral Haircut-Stress Methodology

## Purpose

Phase V, Section 17 measures how collateral haircut increases affect the
liquidity position of fictional synthetic clearing members. The model separates
the haircut mechanism from the Section 15 Treasury price-shock model and the
Section 16 repo funding-stress model so each risk channel can be validated
independently before combined scenario aggregation.

The implementation does not use, identify, represent, rank, or infer any actual
FICC participant. All member-level records are fictional synthetic observations.

## Controlled inputs

The model uses:

- Section 12 calibrated synthetic member portfolios;
- Section 14 baseline liquidity cash flows;
- explicit maturity-bucket haircut assumptions in
  `configs/collateral_haircut_stress.yaml`; and
- explicit scenario, concentration, collateral-call, and inventory-availability
  assumptions.

## Maturity-dependent baseline haircuts

Each Treasury maturity bucket has a controlled baseline haircut and eligibility
factor. Longer-duration collateral receives a larger baseline haircut and may
receive a lower eligibility factor. The default configuration covers:

- bills from zero to one year;
- notes from one to three years;
- notes from three to seven years;
- notes from seven to ten years;
- bonds from ten to thirty years; and
- STRIPS or other Treasury exposures beyond thirty years.

## Stress-dependent haircuts

For member \(i\), maturity bucket \(b\), and scenario \(s\), the stressed
haircut is:

\[
h_{i,b,s} =
\min\left(
h_s^{\max},
\max\left[
h_b,
h_b m_s + a_s + a_{b,s} + c_{i,b,s}
\right]
\right),
\]

where:

- \(h_b\) is the baseline maturity haircut;
- \(m_s\) is the scenario stress multiplier;
- \(a_s\) is the scenario additive haircut;
- \(a_{b,s}\) is the maturity-specific scenario addon; and
- \(c_{i,b,s}\) is the concentration addon.

The stressed haircut cannot fall below the baseline haircut or exceed the
scenario maximum.

## Concentration multiplier

The member's Treasury collateral is converted to maturity-bucket weights. The
concentration addon is:

\[
c_{i,b,s} =
\max(w_{i,b} - \tau_s, 0)\gamma_s,
\]

where \(w_{i,b}\) is the bucket share, \(\tau_s\) is the scenario concentration
threshold, and \(\gamma_s\) is the concentration multiplier. This produces a
larger haircut for concentrated maturity exposures without using participant-
specific information.

## Additional collateral requirement

Repo financing need is allocated across maturity buckets using the synthetic
Treasury collateral weights. Required collateral before and after stress is:

\[
C^{base}_{i,b} = \frac{E_{i,b}}{1-h_b},
\qquad
C^{stress}_{i,b,s} = \frac{E_{i,b}}{1-h_{i,b,s}},
\]

where \(E_{i,b}\) is allocated repo exposure.

The haircut-driven collateral call is:

\[
\Delta C^{haircut}_{i,b,s}
=
\max(C^{stress}_{i,b,s} - C^{base}_{i,b}, 0).
\]

An explicit scenario collateral-call rate is added to capture non-haircut
collateral demands. Total additional collateral requirement equals the
haircut-driven call plus the scenario call.

## Available-collateral constraint

Collateral inventory is allocated across maturity buckets and capped by the
bucket's Treasury market value. Baseline excess inventory is reduced by:

- the maturity eligibility factor;
- the scenario inventory-availability rate; and
- the stressed-to-baseline collateral valuation factor.

Collateral posted cannot exceed stressed available collateral. Any remaining
requirement is a collateral shortfall:

\[
S_{i,b,s}
=
\max(\Delta C_{i,b,s} - A_{i,b,s}, 0).
\]

## Liquidity integration

Haircut value loss, inventory unavailability, and collateral posted reduce
eligible collateral resources. The resource reduction is capped by the
synthetic member's available qualified liquid resources and by the Section 14
baseline eligible-collateral liquidity amount.

Collateral shortfall increases stressed liquidity need. The model recalculates:

- stressed eligible collateral liquidity;
- stressed total available resources;
- stressed liquidity need;
- stressed liquidity headroom;
- stressed liquidity shortfall; and
- stressed liquidity coverage ratio.

## Validation controls

The implementation validates:

- complete member-scenario-maturity output;
- unique scenario, member, and maturity keys;
- finite and nonnegative monetary amounts;
- baseline and maximum haircut bounds;
- additional collateral requirement decomposition;
- collateral-posting limits;
- collateral-shortfall identities;
- liquidity headroom and shortfall identities;
- exact zero-shock control behavior;
- nondecreasing haircut severity;
- complete scenario aggregation;
- deterministic reproduction under input row reordering; and
- synthetic-only member identity controls.

## Limitations

- Haircuts are scenario assumptions rather than observed contractual terms.
- Public aggregate data do not disclose actual participant collateral inventory,
  encumbrance, substitutions, or bilateral haircut schedules.
- Repo exposure is allocated by Treasury maturity weights rather than instrument-
  level financing records.
- The model is a deterministic risk overlay, not an equilibrium model of
  collateral transformation or dealer behavior.
- Results must not be interpreted as estimates for an actual FICC participant.
'@


    Write-Utf8File -Path "configs\collateral_haircut_stress.yaml" -Content $ConfigContent
    Write-Utf8File `
        -Path "src\ficc_liquidity\stress\collateral_haircut_stress.py" `
        -Content $ModuleContent
    Write-Utf8File `
        -Path "scripts\run_collateral_haircut_stress.py" `
        -Content $RunnerContent
    Write-Utf8File `
        -Path "tests\test_collateral_haircut_stress.py" `
        -Content $TestContent
    Write-Utf8File `
        -Path "docs\collateral_haircut_stress_methodology.md" `
        -Content $MethodologyContent

    $initPath = "src\ficc_liquidity\stress\__init__.py"
    $initText = Get-Content -LiteralPath $initPath -Raw
    if ($initText -notmatch "collateral_haircut_stress") {
        $InitAppend = @'

from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: F401
    CollateralHaircutStressError,
    CollateralHaircutStressResult,
    CollateralHaircutStressSettings,
    HaircutScenario,
    MaturityHaircut,
    calculate_collateral_haircut_stress,
)

__all__.extend(
    [
        "CollateralHaircutStressError",
        "CollateralHaircutStressResult",
        "CollateralHaircutStressSettings",
        "HaircutScenario",
        "MaturityHaircut",
        "calculate_collateral_haircut_stress",
    ]
)
'@
        Write-Utf8File -Path $initPath -Content ($initText.TrimEnd() + "`n" + $InitAppend)
    }
    Write-Pass "Section 17 configuration, model, runner, tests, and methodology created"

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
        throw "Section 17 requires Python 3.11. Found: $versionText"
    }
    Write-Pass "Python 3.11 virtual environment confirmed"

    $newPythonFiles = @(
        "src\ficc_liquidity\stress\__init__.py",
        "src\ficc_liquidity\stress\collateral_haircut_stress.py",
        "scripts\run_collateral_haircut_stress.py",
        "tests\test_collateral_haircut_stress.py"
    )

    Write-Step "Formatting and linting the Section 17 implementation"
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
            "src\ficc_liquidity\stress\collateral_haircut_stress.py",
            "tests\test_collateral_haircut_stress.py"
        ) `
        -FailureMessage "Strict Mypy validation failed."
    Write-Pass "Strict Mypy validation passed"

    Write-Step "Running focused Section 17 tests and branch coverage"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "pytest", "-p", "pytest_cov",
            "-q",
            "tests\test_collateral_haircut_stress.py",
            "-o", "addopts=",
            "--strict-config",
            "--strict-markers",
            "--cov=ficc_liquidity.stress.collateral_haircut_stress",
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under=85"
        ) `
        -FailureMessage "Focused Section 17 tests or coverage failed."
    Write-Pass "Focused Section 17 tests and coverage passed"

    Write-Step "Executing the controlled Section 17 collateral haircut-stress model"
    $runnerArguments = @(
        "scripts\run_collateral_haircut_stress.py",
        "--config", "configs\collateral_haircut_stress.yaml",
        "--output-dir", "reports\tables",
        "--evidence-dir", "reports\evidence",
        "--manifest", "data\manifests\collateral_haircut_stress_manifest.csv"
    )
    if ($AllowDemo) {
        $runnerArguments += "--allow-demo"
        $runnerArguments += "--smoke"
        Write-Warn "Controlled demo mode was explicitly enabled."
    }
    Invoke-Checked -FilePath $Python `
        -ArgumentList $runnerArguments `
        -FailureMessage "Section 17 model execution failed."
    Write-Pass "Section 17 model outputs, manifest, and validation evidence created"

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
        Write-Step "Staging controlled Section 17 deliverables"

        $regularPaths = @(
            $AutomationRelativePath,
            "configs\collateral_haircut_stress.yaml",
            "docs\collateral_haircut_stress_methodology.md",
            "scripts\run_collateral_haircut_stress.py",
            "src\ficc_liquidity\stress\__init__.py",
            "src\ficc_liquidity\stress\collateral_haircut_stress.py",
            "tests\test_collateral_haircut_stress.py"
        )
        Invoke-Checked -FilePath "git" `
            -ArgumentList (@("add", "--") + $regularPaths) `
            -FailureMessage "Unable to stage Section 17 source deliverables."

        $generatedPaths = @(
            "data\manifests\collateral_haircut_stress_manifest.csv",
            "reports\evidence\section17_collateral_haircut_stress.json",
            "reports\evidence\section17_collateral_haircut_stress.md",
            "reports\tables\collateral_haircut_stress_bucket_results.csv",
            "reports\tables\collateral_haircut_stress_member_summary.csv",
            "reports\tables\collateral_haircut_stress_scenario_summary.csv"
        )
        if ($AllowDemo) {
            $generatedPaths = @(
                "data\manifests\collateral_haircut_stress_manifest.csv",
                "reports\evidence\section17_collateral_haircut_stress_smoke.json",
                "reports\evidence\section17_collateral_haircut_stress_smoke.md",
                "reports\tables\collateral_haircut_stress_bucket_results_smoke.csv",
                "reports\tables\collateral_haircut_stress_member_summary_smoke.csv",
                "reports\tables\collateral_haircut_stress_scenario_summary_smoke.csv"
            )
        }

        foreach ($generatedPath in $generatedPaths) {
            if (-not (Test-Path -LiteralPath $generatedPath -PathType Leaf)) {
                throw "Expected generated Section 17 artifact is missing: $generatedPath"
            }
        }
        Invoke-Checked -FilePath "git" `
            -ArgumentList (@("add", "-f", "--") + $generatedPaths) `
            -FailureMessage "Unable to force-stage controlled Section 17 evidence."

        Invoke-Checked -FilePath "git" `
            -ArgumentList @("diff", "--cached", "--check") `
            -FailureMessage "Staged Section 17 changes failed whitespace validation."

        $stagedNames = @(& git diff --cached --name-only)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect staged Section 17 changes."
        }
        if ($stagedNames.Count -eq 0) {
            Write-Warn "No new staged changes were detected; the branch may already contain Section 17."
        }
        else {
            Write-Host ""
            Write-Host "Staged files:" -ForegroundColor Cyan
            $stagedNames | ForEach-Object { Write-Host "  $_" }
        }

        if (-not $NoCommit -and $stagedNames.Count -gt 0) {
            Write-Step "Committing Section 17"
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("commit", "-m", $CommitMessage) `
                -FailureMessage "Unable to commit Section 17 changes."
            Write-Pass "Section 17 commit created"
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
                Write-Step "Opening the Section 17 pull request"
                $PullRequestBody = @"
## Summary

Completes Phase V, Section 17: collateral haircut stress.

## Implemented stress channels

- Treasury haircut increases
- Maturity-dependent haircuts
- Stress-dependent haircuts
- Concentration multipliers
- Additional collateral requirements
- Available-collateral constraints

## Model integration

- Uses Section 12 calibrated synthetic member collateral profiles.
- Uses Section 14 final-horizon baseline liquidity resources and needs.
- Keeps Section 17 independent from Section 15 price shock and Section 16 funding
  stress so each channel can be validated before combined scenario aggregation.
- Preserves synthetic-only controls and prohibits participant-level inference.

## Validation

- Ruff formatting and linting
- Strict Mypy
- 24 focused Pytest cases
- Branch coverage above 85 percent
- Deterministic reproduction
- Haircut, collateral-call, inventory, resource, and liquidity identities
- Complete repository quality gates
"@
                $pullRequestUrl = & gh pr create `
                    --repo $RepoFullName `
                    --base main `
                    --head $BranchName `
                    --title $PullRequestTitle `
                    --body $PullRequestBody
                if ($LASTEXITCODE -ne 0) {
                    throw "Unable to create the Section 17 pull request."
                }
                $pullRequestUrl = ([string]$pullRequestUrl).Trim()
                Write-Pass "Pull request created: $pullRequestUrl"
            }

            if ($WatchChecks) {
                Write-Step "Watching Section 17 pull-request checks"
                Invoke-Checked -FilePath "gh" `
                    -ArgumentList @(
                        "pr", "checks", $BranchName,
                        "--repo", $RepoFullName,
                        "--watch"
                    ) `
                    -FailureMessage "One or more pull-request checks failed."
                Write-Pass "Pull-request checks passed"
            }
        }
        elseif ($SkipPullRequest) {
            Write-Warn "Pull-request creation was skipped by request."
        }
    }

    Write-Step "Section 17 automation completed"
    Write-Pass "Treasury haircut increases implemented"
    Write-Pass "Maturity- and stress-dependent haircuts implemented"
    Write-Pass "Concentration multipliers implemented"
    Write-Pass "Additional collateral requirements implemented"
    Write-Pass "Available-collateral constraints implemented"
    Write-Pass "Synthetic identity and participant-inference controls passed"

    Write-Host ""
    Write-Host "Branch: $BranchName"
    Write-Host "Evidence: reports\evidence\section17_collateral_haircut_stress.md"
    Write-Host "Scenario summary: reports\tables\collateral_haircut_stress_scenario_summary.csv"
    if ($AllowDemo) {
        Write-Warn "The committed outputs are smoke-test artifacts because -AllowDemo was used."
    }
}
catch {
    Write-Host ""
    Write-Host "[FAIL] Section 17 automation stopped." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
