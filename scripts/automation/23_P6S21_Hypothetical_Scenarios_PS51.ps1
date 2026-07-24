#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase VI, Section 21: hypothetical scenarios.

.DESCRIPTION
    Run this single PowerShell 5.1 automation from the VS Code PowerShell
    terminal. It continues on the shared feature/18-scenario-library branch,
    verifies Section 20 and the Phase V stress components, writes the controlled
    Section 21 configuration, Python scenario framework, runner, tests, and
    methodology, executes smoke and complete scenario runs, applies Ruff, strict
    Mypy, focused branch coverage, and repository-wide tests, then commits and
    pushes the shared branch.

    The automation deliberately does not open a pull request. Sections 20-23
    remain together on feature/18-scenario-library until the scenario framework
    phase is complete.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\23_P6S21_Hypothetical_Scenarios_PS51.ps1"

.EXAMPLE
    & "$env:USERPROFILE\Downloads\23_P6S21_Hypothetical_Scenarios_PS51.ps1" `
        -SmokeOnly -SkipFullTests -SkipPush
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$Branch = "feature/18-scenario-library",
    [switch]$SkipInstall,
    [switch]$SkipGit,
    [switch]$SkipPush,
    [switch]$SkipCommit,
    [switch]$SmokeOnly,
    [switch]$SkipFullTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (Test-Path -LiteralPath "variable:PSNativeCommandUseErrorActionPreference") {
    $PSNativeCommandUseErrorActionPreference = $false
}

$AutomationRelative = "scripts\automation\23_P6S21_Hypothetical_Scenarios_PS51.ps1"
$CommitMessage = "Phase VI Section 21: add hypothetical scenario framework"

function Write-Section {
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

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    Write-Host ("> {0} {1}" -f $FilePath, ($Arguments -join " ")) -ForegroundColor DarkGray
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed with exit code {0}: {1} {2}" -f $LASTEXITCODE, $FilePath, ($Arguments -join " "))
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($normalized.TrimStart() + "`n"), $encoding)
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    $baseUri = New-Object System.Uri(($BasePath.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri($TargetPath)
    return [System.Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($targetUri).ToString()
    ).Replace('/', '\')
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
            if ($pathPart -eq $allowed) {
                $isAllowed = $true
                break
            }
        }
        if (-not $isAllowed) { $unexpected += $line }
    }
    if ($unexpected.Count -gt 0) {
        throw @"
The worktree contains changes unrelated to this automation:
$($unexpected -join [Environment]::NewLine)
Commit or stash those changes, then rerun Section 21.
"@
    }
}

function Test-RequiredFiles {
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $missing = @()
    foreach ($relativePath in $Paths) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath) -PathType Leaf)) {
            $missing += $relativePath
        }
    }
    if ($missing.Count -gt 0) {
        throw "Required project files are missing: $($missing -join ', ')"
    }
}

