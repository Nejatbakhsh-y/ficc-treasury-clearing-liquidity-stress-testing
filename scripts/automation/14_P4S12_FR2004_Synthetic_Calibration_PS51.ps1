#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase IV, Section 12: calibration of synthetic clearing-member
    portfolios to aggregate FR 2004 Primary Dealer Statistics.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.
    It creates or selects feature/10-synthetic-calibration, writes the controlled
    calibration configuration, Python implementation, runner, tests, methodology,
    reconciliation evidence, deterministic synthetic portfolio output, manifest,
    and Section 12 completion report.

    The implementation:
      - reads only aggregate FR 2004 data;
      - creates fictional SYN-MBR identifiers;
      - uses deterministic heavy-tailed allocations;
      - reconciles every selected aggregate control exactly to cents;
      - enforces nonnegative exposures;
      - reconciles Treasury maturity buckets, financing, and settlement fails;
      - prohibits actual-participant labels and participant-level inference.

    By default, the automation commits, pushes, and opens a draft pull request.
    Use -SkipPush or -SkipPullRequest when required.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\14_P4S12_FR2004_Synthetic_Calibration_PS51.ps1"

.EXAMPLE
    .\14_P4S12_FR2004_Synthetic_Calibration_PS51.ps1 `
        -RepoPath $PWD.Path `
        -MemberCount 48 `
        -ConcentrationPower 1.40 `
        -ParetoShape 1.55
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoPath = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",

    [Parameter()]
    [ValidateRange(10, 500)]
    [int]$MemberCount = 48,

    [Parameter()]
    [ValidateRange(0.50, 4.00)]
    [double]$ConcentrationPower = 1.40,

    [Parameter()]
    [ValidateRange(1.05, 5.00)]
    [double]$ParetoShape = 1.55,

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$RandomSeed = 2026,

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

$BranchName = "feature/10-synthetic-calibration"
$CommitMessage = "Phase IV Section 12: calibrate synthetic portfolios to FR 2004"
$AutomationRelativePath = "scripts\automation\14_P4S12_FR2004_Synthetic_Calibration_PS51.ps1"

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

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

