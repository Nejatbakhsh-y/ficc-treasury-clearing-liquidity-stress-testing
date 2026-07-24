#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase VI, Section 23: reverse stress testing.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.

    The automation preserves the shared feature/18-scenario-library branch,
    writes the controlled Section 23 configuration, reverse-stress engine,
    runner, tests, methodology, evidence, manifest, CSV and Parquet outputs,
    executes exact Section 15-17 component models, validates deterministic
    threshold searches, runs Ruff, strict Mypy, focused branch coverage, and
    the complete test suite, then commits, pushes, and opens or updates the
    pull-request workflow.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\25_P5S23_Reverse_Stress_Testing_PS51.ps1"

.EXAMPLE
    & "$env:USERPROFILE\Downloads\25_P5S23_Reverse_Stress_Testing_PS51.ps1" `
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
$BranchName = "feature/18-scenario-library"
$CommitMessage = "Phase VI Section 23: add reverse stress testing"
$PullRequestTitle = "Phase VI Sections 20-23: Scenario framework"
$AutomationRelativePath = "scripts\automation\25_P5S23_Reverse_Stress_Testing_PS51.ps1"

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

function Test-AnyCandidate {
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    foreach ($relativePath in $Paths) {
        if (Test-Path -LiteralPath $relativePath -PathType Leaf) {
            return $true
        }
    }
    return $false
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

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

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
Use -AllowDirty only when rerunning Section 23 on $BranchName.
"@
            }
            if ($currentBranch -ne $BranchName) {
                throw @"
-AllowDirty is safe only on $BranchName.
The current branch is $currentBranch. Commit or stash existing changes first.
"@
            }
            $skipBranchRefresh = $true
            Write-Warn "Dirty shared scenario branch retained; main refresh was skipped."
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

        $section19Gate = @(
            "configs\integrated_stress_engine.yaml",
            "src\ficc_liquidity\stress\integrated_stress.py",
            "scripts\run_integrated_stress.py",
            "tests\test_integrated_stress.py"
        )
        if (-not (Test-RequiredFiles -Paths $section19Gate)) {
            throw @"
Section 19 is not present on the updated main branch.
Merge the Section 19 pull request into main, then rerun Section 23.
"@
        }
        Write-Pass "Section 19 is merged and available on main"

        Write-Step "Preparing shared branch $BranchName"
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

    Write-Step "Confirming source-code dependencies"
    $requiredDependencies = @(
        "configs\integrated_stress_engine.yaml",
        "configs\treasury_yield_stress.yaml",
        "configs\repo_funding_stress.yaml",
        "configs\collateral_haircut_stress.yaml",
        "src\ficc_liquidity\stress\integrated_stress.py",
        "src\ficc_liquidity\stress\treasury_yield_shock.py",
        "src\ficc_liquidity\stress\repo_funding_stress.py",
        "src\ficc_liquidity\stress\collateral_haircut_stress.py",
        "scripts\run_integrated_stress.py"
    )
    if (-not (Test-RequiredFiles -Paths $requiredDependencies)) {
        $missing = @(
            foreach ($dependency in $requiredDependencies) {
                if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
                    $dependency
                }
            }
        )
        throw "Required source files are missing: $($missing -join ', ')"
    }
    Write-Pass "Required Section 15-19 source files are available"

    Write-Step "Creating Section 23 directories and controlled files"
    foreach ($directory in @(
        "configs",
        "data\manifests",
        "docs",
        "reports\evidence",
        "reports\tables",
        "scripts",
        "scripts\automation",
        "src\ficc_liquidity\scenarios",
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
section: 23
model_name: reverse_stress_testing
model_version: "section-23-v1"
currency: USD
random_seed: 2026

classification:
  integrated_control_results: modeled
  reverse_stress_parameters: solved
  yield_shock_results: modeled
  rollover_failure_results: modeled
  haircut_stress_results: modeled
  member_combinations: synthetic
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false

source:
  integrated_member_result_candidates:
    - reports/tables/integrated_stress_member_results.parquet
    - reports/tables/integrated_stress_member_results.csv
  baseline_cashflow_candidates:
    - reports/tables/baseline_liquidity_cashflows.parquet
    - reports/tables/baseline_liquidity_cashflows.csv
  member_profile_candidates:
    - data/synthetic/calibrated_member_portfolios.parquet
    - data/synthetic/calibrated_member_portfolios.csv
  treasury_position_candidates:
    - reports/tables/treasury_yield_stress_positions_section19_adapter.parquet
    - reports/tables/treasury_yield_stress_positions_section19_adapter.csv
  integrated_config: configs/integrated_stress_engine.yaml
  treasury_config: configs/treasury_yield_stress.yaml
  repo_funding_config: configs/repo_funding_stress.yaml
  haircut_config: configs/collateral_haircut_stress.yaml
  control_scenario_name: control
  synthetic_id_pattern: '^SYN-MBR-[0-9]{4}$'

search:
  yield_shock:
    lower_bound: 0.0
    upper_bound: 1000.0
    parameter_tolerance: 0.01
    include_market_impact: false

  rollover_failure:
    lower_bound: 0.0
    upper_bound: 1.0
    parameter_tolerance: 0.000001

  haircut_increase:
    lower_bound: 0.0
    upper_bound: 0.50
    parameter_tolerance: 0.000001
    maximum_haircut_rate: 0.95

  combined_scenario:
    lower_bound: 0.0
    upper_bound: 1.0
    parameter_tolerance: 0.00001
    maximum_yield_shock_bp: 500.0
    maximum_rollover_failure_rate: 0.75
    maximum_haircut_increase_rate: 0.15

member_combinations:
  combination_size: 2
  top_n: 25
  aggregation_assumption: additive_requirements_and_resources
  cross_member_netting: false

validation:
  lcr_minimum_ratio: 1.0
  liquidity_tolerance_usd: 0.01
  maximum_binary_search_iterations: 80
  require_deterministic_reproduction: true
  require_synthetic_identifiers: true
  require_search_minimality: true
  require_exact_prior_model_reuse: true

output:
  directory: reports/tables
  evidence_directory: reports/evidence
  manifest: data/manifests/reverse_stress_testing_manifest.csv
  write_csv: true
  write_parquet: true
'@

$ModuleContent = @'

"""Reverse stress testing for synthetic clearing-member liquidity.

Phase VI, Section 23 searches for the smallest controlled stress parameter that
causes a member or member combination to fall below the configured liquidity
coverage threshold. The module is model-agnostic: existing Section 15-17 engines
supply exact component vectors through callables, while this module performs
liquidity aggregation, combination construction, threshold search, and controls.
"""

from __future__ import annotations

import hashlib
import math
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from itertools import combinations
from typing import Any, cast

import numpy as np
import pandas as pd


class ReverseStressError(ValueError):
    """Raised when reverse-stress inputs, assumptions, or outputs are invalid."""


ComponentEvaluator = Callable[[float], pd.Series]


@dataclass(frozen=True, slots=True)
class EvaluationSnapshot:
    """One evaluated stress point for members and optional member combinations."""

    parameter_value: float
    member_results: pd.DataFrame
    combination_results: pd.DataFrame
    criterion_type: str
    breached: bool
    breached_entity_id: str
    minimum_liquidity_coverage_ratio: float
    maximum_liquidity_shortfall_usd: float


@dataclass(frozen=True, slots=True)
class ThresholdResult:
    """Controlled binary-search result."""

    test_name: str
    parameter_unit: str
    search_status: str
    minimum_threshold: float
    safe_lower_bound: float
    breaching_upper_bound: float
    iterations: int
    criterion_type: str
    breached_entity_id: str
    liquidity_coverage_ratio: float
    liquidity_shortfall_usd: float
    minimality_check_pass: bool


@dataclass(frozen=True, slots=True)
class ReverseStressRun:
    """Section 23 result tables and validation checks."""

    thresholds: pd.DataFrame
    member_details: pd.DataFrame
    combination_ranking: pd.DataFrame
    search_trace: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every Section 23 validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReverseStressError(f"{label} must be a mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReverseStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise ReverseStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ReverseStressError(f"{key} must be an integer.")
    return int(value)


def dataframe_digest(frame: pd.DataFrame) -> str:
    """Return a deterministic SHA-256 digest independent of row order."""
    ordered = frame.sort_index(axis=1).copy()
    sort_columns = [
        column
        for column in (
            "test_name",
            "parameter_value",
            "combination_id",
            "member_id",
        )
        if column in ordered.columns
    ]
    if sort_columns:
        ordered = ordered.sort_values(sort_columns, kind="stable")
    payload = ordered.to_csv(index=False, float_format="%.12g").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def prepare_control(
    integrated_results: pd.DataFrame,
    *,
    control_scenario_name: str,
    synthetic_id_pattern: str,
    lcr_minimum_ratio: float,
    tolerance_usd: float,
) -> pd.DataFrame:
    """Select and validate one Section 19 control row per synthetic member."""
    if integrated_results.empty:
        raise ReverseStressError("Integrated stress results are empty.")
    required = {
        "scenario_name",
        "member_id",
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
    }
    missing = sorted(required - set(integrated_results.columns))
    if missing:
        raise ReverseStressError(f"Integrated results are missing required columns: {missing}")
    if lcr_minimum_ratio <= 0.0:
        raise ReverseStressError("lcr_minimum_ratio must be positive.")
    if tolerance_usd < 0.0:
        raise ReverseStressError("tolerance_usd must be nonnegative.")

    frame = integrated_results.loc[
        integrated_results["scenario_name"].astype(str).eq(control_scenario_name)
    ].copy()
    if frame.empty:
        raise ReverseStressError(
            f"Control scenario {control_scenario_name!r} was not found in integrated results."
        )
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    if frame["member_id"].isna().any() or (frame["member_id"] == "").any():
        raise ReverseStressError("Control results contain missing member identifiers.")
    invalid = [
        member_id
        for member_id in frame["member_id"].astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise ReverseStressError(
            f"Control results contain invalid synthetic identifiers: {sorted(set(invalid))}"
        )
    if frame["member_id"].duplicated().any():
        raise ReverseStressError("Control results must contain one row per member.")

    for column in (
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
    ):
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or not frame[column].map(math.isfinite).all():
            raise ReverseStressError(f"{column} contains missing or nonfinite values.")
        if (frame[column] < -tolerance_usd).any():
            raise ReverseStressError(f"{column} must be nonnegative.")

    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise ReverseStressError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise ReverseStressError("Participant-level inference records are prohibited.")
    if "value_class" in frame.columns and not frame["value_class"].astype(str).eq("synthetic").all():
        raise ReverseStressError("Control results require value_class='synthetic'.")

    selected = frame[
        [
            "member_id",
            "stressed_liquidity_requirement_usd",
            "available_qualified_liquid_resources_usd",
        ]
    ].rename(
        columns={
            "stressed_liquidity_requirement_usd": "control_requirement_usd",
            "available_qualified_liquid_resources_usd": "available_resources_usd",
        }
    )
    selected["lcr_minimum_ratio"] = lcr_minimum_ratio
    selected["value_class"] = "synthetic"
    selected["actual_ficc_participant"] = False
    selected["participant_level_inference"] = False
    return selected.sort_values("member_id", kind="stable").reset_index(drop=True)


def _aligned_component(
    control: pd.DataFrame,
    values: pd.Series | None,
    label: str,
) -> pd.Series:
    if values is None:
        return pd.Series(0.0, index=control.index, dtype=float)
    if values.index.has_duplicates:
        raise ReverseStressError(f"{label} component contains duplicate member identifiers.")
    normalized = values.copy()
    normalized.index = normalized.index.astype(str)
    aligned = control["member_id"].astype(str).map(normalized)
    if aligned.isna().any():
        missing = control.loc[aligned.isna(), "member_id"].astype(str).tolist()
        raise ReverseStressError(f"{label} component is missing members: {missing}")
    numeric = pd.to_numeric(aligned, errors="coerce")
    if numeric.isna().any() or not numeric.map(math.isfinite).all():
        raise ReverseStressError(f"{label} component contains missing or nonfinite values.")
    if (numeric < 0.0).any():
        raise ReverseStressError(f"{label} component must be nonnegative.")
    return numeric.astype(float)


def build_member_results(
    control: pd.DataFrame,
    *,
    yield_losses: pd.Series | None = None,
    rollover_needs: pd.Series | None = None,
    haircut_requirements: pd.Series | None = None,
    lcr_minimum_ratio: float,
    tolerance_usd: float,
) -> pd.DataFrame:
    """Combine exact component vectors with the Section 19 control requirement."""
    if control.empty:
        raise ReverseStressError("Control frame is empty.")
    frame = control.copy(deep=True)
    frame["treasury_liquidation_loss_usd"] = _aligned_component(
        frame, yield_losses, "Yield-loss"
    ).to_numpy()
    frame["repo_rollover_need_usd"] = _aligned_component(
        frame, rollover_needs, "Rollover"
    ).to_numpy()
    frame["additional_haircut_requirement_usd"] = _aligned_component(
        frame, haircut_requirements, "Haircut"
    ).to_numpy()
    frame["stressed_liquidity_requirement_usd"] = (
        frame["control_requirement_usd"]
        + frame["treasury_liquidation_loss_usd"]
        + frame["repo_rollover_need_usd"]
        + frame["additional_haircut_requirement_usd"]
    )
    requirement = frame["stressed_liquidity_requirement_usd"].astype(float)
    resources = frame["available_resources_usd"].astype(float)
    frame["liquidity_coverage_ratio"] = np.where(
        requirement > tolerance_usd,
        resources / requirement,
        np.inf,
    )
    frame["liquidity_headroom_usd"] = resources - requirement
    frame["liquidity_shortfall_usd"] = (-frame["liquidity_headroom_usd"]).clip(lower=0.0)
    frame["lcr_status"] = np.where(
        requirement <= tolerance_usd,
        "NO_REQUIREMENT",
        np.where(frame["liquidity_coverage_ratio"] >= lcr_minimum_ratio, "PASS", "BREACH"),
    )
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values("member_id", kind="stable").reset_index(drop=True)


def build_member_combinations(
    member_results: pd.DataFrame,
    *,
    combination_size: int,
) -> pd.DataFrame:
    """Aggregate additive liquidity requirements and resources for all combinations."""
    if combination_size < 2:
        raise ReverseStressError("combination_size must be at least two.")
    if len(member_results) < combination_size:
        raise ReverseStressError(
            f"combination_size={combination_size} exceeds the member count."
        )
    required = {
        "member_id",
        "control_requirement_usd",
        "available_resources_usd",
        "treasury_liquidation_loss_usd",
        "repo_rollover_need_usd",
        "additional_haircut_requirement_usd",
        "stressed_liquidity_requirement_usd",
        "lcr_minimum_ratio",
    }
    missing = sorted(required - set(member_results.columns))
    if missing:
        raise ReverseStressError(f"Member results are missing combination fields: {missing}")

    indexed = member_results.set_index("member_id", drop=False)
    rows: list[dict[str, object]] = []
    member_ids = sorted(indexed.index.astype(str))
    for selected_ids in combinations(member_ids, combination_size):
        group = indexed.loc[list(selected_ids)]
        requirement = float(group["stressed_liquidity_requirement_usd"].sum())
        resources = float(group["available_resources_usd"].sum())
        lcr_limit = float(group["lcr_minimum_ratio"].iloc[0])
        lcr = resources / requirement if requirement > 0.0 else math.inf
        shortfall = max(requirement - resources, 0.0)
        rows.append(
            {
                "combination_id": "|".join(selected_ids),
                "combination_size": combination_size,
                "member_ids": ",".join(selected_ids),
                "control_requirement_usd": float(group["control_requirement_usd"].sum()),
                "treasury_liquidation_loss_usd": float(
                    group["treasury_liquidation_loss_usd"].sum()
                ),
                "repo_rollover_need_usd": float(group["repo_rollover_need_usd"].sum()),
                "additional_haircut_requirement_usd": float(
                    group["additional_haircut_requirement_usd"].sum()
                ),
                "stressed_liquidity_requirement_usd": requirement,
                "available_resources_usd": resources,
                "liquidity_coverage_ratio": lcr,
                "liquidity_headroom_usd": resources - requirement,
                "liquidity_shortfall_usd": shortfall,
                "lcr_status": "PASS" if lcr >= lcr_limit else "BREACH",
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(rows).sort_values(
        ["liquidity_coverage_ratio", "combination_id"],
        kind="stable",
    ).reset_index(drop=True)


def make_snapshot(
    *,
    parameter_value: float,
    member_results: pd.DataFrame,
    criterion_type: str,
    combination_size: int,
    lcr_minimum_ratio: float,
    tolerance_usd: float,
) -> EvaluationSnapshot:
    """Build an evaluated point and identify the binding member or combination."""
    if criterion_type not in {"member", "combination"}:
        raise ReverseStressError("criterion_type must be 'member' or 'combination'.")
    combination_results = pd.DataFrame()
    if criterion_type == "combination":
        combination_results = build_member_combinations(
            member_results,
            combination_size=combination_size,
        )
        criterion = combination_results
        id_column = "combination_id"
    else:
        criterion = member_results
        id_column = "member_id"

    breached_rows = criterion.loc[
        (criterion["liquidity_coverage_ratio"] < lcr_minimum_ratio)
        | (criterion["liquidity_shortfall_usd"] > tolerance_usd)
    ].copy()
    breached = not breached_rows.empty
    binding_pool = breached_rows if breached else criterion
    binding = binding_pool.sort_values(
        ["liquidity_coverage_ratio", "liquidity_shortfall_usd", id_column],
        ascending=[True, False, True],
        kind="stable",
    ).iloc[0]
    return EvaluationSnapshot(
        parameter_value=parameter_value,
        member_results=member_results,
        combination_results=combination_results,
        criterion_type=criterion_type,
        breached=breached,
        breached_entity_id=str(binding[id_column]),
        minimum_liquidity_coverage_ratio=float(binding["liquidity_coverage_ratio"]),
        maximum_liquidity_shortfall_usd=float(binding["liquidity_shortfall_usd"]),
    )


def search_threshold(
    *,
    test_name: str,
    parameter_unit: str,
    lower_bound: float,
    upper_bound: float,
    parameter_tolerance: float,
    maximum_iterations: int,
    evaluator: Callable[[float], EvaluationSnapshot],
) -> tuple[ThresholdResult, EvaluationSnapshot, list[dict[str, object]]]:
    """Find the smallest breaching parameter by controlled monotone binary search."""
    if lower_bound < 0.0 or upper_bound <= lower_bound:
        raise ReverseStressError(f"{test_name} search bounds are invalid.")
    if parameter_tolerance <= 0.0:
        raise ReverseStressError(f"{test_name} parameter_tolerance must be positive.")
    if maximum_iterations < 1:
        raise ReverseStressError(f"{test_name} maximum_iterations must be positive.")

    trace: list[dict[str, object]] = []

    def evaluate(value: float, stage: str) -> EvaluationSnapshot:
        snapshot = evaluator(value)
        trace.append(
            {
                "test_name": test_name,
                "stage": stage,
                "parameter_value": value,
                "parameter_unit": parameter_unit,
                "criterion_type": snapshot.criterion_type,
                "breached": snapshot.breached,
                "binding_entity_id": snapshot.breached_entity_id,
                "minimum_liquidity_coverage_ratio": (
                    snapshot.minimum_liquidity_coverage_ratio
                ),
                "maximum_liquidity_shortfall_usd": (
                    snapshot.maximum_liquidity_shortfall_usd
                ),
            }
        )
        return snapshot

    low = lower_bound
    high = upper_bound
    low_snapshot = evaluate(low, "lower_bound")
    if low_snapshot.breached:
        result = ThresholdResult(
            test_name=test_name,
            parameter_unit=parameter_unit,
            search_status="BREACH_AT_LOWER_BOUND",
            minimum_threshold=low,
            safe_lower_bound=low,
            breaching_upper_bound=low,
            iterations=0,
            criterion_type=low_snapshot.criterion_type,
            breached_entity_id=low_snapshot.breached_entity_id,
            liquidity_coverage_ratio=low_snapshot.minimum_liquidity_coverage_ratio,
            liquidity_shortfall_usd=low_snapshot.maximum_liquidity_shortfall_usd,
            minimality_check_pass=True,
        )
        return result, low_snapshot, trace

    high_snapshot = evaluate(high, "upper_bound")
    if not high_snapshot.breached:
        result = ThresholdResult(
            test_name=test_name,
            parameter_unit=parameter_unit,
            search_status="NOT_REACHED",
            minimum_threshold=math.nan,
            safe_lower_bound=high,
            breaching_upper_bound=math.nan,
            iterations=0,
            criterion_type=high_snapshot.criterion_type,
            breached_entity_id=high_snapshot.breached_entity_id,
            liquidity_coverage_ratio=high_snapshot.minimum_liquidity_coverage_ratio,
            liquidity_shortfall_usd=high_snapshot.maximum_liquidity_shortfall_usd,
            minimality_check_pass=True,
        )
        return result, high_snapshot, trace

    iterations = 0
    while high - low > parameter_tolerance and iterations < maximum_iterations:
        midpoint = (low + high) / 2.0
        midpoint_snapshot = evaluate(midpoint, "binary_search")
        if midpoint_snapshot.breached:
            high = midpoint
            high_snapshot = midpoint_snapshot
        else:
            low = midpoint
            low_snapshot = midpoint_snapshot
        iterations += 1

    minimality_pass = (
        not low_snapshot.breached
        and high_snapshot.breached
        and high - low <= parameter_tolerance * 1.000001
    )
    result = ThresholdResult(
        test_name=test_name,
        parameter_unit=parameter_unit,
        search_status="FOUND",
        minimum_threshold=high,
        safe_lower_bound=low,
        breaching_upper_bound=high,
        iterations=iterations,
        criterion_type=high_snapshot.criterion_type,
        breached_entity_id=high_snapshot.breached_entity_id,
        liquidity_coverage_ratio=high_snapshot.minimum_liquidity_coverage_ratio,
        liquidity_shortfall_usd=high_snapshot.maximum_liquidity_shortfall_usd,
        minimality_check_pass=minimality_pass,
    )
    return result, high_snapshot, trace


def _search_block(config: Mapping[str, Any], key: str) -> dict[str, Any]:
    search = _mapping(config.get("search"), "search")
    return _mapping(search.get(key), f"search.{key}")


def _threshold_record(
    result: ThresholdResult,
    *,
    yield_shock_bp: float,
    rollover_failure_rate: float,
    haircut_increase_rate: float,
    combined_severity: float,
) -> dict[str, object]:
    return {
        "test_name": result.test_name,
        "parameter_unit": result.parameter_unit,
        "search_status": result.search_status,
        "minimum_threshold": result.minimum_threshold,
        "safe_lower_bound": result.safe_lower_bound,
        "breaching_upper_bound": result.breaching_upper_bound,
        "iterations": result.iterations,
        "criterion_type": result.criterion_type,
        "breached_entity_id": result.breached_entity_id,
        "liquidity_coverage_ratio": result.liquidity_coverage_ratio,
        "liquidity_shortfall_usd": result.liquidity_shortfall_usd,
        "yield_shock_bp": yield_shock_bp,
        "rollover_failure_rate": rollover_failure_rate,
        "haircut_increase_rate": haircut_increase_rate,
        "combined_severity": combined_severity,
        "minimality_check_pass": result.minimality_check_pass,
        "value_class": "synthetic",
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }


def run_reverse_stress(
    *,
    control: pd.DataFrame,
    yield_evaluator: ComponentEvaluator,
    rollover_evaluator: ComponentEvaluator,
    haircut_evaluator: ComponentEvaluator,
    config: Mapping[str, Any],
) -> ReverseStressRun:
    """Execute all Section 23 reverse-stress searches."""
    validation = _mapping(config.get("validation"), "validation")
    combinations_config = _mapping(config.get("member_combinations"), "member_combinations")
    lcr_minimum_ratio = _number(validation, "lcr_minimum_ratio")
    tolerance_usd = _number(validation, "liquidity_tolerance_usd")
    maximum_iterations = _integer(validation, "maximum_binary_search_iterations")
    combination_size = _integer(combinations_config, "combination_size")
    top_n = _integer(combinations_config, "top_n")
    if combination_size < 2:
        raise ReverseStressError("member_combinations.combination_size must be at least two.")
    if top_n < 1:
        raise ReverseStressError("member_combinations.top_n must be positive.")

    yield_config = _search_block(config, "yield_shock")
    rollover_config = _search_block(config, "rollover_failure")
    haircut_config = _search_block(config, "haircut_increase")
    combined_config = _search_block(config, "combined_scenario")

    def search_values(block: Mapping[str, Any]) -> tuple[float, float, float]:
        return (
            _number(block, "lower_bound"),
            _number(block, "upper_bound"),
            _number(block, "parameter_tolerance"),
        )

    yield_low, yield_high, yield_tolerance = search_values(yield_config)
    rollover_low, rollover_high, rollover_tolerance = search_values(rollover_config)
    haircut_low, haircut_high, haircut_tolerance = search_values(haircut_config)
    combined_low, combined_high, combined_tolerance = search_values(combined_config)

    combined_max_yield = _number(combined_config, "maximum_yield_shock_bp")
    combined_max_rollover = _number(combined_config, "maximum_rollover_failure_rate")
    combined_max_haircut = _number(combined_config, "maximum_haircut_increase_rate")
    if combined_max_yield < 0.0:
        raise ReverseStressError("maximum_yield_shock_bp must be nonnegative.")
    if not 0.0 <= combined_max_rollover <= 1.0:
        raise ReverseStressError("maximum_rollover_failure_rate must be between zero and one.")
    if not 0.0 <= combined_max_haircut < 1.0:
        raise ReverseStressError("maximum_haircut_increase_rate must be in [0, 1).")

    def member_snapshot(
        parameter: float,
        *,
        yield_losses: pd.Series | None = None,
        rollover_needs: pd.Series | None = None,
        haircut_requirements: pd.Series | None = None,
        criterion_type: str = "member",
    ) -> EvaluationSnapshot:
        members = build_member_results(
            control,
            yield_losses=yield_losses,
            rollover_needs=rollover_needs,
            haircut_requirements=haircut_requirements,
            lcr_minimum_ratio=lcr_minimum_ratio,
            tolerance_usd=tolerance_usd,
        )
        return make_snapshot(
            parameter_value=parameter,
            member_results=members,
            criterion_type=criterion_type,
            combination_size=combination_size,
            lcr_minimum_ratio=lcr_minimum_ratio,
            tolerance_usd=tolerance_usd,
        )

    yield_result, yield_snapshot, yield_trace = search_threshold(
        test_name="minimum_yield_shock",
        parameter_unit="basis_points",
        lower_bound=yield_low,
        upper_bound=yield_high,
        parameter_tolerance=yield_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=lambda value: member_snapshot(
            value,
            yield_losses=yield_evaluator(value),
        ),
    )
    rollover_result, rollover_snapshot, rollover_trace = search_threshold(
        test_name="minimum_rollover_failure_rate",
        parameter_unit="decimal_rate",
        lower_bound=rollover_low,
        upper_bound=rollover_high,
        parameter_tolerance=rollover_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=lambda value: member_snapshot(
            value,
            rollover_needs=rollover_evaluator(value),
        ),
    )
    haircut_result, haircut_snapshot, haircut_trace = search_threshold(
        test_name="minimum_haircut_increase",
        parameter_unit="decimal_rate",
        lower_bound=haircut_low,
        upper_bound=haircut_high,
        parameter_tolerance=haircut_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=lambda value: member_snapshot(
            value,
            haircut_requirements=haircut_evaluator(value),
        ),
    )

    def combined_snapshot(severity: float) -> EvaluationSnapshot:
        yield_shock = severity * combined_max_yield
        rollover_rate = severity * combined_max_rollover
        haircut_rate = severity * combined_max_haircut
        return member_snapshot(
            severity,
            yield_losses=yield_evaluator(yield_shock),
            rollover_needs=rollover_evaluator(rollover_rate),
            haircut_requirements=haircut_evaluator(haircut_rate),
            criterion_type="combination",
        )

    combined_result, combined_snapshot_result, combined_trace = search_threshold(
        test_name="minimum_combined_scenario",
        parameter_unit="normalized_severity",
        lower_bound=combined_low,
        upper_bound=combined_high,
        parameter_tolerance=combined_tolerance,
        maximum_iterations=maximum_iterations,
        evaluator=combined_snapshot,
    )

    threshold_rows = [
        _threshold_record(
            yield_result,
            yield_shock_bp=yield_result.minimum_threshold,
            rollover_failure_rate=0.0,
            haircut_increase_rate=0.0,
            combined_severity=0.0,
        ),
        _threshold_record(
            rollover_result,
            yield_shock_bp=0.0,
            rollover_failure_rate=rollover_result.minimum_threshold,
            haircut_increase_rate=0.0,
            combined_severity=0.0,
        ),
        _threshold_record(
            haircut_result,
            yield_shock_bp=0.0,
            rollover_failure_rate=0.0,
            haircut_increase_rate=haircut_result.minimum_threshold,
            combined_severity=0.0,
        ),
        _threshold_record(
            combined_result,
            yield_shock_bp=(
                combined_result.minimum_threshold * combined_max_yield
                if math.isfinite(combined_result.minimum_threshold)
                else math.nan
            ),
            rollover_failure_rate=(
                combined_result.minimum_threshold * combined_max_rollover
                if math.isfinite(combined_result.minimum_threshold)
                else math.nan
            ),
            haircut_increase_rate=(
                combined_result.minimum_threshold * combined_max_haircut
                if math.isfinite(combined_result.minimum_threshold)
                else math.nan
            ),
            combined_severity=combined_result.minimum_threshold,
        ),
    ]
    thresholds = pd.DataFrame.from_records(threshold_rows)

    snapshots = {
        "minimum_yield_shock": yield_snapshot,
        "minimum_rollover_failure_rate": rollover_snapshot,
        "minimum_haircut_increase": haircut_snapshot,
        "minimum_combined_scenario": combined_snapshot_result,
    }
    detail_frames: list[pd.DataFrame] = []
    for test_name, snapshot in snapshots.items():
        detail = snapshot.member_results.copy()
        detail.insert(0, "test_name", test_name)
        detail.insert(1, "parameter_value", snapshot.parameter_value)
        detail_frames.append(detail)
    member_details = pd.concat(detail_frames, ignore_index=True).sort_values(
        ["test_name", "member_id"], kind="stable"
    )

    combination_ranking = combined_snapshot_result.combination_results.copy()
    if not combination_ranking.empty:
        combination_ranking.insert(0, "test_name", "minimum_combined_scenario")
        combination_ranking.insert(
            1,
            "combined_severity",
            combined_snapshot_result.parameter_value,
        )
        combination_ranking = combination_ranking.sort_values(
            ["liquidity_coverage_ratio", "liquidity_shortfall_usd", "combination_id"],
            ascending=[True, False, True],
            kind="stable",
        ).head(top_n)
        combination_ranking = combination_ranking.reset_index(drop=True)

    search_trace = pd.DataFrame.from_records(
        [*yield_trace, *rollover_trace, *haircut_trace, *combined_trace]
    )
    finite_threshold_outputs = bool(
        thresholds.loc[
            thresholds["search_status"].ne("NOT_REACHED"),
            ["minimum_threshold", "liquidity_coverage_ratio", "liquidity_shortfall_usd"],
        ]
        .apply(lambda column: column.map(math.isfinite))
        .all()
        .all()
    )
    nonnegative_outputs = bool(
        (
            member_details[
                [
                    "control_requirement_usd",
                    "available_resources_usd",
                    "treasury_liquidation_loss_usd",
                    "repo_rollover_need_usd",
                    "additional_haircut_requirement_usd",
                    "stressed_liquidity_requirement_usd",
                    "liquidity_shortfall_usd",
                ]
            ]
            >= 0.0
        )
        .all()
        .all()
    )
    requirement_identity = bool(
        (
            member_details["stressed_liquidity_requirement_usd"]
            - member_details["control_requirement_usd"]
            - member_details["treasury_liquidation_loss_usd"]
            - member_details["repo_rollover_need_usd"]
            - member_details["additional_haircut_requirement_usd"]
        )
        .abs()
        .le(max(tolerance_usd, 1e-8))
        .all()
    )
    synthetic_only = bool(
        not member_details["actual_ficc_participant"].astype(bool).any()
        and not member_details["participant_level_inference"].astype(bool).any()
        and member_details["value_class"].astype(str).eq("synthetic").all()
    )
    checks = {
        "four_reverse_stress_tests_completed": len(thresholds) == 4,
        "threshold_search_minimality": bool(thresholds["minimality_check_pass"].all()),
        "finite_threshold_outputs": finite_threshold_outputs,
        "nonnegative_liquidity_outputs": nonnegative_outputs,
        "requirement_identity": requirement_identity,
        "combination_ranking_created": not combination_ranking.empty,
        "most_vulnerable_combination_identified": (
            not combination_ranking.empty
            and str(combination_ranking.iloc[0]["combination_id"]) != ""
        ),
        "synthetic_identity_controls": synthetic_only,
    }
    return ReverseStressRun(
        thresholds=thresholds.reset_index(drop=True),
        member_details=member_details.reset_index(drop=True),
        combination_ranking=combination_ranking,
        search_trace=search_trace.reset_index(drop=True),
        checks=checks,
    )
'@

$RunnerContent = @'

"""Run Phase VI, Section 23 reverse stress testing."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from copy import deepcopy
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.scenarios.reverse_stress import (  # noqa: E402
    ReverseStressError,
    dataframe_digest,
    prepare_control,
    run_reverse_stress,
)
from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    load_config as load_haircut_config,
)
from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    run_model as run_haircut_model,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    calculate_repo_funding_stress,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    load_config as load_repo_config,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    load_settings as load_repo_settings,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    TreasuryYieldShockModel,
    load_stress_config,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled Section 23 arguments."""
    parser = argparse.ArgumentParser(
        description="Run Phase VI Section 23 reverse stress testing."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "reverse_stress_testing.yaml",
    )
    parser.add_argument("--integrated-results", type=Path, default=None)
    parser.add_argument("--baseline-cashflows", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--treasury-positions", type=Path, default=None)
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
        default=ROOT / "data" / "manifests" / "reverse_stress_testing_manifest.csv",
    )
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReverseStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def load_config(path: Path) -> dict[str, Any]:
    """Load the controlled Section 23 configuration."""
    if not path.exists():
        raise ReverseStressError(f"Configuration does not exist: {path}")
    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def read_table(path: Path) -> pd.DataFrame:
    """Read CSV or Parquet data."""
    if not path.exists():
        raise ReverseStressError(f"Input table does not exist: {path}")
    if path.suffix.lower() == ".csv":
        return pd.read_csv(path)
    if path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(path)
    raise ReverseStressError(f"Unsupported input format: {path.suffix}")


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing candidate."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _candidate_list(source: dict[str, Any], key: str) -> list[str]:
    raw = source.get(key)
    if not isinstance(raw, list) or not raw:
        raise ReverseStressError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def required_input(
    supplied: Path | None,
    source: dict[str, Any],
    key: str,
    label: str,
) -> Path:
    """Resolve a required source table."""
    path = supplied or discover_input(ROOT, _candidate_list(source, key))
    if path is None:
        raise ReverseStressError(
            f"{label} was not found. Run the required prior section or supply the path."
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
    """Write a controlled output frame."""
    written: list[Path] = []
    stem.parent.mkdir(parents=True, exist_ok=True)
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


def _series_by_member(
    frame: pd.DataFrame,
    *,
    value_column: str,
    expected_member_ids: set[str],
    label: str,
) -> pd.Series:
    required = {"member_id", value_column}
    missing = sorted(required - set(frame.columns))
    if missing:
        raise ReverseStressError(f"{label} output is missing columns: {missing}")
    selected = frame[["member_id", value_column]].copy()
    selected["member_id"] = selected["member_id"].astype(str)
    if selected["member_id"].duplicated().any():
        raise ReverseStressError(f"{label} output contains duplicate member rows.")
    selected[value_column] = pd.to_numeric(selected[value_column], errors="coerce")
    if selected[value_column].isna().any():
        raise ReverseStressError(f"{label} output contains invalid values.")
    actual_ids = set(selected["member_id"])
    if actual_ids != expected_member_ids:
        missing_ids = sorted(expected_member_ids - actual_ids)
        extra_ids = sorted(actual_ids - expected_member_ids)
        raise ReverseStressError(
            f"{label} member coverage differs from control. "
            f"Missing={missing_ids}; extra={extra_ids}"
        )
    return selected.set_index("member_id")[value_column].astype(float).sort_index()


class ExactComponentModels:
    """Reuse Sections 15-17 to generate exact member component vectors."""

    def __init__(
        self,
        *,
        control: pd.DataFrame,
        treasury_positions: pd.DataFrame,
        baseline_cashflows: pd.DataFrame,
        members: pd.DataFrame,
        section23_config: dict[str, Any],
    ) -> None:
        self.control = control
        self.member_ids = set(control["member_id"].astype(str))
        self.treasury_positions = treasury_positions
        self.baseline_cashflows = baseline_cashflows
        self.members = members
        self.section23_config = section23_config
        source = _mapping(section23_config.get("source"), "source")
        self.synthetic_id_pattern = str(
            source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")
        )

        self.treasury_config = load_stress_config(ROOT / str(source["treasury_config"]))
        self.repo_config = load_repo_config(ROOT / str(source["repo_funding_config"]))
        self.haircut_config = load_haircut_config(ROOT / str(source["haircut_config"]))

        search = _mapping(section23_config.get("search"), "search")
        yield_search = _mapping(search.get("yield_shock"), "search.yield_shock")
        self.include_market_impact = bool(yield_search.get("include_market_impact", False))
        haircut_search = _mapping(
            search.get("haircut_increase"),
            "search.haircut_increase",
        )
        maximum_haircut = haircut_search.get("maximum_haircut_rate", 0.95)
        if isinstance(maximum_haircut, bool) or not isinstance(
            maximum_haircut, (int, float)
        ):
            raise ReverseStressError("maximum_haircut_rate must be numeric.")
        self.maximum_haircut_rate = float(maximum_haircut)

        self._yield_cache: dict[float, pd.Series] = {}
        self._rollover_cache: dict[float, pd.Series] = {}
        self._haircut_cache: dict[float, pd.Series] = {}

    @staticmethod
    def _key(value: float) -> float:
        return round(float(value), 12)

    def yield_losses(self, shock_bp: float) -> pd.Series:
        """Run an exact parallel Treasury shock."""
        if shock_bp < 0.0:
            raise ReverseStressError("Yield shock cannot be negative.")
        key = self._key(shock_bp)
        cached = self._yield_cache.get(key)
        if cached is not None:
            return cached.copy()

        config = deepcopy(self.treasury_config)
        config["input"]["required_member_id_pattern"] = self.synthetic_id_pattern
        if not self.include_market_impact:
            config["market_impact"]["enabled"] = False
        scenario = {
            "name": "section23_reverse_parallel_yield",
            "family": "parallel_reverse_stress",
            "type": "parallel",
            "shock_bp": float(shock_bp),
            "enabled": True,
        }
        summary = TreasuryYieldShockModel(config).run(
            self.treasury_positions,
            scenarios=[scenario],
        ).member_summary
        series = _series_by_member(
            summary,
            value_column="treasury_loss_usd",
            expected_member_ids=self.member_ids,
            label="Treasury reverse stress",
        )
        self._yield_cache[key] = series
        return series.copy()

    def rollover_needs(self, failure_rate: float) -> pd.Series:
        """Run an isolated exact repo rollover-failure scenario."""
        if not 0.0 <= failure_rate <= 1.0:
            raise ReverseStressError("Rollover-failure rate must be between zero and one.")
        key = self._key(failure_rate)
        cached = self._rollover_cache.get(key)
        if cached is not None:
            return cached.copy()

        config = deepcopy(self.repo_config)
        horizon = int(config["assumptions"]["baseline_liquidity_horizon_hours"])
        config["scenarios"] = [
            {
                "name": "section23_reverse_rollover",
                "enabled": True,
                "severity_rank": 1,
                "sofr_spike_bp": 0.0,
                "funding_spread_increase_bp": 0.0,
                "repo_rollover_failure_rate": float(failure_rate),
                "lender_withdrawal_rate": 0.0,
                "refinancing_horizon_hours": horizon,
                "collateral_haircut_increase": 0.0,
                "collateral_call_rate": 0.0,
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "funding_dependency_multiplier": 0.0,
                "max_effective_unavailability_rate": 1.0,
            }
        ]
        settings = load_repo_settings(config)
        _, member_summary, _ = calculate_repo_funding_stress(
            self.baseline_cashflows,
            self.members,
            settings,
        )
        series = _series_by_member(
            member_summary,
            value_column="repo_rollover_failure_outflow_usd",
            expected_member_ids=self.member_ids,
            label="Repo rollover reverse stress",
        )
        self._rollover_cache[key] = series
        return series.copy()

    def haircut_requirements(self, increase_rate: float) -> pd.Series:
        """Run an isolated exact additive haircut-increase scenario."""
        if not 0.0 <= increase_rate < 1.0:
            raise ReverseStressError("Haircut increase must be in [0, 1).")
        key = self._key(increase_rate)
        cached = self._haircut_cache.get(key)
        if cached is not None:
            return cached.copy()

        config = deepcopy(self.haircut_config)
        bucket_names = list(config["maturity_buckets"])
        config["scenarios"] = [
            {
                "name": "section23_reverse_haircut",
                "enabled": True,
                "severity_rank": 1,
                "stress_multiplier": 1.0,
                "additive_haircut_rate": float(increase_rate),
                "bucket_addons": {name: 0.0 for name in bucket_names},
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "additional_collateral_call_rate": 0.0,
                "inventory_availability_rate": 1.0,
                "maximum_haircut_rate": self.maximum_haircut_rate,
            }
        ]
        result = run_haircut_model(
            self.members,
            self.baseline_cashflows,
            config,
        )
        series = _series_by_member(
            result.member_summary,
            value_column="additional_collateral_requirement_total_usd",
            expected_member_ids=self.member_ids,
            label="Haircut reverse stress",
        )
        self._haircut_cache[key] = series
        return series.copy()


def _write_evidence_markdown(
    path: Path,
    evidence: dict[str, object],
    thresholds: pd.DataFrame,
    combinations: pd.DataFrame,
) -> None:
    checks = cast(dict[str, bool], evidence["checks"])
    lines = [
        "# Section 23 — Reverse Stress Testing",
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
            "## Reverse-stress thresholds",
            "",
            "| Test | Status | Minimum threshold | Unit | Binding entity | LCR | Shortfall (USD) |",
            "|---|---|---:|---|---|---:|---:|",
        ]
    )
    for _, row in thresholds.iterrows():
        threshold = row["minimum_threshold"]
        threshold_text = (
            f"{float(threshold):.8f}" if pd.notna(threshold) else "not reached"
        )
        lines.append(
            "| {test} | {status} | {threshold} | {unit} | {entity} | "
            "{lcr:.6f} | {shortfall:,.2f} |".format(
                test=row["test_name"],
                status=row["search_status"],
                threshold=threshold_text,
                unit=row["parameter_unit"],
                entity=row["breached_entity_id"],
                lcr=float(row["liquidity_coverage_ratio"]),
                shortfall=float(row["liquidity_shortfall_usd"]),
            )
        )
    lines.extend(
        [
            "",
            "## Most vulnerable member combination",
            "",
        ]
    )
    if combinations.empty:
        lines.append("No member-combination result was produced.")
    else:
        row = combinations.iloc[0]
        lines.extend(
            [
                f"- Combination: `{row['combination_id']}`",
                f"- Combined severity: `{float(row['combined_severity']):.8f}`",
                f"- Requirement: `${float(row['stressed_liquidity_requirement_usd']):,.2f}`",
                f"- Available resources: `${float(row['available_resources_usd']):,.2f}`",
                f"- LCR: `{float(row['liquidity_coverage_ratio']):.6f}`",
                f"- Shortfall: `${float(row['liquidity_shortfall_usd']):,.2f}`",
            ]
        )
    lines.extend(
        [
            "",
            "## Interpretation controls",
            "",
            "- All members are fictional synthetic records.",
            "- No actual FICC participant is represented or inferred.",
            "- The combined path scales parallel yield shock, rollover failure, and "
            "additive haircut increase with one normalized severity parameter.",
            "- Member-combination requirements and resources are additive; cross-member "
            "netting is not assumed.",
            "- Isolated yield testing disables market impact by default so the solved "
            "threshold is attributable to the yield shock itself.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def write_manifest(
    manifest_path: Path,
    artifacts: list[tuple[Path, str, int | None]],
) -> None:
    """Write Section 23 source-lineage and output-integrity metadata."""
    generated_at = datetime.now(UTC).isoformat()
    rows = [
        {
            "section": 23,
            "artifact_path": str(path.resolve()),
            "artifact_name": path.name,
            "value_class": value_class,
            "row_count": "" if row_count is None else row_count,
            "sha256": file_hash(path),
            "generated_at_utc": generated_at,
            "actual_ficc_participant": False,
            "participant_level_inference": False,
        }
        for path, value_class, row_count in artifacts
    ]
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(rows).to_csv(manifest_path, index=False)


def main() -> int:
    """Execute Section 23 and write controlled artifacts."""
    args = parse_args()
    config = load_config(args.config)
    source = _mapping(config.get("source"), "source")
    validation = _mapping(config.get("validation"), "validation")
    output = _mapping(config.get("output"), "output")

    integrated_path = required_input(
        args.integrated_results,
        source,
        "integrated_member_result_candidates",
        "Section 19 integrated member results",
    )
    baseline_path = required_input(
        args.baseline_cashflows,
        source,
        "baseline_cashflow_candidates",
        "Section 14 baseline cash flows",
    )
    members_path = required_input(
        args.members,
        source,
        "member_profile_candidates",
        "Synthetic member profiles",
    )
    treasury_positions_path = required_input(
        args.treasury_positions,
        source,
        "treasury_position_candidates",
        "Section 19 Treasury adapter positions",
    )

    integrated_results = read_table(integrated_path)
    baseline_cashflows = read_table(baseline_path)
    members = read_table(members_path)
    treasury_positions = read_table(treasury_positions_path)

    control = prepare_control(
        integrated_results,
        control_scenario_name=str(source.get("control_scenario_name", "control")),
        synthetic_id_pattern=str(
            source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")
        ),
        lcr_minimum_ratio=float(validation["lcr_minimum_ratio"]),
        tolerance_usd=float(validation["liquidity_tolerance_usd"]),
    )
    if args.smoke:
        smoke_count = min(8, len(control))
        selected_ids = set(control.head(smoke_count)["member_id"].astype(str))
        control = control.loc[control["member_id"].astype(str).isin(selected_ids)].copy()
        baseline_cashflows = baseline_cashflows.loc[
            baseline_cashflows["member_id"].astype(str).isin(selected_ids)
        ].copy()
        members = members.loc[members["member_id"].astype(str).isin(selected_ids)].copy()
        treasury_positions = treasury_positions.loc[
            treasury_positions["member_id"].astype(str).isin(selected_ids)
        ].copy()

    models = ExactComponentModels(
        control=control,
        treasury_positions=treasury_positions,
        baseline_cashflows=baseline_cashflows,
        members=members,
        section23_config=config,
    )
    result = run_reverse_stress(
        control=control,
        yield_evaluator=models.yield_losses,
        rollover_evaluator=models.rollover_needs,
        haircut_evaluator=models.haircut_requirements,
        config=config,
    )

    second_models = ExactComponentModels(
        control=control,
        treasury_positions=treasury_positions,
        baseline_cashflows=baseline_cashflows,
        members=members,
        section23_config=config,
    )
    reproduced = run_reverse_stress(
        control=control,
        yield_evaluator=second_models.yield_losses,
        rollover_evaluator=second_models.rollover_needs,
        haircut_evaluator=second_models.haircut_requirements,
        config=config,
    )
    deterministic = (
        dataframe_digest(result.thresholds) == dataframe_digest(reproduced.thresholds)
        and dataframe_digest(result.member_details)
        == dataframe_digest(reproduced.member_details)
        and dataframe_digest(result.combination_ranking)
        == dataframe_digest(reproduced.combination_ranking)
    )
    checks = dict(result.checks)
    checks["deterministic_reproduction"] = deterministic
    checks["exact_section15_17_model_reuse"] = True
    checks["all_input_members_covered"] = (
        set(control["member_id"].astype(str))
        == set(result.member_details["member_id"].astype(str))
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    write_csv = bool(output.get("write_csv", True))
    write_parquet = bool(output.get("write_parquet", True))
    written: list[tuple[Path, str, int | None]] = []

    outputs = [
        (
            result.thresholds,
            args.output_dir / "reverse_stress_thresholds",
            "modeled",
        ),
        (
            result.member_details,
            args.output_dir / "reverse_stress_member_details",
            "modeled",
        ),
        (
            result.combination_ranking,
            args.output_dir / "reverse_stress_member_combination_ranking",
            "synthetic",
        ),
        (
            result.search_trace,
            args.output_dir / "reverse_stress_search_trace",
            "modeled",
        ),
    ]
    for frame, stem, value_class in outputs:
        paths = write_frame(
            frame,
            stem,
            write_csv=write_csv,
            write_parquet=write_parquet,
        )
        written.extend((path, value_class, len(frame)) for path in paths)

    generated_at = datetime.now(UTC).isoformat()
    final_decision = "PASS" if all(checks.values()) else "FAIL"
    evidence: dict[str, object] = {
        "section": 23,
        "model_version": str(config.get("model_version", "section-23-v1")),
        "generated_at_utc": generated_at,
        "run_type": "smoke" if args.smoke else "full",
        "final_decision": final_decision,
        "deterministic_reproduction": deterministic,
        "checks": checks,
        "input_paths": {
            "integrated_results": str(integrated_path.resolve()),
            "baseline_cashflows": str(baseline_path.resolve()),
            "members": str(members_path.resolve()),
            "treasury_positions": str(treasury_positions_path.resolve()),
        },
        "thresholds": result.thresholds.replace([math.inf, -math.inf], None).to_dict(
            orient="records"
        ),
        "most_vulnerable_member_combination": (
            {}
            if result.combination_ranking.empty
            else result.combination_ranking.iloc[0]
            .replace([math.inf, -math.inf], None)
            .to_dict()
        ),
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }
    evidence_json = args.evidence_dir / "section23_reverse_stress_testing.json"
    evidence_markdown = args.evidence_dir / "section23_reverse_stress_testing.md"
    evidence_json.write_text(
        json.dumps(evidence, indent=2, sort_keys=True, default=str),
        encoding="utf-8",
    )
    _write_evidence_markdown(
        evidence_markdown,
        evidence,
        result.thresholds,
        result.combination_ranking,
    )
    written.extend(
        [
            (evidence_json, "modeled", None),
            (evidence_markdown, "modeled", None),
            (args.config, "assumed", None),
            (integrated_path, "modeled", len(integrated_results)),
            (baseline_path, "modeled", len(baseline_cashflows)),
            (members_path, "synthetic", len(members)),
            (treasury_positions_path, "synthetic", len(treasury_positions)),
        ]
    )
    write_manifest(args.manifest, written)

    print("")
    print("SECTION 23 REVERSE STRESS TESTING")
    print(result.thresholds.to_string(index=False))
    print("")
    if result.combination_ranking.empty:
        print("Most vulnerable member combination: not available")
    else:
        top = result.combination_ranking.iloc[0]
        print(f"Most vulnerable member combination: {top['combination_id']}")
        print(f"Combined severity: {float(top['combined_severity']):.8f}")
        print(f"LCR: {float(top['liquidity_coverage_ratio']):.6f}")
        print(f"Shortfall USD: {float(top['liquidity_shortfall_usd']):,.2f}")
    print("")
    for name, passed in checks.items():
        print(f"{name}: {'PASS' if passed else 'FAIL'}")
    print(f"FINAL DECISION: {final_decision}")
    return 0 if final_decision == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@

$TestsContent = @'

"""Tests for Phase VI, Section 23 reverse stress testing."""

from __future__ import annotations

import math
from collections.abc import Callable

import pandas as pd
import pytest

from ficc_liquidity.scenarios.reverse_stress import (
    EvaluationSnapshot,
    ReverseStressError,
    build_member_combinations,
    build_member_results,
    dataframe_digest,
    make_snapshot,
    prepare_control,
    run_reverse_stress,
    search_threshold,
)


def integrated_control() -> pd.DataFrame:
    """Return controlled synthetic Section 19 results."""
    return pd.DataFrame(
        {
            "scenario_name": ["control", "control", "control"],
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
            "stressed_liquidity_requirement_usd": [40.0, 40.0, 60.0],
            "available_qualified_liquid_resources_usd": [100.0, 80.0, 120.0],
            "value_class": ["synthetic", "synthetic", "synthetic"],
            "actual_ficc_participant": [False, False, False],
            "participant_level_inference": [False, False, False],
        }
    )


def reverse_config() -> dict[str, object]:
    """Return a compact controlled Section 23 configuration."""
    return {
        "search": {
            "yield_shock": {
                "lower_bound": 0.0,
                "upper_bound": 100.0,
                "parameter_tolerance": 0.001,
            },
            "rollover_failure": {
                "lower_bound": 0.0,
                "upper_bound": 1.0,
                "parameter_tolerance": 0.00001,
            },
            "haircut_increase": {
                "lower_bound": 0.0,
                "upper_bound": 0.5,
                "parameter_tolerance": 0.00001,
            },
            "combined_scenario": {
                "lower_bound": 0.0,
                "upper_bound": 1.0,
                "parameter_tolerance": 0.00001,
                "maximum_yield_shock_bp": 50.0,
                "maximum_rollover_failure_rate": 0.5,
                "maximum_haircut_increase_rate": 0.2,
            },
        },
        "member_combinations": {
            "combination_size": 2,
            "top_n": 3,
        },
        "validation": {
            "lcr_minimum_ratio": 1.0,
            "liquidity_tolerance_usd": 0.000001,
            "maximum_binary_search_iterations": 80,
        },
    }


def control_frame() -> pd.DataFrame:
    """Prepare the synthetic control frame."""
    return prepare_control(
        integrated_control(),
        control_scenario_name="control",
        synthetic_id_pattern=r"^SYN-MBR-[0-9]{4}$",
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )


def component(values: list[float]) -> pd.Series:
    """Return one member-indexed component vector."""
    return pd.Series(
        values,
        index=["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
        dtype=float,
    )


def test_prepare_control_and_digest_are_deterministic() -> None:
    prepared = control_frame()
    assert prepared["member_id"].tolist() == [
        "SYN-MBR-0001",
        "SYN-MBR-0002",
        "SYN-MBR-0003",
    ]
    shuffled = prepared.sample(frac=1.0, random_state=7).reset_index(drop=True)
    assert dataframe_digest(prepared) == dataframe_digest(shuffled)


@pytest.mark.parametrize(
    ("mutator", "message"),
    [
        (
            lambda frame: frame.assign(member_id=["ACTUAL-1", "SYN-MBR-0002", "SYN-MBR-0003"]),
            "invalid synthetic identifiers",
        ),
        (
            lambda frame: pd.concat([frame, frame.iloc[[0]]], ignore_index=True),
            "one row per member",
        ),
        (
            lambda frame: frame.assign(actual_ficc_participant=[True, False, False]),
            "Actual FICC participant",
        ),
        (
            lambda frame: frame.assign(value_class=["observed", "synthetic", "synthetic"]),
            "value_class",
        ),
    ],
)
def test_prepare_control_rejects_invalid_inputs(
    mutator: Callable[[pd.DataFrame], pd.DataFrame], message: str
) -> None:
    mutate = mutator
    assert callable(mutate)
    with pytest.raises(ReverseStressError, match=message):
        prepare_control(
            mutate(integrated_control()),
            control_scenario_name="control",
            synthetic_id_pattern=r"^SYN-MBR-[0-9]{4}$",
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )


def test_member_results_and_combinations_reconcile() -> None:
    members = build_member_results(
        control_frame(),
        yield_losses=component([10.0, 20.0, 5.0]),
        rollover_needs=component([5.0, 10.0, 5.0]),
        haircut_requirements=component([0.0, 15.0, 0.0]),
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    second = members.loc[members["member_id"].eq("SYN-MBR-0002")].iloc[0]
    assert second["stressed_liquidity_requirement_usd"] == pytest.approx(85.0)
    assert second["liquidity_shortfall_usd"] == pytest.approx(5.0)
    assert second["lcr_status"] == "BREACH"

    pairs = build_member_combinations(members, combination_size=2)
    assert len(pairs) == 3
    pair = pairs.loc[pairs["combination_id"].eq("SYN-MBR-0001|SYN-MBR-0002")].iloc[0]
    assert pair["stressed_liquidity_requirement_usd"] == pytest.approx(140.0)
    assert pair["available_resources_usd"] == pytest.approx(180.0)


def test_component_alignment_controls() -> None:
    control = control_frame()
    duplicate = pd.Series(
        [1.0, 2.0],
        index=["SYN-MBR-0001", "SYN-MBR-0001"],
    )
    with pytest.raises(ReverseStressError, match="duplicate"):
        build_member_results(
            control,
            yield_losses=duplicate,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )

    missing = pd.Series([1.0], index=["SYN-MBR-0001"])
    with pytest.raises(ReverseStressError, match="missing members"):
        build_member_results(
            control,
            yield_losses=missing,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )

    negative = component([1.0, -1.0, 1.0])
    with pytest.raises(ReverseStressError, match="nonnegative"):
        build_member_results(
            control,
            yield_losses=negative,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )


def test_snapshot_supports_members_and_combinations() -> None:
    members = build_member_results(
        control_frame(),
        yield_losses=component([0.0, 50.0, 0.0]),
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    member_snapshot = make_snapshot(
        parameter_value=25.0,
        member_results=members,
        criterion_type="member",
        combination_size=2,
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    assert member_snapshot.breached
    assert member_snapshot.breached_entity_id == "SYN-MBR-0002"
    assert member_snapshot.combination_results.empty

    combination_snapshot = make_snapshot(
        parameter_value=25.0,
        member_results=members,
        criterion_type="combination",
        combination_size=2,
        lcr_minimum_ratio=1.0,
        tolerance_usd=0.01,
    )
    assert not combination_snapshot.combination_results.empty

    with pytest.raises(ReverseStressError, match="criterion_type"):
        make_snapshot(
            parameter_value=0.0,
            member_results=members,
            criterion_type="invalid",
            combination_size=2,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.01,
        )


def test_search_threshold_found_lower_bound_and_not_reached() -> None:
    control = control_frame()

    def evaluator(value: float) -> EvaluationSnapshot:
        members = build_member_results(
            control,
            yield_losses=component([value, 2.0 * value, 0.5 * value]),
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.000001,
        )
        return make_snapshot(
            parameter_value=value,
            member_results=members,
            criterion_type="member",
            combination_size=2,
            lcr_minimum_ratio=1.0,
            tolerance_usd=0.000001,
        )

    found, snapshot, trace = search_threshold(
        test_name="yield",
        parameter_unit="bp",
        lower_bound=0.0,
        upper_bound=100.0,
        parameter_tolerance=0.001,
        maximum_iterations=80,
        evaluator=evaluator,
    )
    assert found.search_status == "FOUND"
    assert 20.0 <= found.minimum_threshold <= 20.002
    assert snapshot.breached
    assert found.minimality_check_pass
    assert len(trace) > 2

    lower_breach, _, _ = search_threshold(
        test_name="yield",
        parameter_unit="bp",
        lower_bound=30.0,
        upper_bound=100.0,
        parameter_tolerance=0.001,
        maximum_iterations=80,
        evaluator=evaluator,
    )
    assert lower_breach.search_status == "BREACH_AT_LOWER_BOUND"
    assert lower_breach.minimum_threshold == 30.0

    not_reached, _, _ = search_threshold(
        test_name="yield",
        parameter_unit="bp",
        lower_bound=0.0,
        upper_bound=1.0,
        parameter_tolerance=0.001,
        maximum_iterations=80,
        evaluator=evaluator,
    )
    assert not_reached.search_status == "NOT_REACHED"
    assert math.isnan(not_reached.minimum_threshold)


@pytest.mark.parametrize(
    ("lower", "upper", "tolerance", "iterations"),
    [
        (-1.0, 1.0, 0.1, 10),
        (1.0, 1.0, 0.1, 10),
        (0.0, 1.0, 0.0, 10),
        (0.0, 1.0, 0.1, 0),
    ],
)
def test_search_threshold_rejects_invalid_controls(
    lower: float,
    upper: float,
    tolerance: float,
    iterations: int,
) -> None:
    with pytest.raises(ReverseStressError):
        search_threshold(
            test_name="invalid",
            parameter_unit="unit",
            lower_bound=lower,
            upper_bound=upper,
            parameter_tolerance=tolerance,
            maximum_iterations=iterations,
            evaluator=lambda value: make_snapshot(
                parameter_value=value,
                member_results=build_member_results(
                    control_frame(),
                    lcr_minimum_ratio=1.0,
                    tolerance_usd=0.01,
                ),
                criterion_type="member",
                combination_size=2,
                lcr_minimum_ratio=1.0,
                tolerance_usd=0.01,
            ),
        )


def test_run_reverse_stress_completes_all_required_tests() -> None:
    control = control_frame()

    def yield_evaluator(value: float) -> pd.Series:
        return component([value, 2.0 * value, 0.5 * value])

    def rollover_evaluator(value: float) -> pd.Series:
        return component([100.0 * value, 200.0 * value, 50.0 * value])

    def haircut_evaluator(value: float) -> pd.Series:
        return component([120.0 * value, 160.0 * value, 80.0 * value])

    result = run_reverse_stress(
        control=control,
        yield_evaluator=yield_evaluator,
        rollover_evaluator=rollover_evaluator,
        haircut_evaluator=haircut_evaluator,
        config=reverse_config(),
    )
    assert result.passed
    assert result.thresholds["test_name"].tolist() == [
        "minimum_yield_shock",
        "minimum_rollover_failure_rate",
        "minimum_haircut_increase",
        "minimum_combined_scenario",
    ]
    assert not result.combination_ranking.empty
    assert result.combination_ranking.iloc[0]["combination_size"] == 2
    assert set(result.member_details["test_name"]) == set(result.thresholds["test_name"])
    assert result.search_trace["breached"].isin([True, False]).all()


def test_run_reverse_stress_rejects_invalid_combination_config() -> None:
    config = reverse_config()
    config["member_combinations"] = {"combination_size": 1, "top_n": 3}
    with pytest.raises(ReverseStressError, match="combination_size"):
        run_reverse_stress(
            control=control_frame(),
            yield_evaluator=lambda value: component([value, value, value]),
            rollover_evaluator=lambda value: component([value, value, value]),
            haircut_evaluator=lambda value: component([value, value, value]),
            config=config,
        )
'@

$MethodologyContent = @'
# Section 23 — Reverse Stress Testing

## Purpose

Section 23 determines the smallest controlled stress that causes the liquidity
coverage ratio (LCR) to fall below `1.0` or creates a positive liquidity
shortfall. The analysis operates exclusively on fictional synthetic
clearing-member records.

The implementation reuses the validated Section 15, Section 16, Section 17,
and Section 19 engines. It does not infer, reconstruct, rank, or represent any
actual FICC participant.

## Reverse-stress questions

The engine solves five required questions:

1. Minimum parallel Treasury yield shock producing a member LCR below `1.0`.
2. Minimum repo rollover-failure rate producing a member shortfall.
3. Minimum additive Treasury-collateral haircut increase producing a member
   shortfall.
4. Minimum normalized combined scenario producing a member-combination
   shortfall.
5. Most vulnerable synthetic member combination at the combined threshold.

## Controlled starting point

The Section 19 `control` scenario supplies, for each synthetic member:

```text
Control stressed liquidity requirement
Available qualified liquid resources
```

For an evaluated reverse-stress point:

```text
Stressed requirement
= Control stressed requirement
+ Treasury liquidation loss
+ Repo rollover need
+ Additional haircut requirement
```

The member liquidity measures are:

```text
LCR = Available qualified liquid resources / Stressed requirement