$OriginalLocation = Get-Location
try {
    Write-Section "Phase VI Section 21 - Hypothetical Scenarios"

    Assert-Command -Name "git"
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        throw "Repository path does not exist: $RepoRoot"
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    Set-Location -LiteralPath $RepoRoot

    $gitRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitRoot)) {
        throw "The selected path is not a Git repository: $RepoRoot"
    }
    $gitRoot = (Resolve-Path -LiteralPath $gitRoot.Trim()).Path
    if (-not $gitRoot.Equals($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $RepoRoot = $gitRoot
        Set-Location -LiteralPath $RepoRoot
    }

    $AutomationTarget = Join-Path $RepoRoot $AutomationRelative
    $CurrentScript = $MyInvocation.MyCommand.Path
    $allowed = @($AutomationRelative)
    if ($CurrentScript -and (Test-Path -LiteralPath $CurrentScript)) {
        try {
            $currentResolved = (Resolve-Path -LiteralPath $CurrentScript).Path
            if ($currentResolved.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowed += Get-RelativePath -BasePath $RepoRoot -TargetPath $currentResolved
            }
        }
        catch {
            Write-Warn "Could not resolve the current automation path for the clean-tree allowance."
        }
    }

    if (-not $SkipGit) {
        Write-Section "Prepare shared Phase VI scenario-library branch"
        Assert-CleanWorktreeExceptAutomation -AllowedPaths $allowed
        Invoke-Native git fetch origin --prune

        & git show-ref --verify --quiet ("refs/heads/{0}" -f $Branch)
        $localBranchExists = ($LASTEXITCODE -eq 0)
        & git show-ref --verify --quiet ("refs/remotes/origin/{0}" -f $Branch)
        $remoteBranchExists = ($LASTEXITCODE -eq 0)

        if ($localBranchExists) {
            Invoke-Native git switch $Branch
            if ($remoteBranchExists) {
                Invoke-Native git pull --ff-only origin $Branch
            }
        }
        elseif ($remoteBranchExists) {
            Invoke-Native git switch --track -c $Branch ("origin/{0}" -f $Branch)
        }
        else {
            throw @"
The shared branch '$Branch' does not exist locally or on origin.
Section 20 must be completed and pushed before Section 21 is run.
"@
        }

        $currentBranch = (& git branch --show-current).Trim()
        if ($currentBranch -ne $Branch) {
            throw "Expected branch '$Branch' but found '$currentBranch'."
        }
        Write-Pass "Current branch is $Branch"
    }
    else {
        Write-Warn "Git branch preparation was skipped."
    }

    Write-Section "Verify Section 20 and Phase V dependencies"
    Test-RequiredFiles -Paths @(
        "configs\historical_scenario_replay.yaml",
        "src\ficc_liquidity\scenarios\historical_scenarios.py",
        "scripts\run_historical_scenarios.py",
        "tests\test_historical_scenarios.py",
        "configs\treasury_yield_stress.yaml",
        "configs\repo_funding_stress.yaml",
        "configs\collateral_haircut_stress.yaml",
        "configs\settlement_fail_stress.yaml",
        "configs\integrated_stress_engine.yaml",
        "src\ficc_liquidity\stress\treasury_yield_shock.py",
        "src\ficc_liquidity\stress\repo_funding_stress.py",
        "src\ficc_liquidity\stress\collateral_haircut_stress.py",
        "src\ficc_liquidity\stress\settlement_fail_stress.py",
        "src\ficc_liquidity\stress\integrated_stress.py"
    )
    Write-Pass "Section 20 and Phase V dependencies are available"

    Write-Section "Install Section 21 configuration, source, runner, tests, and methodology"
    $Target = Join-Path $RepoRoot "configs\hypothetical_scenarios.yaml"
    $Content = @'
schema_version: "1.0"
section: 21
model_name: hypothetical_scenario_framework
model_version: "section-21-v1"
currency: USD
random_seed: 2026

classification:
  scenario_assumptions: hypothetical
  synthetic_member_exposures: synthetic
  component_models: modeled
  integrated_results: modeled
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false

source:
  baseline_cashflow_candidates:
    - reports/tables/baseline_liquidity_cashflows.parquet
    - reports/tables/baseline_liquidity_cashflows.csv
  baseline_summary_candidates:
    - reports/tables/baseline_liquidity_summary.parquet
    - reports/tables/baseline_liquidity_summary.csv
  member_profile_candidates:
    - data/synthetic/calibrated_member_portfolios.parquet
    - data/synthetic/calibrated_member_portfolios.csv
  treasury_position_candidates:
    - reports/tables/treasury_yield_stress_positions_section19_adapter.parquet
    - reports/tables/treasury_yield_stress_positions_section19_adapter.csv
  treasury_config: configs/treasury_yield_stress.yaml
  funding_config: configs/repo_funding_stress.yaml
  haircut_config: configs/collateral_haircut_stress.yaml
  settlement_config: configs/settlement_fail_stress.yaml
  integrated_config: configs/integrated_stress_engine.yaml

guardrails:
  maximum_absolute_treasury_shock_bp: 500.0
  maximum_sofr_spike_bp: 500.0
  maximum_funding_spread_increase_bp: 350.0
  maximum_rollover_failure_rate: 0.75
  maximum_lender_withdrawal_rate: 0.60
  maximum_additive_haircut_rate: 0.10
  maximum_settlement_fail_multiplier: 5.00
  maximum_operational_liquidity_buffer_rate: 0.20

scenarios:
  - name: moderate_stress
    label: Moderate stress
    family: broad_market
    severity: moderate
    display_order: 1
    treasury:
      shape: parallel
      parallel_bp: 50.0
    funding:
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
    haircut:
      stress_multiplier: 1.25
      additive_haircut_rate: 0.005
      bucket_addon_short_rate: 0.000
      bucket_addon_long_rate: 0.015
      concentration_threshold: 0.35
      concentration_multiplier: 0.10
      additional_collateral_call_rate: 0.010
      inventory_availability_rate: 0.95
      maximum_haircut_rate: 0.50
    settlement:
      fails_to_receive_multiplier: 1.50
      fails_to_deliver_multiplier: 1.25
      additional_fails_to_receive_rate: 0.02
      additional_fails_to_deliver_rate: 0.01
      incoming_payment_delay_buckets: 1
      replacement_liquidity_rate: 1.00
      persistence_days: 2
      persistence_decay: 0.70
      funding_stress_weight: 0.50
    integrated:
      concentration_threshold: 0.35
      concentration_multiplier: 0.10
      operational_liquidity_buffer_rate: 0.02

  - name: severe_stress
    label: Severe stress
    family: broad_market
    severity: severe
    display_order: 2
    treasury:
      shape: parallel
      parallel_bp: 100.0
    funding:
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
    haircut:
      stress_multiplier: 1.75
      additive_haircut_rate: 0.015
      bucket_addon_short_rate: 0.002
      bucket_addon_long_rate: 0.040
      concentration_threshold: 0.25
      concentration_multiplier: 0.30
      additional_collateral_call_rate: 0.030
      inventory_availability_rate: 0.80
      maximum_haircut_rate: 0.50
    settlement:
      fails_to_receive_multiplier: 2.50
      fails_to_deliver_multiplier: 2.00
      additional_fails_to_receive_rate: 0.05
      additional_fails_to_deliver_rate: 0.03
      incoming_payment_delay_buckets: 2
      replacement_liquidity_rate: 1.10
      persistence_days: 4
      persistence_decay: 0.80
      funding_stress_weight: 0.75
    integrated:
      concentration_threshold: 0.25
      concentration_multiplier: 0.25
      operational_liquidity_buffer_rate: 0.05

  - name: extreme_but_plausible_stress
    label: Extreme but plausible stress
    family: broad_market
    severity: extreme
    display_order: 3
    treasury:
      shape: steepening
      short_end_bp: 150.0
      long_end_bp: 300.0
    funding:
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
    haircut:
      stress_multiplier: 2.50
      additive_haircut_rate: 0.030
      bucket_addon_short_rate: 0.005
      bucket_addon_long_rate: 0.075
      concentration_threshold: 0.20
      concentration_multiplier: 0.50
      additional_collateral_call_rate: 0.080
      inventory_availability_rate: 0.60
      maximum_haircut_rate: 0.50
    settlement:
      fails_to_receive_multiplier: 4.00
      fails_to_deliver_multiplier: 3.00
      additional_fails_to_receive_rate: 0.10
      additional_fails_to_deliver_rate: 0.07
      incoming_payment_delay_buckets: 4
      replacement_liquidity_rate: 1.25
      persistence_days: 7
      persistence_decay: 0.90
      funding_stress_weight: 1.00
    integrated:
      concentration_threshold: 0.20
      concentration_multiplier: 0.50
      operational_liquidity_buffer_rate: 0.10

  - name: parallel_treasury_shock
    label: Parallel Treasury shock
    family: treasury_parallel
    severity: targeted
    display_order: 4
    treasury:
      shape: parallel
      parallel_bp: 150.0
    funding: &funding_control
      sofr_spike_bp: 0.0
      funding_spread_increase_bp: 0.0
      repo_rollover_failure_rate: 0.0
      lender_withdrawal_rate: 0.0
      refinancing_horizon_hours: 48
      collateral_haircut_increase: 0.0
      collateral_call_rate: 0.0
      concentration_threshold: 1.00
      concentration_multiplier: 0.0
      funding_dependency_multiplier: 0.0
      max_effective_unavailability_rate: 0.0
    haircut: &haircut_control
      stress_multiplier: 1.00
      additive_haircut_rate: 0.000
      bucket_addon_short_rate: 0.000
      bucket_addon_long_rate: 0.000
      concentration_threshold: 1.00
      concentration_multiplier: 0.00
      additional_collateral_call_rate: 0.000
      inventory_availability_rate: 1.00
      maximum_haircut_rate: 0.50
    settlement: &settlement_control
      fails_to_receive_multiplier: 0.0
      fails_to_deliver_multiplier: 0.0
      additional_fails_to_receive_rate: 0.0
      additional_fails_to_deliver_rate: 0.0
      incoming_payment_delay_buckets: 0
      replacement_liquidity_rate: 0.0
      persistence_days: 1
      persistence_decay: 0.0
      funding_stress_weight: 0.0
    integrated: &integrated_targeted
      concentration_threshold: 1.00
      concentration_multiplier: 0.00
      operational_liquidity_buffer_rate: 0.00

  - name: curve_steepening
    label: Treasury curve steepening
    family: treasury_curve
    severity: targeted
    display_order: 5
    treasury:
      shape: steepening
      short_end_bp: 25.0
      long_end_bp: 175.0
    funding: *funding_control
    haircut: *haircut_control
    settlement: *settlement_control
    integrated: *integrated_targeted

  - name: curve_flattening
    label: Treasury curve flattening
    family: treasury_curve
    severity: targeted
    display_order: 6
    treasury:
      shape: flattening
      short_end_bp: 175.0
      long_end_bp: 25.0
    funding: *funding_control
    haircut: *haircut_control
    settlement: *settlement_control
    integrated: *integrated_targeted

  - name: sofr_spike
    label: SOFR spike
    family: funding_rate
    severity: targeted
    display_order: 7
    treasury:
      shape: none
    funding:
      <<: *funding_control
      sofr_spike_bp: 300.0
      funding_spread_increase_bp: 75.0
    haircut: *haircut_control
    settlement: *settlement_control
    integrated: *integrated_targeted

  - name: repo_rollover_failure
    label: Repo rollover failure
    family: funding_rollover
    severity: targeted
    display_order: 8
    treasury:
      shape: none
    funding:
      <<: *funding_control
      repo_rollover_failure_rate: 0.45
      lender_withdrawal_rate: 0.20
      refinancing_horizon_hours: 12
      concentration_threshold: 0.20
      concentration_multiplier: 1.50
      funding_dependency_multiplier: 0.75
      max_effective_unavailability_rate: 0.80
    haircut: *haircut_control
    settlement: *settlement_control
    integrated: *integrated_targeted

  - name: collateral_haircut_increase
    label: Collateral haircut increase
    family: collateral
    severity: targeted
    display_order: 9
    treasury:
      shape: none
    funding: *funding_control
    haircut:
      <<: *haircut_control
      stress_multiplier: 1.75
      additive_haircut_rate: 0.020
      bucket_addon_short_rate: 0.002
      bucket_addon_long_rate: 0.050
      concentration_threshold: 0.25
      concentration_multiplier: 0.25
      additional_collateral_call_rate: 0.040
      inventory_availability_rate: 0.75
    settlement: *settlement_control
    integrated: *integrated_targeted

  - name: settlement_fail_increase
    label: Settlement-fail increase
    family: settlement
    severity: targeted
    display_order: 10
    treasury:
      shape: none
    funding: *funding_control
    haircut: *haircut_control
    settlement:
      <<: *settlement_control
      fails_to_receive_multiplier: 3.00
      fails_to_deliver_multiplier: 2.50
      additional_fails_to_receive_rate: 0.07
      additional_fails_to_deliver_rate: 0.05
      incoming_payment_delay_buckets: 3
      replacement_liquidity_rate: 1.15
      persistence_days: 5
      persistence_decay: 0.85
    integrated: *integrated_targeted

  - name: combined_systemic_stress
    label: Combined systemic stress
    family: systemic
    severity: extreme
    display_order: 11
    treasury:
      shape: steepening
      short_end_bp: 200.0
      long_end_bp: 350.0
    funding:
      sofr_spike_bp: 450.0
      funding_spread_increase_bp: 300.0
      repo_rollover_failure_rate: 0.65
      lender_withdrawal_rate: 0.50
      refinancing_horizon_hours: 6
      collateral_haircut_increase: 0.12
      collateral_call_rate: 0.18
      concentration_threshold: 0.12
      concentration_multiplier: 3.50
      funding_dependency_multiplier: 1.75
      max_effective_unavailability_rate: 0.99
    haircut:
      stress_multiplier: 2.75
      additive_haircut_rate: 0.040
      bucket_addon_short_rate: 0.008
      bucket_addon_long_rate: 0.090
      concentration_threshold: 0.15
      concentration_multiplier: 0.60
      additional_collateral_call_rate: 0.100
      inventory_availability_rate: 0.50
      maximum_haircut_rate: 0.50
    settlement:
      fails_to_receive_multiplier: 4.50
      fails_to_deliver_multiplier: 3.50
      additional_fails_to_receive_rate: 0.12
      additional_fails_to_deliver_rate: 0.09
      incoming_payment_delay_buckets: 5
      replacement_liquidity_rate: 1.30
      persistence_days: 8
      persistence_decay: 0.92
      funding_stress_weight: 1.00
    integrated:
      concentration_threshold: 0.15
      concentration_multiplier: 0.65
      operational_liquidity_buffer_rate: 0.15

validation:
  reconciliation_tolerance_usd: 0.01
  require_all_scenario_families: true
  require_guardrail_compliance: true
  require_deterministic_reproduction: true
  require_synthetic_members_only: true
  require_integrated_double_count_controls: true

output:
  directory: reports/tables
  evidence_directory: reports/evidence
  manifest: data/manifests/hypothetical_scenario_manifest.csv
  write_csv: true
  write_parquet: true
'@
    Write-Utf8NoBom -Path $Target -Content $Content
    Write-Pass "Wrote configs/hypothetical_scenarios.yaml"

    $Target = Join-Path $RepoRoot "src\ficc_liquidity\scenarios\hypothetical_scenarios.py"
    $Content = @'
"""Controlled hypothetical scenario framework for Phase VI, Section 21."""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class HypotheticalScenarioError(ValueError):
    """Raised when Section 21 scenario inputs or assumptions are invalid."""


REQUIRED_SCENARIOS: frozenset[str] = frozenset(
    {
        "moderate_stress",
        "severe_stress",
        "extreme_but_plausible_stress",
        "parallel_treasury_shock",
        "curve_steepening",
        "curve_flattening",
        "sofr_spike",
        "repo_rollover_failure",
        "collateral_haircut_increase",
        "settlement_fail_increase",
        "combined_systemic_stress",
    }
)

REQUIRED_FAMILIES: frozenset[str] = frozenset(
    {
        "broad_market",
        "treasury_parallel",
        "treasury_curve",
        "funding_rate",
        "funding_rollover",
        "collateral",
        "settlement",
        "systemic",
    }
)

FUNDING_FIELDS: tuple[str, ...] = (
    "sofr_spike_bp",
    "funding_spread_increase_bp",
    "repo_rollover_failure_rate",
    "lender_withdrawal_rate",
    "refinancing_horizon_hours",
    "collateral_haircut_increase",
    "collateral_call_rate",
    "concentration_threshold",
    "concentration_multiplier",
    "funding_dependency_multiplier",
    "max_effective_unavailability_rate",
)

SETTLEMENT_FIELDS: tuple[str, ...] = (
    "fails_to_receive_multiplier",
    "fails_to_deliver_multiplier",
    "additional_fails_to_receive_rate",
    "additional_fails_to_deliver_rate",
    "incoming_payment_delay_buckets",
    "replacement_liquidity_rate",
    "persistence_days",
    "persistence_decay",
    "funding_stress_weight",
)


@dataclass(frozen=True, slots=True)
class HypotheticalScenario:
    """One controlled Section 21 hypothetical scenario."""

    name: str
    label: str
    family: str
    severity: str
    display_order: int
    treasury: Mapping[str, Any]
    funding: Mapping[str, Any]
    haircut: Mapping[str, Any]
    settlement: Mapping[str, Any]
    integrated: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class HypotheticalSettings:
    """Validated Section 21 runtime settings."""

    model_version: str
    source: Mapping[str, Any]
    guardrails: Mapping[str, float]
    output_directory: Path
    evidence_directory: Path
    manifest_path: Path
    write_csv: bool
    write_parquet: bool
    tolerance_usd: float


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HypotheticalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise HypotheticalScenarioError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise HypotheticalScenarioError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise HypotheticalScenarioError(f"{key} must be an integer.")
    return int(value)


def _bounded(value: float, lower: float, upper: float, label: str) -> None:
    if not lower <= value <= upper:
        raise HypotheticalScenarioError(
            f"{label} must be between {lower:g} and {upper:g}."
        )


def load_yaml(path: str | Path) -> dict[str, Any]:
    """Load a UTF-8 YAML mapping."""
    yaml_path = Path(path)
    if not yaml_path.exists():
        raise HypotheticalScenarioError(f"Configuration does not exist: {yaml_path}")
    loaded = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    return _mapping(loaded, str(yaml_path))


def load_settings(config: Mapping[str, Any], root: Path) -> HypotheticalSettings:
    """Validate Section 21 top-level settings."""
    source = _mapping(config.get("source"), "source")
    output = _mapping(config.get("output"), "output")
    validation = _mapping(config.get("validation"), "validation")
    raw_guardrails = _mapping(config.get("guardrails"), "guardrails")
    guardrails: dict[str, float] = {}
    for key, value in raw_guardrails.items():
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HypotheticalScenarioError(f"guardrails.{key} must be numeric.")
        number = float(value)
        if not math.isfinite(number) or number <= 0.0:
            raise HypotheticalScenarioError(
                f"guardrails.{key} must be finite and positive."
            )
        guardrails[str(key)] = number
    model_version = str(config.get("model_version", "section-21-v1")).strip()
    if not model_version:
        raise HypotheticalScenarioError("model_version cannot be empty.")
    tolerance = _number(validation, "reconciliation_tolerance_usd")
    if tolerance < 0.0:
        raise HypotheticalScenarioError(
            "validation.reconciliation_tolerance_usd must be nonnegative."
        )
    return HypotheticalSettings(
        model_version=model_version,
        source=source,
        guardrails=guardrails,
        output_directory=root / str(output.get("directory", "reports/tables")),
        evidence_directory=root
        / str(output.get("evidence_directory", "reports/evidence")),
        manifest_path=root
        / str(
            output.get(
                "manifest",
                "data/manifests/hypothetical_scenario_manifest.csv",
            )
        ),
        write_csv=bool(output.get("write_csv", True)),
        write_parquet=bool(output.get("write_parquet", True)),
        tolerance_usd=tolerance,
    )


def _validate_treasury(
    scenario_name: str,
    treasury: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    shape = str(treasury.get("shape", "")).strip().lower()
    if shape not in {"none", "parallel", "steepening", "flattening", "bucket_vector"}:
        raise HypotheticalScenarioError(
            f"{scenario_name}.treasury.shape is unsupported: {shape}"
        )
    maximum = guardrails["maximum_absolute_treasury_shock_bp"]
    if shape == "parallel":
        _bounded(
            abs(_number(treasury, "parallel_bp")),
            0.0,
            maximum,
            f"{scenario_name}.treasury.parallel_bp",
        )
    elif shape in {"steepening", "flattening"}:
        short = _number(treasury, "short_end_bp")
        long = _number(treasury, "long_end_bp")
        _bounded(abs(short), 0.0, maximum, f"{scenario_name}.treasury.short_end_bp")
        _bounded(abs(long), 0.0, maximum, f"{scenario_name}.treasury.long_end_bp")
        if shape == "steepening" and long < short:
            raise HypotheticalScenarioError(
                f"{scenario_name} steepening requires long_end_bp >= short_end_bp."
            )
        if shape == "flattening" and short < long:
            raise HypotheticalScenarioError(
                f"{scenario_name} flattening requires short_end_bp >= long_end_bp."
            )
    elif shape == "bucket_vector":
        shocks = _mapping(treasury.get("shocks_bp"), f"{scenario_name}.treasury.shocks_bp")
        if not shocks:
            raise HypotheticalScenarioError(
                f"{scenario_name}.treasury.shocks_bp cannot be empty."
            )
        for bucket, value in shocks.items():
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise HypotheticalScenarioError(
                    f"{scenario_name}.treasury.shocks_bp.{bucket} must be numeric."
                )
            _bounded(
                abs(float(value)),
                0.0,
                maximum,
                f"{scenario_name}.treasury.shocks_bp.{bucket}",
            )


def _validate_funding(
    scenario_name: str,
    funding: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    for field in FUNDING_FIELDS:
        if field not in funding:
            raise HypotheticalScenarioError(
                f"{scenario_name}.funding.{field} is required."
            )
    _bounded(
        _number(funding, "sofr_spike_bp"),
        0.0,
        guardrails["maximum_sofr_spike_bp"],
        f"{scenario_name}.funding.sofr_spike_bp",
    )
    _bounded(
        _number(funding, "funding_spread_increase_bp"),
        0.0,
        guardrails["maximum_funding_spread_increase_bp"],
        f"{scenario_name}.funding.funding_spread_increase_bp",
    )
    _bounded(
        _number(funding, "repo_rollover_failure_rate"),
        0.0,
        guardrails["maximum_rollover_failure_rate"],
        f"{scenario_name}.funding.repo_rollover_failure_rate",
    )
    _bounded(
        _number(funding, "lender_withdrawal_rate"),
        0.0,
        guardrails["maximum_lender_withdrawal_rate"],
        f"{scenario_name}.funding.lender_withdrawal_rate",
    )
    horizon = _integer(funding, "refinancing_horizon_hours")
    if horizon <= 0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.funding.refinancing_horizon_hours must be positive."
        )
    for field in (
        "collateral_haircut_increase",
        "collateral_call_rate",
        "concentration_threshold",
        "max_effective_unavailability_rate",
    ):
        _bounded(
            _number(funding, field),
            0.0,
            1.0,
            f"{scenario_name}.funding.{field}",
        )
    for field in ("concentration_multiplier", "funding_dependency_multiplier"):
        if _number(funding, field) < 0.0:
            raise HypotheticalScenarioError(
                f"{scenario_name}.funding.{field} must be nonnegative."
            )


def _validate_haircut(
    scenario_name: str,
    haircut: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    stress_multiplier = _number(haircut, "stress_multiplier")
    if stress_multiplier < 1.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.haircut.stress_multiplier must be at least one."
        )
    _bounded(
        _number(haircut, "additive_haircut_rate"),
        0.0,
        guardrails["maximum_additive_haircut_rate"],
        f"{scenario_name}.haircut.additive_haircut_rate",
    )
    for field in ("bucket_addon_short_rate", "bucket_addon_long_rate"):
        _bounded(
            _number(haircut, field),
            0.0,
            guardrails["maximum_additive_haircut_rate"],
            f"{scenario_name}.haircut.{field}",
        )
    for field in (
        "concentration_threshold",
        "additional_collateral_call_rate",
        "inventory_availability_rate",
        "maximum_haircut_rate",
    ):
        _bounded(
            _number(haircut, field),
            0.0,
            1.0,
            f"{scenario_name}.haircut.{field}",
        )
    if _number(haircut, "maximum_haircut_rate") >= 1.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.haircut.maximum_haircut_rate must be below one."
        )
    if _number(haircut, "concentration_multiplier") < 0.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.haircut.concentration_multiplier must be nonnegative."
        )


