#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase V, Section 14: baseline liquidity cash-flow engine.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.
    It validates and, when explicitly requested, integrates the open Section 12
    calibration pull request; creates feature/12-baseline-liquidity; writes the
    controlled YAML configuration, Python engine, runner, tests, methodology,
    output tables, manifest, and evidence; runs Ruff, strict Mypy, focused
    coverage, and the full repository test suite; then commits, pushes, and opens
    a pull request.

    The engine models unstressed settlement obligations, repo maturities,
    financing inflows and outflows, available cash, eligible collateral
    liquidity, netting, payment timing, the liquidity horizon, and available
    qualified liquid resources. It operates only on fictional synthetic members.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\16_P5S14_Baseline_Liquidity_Cashflow_Engine_PS51.ps1" `
        -AutoMergeSection12
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoPath = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",

    [Parameter()]
    [switch]$AutoMergeSection12,

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

    [Parameter(DontShow)]
    [switch]$Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (Test-Path -LiteralPath "variable:PSNativeCommandUseErrorActionPreference") {
    $PSNativeCommandUseErrorActionPreference = $false
}

$RepoFullName = "Nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing"
$Section12PullRequest = 16
$BranchName = "feature/12-baseline-liquidity"
$CommitMessage = "Phase V Section 14: add baseline liquidity cash-flow engine"
$AutomationRelativePath = "scripts\automation\16_P5S14_Baseline_Liquidity_Cashflow_Engine_PS51.ps1"

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

    [System.IO.File]::WriteAllText(
        $Path,
        ($Content.TrimStart() + [Environment]::NewLine),
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

try {
    $RepoPath = (Resolve-Path -LiteralPath $RepoPath -ErrorAction Stop).Path
    $ScriptPath = $MyInvocation.MyCommand.Path
    $repoPrefix = $RepoPath.TrimEnd("\") + "\"

    if (
        -not $Relaunched -and
        $ScriptPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        $downloadDirectory = Join-Path $env:USERPROFILE "Downloads"
        New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
        $destination = Join-Path $downloadDirectory (
            "16_P5S14_Baseline_Liquidity_Cashflow_Engine_PS51_{0}.ps1" -f `
                (Get-Date -Format "yyyyMMdd_HHmmss")
        )
        Copy-Item -LiteralPath $ScriptPath -Destination $destination -Force

        $childArguments = @{
            RepoPath = $RepoPath
            Relaunched = $true
        }
        foreach ($switchName in @(
            "AutoMergeSection12",
            "AllowDirty",
            "SkipGit",
            "NoCommit",
            "SkipPush",
            "SkipPullRequest",
            "SkipFullTests"
        )) {
            if (Get-Variable -Name $switchName -ValueOnly) {
                $childArguments[$switchName] = $true
            }
        }

        try {
            & $destination @childArguments
            $childSucceeded = $?
        }
        finally {
            Remove-Item -LiteralPath $ScriptPath -Force -ErrorAction SilentlyContinue
        }
        if (-not $childSucceeded) {
            exit 1
        }
        exit 0
    }

    Set-Location $RepoPath
    Write-Step "Validating repository, tools, and working-tree state"

    if (-not (Test-Path -LiteralPath ".git" -PathType Container)) {
        throw "The selected folder is not a Git repository: $RepoPath"
    }
    if (-not (Test-Path -LiteralPath "pyproject.toml" -PathType Leaf)) {
        throw "pyproject.toml was not found. Open the FICC repository in VS Code."
    }

    Assert-Command -Name "git"
    if (-not $SkipGit) {
        $dirty = @(& git status --porcelain)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect Git working-tree status."
        }
        if ($dirty.Count -gt 0 -and -not $AllowDirty) {
            throw @"
The working tree contains uncommitted changes.
Commit or stash them, then rerun this automation.
Use -AllowDirty only after reviewing the existing changes.
"@
        }

        Invoke-Checked -FilePath "git" `
            -ArgumentList @("fetch", "origin", "--prune") `
            -FailureMessage "Unable to fetch origin."
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("switch", "main") `
            -FailureMessage "Unable to switch to main."
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("pull", "--ff-only", "origin", "main") `
            -FailureMessage "Unable to update main."
    }

    $section12Required = @(
        "configs\synthetic_calibration.yaml",
        "src\ficc_liquidity\synthetic\calibrate_members.py",
        "data\synthetic\calibrated_member_portfolios.parquet"
    )

    if (-not (Test-RequiredFiles -Paths $section12Required)) {
        if (-not $AutoMergeSection12) {
            throw @"
Section 12 is not present on main. Pull request #16 is the required dependency.
Rerun this same automation with -AutoMergeSection12 after reviewing PR #16:

& "$ScriptPath" -AutoMergeSection12
"@
        }

        Assert-Command -Name "gh"
        Write-Step "Integrating the approved Section 12 dependency from PR #16"
        Invoke-Checked -FilePath "gh" `
            -ArgumentList @("auth", "status") `
            -FailureMessage "GitHub CLI authentication is not available."

        $prJson = & gh pr view $Section12PullRequest `
            --repo $RepoFullName `
            --json state,mergedAt
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect Section 12 pull request #16."
        }
        $prData = $prJson | ConvertFrom-Json
        $prState = ("{0}|{1}" -f [string]$prData.state, [string]$prData.mergedAt)

        if ($prState.StartsWith("OPEN|")) {
            Invoke-Checked -FilePath "gh" `
                -ArgumentList @(
                    "pr", "checks", "$Section12PullRequest",
                    "--repo", $RepoFullName,
                    "--watch"
                ) `
                -FailureMessage "Section 12 checks did not pass."
            Invoke-Checked -FilePath "gh" `
                -ArgumentList @(
                    "pr", "merge", "$Section12PullRequest",
                    "--repo", $RepoFullName,
                    "--squash",
                    "--delete-branch"
                ) `
                -FailureMessage "Unable to merge Section 12 pull request #16."
        }
        elseif (-not $prState.StartsWith("MERGED|")) {
            throw "Section 12 pull request #16 is closed without a merge. Review it before Section 14."
        }

        Invoke-Checked -FilePath "git" `
            -ArgumentList @("switch", "main") `
            -FailureMessage "Unable to switch to main after the Section 12 merge."
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("pull", "--ff-only", "origin", "main") `
            -FailureMessage "Unable to pull the merged Section 12 changes."
    }

    if (-not (Test-RequiredFiles -Paths $section12Required)) {
        throw "Section 12 dependency files remain unavailable after integration."
    }
    Write-Pass "Section 12 calibrated synthetic portfolios are available"

    $section13Required = @(
        "configs\default_sets.yaml",
        "src\ficc_liquidity\synthetic\default_sets.py",
        "tests\test_default_sets.py"
    )
    if (-not (Test-RequiredFiles -Paths $section13Required)) {
        throw "Section 13 default-set construction is missing from main."
    }
    Write-Pass "Section 13 default-set construction is available"

    if (-not $SkipGit) {
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
    else {
        Write-Warn "Git branch operations were skipped."
    }

    Write-Step "Creating Section 14 directories and controlled files"
    foreach ($directory in @(
        "configs",
        "data\manifests",
        "docs",
        "reports\evidence",
        "reports\tables",
        "scripts",
        "scripts\automation",
        "src\ficc_liquidity\liquidity",
        "tests"
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $automationTarget = Join-Path $RepoPath $AutomationRelativePath
    if ($ScriptPath -ne $automationTarget) {
        Copy-Item -LiteralPath $ScriptPath -Destination $automationTarget -Force
    }

    $ConfigContent = @'
schema_version: "1.0"
model_version: "section-14-v1"

classification:
  source_values: synthetic
  assumptions: assumed
  calculations: modeled
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false

source:
  member_portfolios: "data/synthetic/calibrated_member_portfolios.parquet"
  member_id_column: "member_id"
  synthetic_id_pattern: "^SYN-MBR-[0-9]{4}$"

liquidity_horizon:
  label: "two-business-day baseline horizon"
  hours: 48
  buckets:
    - name: "day1_open"
      elapsed_hours: 0
    - name: "day1_midday"
      elapsed_hours: 6
    - name: "day1_close"
      elapsed_hours: 12
    - name: "day2_open"
      elapsed_hours: 24
    - name: "day2_close"
      elapsed_hours: 48

payment_timing:
  settlement_obligations:
    day1_open: 0.35
    day1_midday: 0.30
    day1_close: 0.25
    day2_open: 0.10
    day2_close: 0.00
  repo_maturities:
    day1_open: 0.20
    day1_midday: 0.30
    day1_close: 0.30
    day2_open: 0.15
    day2_close: 0.05
  financing_inflows:
    day1_open: 0.10
    day1_midday: 0.25
    day1_close: 0.30
    day2_open: 0.25
    day2_close: 0.10
  eligible_collateral_availability:
    day1_open: 0.00
    day1_midday: 0.25
    day1_close: 0.45
    day2_open: 0.20
    day2_close: 0.10

assumptions:
  settlement_netting_rate: 0.25
  repo_roll_rate: 0.80
  reverse_repo_inflow_recognition_rate: 0.95
  financing_netting_enabled: true
  available_cash_share_of_aqlr: 0.35
  eligible_collateral_haircut: 0.05
  collateral_operational_availability_rate: 0.90
  resource_reuse_permitted: false

validation:
  reconciliation_tolerance_usd: 0.01
  require_nonnegative_cashflow_components: true
  require_synthetic_identifiers: true
  require_deterministic_reproduction: true

outputs:
  cashflows: "reports/tables/baseline_liquidity_cashflows.csv"
  member_summary: "reports/tables/baseline_liquidity_summary.csv"
  manifest: "data/manifests/baseline_liquidity_manifest.csv"
  evidence: "reports/evidence/section14_baseline_liquidity_validation.txt"
'@
    $InitContent = @'
"""Liquidity cash-flow and stress-model components."""

from ficc_liquidity.liquidity.baseline_cashflow import (
    BaselineLiquidityError,
    BaselineSettings,
    TimeBucket,
    ValidationResult,
    calculate_cashflows,
    load_config,
    load_settings,
    prepare_members,
    run_engine,
    validate_results,
)

__all__ = [
    "BaselineLiquidityError",
    "BaselineSettings",
    "TimeBucket",
    "ValidationResult",
    "calculate_cashflows",
    "load_config",
    "load_settings",
    "prepare_members",
    "run_engine",
    "validate_results",
]
'@
    $ModuleContent = @'
"""Baseline liquidity cash-flow engine for fictional clearing members.

The engine models unstressed, time-bucketed liquidity cash flows. It operates
only on synthetic member records and does not represent actual FICC participants.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class BaselineLiquidityError(ValueError):
    """Raised when baseline-liquidity inputs or assumptions are invalid."""


@dataclass(frozen=True, slots=True)
class TimeBucket:
    """One ordered payment-timing bucket in the liquidity horizon."""

    name: str
    elapsed_hours: int


@dataclass(frozen=True, slots=True)
class BaselineSettings:
    """Validated assumptions for the baseline cash-flow engine."""

    model_version: str
    horizon_hours: int
    buckets: tuple[TimeBucket, ...]
    settlement_schedule: Mapping[str, float]
    repo_maturity_schedule: Mapping[str, float]
    financing_inflow_schedule: Mapping[str, float]
    collateral_availability_schedule: Mapping[str, float]
    settlement_netting_rate: float
    repo_roll_rate: float
    reverse_repo_inflow_recognition_rate: float
    financing_netting_enabled: bool
    available_cash_share_of_aqlr: float
    collateral_haircut: float
    collateral_operational_availability_rate: float
    tolerance_usd: float
    member_id_column: str
    synthetic_id_pattern: str


@dataclass(frozen=True, slots=True)
class ValidationResult:
    """Structured Section 14 validation result."""

    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise BaselineLiquidityError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise BaselineLiquidityError(f"{key} must be numeric.")
    return float(value)


def _boolean(mapping: Mapping[str, Any], key: str) -> bool:
    value = mapping.get(key)
    if not isinstance(value, bool):
        raise BaselineLiquidityError(f"{key} must be true or false.")
    return value


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise BaselineLiquidityError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _schedule(
    payment_timing: Mapping[str, Any],
    key: str,
    bucket_names: Sequence[str],
) -> dict[str, float]:
    raw = _mapping(payment_timing.get(key), f"payment_timing.{key}")
    actual_names = set(str(name) for name in raw)
    expected_names = set(bucket_names)
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        raise BaselineLiquidityError(
            f"payment_timing.{key} must define every bucket exactly once; "
            f"missing={missing}, extra={extra}."
        )
    schedule = {name: float(raw[name]) for name in bucket_names}
    if any(not math.isfinite(value) or value < 0.0 for value in schedule.values()):
        raise BaselineLiquidityError(f"payment_timing.{key} contains invalid weights.")
    if not math.isclose(sum(schedule.values()), 1.0, abs_tol=1e-12):
        raise BaselineLiquidityError(f"payment_timing.{key} weights must sum to one.")
    return schedule


def load_settings(config: Mapping[str, Any]) -> BaselineSettings:
    """Validate and convert the baseline-liquidity configuration."""
    source = _mapping(config.get("source"), "source")
    horizon = _mapping(config.get("liquidity_horizon"), "liquidity_horizon")
    payment_timing = _mapping(config.get("payment_timing"), "payment_timing")
    assumptions = _mapping(config.get("assumptions"), "assumptions")
    validation = _mapping(config.get("validation"), "validation")

    raw_buckets = horizon.get("buckets")
    if not isinstance(raw_buckets, list) or not raw_buckets:
        raise BaselineLiquidityError("liquidity_horizon.buckets must be a nonempty list.")

    buckets: list[TimeBucket] = []
    names: set[str] = set()
    previous_hour = -1
    for raw_bucket in raw_buckets:
        bucket = _mapping(raw_bucket, "liquidity_horizon bucket")
        name = str(bucket.get("name", "")).strip()
        elapsed_hours = int(bucket.get("elapsed_hours", -1))
        if not name or name in names:
            raise BaselineLiquidityError("Liquidity-horizon bucket names must be unique and nonempty.")
        if elapsed_hours < 0 or elapsed_hours <= previous_hour:
            raise BaselineLiquidityError("Liquidity-horizon bucket hours must be strictly increasing.")
        names.add(name)
        previous_hour = elapsed_hours
        buckets.append(TimeBucket(name=name, elapsed_hours=elapsed_hours))

    horizon_hours = int(horizon.get("hours", 0))
    if horizon_hours <= 0 or buckets[-1].elapsed_hours > horizon_hours:
        raise BaselineLiquidityError(
            "liquidity_horizon.hours must be positive and cover the final time bucket."
        )

    bucket_names = [bucket.name for bucket in buckets]
    settings = BaselineSettings(
        model_version=str(config.get("model_version", "section-14-v1")),
        horizon_hours=horizon_hours,
        buckets=tuple(buckets),
        settlement_schedule=_schedule(payment_timing, "settlement_obligations", bucket_names),
        repo_maturity_schedule=_schedule(payment_timing, "repo_maturities", bucket_names),
        financing_inflow_schedule=_schedule(payment_timing, "financing_inflows", bucket_names),
        collateral_availability_schedule=_schedule(
            payment_timing,
            "eligible_collateral_availability",
            bucket_names,
        ),
        settlement_netting_rate=_number(assumptions, "settlement_netting_rate"),
        repo_roll_rate=_number(assumptions, "repo_roll_rate"),
        reverse_repo_inflow_recognition_rate=_number(
            assumptions,
            "reverse_repo_inflow_recognition_rate",
        ),
        financing_netting_enabled=_boolean(assumptions, "financing_netting_enabled"),
        available_cash_share_of_aqlr=_number(
            assumptions,
            "available_cash_share_of_aqlr",
        ),
        collateral_haircut=_number(assumptions, "eligible_collateral_haircut"),
        collateral_operational_availability_rate=_number(
            assumptions,
            "collateral_operational_availability_rate",
        ),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        member_id_column=str(source.get("member_id_column", "member_id")),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
    )

    bounded = {
        "settlement_netting_rate": settings.settlement_netting_rate,
        "repo_roll_rate": settings.repo_roll_rate,
        "reverse_repo_inflow_recognition_rate": settings.reverse_repo_inflow_recognition_rate,
        "available_cash_share_of_aqlr": settings.available_cash_share_of_aqlr,
        "eligible_collateral_haircut": settings.collateral_haircut,
        "collateral_operational_availability_rate": (
            settings.collateral_operational_availability_rate
        ),
    }
    for label, value in bounded.items():
        if not 0.0 <= value <= 1.0:
            raise BaselineLiquidityError(f"{label} must be between zero and one.")
    if settings.collateral_haircut >= 1.0:
        raise BaselineLiquidityError("eligible_collateral_haircut must be less than one.")
    if settings.tolerance_usd < 0.0:
        raise BaselineLiquidityError("reconciliation_tolerance_usd must be nonnegative.")
    if not settings.model_version.strip():
        raise BaselineLiquidityError("model_version must be populated.")
    return settings


def read_member_data(path: str | Path) -> pd.DataFrame:
    """Read synthetic member portfolios from CSV or Parquet."""
    data_path = Path(path)
    if not data_path.exists():
        raise BaselineLiquidityError(f"Synthetic member portfolios do not exist: {data_path}")
    if data_path.suffix.lower() == ".csv":
        return pd.read_csv(data_path)
    if data_path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(data_path)
    raise BaselineLiquidityError("Synthetic member portfolios must be CSV or Parquet.")


def prepare_members(members: pd.DataFrame, settings: BaselineSettings) -> pd.DataFrame:
    """Canonicalize and validate synthetic member inputs."""
    if members.empty:
        raise BaselineLiquidityError("Synthetic member portfolio dataset is empty.")
    frame = members.copy(deep=True)
    if settings.member_id_column not in frame.columns:
        raise BaselineLiquidityError(
            f"Configured member identifier column is missing: {settings.member_id_column}"
        )
    if settings.member_id_column != "member_id":
        frame = frame.rename(columns={settings.member_id_column: "member_id"})

    required = {
        "member_id",
        "settlement_obligation_usd",
        "repo_financing_need_usd",
        "reverse_repo_position_usd",
        "collateral_inventory_usd",
        "available_qualified_liquid_resources_usd",
    }
    missing = sorted(required - set(frame.columns))
    if missing:
        raise BaselineLiquidityError(f"Required synthetic member columns are missing: {missing}")

    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    if frame["member_id"].isna().any() or frame["member_id"].duplicated().any():
        raise BaselineLiquidityError("Synthetic member identifiers must be unique and nonmissing.")
    invalid_ids = [
        member_id
        for member_id in frame["member_id"].astype(str)
        if re.fullmatch(settings.synthetic_id_pattern, member_id) is None
    ]
    if invalid_ids:
        raise BaselineLiquidityError(
            f"Non-synthetic or invalid member identifiers detected: {sorted(invalid_ids)}"
        )

    if "actual_ficc_participant" in frame.columns and frame[
        "actual_ficc_participant"
    ].fillna(False).astype(bool).any():
        raise BaselineLiquidityError("Actual FICC participant records are prohibited.")
    if "participant_level_inference" in frame.columns and frame[
        "participant_level_inference"
    ].fillna(False).astype(bool).any():
        raise BaselineLiquidityError("Participant-level inference records are prohibited.")
    if "value_class" in frame.columns and not frame["value_class"].astype(str).eq(
        "synthetic"
    ).all():
        raise BaselineLiquidityError("Every input record must use value_class='synthetic'.")

    monetary_columns = sorted(required - {"member_id"})
    for column in monetary_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise BaselineLiquidityError(f"{column} contains missing or nonfinite values.")
        if (frame[column] < 0.0).any():
            raise BaselineLiquidityError(f"{column} contains negative values.")

    if (frame["reverse_repo_position_usd"] > frame["repo_financing_need_usd"]).any():
        raise BaselineLiquidityError("Reverse-repo positions exceed repo financing needs.")
    if (
        frame["available_qualified_liquid_resources_usd"]
        > frame["collateral_inventory_usd"]
    ).any():
        raise BaselineLiquidityError(
            "Available qualified liquid resources exceed collateral inventory."
        )

    if "as_of_date" not in frame.columns:
        frame["as_of_date"] = pd.NaT
    else:
        frame["as_of_date"] = pd.to_datetime(frame["as_of_date"], errors="coerce")

    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values("member_id", kind="stable").reset_index(drop=True)


def _resource_decomposition(
    member: pd.Series,
    settings: BaselineSettings,
) -> tuple[float, float, float, float]:
    source_aqlr = float(member["available_qualified_liquid_resources_usd"])
    collateral_inventory = float(member["collateral_inventory_usd"])
    available_cash = source_aqlr * settings.available_cash_share_of_aqlr
    remaining_post_haircut = max(source_aqlr - available_cash, 0.0)
    operational_collateral = (
        collateral_inventory * settings.collateral_operational_availability_rate
    )
    gross_needed = remaining_post_haircut / (1.0 - settings.collateral_haircut)
    eligible_collateral_market_value = min(operational_collateral, gross_needed)
    eligible_collateral_liquidity = (
        eligible_collateral_market_value * (1.0 - settings.collateral_haircut)
    )
    modeled_aqlr = available_cash + eligible_collateral_liquidity
    return (
        available_cash,
        eligible_collateral_market_value,
        eligible_collateral_liquidity,
        modeled_aqlr,
    )


def calculate_cashflows(
    members: pd.DataFrame,
    settings: BaselineSettings,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Calculate time-bucketed baseline cash flows and member summaries."""
    frame = prepare_members(members, settings)
    cashflow_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []

    for _, member in frame.iterrows():
        member_id = str(member["member_id"])
        available_cash, collateral_mv, collateral_liquidity, modeled_aqlr = (
            _resource_decomposition(member, settings)
        )
        cumulative_need = 0.0
        cumulative_collateral = 0.0
        member_rows: list[dict[str, object]] = []

        for bucket_order, bucket in enumerate(settings.buckets, start=1):
            settlement_gross = float(member["settlement_obligation_usd"]) * float(
                settings.settlement_schedule[bucket.name]
            )
            settlement_netting_benefit = settlement_gross * settings.settlement_netting_rate
            settlement_net = settlement_gross - settlement_netting_benefit

            repo_maturity = float(member["repo_financing_need_usd"]) * float(
                settings.repo_maturity_schedule[bucket.name]
            )
            repo_roll_amount = repo_maturity * settings.repo_roll_rate
            financing_outflow = repo_maturity - repo_roll_amount
            financing_inflow = (
                float(member["reverse_repo_position_usd"])
                * settings.reverse_repo_inflow_recognition_rate
                * float(settings.financing_inflow_schedule[bucket.name])
            )

            if settings.financing_netting_enabled:
                net_financing_outflow = max(financing_outflow - financing_inflow, 0.0)
                recognized_financing_inflow = max(financing_inflow - financing_outflow, 0.0)
            else:
                net_financing_outflow = financing_outflow
                recognized_financing_inflow = financing_inflow

            total_outflow = settlement_net + net_financing_outflow
            total_inflow = recognized_financing_inflow
            net_cash_flow = total_inflow - total_outflow
            cumulative_need = max(cumulative_need + total_outflow - total_inflow, 0.0)

            incremental_collateral = collateral_liquidity * float(
                settings.collateral_availability_schedule[bucket.name]
            )
            cumulative_collateral += incremental_collateral
            cumulative_resources = available_cash + cumulative_collateral
            headroom = cumulative_resources - cumulative_need
            shortfall = max(-headroom, 0.0)

            row: dict[str, object] = {
                "member_id": member_id,
                "as_of_date": member["as_of_date"],
                "bucket_order": bucket_order,
                "time_bucket": bucket.name,
                "elapsed_hours": bucket.elapsed_hours,
                "liquidity_horizon_hours": settings.horizon_hours,
                "gross_settlement_obligation_usd": settlement_gross,
                "settlement_netting_benefit_usd": settlement_netting_benefit,
                "net_settlement_outflow_usd": settlement_net,
                "repo_maturity_usd": repo_maturity,
                "repo_roll_amount_usd": repo_roll_amount,
                "financing_outflow_usd": financing_outflow,
                "financing_inflow_usd": financing_inflow,
                "net_financing_outflow_usd": net_financing_outflow,
                "recognized_financing_inflow_usd": recognized_financing_inflow,
                "total_cash_outflow_usd": total_outflow,
                "total_cash_inflow_usd": total_inflow,
                "net_cash_flow_usd": net_cash_flow,
                "cumulative_net_liquidity_need_usd": cumulative_need,
                "available_cash_usd": available_cash,
                "eligible_collateral_market_value_usd": collateral_mv,
                "incremental_eligible_collateral_liquidity_usd": incremental_collateral,
                "eligible_collateral_liquidity_usd": collateral_liquidity,
                "cumulative_available_resources_usd": cumulative_resources,
                "liquidity_headroom_usd": headroom,
                "liquidity_shortfall_usd": shortfall,
                "source_aqlr_usd": float(
                    member["available_qualified_liquid_resources_usd"]
                ),
                "modeled_aqlr_usd": modeled_aqlr,
                "settlement_netting_rate": settings.settlement_netting_rate,
                "repo_roll_rate": settings.repo_roll_rate,
                "financing_netting_enabled": settings.financing_netting_enabled,
                "model_version": settings.model_version,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
            member_rows.append(row)
            cashflow_rows.append(row)

        member_frame = pd.DataFrame.from_records(member_rows)
        peak_need = float(member_frame["cumulative_net_liquidity_need_usd"].max())
        minimum_headroom = float(member_frame["liquidity_headroom_usd"].min())
        maximum_shortfall = float(member_frame["liquidity_shortfall_usd"].max())
        first_shortfall = member_frame.loc[
            member_frame["liquidity_shortfall_usd"] > settings.tolerance_usd,
            "time_bucket",
        ]
        coverage_ratio = modeled_aqlr / max(peak_need, 0.01)
        summary_rows.append(
            {
                "member_id": member_id,
                "as_of_date": member["as_of_date"],
                "liquidity_horizon_hours": settings.horizon_hours,
                "gross_settlement_obligation_usd": float(
                    member_frame["gross_settlement_obligation_usd"].sum()
                ),
                "net_settlement_outflow_usd": float(
                    member_frame["net_settlement_outflow_usd"].sum()
                ),
                "repo_maturity_usd": float(member_frame["repo_maturity_usd"].sum()),
                "financing_outflow_usd": float(
                    member_frame["financing_outflow_usd"].sum()
                ),
                "financing_inflow_usd": float(
                    member_frame["financing_inflow_usd"].sum()
                ),
                "available_cash_usd": available_cash,
                "eligible_collateral_market_value_usd": collateral_mv,
                "eligible_collateral_liquidity_usd": collateral_liquidity,
                "source_aqlr_usd": float(
                    member["available_qualified_liquid_resources_usd"]
                ),
                "modeled_aqlr_usd": modeled_aqlr,
                "peak_liquidity_need_usd": peak_need,
                "minimum_liquidity_headroom_usd": minimum_headroom,
                "maximum_liquidity_shortfall_usd": maximum_shortfall,
                "liquidity_coverage_ratio": coverage_ratio,
                "first_shortfall_bucket": (
                    str(first_shortfall.iloc[0]) if not first_shortfall.empty else ""
                ),
                "baseline_liquidity_status": (
                    "COVERED" if maximum_shortfall <= settings.tolerance_usd else "SHORTFALL"
                ),
                "model_version": settings.model_version,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )

    cashflows = pd.DataFrame.from_records(cashflow_rows).sort_values(
        ["member_id", "bucket_order"],
        kind="stable",
    ).reset_index(drop=True)
    summary = pd.DataFrame.from_records(summary_rows).sort_values(
        "member_id",
        kind="stable",
    ).reset_index(drop=True)
    return cashflows, summary


def _within_tolerance(left: pd.Series, right: pd.Series, tolerance: float) -> bool:
    differences = (pd.to_numeric(left) - pd.to_numeric(right)).abs()
    return bool((differences <= tolerance).all())


def validate_results(
    members: pd.DataFrame,
    cashflows: pd.DataFrame,
    summary: pd.DataFrame,
    settings: BaselineSettings,
) -> ValidationResult:
    """Validate Section 14 accounting, timing, resource, and identity controls."""
    source = prepare_members(members, settings).set_index("member_id")
    summary_indexed = summary.set_index("member_id")
    grouped = cashflows.groupby("member_id", sort=True)

    member_bucket_complete = len(cashflows) == len(source) * len(settings.buckets)
    unique_member_bucket = not cashflows.duplicated(["member_id", "time_bucket"]).any()
    horizon_ordered = bool(
        grouped["elapsed_hours"].apply(lambda values: values.is_monotonic_increasing).all()
    )

    settlement_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "gross_settlement_obligation_usd"],
        source["settlement_obligation_usd"],
        settings.tolerance_usd,
    )
    repo_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "repo_maturity_usd"],
        source["repo_financing_need_usd"],
        settings.tolerance_usd,
    )
    expected_financing_inflow = (
        source["reverse_repo_position_usd"]
        * settings.reverse_repo_inflow_recognition_rate
    )
    financing_inflow_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "financing_inflow_usd"],
        expected_financing_inflow,
        settings.tolerance_usd,
    )
    expected_financing_outflow = source["repo_financing_need_usd"] * (
        1.0 - settings.repo_roll_rate
    )
    financing_outflow_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "financing_outflow_usd"],
        expected_financing_outflow,
        settings.tolerance_usd,
    )
    aqlr_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "modeled_aqlr_usd"],
        source["available_qualified_liquid_resources_usd"],
        settings.tolerance_usd,
    )

    nonnegative_columns = [
        column
        for column in cashflows.columns
        if column.endswith("_usd")
        and column not in {"net_cash_flow_usd", "liquidity_headroom_usd"}
    ]
    nonnegative_cashflow_components = bool(
        (cashflows[nonnegative_columns] >= -settings.tolerance_usd).all().all()
    )
    synthetic_only = bool(
        cashflows["value_class"].eq("synthetic").all()
        and not cashflows["actual_ficc_participant"].astype(bool).any()
        and not cashflows["participant_level_inference"].astype(bool).any()
        and summary["value_class"].eq("synthetic").all()
        and not summary["actual_ficc_participant"].astype(bool).any()
        and not summary["participant_level_inference"].astype(bool).any()
    )
    shortfall_identity = bool(
        (
            cashflows["liquidity_shortfall_usd"]
            - (-cashflows["liquidity_headroom_usd"]).clip(lower=0.0)
        )
        .abs()
        .le(settings.tolerance_usd)
        .all()
    )
    resource_timing_reconciliation = bool(
        grouped["incremental_eligible_collateral_liquidity_usd"]
        .sum()
        .sort_index()
        .sub(summary_indexed["eligible_collateral_liquidity_usd"].sort_index())
        .abs()
        .le(settings.tolerance_usd)
        .all()
    )

    checks = {
        "member_bucket_completeness": member_bucket_complete,
        "unique_member_time_buckets": unique_member_bucket,
        "payment_timing_is_ordered": horizon_ordered,
        "settlement_obligations_reconcile": settlement_reconciliation,
        "repo_maturities_reconcile": repo_reconciliation,
        "financing_inflows_reconcile": financing_inflow_reconciliation,
        "financing_outflows_reconcile": financing_outflow_reconciliation,
        "available_qualified_liquid_resources_reconcile": aqlr_reconciliation,
        "eligible_collateral_timing_reconciles": resource_timing_reconciliation,
        "nonnegative_cashflow_components": nonnegative_cashflow_components,
        "liquidity_shortfall_identity": shortfall_identity,
        "synthetic_members_only": synthetic_only,
    }
    return ValidationResult(checks=checks)