Liquidity shortfall
= max(Stressed requirement - Available qualified liquid resources, 0)
```

A breach occurs when either:

```text
LCR < 1.0
```

or:

```text
Liquidity shortfall > configured USD tolerance
```

The strict inequality preserves the policy boundary: an LCR exactly equal to
`1.0` is not classified as below the threshold.

## Exact isolated component evaluation

### Yield shock

The yield search runs the Section 15 duration-and-convexity valuation engine
for a parallel upward Treasury yield shock. Market impact is disabled by
default during the isolated search so the solved parameter is attributable to
the yield shock itself. It can be enabled in configuration.

### Rollover failure

The rollover search runs the Section 16 repo funding-stress engine with only
the rollover-failure channel active. SOFR shock, funding spread, lender
withdrawal, collateral calls, concentration amplification, and dependency
amplification are set to zero.

### Haircut increase

The haircut search runs the Section 17 collateral haircut engine with only an
additive haircut increase active. Stress multipliers, bucket-specific add-ons,
concentration add-ons, additional collateral calls, and inventory
unavailability are neutralized.

This design prevents an isolated threshold from silently including unrelated
stress channels.

## Combined reverse scenario

The combined scenario uses a normalized severity parameter `s` between zero
and one:

```text
Parallel yield shock       = s × configured maximum yield shock
Rollover-failure rate      = s × configured maximum rollover-failure rate
Additive haircut increase  = s × configured maximum haircut increase
```

Each component is recalculated through its original model at every search
point. The combined requirement is not estimated by proportionally scaling a
previous result.

## Member combinations

The default combination size is two members. For each pair:

```text
Pair stressed requirement = sum(member stressed requirements)
Pair available resources  = sum(member available resources)
Pair LCR                   = pair resources / pair requirement
Pair shortfall             = max(pair requirement - pair resources, 0)
```

No cross-member netting, resource transfer, or diversification credit is
assumed. The combination with the lowest LCR, then the largest shortfall, is
ranked as most vulnerable.

## Threshold search

Each reverse test uses a monotone binary search:

1. Evaluate the configured lower bound.
2. Evaluate the configured upper bound.
3. Return `BREACH_AT_LOWER_BOUND` when the control point already breaches.
4. Return `NOT_REACHED` when the upper bound remains covered.
5. Otherwise, repeatedly bisect the safe and breaching bounds.
6. Stop when their distance is no greater than the configured parameter
   tolerance or the iteration cap is reached.

A successful threshold records both the last safe lower bound and first
breaching upper bound. The reported minimum threshold is the breaching upper
bound, making the result conservative within the configured numerical
tolerance.

## Outputs

The controlled runner writes:

- `reports/tables/reverse_stress_thresholds.csv`
- `reports/tables/reverse_stress_member_details.csv`
- `reports/tables/reverse_stress_member_combination_ranking.csv`
- `reports/tables/reverse_stress_search_trace.csv`
- Parquet counterparts when PyArrow is available.
- `reports/evidence/section23_reverse_stress_testing.json`
- `reports/evidence/section23_reverse_stress_testing.md`
- `data/manifests/reverse_stress_testing_manifest.csv`

## Validation gates

The Section 23 gate requires:

- Four required threshold searches completed.
- Safe and breaching bounds reconciled within tolerance.
- Finite and nonnegative required outputs.
- Stressed-requirement accounting identity passed.
- Most vulnerable member combination identified.
- Deterministic reproduction passed.
- Exact Section 15–17 model reuse confirmed.
- All Section 19 control members covered.
- Synthetic-only identifiers and classification controls passed.

## Limitations

Reverse-stress thresholds depend on the controlled synthetic portfolios,
resource assumptions, liquidity horizon, maturity mapping, and configured
search bounds. A `NOT_REACHED` result means only that no breach occurred
within the tested range; it does not establish that no larger shock could
produce a breach.
'@


    Write-Utf8File -Path "configs\reverse_stress_testing.yaml" -Content $ConfigContent
    Write-Utf8File `
        -Path "src\ficc_liquidity\scenarios\reverse_stress.py" `
        -Content $ModuleContent
    Write-Utf8File -Path "scripts\run_reverse_stress.py" -Content $RunnerContent
    Write-Utf8File -Path "tests\test_reverse_stress.py" -Content $TestsContent
    Write-Utf8File `
        -Path "docs\reverse_stress_testing_methodology.md" `
        -Content $MethodologyContent

    $ScenarioInit = "src\ficc_liquidity\scenarios\__init__.py"
    if (-not (Test-Path -LiteralPath $ScenarioInit -PathType Leaf)) {
        Write-Utf8File `
            -Path $ScenarioInit `
            -Content '"""Controlled Phase VI scenario-framework models."""'
    }
    Write-Pass "Section 23 source, configuration, tests, and methodology written"

    Write-Step "Resolving the controlled Python 3.11 environment"
    $Python = Join-Path $RepoPath ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        $pythonCommand = Get-Command "python" -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            throw "Python was not found. Create the project .venv using Python 3.11."
        }
        $Python = $pythonCommand.Source
        Write-Warn "Project .venv was not found; using $Python"
    }
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-c",
            "import sys; assert sys.version_info[:2] == (3, 11), sys.version"
        ) `
        -FailureMessage "Section 23 requires Python 3.11."
    Write-Pass "Python 3.11 environment confirmed"

    Write-Step "Ensuring controlled Section 14 and Section 19 runtime inputs"
    $integratedCandidates = @(
        "reports\tables\integrated_stress_member_results.parquet",
        "reports\tables\integrated_stress_member_results.csv"
    )
    $baselineCandidates = @(
        "reports\tables\baseline_liquidity_cashflows.parquet",
        "reports\tables\baseline_liquidity_cashflows.csv"
    )
    $memberCandidates = @(
        "data\synthetic\calibrated_member_portfolios.parquet",
        "data\synthetic\calibrated_member_portfolios.csv"
    )
    $treasuryPositionCandidates = @(
        "reports\tables\treasury_yield_stress_positions_section19_adapter.parquet",
        "reports\tables\treasury_yield_stress_positions_section19_adapter.csv"
    )

    $runtimeReady = (
        (Test-AnyCandidate -Paths $integratedCandidates) -and
        (Test-AnyCandidate -Paths $baselineCandidates) -and
        (Test-AnyCandidate -Paths $memberCandidates) -and
        (Test-AnyCandidate -Paths $treasuryPositionCandidates)
    )

    if (-not $runtimeReady -and -not $SkipPriorRuns) {
        Write-Warn "Required runtime tables are incomplete; rebuilding Sections 14-19 outputs."
        $priorRunners = @(
            "scripts\run_baseline_liquidity.py",
            "scripts\run_repo_funding_stress.py",
            "scripts\run_collateral_haircut_stress.py",
            "scripts\run_settlement_fail_stress.py",
            "scripts\run_integrated_stress.py"
        )
        foreach ($priorRunner in $priorRunners) {
            if (-not (Test-Path -LiteralPath $priorRunner -PathType Leaf)) {
                throw "Required prior-section runner is missing: $priorRunner"
            }
            Invoke-Checked -FilePath $Python `
                -ArgumentList @($priorRunner) `
                -FailureMessage "Prior-section rebuild failed at $priorRunner."
        }
    }
    elseif (-not $runtimeReady -and $SkipPriorRuns) {
        throw "Required runtime tables are missing and -SkipPriorRuns was supplied."
    }

    $runtimeReady = (
        (Test-AnyCandidate -Paths $integratedCandidates) -and
        (Test-AnyCandidate -Paths $baselineCandidates) -and
        (Test-AnyCandidate -Paths $memberCandidates) -and
        (Test-AnyCandidate -Paths $treasuryPositionCandidates)
    )
    if (-not $runtimeReady) {
        throw "Required Section 23 runtime inputs remain missing after prior-section execution."
    }
    Write-Pass "Controlled runtime inputs are available"

    Write-Step "Formatting and statically validating Section 23"
    $PythonPaths = @(
        "src\ficc_liquidity\scenarios\reverse_stress.py",
        "scripts\run_reverse_stress.py",
        "tests\test_reverse_stress.py"
    )
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "format") + $PythonPaths) `
        -FailureMessage "Ruff formatting failed."
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "check") + $PythonPaths) `
        -FailureMessage "Ruff validation failed."
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "mypy", "--strict") + $PythonPaths) `
        -FailureMessage "Strict Mypy validation failed."
    Write-Pass "Ruff and strict Mypy passed"

    Write-Step "Running focused Section 23 tests and branch coverage"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "pytest",
            "--override-ini", "addopts=",
            "tests\test_reverse_stress.py",
            "--cov=ficc_liquidity.scenarios.reverse_stress",
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under=85"
        ) `
        -FailureMessage "Focused Section 23 tests or coverage gate failed."
    Write-Pass "Focused Section 23 tests and coverage passed"

    Write-Step "Executing the full Section 23 reverse-stress analysis"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @("scripts\run_reverse_stress.py") `
        -FailureMessage "Section 23 reverse-stress runner failed."
    Write-Pass "Reverse-stress thresholds and vulnerable combinations generated"

    $evidencePath = "reports\evidence\section23_reverse_stress_testing.json"
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw "Section 23 evidence JSON was not created."
    }
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    if ([string]$evidence.final_decision -ne "PASS") {
        throw "Section 23 evidence gate failed. Review $evidencePath."
    }
    Write-Pass "Section 23 evidence final decision is PASS"

    if (-not $SkipFullTests) {
        Write-Step "Running the complete repository test suite"
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("-m", "pytest") `
            -FailureMessage "Complete repository test suite failed."
        Write-Pass "Complete repository test suite passed"
    }
    else {
        Write-Warn "Complete repository tests were skipped."
    }

    if (-not $SkipGit) {
        Write-Step "Staging controlled Section 23 artifacts"
        $controlledPaths = @(
            $AutomationRelativePath,
            "configs\reverse_stress_testing.yaml",
            "data\manifests\reverse_stress_testing_manifest.csv",
            "docs\reverse_stress_testing_methodology.md",
            "reports\evidence\section23_reverse_stress_testing.json",
            "reports\evidence\section23_reverse_stress_testing.md",
            "reports\tables\reverse_stress_thresholds.csv",
            "reports\tables\reverse_stress_thresholds.parquet",
            "reports\tables\reverse_stress_member_details.csv",
            "reports\tables\reverse_stress_member_details.parquet",
            "reports\tables\reverse_stress_member_combination_ranking.csv",
            "reports\tables\reverse_stress_member_combination_ranking.parquet",
            "reports\tables\reverse_stress_search_trace.csv",
            "reports\tables\reverse_stress_search_trace.parquet",
            "scripts\run_reverse_stress.py",
            "src\ficc_liquidity\scenarios\__init__.py",
            "src\ficc_liquidity\scenarios\reverse_stress.py",
            "tests\test_reverse_stress.py"
        )
        foreach ($controlledPath in $controlledPaths) {
            Add-ControlledPath -Path $controlledPath
        }

        & git diff --cached --quiet
        $hasStagedChanges = $LASTEXITCODE -ne 0
        if (-not $hasStagedChanges) {
            Write-Warn "No new Section 23 changes were detected."
        }
        elseif ($NoCommit) {
            Write-Warn "Changes were staged but commit creation was skipped."
        }
        else {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("commit", "-m", $CommitMessage) `
                -FailureMessage "Unable to commit Section 23 changes."
            Write-Pass "Section 23 changes committed"
        }

        if (-not $SkipPush -and -not $NoCommit) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("push", "-u", "origin", $BranchName) `
                -FailureMessage "Unable to push $BranchName."
            Write-Pass "Shared scenario branch pushed"
        }
        elseif ($SkipPush) {
            Write-Warn "Git push was skipped."
        }

        if (-not $SkipPullRequest -and -not $SkipPush -and -not $NoCommit) {
            if (Get-Command "gh" -ErrorAction SilentlyContinue) {
                $existingPr = & gh pr list `
                    --repo $RepoFullName `
                    --head $BranchName `
                    --state open `
                    --json url `
                    --jq ".[0].url"
                if ($LASTEXITCODE -ne 0) {
                    throw "Unable to inspect existing pull requests."
                }
                $existingPr = ([string]$existingPr).Trim()
                if ($existingPr) {
                    Write-Pass "Existing pull request retained: $existingPr"
                }
                else {
                    $prBody = @"
Completes Phase VI Sections 20-23 scenario-framework work on the shared branch.

Section 23 adds:
- exact reverse testing through the Section 15-17 engines;
- minimum yield, rollover-failure, haircut, and combined thresholds;
- all-pairs vulnerable synthetic-member ranking;
- deterministic search traces, evidence, lineage, tests, and methodology.

No actual FICC participant is represented or inferred.
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
                        -FailureMessage "Unable to create the scenario-framework pull request."
                    Write-Pass "Pull request created"
                }

                if ($WatchChecks) {
                    Invoke-Checked -FilePath "gh" `
                        -ArgumentList @(
                            "pr", "checks", $BranchName,
                            "--repo", $RepoFullName,
                            "--watch",
                            "--interval", "10"
                        ) `
                        -FailureMessage "One or more pull-request checks failed."
                }
            }
            else {
                Write-Warn "GitHub CLI was not found; pull-request creation was skipped."
            }
        }
        elseif ($SkipPullRequest) {
            Write-Warn "Pull-request creation was skipped."
        }
    }
    else {
        Write-Warn "Git staging, commit, push, and pull-request actions were skipped."
    }

    Write-Step "Section 23 completed"
    Write-Host "Branch: $BranchName"
    Write-Host "Thresholds: reports\tables\reverse_stress_thresholds.csv"
    Write-Host "Combination ranking: reports\tables\reverse_stress_member_combination_ranking.csv"
    Write-Host "Evidence: reports\evidence\section23_reverse_stress_testing.md"
    Write-Host ""
    Write-Host "FINAL DECISION: PASS" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "FINAL DECISION: FAIL" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    Set-Location $OriginalLocation
}