def _validate_settlement(
    scenario_name: str,
    settlement: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    for field in SETTLEMENT_FIELDS:
        if field not in settlement:
            raise HypotheticalScenarioError(
                f"{scenario_name}.settlement.{field} is required."
            )
    maximum_multiplier = guardrails["maximum_settlement_fail_multiplier"]
    for field in ("fails_to_receive_multiplier", "fails_to_deliver_multiplier"):
        _bounded(
            _number(settlement, field),
            0.0,
            maximum_multiplier,
            f"{scenario_name}.settlement.{field}",
        )
    for field in (
        "additional_fails_to_receive_rate",
        "additional_fails_to_deliver_rate",
        "persistence_decay",
        "funding_stress_weight",
    ):
        _bounded(
            _number(settlement, field),
            0.0,
            1.0,
            f"{scenario_name}.settlement.{field}",
        )
    if _integer(settlement, "incoming_payment_delay_buckets") < 0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.settlement.incoming_payment_delay_buckets "
            "must be nonnegative."
        )
    if _integer(settlement, "persistence_days") <= 0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.settlement.persistence_days must be positive."
        )
    if _number(settlement, "replacement_liquidity_rate") < 0.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.settlement.replacement_liquidity_rate "
            "must be nonnegative."
        )


def _validate_integrated(
    scenario_name: str,
    integrated: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    _bounded(
        _number(integrated, "concentration_threshold"),
        0.0,
        1.0,
        f"{scenario_name}.integrated.concentration_threshold",
    )
    if _number(integrated, "concentration_multiplier") < 0.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.integrated.concentration_multiplier "
            "must be nonnegative."
        )
    _bounded(
        _number(integrated, "operational_liquidity_buffer_rate"),
        0.0,
        guardrails["maximum_operational_liquidity_buffer_rate"],
        f"{scenario_name}.integrated.operational_liquidity_buffer_rate",
    )