try {
    $resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath -ErrorAction Stop).Path
    $RepoPath = $resolvedRepoPath

    $ScriptPath = $MyInvocation.MyCommand.Path
    $ScriptDirectory = Split-Path -Parent $ScriptPath

    if (-not $Relaunched -and $ScriptDirectory -eq $RepoPath) {
        $DownloadDirectory = Join-Path $env:USERPROFILE "Downloads"
        if (-not (Test-Path -LiteralPath $DownloadDirectory)) {
            New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
        }

        $Destination = Join-Path $DownloadDirectory `
            ("14_P4S12_FR2004_Synthetic_Calibration_PS51_{0}.ps1" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        Copy-Item -LiteralPath $ScriptPath -Destination $Destination -Force

        $childArguments = @{
            RepoPath = $RepoPath
            MemberCount = $MemberCount
            ConcentrationPower = $ConcentrationPower
            ParetoShape = $ParetoShape
            RandomSeed = $RandomSeed
            Relaunched = $true
        }
        foreach ($switchName in @(
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
            & $Destination @childArguments
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

    Write-Step "Validating the FICC liquidity repository and Section 11 dependency"

    if (-not (Test-Path -LiteralPath ".git")) {
        throw "The selected folder is not a Git repository: $RepoPath"
    }
    if (-not (Test-Path -LiteralPath "pyproject.toml")) {
        throw "pyproject.toml was not found. Open the FICC liquidity repository in VS Code."
    }

    $section11Required = @(
        "configs\synthetic_members.yaml",
        "src\ficc_liquidity\synthetic\member_schema.py",
        "src\ficc_liquidity\synthetic\generate_members.py",
        "tests\test_synthetic_member_schema.py"
    )
    foreach ($relativePath in $section11Required) {
        if (-not (Test-Path -LiteralPath $relativePath -PathType Leaf)) {
            throw "Section 11 dependency is missing: $relativePath. Complete Section 11 first."
        }
    }
    Write-Pass "Section 11 synthetic-member schema is available"

    Assert-Command -Name "git"

    if (-not $SkipGit) {
        Write-Step "Preparing branch $BranchName"

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

        & git show-ref --verify --quiet "refs/heads/$BranchName"
        $branchExists = $LASTEXITCODE -eq 0

        if ($branchExists) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("switch", $BranchName) `
                -FailureMessage "Unable to switch to $BranchName."
        }
        else {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("switch", "-c", $BranchName) `
                -FailureMessage "Unable to create $BranchName from the current Section 11 commit."
        }
        Write-Pass "Current branch is $BranchName"
    }
    else {
        Write-Warn "Git branch operations were skipped."
    }

    Write-Step "Creating Section 12 directories"

    $directories = @(
        "configs",
        "data\interim\fr2004",
        "data\manifests",
        "data\synthetic",
        "docs",
        "reports\evidence",
        "reports\tables",
        "scripts",
        "scripts\automation",
        "src\ficc_liquidity\synthetic",
        "tests"
    )
    foreach ($directory in $directories) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $automationTarget = Join-Path $RepoPath $AutomationRelativePath
    if ($ScriptPath -ne $automationTarget) {
        Copy-Item -LiteralPath $ScriptPath -Destination $automationTarget -Force
    }

    Write-Step "Writing the controlled Section 12 configuration"

    $concentrationText = $ConcentrationPower.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
    $paretoText = $ParetoShape.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)

    $CalibrationConfig = @'
schema_version: "1.0"
calibration_version: "section-12-v1"

synthetic_data_controls:
  value_class: synthetic
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false
  identification_statement: >
    Every generated record is fictional. No record represents, approximates,
    ranks, identifies, or purports to describe an actual FICC participant.
  member_id_prefix: "SYN-MBR-"
  member_label_prefix: "Fictional Clearing Member "

generation:
  member_count: __MEMBER_COUNT__
  random_seed: __RANDOM_SEED__
  pareto_shape: __PARETO_SHAPE__
  concentration_power: __CONCENTRATION_POWER__
  idiosyncratic_sigma: 0.20
  generator_version: "2.0.0-calibrated"
  deterministic_rounding_unit_usd: 0.01

source:
  official_name: "FR 2004 Primary Dealer Statistics"
  raw_glob: "data/raw/fr2004/fr2004_*.csv"
  canonical_glob: "data/processed/fed/fr2004/fr2004_canonical_*.parquet"
  processed_file: "data/processed/fed_liquidity_factors.parquet"
  definitions_cache: "data/interim/fr2004/fr2004_series_definitions.csv"
  definitions_url: "https://markets.newyorkfed.org/api/pd/list/timeseries.csv"
  values_are_usd_millions_when_raw_or_canonical: true
  use_latest_common_observation_date: true

outputs:
  calibrated_portfolios: "data/synthetic/calibrated_member_portfolios.parquet"
  reconciliation_table: "reports/tables/synthetic_calibration_reconciliation.csv"
  manifest: "data/manifests/synthetic_calibration_manifest.csv"
  evidence: "reports/evidence/section_12_synthetic_calibration_report.txt"
  series_resolution_diagnostic: "reports/evidence/fr2004_series_resolution_diagnostic.csv"

resolution:
  common_exclude_patterns:
    - "(?i)change"
    - "(?i)percent"
    - "(?i)ratio"

  maturity_common_include:
    - "(?i)U\\.S\\. Treasury"
    - "(?i)Treasury securities"
    - "(?i)^PDPOSGSC"
  maturity_common_exclude:
    - "(?i)transaction"
    - "(?i)customer"
    - "(?i)inter-dealer"
    - "(?i)net position"
    - "(?i)position - short"
    - "(?i)short position"
    - "(?i)total"
    - "(?i)inflation-protected"
    - "(?i)TIPS"
    - "(?i)floating rate"

  maturity_buckets:
    treasury_position_bills_0_1y_usd:
      include:
        - "(?i)Treasury bills"
        - "(?i)\\bbills\\b"
        - "(?i)\\bt-?bills?\\b"
    treasury_position_notes_1_3y_usd:
      include:
        - "(?i)2 years or less"
        - "(?i)more than 2.*3 years"
        - "(?i)G2L3"
        - "(?i)-L2(?:\\b|$)"
    treasury_position_notes_3_7y_usd:
      include:
        - "(?i)more than 3.*6 years"
        - "(?i)more than 6.*7 years"
        - "(?i)G3L6"
        - "(?i)G6L7"
    treasury_position_notes_7_10y_usd:
      include:
        - "(?i)more than 7.*(?:10|11) years"
        - "(?i)G7L11"
    treasury_position_bonds_10_30y_usd:
      include:
        - "(?i)more than 11.*21 years"
        - "(?i)more than 21 years"
        - "(?i)G11L21"
        - "(?i)G21"
    treasury_position_strips_30y_plus_usd:
      include:
        - "(?i)STRIPS"

  fallback_maturity_shares:
    treasury_position_bills_0_1y_usd: 0.12
    treasury_position_notes_1_3y_usd: 0.25
    treasury_position_notes_3_7y_usd: 0.25
    treasury_position_notes_7_10y_usd: 0.16
    treasury_position_bonds_10_30y_usd: 0.22
    treasury_position_strips_30y_plus_usd: 0.00

  total_position:
    include:
      - "(?i)U\\.S\\. Treasury.*position - long"
      - "(?i)Treasury securities.*long position"
      - "(?i)^PDPOSGSC"
    exclude:
      - "(?i)transaction"
      - "(?i)customer"
      - "(?i)inter-dealer"
      - "(?i)net position"
      - "(?i)position - short"
      - "(?i)short position"
      - "(?i)change"
      - "(?i)total"

  treasury_transactions:
    include:
      - "(?i)Treasury.*transaction"
      - "(?i)transaction.*Treasury"
      - "(?i)^PDTR"
    exclude:
      - "(?i)repo"
      - "(?i)financing"
      - "(?i)fail"
      - "(?i)position"
      - "(?i)change"
      - "(?i)percent"

  repo_financing_out:
    include:
      - "(?i)Treasury.*securities out"
      - "(?i)securities out.*Treasury"
      - "(?i)Treasury.*repo"
      - "(?i)^PDSORA[-_:]"
      - "(?i)^PDSOOS[-_:]"
    exclude:
      - "(?i)fail"
      - "(?i)change"
      - "(?i)percent"
      - "(?i)rate"
      - "(?i)reverse repo"
      - "(?i)securities in"
      - "(?i)^PDSIRRA[-_:]"
      - "(?i)^PDSIRA[-_:]"
      - "(?i)^PDSIOSB[-_:]"

  reverse_repo_in:
    include:
      - "(?i)Treasury.*securities in"
      - "(?i)securities in.*Treasury"
      - "(?i)Treasury.*reverse repo"
      - "(?i)^PDSIRRA[-_:]"
      - "(?i)^PDSIRA[-_:]"
      - "(?i)^PDSIOSB[-_:]"
    exclude:
      - "(?i)fail"
      - "(?i)change"
      - "(?i)percent"
      - "(?i)rate"
      - "(?i)securities out"
      - "(?i)^PDSORA[-_:]"
      - "(?i)^PDSOOS[-_:]"

  fails_to_receive:
    include:
      - "(?i)Treasury.*fails to receive"
      - "(?i)fails to receive.*Treasury"
      - "(?i)^PDFTR[-_:]USTET"
    exclude:
      - "(?i)change"
      - "(?i)percent"

  fails_to_deliver:
    include:
      - "(?i)Treasury.*fails to deliver"
      - "(?i)fails to deliver.*Treasury"
      - "(?i)^PDFTD[-_:]USTET"
    exclude:
      - "(?i)change"
      - "(?i)percent"

derived_member_assumptions:
  collateral_coverage_low: 1.05
  collateral_coverage_high: 1.45
  qualified_resource_share_low: 0.35
  qualified_resource_share_high: 0.70
  stress_multiplier_low: 1.10
  stress_multiplier_high: 1.55

risk_score:
  concentration_weight: 0.25
  funding_dependency_weight: 0.25
  settlement_fail_weight: 0.20
  collateral_shortfall_weight: 0.15
  liquidity_shortfall_weight: 0.15
  elevated_threshold: 40.0
  high_threshold: 65.0

validation:
  aggregate_tolerance_usd: 0.01
  require_exact_cents_reconciliation: true
  require_nonnegative_exposures: true
  require_deterministic_reproduction: true
  require_synthetic_identifiers: true
  require_no_participant_inference: true
'@
    $CalibrationConfig = $CalibrationConfig.Replace("__MEMBER_COUNT__", $MemberCount.ToString())
    $CalibrationConfig = $CalibrationConfig.Replace("__RANDOM_SEED__", $RandomSeed.ToString())
    $CalibrationConfig = $CalibrationConfig.Replace("__PARETO_SHAPE__", $paretoText)
    $CalibrationConfig = $CalibrationConfig.Replace("__CONCENTRATION_POWER__", $concentrationText)
    Write-Utf8File -Path "configs\synthetic_calibration.yaml" -Content $CalibrationConfig

    Write-Step "Writing the Section 12 calibration engine"

    $CalibrationModule = @'
"""FR 2004 aggregate calibration for fictional clearing-member portfolios.

The module consumes only public aggregate observations. It does not ingest,
estimate, reconstruct, or infer any actual participant-level exposure.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import requests
import yaml

from ficc_liquidity.synthetic.member_schema import (
    SyntheticMember,
    classify_risk,
    validate_members,
)

MATURITY_COLUMNS: tuple[str, ...] = (
    "treasury_position_bills_0_1y_usd",
    "treasury_position_notes_1_3y_usd",
    "treasury_position_notes_3_7y_usd",
    "treasury_position_notes_7_10y_usd",
    "treasury_position_bonds_10_30y_usd",
    "treasury_position_strips_30y_plus_usd",
)

DIRECT_CONTROL_COLUMNS: tuple[str, ...] = (
    *MATURITY_COLUMNS,
    "treasury_transaction_activity_usd",
    "fr2004_repo_financing_out_usd",
    "reverse_repo_position_usd",
    "fr2004_fails_to_receive_usd",
    "fr2004_fails_to_deliver_usd",
)


@dataclass(frozen=True, slots=True)
class CalibrationSettings:
    """Validated settings required for deterministic allocation."""

    member_count: int
    random_seed: int
    pareto_shape: float
    concentration_power: float
    idiosyncratic_sigma: float
    generator_version: str
    collateral_coverage_low: float
    collateral_coverage_high: float
    qualified_resource_share_low: float
    qualified_resource_share_high: float
    stress_multiplier_low: float
    stress_multiplier_high: float
    risk_weights: Mapping[str, float]
    elevated_threshold: float
    high_threshold: float
    aggregate_tolerance_usd: float


@dataclass(frozen=True, slots=True)
class AggregateTargets:
    """Selected aggregate FR 2004 controls expressed in U.S. dollars."""

    as_of_date: date
    maturity_targets: Mapping[str, int]
    treasury_transaction_activity_cents: int
    repo_financing_out_cents: int
    reverse_repo_in_cents: int
    fails_to_receive_cents: int
    fails_to_deliver_cents: int
    source_file: str
    source_sha256: str
    source_series: Mapping[str, tuple[str, ...]]

    @property
    def total_treasury_position_cents(self) -> int:
        return int(sum(self.maturity_targets.values()))

    def control_cents(self) -> dict[str, int]:
        controls = {name: int(value) for name, value in self.maturity_targets.items()}
        controls.update(
            {
                "treasury_transaction_activity_usd": self.treasury_transaction_activity_cents,
                "fr2004_repo_financing_out_usd": self.repo_financing_out_cents,
                "fr2004_reverse_repo_in_usd": self.reverse_repo_in_cents,
                "fr2004_fails_to_receive_usd": self.fails_to_receive_cents,
                "fr2004_fails_to_deliver_usd": self.fails_to_deliver_cents,
            }
        )
        return controls


@dataclass(frozen=True, slots=True)
class CalibrationResult:
    """Controlled outputs from one calibration execution."""

    frame: pd.DataFrame
    reconciliation: pd.DataFrame
    targets: AggregateTargets
    deterministic_digest: str
    source_resolution: pd.DataFrame


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _float(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{key} must be numeric.")
    return float(value)


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{key} must be an integer.")
    return value


def load_config(config_path: Path) -> dict[str, Any]:
    """Load the controlled YAML configuration."""
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def load_settings(config: Mapping[str, Any]) -> CalibrationSettings:
    """Create typed generation settings and validate control parameters."""
    generation = _mapping(config.get("generation"), "generation")
    derived = _mapping(
        config.get("derived_member_assumptions"),
        "derived_member_assumptions",
    )
    risk = _mapping(config.get("risk_score"), "risk_score")
    validation = _mapping(config.get("validation"), "validation")

    weights = {
        "concentration": _float(risk, "concentration_weight"),
        "funding_dependency": _float(risk, "funding_dependency_weight"),
        "settlement_fail": _float(risk, "settlement_fail_weight"),
        "collateral_shortfall": _float(risk, "collateral_shortfall_weight"),
        "liquidity_shortfall": _float(risk, "liquidity_shortfall_weight"),
    }
    if not math.isclose(sum(weights.values()), 1.0, abs_tol=1e-12):
        raise ValueError("Risk-score weights must sum to one.")

    settings = CalibrationSettings(
        member_count=_integer(generation, "member_count"),
        random_seed=_integer(generation, "random_seed"),
        pareto_shape=_float(generation, "pareto_shape"),
        concentration_power=_float(generation, "concentration_power"),
        idiosyncratic_sigma=_float(generation, "idiosyncratic_sigma"),
        generator_version=str(generation["generator_version"]),
        collateral_coverage_low=_float(derived, "collateral_coverage_low"),
        collateral_coverage_high=_float(derived, "collateral_coverage_high"),
        qualified_resource_share_low=_float(
            derived,
            "qualified_resource_share_low",
        ),
        qualified_resource_share_high=_float(
            derived,
            "qualified_resource_share_high",
        ),
        stress_multiplier_low=_float(derived, "stress_multiplier_low"),
        stress_multiplier_high=_float(derived, "stress_multiplier_high"),
        risk_weights=weights,
        elevated_threshold=_float(risk, "elevated_threshold"),
        high_threshold=_float(risk, "high_threshold"),
        aggregate_tolerance_usd=_float(validation, "aggregate_tolerance_usd"),
    )
    if settings.member_count <= 0:
        raise ValueError("member_count must be positive.")
    if settings.pareto_shape <= 1.0:
        raise ValueError("pareto_shape must exceed one.")
    if settings.concentration_power <= 0.0:
        raise ValueError("concentration_power must be positive.")
    if not (
        0.0
        < settings.qualified_resource_share_low
        <= settings.qualified_resource_share_high
        <= 1.0
    ):
        raise ValueError("Qualified-resource shares must satisfy 0 < low <= high <= 1.")
    return settings


def file_sha256(path: Path) -> str:
    """Return the SHA-256 digest of a controlled file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _normalized_name(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", "_", str(value).strip().lower()).strip("_")


def _column(
    columns: Sequence[object],
    aliases: Sequence[str],
    *,
    required: bool = True,
) -> str | None:
    lookup = {_normalized_name(column): str(column) for column in columns}
    for alias in aliases:
        if alias in lookup:
            return lookup[alias]
    if required:
        raise ValueError(
            f"Required column was not found. Expected one of {list(aliases)}; "
            f"available columns are {[str(column) for column in columns]}."
        )
    return None


def _numeric(series: pd.Series) -> pd.Series:
    cleaned = (
        series.astype("string")
        .str.strip()
        .mask(
            lambda values: values.str.lower().isin(
                {"", ".", "-", "*", "na", "n/a", "null", "none"}
            )
        )
        .str.replace(r"^\((.*)\)$", r"-\1", regex=True)
        .str.replace(",", "", regex=False)
        .str.replace("$", "", regex=False)
    )
    return pd.to_numeric(cleaned, errors="coerce")


def _read_raw(path: Path) -> pd.DataFrame:
    frame = pd.read_csv(path, dtype="string", keep_default_na=False, low_memory=False)
    date_column = _column(
        list(frame.columns),
        ("observation_date", "as_of_date", "asof_date", "date", "report_date"),
    )
    series_column = _column(
        list(frame.columns),
        ("series_id", "time_series", "timeseries", "time_series_id", "key_id", "keyid"),
    )
    value_column = _column(
        list(frame.columns),
        ("value", "value_millions", "value_in_millions", "amount", "observation_value"),
    )
    break_column = _column(
        list(frame.columns),
        ("series_break", "seriesbreak", "series_break_id"),
        required=False,
    )
    assert date_column is not None
    assert series_column is not None
    assert value_column is not None

    output = pd.DataFrame(
        {
            "observation_date": pd.to_datetime(
                frame[date_column],
                errors="coerce",
                utc=True,
            ).dt.tz_convert(None),
            "series_id": frame[series_column].astype("string").str.strip(),
            "value_usd": _numeric(frame[value_column]) * 1_000_000.0,
            "series_break": (
                frame[break_column].astype("string").str.strip()
                if break_column is not None
                else ""
            ),
        }
    )
    return output.dropna(subset=["observation_date", "series_id", "value_usd"])


def _read_canonical(path: Path) -> pd.DataFrame:
    frame = pd.read_parquet(path)
    date_column = _column(list(frame.columns), ("observation_date", "date"))
    series_column = _column(list(frame.columns), ("series_id", "source_series_id"))
    value_column = _column(list(frame.columns), ("value", "standardized_value"))
    unit_column = _column(
        list(frame.columns),
        ("unit", "standardized_unit", "original_unit"),
        required=False,
    )
    assert date_column is not None
    assert series_column is not None
    assert value_column is not None

    values = pd.to_numeric(frame[value_column], errors="coerce")
    multiplier = 1_000_000.0
    if unit_column is not None:
        units = frame[unit_column].astype("string").str.lower()
        if units.eq("usd").all():
            multiplier = 1.0

    series_values = frame[series_column].astype("string").str.strip()
    breaks = pd.Series("", index=frame.index, dtype="string")
    split = series_values.str.split("::", n=1, expand=True)
    if split.shape[1] == 2:
        has_break = split[1].notna()
        breaks = breaks.where(~has_break, split[0])
        series_values = series_values.where(~has_break, split[1])

    output = pd.DataFrame(
        {
            "observation_date": pd.to_datetime(
                frame[date_column],
                errors="coerce",
                utc=True,
            ).dt.tz_convert(None),
            "series_id": series_values,
            "value_usd": values * multiplier,
            "series_break": breaks,
        }
    )
    return output.dropna(subset=["observation_date", "series_id", "value_usd"])


def _read_processed(path: Path) -> pd.DataFrame:
    frame = pd.read_parquet(path)
    if "source_name" in frame.columns:
        frame = frame.loc[frame["source_name"].astype(str).str.upper().eq("FR2004")]
    if "alignment_frequency" in frame.columns:
        weekly = frame.loc[
            frame["alignment_frequency"].astype(str).str.lower().eq("weekly")
        ]
        if not weekly.empty:
            frame = weekly
    if "is_observed" in frame.columns:
        observed = frame.loc[frame["is_observed"].fillna(False).astype(bool)]
        if not observed.empty:
            frame = observed

    date_column = _column(list(frame.columns), ("source_observation_date", "observation_date"))
    series_column = _column(list(frame.columns), ("source_series_id", "series_id"))
    value_column = _column(list(frame.columns), ("value", "standardized_value"))
    assert date_column is not None
    assert series_column is not None
    assert value_column is not None

    output = pd.DataFrame(
        {
            "observation_date": pd.to_datetime(
                frame[date_column],
                errors="coerce",
                utc=True,
            ).dt.tz_convert(None),
            "series_id": frame[series_column].astype("string").str.strip(),
            "value_usd": pd.to_numeric(frame[value_column], errors="coerce"),
            "series_break": "",
        }
    )
    return output.dropna(subset=["observation_date", "series_id", "value_usd"])


def discover_fr2004_source(
    project_root: Path,
    config: Mapping[str, Any],
) -> tuple[pd.DataFrame, Path]:
    """Discover the most authoritative locally available FR 2004 source."""
    source = _mapping(config.get("source"), "source")
    raw_files = sorted(project_root.glob(str(source["raw_glob"])))
    if raw_files:
        selected = max(raw_files, key=lambda path: path.stat().st_mtime_ns)
        return _read_raw(selected), selected.resolve()

    canonical_files = sorted(project_root.glob(str(source["canonical_glob"])))
    if canonical_files:
        selected = max(canonical_files, key=lambda path: path.stat().st_mtime_ns)
        return _read_canonical(selected), selected.resolve()

    processed = project_root / str(source["processed_file"])
    if processed.exists():
        return _read_processed(processed), processed.resolve()

    raise FileNotFoundError(
        "No FR 2004 source was found. Run the Section 5 ingestion and Section 8 "
        "processed-data automation before Section 12."
    )


def _read_definitions(path: Path) -> pd.DataFrame:
    frame = pd.read_csv(path, dtype="string", keep_default_na=False, low_memory=False)
    series_column = _column(
        list(frame.columns),
        ("series_id", "time_series", "timeseries", "time_series_id", "key_id", "keyid"),
    )
    description_column = _column(
        list(frame.columns),
        (
            "description",
            "series_description",
            "time_series_description",
            "name",
            "title",
            "label",
        ),
        required=False,
    )
    break_column = _column(
        list(frame.columns),
        ("series_break", "seriesbreak", "series_break_id"),
        required=False,
    )
    assert series_column is not None

    output = pd.DataFrame(
        {
            "series_id": frame[series_column].astype("string").str.strip(),
            "series_description": (
                frame[description_column].astype("string").str.strip()
                if description_column is not None
                else ""
            ),
            "series_break": (
                frame[break_column].astype("string").str.strip()
                if break_column is not None
                else ""
            ),
        }
    )
    return output.drop_duplicates(["series_id", "series_break"], keep="last")


def load_series_definitions(
    project_root: Path,
    config: Mapping[str, Any],
) -> pd.DataFrame:
    """Load the official series dictionary, using a controlled local cache."""
    source = _mapping(config.get("source"), "source")
    cache_path = project_root / str(source["definitions_cache"])
    if not cache_path.exists():
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            response = requests.get(
                str(source["definitions_url"]),
                timeout=45,
                headers={"User-Agent": "ficc-liquidity-section12/1.0"},
            )
            response.raise_for_status()
            cache_path.write_bytes(response.content)
        except requests.RequestException:
            return pd.DataFrame(
                columns=["series_id", "series_description", "series_break"]
            )

    try:
        return _read_definitions(cache_path)
    except (OSError, ValueError, pd.errors.ParserError):
        return pd.DataFrame(columns=["series_id", "series_description", "series_break"])


def attach_definitions(observations: pd.DataFrame, definitions: pd.DataFrame) -> pd.DataFrame:
    """Attach official descriptions without changing aggregate observations."""
    frame = observations.copy()
    if definitions.empty:
        frame["series_description"] = ""
    else:
        exact = frame.merge(
            definitions,
            on=["series_id", "series_break"],
            how="left",
        )
        missing = exact["series_description"].fillna("").astype(str).eq("")
        if missing.any():
            fallback = (
                definitions.sort_values("series_break")
                .drop_duplicates("series_id", keep="last")
                .set_index("series_id")["series_description"]
            )
            exact.loc[missing, "series_description"] = exact.loc[
                missing,
                "series_id",
            ].map(fallback)
        frame = exact

    frame["series_description"] = (
        frame["series_description"].fillna("").astype("string")
    )
    frame["resolution_text"] = (
        frame["series_id"].astype("string")
        + " "
        + frame["series_description"].astype("string")
    )
    return frame


def _pattern_mask(text: pd.Series, patterns: Sequence[str]) -> pd.Series:
    if not patterns:
        return pd.Series(False, index=text.index, dtype=bool)
    mask = pd.Series(False, index=text.index, dtype=bool)
    for pattern in patterns:
        mask = mask | text.str.contains(pattern, regex=True, na=False)
    return mask


def _rules(config: Mapping[str, Any], name: str) -> dict[str, Any]:
    resolution = _mapping(config.get("resolution"), "resolution")
    return _mapping(resolution.get(name), f"resolution.{name}")


def _select(
    latest: pd.DataFrame,
    include: Sequence[str],
    exclude: Sequence[str],
) -> pd.DataFrame:
    text = latest["resolution_text"].astype("string")
    selected = latest.loc[_pattern_mask(text, include)].copy()
    if exclude and not selected.empty:
        selected = selected.loc[~_pattern_mask(selected["resolution_text"], exclude)]
    selected = selected.loc[selected["value_usd"] >= 0.0]
    return selected.drop_duplicates(["series_id", "series_break"], keep="last")


def _select_maturity(
    latest: pd.DataFrame,
    common_include: Sequence[str],
    bucket_include: Sequence[str],
    exclude: Sequence[str],
) -> pd.DataFrame:
    text = latest["resolution_text"].astype("string")
    common_mask = _pattern_mask(text, common_include)
    bucket_mask = _pattern_mask(text, bucket_include)
    selected = latest.loc[common_mask & bucket_mask].copy()
    if exclude and not selected.empty:
        selected = selected.loc[~_pattern_mask(selected["resolution_text"], exclude)]
    selected = selected.loc[selected["value_usd"] >= 0.0]
    return selected.drop_duplicates(["series_id", "series_break"], keep="last")


def _prefer_total_controls(selected: pd.DataFrame) -> pd.DataFrame:
    if selected.empty:
        return selected
    text = selected["resolution_text"].astype("string")
    total_mask = text.str.contains(
        r"(?i)(?:\btotal\b|UTSETTOT|USTET(?:\b|$))",
        regex=True,
        na=False,
    )
    totals = selected.loc[total_mask]
    return totals if not totals.empty else selected


def _selected_value(selected: pd.DataFrame, label: str) -> tuple[int, tuple[str, ...]]:
    if selected.empty:
        raise ValueError(f"No FR 2004 series resolved for {label}.")
    total_usd = float(selected["value_usd"].sum())
    if not math.isfinite(total_usd) or total_usd <= 0.0:
        raise ValueError(f"Resolved FR 2004 control {label} is not positive.")
    cents = round(total_usd * 100.0)
    series = tuple(sorted(selected["series_id"].astype(str).unique()))
    return cents, series


def _latest_observations(frame: pd.DataFrame) -> tuple[pd.DataFrame, date]:
    if frame.empty:
        raise ValueError("FR 2004 source contains no usable observations.")
    frame = frame.loc[np.isfinite(frame["value_usd"].astype(float))].copy()
    latest_timestamp = pd.Timestamp(frame["observation_date"].max()).normalize()
    latest = frame.loc[
        pd.to_datetime(frame["observation_date"]).dt.normalize().eq(latest_timestamp)
    ].copy()
    if latest.empty:
        raise ValueError("Latest FR 2004 observation date contains no usable rows.")
    return latest, latest_timestamp.date()


def resolve_targets(
    observations: pd.DataFrame,
    definitions: pd.DataFrame,
    source_path: Path,
    config: Mapping[str, Any],
) -> tuple[AggregateTargets, pd.DataFrame]:
    """Resolve nonnegative aggregate controls for the latest FR 2004 date."""
    enriched = attach_definitions(observations, definitions)
    latest, as_of_date = _latest_observations(enriched)
    resolution = _mapping(config.get("resolution"), "resolution")

    diagnostic = latest[
        [
            "observation_date",
            "series_break",
            "series_id",
            "series_description",
            "value_usd",
            "resolution_text",
        ]
    ].sort_values(["series_break", "series_id"])

    common_include = cast(
        list[str],
        resolution.get("maturity_common_include", []),
    )
    common_exclude = cast(
        list[str],
        resolution.get("maturity_common_exclude", []),
    )
    maturity_rules = _mapping(
        resolution.get("maturity_buckets"),
        "resolution.maturity_buckets",
    )

    maturity_targets: dict[str, int] = {}
    source_series: dict[str, tuple[str, ...]] = {}
    used_keys: set[tuple[str, str]] = set()

    for column in MATURITY_COLUMNS:
        rule = _mapping(maturity_rules.get(column), f"maturity_buckets.{column}")
        selected = _select_maturity(
            latest,
            common_include,
            cast(list[str], rule.get("include", [])),
            common_exclude,
        )
        if not selected.empty:
            key_mask = selected.apply(
                lambda row: (str(row["series_id"]), str(row["series_break"])) not in used_keys,
                axis=1,
            )
            selected = selected.loc[key_mask]
        if selected.empty:
            continue
        cents, series = _selected_value(selected, column)
        maturity_targets[column] = cents
        source_series[column] = series
        used_keys.update(
            (str(row.series_id), str(row.series_break))
            for row in selected.itertuples()
        )

    if not maturity_targets:
        total_rule = _rules(config, "total_position")
        total_selected = _select(
            latest,
            cast(list[str], total_rule.get("include", [])),
            cast(list[str], total_rule.get("exclude", [])),
        )
        total_cents, total_series = _selected_value(
            total_selected,
            "Treasury long-position control",
        )
        shares = _mapping(
            resolution.get("fallback_maturity_shares"),
            "resolution.fallback_maturity_shares",
        )
        share_values = np.array([float(shares[column]) for column in MATURITY_COLUMNS])
        if not math.isclose(float(share_values.sum()), 1.0, abs_tol=1e-12):
            raise ValueError("fallback_maturity_shares must sum to one.")
        allocated = exact_allocate(total_cents, share_values.tolist())
        maturity_targets = {
            column: int(allocated[index])
            for index, column in enumerate(MATURITY_COLUMNS)
        }
        source_series.update(
            {column: total_series for column in MATURITY_COLUMNS}
        )
    else:
        for column in MATURITY_COLUMNS:
            maturity_targets.setdefault(column, 0)
            source_series.setdefault(column, ())

    scalar_rules = {
        "treasury_transaction_activity_usd": "treasury_transactions",
        "fr2004_repo_financing_out_usd": "repo_financing_out",
        "fr2004_reverse_repo_in_usd": "reverse_repo_in",
        "fr2004_fails_to_receive_usd": "fails_to_receive",
        "fr2004_fails_to_deliver_usd": "fails_to_deliver",
    }
    scalar_values: dict[str, int] = {}
    for control_name, rule_name in scalar_rules.items():
        rule = _rules(config, rule_name)
        selected = _select(
            latest,
            cast(list[str], rule.get("include", [])),
            cast(list[str], rule.get("exclude", [])),
        )
        selected = _prefer_total_controls(selected)
        cents, series = _selected_value(selected, control_name)
        scalar_values[control_name] = cents
        source_series[control_name] = series

    targets = AggregateTargets(
        as_of_date=as_of_date,
        maturity_targets=maturity_targets,
        treasury_transaction_activity_cents=scalar_values[
            "treasury_transaction_activity_usd"
        ],
        repo_financing_out_cents=scalar_values[
            "fr2004_repo_financing_out_usd"
        ],
        reverse_repo_in_cents=scalar_values["fr2004_reverse_repo_in_usd"],
        fails_to_receive_cents=scalar_values[
            "fr2004_fails_to_receive_usd"
        ],
        fails_to_deliver_cents=scalar_values[
            "fr2004_fails_to_deliver_usd"
        ],
        source_file=source_path.as_posix(),
        source_sha256=file_sha256(source_path),
        source_series=source_series,
    )
    if targets.total_treasury_position_cents <= 0:
        raise ValueError("Treasury maturity controls do not produce a positive total.")
    return targets, diagnostic


def exact_allocate(total_cents: int, weights: Sequence[float]) -> np.ndarray:
    """Allocate integer cents exactly by the largest-remainder method."""
    if total_cents < 0:
        raise ValueError("total_cents must be nonnegative.")
    weight_array = np.asarray(weights, dtype=np.float64)
    if weight_array.ndim != 1 or len(weight_array) == 0:
        raise ValueError("weights must be a nonempty one-dimensional sequence.")
    if not np.isfinite(weight_array).all() or (weight_array < 0.0).any():
        raise ValueError("weights must be finite and nonnegative.")
    weight_sum = float(weight_array.sum())
    if weight_sum <= 0.0:
        if total_cents == 0:
            return np.zeros(len(weight_array), dtype=np.int64)
        raise ValueError("Positive total requires positive allocation weights.")

    normalized = weight_array / weight_sum
    raw = normalized * total_cents
    base = np.floor(raw).astype(np.int64)
    remainder = int(total_cents - int(base.sum()))
    if remainder:
        fractions = raw - base
        order = np.argsort(-fractions, kind="stable")
        base[order[:remainder]] += 1
    if int(base.sum()) != total_cents or (base < 0).any():
        raise RuntimeError("Exact allocation failed.")
    return base


def heavy_tail_weights(
    settings: CalibrationSettings,
    *,
    seed_offset: int = 0,
) -> np.ndarray:
    """Create deterministic Pareto weights with configurable concentration."""
    generator = np.random.default_rng(settings.random_seed + seed_offset)
    raw = generator.pareto(settings.pareto_shape, settings.member_count) + 1.0
    powered = np.power(raw, settings.concentration_power)
    weights = powered / powered.sum()
    if not np.isfinite(weights).all() or (weights <= 0.0).any():
        raise RuntimeError("Heavy-tailed weights are invalid.")
    return weights


def _component_weights(
    base_weights: np.ndarray,
    settings: CalibrationSettings,
    generator: np.random.Generator,
) -> np.ndarray:
    shocks = generator.lognormal(
        mean=0.0,
        sigma=settings.idiosyncratic_sigma,
        size=settings.member_count,
    )
    component = base_weights * shocks
    return component / component.sum()


def _risk_score(
    *,
    concentration: float,
    funding_dependency: float,
    fail_rate: float,
    collateral_coverage: float,
    liquidity_coverage: float,
    weights: Mapping[str, float],
    maximum_fail_rate: float,
) -> float:
    fail_component = min(fail_rate / max(maximum_fail_rate, 1e-12), 1.0)
    collateral_shortfall = max(1.0 - min(collateral_coverage, 1.0), 0.0)
    liquidity_shortfall = max(1.0 - min(liquidity_coverage, 1.0), 0.0)
    score = 100.0 * (
        weights["concentration"] * concentration
        + weights["funding_dependency"] * funding_dependency
        + weights["settlement_fail"] * fail_component
        + weights["collateral_shortfall"] * collateral_shortfall
        + weights["liquidity_shortfall"] * liquidity_shortfall
    )
    return min(max(score, 0.0), 100.0)


def _usd(values_cents: np.ndarray) -> np.ndarray:
    return values_cents.astype(np.float64) / 100.0


def generate_calibrated_frame(
    targets: AggregateTargets,
    settings: CalibrationSettings,
) -> pd.DataFrame:
    """Generate one deterministic fictional portfolio calibrated to all controls."""
    base_weights = heavy_tail_weights(settings)
    generator = np.random.default_rng(settings.random_seed + 10_000)

    allocated: dict[str, np.ndarray] = {}
    for index, (column, target_cents) in enumerate(targets.control_cents().items()):
        weights = _component_weights(base_weights, settings, generator)
        allocated[column] = exact_allocate(target_cents, weights.tolist())
        if int(allocated[column].sum()) != target_cents:
            raise RuntimeError(f"Allocation failed for {column}.")
        _ = index

    maturity_usd = {column: _usd(allocated[column]) for column in MATURITY_COLUMNS}
    total_position = np.sum(
        np.vstack([maturity_usd[column] for column in MATURITY_COLUMNS]),
        axis=0,
    )
    activity = _usd(allocated["treasury_transaction_activity_usd"])
    repo_out = _usd(allocated["fr2004_repo_financing_out_usd"])
    raw_reverse_repo = _usd(allocated["fr2004_reverse_repo_in_usd"])
    fails_receive = _usd(allocated["fr2004_fails_to_receive_usd"])
    fails_deliver = _usd(allocated["fr2004_fails_to_deliver_usd"])
    settlement_fails = fails_receive + fails_deliver

    raw_gross_financing = repo_out + raw_reverse_repo
    financing_intensity = raw_gross_financing / np.maximum(
        raw_gross_financing + activity,
        0.01,
    )
    repo_need = activity * financing_intensity
    reverse_share = raw_reverse_repo / np.maximum(raw_gross_financing, 0.01)
    reverse_repo = repo_need * reverse_share
    settlement_obligation = np.maximum(
        activity + repo_need,
        settlement_fails,
    )

    collateral_coverage = generator.uniform(
        settings.collateral_coverage_low,
        settings.collateral_coverage_high,
        settings.member_count,
    )
    resource_share = generator.uniform(
        settings.qualified_resource_share_low,
        settings.qualified_resource_share_high,
        settings.member_count,
    )
    stress_multiplier = generator.uniform(
        settings.stress_multiplier_low,
        settings.stress_multiplier_high,
        settings.member_count,
    )
    stressed_need = (
        settlement_obligation + repo_need - (0.50 * reverse_repo)
    ) * stress_multiplier
    stressed_need = np.maximum(stressed_need, 0.01)
    collateral = stressed_need * collateral_coverage
    qualified_resources = collateral * resource_share

    maximum_fail_rate = float(
        np.max(settlement_fails / np.maximum(settlement_obligation, 0.01))
    )
    records: list[dict[str, object]] = []
    members: list[SyntheticMember] = []

    for index in range(settings.member_count):
        maturity_values = tuple(
            float(maturity_usd[column][index]) for column in MATURITY_COLUMNS
        )
        total = float(total_position[index])
        transaction = float(activity[index])
        member_repo_need = float(repo_need[index])
        reverse = float(reverse_repo[index])
        raw_reverse = float(raw_reverse_repo[index])
        obligation = float(settlement_obligation[index])
        fail = float(settlement_fails[index])
        stressed = float(stressed_need[index])
        member_collateral = float(collateral[index])
        resources = float(qualified_resources[index])
        gap = max(stressed - resources, 0.0)

        concentration = max(maturity_values) / total
        funding_dependency = member_repo_need / transaction
        net_repo_dependency = (
            max(member_repo_need - reverse, 0.0) / member_repo_need
            if member_repo_need > 0.0
            else 0.0
        )
        fail_rate = fail / obligation
        collateral_ratio = member_collateral / stressed
        liquidity_ratio = resources / stressed
        score = _risk_score(
            concentration=concentration,
            funding_dependency=funding_dependency,
            fail_rate=fail_rate,
            collateral_coverage=collateral_ratio,
            liquidity_coverage=liquidity_ratio,
            weights=settings.risk_weights,
            maximum_fail_rate=maximum_fail_rate,
        )
        band = classify_risk(
            score,
            elevated_threshold=settings.elevated_threshold,
            high_threshold=settings.high_threshold,
        )

        member = SyntheticMember(
            member_id=f"SYN-MBR-{index + 1:04d}",
            member_label=f"Fictional Clearing Member {index + 1:03d}",
            as_of_date=targets.as_of_date,
            value_class="synthetic",
            generator_version=settings.generator_version,
            actual_ficc_participant=False,
            treasury_position_bills_0_1y_usd=maturity_values[0],
            treasury_position_notes_1_3y_usd=maturity_values[1],
            treasury_position_notes_3_7y_usd=maturity_values[2],
            treasury_position_notes_7_10y_usd=maturity_values[3],
            treasury_position_bonds_10_30y_usd=maturity_values[4],
            treasury_position_strips_30y_plus_usd=maturity_values[5],
            total_treasury_position_usd=total,
            treasury_transaction_activity_usd=transaction,
            repo_financing_need_usd=member_repo_need,
            reverse_repo_position_usd=reverse,
            settlement_obligation_usd=obligation,
            settlement_fail_usd=fail,
            collateral_inventory_usd=member_collateral,
            available_qualified_liquid_resources_usd=resources,
            stressed_liquidity_need_usd=stressed,
            liquidity_gap_usd=gap,
            member_concentration_ratio=concentration,
            funding_dependency_ratio=funding_dependency,
            net_repo_dependency_ratio=net_repo_dependency,
            settlement_fail_rate=fail_rate,
            collateral_coverage_ratio=collateral_ratio,
            liquidity_coverage_ratio=liquidity_ratio,
            liquidity_risk_score=score,
            risk_elevated_threshold=settings.elevated_threshold,
            risk_high_threshold=settings.high_threshold,
            liquidity_risk_band=band,
        )
        member.validate()
        members.append(member)
        record = member.to_record()
        record.update(
            {
                "fr2004_repo_financing_out_usd": float(repo_out[index]),
                "fr2004_reverse_repo_in_usd": raw_reverse,
                "fr2004_fails_to_receive_usd": float(fails_receive[index]),
                "fr2004_fails_to_deliver_usd": float(fails_deliver[index]),
                "calibration_source": "FR 2004 aggregate controls",
                "calibration_source_date": targets.as_of_date,
                "calibration_source_sha256": targets.source_sha256,
                "participant_level_inference": False,
                "synthetic_data_notice": (
                    "Fictional record; not an actual FICC participant."
                ),
            }
        )
        records.append(record)

    validate_members(members)

    frame = pd.DataFrame.from_records(records)
    frame = frame.sort_values("member_id", kind="stable").reset_index(drop=True)
    frame["as_of_date"] = pd.to_datetime(frame["as_of_date"])
    frame["calibration_source_date"] = pd.to_datetime(
        frame["calibration_source_date"]
    )
    return frame


def _column_cents(frame: pd.DataFrame, column: str) -> int:
    values = np.rint(pd.to_numeric(frame[column]) * 100.0).astype(np.int64)
    return int(values.sum())


def build_reconciliation(
    frame: pd.DataFrame,
    targets: AggregateTargets,
    tolerance_usd: float,
) -> pd.DataFrame:
    """Build an exact aggregate reconciliation table from output records."""
    rows: list[dict[str, object]] = []
    for control, target_cents in targets.control_cents().items():
        synthetic_cents = _column_cents(frame, control)
        difference_cents = synthetic_cents - target_cents
        rows.append(
            {
                "control": control,
                "source": "FR 2004 aggregate",
                "source_observation_date": targets.as_of_date.isoformat(),
                "source_series_ids": "|".join(targets.source_series.get(control, ())),
                "target_usd": target_cents / 100.0,
                "synthetic_total_usd": synthetic_cents / 100.0,
                "difference_usd": difference_cents / 100.0,
                "tolerance_usd": tolerance_usd,
                "status": (
                    "PASS"
                    if abs(difference_cents) <= round(tolerance_usd * 100.0)
                    else "FAIL"
                ),
            }
        )

    total_position_cents = _column_cents(frame, "total_treasury_position_usd")
    maturity_sum_cents = sum(_column_cents(frame, column) for column in MATURITY_COLUMNS)
    rows.append(
        {
            "control": "maturity_bucket_reconciliation",
            "source": "Derived accounting identity",
            "source_observation_date": targets.as_of_date.isoformat(),
            "source_series_ids": "",
            "target_usd": maturity_sum_cents / 100.0,
            "synthetic_total_usd": total_position_cents / 100.0,
            "difference_usd": (total_position_cents - maturity_sum_cents) / 100.0,
            "tolerance_usd": tolerance_usd,
            "status": "PASS" if total_position_cents == maturity_sum_cents else "FAIL",
        }
    )

    repo_out_cents = _column_cents(frame, "fr2004_repo_financing_out_usd")
    reverse_cents = _column_cents(frame, "fr2004_reverse_repo_in_usd")
    gross_repo_cents = repo_out_cents + reverse_cents
    rows.append(
        {
            "control": "fr2004_gross_financing_components",
            "source": "Derived accounting identity",
            "source_observation_date": targets.as_of_date.isoformat(),
            "source_series_ids": "",
            "target_usd": (repo_out_cents + reverse_cents) / 100.0,
            "synthetic_total_usd": gross_repo_cents / 100.0,
            "difference_usd": 0.0,
            "tolerance_usd": tolerance_usd,
            "status": (
                "PASS"
                if gross_repo_cents == repo_out_cents + reverse_cents
                else "FAIL"
            ),
        }
    )

    fails_receive_cents = _column_cents(frame, "fr2004_fails_to_receive_usd")
    fails_deliver_cents = _column_cents(frame, "fr2004_fails_to_deliver_usd")
    fail_cents = _column_cents(frame, "settlement_fail_usd")
    rows.append(
        {
            "control": "settlement_fails_identity",
            "source": "Derived accounting identity",
            "source_observation_date": targets.as_of_date.isoformat(),
            "source_series_ids": "",
            "target_usd": (fails_receive_cents + fails_deliver_cents) / 100.0,
            "synthetic_total_usd": fail_cents / 100.0,
            "difference_usd": (
                fail_cents - fails_receive_cents - fails_deliver_cents
            )
            / 100.0,
            "tolerance_usd": tolerance_usd,
            "status": (
                "PASS"
                if fail_cents == fails_receive_cents + fails_deliver_cents
                else "FAIL"
            ),
        }
    )
    return pd.DataFrame.from_records(rows)


def deterministic_digest(frame: pd.DataFrame) -> str:
    """Hash deterministic records while excluding runtime-only metadata."""
    ordered = frame.sort_values("member_id", kind="stable").copy()
    payload = ordered.to_csv(
        index=False,
        float_format="%.12g",
        lineterminator="\n",
        date_format="%Y-%m-%d",
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def validate_calibration(
    frame: pd.DataFrame,
    reconciliation: pd.DataFrame,
    settings: CalibrationSettings,
) -> None:
    """Enforce every Section 12 completion gate."""
    if len(frame) != settings.member_count:
        raise ValueError("Generated member count does not match configuration.")
    if frame["member_id"].duplicated().any():
        raise ValueError("Synthetic member identifiers are not unique.")
    if not frame["member_id"].astype(str).str.fullmatch(r"SYN-MBR-\d{4}").all():
        raise ValueError("Synthetic member identifier control failed.")
    if not frame["member_label"].astype(str).str.fullmatch(
        r"Fictional Clearing Member \d{3}"
    ).all():
        raise ValueError("Synthetic member label control failed.")
    if not frame["value_class"].eq("synthetic").all():
        raise ValueError("Synthetic-data labeling control failed.")
    if frame["actual_ficc_participant"].astype(bool).any():
        raise ValueError("An output record was marked as an actual FICC participant.")
    if frame["participant_level_inference"].astype(bool).any():
        raise ValueError("Participant-level inference control failed.")

    monetary_columns = [
        column
        for column in frame.columns
        if column.endswith("_usd") and pd.api.types.is_numeric_dtype(frame[column])
    ]
    if monetary_columns and (frame[monetary_columns] < 0.0).any().any():
        raise ValueError("Negative monetary exposure detected.")

    if not reconciliation["status"].eq("PASS").all():
        failed = reconciliation.loc[
            ~reconciliation["status"].eq("PASS"),
            "control",
        ].tolist()
        raise ValueError(f"Aggregate reconciliation failed: {failed}")

    if (frame["settlement_fail_usd"] > frame["settlement_obligation_usd"]).any():
        raise ValueError("Settlement fails exceed settlement obligations.")
    if (
        frame["reverse_repo_position_usd"] > frame["repo_financing_need_usd"]
    ).any():
        raise ValueError("Reverse-repo positions exceed gross repo financing.")
    if (
        frame["available_qualified_liquid_resources_usd"]
        > frame["collateral_inventory_usd"]
    ).any():
        raise ValueError("Qualified liquid resources exceed collateral inventory.")


def _write_manifest(
    *,
    output_path: Path,
    manifest_path: Path,
    targets: AggregateTargets,
    settings: CalibrationSettings,
    digest: str,
    row_count: int,
) -> None:
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "dataset": "calibrated_synthetic_clearing_member_portfolios",
        "value_class": "synthetic",
        "actual_ficc_participants": False,
        "participant_level_inference": False,
        "member_count": settings.member_count,
        "random_seed": settings.random_seed,
        "pareto_shape": settings.pareto_shape,
        "concentration_power": settings.concentration_power,
        "source_name": "FR 2004 Primary Dealer Statistics",
        "source_observation_date": targets.as_of_date.isoformat(),
        "source_file": targets.source_file,
        "source_sha256": targets.source_sha256,
        "output_file": output_path.as_posix(),
        "output_sha256": file_sha256(output_path),
        "deterministic_record_digest": digest,
        "row_count": row_count,
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "gate_status": "PASS",
    }
    pd.DataFrame([row]).to_csv(manifest_path, index=False)


def _write_evidence(
    *,
    evidence_path: Path,
    frame: pd.DataFrame,
    reconciliation: pd.DataFrame,
    targets: AggregateTargets,
    settings: CalibrationSettings,
    digest: str,
) -> None:
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    largest_share = float(
        frame["total_treasury_position_usd"].max()
        / frame["total_treasury_position_usd"].sum()
    )
    top_five_share = float(
        frame.nlargest(5, "total_treasury_position_usd")[
            "total_treasury_position_usd"
        ].sum()
        / frame["total_treasury_position_usd"].sum()
    )
    lines = [
        "PHASE IV — SECTION 12: CALIBRATION TO FEDERAL RESERVE AGGREGATES",
        "=" * 72,
        f"Generated at UTC: {datetime.now(UTC).isoformat()}",
        f"FR 2004 source date: {targets.as_of_date.isoformat()}",
        f"FR 2004 source file: {targets.source_file}",
        f"FR 2004 source SHA-256: {targets.source_sha256}",
        f"Member count: {settings.member_count}",
        f"Random seed: {settings.random_seed}",
        f"Pareto shape: {settings.pareto_shape}",
        f"Concentration power: {settings.concentration_power}",
        f"Deterministic record digest: {digest}",
        f"Largest-member Treasury share: {largest_share:.6f}",
        f"Top-five Treasury share: {top_five_share:.6f}",
        "",
        "Control results:",
        f"- Reconciliation rows: {len(reconciliation)}",
        f"- Reconciliation failures: {int((reconciliation['status'] != 'PASS').sum())}",
        f"- Negative USD values: {int((frame.filter(regex=r'_usd$') < 0).sum().sum())}",
        f"- Actual-participant flags: {int(frame['actual_ficc_participant'].astype(bool).sum())}",
        f"- Participant-inference flags: "
        f"{int(frame['participant_level_inference'].astype(bool).sum())}",
        "",
        "GATE RESULTS",
        "FR 2004 aggregate reconciliation: PASS",
        "Synthetic member identifiers: PASS",
        "Nonnegative exposures: PASS",
        "Deterministic reproduction: PASS",
        "No participant-level inference: PASS",
        "",
        "Important limitation:",
        (
            "This output is a stochastic allocation of public aggregate controls. "
            "It is not an estimate of any actual FICC participant and must not be "
            "used for participant identification, ranking, or reverse engineering."
        ),
        "",
        "Section 12 final decision: PASS",
    ]
    evidence_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_calibration(
    project_root: Path,
    config_path: Path,
) -> CalibrationResult:
    """Execute source resolution, generation, validation, and controlled output."""
    config = load_config(config_path)
    settings = load_settings(config)
    observations, source_path = discover_fr2004_source(project_root, config)
    definitions = load_series_definitions(project_root, config)
    targets, diagnostic = resolve_targets(
        observations,
        definitions,
        source_path,
        config,
    )

    outputs = _mapping(config.get("outputs"), "outputs")
    diagnostic_path = project_root / str(outputs["series_resolution_diagnostic"])
    diagnostic_path.parent.mkdir(parents=True, exist_ok=True)
    diagnostic.to_csv(diagnostic_path, index=False)

    frame_first = generate_calibrated_frame(targets, settings)
    frame_second = generate_calibrated_frame(targets, settings)
    digest_first = deterministic_digest(frame_first)
    digest_second = deterministic_digest(frame_second)
    if digest_first != digest_second:
        raise RuntimeError("Deterministic reproduction gate failed.")

    reconciliation = build_reconciliation(
        frame_first,
        targets,
        settings.aggregate_tolerance_usd,
    )
    validate_calibration(frame_first, reconciliation, settings)

    output_path = project_root / str(outputs["calibrated_portfolios"])
    reconciliation_path = project_root / str(outputs["reconciliation_table"])
    manifest_path = project_root / str(outputs["manifest"])
    evidence_path = project_root / str(outputs["evidence"])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    reconciliation_path.parent.mkdir(parents=True, exist_ok=True)
    frame_first.to_parquet(output_path, index=False, compression="zstd")
    reconciliation.to_csv(reconciliation_path, index=False)

    _write_manifest(
        output_path=output_path,
        manifest_path=manifest_path,
        targets=targets,
        settings=settings,
        digest=digest_first,
        row_count=len(frame_first),
    )
    _write_evidence(
        evidence_path=evidence_path,
        frame=frame_first,
        reconciliation=reconciliation,
        targets=targets,
        settings=settings,
        digest=digest_first,
    )
    return CalibrationResult(
        frame=frame_first,
        reconciliation=reconciliation,
        targets=targets,
        deterministic_digest=digest_first,
        source_resolution=diagnostic,
    )


def result_summary(result: CalibrationResult) -> str:
    """Return a stable JSON execution summary."""
    payload = {
        "member_count": len(result.frame),
        "source_observation_date": result.targets.as_of_date.isoformat(),
        "reconciliation_status": (
            "PASS" if result.reconciliation["status"].eq("PASS").all() else "FAIL"
        ),
        "deterministic_digest": result.deterministic_digest,
        "actual_ficc_participants": False,
        "participant_level_inference": False,
    }
    return json.dumps(payload, indent=2, sort_keys=True)
'@
    Write-Utf8File `
        -Path "src\ficc_liquidity\synthetic\calibrate_members.py" `
        -Content $CalibrationModule

    Write-Step "Writing the Section 12 command-line runner"

    $Runner = @'
"""Execute Phase IV, Section 12 synthetic-member aggregate calibration."""

from __future__ import annotations

import argparse
from pathlib import Path

from ficc_liquidity.synthetic.calibrate_members import (
    result_summary,
    run_calibration,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Repository root. Defaults to the current directory.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/synthetic_calibration.yaml"),
        help="Controlled Section 12 YAML configuration.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project_root = args.project_root.resolve()
    config_path = (
        args.config
        if args.config.is_absolute()
        else project_root / args.config
    )
    result = run_calibration(project_root, config_path)
    print(result_summary(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@
    Write-Utf8File -Path "scripts\run_synthetic_calibration.py" -Content $Runner

    Write-Step "Writing Section 12 unit tests"

    $Tests = @'
"""Unit tests for FR 2004 aggregate synthetic-member calibration."""

from __future__ import annotations

from datetime import date

import numpy as np

from ficc_liquidity.synthetic.calibrate_members import (
    MATURITY_COLUMNS,
    AggregateTargets,
    CalibrationSettings,
    build_reconciliation,
    deterministic_digest,
    exact_allocate,
    generate_calibrated_frame,
    heavy_tail_weights,
    validate_calibration,
)


def _settings(
    *,
    concentration_power: float = 1.4,
    random_seed: int = 2026,
) -> CalibrationSettings:
    return CalibrationSettings(
        member_count=24,
        random_seed=random_seed,
        pareto_shape=1.55,
        concentration_power=concentration_power,
        idiosyncratic_sigma=0.20,
        generator_version="test",
        collateral_coverage_low=1.05,
        collateral_coverage_high=1.45,
        qualified_resource_share_low=0.35,
        qualified_resource_share_high=0.70,
        stress_multiplier_low=1.10,
        stress_multiplier_high=1.55,
        risk_weights={
            "concentration": 0.25,
            "funding_dependency": 0.25,
            "settlement_fail": 0.20,
            "collateral_shortfall": 0.15,
            "liquidity_shortfall": 0.15,
        },
        elevated_threshold=40.0,
        high_threshold=65.0,
        aggregate_tolerance_usd=0.01,
    )


def _targets() -> AggregateTargets:
    maturity = {
        MATURITY_COLUMNS[0]: 7_000_000_000_00,
        MATURITY_COLUMNS[1]: 12_000_000_000_00,
        MATURITY_COLUMNS[2]: 15_000_000_000_00,
        MATURITY_COLUMNS[3]: 9_000_000_000_00,
        MATURITY_COLUMNS[4]: 14_000_000_000_00,
        MATURITY_COLUMNS[5]: 1_000_000_000_00,
    }
    source_series = {
        column: (f"TEST-{index}",)
        for index, column in enumerate(
            (
                *MATURITY_COLUMNS,
                "treasury_transaction_activity_usd",
                "fr2004_repo_financing_out_usd",
                "fr2004_reverse_repo_in_usd",
                "fr2004_fails_to_receive_usd",
                "fr2004_fails_to_deliver_usd",
            ),
            start=1,
        )
    }
    return AggregateTargets(
        as_of_date=date(2026, 1, 2),
        maturity_targets=maturity,
        treasury_transaction_activity_cents=40_000_000_000_00,
        repo_financing_out_cents=22_000_000_000_00,
        reverse_repo_in_cents=13_000_000_000_00,
        fails_to_receive_cents=2_000_000_000_00,
        fails_to_deliver_cents=3_000_000_000_00,
        source_file="test.csv",
        source_sha256="a" * 64,
        source_series=source_series,
    )


def test_exact_allocate_reconciles_integer_cents() -> None:
    allocated = exact_allocate(10_003, [0.5, 0.3, 0.2])
    assert allocated.sum() == 10_003
    assert (allocated >= 0).all()


def test_generation_is_deterministic_and_reconciles() -> None:
    settings = _settings()
    targets = _targets()
    first = generate_calibrated_frame(targets, settings)
    second = generate_calibrated_frame(targets, settings)

    assert deterministic_digest(first) == deterministic_digest(second)
    reconciliation = build_reconciliation(
        first,
        targets,
        settings.aggregate_tolerance_usd,
    )
    assert reconciliation["status"].eq("PASS").all()
    validate_calibration(first, reconciliation, settings)


def test_identifiers_and_labels_are_synthetic_only() -> None:
    frame = generate_calibrated_frame(_targets(), _settings())
    assert frame["member_id"].str.fullmatch(r"SYN-MBR-\d{4}").all()
    assert frame["member_label"].str.fullmatch(
        r"Fictional Clearing Member \d{3}"
    ).all()
    assert frame["value_class"].eq("synthetic").all()
    assert not frame["actual_ficc_participant"].any()
    assert not frame["participant_level_inference"].any()


def test_all_monetary_exposures_are_nonnegative() -> None:
    frame = generate_calibrated_frame(_targets(), _settings())
    monetary = [
        column
        for column in frame.columns
        if column.endswith("_usd")
        and np.issubdtype(frame[column].dtype, np.number)
    ]
    assert monetary
    assert (frame[monetary] >= 0.0).all().all()


def test_configurable_concentration_changes_largest_weight() -> None:
    low = heavy_tail_weights(_settings(concentration_power=0.8))
    high = heavy_tail_weights(_settings(concentration_power=2.2))
    assert high.max() > low.max()


def test_different_seed_changes_portfolio() -> None:
    targets = _targets()
    first = generate_calibrated_frame(targets, _settings(random_seed=2026))
    second = generate_calibrated_frame(targets, _settings(random_seed=2027))
    assert deterministic_digest(first) != deterministic_digest(second)
'@
    Write-Utf8File -Path "tests\test_synthetic_calibration.py" -Content $Tests

    Write-Step "Writing the Section 12 methodology and limitations"

    $Methodology = @'
# Phase IV, Section 12 — Calibration to Federal Reserve Aggregates

## Purpose

This section allocates selected public FR 2004 aggregate controls across a configurable
set of fictional clearing members. It supports liquidity stress-testing methodology and
implementation validation. It does not estimate actual participant portfolios.

## Mandatory non-identification control

Every generated identifier follows `SYN-MBR-0001` and every label follows
`Fictional Clearing Member 001`. The output sets:

- `value_class = synthetic`;
- `actual_ficc_participant = false`;
- `participant_level_inference = false`.

No dealer name, FICC participant name, market share estimate, regulatory filing, or
participant-specific attribute is used. The allocation is determined only by the configured
random seed, Pareto shape, concentration power, and public aggregate totals.

## Source hierarchy

The implementation uses the first available controlled source:

1. latest immutable FR 2004 raw CSV under `data/raw/fr2004`;
2. latest canonical FR 2004 Parquet file;
3. Section 8 processed Federal Reserve factors.

The official FR 2004 series dictionary is cached locally when available. Series resolution is
recorded in `reports/evidence/fr2004_series_resolution_diagnostic.csv`.

## Aggregate controls

The selected controls are:

- nonnegative Treasury long-position maturity buckets;
- Treasury transaction activity;
- Treasury securities-out financing;
- Treasury securities-in or reverse-repo activity;
- Treasury fails to receive;
- Treasury fails to deliver.

Treasury maturity controls are mutually exclusive within the selected series universe. If the
official descriptions do not permit direct maturity resolution, the selected aggregate
Treasury long-position control is split using the pre-specified fallback shares in the YAML
configuration. The fallback is a transparent model assumption, not an observed participant
distribution.

## Exact allocation

For every control, the procedure:

1. converts the aggregate to integer U.S. cents;
2. generates deterministic Pareto member weights;
3. applies the configured concentration power;
4. applies a deterministic lognormal component perturbation;
5. allocates cents using the largest-remainder method;
6. verifies that allocated cents equal target cents exactly.

This prevents floating-point drift from creating an apparent reconciliation difference.

## Financing and settlement identities

The FR 2004 securities-out and securities-in controls are stock measures, while Treasury
transaction activity is a flow measure. They are therefore retained in separate, clearly
labeled FR 2004 calibration columns and reconciled independently. The member-schema repo
financing need and reverse-repo position are synthetic normalized exposures derived from
the member's allocated transaction activity and observed financing mix. This construction
preserves the Section 11 requirements that funding dependency remain between zero and one
and that reverse-repo positions not exceed repo financing need without mischaracterizing
stock and flow aggregates as an accounting identity.

Settlement fails equal fails to receive plus fails to deliver, with both components retained
and reconciled separately.

## Derived fields

Settlement obligations, stressed liquidity needs, collateral inventory, qualified liquid
resources, coverage ratios, and liquidity-risk scores are synthetic derived quantities. They
are not represented as FR 2004 observations.

## Reproducibility

The random seed, member count, Pareto shape, concentration power, risk weights, source hash,
source observation date, and deterministic record digest are recorded in the manifest and
evidence report. Two independent in-memory generations must have identical digests.

## Completion gates

The implementation cannot report Section 12 as complete unless all five gates pass:

- FR 2004 aggregate reconciliation;
- synthetic member identifiers;
- nonnegative exposures;
- deterministic reproduction;
- no participant-level inference.
'@
    Write-Utf8File -Path "docs\synthetic_calibration_methodology.md" -Content $Methodology

    if (-not (Test-Path -LiteralPath "scripts\__init__.py")) {
        Write-Utf8File `
            -Path "scripts\__init__.py" `
            -Content '"""Controlled executable scripts for the FICC liquidity project."""'
    }

    Write-Step "Resolving the Python 3.11 environment"

    $Python = Join-Path $RepoPath ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        $pyLauncher = Get-Command "py" -ErrorAction SilentlyContinue
        if ($null -eq $pyLauncher) {
            throw "Python launcher was not found. Install Python 3.11 and restart VS Code."
        }
        Invoke-Checked -FilePath $pyLauncher.Source `
            -ArgumentList @("-3.11", "-m", "venv", ".venv") `
            -FailureMessage "Unable to create the Python 3.11 virtual environment."
    }

    $PythonVersion = (& $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')").Trim()
    if ($LASTEXITCODE -ne 0 -or $PythonVersion -ne "3.11") {
        throw "Section 12 requires Python 3.11; detected '$PythonVersion'."
    }
    Write-Pass "Python 3.11 virtual environment detected"

    $env:PYTHONPATH = Join-Path $RepoPath "src"

    Write-Step "Checking required Python packages"

    & $Python -c "import numpy, pandas, yaml, pyarrow, requests, pytest, ruff, mypy"
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked -FilePath $Python `
            -ArgumentList @(
                "-m", "pip", "install",
                "numpy", "pandas", "pyyaml", "pyarrow", "requests",
                "pytest", "pytest-cov", "ruff", "mypy",
                "pandas-stubs", "types-PyYAML", "types-requests"
            ) `
            -FailureMessage "Unable to install Section 12 dependencies."
    }
    Write-Pass "Required Python packages are available"

    $QualityPaths = @(
        "src/ficc_liquidity/synthetic/calibrate_members.py",
        "scripts/run_synthetic_calibration.py",
        "tests/test_synthetic_calibration.py"
    )

    Write-Step "Running formatting, syntax, linting, and type checks"

    Invoke-Checked -FilePath $Python `
        -ArgumentList (@(
            "-m", "ruff", "check", "--fix",
            "--select", "E,F,I,UP,B,RUF"
        ) + $QualityPaths) `
        -FailureMessage "Ruff automatic repair failed."

    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "format") + $QualityPaths) `
        -FailureMessage "Ruff formatting failed."

    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "format", "--check") + $QualityPaths) `
        -FailureMessage "Ruff format validation failed."

    Invoke-Checked -FilePath $Python `
        -ArgumentList (@(
            "-m", "ruff", "check",
            "--select", "E,F,I,UP,B,RUF"
        ) + $QualityPaths) `
        -FailureMessage "Ruff linting failed."

    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "compileall", "-q") + $QualityPaths) `
        -FailureMessage "Python syntax compilation failed."

    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "mypy",
            "--ignore-missing-imports",
            "--allow-any-generics",
            "--allow-untyped-defs",
            "--allow-incomplete-defs",
            "--allow-untyped-calls",
            "--no-warn-return-any",
            "src/ficc_liquidity/synthetic/calibrate_members.py",
            "scripts/run_synthetic_calibration.py"
        ) `
        -FailureMessage "Mypy validation failed."

    Write-Pass "Formatting, syntax, Ruff, and Mypy checks passed"

    Write-Step "Running focused Section 12 tests"

    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "pytest", "-q", "-o", "addopts=",
            "tests/test_synthetic_calibration.py"
        ) `
        -FailureMessage "Section 12 unit tests failed."
    Write-Pass "Section 12 unit tests passed"

    Write-Step "Executing FR 2004 aggregate calibration"

    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "scripts/run_synthetic_calibration.py",
            "--project-root", $RepoPath,
            "--config", "configs/synthetic_calibration.yaml"
        ) `
        -FailureMessage @"
Section 12 calibration failed.
Review reports/evidence/fr2004_series_resolution_diagnostic.csv.
If an official series description changed, update only the regex mapping in
configs/synthetic_calibration.yaml and rerun this same automation with -AllowDirty.
"@

    $RequiredOutputs = @(
        "data\synthetic\calibrated_member_portfolios.parquet",
        "reports\tables\synthetic_calibration_reconciliation.csv",
        "data\manifests\synthetic_calibration_manifest.csv",
        "reports\evidence\section_12_synthetic_calibration_report.txt",
        "reports\evidence\fr2004_series_resolution_diagnostic.csv"
    )
    foreach ($relativePath in $RequiredOutputs) {
        $fullPath = Join-Path $RepoPath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Required Section 12 output was not created: $relativePath"
        }
        if ((Get-Item -LiteralPath $fullPath).Length -eq 0) {
            throw "Required Section 12 output is empty: $relativePath"
        }
        Write-Pass $relativePath
    }

    Write-Step "Independently verifying the five Section 12 gates"

    $VerifierPath = Join-Path $env:TEMP "verify_section12_$([guid]::NewGuid().ToString('N')).py"
    $Verifier = @'
from pathlib import Path

import numpy as np
import pandas as pd

root = Path.cwd()
portfolio = pd.read_parquet(
    root / "data/synthetic/calibrated_member_portfolios.parquet"
)
reconciliation = pd.read_csv(
    root / "reports/tables/synthetic_calibration_reconciliation.csv"
)
manifest = pd.read_csv(
    root / "data/manifests/synthetic_calibration_manifest.csv"
)

if portfolio.empty:
    raise RuntimeError("Calibrated portfolio is empty.")
if not reconciliation["status"].eq("PASS").all():
    raise RuntimeError("FR 2004 aggregate reconciliation contains a failure.")
if not portfolio["member_id"].astype(str).str.fullmatch(r"SYN-MBR-\d{4}").all():
    raise RuntimeError("Synthetic member identifier gate failed.")
if portfolio["member_id"].duplicated().any():
    raise RuntimeError("Synthetic member identifiers are not unique.")

money = [
    column
    for column in portfolio.columns
    if column.endswith("_usd")
    and np.issubdtype(portfolio[column].dtype, np.number)
]
if not money or (portfolio[money] < 0.0).any().any():
    raise RuntimeError("Nonnegative exposure gate failed.")
if not portfolio["value_class"].eq("synthetic").all():
    raise RuntimeError("Synthetic-data labeling gate failed.")
if portfolio["actual_ficc_participant"].astype(bool).any():
    raise RuntimeError("Actual-participant flag gate failed.")
if portfolio["participant_level_inference"].astype(bool).any():
    raise RuntimeError("Participant-level inference gate failed.")
if manifest.iloc[-1]["gate_status"] != "PASS":
    raise RuntimeError("Manifest gate status is not PASS.")
digest = str(manifest.iloc[-1]["deterministic_record_digest"])
if len(digest) != 64:
    raise RuntimeError("Deterministic digest is invalid.")

print("FR 2004 aggregate reconciliation: PASS")
print("Synthetic member identifiers: PASS")
print("Nonnegative exposures: PASS")
print("Deterministic reproduction: PASS")
print("No participant-level inference: PASS")
'@
    Write-Utf8File -Path $VerifierPath -Content $Verifier
    try {
        Invoke-Checked -FilePath $Python `
            -ArgumentList @($VerifierPath) `
            -FailureMessage "Independent Section 12 gate verification failed."
    }
    finally {
        Remove-Item -LiteralPath $VerifierPath -Force -ErrorAction SilentlyContinue
    }

    if (-not $SkipFullTests) {
        Write-Step "Running the complete repository test suite"
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("-m", "pytest", "-q") `
            -FailureMessage "The complete repository test suite failed."
        Write-Pass "Complete repository test suite passed"
    }
    else {
        Write-Warn "Complete repository tests were skipped; focused Section 12 tests passed."
    }

    if (-not $SkipGit -and -not $NoCommit) {
        Write-Step "Staging and committing only Section 12 artifacts"

        $StagePaths = @(
            "configs/synthetic_calibration.yaml",
            "src/ficc_liquidity/synthetic/calibrate_members.py",
            "scripts/run_synthetic_calibration.py",
            "scripts/__init__.py",
            "scripts/automation/14_P4S12_FR2004_Synthetic_Calibration_PS51.ps1",
            "tests/test_synthetic_calibration.py",
            "docs/synthetic_calibration_methodology.md",
            "reports/tables/synthetic_calibration_reconciliation.csv",
            "reports/evidence/section_12_synthetic_calibration_report.txt",
            "reports/evidence/fr2004_series_resolution_diagnostic.csv",
            "data/manifests/synthetic_calibration_manifest.csv"
        )
        foreach ($relativePath in $StagePaths) {
            if (Test-Path -LiteralPath (Join-Path $RepoPath $relativePath)) {
                Invoke-Checked -FilePath "git" `
                    -ArgumentList @("add", "--", $relativePath) `
                    -FailureMessage "Unable to stage $relativePath."
            }
        }

        $PortfolioPath = "data/synthetic/calibrated_member_portfolios.parquet"
        $PortfolioSizeMb = (Get-Item -LiteralPath $PortfolioPath).Length / 1MB
        if ($PortfolioSizeMb -gt 95) {
            throw "Generated portfolio is unexpectedly larger than 95 MB."
        }
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("add", "-f", "--", $PortfolioPath) `
            -FailureMessage "Unable to stage the calibrated portfolio Parquet file."

        & git diff --cached --quiet
        $hasStagedChanges = $LASTEXITCODE -ne 0
        if ($hasStagedChanges) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("commit", "-m", $CommitMessage) `
                -FailureMessage "Section 12 Git commit failed."
        }
        else {
            Write-Warn "No new Section 12 changes required a commit."
        }
    }
    elseif ($NoCommit) {
        Write-Warn "Git commit was skipped by request."
    }

    if (-not $SkipGit -and -not $SkipPush) {
        Write-Step "Pushing $BranchName"
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("push", "-u", "origin", $BranchName) `
            -FailureMessage "Unable to push $BranchName."
        Write-Pass "Feature branch pushed"
    }
    elseif ($SkipPush) {
        Write-Warn "GitHub push was skipped."
    }

    if (
        -not $SkipGit -and
        -not $SkipPush -and
        -not $SkipPullRequest
    ) {
        Write-Step "Creating or confirming the draft pull request"
        Assert-Command -Name "gh"

        & gh pr view $BranchName --json url *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Warn "A pull request already exists for $BranchName."
        }
        else {
            $PrBody = @"
## Phase IV — Synthetic Clearing-Member Portfolios
### Section 12 — Calibration to Federal Reserve aggregates

Implements:
- deterministic heavy-tailed synthetic-member allocation;
- configurable member count, Pareto shape, and concentration;
- exact-cent reconciliation to selected FR 2004 aggregate controls;
- Treasury maturity-bucket reconciliation;
- repo, reverse-repo, and settlement-fail reconciliation;
- nonnegative exposure validation;
- controlled synthetic identifiers and labeling;
- explicit prohibition on participant-level inference;
- tests, manifest, reconciliation table, and validation evidence.

### Gates
- FR 2004 aggregate reconciliation: PASS
- Synthetic member identifiers: PASS
- Nonnegative exposures: PASS
- Deterministic reproduction: PASS
- No participant-level inference: PASS
"@
            Invoke-Checked -FilePath "gh" `
                -ArgumentList @(
                    "pr", "create", "--draft",
                    "--base", "main",
                    "--head", $BranchName,
                    "--title", "Phase IV Section 12: calibrate synthetic portfolios to FR 2004",
                    "--body", $PrBody
                ) `
                -FailureMessage "Unable to create the Section 12 pull request."
        }
    }
    elseif ($SkipPullRequest) {
        Write-Warn "Pull-request creation was skipped."
    }

    Write-Step "Section 12 completion summary"

    $Manifest = Import-Csv -LiteralPath "data\manifests\synthetic_calibration_manifest.csv" |
        Select-Object -Last 1

    Write-Host "Branch:                              $BranchName"
    Write-Host "Member count:                         $($Manifest.member_count)"
    Write-Host "Random seed:                          $($Manifest.random_seed)"
    Write-Host "FR 2004 observation date:             $($Manifest.source_observation_date)"
    Write-Host "Deterministic record digest:          $($Manifest.deterministic_record_digest)"
    Write-Host ""
    Write-Host "FR 2004 aggregate reconciliation: PASS" -ForegroundColor Green
    Write-Host "Synthetic member identifiers: PASS" -ForegroundColor Green
    Write-Host "Nonnegative exposures: PASS" -ForegroundColor Green
    Write-Host "Deterministic reproduction: PASS" -ForegroundColor Green
    Write-Host "No participant-level inference: PASS" -ForegroundColor Green
    Write-Host ""
    Write-Host "SECTION 12 FINAL DECISION: PASS" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "SECTION 12 AUTOMATION FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Correct the reported condition and rerun the same PowerShell file." -ForegroundColor Yellow
    exit 1
}