def run_engine(
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> tuple[pd.DataFrame, pd.DataFrame, ValidationResult]:
    """Run the deterministic baseline engine and validate outputs."""
    settings = load_settings(config)
    cashflows, summary = calculate_cashflows(members, settings)
    validation = validate_results(members, cashflows, summary, settings)

    shuffled = members.sample(frac=1.0, random_state=2026).reset_index(drop=True)
    repeated_cashflows, repeated_summary = calculate_cashflows(shuffled, settings)
    deterministic = cashflows.equals(repeated_cashflows) and summary.equals(repeated_summary)
    checks = dict(validation.checks)
    checks["deterministic_reproduction"] = deterministic
    return cashflows, summary, ValidationResult(checks=checks)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_frame(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix.lower() == ".csv":
        frame.to_csv(path, index=False)
    elif path.suffix.lower() in {".parquet", ".pq"}:
        frame.to_parquet(path, index=False)
    else:
        raise BaselineLiquidityError("Output paths must use .csv or .parquet.")


def write_outputs(
    cashflows: pd.DataFrame,
    summary: pd.DataFrame,
    validation: ValidationResult,
    *,
    source_path: Path,
    config_path: Path,
    cashflow_path: Path,
    summary_path: Path,
    manifest_path: Path,
    evidence_path: Path,
) -> None:
    """Write controlled model outputs, lineage manifest, and evidence."""
    _write_frame(cashflows, cashflow_path)
    _write_frame(summary, summary_path)

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = pd.DataFrame(
        [
            {
                "dataset": "baseline_liquidity_cashflows",
                "value_class": "modeled_from_synthetic_inputs",
                "source_file": source_path.as_posix(),
                "source_sha256": _sha256(source_path),
                "config_file": config_path.as_posix(),
                "config_sha256": _sha256(config_path),
                "cashflow_file": cashflow_path.as_posix(),
                "cashflow_sha256": _sha256(cashflow_path),
                "summary_file": summary_path.as_posix(),
                "summary_sha256": _sha256(summary_path),
                "cashflow_row_count": len(cashflows),
                "summary_row_count": len(summary),
                "actual_ficc_participants": False,
                "participant_level_inference": False,
                "generated_at_utc": datetime.now(UTC).isoformat(),
                "gate_status": "PASS" if validation.passed else "FAIL",
            }
        ]
    )
    manifest.to_csv(manifest_path, index=False)

    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "PHASE V ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â SECTION 14: BASELINE LIQUIDITY CASH-FLOW ENGINE",
        "=" * 74,
        f"Generated at UTC: {datetime.now(UTC).isoformat()}",
        f"Source synthetic portfolio: {source_path.as_posix()}",
        f"Configuration: {config_path.as_posix()}",
        f"Synthetic members: {summary['member_id'].nunique()}",
        f"Cash-flow rows: {len(cashflows)}",
        f"Liquidity horizon hours: {int(cashflows['liquidity_horizon_hours'].iloc[0])}",
        "Actual FICC participants represented: NO",
        "Participant-level inference performed: NO",
        "",
        "CONTROL RESULTS",
    ]
    for name, passed in validation.checks.items():
        lines.append(f"{name}: {'PASS' if passed else 'FAIL'}")
    lines.extend(
        [
            "",
            f"Members with baseline shortfall: "
            f"{int(summary['baseline_liquidity_status'].eq('SHORTFALL').sum())}",
            f"Maximum baseline shortfall USD: "
            f"{float(summary['maximum_liquidity_shortfall_usd'].max()):.2f}",
            "",
            "Section 14 final decision: " + ("PASS" if validation.passed else "FAIL"),
        ]
    )
    evidence_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    """Build the Section 14 command-line interface."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--members",
        type=Path,
        default=Path("data/synthetic/calibrated_member_portfolios.parquet"),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/baseline_liquidity.yaml"),
    )
    parser.add_argument(
        "--cashflows",
        type=Path,
        default=Path("reports/tables/baseline_liquidity_cashflows.csv"),
    )
    parser.add_argument(
        "--summary",
        type=Path,
        default=Path("reports/tables/baseline_liquidity_summary.csv"),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("data/manifests/baseline_liquidity_manifest.csv"),
    )
    parser.add_argument(
        "--evidence",
        type=Path,
        default=Path("reports/evidence/section14_baseline_liquidity_validation.txt"),
    )
    return parser


def main() -> int:
    """Run the Section 14 command-line workflow."""
    args = build_parser().parse_args()
    config = load_config(args.config)
    members = read_member_data(args.members)
    cashflows, summary, validation = run_engine(members, config)
    write_outputs(
        cashflows,
        summary,
        validation,
        source_path=args.members,
        config_path=args.config,
        cashflow_path=args.cashflows,
        summary_path=args.summary,
        manifest_path=args.manifest,
        evidence_path=args.evidence,
    )
    print(json.dumps({"checks": validation.checks, "passed": validation.passed}, indent=2))
    return 0 if validation.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@
    $RunnerContent = @'
"""Run the Phase V Section 14 baseline liquidity cash-flow engine."""

from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = PROJECT_ROOT / "src"
if str(SRC_ROOT) not in sys.path:
    sys.path.insert(0, str(SRC_ROOT))

from ficc_liquidity.liquidity.baseline_cashflow import main  # noqa: E402, I001


if __name__ == "__main__":
    raise SystemExit(main())
'@
    $TestContent = @'
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.liquidity import baseline_cashflow as model


def _config() -> dict[str, Any]:
    return {
        "model_version": "section-14-v1",
        "source": {
            "member_id_column": "member_id",
            "synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$",
        },
        "liquidity_horizon": {
            "hours": 48,
            "buckets": [
                {"name": "day1_open", "elapsed_hours": 0},
                {"name": "day1_midday", "elapsed_hours": 6},
                {"name": "day1_close", "elapsed_hours": 12},
                {"name": "day2_open", "elapsed_hours": 24},
                {"name": "day2_close", "elapsed_hours": 36},
            ],
        },
        "payment_timing": {
            "settlement_obligations": {
                "day1_open": 0.35,
                "day1_midday": 0.30,
                "day1_close": 0.25,
                "day2_open": 0.10,
                "day2_close": 0.00,
            },
            "repo_maturities": {
                "day1_open": 0.20,
                "day1_midday": 0.30,
                "day1_close": 0.30,
                "day2_open": 0.15,
                "day2_close": 0.05,
            },
            "financing_inflows": {
                "day1_open": 0.10,
                "day1_midday": 0.25,
                "day1_close": 0.30,
                "day2_open": 0.25,
                "day2_close": 0.10,
            },
            "eligible_collateral_availability": {
                "day1_open": 0.00,
                "day1_midday": 0.25,
                "day1_close": 0.45,
                "day2_open": 0.20,
                "day2_close": 0.10,
            },
        },
        "assumptions": {
            "settlement_netting_rate": 0.25,
            "repo_roll_rate": 0.80,
            "reverse_repo_inflow_recognition_rate": 0.95,
            "financing_netting_enabled": True,
            "available_cash_share_of_aqlr": 0.35,
            "eligible_collateral_haircut": 0.05,
            "collateral_operational_availability_rate": 0.90,
        },
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


def _members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "as_of_date": ["2026-07-01", "2026-07-01"],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
            "settlement_obligation_usd": [1_000.0, 800.0],
            "repo_financing_need_usd": [600.0, 400.0],
            "reverse_repo_position_usd": [200.0, 100.0],
            "collateral_inventory_usd": [1_000.0, 800.0],
            "available_qualified_liquid_resources_usd": [700.0, 500.0],
        }
    )


def test_engine_reconciles_all_baseline_components() -> None:
    cashflows, summary, validation = model.run_engine(_members(), _config())

    assert validation.passed
    assert len(cashflows) == 10
    assert len(summary) == 2
    assert summary["gross_settlement_obligation_usd"].tolist() == pytest.approx(
        [1_000.0, 800.0]
    )
    assert summary["repo_maturity_usd"].tolist() == pytest.approx([600.0, 400.0])
    assert summary["financing_inflow_usd"].tolist() == pytest.approx([190.0, 95.0])
    assert summary["modeled_aqlr_usd"].tolist() == pytest.approx([700.0, 500.0])
    assert not cashflows["actual_ficc_participant"].any()


def test_engine_is_independent_of_input_row_order() -> None:
    first = model.run_engine(_members(), _config())
    shuffled = _members().iloc[::-1].reset_index(drop=True)
    second = model.run_engine(shuffled, _config())

    assert first[0].equals(second[0])
    assert first[1].equals(second[1])
    assert first[2].passed and second[2].passed


def test_financing_netting_can_be_disabled() -> None:
    config = _config()
    config["assumptions"]["financing_netting_enabled"] = False
    cashflows, summary, validation = model.run_engine(_members(), config)

    assert validation.passed
    assert cashflows["net_financing_outflow_usd"].sum() == pytest.approx(
        summary["financing_outflow_usd"].sum()
    )
    assert cashflows["recognized_financing_inflow_usd"].sum() == pytest.approx(
        summary["financing_inflow_usd"].sum()
    )


def test_member_id_alias_is_supported() -> None:
    config = _config()
    config["source"]["member_id_column"] = "synthetic_member_id"
    members = _members().rename(columns={"member_id": "synthetic_member_id"})

    _, summary, validation = model.run_engine(members, config)

    assert validation.passed
    assert summary["member_id"].tolist() == ["SYN-MBR-0001", "SYN-MBR-0002"]


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (
            lambda config: config["payment_timing"]["repo_maturities"].update(
                {"day2_close": 0.10}
            ),
            "weights must sum to one",
        ),
        (
            lambda config: config["assumptions"].update(
                {"settlement_netting_rate": 1.10}
            ),
            "must be between zero and one",
        ),
        (
            lambda config: config["liquidity_horizon"].update({"hours": 12}),
            "cover the final time bucket",
        ),
    ],
)
def test_invalid_model_configurations_are_rejected(mutation: Any, message: str) -> None:
    config = _config()
    mutation(config)
    with pytest.raises(model.BaselineLiquidityError, match=message):
        model.load_settings(config)


def test_missing_or_extra_schedule_buckets_are_rejected() -> None:
    config = _config()
    del config["payment_timing"]["settlement_obligations"]["day2_close"]
    config["payment_timing"]["settlement_obligations"]["unexpected"] = 0.0

    with pytest.raises(model.BaselineLiquidityError, match="define every bucket"):
        model.load_settings(config)


@pytest.mark.parametrize(
    ("column", "value", "message"),
    [
        ("member_id", "REAL-MEMBER", "Non-synthetic"),
        ("settlement_obligation_usd", -1.0, "negative"),
        ("reverse_repo_position_usd", 700.0, "exceed repo financing"),
        (
            "available_qualified_liquid_resources_usd",
            1_500.0,
            "exceed collateral inventory",
        ),
    ],
)
def test_invalid_synthetic_member_values_are_rejected(
    column: str,
    value: object,
    message: str,
) -> None:
    members = _members()
    members.loc[0, column] = cast(Any, value)
    settings = model.load_settings(_config())

    with pytest.raises(model.BaselineLiquidityError, match=message):
        model.prepare_members(members, settings)


def test_actual_participant_and_inference_flags_are_rejected() -> None:
    settings = model.load_settings(_config())
    actual = _members()
    actual.loc[0, "actual_ficc_participant"] = True
    inferred = _members()
    inferred.loc[0, "participant_level_inference"] = True

    with pytest.raises(model.BaselineLiquidityError, match="Actual FICC"):
        model.prepare_members(actual, settings)
    with pytest.raises(model.BaselineLiquidityError, match="Participant-level inference"):
        model.prepare_members(inferred, settings)


def test_missing_required_member_column_is_rejected() -> None:
    members = _members().drop(columns="collateral_inventory_usd")
    settings = model.load_settings(_config())

    with pytest.raises(model.BaselineLiquidityError, match="Required synthetic member columns"):
        model.prepare_members(members, settings)


def test_csv_reader_and_configuration_loader(tmp_path: Path) -> None:
    member_path = tmp_path / "members.csv"
    config_path = tmp_path / "config.yaml"
    _members().to_csv(member_path, index=False)
    config_path.write_text(yaml.safe_dump(_config(), sort_keys=False), encoding="utf-8")

    assert len(model.read_member_data(member_path)) == 2
    assert model.load_config(config_path)["model_version"] == "section-14-v1"

    invalid_path = tmp_path / "members.txt"
    invalid_path.write_text("x", encoding="utf-8")
    with pytest.raises(model.BaselineLiquidityError, match="must be CSV or Parquet"):
        model.read_member_data(invalid_path)


def test_cli_writes_controlled_outputs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    member_path = tmp_path / "members.csv"
    config_path = tmp_path / "config.yaml"
    cashflow_path = tmp_path / "cashflows.csv"
    summary_path = tmp_path / "summary.csv"
    manifest_path = tmp_path / "manifest.csv"
    evidence_path = tmp_path / "evidence.txt"
    _members().to_csv(member_path, index=False)
    config_path.write_text(yaml.safe_dump(_config(), sort_keys=False), encoding="utf-8")

    monkeypatch.setattr(
        sys,
        "argv",
        [
            "baseline_cashflow",
            "--members",
            str(member_path),
            "--config",
            str(config_path),
            "--cashflows",
            str(cashflow_path),
            "--summary",
            str(summary_path),
            "--manifest",
            str(manifest_path),
            "--evidence",
            str(evidence_path),
        ],
    )

    assert model.main() == 0
    assert cashflow_path.exists()
    assert summary_path.exists()
    assert manifest_path.exists()
    assert "Section 14 final decision: PASS" in evidence_path.read_text(encoding="utf-8")
    manifest = pd.read_csv(manifest_path)
    assert manifest.loc[0, "gate_status"] == "PASS"
    assert not bool(manifest.loc[0, "actual_ficc_participants"])


def test_invalid_output_extension_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(model.BaselineLiquidityError, match="Output paths"):
        model._write_frame(pd.DataFrame({"a": [1]}), tmp_path / "output.txt")


def test_load_config_rejects_missing_and_nonmapping_files(tmp_path: Path) -> None:
    with pytest.raises(model.BaselineLiquidityError, match="does not exist"):
        model.load_config(tmp_path / "missing.yaml")

    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(model.BaselineLiquidityError, match="must be a YAML mapping"):
        model.load_config(invalid)
'@
    $DocumentationContent = @'
# Baseline Liquidity Cash-Flow Engine

## Purpose

Phase V, Section 14 establishes the unstressed liquidity cash-flow engine used as the reference point for later historical, hypothetical, reverse, Cover 1, and Cover 2 stress tests. The engine operates only on fictional `SYN-MBR-####` clearing-member portfolios. It does not represent, estimate, rank, identify, or reverse engineer any actual FICC participant.

## Value classification

| Element | Classification | Treatment |
|---|---|---|
| Calibrated member portfolio fields | Synthetic | Generated in Phase IV from public aggregate controls. |
| Payment timing, netting, roll, recognition, cash-share, haircut, and operational-availability parameters | Assumed | Controlled in `configs/baseline_liquidity.yaml`. |
| Time-bucketed cash flows, cumulative needs, resources, headroom, shortfalls, and coverage ratios | Modeled | Deterministic outputs of the Section 14 engine. |

## Modeled components

The engine produces one row per synthetic member and payment-time bucket. It models:

- gross and net settlement cash obligations;
- repo maturities and the portion not rolled at maturity;
- recognized reverse-repo financing inflows;
- financing outflows after the baseline roll assumption;
- available cash at the start of the horizon;
- eligible collateral market value and post-haircut liquidity;
- settlement and financing netting assumptions;
- configurable payment timing over a 48-hour liquidity horizon;
- cumulative net liquidity need, available resources, headroom, and shortfall;
- available qualified liquid resources and the resulting baseline liquidity-coverage ratio.

## Core equations

For member `i` and time bucket `t`:

```text
gross settlement(i,t) = settlement obligation(i) ÃƒÆ’Ã¢â‚¬â€ settlement schedule(t)
net settlement(i,t) = gross settlement(i,t) ÃƒÆ’Ã¢â‚¬â€ (1 - settlement netting rate)
repo maturity(i,t) = repo financing need(i) ÃƒÆ’Ã¢â‚¬â€ repo maturity schedule(t)
financing outflow(i,t) = repo maturity(i,t) ÃƒÆ’Ã¢â‚¬â€ (1 - repo roll rate)
financing inflow(i,t) = reverse repo(i) ÃƒÆ’Ã¢â‚¬â€ recognition rate ÃƒÆ’Ã¢â‚¬â€ inflow schedule(t)
```

When financing netting is enabled, inflows and outflows are offset within each bucket before the residual is included in cash need. Cumulative net liquidity need is floored at zero. Available cash is recognized at the opening bucket. Eligible collateral liquidity is recognized according to the configured operational timing schedule after the configured haircut.

The source AQLR amount is decomposed into available cash and post-haircut eligible collateral liquidity without double counting. The default assumptions are selected so that the modeled decomposition reconciles to source AQLR to the configured USD tolerance.

## Validation controls

The implementation requires:

- complete and unique member-time buckets;
- strictly increasing payment times within the horizon;
- exact settlement-obligation reconciliation;
- exact repo-maturity reconciliation;
- financing inflow and outflow reconciliation;
- AQLR and eligible-collateral timing reconciliation;
- nonnegative gross cash-flow components;
- exact liquidity-shortfall identity;
- deterministic results independent of input row order;
- synthetic identifiers only, with no participant-level inference.

## Limitations

This is a baseline cash-flow model, not a legal interpretation of FICC rules and not a participant-level exposure model. Payment schedules, netting rates, repo roll rates, recognition rates, collateral haircuts, operational availability, and cash composition are explicit assumptions. Later phases should stress these assumptions rather than treating them as observed facts.
'@

    Write-Utf8File -Path "configs\baseline_liquidity.yaml" -Content $ConfigContent
    Write-Utf8File -Path "src\ficc_liquidity\liquidity\__init__.py" -Content $InitContent
    Write-Utf8File `
        -Path "src\ficc_liquidity\liquidity\baseline_cashflow.py" `
        -Content $ModuleContent
    Write-Utf8File -Path "scripts\run_baseline_liquidity.py" -Content $RunnerContent
    Write-Utf8File -Path "tests\test_baseline_liquidity.py" -Content $TestContent
    Write-Utf8File -Path "docs\baseline_liquidity_methodology.md" -Content $DocumentationContent
    Write-Pass "Section 14 source, configuration, tests, and documentation were written"

    Write-Step "Selecting Python 3.11 and installing the repository in editable mode"
    $PythonCommand = $null
    $PythonPrefix = @()
    if (Test-Path -LiteralPath ".venv\Scripts\python.exe" -PathType Leaf) {
        $PythonCommand = (Resolve-Path -LiteralPath ".venv\Scripts\python.exe").Path
    }
    elseif (Get-Command "py" -ErrorAction SilentlyContinue) {
        $PythonCommand = "py"
        $PythonPrefix = @("-3.11")
    }
    elseif (Get-Command "python" -ErrorAction SilentlyContinue) {
        $PythonCommand = "python"
    }
    else {
        throw "Python 3.11 was not found. Select the repository .venv interpreter in VS Code."
    }

    function Invoke-Python {
        param(
            [Parameter(Mandatory = $true)][string[]]$ArgumentList,
            [Parameter()][string]$FailureMessage = "Python command failed."
        )
        Invoke-Checked -FilePath $PythonCommand `
            -ArgumentList ($PythonPrefix + $ArgumentList) `
            -FailureMessage $FailureMessage
    }

    Invoke-Python `
        -ArgumentList @("-m", "pip", "install", "-e", ".[dev]") `
        -FailureMessage "Unable to install the repository and development dependencies."

    $pythonVersion = (& $PythonCommand @PythonPrefix -c `
        "import sys; print('.'.join(map(str, sys.version_info[:3])))").Trim()
    if ($LASTEXITCODE -ne 0 -or -not $pythonVersion.StartsWith("3.11.")) {
        throw "Section 14 requires Python 3.11; selected interpreter is $pythonVersion."
    }
    Write-Pass "Python interpreter: $pythonVersion"

    $qualityPaths = @(
        "src\ficc_liquidity\liquidity\__init__.py",
        "src\ficc_liquidity\liquidity\baseline_cashflow.py",
        "scripts\run_baseline_liquidity.py",
        "tests\test_baseline_liquidity.py"
    )

    Write-Step "Formatting, linting, and type-checking Section 14"
    Invoke-Python `
        -ArgumentList (@("-m", "ruff", "format") + $qualityPaths) `
        -FailureMessage "Ruff formatting failed."
    Invoke-Python `
        -ArgumentList (@("-m", "ruff", "check") + $qualityPaths) `
        -FailureMessage "Ruff validation failed."
    Invoke-Python `
        -ArgumentList (@("-m", "mypy") + $qualityPaths) `
        -FailureMessage "Strict Mypy validation failed."
    Write-Pass "Ruff and strict Mypy validation passed"

    Write-Step "Running the baseline liquidity cash-flow engine"
    Invoke-Python `
        -ArgumentList @("scripts\run_baseline_liquidity.py") `
        -FailureMessage "The Section 14 baseline engine failed."

    $requiredOutputs = @(
        "reports\tables\baseline_liquidity_cashflows.csv",
        "reports\tables\baseline_liquidity_summary.csv",
        "data\manifests\baseline_liquidity_manifest.csv",
        "reports\evidence\section14_baseline_liquidity_validation.txt"
    )
    if (-not (Test-RequiredFiles -Paths $requiredOutputs)) {
        throw "One or more Section 14 controlled outputs were not created."
    }
    Write-Pass "Baseline cash-flow, summary, manifest, and evidence outputs were created"

    Write-Step "Running focused Section 14 tests with branch coverage"
    Invoke-Python `
        -ArgumentList @(
            "-m", "pytest",
            "-q",
            "-o", "addopts=",
            "tests\test_baseline_liquidity.py",
            "--cov=ficc_liquidity.liquidity.baseline_cashflow",
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under=85"
        ) `
        -FailureMessage "Focused Section 14 tests or coverage gate failed."
    Write-Pass "Focused Section 14 tests and coverage gate passed"

    if (-not $SkipFullTests) {
        Write-Step "Running the complete repository validation suite"
        Invoke-Python `
            -ArgumentList @("-m", "pytest", "-q") `
            -FailureMessage "The complete repository test suite failed."
        Write-Pass "Complete repository test suite passed"
    }
    else {
        Write-Warn "Complete repository tests were skipped by request."
    }

    $evidencePath = "reports\evidence\section14_baseline_liquidity_validation.txt"
    $evidence = Get-Content -LiteralPath $evidencePath -Raw
    $evidence += @"

AUTOMATION QUALITY GATES
Ruff formatting: PASS
Ruff linting: PASS
Strict Mypy: PASS
Focused Section 14 tests: PASS
Section 14 branch coverage minimum 85 percent: PASS
Complete repository tests: $(if ($SkipFullTests) { "SKIPPED" } else { "PASS" })
"@
    Write-Utf8File -Path $evidencePath -Content $evidence

    Write-Step "Validating generated evidence and summary metrics"
    $decision = Select-String `
        -LiteralPath $evidencePath `
        -Pattern "Section 14 final decision: PASS" `
        -SimpleMatch
    if (-not $decision) {
        throw "The Section 14 evidence file does not contain a PASS decision."
    }

    Invoke-Python `
        -ArgumentList @(
            "-c",
            "import pandas as pd; s=pd.read_csv('reports/tables/baseline_liquidity_summary.csv'); " +
            "assert len(s)>0; assert s['member_id'].str.fullmatch(r'SYN-MBR-[0-9]{4}').all(); " +
            "assert not s['actual_ficc_participant'].astype(bool).any(); " +
            "print({'members': len(s), 'shortfalls': int((s['baseline_liquidity_status']=='SHORTFALL').sum()), " +
            "'max_shortfall_usd': float(s['maximum_liquidity_shortfall_usd'].max())})"
        ) `
        -FailureMessage "Final Section 14 output validation failed."
    Write-Pass "Section 14 completion evidence is valid"

    $prNumber = $null
    if (-not $SkipGit) {
        Write-Step "Staging and committing Section 14"
        $pathsToStage = @(
            $AutomationRelativePath,
            "configs\baseline_liquidity.yaml",
            "data\manifests\baseline_liquidity_manifest.csv",
            "docs\baseline_liquidity_methodology.md",
            "reports\evidence\section14_baseline_liquidity_validation.txt",
            "reports\tables\baseline_liquidity_cashflows.csv",
            "reports\tables\baseline_liquidity_summary.csv",
            "scripts\run_baseline_liquidity.py",
            "src\ficc_liquidity\liquidity\__init__.py",
            "src\ficc_liquidity\liquidity\baseline_cashflow.py",
            "tests\test_baseline_liquidity.py"
        )
        Invoke-Checked -FilePath "git" `
            -ArgumentList (@("add", "--") + $pathsToStage) `
            -FailureMessage "Unable to stage Section 14 files."

        & git diff --cached --quiet
        $hasStagedChanges = $LASTEXITCODE -ne 0
        if ($hasStagedChanges -and -not $NoCommit) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("commit", "-m", $CommitMessage) `
                -FailureMessage "Unable to commit Section 14."
            Write-Pass "Section 14 changes were committed"
        }
        elseif ($NoCommit) {
            Write-Warn "Changes were staged but not committed because -NoCommit was used."
        }
        else {
            Write-Warn "No new staged changes were detected."
        }

        if (-not $SkipPush -and -not $NoCommit) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("push", "-u", "origin", $BranchName) `
                -FailureMessage "Unable to push $BranchName."
            Write-Pass "Branch was pushed to origin"
        }
        else {
            Write-Warn "Git push was skipped."
        }

        if (-not $SkipPullRequest -and -not $SkipPush -and -not $NoCommit) {
            Assert-Command -Name "gh"
            $existingPrJson = & gh pr list `
                --repo $RepoFullName `
                --head $BranchName `
                --base main `
                --state open `
                --json number
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect existing Section 14 pull requests."
            }
            $existingPrData = @($existingPrJson | ConvertFrom-Json)
            $existingPr = if ($existingPrData.Count -gt 0) {
                [string]$existingPrData[0].number
            }
            else {
                ""
            }

            if ($existingPr) {
                $prNumber = $existingPr
                Write-Warn "An open pull request already exists: #$prNumber"
            }
            else {
                $pullRequestBody = @"
Completes Phase V, Section 14: baseline liquidity cash-flow engine.

Implements:
- settlement cash obligations;
- repo maturities;
- financing inflows and outflows;
- available cash;
- eligible collateral liquidity;
- configurable settlement and financing netting;
- configurable payment timing and a 48-hour liquidity horizon;
- available qualified liquid resources;
- deterministic member-level cash-flow and summary outputs;
- synthetic-only and no-participant-inference controls;
- Ruff, strict Mypy, focused coverage, and repository test gates.
"@
                Invoke-Checked -FilePath "gh" `
                    -ArgumentList @(
                        "pr", "create",
                        "--repo", $RepoFullName,
                        "--base", "main",
                        "--head", $BranchName,
                        "--title", "Phase V Section 14: Baseline liquidity cash-flow engine",
                        "--body", $pullRequestBody
                    ) `
                    -FailureMessage "Unable to create the Section 14 pull request."
                $createdPrJson = & gh pr list `
                    --repo $RepoFullName `
                    --head $BranchName `
                    --base main `
                    --state open `
                    --json number
                if ($LASTEXITCODE -ne 0) {
                    throw "Unable to read the newly created Section 14 pull request."
                }
                $createdPrData = @($createdPrJson | ConvertFrom-Json)
                $prNumber = if ($createdPrData.Count -gt 0) {
                    [string]$createdPrData[0].number
                }
                else {
                    ""
                }
            }
            if ($prNumber) {
                Write-Pass "Section 14 pull request is open: #$prNumber"
            }
        }
    }

    Write-Step "Phase V Section 14 completed"
    Write-Host "Branch: $BranchName"
    Write-Host "Evidence: $RepoPath\reports\evidence\section14_baseline_liquidity_validation.txt"
    Write-Host "Cash flows: $RepoPath\reports\tables\baseline_liquidity_cashflows.csv"
    Write-Host "Summary: $RepoPath\reports\tables\baseline_liquidity_summary.csv"
    if ($prNumber) {
        Write-Host "Next command: gh pr checks $prNumber --repo $RepoFullName --watch"
    }
    else {
        Write-Host "Next command: git status --short"
    }
    exit 0
}
catch {
    Write-Host ""
    Write-Host "SECTION 14 AUTOMATION FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