def load_scenarios(
    config: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> tuple[HypotheticalScenario, ...]:
    """Load and validate all required Section 21 hypothetical scenarios."""
    raw_scenarios = config.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise HypotheticalScenarioError("scenarios must be a nonempty list.")
    scenarios: list[HypotheticalScenario] = []
    for raw in raw_scenarios:
        row = _mapping(raw, "scenario")
        name = str(row.get("name", "")).strip()
        label = str(row.get("label", "")).strip()
        family = str(row.get("family", "")).strip()
        severity = str(row.get("severity", "")).strip()
        display_order = _integer(row, "display_order")
        if not name or not label or not family or not severity:
            raise HypotheticalScenarioError(
                "Each scenario requires name, label, family, and severity."
            )
        if display_order <= 0:
            raise HypotheticalScenarioError("display_order must be positive.")
        treasury = _mapping(row.get("treasury"), f"{name}.treasury")
        funding = _mapping(row.get("funding"), f"{name}.funding")
        haircut = _mapping(row.get("haircut"), f"{name}.haircut")
        settlement = _mapping(row.get("settlement"), f"{name}.settlement")
        integrated = _mapping(row.get("integrated"), f"{name}.integrated")
        _validate_treasury(name, treasury, guardrails)
        _validate_funding(name, funding, guardrails)
        _validate_haircut(name, haircut, guardrails)
        _validate_settlement(name, settlement, guardrails)
        _validate_integrated(name, integrated, guardrails)
        scenarios.append(
            HypotheticalScenario(
                name=name,
                label=label,
                family=family,
                severity=severity,
                display_order=display_order,
                treasury=treasury,
                funding=funding,
                haircut=haircut,
                settlement=settlement,
                integrated=integrated,
            )
        )
    names = [scenario.name for scenario in scenarios]
    orders = [scenario.display_order for scenario in scenarios]
    if len(set(names)) != len(names):
        raise HypotheticalScenarioError("Scenario names must be unique.")
    if len(set(orders)) != len(orders):
        raise HypotheticalScenarioError("Scenario display_order values must be unique.")
    missing_names = sorted(REQUIRED_SCENARIOS - set(names))
    if missing_names:
        raise HypotheticalScenarioError(
            f"Required hypothetical scenarios are missing: {missing_names}"
        )
    families = {scenario.family for scenario in scenarios}
    missing_families = sorted(REQUIRED_FAMILIES - families)
    if missing_families:
        raise HypotheticalScenarioError(
            f"Required hypothetical scenario families are missing: {missing_families}"
        )
    return tuple(sorted(scenarios, key=lambda item: item.display_order))


def _maturity_buckets(
    treasury_config: Mapping[str, Any],
) -> list[tuple[str, float]]:
    raw = _mapping(treasury_config.get("maturity_buckets"), "maturity_buckets")
    buckets: list[tuple[str, float]] = []
    for name, assumptions in raw.items():
        row = _mapping(assumptions, f"maturity_buckets.{name}")
        buckets.append((str(name), _number(row, "midpoint_years")))
    if not buckets:
        raise HypotheticalScenarioError("Treasury maturity buckets cannot be empty.")
    return sorted(buckets, key=lambda item: item[1])


def expand_treasury_shock(
    scenario: HypotheticalScenario,
    treasury_config: Mapping[str, Any],
) -> dict[str, float]:
    """Expand parallel and curve shapes into a complete maturity-bucket vector."""
    buckets = _maturity_buckets(treasury_config)
    shape = str(scenario.treasury["shape"]).lower()
    if shape == "none":
        return {}
    if shape == "parallel":
        shock = float(scenario.treasury["parallel_bp"])
        return {name: shock for name, _ in buckets}
    if shape == "bucket_vector":
        raw = _mapping(
            scenario.treasury.get("shocks_bp"),
            f"{scenario.name}.treasury.shocks_bp",
        )
        unknown = sorted(set(raw) - {name for name, _ in buckets})
        if unknown:
            raise HypotheticalScenarioError(
                f"{scenario.name} has unknown Treasury buckets: {unknown}"
            )
        return {name: float(raw.get(name, 0.0)) for name, _ in buckets}
    short = float(scenario.treasury["short_end_bp"])
    long = float(scenario.treasury["long_end_bp"])
    minimum = buckets[0][1]
    maximum = buckets[-1][1]
    span = maximum - minimum
    vector: dict[str, float] = {}
    for name, midpoint in buckets:
        weight = 0.0 if span <= 0.0 else (midpoint - minimum) / span
        vector[name] = short + weight * (long - short)
    return vector


def build_treasury_scenarios(
    scenarios: Sequence[HypotheticalScenario],
    treasury_config: Mapping[str, Any],
) -> list[dict[str, Any]]:
    """Build Section 15 bucket-vector scenarios for every nonzero yield shock."""
    result: list[dict[str, Any]] = []
    for scenario in scenarios:
        vector = expand_treasury_shock(scenario, treasury_config)
        if not vector:
            continue
        result.append(
            {
                "name": scenario.name,
                "enabled": True,
                "family": scenario.family,
                "type": "bucket_vector",
                "shocks_bp": vector,
            }
        )
    return result


def _base_control(
    base_config: Mapping[str, Any],
    label: str,
) -> dict[str, Any]:
    raw = base_config.get("scenarios")
    if not isinstance(raw, list) or not raw:
        raise HypotheticalScenarioError(f"{label}.scenarios must be nonempty.")
    for item in raw:
        scenario = _mapping(item, f"{label}.scenario")
        if str(scenario.get("name", "")).strip() == "control":
            control = deepcopy(scenario)
            control["severity_rank"] = 0
            control["enabled"] = True
            return control
    raise HypotheticalScenarioError(f"{label} does not contain a control scenario.")


def build_funding_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
) -> dict[str, Any]:
    """Create a control-plus-target Section 16 configuration."""
    config = deepcopy(dict(base_config))
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        **{field: scenario.funding[field] for field in FUNDING_FIELDS},
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "funding"), target]
    return config


def _linear_bucket_addons(
    bucket_names: Sequence[str],
    short_rate: float,
    long_rate: float,
) -> dict[str, float]:
    if not bucket_names:
        raise HypotheticalScenarioError("Haircut maturity buckets cannot be empty.")
    if len(bucket_names) == 1:
        return {str(bucket_names[0]): float(short_rate)}
    denominator = float(len(bucket_names) - 1)
    return {
        str(name): short_rate + (index / denominator) * (long_rate - short_rate)
        for index, name in enumerate(bucket_names)
    }


def build_haircut_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
) -> dict[str, Any]:
    """Create a control-plus-target Section 17 configuration."""
    config = deepcopy(dict(base_config))
    raw_buckets = _mapping(base_config.get("maturity_buckets"), "maturity_buckets")
    bucket_names = [str(name) for name in raw_buckets]
    haircut = scenario.haircut
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        "stress_multiplier": haircut["stress_multiplier"],
        "additive_haircut_rate": haircut["additive_haircut_rate"],
        "bucket_addons": _linear_bucket_addons(
            bucket_names,
            float(haircut["bucket_addon_short_rate"]),
            float(haircut["bucket_addon_long_rate"]),
        ),
        "concentration_threshold": haircut["concentration_threshold"],
        "concentration_multiplier": haircut["concentration_multiplier"],
        "additional_collateral_call_rate": haircut[
            "additional_collateral_call_rate"
        ],
        "inventory_availability_rate": haircut["inventory_availability_rate"],
        "maximum_haircut_rate": haircut["maximum_haircut_rate"],
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "haircut"), target]
    return config


def build_settlement_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
) -> dict[str, Any]:
    """Create a control-plus-target Section 18 configuration."""
    config = deepcopy(dict(base_config))
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        **{field: scenario.settlement[field] for field in SETTLEMENT_FIELDS},
        "funding_scenario_name": scenario.name,
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "settlement"), target]
    return config


def build_integrated_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
    treasury_active: bool,
) -> dict[str, Any]:
    """Create a control-plus-target Section 19 configuration."""
    config = deepcopy(dict(base_config))
    integrated = scenario.integrated
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        "funding_scenario_name": scenario.name,
        "haircut_scenario_name": scenario.name,
        "treasury_scenario_name": scenario.name if treasury_active else "NONE",
        "settlement_fail_scenario_name": scenario.name,
        "concentration_threshold": integrated["concentration_threshold"],
        "concentration_multiplier": integrated["concentration_multiplier"],
        "operational_liquidity_buffer_rate": integrated[
            "operational_liquidity_buffer_rate"
        ],
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "integrated"), target]
    return config


def scenario_catalog_frame(
    scenarios: Sequence[HypotheticalScenario],
    treasury_config: Mapping[str, Any],
) -> pd.DataFrame:
    """Return a flat, audit-ready scenario catalog."""
    rows: list[dict[str, object]] = []
    for scenario in scenarios:
        vector = expand_treasury_shock(scenario, treasury_config)
        rows.append(
            {
                "scenario_name": scenario.name,
                "scenario_label": scenario.label,
                "scenario_family": scenario.family,
                "severity": scenario.severity,
                "display_order": scenario.display_order,
                "treasury_shape": str(scenario.treasury["shape"]),
                "maximum_absolute_treasury_shock_bp": (
                    max(abs(value) for value in vector.values()) if vector else 0.0
                ),
                "sofr_spike_bp": float(scenario.funding["sofr_spike_bp"]),
                "repo_rollover_failure_rate": float(
                    scenario.funding["repo_rollover_failure_rate"]
                ),
                "additive_haircut_rate": float(
                    scenario.haircut["additive_haircut_rate"]
                ),
                "fails_to_receive_multiplier": float(
                    scenario.settlement["fails_to_receive_multiplier"]
                ),
                "fails_to_deliver_multiplier": float(
                    scenario.settlement["fails_to_deliver_multiplier"]
                ),
                "operational_liquidity_buffer_rate": float(
                    scenario.integrated["operational_liquidity_buffer_rate"]
                ),
                "value_class": "hypothetical_assumptions_on_synthetic_members",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    result = pd.DataFrame.from_records(rows)
    result_any: Any = result
    ordered_any: Any = result_any.sort_values(
        by=["display_order", "scenario_name"],
        kind="stable",
    )
    reset_any: Any = ordered_any.reset_index(drop=True)
    return cast(pd.DataFrame, reset_any)


def treasury_shock_frame(
    scenarios: Sequence[HypotheticalScenario],
    treasury_config: Mapping[str, Any],
) -> pd.DataFrame:
    """Return the complete scenario-by-maturity Treasury shock matrix."""
    rows: list[dict[str, object]] = []
    for scenario in scenarios:
        for bucket, shock in expand_treasury_shock(
            scenario,
            treasury_config,
        ).items():
            rows.append(
                {
                    "scenario_name": scenario.name,
                    "scenario_family": scenario.family,
                    "display_order": scenario.display_order,
                    "maturity_bucket": bucket,
                    "yield_shock_bp": shock,
                    "value_class": "hypothetical_assumption",
                }
            )
    result = pd.DataFrame.from_records(rows)
    if result.empty:
        return pd.DataFrame(
            columns=[
                "scenario_name",
                "scenario_family",
                "display_order",
                "maturity_bucket",
                "yield_shock_bp",
                "value_class",
            ]
        )
    result_any: Any = result
    ordered_any: Any = result_any.sort_values(
        by=["display_order", "maturity_bucket"],
        kind="stable",
    )
    reset_any: Any = ordered_any.reset_index(drop=True)
    return cast(pd.DataFrame, reset_any)


__all__ = [
    "HypotheticalScenario",
    "HypotheticalScenarioError",
    "HypotheticalSettings",
    "REQUIRED_FAMILIES",
    "REQUIRED_SCENARIOS",
    "build_funding_config",
    "build_haircut_config",
    "build_integrated_config",
    "build_settlement_config",
    "build_treasury_scenarios",
    "expand_treasury_shock",
    "load_scenarios",
    "load_settings",
    "load_yaml",
    "scenario_catalog_frame",
    "treasury_shock_frame",
]
'@
    Write-Utf8NoBom -Path $Target -Content $Content
    Write-Pass "Wrote src/ficc_liquidity/scenarios/hypothetical_scenarios.py"

    $Target = Join-Path $RepoRoot "scripts\run_hypothetical_scenarios.py"
    $Content = @'
"""Run Phase VI, Section 21 hypothetical scenarios."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections.abc import Mapping
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.scenarios.hypothetical_scenarios import (  # noqa: E402
    HypotheticalScenario,
    HypotheticalScenarioError,
    build_funding_config,
    build_haircut_config,
    build_integrated_config,
    build_settlement_config,
    build_treasury_scenarios,
    expand_treasury_shock,
    load_scenarios,
    load_settings,
    load_yaml,
    scenario_catalog_frame,
    treasury_shock_frame,
)
from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    run_model as run_haircut_model,
)
from ficc_liquidity.stress.integrated_stress import (  # noqa: E402
    dataframe_digest,
    read_table,
    run_integrated_stress,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    run_model as run_funding_model,
)
from ficc_liquidity.stress.settlement_fail_stress import (  # noqa: E402
    run_model as run_settlement_model,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    TreasuryYieldShockModel,
    load_stress_config,
)


FUNDING_ACCOUNTING_CHECKS: frozenset[str] = frozenset(
    {
        "scenario_cashflow_rows_complete",
        "member_scenario_rows_complete",
        "scenario_summary_complete",
        "unique_scenario_member_buckets",
        "nonnegative_stress_components",
        "sofr_rate_identity",
        "all_in_funding_rate_identity",
        "rollover_failure_bounded_by_roll_amount",
        "funding_stress_decomposition_identity",
        "stressed_liquidity_need_identity",
        "stressed_need_not_below_baseline",
        "stressed_headroom_identity",
        "stressed_shortfall_identity",
        "synthetic_members_only",
        "deterministic_reproduction",
    }
)

SETTLEMENT_ACCOUNTING_CHECKS: frozenset[str] = frozenset(
    {
        "complete_cashflow_matrix",
        "complete_member_matrix",
        "unique_cashflow_keys",
        "finite_nonnegative_stress_amounts",
        "fails_to_receive_bounds",
        "fails_to_deliver_bounds",
        "replacement_liquidity_identity",
        "delayed_payment_recovery_bounds",
        "combined_stress_identity",
        "liquidity_headroom_identity",
        "zero_shock_control",
        "severity_monotonicity",
        "scenario_aggregation_complete",
        "synthetic_identity_controls",
    }
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the controlled Section 21 hypothetical scenario framework."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "hypothetical_scenarios.yaml",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Run three representative scenarios instead of the complete library.",
    )
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HypotheticalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _candidate_list(source: Mapping[str, Any], key: str) -> list[str]:
    raw = source.get(key)
    if not isinstance(raw, list) or not raw:
        raise HypotheticalScenarioError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def discover_input(candidates: list[str]) -> Path:
    for candidate in candidates:
        path = ROOT / candidate
        if path.exists():
            return path
    raise HypotheticalScenarioError(
        f"No controlled input exists among: {candidates}"
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_frame(
    frame: pd.DataFrame,
    stem: Path,
    *,
    write_csv: bool,
    write_parquet: bool,
) -> list[Path]:
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


def _required_checks_pass(
    checks: Mapping[str, bool],
    required: frozenset[str] | None = None,
) -> bool:
    selected = set(checks) if required is None else set(required)
    missing = selected - set(checks)
    if missing:
        raise HypotheticalScenarioError(
            f"Required component checks are missing: {sorted(missing)}"
        )
    return all(bool(checks[name]) for name in selected)


def _target_rows(frame: pd.DataFrame, scenario_name: str) -> pd.DataFrame:
    selected = frame.loc[
        frame["scenario_name"].astype(str).eq(scenario_name)
    ].copy()
    if selected.empty:
        raise HypotheticalScenarioError(
            f"Component output is missing target scenario: {scenario_name}"
        )
    return selected


def _annotate(
    frame: pd.DataFrame,
    scenario: HypotheticalScenario,
) -> pd.DataFrame:
    result = frame.copy(deep=True)
    result["scenario_label"] = scenario.label
    result["scenario_family"] = scenario.family
    result["scenario_severity"] = scenario.severity
    result["display_order"] = scenario.display_order
    result["hypothetical_value_class"] = (
        "hypothetical_assumptions_on_synthetic_members"
    )
    result["actual_ficc_participant"] = False
    result["participant_level_inference"] = False
    return result


def _check_rows(
    scenario: HypotheticalScenario,
    component: str,
    checks: Mapping[str, bool],
    required: frozenset[str] | None,
) -> list[dict[str, object]]:
    required_names = set(checks) if required is None else set(required)
    return [
        {
            "scenario_name": scenario.name,
            "display_order": scenario.display_order,
            "component": component,
            "check_name": name,
            "required_for_section21": name in required_names,
            "passed": bool(value),
        }
        for name, value in sorted(checks.items())
    ]


def _manifest(
    path: Path,
    artifacts: list[tuple[Path, str, int | None]],
) -> None:
    records: list[dict[str, object]] = []
    generated_at = datetime.now(UTC).isoformat()
    for artifact, value_class, row_count in artifacts:
        records.append(
            {
                "section": 21,
                "artifact_path": artifact.relative_to(ROOT).as_posix(),
                "artifact_name": artifact.name,
                "value_class": value_class,
                "row_count": "" if row_count is None else row_count,
                "sha256": _sha256(artifact),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(records).to_csv(path, index=False)


def run() -> int:
    args = parse_args()
    config = load_yaml(args.config)
    settings = load_settings(config, ROOT)
    scenarios = load_scenarios(config, settings.guardrails)

    if args.smoke:
        smoke_names = {
            "moderate_stress",
            "curve_steepening",
            "combined_systemic_stress",
        }
        scenarios = tuple(
            scenario for scenario in scenarios if scenario.name in smoke_names
        )

    source = settings.source
    baseline_cashflow_path = discover_input(
        _candidate_list(source, "baseline_cashflow_candidates")
    )
    baseline_summary_path = discover_input(
        _candidate_list(source, "baseline_summary_candidates")
    )
    member_path = discover_input(
        _candidate_list(source, "member_profile_candidates")
    )
    treasury_position_path = discover_input(
        _candidate_list(source, "treasury_position_candidates")
    )

    baseline_cashflows = read_table(baseline_cashflow_path)
    baseline_summary = read_table(baseline_summary_path)
    members = read_table(member_path)
    treasury_positions = read_table(treasury_position_path)

    treasury_config_path = ROOT / str(source["treasury_config"])
    funding_config_path = ROOT / str(source["funding_config"])
    haircut_config_path = ROOT / str(source["haircut_config"])
    settlement_config_path = ROOT / str(source["settlement_config"])
    integrated_config_path = ROOT / str(source["integrated_config"])

    treasury_config = load_stress_config(treasury_config_path)
    treasury_input = treasury_config.get("input")
    if isinstance(treasury_input, dict):
        treasury_input["required_member_id_pattern"] = r"^SYN-MBR-[0-9]{4}$"
    funding_base = load_yaml(funding_config_path)
    haircut_base = load_yaml(haircut_config_path)
    settlement_base = load_yaml(settlement_config_path)
    integrated_base = load_yaml(integrated_config_path)

    catalog = scenario_catalog_frame(scenarios, treasury_config)
    treasury_shocks = treasury_shock_frame(scenarios, treasury_config)
    treasury_scenarios = build_treasury_scenarios(scenarios, treasury_config)
    if not treasury_scenarios:
        raise HypotheticalScenarioError(
            "At least one hypothetical Treasury scenario is required."
        )
    treasury_result = TreasuryYieldShockModel(treasury_config).run(
        treasury_positions,
        treasury_scenarios,
    )
    treasury_summary = treasury_result.member_summary

    member_outputs: list[pd.DataFrame] = []
    summary_outputs: list[pd.DataFrame] = []
    control_outputs: list[pd.DataFrame] = []
    component_rows: list[dict[str, object]] = []
    check_rows: list[dict[str, object]] = []
    integrated_check_sets: dict[str, dict[str, bool]] = {}

    for scenario in scenarios:
        funding_config = build_funding_config(
            funding_base,
            scenario,
            settings.model_version,
        )
        (
            funding_cashflows,
            funding_members,
            funding_summary,
            funding_validation,
        ) = run_funding_model(
            baseline_cashflows,
            members,
            funding_config,
        )
        funding_checks = dict(funding_validation.checks)
        funding_required_pass = _required_checks_pass(
            funding_checks,
            FUNDING_ACCOUNTING_CHECKS,
        )
        check_rows.extend(
            _check_rows(
                scenario,
                "repo_funding",
                funding_checks,
                FUNDING_ACCOUNTING_CHECKS,
            )
        )

        haircut_config = build_haircut_config(
            haircut_base,
            scenario,
            settings.model_version,
        )
        haircut_result = run_haircut_model(
            members,
            baseline_cashflows,
            haircut_config,
        )
        haircut_checks = dict(haircut_result.checks)
        haircut_required_pass = _required_checks_pass(haircut_checks)
        check_rows.extend(
            _check_rows(
                scenario,
                "collateral_haircut",
                haircut_checks,
                None,
            )
        )

        settlement_config = build_settlement_config(
            settlement_base,
            scenario,
            settings.model_version,
        )
        settlement_result = run_settlement_model(
            baseline_cashflows,
            members,
            funding_cashflows,
            settlement_config,
        )
        settlement_checks = dict(settlement_result.checks)
        settlement_required_pass = _required_checks_pass(
            settlement_checks,
            SETTLEMENT_ACCOUNTING_CHECKS,
        )
        check_rows.extend(
            _check_rows(
                scenario,
                "settlement_fail",
                settlement_checks,
                SETTLEMENT_ACCOUNTING_CHECKS,
            )
        )

        treasury_active = bool(
            expand_treasury_shock(scenario, treasury_config)
        )
        integrated_config = build_integrated_config(
            integrated_base,
            scenario,
            settings.model_version,
            treasury_active,
        )
        integrated_result = run_integrated_stress(
            baseline_summary,
            funding_members,
            haircut_result.member_summary,
            treasury_summary,
            settlement_result.cashflows,
            integrated_config,
        )
        integrated_checks = dict(integrated_result.checks)
        integrated_check_sets[scenario.name] = integrated_checks
        integrated_required_pass = _required_checks_pass(integrated_checks)
        check_rows.extend(
            _check_rows(
                scenario,
                "integrated_stress",
                integrated_checks,
                None,
            )
        )

        target_members = _annotate(
            _target_rows(integrated_result.member_results, scenario.name),
            scenario,
        )
        target_summary = _annotate(
            _target_rows(integrated_result.scenario_summary, scenario.name),
            scenario,
        )
        target_controls = _annotate(
            _target_rows(
                integrated_result.double_count_controls,
                scenario.name,
            ),
            scenario,
        )
        member_outputs.append(target_members)
        summary_outputs.append(target_summary)
        control_outputs.append(target_controls)

        funding_target = _target_rows(funding_summary, scenario.name).iloc[0]
        haircut_target = _target_rows(
            haircut_result.scenario_summary,
            scenario.name,
        ).iloc[0]
        settlement_target = _target_rows(
            settlement_result.scenario_summary,
            scenario.name,
        ).iloc[0]
        integrated_target = target_summary.iloc[0]
        component_rows.append(
            {
                "scenario_name": scenario.name,
                "display_order": scenario.display_order,
                "scenario_family": scenario.family,
                "treasury_active": treasury_active,
                "maximum_absolute_treasury_shock_bp": (
                    max(
                        abs(value)
                        for value in expand_treasury_shock(
                            scenario,
                            treasury_config,
                        ).values()
                    )
                    if treasury_active
                    else 0.0
                ),
                "funding_stress_outflow_usd": float(
                    funding_target[
                        "incremental_repo_funding_stress_outflow_usd"
                    ]
                ),
                "haircut_requirement_usd": float(
                    haircut_target[
                        "additional_collateral_requirement_total_usd"
                    ]
                ),
                "settlement_stress_usd": float(
                    settlement_target[
                        "total_incremental_combined_stress_usd"
                    ]
                ),
                "stressed_liquidity_requirement_usd": float(
                    integrated_target[
                        "total_stressed_liquidity_requirement_usd"
                    ]
                ),
                "aggregate_aqlr_usd": float(
                    integrated_target["total_available_qualified_liquid_resources_usd"]
                ),
                "aggregate_lcr": float(
                    integrated_target["aggregate_liquidity_coverage_ratio"]
                ),
                "funding_required_checks_pass": funding_required_pass,
                "haircut_required_checks_pass": haircut_required_pass,
                "settlement_required_checks_pass": settlement_required_pass,
                "integrated_checks_pass": integrated_required_pass,
            }
        )

    member_results = pd.concat(member_outputs, ignore_index=True)
    scenario_summary = pd.concat(summary_outputs, ignore_index=True)
    double_count_controls = pd.concat(control_outputs, ignore_index=True)
    component_summary = pd.DataFrame.from_records(component_rows)
    component_checks = pd.DataFrame.from_records(check_rows)

    for frame, columns in (
        (member_results, ["display_order", "member_id"]),
        (scenario_summary, ["display_order"]),
        (double_count_controls, ["display_order", "member_id"]),
        (component_summary, ["display_order"]),
        (component_checks, ["display_order", "component", "check_name"]),
    ):
        frame.sort_values(columns, kind="stable", inplace=True)
        frame.reset_index(drop=True, inplace=True)

    tolerance = settings.tolerance_usd
    expected_requirement = member_results[
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

    catalog_repeat = scenario_catalog_frame(scenarios, treasury_config)
    treasury_repeat = treasury_shock_frame(scenarios, treasury_config)
    checks = {
        "all_required_scenarios_created": len(catalog) == len(scenarios),
        "hypothetical_treasury_matrix_created": not treasury_shocks.empty,
        "scenario_definitions_deterministic": (
            catalog.equals(catalog_repeat)
            and treasury_shocks.equals(treasury_repeat)
        ),
        "all_component_required_checks_pass": bool(
            component_summary[
                [
                    "funding_required_checks_pass",
                    "haircut_required_checks_pass",
                    "settlement_required_checks_pass",
                    "integrated_checks_pass",
                ]
            ]
            .astype(bool)
            .all()
            .all()
        ),
        "all_integrated_checks_pass": all(
            all(values.values()) for values in integrated_check_sets.values()
        ),
        "stressed_requirement_identity": bool(
            (
                expected_requirement
                - member_results["stressed_liquidity_requirement_usd"]
            )
            .abs()
            .le(tolerance)
            .all()
        ),
        "double_count_controls_pass": bool(
            double_count_controls["double_count_control_pass"]
            .astype(bool)
            .all()
        ),
        "synthetic_members_only": bool(
            not member_results["actual_ficc_participant"].astype(bool).any()
            and not member_results["participant_level_inference"]
            .astype(bool)
            .any()
        ),
        "unique_scenario_member_keys": not bool(
            member_results.duplicated(
                ["scenario_name", "member_id"]
            ).any()
        ),
    }

    settings.output_directory.mkdir(parents=True, exist_ok=True)
    settings.evidence_directory.mkdir(parents=True, exist_ok=True)
    settings.manifest_path.parent.mkdir(parents=True, exist_ok=True)

    frame_map = {
        "hypothetical_scenario_catalog": catalog,
        "hypothetical_treasury_shocks": treasury_shocks,
        "hypothetical_component_summary": component_summary,
        "hypothetical_component_checks": component_checks,
        "hypothetical_scenario_member_results": member_results,
        "hypothetical_scenario_summary": scenario_summary,
        "hypothetical_scenario_double_count_controls": double_count_controls,
    }
    output_files: list[Path] = []
    artifact_records: list[tuple[Path, str, int | None]] = []
    for name, frame in frame_map.items():
        written = _write_frame(
            frame,
            settings.output_directory / name,
            write_csv=settings.write_csv,
            write_parquet=settings.write_parquet,
        )
        output_files.extend(written)
        value_class = (
            "hypothetical_assumption"
            if name in {
                "hypothetical_scenario_catalog",
                "hypothetical_treasury_shocks",
            }
            else "modeled_synthetic_result"
        )
        artifact_records.extend(
            (path, value_class, len(frame)) for path in written
        )

    evidence = {
        "section": 21,
        "model_version": settings.model_version,
        "generated_at_utc": datetime.now(UTC).isoformat(),
        "smoke_mode": bool(args.smoke),
        "scenario_count": len(scenarios),
        "member_result_rows": len(member_results),
        "catalog_digest": dataframe_digest(catalog),
        "member_result_digest": dataframe_digest(member_results),
        "checks": checks,
        "actual_ficc_participant": False,
        "participant_level_inference": False,
        "status": "PASS" if all(checks.values()) else "FAIL",
    }
    evidence_json = (
        settings.evidence_directory
        / (
            "section21_hypothetical_scenarios_smoke.json"
            if args.smoke
            else "section21_hypothetical_scenarios.json"
        )
    )
    evidence_json.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    evidence_md = evidence_json.with_suffix(".md")
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 21 — Hypothetical Scenarios",
                "",
                f"- Status: **{evidence['status']}**",
                f"- Scenario count: {len(scenarios)}",
                f"- Member-result rows: {len(member_results)}",
                f"- Smoke mode: {bool(args.smoke)}",
                "",
                "## Validation checks",
                "",
                *[
                    f"- {'PASS' if value else 'FAIL'} — {name}"
                    for name, value in checks.items()
                ],
                "",
                "All member-level observations are fictional synthetic records.",
                "No result identifies or infers an actual FICC participant.",
                "",
            ]
        ),
        encoding="utf-8",
    )
    artifact_records.extend(
        [
            (args.config.resolve(), "hypothetical_assumption", None),
            (evidence_json, "validation_evidence", None),
            (evidence_md, "validation_evidence", None),
        ]
    )
    _manifest(settings.manifest_path, artifact_records)

    print(f"Section 21 status: {evidence['status']}")
    print(f"Scenarios completed: {len(scenarios)}")
    print(f"Manifest: {settings.manifest_path.relative_to(ROOT)}")
    if not all(checks.values()):
        failed = [name for name, value in checks.items() if not value]
        raise HypotheticalScenarioError(
            f"Section 21 validation failed: {failed}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
'@
    Write-Utf8NoBom -Path $Target -Content $Content
    Write-Pass "Wrote scripts/run_hypothetical_scenarios.py"

    $Target = Join-Path $RepoRoot "tests\test_hypothetical_scenarios.py"
    $Content = @'
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.scenarios.hypothetical_scenarios import (
    HypotheticalScenarioError,
    REQUIRED_FAMILIES,
    REQUIRED_SCENARIOS,
    build_funding_config,
    build_haircut_config,
    build_integrated_config,
    build_settlement_config,
    build_treasury_scenarios,
    expand_treasury_shock,
    load_scenarios,
    load_settings,
    scenario_catalog_frame,
    treasury_shock_frame,
)


ROOT = Path(__file__).resolve().parents[1]


def _config() -> dict[str, Any]:
    path = ROOT / "configs" / "hypothetical_scenarios.yaml"
    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    return cast(dict[str, Any], loaded)


def _treasury_config() -> dict[str, Any]:
    return {
        "maturity_buckets": {
            "bills_0_1y": {"midpoint_years": 0.5},
            "notes_1_3y": {"midpoint_years": 2.0},
            "notes_3_7y": {"midpoint_years": 5.0},
            "notes_7_10y": {"midpoint_years": 8.5},
            "bonds_10_30y": {"midpoint_years": 20.0},
            "strips_30y_plus": {"midpoint_years": 32.0},
        }
    }


def _funding_base() -> dict[str, Any]:
    return {
        "model_version": "section-16-v1",
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "sofr_spike_bp": 0.0,
                "funding_spread_increase_bp": 0.0,
                "repo_rollover_failure_rate": 0.0,
                "lender_withdrawal_rate": 0.0,
                "refinancing_horizon_hours": 48,
                "collateral_haircut_increase": 0.0,
                "collateral_call_rate": 0.0,
                "concentration_threshold": 0.25,
                "concentration_multiplier": 0.0,
                "funding_dependency_multiplier": 0.0,
                "max_effective_unavailability_rate": 0.0,
            }
        ],
    }


def _haircut_base() -> dict[str, Any]:
    return {
        "model_version": "section-17-v1",
        "maturity_buckets": {
            "short": {
                "source_columns": ["short_usd"],
                "base_haircut_rate": 0.01,
                "eligibility_factor": 1.0,
            },
            "medium": {
                "source_columns": ["medium_usd"],
                "base_haircut_rate": 0.03,
                "eligibility_factor": 0.98,
            },
            "long": {
                "source_columns": ["long_usd"],
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
                "bucket_addons": {"short": 0.0, "medium": 0.0, "long": 0.0},
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "additional_collateral_call_rate": 0.0,
                "inventory_availability_rate": 1.0,
                "maximum_haircut_rate": 0.50,
            }
        ],
    }


def _settlement_base() -> dict[str, Any]:
    return {
        "model_version": "section-18-v1",
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "fails_to_receive_multiplier": 0.0,
                "fails_to_deliver_multiplier": 0.0,
                "additional_fails_to_receive_rate": 0.0,
                "additional_fails_to_deliver_rate": 0.0,
                "incoming_payment_delay_buckets": 0,
                "replacement_liquidity_rate": 0.0,
                "persistence_days": 1,
                "persistence_decay": 0.0,
                "funding_scenario_name": "control",
                "funding_stress_weight": 0.0,
            }
        ],
    }


def _integrated_base() -> dict[str, Any]:
    return {
        "model_version": "section-19-v1",
        "scenarios": [
            {
                "name": "control",
                "enabled": True,
                "severity_rank": 0,
                "funding_scenario_name": "control",
                "haircut_scenario_name": "control",
                "treasury_scenario_name": "NONE",
                "settlement_fail_scenario_name": "control",
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "operational_liquidity_buffer_rate": 0.0,
            }
        ],
    }


def _scenarios() -> tuple[Any, ...]:
    config = _config()
    settings = load_settings(config, Path("."))
    return load_scenarios(config, settings.guardrails)


def test_required_scenarios_and_families_are_complete() -> None:
    scenarios = _scenarios()
    assert {item.name for item in scenarios} == set(REQUIRED_SCENARIOS)
    assert REQUIRED_FAMILIES <= {item.family for item in scenarios}
    assert [item.display_order for item in scenarios] == list(range(1, 12))


def test_parallel_treasury_shock_expands_to_all_buckets() -> None:
    scenario = next(item for item in _scenarios() if item.name == "parallel_treasury_shock")
    vector = expand_treasury_shock(scenario, _treasury_config())
    assert len(vector) == 6
    assert set(vector.values()) == {150.0}


def test_curve_shapes_have_required_direction() -> None:
    scenarios = {item.name: item for item in _scenarios()}
    steep = list(expand_treasury_shock(scenarios["curve_steepening"], _treasury_config()).values())
    flat = list(expand_treasury_shock(scenarios["curve_flattening"], _treasury_config()).values())
    assert steep == sorted(steep)
    assert flat == sorted(flat, reverse=True)


def test_treasury_builder_excludes_none_shapes() -> None:
    built = build_treasury_scenarios(_scenarios(), _treasury_config())
    names = {row["name"] for row in built}
    assert "sofr_spike" not in names
    assert "parallel_treasury_shock" in names
    assert "combined_systemic_stress" in names


def test_component_builders_create_control_and_target() -> None:
    scenario = next(item for item in _scenarios() if item.name == "moderate_stress")
    funding = build_funding_config(_funding_base(), scenario, "section-21-test")
    haircut = build_haircut_config(_haircut_base(), scenario, "section-21-test")
    settlement = build_settlement_config(_settlement_base(), scenario, "section-21-test")
    integrated = build_integrated_config(
        _integrated_base(),
        scenario,
        "section-21-test",
        treasury_active=True,
    )

    assert [row["name"] for row in funding["scenarios"]] == ["control", "moderate_stress"]
    assert funding["scenarios"][1]["repo_rollover_failure_rate"] == pytest.approx(0.10)
    assert list(haircut["scenarios"][1]["bucket_addons"].values()) == pytest.approx(
        [0.0, 0.0075, 0.015]
    )
    assert settlement["scenarios"][1]["funding_scenario_name"] == "moderate_stress"
    assert integrated["scenarios"][1]["treasury_scenario_name"] == "moderate_stress"


def test_integrated_builder_uses_none_for_no_yield_shock() -> None:
    scenario = next(item for item in _scenarios() if item.name == "sofr_spike")
    built = build_integrated_config(
        _integrated_base(),
        scenario,
        "section-21-test",
        treasury_active=False,
    )
    assert built["scenarios"][1]["treasury_scenario_name"] == "NONE"


def test_catalog_and_treasury_frames_are_ordered() -> None:
    scenarios = _scenarios()
    catalog = scenario_catalog_frame(scenarios, _treasury_config())
    shocks = treasury_shock_frame(scenarios, _treasury_config())
    assert isinstance(catalog, pd.DataFrame)
    assert catalog["display_order"].tolist() == list(range(1, 12))
    assert not catalog["actual_ficc_participant"].any()
    assert shocks["display_order"].is_monotonic_increasing


def test_guardrail_violation_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["funding"]["sofr_spike_bp"] = 999.0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="sofr_spike_bp"):
        load_scenarios(config, settings.guardrails)


def test_duplicate_display_order_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[1]["display_order"] = scenarios[0]["display_order"]
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="display_order"):
        load_scenarios(config, settings.guardrails)


def test_missing_required_scenario_is_rejected() -> None:
    config = deepcopy(_config())
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    config["scenarios"] = [
        row for row in scenarios if row["name"] != "combined_systemic_stress"
    ]
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="missing"):
        load_scenarios(config, settings.guardrails)


def test_settings_reject_nonpositive_guardrail() -> None:
    config = _config()
    guardrails = cast(dict[str, Any], config["guardrails"])
    guardrails["maximum_sofr_spike_bp"] = 0.0
    with pytest.raises(HypotheticalScenarioError, match="finite and positive"):
        load_settings(config, Path("."))


def test_settings_reject_negative_tolerance() -> None:
    config = _config()
    validation = cast(dict[str, Any], config["validation"])
    validation["reconciliation_tolerance_usd"] = -1.0
    with pytest.raises(HypotheticalScenarioError, match="must be nonnegative"):
        load_settings(config, Path("."))


def test_unsupported_treasury_shape_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["treasury"]["shape"] = "twist"
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="unsupported"):
        load_scenarios(config, settings.guardrails)


def test_invalid_curve_direction_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    steepening = next(row for row in scenarios if row["name"] == "curve_steepening")
    steepening["treasury"]["short_end_bp"] = 200.0
    steepening["treasury"]["long_end_bp"] = 100.0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="steepening requires"):
        load_scenarios(config, settings.guardrails)


def test_invalid_funding_horizon_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["funding"]["refinancing_horizon_hours"] = 0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="must be positive"):
        load_scenarios(config, settings.guardrails)


def test_invalid_haircut_multiplier_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["haircut"]["stress_multiplier"] = 0.99
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="at least one"):
        load_scenarios(config, settings.guardrails)


def test_invalid_settlement_persistence_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["settlement"]["persistence_days"] = 0
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="must be positive"):
        load_scenarios(config, settings.guardrails)


def test_invalid_integrated_buffer_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[0]["integrated"]["operational_liquidity_buffer_rate"] = 0.50
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="operational_liquidity_buffer_rate"):
        load_scenarios(config, settings.guardrails)


def test_duplicate_scenario_name_is_rejected() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenarios[1]["name"] = scenarios[0]["name"]
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="names must be unique"):
        load_scenarios(config, settings.guardrails)


def test_unknown_bucket_vector_is_rejected_when_expanded() -> None:
    config = _config()
    scenarios = cast(list[dict[str, Any]], config["scenarios"])
    scenario_row = scenarios[0]
    scenario_row["treasury"] = {
        "shape": "bucket_vector",
        "shocks_bp": {"unknown_bucket": 25.0},
    }
    settings = load_settings(config, Path("."))
    scenario = load_scenarios(config, settings.guardrails)[0]
    with pytest.raises(HypotheticalScenarioError, match="unknown Treasury buckets"):
        expand_treasury_shock(scenario, _treasury_config())


def test_single_bucket_curve_expansion_is_supported() -> None:
    scenario = next(item for item in _scenarios() if item.name == "curve_steepening")
    config = {"maturity_buckets": {"only": {"midpoint_years": 2.0}}}
    assert expand_treasury_shock(scenario, config) == {"only": 25.0}


def test_empty_scenario_list_is_rejected() -> None:
    config = _config()
    config["scenarios"] = []
    settings = load_settings(config, Path("."))
    with pytest.raises(HypotheticalScenarioError, match="nonempty"):
        load_scenarios(config, settings.guardrails)


def test_base_configuration_requires_control_scenario() -> None:
    scenario = next(item for item in _scenarios() if item.name == "moderate_stress")
    with pytest.raises(HypotheticalScenarioError, match="control scenario"):
        build_funding_config(
            {"scenarios": [{"name": "not_control"}]},
            scenario,
            "section-21-test",
        )


def test_empty_haircut_maturity_buckets_are_rejected() -> None:
    scenario = next(item for item in _scenarios() if item.name == "moderate_stress")
    base = _haircut_base()
    base["maturity_buckets"] = {}
    with pytest.raises(HypotheticalScenarioError, match="cannot be empty"):
        build_haircut_config(base, scenario, "section-21-test")
'@
    Write-Utf8NoBom -Path $Target -Content $Content
    Write-Pass "Wrote tests/test_hypothetical_scenarios.py"

    $Target = Join-Path $RepoRoot "docs\hypothetical_scenarios_methodology.md"
    $Content = @'
# Section 21 — Hypothetical Scenarios

## Objective

Section 21 establishes a controlled hypothetical-scenario library for FICC Treasury clearing liquidity stress testing. It converts explicit, reviewable assumptions into inputs for the validated Phase V Treasury, repo-funding, collateral-haircut, settlement-fail, and integrated liquidity models.

The framework applies hypothetical market and operational shocks only to fictional synthetic clearing-member portfolios. It does not identify, estimate, rank, or infer any actual FICC participant.

## Required scenario library

The controlled library contains eleven scenarios:

1. Moderate stress.
2. Severe stress.
3. Extreme but plausible stress.
4. Parallel Treasury shock.
5. Treasury curve steepening.
6. Treasury curve flattening.
7. SOFR spike.
8. Repo rollover failure.
9. Collateral haircut increase.
10. Settlement-fail increase.
11. Combined systemic stress.

The first three scenarios provide broad severity tiers. The next seven isolate individual or closely related transmission channels. The combined systemic scenario applies simultaneous shocks across Treasury valuation, secured funding, collateral, settlement, concentration, and the operational liquidity buffer.

## Scenario architecture

Scenario assumptions are stored in `configs/hypothetical_scenarios.yaml`. Each scenario contains five controlled blocks:

- `treasury`: yield-curve shape and basis-point shocks;
- `funding`: SOFR, spread, rollover, lender-withdrawal, refinancing-horizon, and funding-concentration assumptions;
- `haircut`: maturity-dependent haircut, collateral-call, concentration, and inventory-availability assumptions;
- `settlement`: fails-to-receive, fails-to-deliver, payment-delay, replacement-liquidity, persistence, and funding-interaction assumptions;
- `integrated`: residual concentration and operational-liquidity-buffer assumptions used by Section 19.

All assumptions are subject to explicit numerical guardrails. A scenario outside those guardrails fails configuration validation before any model is executed.

## Treasury shocks

Parallel Treasury scenarios apply the same basis-point movement to every Section 15 maturity bucket. Curve steepening and flattening are represented as linear shock vectors between the shortest and longest configured maturity midpoints. The resulting bucket vector is passed to the existing Section 15 duration-plus-convexity model, including its liquidation-horizon, concentration, and market-impact controls.

A zero Treasury block is represented by `shape: none`. Such a scenario is passed to Section 19 with `treasury_scenario_name: NONE`, preventing the creation of a fictitious Treasury loss.

## Component-model execution

Each hypothetical scenario is executed independently as a control-plus-target pair:

- Section 16 receives the scenario-specific repo-funding assumptions.
- Section 17 receives the scenario-specific collateral-haircut assumptions.
- Section 18 receives the scenario-specific settlement assumptions and the corresponding Section 16 cash flows.
- Section 15 receives the scenario-specific Treasury bucket vector where applicable.
- Section 19 combines the atomic outputs and calculates stressed liquidity requirement, available qualified liquid resources, liquidity headroom, shortfall, and liquidity coverage ratio.

Independent control-plus-target execution prevents unrelated targeted scenarios from being forced into a false global severity ordering. Accounting, identity, bound, and synthetic-data controls remain mandatory for every scenario. Component feature-coverage checks that are meaningful only for the full Section 16 or Section 18 libraries are recorded but are not incorrectly required for isolated single-channel scenarios.

## No-double-counting control

Section 21 uses the Section 19 atomic integration design. It includes:

- settlement liquidity need;
- repo rollover need;
- incremental funding cost;
- additional haircut requirement;
- Treasury liquidation loss;
- settlement-fail requirement;
- concentration adjustment;
- operational liquidity buffer.

Composite Section 16 and Section 18 totals and Section 17 stressed-resource reductions remain excluded from additive integration. The Section 19 double-counting control must pass for every Section 21 scenario.

## Validation requirements

The automation requires:

- all eleven required scenarios and all required scenario families;
- unique scenario names and display orders;
- guardrail compliance;
- complete Treasury maturity vectors for active Treasury scenarios;
- component accounting and model-identity checks;
- integrated stressed-liquidity identity checks;
- passing double-counting controls;
- deterministic scenario construction;
- unique scenario-member keys;
- synthetic-member-only results;
- no actual-participant or participant-level inference.

## Controlled outputs

The framework produces CSV and, where supported, Parquet versions of:

- `reports/tables/hypothetical_scenario_catalog`;
- `reports/tables/hypothetical_treasury_shocks`;
- `reports/tables/hypothetical_component_summary`;
- `reports/tables/hypothetical_component_checks`;
- `reports/tables/hypothetical_scenario_member_results`;
- `reports/tables/hypothetical_scenario_summary`;
- `reports/tables/hypothetical_scenario_double_count_controls`.

Validation evidence is written to:

- `reports/evidence/section21_hypothetical_scenarios.json`;
- `reports/evidence/section21_hypothetical_scenarios.md`;
- `reports/evidence/section21_automation_gate.txt`;
- `data/manifests/hypothetical_scenario_manifest.csv`.

Smoke-mode evidence uses the `_smoke` suffix and executes moderate stress, curve steepening, and combined systemic stress.

## Interpretation

Hypothetical scenarios are model-risk tools, not forecasts. Their values represent controlled assumptions selected to test liquidity resilience and model behavior. “Extreme but plausible” indicates a scenario within the documented Section 21 guardrails; it is not a probability statement and does not imply that the scenario is expected to occur.
'@
    Write-Utf8NoBom -Path $Target -Content $Content
    Write-Pass "Wrote docs/hypothetical_scenarios_methodology.md"


    if ($CurrentScript -and (Test-Path -LiteralPath $CurrentScript)) {
        $automationParent = Split-Path -Parent $AutomationTarget
        if (-not (Test-Path -LiteralPath $automationParent)) {
            New-Item -ItemType Directory -Force -Path $automationParent | Out-Null
        }
        $sourceResolved = (Resolve-Path -LiteralPath $CurrentScript).Path
        if (-not $sourceResolved.Equals($AutomationTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $sourceResolved -Destination $AutomationTarget -Force
            Write-Pass "Copied automation to $AutomationRelative"
        }
    }

    Write-Section "Resolve Python 3.11 environment"
    $Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
        if ($null -ne $pyLauncher) {
            Invoke-Native py -3.11 -m venv .venv
        }
        else {
            $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
            if ($null -eq $pythonCommand) {
                throw "Python was not found. Install Python 3.11 and rerun the automation."
            }
            Invoke-Native python -m venv .venv
        }
    }
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw "Virtual-environment interpreter was not created: $Python"
    }
    Invoke-Native $Python --version

    if (-not $SkipInstall) {
        Write-Section "Install project and validation dependencies"
        Invoke-Native $Python -m pip install --upgrade pip
        & $Python -m pip install -e ".[dev]"
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "The project dev extra could not be installed; installing explicit dependencies."
            Invoke-Native $Python -m pip install -e .
            Invoke-Native $Python -m pip install pandas pyarrow pyyaml pytest pytest-cov ruff mypy pandas-stubs types-PyYAML
        }
    }

    $NewPythonFiles = @(
        "src\ficc_liquidity\scenarios\hypothetical_scenarios.py",
        "scripts\run_hypothetical_scenarios.py",
        "tests\test_hypothetical_scenarios.py"
    )

    Write-Section "Format, compile, and test the Section 21 implementation"
    Invoke-Native $Python -m ruff check --fix @NewPythonFiles
    Invoke-Native $Python -m ruff format @NewPythonFiles
    Invoke-Native $Python -m ruff check @NewPythonFiles
    Invoke-Native $Python -m py_compile @NewPythonFiles
    Invoke-Native -FilePath $Python -Arguments @(
        "-m",
        "pytest",
        "-o",
        "addopts=",
        "-q",
        "tests/test_hypothetical_scenarios.py",
        "--cov=ficc_liquidity.scenarios.hypothetical_scenarios",
        "--cov-branch",
        "--cov-report=term-missing",
        "--cov-fail-under=85"
    )

    Write-Section "Run hypothetical-scenario framework"
    Invoke-Native $Python scripts/run_hypothetical_scenarios.py --smoke
    if (-not $SmokeOnly) {
        Invoke-Native $Python scripts/run_hypothetical_scenarios.py
    }
    else {
        Write-Warn "SmokeOnly was selected; complete eleven-scenario execution was skipped."
    }

    Write-Section "Run repository quality gates"
    Invoke-Native $Python -m ruff format --check .
    Invoke-Native $Python -m ruff check .
    Invoke-Native $Python -m mypy src tests

    $FullTestStatus = "PASS"
    if (-not $SkipFullTests) {
        Invoke-Native $Python -m pytest -q `
            --cov=ficc_liquidity `
            --cov-branch `
            --cov-report=term-missing `
            --cov-fail-under=85
    }
    else {
        $FullTestStatus = "SKIPPED BY PARAMETER"
        Write-Warn "Complete repository pytest and coverage gate was skipped."
    }

    $ScenarioExecutionStatus = if ($SmokeOnly) { "SMOKE ONLY" } else { "PASS - COMPLETE LIBRARY" }
    $FinalDecision = if ($SmokeOnly -or $SkipFullTests) {
        "HOLD SECTION 21 - PARTIAL VALIDATION"
    }
    else {
        "PASS SECTION 21"
    }
    $GatePath = Join-Path $RepoRoot "reports\evidence\section21_automation_gate.txt"
    $GateContent = @"
Phase VI Section 21 - Hypothetical Scenarios
Generated: $([DateTime]::UtcNow.ToString('o'))
Branch: $Branch
Scenario configuration: PASS
Moderate stress definition: PASS
Severe stress definition: PASS
Extreme but plausible stress definition: PASS
Parallel Treasury shock definition: PASS
Curve steepening and flattening definitions: PASS
SOFR spike definition: PASS
Rollover-failure definition: PASS
Haircut-increase definition: PASS
Settlement-fail-increase definition: PASS
Combined-systemic-stress definition: PASS
Guardrail validation: PASS
Synthetic-member safeguard: PASS
Section 19 double-count controls: PASS
Scenario execution: $ScenarioExecutionStatus
Focused tests: 24 PASS
Focused branch-aware coverage: at least 85 percent
Ruff: PASS
Strict Mypy: PASS
Full repository pytest and coverage gate: $FullTestStatus
FINAL DECISION: $FinalDecision
"@
    Write-Utf8NoBom -Path $GatePath -Content $GateContent
    Write-Pass "Wrote reports/evidence/section21_automation_gate.txt"

    if (-not $SkipGit) {
        Write-Section "Stage, commit, and push Section 21 on the shared branch"
        $PathsToAdd = @(
            $AutomationRelative,
            "configs/hypothetical_scenarios.yaml",
            "src/ficc_liquidity/scenarios/hypothetical_scenarios.py",
            "scripts/run_hypothetical_scenarios.py",
            "tests/test_hypothetical_scenarios.py",
            "docs/hypothetical_scenarios_methodology.md",
            "reports/tables/hypothetical_scenario_catalog.csv",
            "reports/tables/hypothetical_scenario_catalog.parquet",
            "reports/tables/hypothetical_treasury_shocks.csv",
            "reports/tables/hypothetical_treasury_shocks.parquet",
            "reports/tables/hypothetical_component_summary.csv",
            "reports/tables/hypothetical_component_summary.parquet",
            "reports/tables/hypothetical_component_checks.csv",
            "reports/tables/hypothetical_component_checks.parquet",
            "reports/tables/hypothetical_scenario_member_results.csv",
            "reports/tables/hypothetical_scenario_member_results.parquet",
            "reports/tables/hypothetical_scenario_summary.csv",
            "reports/tables/hypothetical_scenario_summary.parquet",
            "reports/tables/hypothetical_scenario_double_count_controls.csv",
            "reports/tables/hypothetical_scenario_double_count_controls.parquet",
            "reports/evidence/section21_hypothetical_scenarios.json",
            "reports/evidence/section21_hypothetical_scenarios.md",
            "reports/evidence/section21_hypothetical_scenarios_smoke.json",
            "reports/evidence/section21_hypothetical_scenarios_smoke.md",
            "reports/evidence/section21_automation_gate.txt",
            "data/manifests/hypothetical_scenario_manifest.csv"
        )
        foreach ($path in $PathsToAdd) {
            $absolute = Join-Path $RepoRoot $path
            if (Test-Path -LiteralPath $absolute -PathType Leaf) {
                & git check-ignore -q -- $path
                if ($LASTEXITCODE -eq 0) {
                    & git add -f -- $path
                }
                else {
                    & git add -- $path
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "git add failed for $path"
                }
            }
        }

        & git diff --cached --quiet
        if ($LASTEXITCODE -eq 1) {
            if (-not $SkipCommit) {
                Invoke-Native git commit -m $CommitMessage
            }
            else {
                Write-Warn "Changes were staged but commit creation was skipped."
            }
        }
        elseif ($LASTEXITCODE -eq 0) {
            Write-Warn "No new staged changes; Section 21 is already current."
        }
        else {
            throw "Unable to inspect staged Git changes."
        }

        if (-not $SkipPush -and -not $SkipCommit) {
            Invoke-Native git push -u origin $Branch
        }
        elseif ($SkipPush) {
            Write-Warn "Git push was skipped."
        }
    }

    Write-Section "Section 21 completed"
    if ($FinalDecision -eq "PASS SECTION 21") {
        Write-Host "FINAL DECISION: $FinalDecision" -ForegroundColor Green
    }
    else {
        Write-Host "FINAL DECISION: $FinalDecision" -ForegroundColor Yellow
    }
    Write-Host "Branch: $Branch" -ForegroundColor Green
    Write-Host "Primary evidence: reports\evidence\section21_hypothetical_scenarios.md" -ForegroundColor Green
    Write-Host "Automation gate: reports\evidence\section21_automation_gate.txt" -ForegroundColor Green
    Write-Host "Do not open or merge a pull request yet. Sections 22-23 continue on this same branch." -ForegroundColor Yellow
}
finally {
    Set-Location -LiteralPath $OriginalLocation
}
