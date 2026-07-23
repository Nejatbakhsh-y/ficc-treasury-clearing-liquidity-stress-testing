#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase VI, Section 22: Cover 1 and Cover 2 analysis.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.

    The automation remains on the shared feature/18-scenario-library branch,
    verifies that Sections 20 and 21 are present, creates the Section 22
    configuration, calculation module, runner, tests, methodology, result
    tables, evidence, and manifest; runs the hypothetical scenario library when
    its controlled member-result table is missing; executes Ruff, strict Mypy,
    focused tests, the complete repository test suite, commits, and pushes.

    It deliberately does not open a pull request. Sections 20 through 23 are
    grouped on feature/18-scenario-library and should be submitted together.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & ".\24_P6S22_Cover_Analysis_PS51.ps1"

.EXAMPLE
    & ".\24_P6S22_Cover_Analysis_PS51.ps1" `
        -SkipFullTests -NoCommit -SkipPush
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
    [switch]$SkipSection21Run,

    [Parameter()]
    [switch]$SkipFullTests,

    [Parameter()]
    [switch]$NoCommit,

    [Parameter()]
    [switch]$SkipPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if (Test-Path -LiteralPath "variable:PSNativeCommandUseErrorActionPreference") {
    $PSNativeCommandUseErrorActionPreference = $false
}

$BranchName = "feature/18-scenario-library"
$CommitMessage = "Phase VI Section 22: add Cover 1 and Cover 2 analysis"
$AutomationFileName = "24_P6S22_Cover_Analysis_PS51.ps1"
$AutomationRelativePath = "scripts\automation\24_P6S22_Cover_Analysis_PS51.ps1"

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

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Controlled path does not exist: $Path"
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

function Get-MeaningfulDirtyState {
    param([Parameter(Mandatory = $true)][string]$AutomationName)

    $statusLines = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect Git working-tree status."
    }
    return @(
        $statusLines | Where-Object {
            $line = [string]$_
            -not $line.EndsWith($AutomationName, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
}

$OriginalLocation = Get-Location

try {
    $RepoPath = (Resolve-Path -LiteralPath $RepoPath -ErrorAction Stop).Path
    $ScriptPath = $MyInvocation.MyCommand.Path
    Set-Location $RepoPath

    Write-Step "Validating repository, Python environment, and shared scenario branch"

    if (-not (Test-Path -LiteralPath ".git" -PathType Container)) {
        throw "The selected folder is not a Git repository: $RepoPath"
    }
    if (-not (Test-Path -LiteralPath "pyproject.toml" -PathType Leaf)) {
        throw "pyproject.toml was not found. Open the FICC repository in VS Code."
    }

    Assert-Command -Name "git"
    $Python = Join-Path $RepoPath ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw "Python 3.11 virtual environment not found: $Python"
    }

    if (-not $SkipGit) {
        $currentBranch = Get-CurrentBranch
        $dirty = @(Get-MeaningfulDirtyState -AutomationName $AutomationFileName)
        if ($dirty.Count -gt 0 -and -not $AllowDirty) {
            throw @"
The working tree contains uncommitted changes:
$($dirty -join "`n")

Commit or stash them, then rerun this automation. Use -AllowDirty only when
rerunning Section 22 on $BranchName.
"@
        }
        if ($dirty.Count -gt 0 -and $currentBranch -ne $BranchName) {
            throw "-AllowDirty is permitted only on $BranchName. Current branch: $currentBranch"
        }

        if ($dirty.Count -eq 0) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("fetch", "origin", "--prune") `
                -FailureMessage "Unable to fetch origin."

            if ($currentBranch -ne $BranchName) {
                & git show-ref --verify --quiet "refs/heads/$BranchName"
                $localBranchExists = $LASTEXITCODE -eq 0
                & git ls-remote --exit-code --heads origin $BranchName *> $null
                $remoteBranchExists = $LASTEXITCODE -eq 0

                if ($localBranchExists) {
                    Invoke-Checked -FilePath "git" `
                        -ArgumentList @("switch", $BranchName) `
                        -FailureMessage "Unable to switch to $BranchName."
                }
                elseif ($remoteBranchExists) {
                    Invoke-Checked -FilePath "git" `
                        -ArgumentList @("switch", "--track", "-c", $BranchName, "origin/$BranchName") `
                        -FailureMessage "Unable to restore $BranchName from origin."
                }
                else {
                    throw @"
The shared scenario-library branch does not exist locally or on origin.
Complete Sections 20 and 21 first. Expected branch: $BranchName
"@
                }
            }

            & git ls-remote --exit-code --heads origin $BranchName *> $null
            if ($LASTEXITCODE -eq 0) {
                Invoke-Checked -FilePath "git" `
                    -ArgumentList @("pull", "--ff-only", "origin", $BranchName) `
                    -FailureMessage "Unable to update $BranchName."
            }
        }
        else {
            Write-Warn "Dirty shared branch retained; fetch, switch, and pull were skipped."
        }

        if ((Get-CurrentBranch) -ne $BranchName) {
            throw "Section 22 must run on $BranchName."
        }
        Write-Pass "Current branch is $BranchName"
    }
    else {
        Write-Warn "Git branch operations were skipped."
    }

    $section21Gate = @(
        "configs\hypothetical_scenarios.yaml",
        "src\ficc_liquidity\scenarios\hypothetical_scenarios.py",
        "scripts\run_hypothetical_scenarios.py",
        "tests\test_hypothetical_scenarios.py"
    )
    if (-not (Test-RequiredFiles -Paths $section21Gate)) {
        $missing = @(
            foreach ($path in $section21Gate) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $path
                }
            }
        )
        throw @"
Section 21 is incomplete on $BranchName. Missing files:
$($missing -join "`n")

Run 23_P6S21_Hypothetical_Scenarios_PS51.ps1 first, then rerun Section 22.
"@
    }
    Write-Pass "Section 21 hypothetical-scenario implementation is present"

    Write-Step "Creating Section 22 controlled files"
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

    $rootAutomationTarget = Join-Path $RepoPath $AutomationFileName
    $automationTarget = Join-Path $RepoPath $AutomationRelativePath
    if ($ScriptPath) {
        if (-not $ScriptPath.Equals(
            $rootAutomationTarget,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            Copy-Item -LiteralPath $ScriptPath -Destination $rootAutomationTarget -Force
        }
        if (-not $ScriptPath.Equals(
            $automationTarget,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            Copy-Item -LiteralPath $ScriptPath -Destination $automationTarget -Force
        }
    }

$ConfigContent = @'
schema_version: "1.0"
section: 22
model_name: cover_1_cover_2_analysis
model_version: "section-22-v1"
currency: USD
random_seed: 2026

classification:
  hypothetical_scenario_results: modeled
  cover_selection_rule: assumed
  cover_results: modeled
  actual_ficc_participants_permitted: false
  participant_level_inference_permitted: false

source:
  member_result_candidates:
    - reports/tables/hypothetical_scenario_member_results.parquet
    - reports/tables/hypothetical_scenario_member_results.csv
    - reports/tables/integrated_stress_member_results.parquet
    - reports/tables/integrated_stress_member_results.csv
  synthetic_id_pattern: '^SYN-MBR-[0-9]{4}$'

selection:
  method: largest_gross_stressed_liquidity_requirement
  ranking_column: stressed_liquidity_requirement_usd
  tie_breakers:
    - liquidity_shortfall_usd_descending
    - member_id_ascending
  cover_levels:
    - 1
    - 2
  available_resources_basis: selected_member_aqlr_sum

metrics:
  lcr_minimum_ratio: 1.00
  resource_utilization_definition: stressed_requirement_divided_by_available_resources
  component_columns:
    - column: settlement_liquidity_need_usd
      label: settlement_liquidity_need
    - column: repo_rollover_need_usd
      label: repo_rollover_need
    - column: incremental_funding_cost_usd
      label: incremental_funding_cost
    - column: additional_haircut_requirement_usd
      label: additional_haircut_requirement
    - column: treasury_liquidation_loss_usd
      label: treasury_liquidation_loss
    - column: settlement_fail_requirement_usd
      label: settlement_fail_requirement
    - column: concentration_adjustment_usd
      label: concentration_adjustment
    - column: operational_liquidity_buffer_usd
      label: operational_liquidity_buffer

validation:
  reconciliation_tolerance_usd: 0.01
  require_cover_1_member_count: true
  require_cover_2_member_count: true
  require_cover_2_not_less_than_cover_1: true
  require_deterministic_reproduction: true
  require_component_reconciliation: true
  require_synthetic_identifiers: true

output:
  cover_results_csv: reports/tables/cover_analysis_results.csv
  cover_results_parquet: reports/tables/cover_analysis_results.parquet
  scenario_summary_csv: reports/tables/cover_analysis_scenario_summary.csv
  scenario_summary_parquet: reports/tables/cover_analysis_scenario_summary.parquet
  selected_members_csv: reports/tables/cover_analysis_selected_members.csv
  selected_members_parquet: reports/tables/cover_analysis_selected_members.parquet
  component_summary_csv: reports/tables/cover_analysis_component_summary.csv
  component_summary_parquet: reports/tables/cover_analysis_component_summary.parquet
  evidence_json: reports/evidence/section22_cover_analysis.json
  evidence_markdown: reports/evidence/section22_cover_analysis.md
  manifest: data/manifests/cover_analysis_manifest.csv
'@

$ModuleContent = @'
"""Cover 1 and Cover 2 liquidity analysis for synthetic clearing members.

The module consumes scenario-level member results produced by the Phase VI
scenario library. It ranks synthetic members deterministically by gross stressed
liquidity requirement and calculates Cover 1 and Cover 2 coverage diagnostics.
"""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class CoverAnalysisError(ValueError):
    """Raised when Section 22 configuration or scenario results are invalid."""


CANONICAL_ALIASES: Mapping[str, tuple[str, ...]] = {
    "member_id": ("member_id", "synthetic_member_id", "clearing_member_id"),
    "scenario_name": ("scenario_name", "hypothetical_scenario_name", "scenario_id"),
    "severity_rank": ("severity_rank", "scenario_severity_rank"),
    "stressed_liquidity_requirement_usd": (
        "stressed_liquidity_requirement_usd",
        "total_stressed_liquidity_requirement_usd",
        "integrated_stressed_liquidity_requirement_usd",
    ),
    "available_qualified_liquid_resources_usd": (
        "available_qualified_liquid_resources_usd",
        "available_resources_usd",
        "aqlr_usd",
    ),
    "settlement_liquidity_need_usd": (
        "settlement_liquidity_need_usd",
        "net_settlement_outflow_usd",
    ),
    "repo_rollover_need_usd": (
        "repo_rollover_need_usd",
        "repo_rollover_failure_outflow_usd",
    ),
    "incremental_funding_cost_usd": (
        "incremental_funding_cost_usd",
        "funding_cost_increase_usd",
    ),
    "additional_haircut_requirement_usd": (
        "additional_haircut_requirement_usd",
        "additional_collateral_requirement_total_usd",
    ),
    "treasury_liquidation_loss_usd": (
        "treasury_liquidation_loss_usd",
        "treasury_loss_usd",
    ),
    "settlement_fail_requirement_usd": (
        "settlement_fail_requirement_usd",
        "incremental_settlement_fail_outflow_usd",
    ),
    "concentration_adjustment_usd": (
        "concentration_adjustment_usd",
        "concentration_liquidity_adjustment_usd",
    ),
    "operational_liquidity_buffer_usd": (
        "operational_liquidity_buffer_usd",
        "operational_buffer_usd",
    ),
}

DEFAULT_COMPONENTS: tuple[tuple[str, str], ...] = (
    ("settlement_liquidity_need_usd", "settlement_liquidity_need"),
    ("repo_rollover_need_usd", "repo_rollover_need"),
    ("incremental_funding_cost_usd", "incremental_funding_cost"),
    ("additional_haircut_requirement_usd", "additional_haircut_requirement"),
    ("treasury_liquidation_loss_usd", "treasury_liquidation_loss"),
    ("settlement_fail_requirement_usd", "settlement_fail_requirement"),
    ("concentration_adjustment_usd", "concentration_adjustment"),
    ("operational_liquidity_buffer_usd", "operational_liquidity_buffer"),
)


@dataclass(frozen=True)
class CoverAnalysisSettings:
    """Controlled Section 22 calculation settings."""

    model_version: str
    synthetic_id_pattern: str
    cover_levels: tuple[int, ...]
    lcr_minimum_ratio: float
    reconciliation_tolerance_usd: float
    component_columns: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class CoverAnalysisResult:
    """Structured Section 22 result tables and validation checks."""

    cover_results: pd.DataFrame
    scenario_summary: pd.DataFrame
    selected_members: pd.DataFrame
    component_summary: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return True when every controlled validation check passes."""
        return all(self.checks.values())


def load_cover_analysis_config(path: str | Path) -> dict[str, Any]:
    """Load a Section 22 YAML configuration file."""

    config_path = Path(path)
    if not config_path.is_file():
        raise CoverAnalysisError(f"Cover-analysis configuration not found: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise CoverAnalysisError("Cover-analysis configuration must be a YAML mapping.")
    return cast(dict[str, Any], loaded)


def settings_from_config(config: Mapping[str, Any]) -> CoverAnalysisSettings:
    """Build validated calculation settings from a configuration mapping."""

    model_version = str(config.get("model_version", "section-22-v1"))
    source = _mapping(config.get("source", {}), "source")
    selection = _mapping(config.get("selection", {}), "selection")
    metrics = _mapping(config.get("metrics", {}), "metrics")
    validation = _mapping(config.get("validation", {}), "validation")

    synthetic_id_pattern = str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$"))
    try:
        re.compile(synthetic_id_pattern)
    except re.error as exc:
        raise CoverAnalysisError("source.synthetic_id_pattern is not valid regex.") from exc

    raw_levels = selection.get("cover_levels", [1, 2])
    if not isinstance(raw_levels, Sequence) or isinstance(raw_levels, (str, bytes)):
        raise CoverAnalysisError("selection.cover_levels must be a sequence of positive integers.")
    cover_levels = tuple(int(level) for level in raw_levels)
    if cover_levels != (1, 2):
        raise CoverAnalysisError("Section 22 requires cover_levels to be exactly [1, 2].")

    lcr_minimum_ratio = float(metrics.get("lcr_minimum_ratio", 1.0))
    tolerance = float(validation.get("reconciliation_tolerance_usd", 0.01))
    if lcr_minimum_ratio <= 0.0:
        raise CoverAnalysisError("metrics.lcr_minimum_ratio must be positive.")
    if tolerance < 0.0:
        raise CoverAnalysisError("validation.reconciliation_tolerance_usd cannot be negative.")

    configured_components = metrics.get("component_columns")
    component_columns = _parse_components(configured_components)
    return CoverAnalysisSettings(
        model_version=model_version,
        synthetic_id_pattern=synthetic_id_pattern,
        cover_levels=cover_levels,
        lcr_minimum_ratio=lcr_minimum_ratio,
        reconciliation_tolerance_usd=tolerance,
        component_columns=component_columns,
    )


def _mapping(value: object, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise CoverAnalysisError(f"{name} must be a mapping.")
    return cast(Mapping[str, Any], value)


def _parse_components(value: object) -> tuple[tuple[str, str], ...]:
    if value is None:
        return DEFAULT_COMPONENTS
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        raise CoverAnalysisError("metrics.component_columns must be a sequence.")
    parsed: list[tuple[str, str]] = []
    for item in value:
        if not isinstance(item, Mapping):
            raise CoverAnalysisError("Each component definition must be a mapping.")
        column = str(item.get("column", "")).strip()
        label = str(item.get("label", "")).strip()
        if not column or not label:
            raise CoverAnalysisError("Each component requires nonempty column and label values.")
        parsed.append((column, label))
    if not parsed:
        raise CoverAnalysisError("At least one stress component is required.")
    if len({column for column, _ in parsed}) != len(parsed):
        raise CoverAnalysisError("Stress-component columns must be unique.")
    return tuple(parsed)


def canonicalize_member_results(
    frame: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> pd.DataFrame:
    """Resolve aliases and validate scenario-level synthetic member results."""

    if frame.empty:
        raise CoverAnalysisError("Scenario member results are empty.")

    required = {
        "member_id",
        "scenario_name",
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        *(column for column, _ in settings.component_columns),
    }
    rename_map: dict[str, str] = {}
    missing: list[str] = []
    for canonical in sorted(required | {"severity_rank"}):
        aliases = CANONICAL_ALIASES.get(canonical, (canonical,))
        source = next((name for name in aliases if name in frame.columns), None)
        if source is None:
            if canonical == "severity_rank":
                continue
            missing.append(canonical)
        elif source != canonical:
            rename_map[source] = canonical
    if missing:
        raise CoverAnalysisError(
            "Scenario member results are missing required columns: " + ", ".join(missing)
        )

    result = frame.rename(columns=rename_map).copy()
    result["member_id"] = result["member_id"].astype(str).str.strip()
    result["scenario_name"] = result["scenario_name"].astype(str).str.strip()
    if "severity_rank" not in result.columns:
        ordered_names = sorted(result["scenario_name"].unique().tolist())
        rank_map = {name: rank for rank, name in enumerate(ordered_names)}
        result["severity_rank"] = result["scenario_name"].map(rank_map)

    numeric_columns = [
        "severity_rank",
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        *(column for column, _ in settings.component_columns),
    ]
    for column in numeric_columns:
        result[column] = pd.to_numeric(result[column], errors="raise")

    if result["member_id"].eq("").any() or result["scenario_name"].eq("").any():
        raise CoverAnalysisError("Member and scenario identifiers must be nonempty.")
    pattern = re.compile(settings.synthetic_id_pattern)
    invalid_ids = sorted(
        member_id
        for member_id in result["member_id"].unique().tolist()
        if pattern.fullmatch(str(member_id)) is None
    )
    if invalid_ids:
        raise CoverAnalysisError(
            "Only controlled synthetic member identifiers are permitted: "
            + ", ".join(invalid_ids[:5])
        )
    if result.duplicated(subset=["scenario_name", "member_id"]).any():
        raise CoverAnalysisError("Scenario/member records must be unique.")

    nonnegative_columns = [
        "stressed_liquidity_requirement_usd",
        "available_qualified_liquid_resources_usd",
        *(column for column, _ in settings.component_columns),
    ]
    if (result[nonnegative_columns] < 0.0).any().any():
        raise CoverAnalysisError(
            "Requirements, resources, and stress components cannot be negative."
        )
    if not result[numeric_columns].map(math.isfinite).all().all():
        raise CoverAnalysisError("Numeric scenario results must be finite.")

    component_total = result[[column for column, _ in settings.component_columns]].sum(axis=1)
    difference = (
        component_total - result["stressed_liquidity_requirement_usd"]
    ).abs()
    if (difference > settings.reconciliation_tolerance_usd).any():
        maximum = float(difference.max())
        raise CoverAnalysisError(
            "Stress components do not reconcile to stressed liquidity requirement; "
            f"maximum difference is {maximum:.6f}."
        )

    result["liquidity_shortfall_usd"] = (
        result["stressed_liquidity_requirement_usd"]
        - result["available_qualified_liquid_resources_usd"]
    ).clip(lower=0.0)
    return result.sort_values(
        ["severity_rank", "scenario_name", "member_id"], kind="mergesort"
    ).reset_index(drop=True)


def analyze_cover_sets(
    frame: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> CoverAnalysisResult:
    """Calculate deterministic Cover 1 and Cover 2 diagnostics for every scenario."""

    canonical = canonicalize_member_results(frame, settings)
    cover_rows: list[dict[str, object]] = []
    selected_rows: list[dict[str, object]] = []
    component_rows: list[dict[str, object]] = []

    grouped = canonical.groupby(["severity_rank", "scenario_name"], sort=True, dropna=False)
    for (severity_rank, scenario_name), scenario_frame in grouped:
        ranked = scenario_frame.sort_values(
            [
                "stressed_liquidity_requirement_usd",
                "liquidity_shortfall_usd",
                "member_id",
            ],
            ascending=[False, False, True],
            kind="mergesort",
        ).reset_index(drop=True)
        for cover_level in settings.cover_levels:
            selected = ranked.head(cover_level).copy()
            if len(selected) != cover_level:
                raise CoverAnalysisError(
                    f"Scenario {scenario_name!s} has fewer than {cover_level} members."
                )
            requirement = float(selected["stressed_liquidity_requirement_usd"].sum())
            resources = float(selected["available_qualified_liquid_resources_usd"].sum())
            shortfall = max(requirement - resources, 0.0)
            lcr = (
                resources / requirement
                if requirement > settings.reconciliation_tolerance_usd
                else math.nan
            )
            utilization = (
                requirement / resources
                if resources > settings.reconciliation_tolerance_usd
                else math.nan
            )

            component_totals = {
                column: float(selected[column].sum())
                for column, _ in settings.component_columns
            }
            dominant_column, dominant_label = max(
                settings.component_columns,
                key=lambda pair: (component_totals[pair[0]], -_component_index(settings, pair[0])),
            )
            dominant_amount = component_totals[dominant_column]
            dominant_share = dominant_amount / requirement if requirement > 0.0 else math.nan
            selected_ids = selected["member_id"].astype(str).tolist()
            status = (
                "PASS"
                if math.isfinite(lcr) and lcr >= settings.lcr_minimum_ratio
                else "BREACH"
            )

            cover_rows.append(
                {
                    "scenario_name": str(scenario_name),
                    "severity_rank": int(cast(Any, severity_rank)),
                    "cover_standard": f"COVER_{cover_level}",
                    "cover_level": cover_level,
                    "selected_member_count": len(selected_ids),
                    "selected_member_ids_json": json.dumps(selected_ids),
                    "cover_stressed_requirement_usd": requirement,
                    "available_resources_usd": resources,
                    "liquidity_coverage_ratio": lcr,
                    "liquidity_shortfall_usd": shortfall,
                    "resource_utilization_ratio": utilization,
                    "dominant_stress_component": dominant_label,
                    "dominant_stress_component_column": dominant_column,
                    "dominant_stress_component_usd": dominant_amount,
                    "dominant_stress_component_share": dominant_share,
                    "lcr_minimum_ratio": settings.lcr_minimum_ratio,
                    "coverage_status": status,
                    "model_version": settings.model_version,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )

            for rank, (_, member) in enumerate(selected.iterrows(), start=1):
                selected_rows.append(
                    {
                        "scenario_name": str(scenario_name),
                        "severity_rank": int(cast(Any, severity_rank)),
                        "cover_standard": f"COVER_{cover_level}",
                        "cover_level": cover_level,
                        "selection_rank": rank,
                        "member_id": str(member["member_id"]),
                        "member_stressed_requirement_usd": float(
                            member["stressed_liquidity_requirement_usd"]
                        ),
                        "member_available_resources_usd": float(
                            member["available_qualified_liquid_resources_usd"]
                        ),
                        "member_liquidity_shortfall_usd": float(
                            member["liquidity_shortfall_usd"]
                        ),
                        "model_version": settings.model_version,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )

            for column, label in settings.component_columns:
                amount = component_totals[column]
                component_rows.append(
                    {
                        "scenario_name": str(scenario_name),
                        "severity_rank": int(cast(Any, severity_rank)),
                        "cover_standard": f"COVER_{cover_level}",
                        "cover_level": cover_level,
                        "component_column": column,
                        "component_name": label,
                        "component_amount_usd": amount,
                        "component_share_of_requirement": (
                            amount / requirement if requirement > 0.0 else math.nan
                        ),
                        "is_dominant_component": column == dominant_column,
                        "model_version": settings.model_version,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )

    cover_results = pd.DataFrame(cover_rows).sort_values(
        ["severity_rank", "scenario_name", "cover_level"], kind="mergesort"
    ).reset_index(drop=True)
    selected_members = pd.DataFrame(selected_rows).sort_values(
        ["severity_rank", "scenario_name", "cover_level", "selection_rank"],
        kind="mergesort",
    ).reset_index(drop=True)
    component_summary = pd.DataFrame(component_rows).sort_values(
        ["severity_rank", "scenario_name", "cover_level", "component_name"],
        kind="mergesort",
    ).reset_index(drop=True)
    scenario_summary = build_scenario_summary(cover_results)

    checks = _build_checks(
        canonical,
        cover_results,
        selected_members,
        component_summary,
        settings,
    )
    return CoverAnalysisResult(
        cover_results=cover_results,
        scenario_summary=scenario_summary,
        selected_members=selected_members,
        component_summary=component_summary,
        checks=checks,
    )


def _component_index(settings: CoverAnalysisSettings, column: str) -> int:
    return next(index for index, pair in enumerate(settings.component_columns) if pair[0] == column)


def build_scenario_summary(cover_results: pd.DataFrame) -> pd.DataFrame:
    """Create one wide row per scenario with explicit Cover 1 and Cover 2 metrics."""

    if cover_results.empty:
        raise CoverAnalysisError("Cover results are empty.")
    rows: list[dict[str, object]] = []
    for (severity_rank, scenario_name), group in cover_results.groupby(
        ["severity_rank", "scenario_name"], sort=True, dropna=False
    ):
        by_level = {int(row["cover_level"]): row for _, row in group.iterrows()}
        if set(by_level) != {1, 2}:
            raise CoverAnalysisError(
                f"Scenario {scenario_name!s} does not contain Cover 1 and Cover 2."
            )
        row: dict[str, object] = {
            "scenario_name": str(scenario_name),
            "severity_rank": int(cast(Any, severity_rank)),
            "model_version": str(by_level[1]["model_version"]),
            "value_class": "synthetic",
            "actual_ficc_participant": False,
            "participant_level_inference": False,
        }
        for level in (1, 2):
            source = by_level[level]
            prefix = f"cover_{level}"
            row[f"{prefix}_member_ids_json"] = source["selected_member_ids_json"]
            row[f"{prefix}_stressed_requirement_usd"] = source[
                "cover_stressed_requirement_usd"
            ]
            row[f"{prefix}_available_resources_usd"] = source["available_resources_usd"]
            row[f"{prefix}_liquidity_coverage_ratio"] = source[
                "liquidity_coverage_ratio"
            ]
            row[f"{prefix}_liquidity_shortfall_usd"] = source[
                "liquidity_shortfall_usd"
            ]
            row[f"{prefix}_resource_utilization_ratio"] = source[
                "resource_utilization_ratio"
            ]
            row[f"{prefix}_dominant_stress_component"] = source[
                "dominant_stress_component"
            ]
            row[f"{prefix}_dominant_stress_component_usd"] = source[
                "dominant_stress_component_usd"
            ]
            row[f"{prefix}_coverage_status"] = source["coverage_status"]
        rows.append(row)
    return pd.DataFrame(rows).sort_values(
        ["severity_rank", "scenario_name"], kind="mergesort"
    ).reset_index(drop=True)


def _build_checks(
    canonical: pd.DataFrame,
    cover_results: pd.DataFrame,
    selected_members: pd.DataFrame,
    component_summary: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> dict[str, bool]:
    scenario_count = int(canonical["scenario_name"].nunique())
    cover1 = cover_results.loc[cover_results["cover_level"] == 1]
    cover2 = cover_results.loc[cover_results["cover_level"] == 2]
    merged = cover1.merge(
        cover2,
        on=["scenario_name", "severity_rank"],
        suffixes=("_cover1", "_cover2"),
        validate="one_to_one",
    )
    tolerance = settings.reconciliation_tolerance_usd
    identity_difference = (
        cover_results["cover_stressed_requirement_usd"]
        - cover_results["available_resources_usd"]
        - cover_results["liquidity_shortfall_usd"]
    )
    positive_gap = cover_results["cover_stressed_requirement_usd"] >= cover_results[
        "available_resources_usd"
    ]
    identity_ok = (
        identity_difference.loc[positive_gap].abs() <= tolerance
    ).all() and (cover_results.loc[~positive_gap, "liquidity_shortfall_usd"] <= tolerance).all()

    component_totals = component_summary.groupby(
        ["scenario_name", "severity_rank", "cover_level"], sort=True
    )["component_amount_usd"].sum()
    requirement_totals = cover_results.set_index(
        ["scenario_name", "severity_rank", "cover_level"]
    )["cover_stressed_requirement_usd"]
    component_difference = (component_totals - requirement_totals).abs()

    return {
        "scenario_coverage_complete": len(cover_results) == scenario_count * 2,
        "cover_1_member_count": bool((cover1["selected_member_count"] == 1).all()),
        "cover_2_member_count": bool((cover2["selected_member_count"] == 2).all()),
        "cover_2_not_less_than_cover_1": bool(
            (
                merged["cover_stressed_requirement_usd_cover2"]
                + tolerance
                >= merged["cover_stressed_requirement_usd_cover1"]
            ).all()
        ),
        "available_resources_nonnegative": bool(
            (cover_results["available_resources_usd"] >= 0.0).all()
        ),
        "liquidity_shortfall_identity": bool(identity_ok),
        "component_reconciliation": bool((component_difference <= tolerance).all()),
        "one_dominant_component_per_cover": bool(
            component_summary.groupby(
                ["scenario_name", "severity_rank", "cover_level"], sort=True
            )["is_dominant_component"].sum().eq(1).all()
        ),
        "selected_members_unique_within_cover": not selected_members.duplicated(
            subset=["scenario_name", "cover_level", "member_id"]
        ).any(),
        "synthetic_identifiers_only": bool(
            canonical["member_id"].astype(str).str.fullmatch(settings.synthetic_id_pattern).all()
        ),
        "actual_ficc_participants_excluded": True,
    }


def deterministic_reproduction_check(
    frame: pd.DataFrame,
    settings: CoverAnalysisSettings,
) -> bool:
    """Verify that input row order cannot alter Cover 1 or Cover 2 selection."""

    first = analyze_cover_sets(frame, settings)
    shuffled = frame.sample(frac=1.0, random_state=2026).reset_index(drop=True)
    second = analyze_cover_sets(shuffled, settings)
    comparable_columns = [
        "scenario_name",
        "severity_rank",
        "cover_level",
        "selected_member_ids_json",
        "cover_stressed_requirement_usd",
        "available_resources_usd",
        "liquidity_shortfall_usd",
        "dominant_stress_component",
    ]
    return first.cover_results[comparable_columns].equals(second.cover_results[comparable_columns])
'@

$RunnerContent = @'
"""Run Phase VI, Section 22 Cover 1 and Cover 2 analysis."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

from ficc_liquidity.scenarios.cover_analysis import (
    CoverAnalysisError,
    analyze_cover_sets,
    deterministic_reproduction_check,
    load_cover_analysis_config,
    settings_from_config,
)


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/cover_analysis.yaml"),
        help="Section 22 YAML configuration.",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=None,
        help="Optional explicit scenario-member result table.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Repository root used to resolve configured relative paths.",
    )
    return parser.parse_args()


def resolve_input_path(
    repo_root: Path,
    config: dict[str, Any],
    explicit_input: Path | None,
) -> Path:
    """Resolve the first available controlled scenario-member result table."""

    if explicit_input is not None:
        candidate = explicit_input if explicit_input.is_absolute() else repo_root / explicit_input
        if candidate.is_file():
            return candidate
        raise CoverAnalysisError(f"Explicit scenario-member input was not found: {candidate}")

    source = config.get("source", {})
    if not isinstance(source, dict):
        raise CoverAnalysisError("source must be a mapping.")
    raw_candidates = source.get("member_result_candidates", [])
    if not isinstance(raw_candidates, list):
        raise CoverAnalysisError("source.member_result_candidates must be a list.")
    for value in raw_candidates:
        candidate = repo_root / str(value)
        if candidate.is_file():
            return candidate
    raise CoverAnalysisError(
        "No scenario-member result table was found. Run Section 21 first. Checked: "
        + ", ".join(str(value) for value in raw_candidates)
    )


def read_table(path: Path) -> pd.DataFrame:
    """Read a controlled CSV or Parquet table."""

    suffix = path.suffix.lower()
    if suffix == ".parquet":
        return pd.read_parquet(path)
    if suffix == ".csv":
        return pd.read_csv(path)
    raise CoverAnalysisError(f"Unsupported input table format: {path.suffix}")


def write_table(frame: pd.DataFrame, csv_path: Path, parquet_path: Path) -> None:
    """Write deterministic CSV and Parquet copies of a result table."""

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    parquet_path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(csv_path, index=False, lineterminator="\n")
    frame.to_parquet(parquet_path, index=False)


def file_sha256(path: Path) -> str:
    """Calculate a SHA-256 digest for an artifact."""

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def output_paths(repo_root: Path, config: dict[str, Any]) -> dict[str, Path]:
    """Resolve configured Section 22 output paths."""

    output = config.get("output", {})
    if not isinstance(output, dict):
        raise CoverAnalysisError("output must be a mapping.")
    defaults = {
        "cover_results_csv": "reports/tables/cover_analysis_results.csv",
        "cover_results_parquet": "reports/tables/cover_analysis_results.parquet",
        "scenario_summary_csv": "reports/tables/cover_analysis_scenario_summary.csv",
        "scenario_summary_parquet": "reports/tables/cover_analysis_scenario_summary.parquet",
        "selected_members_csv": "reports/tables/cover_analysis_selected_members.csv",
        "selected_members_parquet": "reports/tables/cover_analysis_selected_members.parquet",
        "component_summary_csv": "reports/tables/cover_analysis_component_summary.csv",
        "component_summary_parquet": "reports/tables/cover_analysis_component_summary.parquet",
        "evidence_json": "reports/evidence/section22_cover_analysis.json",
        "evidence_markdown": "reports/evidence/section22_cover_analysis.md",
        "manifest": "data/manifests/cover_analysis_manifest.csv",
    }
    return {
        name: repo_root / str(output.get(name, default))
        for name, default in defaults.items()
    }


def write_evidence(
    paths: dict[str, Path],
    source_path: Path,
    config_path: Path,
    result: object,
    deterministic_pass: bool,
) -> None:
    """Write controlled JSON and Markdown validation evidence."""

    from ficc_liquidity.scenarios.cover_analysis import CoverAnalysisResult

    typed_result = cast(CoverAnalysisResult, result)
    generated_at = datetime.now(UTC).isoformat()
    checks = dict(typed_result.checks)
    checks["deterministic_reproduction"] = deterministic_pass
    final_pass = all(checks.values())

    evidence = {
        "section": 22,
        "generated_at_utc": generated_at,
        "run_type": "CONTROLLED_MODEL_RUN",
        "model_version": str(typed_result.cover_results["model_version"].iloc[0]),
        "source_table": str(source_path.resolve()),
        "configuration": str(config_path.resolve()),
        "scenario_count": int(typed_result.scenario_summary.shape[0]),
        "cover_result_rows": int(typed_result.cover_results.shape[0]),
        "selected_member_rows": int(typed_result.selected_members.shape[0]),
        "component_rows": int(typed_result.component_summary.shape[0]),
        "checks": checks,
        "final_decision": "PASS" if final_pass else "FAIL",
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }
    json_path = paths["evidence_json"]
    markdown_path = paths["evidence_markdown"]
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# Section 22 — Cover 1 and Cover 2 Analysis",
        "",
        f"- Generated at: `{generated_at}`",
        f"- Source table: `{source_path.as_posix()}`",
        f"- Scenario count: `{typed_result.scenario_summary.shape[0]}`",
        f"- Cover-result rows: `{typed_result.cover_results.shape[0]}`",
        "- Actual FICC participants represented: `NO`",
        "- Participant-level inference performed: `NO`",
        "",
        "## Validation checks",
        "",
    ]
    lines.extend(
        f"- {name.replace('_', ' ').title()}: `{'PASS' if passed else 'FAIL'}`"
        for name, passed in sorted(checks.items())
    )
    lines.extend(
        [
            "",
            "## Metric definitions",
            "",
            "- Cover 1: the synthetic member with the largest gross stressed liquidity "
            "requirement within each scenario.",
            "- Cover 2: the two synthetic members with the largest gross stressed liquidity "
            "requirements within each scenario.",
            "- Available resources: sum of selected members' available qualified liquid resources.",
            "- LCR: available resources divided by the Cover stressed requirement.",
            "- Liquidity shortfall: maximum of requirement minus resources and zero.",
            "- Resource utilization: Cover stressed requirement divided by available resources.",
            "- Dominant stress component: largest aggregated atomic stress component for "
            "the selected Cover set.",
            "",
            f"## Final decision: {'PASS' if final_pass else 'FAIL'}",
            "",
        ]
    )
    markdown_path.write_text("\n".join(lines), encoding="utf-8")


def write_manifest(
    paths: dict[str, Path],
    source_path: Path,
    config_path: Path,
) -> None:
    """Write Section 22 artifact lineage and integrity metadata."""

    generated_at = datetime.now(UTC).isoformat()
    rows: list[dict[str, object]] = []
    artifact_paths = [
        config_path,
        source_path,
        paths["cover_results_csv"],
        paths["cover_results_parquet"],
        paths["scenario_summary_csv"],
        paths["scenario_summary_parquet"],
        paths["selected_members_csv"],
        paths["selected_members_parquet"],
        paths["component_summary_csv"],
        paths["component_summary_parquet"],
        paths["evidence_json"],
        paths["evidence_markdown"],
    ]
    for path in artifact_paths:
        if not path.is_file():
            continue
        row_count: int | None = None
        if path.suffix.lower() == ".csv":
            row_count = int(pd.read_csv(path).shape[0])
        elif path.suffix.lower() == ".parquet":
            row_count = int(pd.read_parquet(path).shape[0])
        rows.append(
            {
                "section": 22,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "value_class": "assumed" if path == config_path else "synthetic",
                "row_count": row_count,
                "sha256": file_sha256(path),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    manifest_path = paths["manifest"]
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(rows).to_csv(manifest_path, index=False, lineterminator="\n")


def main() -> int:
    """Execute Section 22 and return a process exit code."""

    args = parse_args()
    repo_root = args.repo_root.resolve()
    config_path = args.config if args.config.is_absolute() else repo_root / args.config
    config = load_cover_analysis_config(config_path)
    settings = settings_from_config(config)
    source_path = resolve_input_path(repo_root, config, args.input)
    source_frame = read_table(source_path)
    result = analyze_cover_sets(source_frame, settings)
    deterministic_pass = deterministic_reproduction_check(source_frame, settings)
    paths = output_paths(repo_root, config)

    write_table(
        result.cover_results,
        paths["cover_results_csv"],
        paths["cover_results_parquet"],
    )
    write_table(
        result.scenario_summary,
        paths["scenario_summary_csv"],
        paths["scenario_summary_parquet"],
    )
    write_table(
        result.selected_members,
        paths["selected_members_csv"],
        paths["selected_members_parquet"],
    )
    write_table(
        result.component_summary,
        paths["component_summary_csv"],
        paths["component_summary_parquet"],
    )
    write_evidence(paths, source_path, config_path, result, deterministic_pass)
    write_manifest(paths, source_path, config_path)

    final_pass = result.passed and deterministic_pass
    reported_checks = {**result.checks, "deterministic_reproduction": deterministic_pass}
    for check_name, passed in sorted(reported_checks.items()):
        print(f"{check_name}: {'PASS' if passed else 'FAIL'}")
    print(f"Scenarios analyzed: {result.scenario_summary.shape[0]}")
    print(f"Cover rows written: {result.cover_results.shape[0]}")
    print(f"FINAL DECISION: {'PASS' if final_pass else 'FAIL'}")
    return 0 if final_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@

$TestContent = @'
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.scenarios.cover_analysis import (
    CoverAnalysisError,
    analyze_cover_sets,
    canonicalize_member_results,
    deterministic_reproduction_check,
    load_cover_analysis_config,
    settings_from_config,
)


def config() -> dict[str, Any]:
    return {
        "model_version": "test-v1",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "selection": {"cover_levels": [1, 2]},
        "metrics": {"lcr_minimum_ratio": 1.0},
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


def member_frame() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    specifications = {
        "moderate": [
            ("SYN-MBR-0001", 100.0, 80.0, 60.0, 20.0, 10.0, 5.0, 2.0, 1.0, 1.0, 1.0),
            ("SYN-MBR-0002", 80.0, 90.0, 20.0, 30.0, 10.0, 5.0, 5.0, 5.0, 3.0, 2.0),
            ("SYN-MBR-0003", 60.0, 40.0, 10.0, 5.0, 10.0, 10.0, 10.0, 10.0, 3.0, 2.0),
        ],
        "severe": [
            ("SYN-MBR-0001", 150.0, 100.0, 20.0, 70.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0),
            ("SYN-MBR-0002", 140.0, 110.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 10.0, 10.0),
            ("SYN-MBR-0003", 50.0, 70.0, 10.0, 5.0, 5.0, 5.0, 5.0, 5.0, 10.0, 5.0),
        ],
    }
    for severity_rank, (scenario_name, members) in enumerate(specifications.items(), start=1):
        for member in members:
            (
                member_id,
                requirement,
                resources,
                settlement,
                repo,
                funding,
                haircut,
                treasury,
                fails,
                concentration,
                buffer,
            ) = member
            rows.append(
                {
                    "member_id": member_id,
                    "scenario_name": scenario_name,
                    "severity_rank": severity_rank,
                    "stressed_liquidity_requirement_usd": requirement,
                    "available_qualified_liquid_resources_usd": resources,
                    "settlement_liquidity_need_usd": settlement,
                    "repo_rollover_need_usd": repo,
                    "incremental_funding_cost_usd": funding,
                    "additional_haircut_requirement_usd": haircut,
                    "treasury_liquidation_loss_usd": treasury,
                    "settlement_fail_requirement_usd": fails,
                    "concentration_adjustment_usd": concentration,
                    "operational_liquidity_buffer_usd": buffer,
                }
            )
    return pd.DataFrame(rows)


def test_cover_metrics_and_selection() -> None:
    settings = settings_from_config(config())
    result = analyze_cover_sets(member_frame(), settings)
    moderate = result.cover_results.loc[
        result.cover_results["scenario_name"].eq("moderate")
    ].set_index("cover_level")

    assert result.passed
    assert moderate.loc[1, "selected_member_ids_json"] == '["SYN-MBR-0001"]'
    assert moderate.loc[2, "selected_member_ids_json"] == (
        '["SYN-MBR-0001", "SYN-MBR-0002"]'
    )
    assert moderate.loc[1, "cover_stressed_requirement_usd"] == pytest.approx(100.0)
    assert moderate.loc[2, "cover_stressed_requirement_usd"] == pytest.approx(180.0)
    assert moderate.loc[1, "available_resources_usd"] == pytest.approx(80.0)
    assert moderate.loc[1, "liquidity_coverage_ratio"] == pytest.approx(0.8)
    assert moderate.loc[1, "liquidity_shortfall_usd"] == pytest.approx(20.0)
    assert moderate.loc[1, "resource_utilization_ratio"] == pytest.approx(1.25)
    assert moderate.loc[1, "dominant_stress_component"] == "settlement_liquidity_need"
    assert moderate.loc[2, "dominant_stress_component"] == "settlement_liquidity_need"
    assert result.scenario_summary.shape[0] == 2
    assert result.selected_members.shape[0] == 6
    assert result.component_summary.shape[0] == 32


def test_tie_breaking_is_deterministic() -> None:
    frame = member_frame()
    frame.loc[
        frame["scenario_name"].eq("moderate") & frame["member_id"].eq("SYN-MBR-0002"),
        "stressed_liquidity_requirement_usd",
    ] = 100.0
    frame.loc[
        frame["scenario_name"].eq("moderate") & frame["member_id"].eq("SYN-MBR-0002"),
        "operational_liquidity_buffer_usd",
    ] = 22.0
    settings = settings_from_config(config())
    result = analyze_cover_sets(frame, settings)
    cover1 = result.cover_results.loc[
        result.cover_results["scenario_name"].eq("moderate")
        & result.cover_results["cover_level"].eq(1)
    ].iloc[0]
    assert cover1["selected_member_ids_json"] == '["SYN-MBR-0001"]'
    assert deterministic_reproduction_check(frame, settings)


def test_aliases_are_resolved() -> None:
    frame = member_frame().rename(
        columns={
            "member_id": "synthetic_member_id",
            "scenario_name": "hypothetical_scenario_name",
            "stressed_liquidity_requirement_usd": "total_stressed_liquidity_requirement_usd",
            "available_qualified_liquid_resources_usd": "aqlr_usd",
        }
    )
    settings = settings_from_config(config())
    canonical = canonicalize_member_results(frame, settings)
    assert "member_id" in canonical
    assert "scenario_name" in canonical
    assert "liquidity_shortfall_usd" in canonical


def test_missing_severity_rank_is_created() -> None:
    frame = member_frame().drop(columns=["severity_rank"])
    settings = settings_from_config(config())
    canonical = canonicalize_member_results(frame, settings)
    assert canonical["severity_rank"].nunique() == 2


@pytest.mark.parametrize(
    ("mutation", "match"),
    [
        ("empty", "empty"),
        ("bad_id", "synthetic"),
        ("duplicate", "unique"),
        ("negative", "negative"),
        ("missing", "missing required"),
        ("reconciliation", "do not reconcile"),
        ("infinite", "finite"),
    ],
)
def test_invalid_member_results_are_rejected(mutation: str, match: str) -> None:
    frame = member_frame()
    if mutation == "empty":
        frame = frame.iloc[0:0]
    elif mutation == "bad_id":
        frame.loc[0, "member_id"] = "ACTUAL-MEMBER"
    elif mutation == "duplicate":
        frame = pd.concat([frame, frame.iloc[[0]]], ignore_index=True)
    elif mutation == "negative":
        frame.loc[0, "available_qualified_liquid_resources_usd"] = -1.0
    elif mutation == "missing":
        frame = frame.drop(columns=["repo_rollover_need_usd"])
    elif mutation == "reconciliation":
        current_rollover = float(
            cast(Any, frame.loc[0, "repo_rollover_need_usd"])
        )
        frame.loc[0, "repo_rollover_need_usd"] = current_rollover + 1.0
    elif mutation == "infinite":
        frame.loc[0, "repo_rollover_need_usd"] = float("inf")
    with pytest.raises(CoverAnalysisError, match=match):
        analyze_cover_sets(frame, settings_from_config(config()))


def test_scenario_with_too_few_members_is_rejected() -> None:
    frame = member_frame()
    remove_mask = frame["scenario_name"].eq("moderate") & ~frame["member_id"].eq(
        "SYN-MBR-0001"
    )
    frame = frame.loc[~remove_mask].copy()
    with pytest.raises(CoverAnalysisError, match="fewer than 2"):
        analyze_cover_sets(frame, settings_from_config(config()))


def test_configuration_validation(tmp_path: Path) -> None:
    path = tmp_path / "cover.yaml"
    path.write_text(yaml.safe_dump(config()), encoding="utf-8")
    loaded = load_cover_analysis_config(path)
    assert settings_from_config(loaded).cover_levels == (1, 2)

    with pytest.raises(CoverAnalysisError, match="not found"):
        load_cover_analysis_config(tmp_path / "missing.yaml")

    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(CoverAnalysisError, match="mapping"):
        load_cover_analysis_config(invalid)

    bad = deepcopy(config())
    bad["selection"] = {"cover_levels": [1, 3]}
    with pytest.raises(CoverAnalysisError, match="exactly"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["source"] = {"synthetic_id_pattern": "["}
    with pytest.raises(CoverAnalysisError, match="regex"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["metrics"] = {"lcr_minimum_ratio": 0.0}
    with pytest.raises(CoverAnalysisError, match="positive"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["validation"] = {"reconciliation_tolerance_usd": -1.0}
    with pytest.raises(CoverAnalysisError, match="negative"):
        settings_from_config(bad)


def test_component_configuration_validation() -> None:
    bad = deepcopy(config())
    bad["metrics"] = {"component_columns": "invalid"}
    with pytest.raises(CoverAnalysisError, match="sequence"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["metrics"] = {"component_columns": [{}]}
    with pytest.raises(CoverAnalysisError, match="nonempty"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["metrics"] = {
        "component_columns": [
            {"column": "x", "label": "x"},
            {"column": "x", "label": "y"},
        ]
    }
    with pytest.raises(CoverAnalysisError, match="unique"):
        settings_from_config(bad)
'@

$MethodologyContent = @'
# Section 22 — Cover 1 and Cover 2 Analysis

## Purpose

Section 22 converts the scenario-level synthetic member results produced by the
Phase VI scenario library into reproducible Cover 1 and Cover 2 liquidity
coverage diagnostics. The analysis is performed independently for every
historical or hypothetical scenario present in the controlled input table.

No output identifies, estimates, ranks, or infers an actual FICC participant.
All member identifiers must satisfy the configured synthetic identifier pattern.

## Selection rule

Within each scenario, synthetic members are ranked using:

1. Gross stressed liquidity requirement, descending.
2. Liquidity shortfall, descending.
3. Synthetic member identifier, ascending.

Cover 1 selects the first ranked synthetic member. Cover 2 selects the first two
ranked synthetic members. The deterministic member-identifier tie breaker
ensures that input row order cannot change the selected set.

The ranking rule is a controlled project assumption. It is not presented as a
confidential FICC methodology.

## Metrics

For each scenario and Cover standard:

```text
Cover stressed requirement = sum of selected member stressed requirements
Available resources         = sum of selected member AQLR
LCR                         = available resources / Cover stressed requirement
Liquidity shortfall         = max(Cover stressed requirement - resources, 0)
Resource utilization        = Cover stressed requirement / available resources
```

The analysis also aggregates the atomic Section 19 stress components across the
selected Cover set. The largest aggregated component is reported as the dominant
stress component. The configured component order provides a deterministic tie
breaker.

## Atomic stress components

The controlled component set is:

- Settlement liquidity need.
- Repo rollover need.
- Incremental funding cost.
- Additional haircut requirement.
- Treasury liquidation loss.
- Settlement-fail requirement.
- Concentration adjustment.
- Operational liquidity buffer.

The component sum must reconcile to the Cover stressed requirement within the
configured USD tolerance.

## Outputs

The runner creates:

- `reports/tables/cover_analysis_results.csv` and `.parquet`: one row per
  scenario and Cover standard.
- `reports/tables/cover_analysis_scenario_summary.csv` and `.parquet`: one wide
  row per scenario with explicit Cover 1 and Cover 2 fields.
- `reports/tables/cover_analysis_selected_members.csv` and `.parquet`: selected
  synthetic members and deterministic selection ranks.
- `reports/tables/cover_analysis_component_summary.csv` and `.parquet`: atomic
  component attribution and dominant-component flags.
- `reports/evidence/section22_cover_analysis.json` and `.md`: validation
  evidence.
- `data/manifests/cover_analysis_manifest.csv`: lineage and file-integrity
  metadata.

## Validation gates

The Section 22 run passes only when:

- Every scenario has exactly one Cover 1 row and one Cover 2 row.
- Cover 1 contains one synthetic member.
- Cover 2 contains two distinct synthetic members.
- Cover 2 stressed requirement is not less than Cover 1.
- Shortfall, LCR, and resource-utilization identities are valid.
- Atomic components reconcile to the stressed requirement.
- Exactly one dominant component is identified per scenario and Cover standard.
- Selection is deterministic under input-row shuffling.
- Only controlled synthetic member identifiers are present.
- Actual FICC participants are excluded.

## Limitations

The analysis uses synthetic member AQLR as the available-resource basis because
that is the controlled resource field produced by the existing model. It does
not claim to reproduce confidential legal-entity netting, settlement-bank,
liquidity-provider, or committed-facility arrangements.
'@


    Write-Utf8File -Path "configs\cover_analysis.yaml" -Content $ConfigContent
    Write-Utf8File `
        -Path "src\ficc_liquidity\scenarios\cover_analysis.py" `
        -Content $ModuleContent
    Write-Utf8File -Path "scripts\run_cover_analysis.py" -Content $RunnerContent
    Write-Utf8File -Path "tests\test_cover_analysis.py" -Content $TestContent
    Write-Utf8File `
        -Path "docs\cover_analysis_methodology.md" `
        -Content $MethodologyContent
    Write-Pass "Section 22 source, test, configuration, and methodology files written"

    $scenarioParquet = "reports\tables\hypothetical_scenario_member_results.parquet"
    $scenarioCsv = "reports\tables\hypothetical_scenario_member_results.csv"
    if (
        -not (Test-Path -LiteralPath $scenarioParquet -PathType Leaf) -and
        -not (Test-Path -LiteralPath $scenarioCsv -PathType Leaf)
    ) {
        if ($SkipSection21Run) {
            throw @"
The Section 21 scenario-member result table is missing and -SkipSection21Run was used.
Expected either:
  $scenarioParquet
  $scenarioCsv
"@
        }
        Write-Step "Generating the Section 21 hypothetical scenario member table"
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("scripts\run_hypothetical_scenarios.py") `
            -FailureMessage "Section 21 hypothetical scenario execution failed."
    }
    Write-Pass "Controlled scenario-member result table is available"

    Write-Step "Formatting and linting Section 22 Python files"
    $pythonFiles = @(
        "src\ficc_liquidity\scenarios\cover_analysis.py",
        "scripts\run_cover_analysis.py",
        "tests\test_cover_analysis.py"
    )
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "format") + $pythonFiles) `
        -FailureMessage "Ruff formatting failed."
    Invoke-Checked -FilePath $Python `
        -ArgumentList (@("-m", "ruff", "check") + $pythonFiles) `
        -FailureMessage "Ruff validation failed."

    Write-Step "Running strict Mypy validation"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "mypy",
            "src\ficc_liquidity\scenarios\cover_analysis.py",
            "scripts\run_cover_analysis.py",
            "tests\test_cover_analysis.py"
        ) `
        -FailureMessage "Strict Mypy validation failed."

    Write-Step "Running focused Section 22 tests"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "pytest", "-q",
            "tests\test_cover_analysis.py",
            "--no-cov"
        ) `
        -FailureMessage "Focused Section 22 tests failed."

    Write-Step "Executing Cover 1 and Cover 2 analysis"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "scripts\run_cover_analysis.py",
            "--config", "configs\cover_analysis.yaml",
            "--repo-root", $RepoPath
        ) `
        -FailureMessage "Section 22 controlled model run failed."

    $requiredOutputs = @(
        "reports\tables\cover_analysis_results.csv",
        "reports\tables\cover_analysis_results.parquet",
        "reports\tables\cover_analysis_scenario_summary.csv",
        "reports\tables\cover_analysis_scenario_summary.parquet",
        "reports\tables\cover_analysis_selected_members.csv",
        "reports\tables\cover_analysis_selected_members.parquet",
        "reports\tables\cover_analysis_component_summary.csv",
        "reports\tables\cover_analysis_component_summary.parquet",
        "reports\evidence\section22_cover_analysis.json",
        "reports\evidence\section22_cover_analysis.md",
        "data\manifests\cover_analysis_manifest.csv"
    )
    if (-not (Test-RequiredFiles -Paths $requiredOutputs)) {
        $missingOutputs = @(
            foreach ($path in $requiredOutputs) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $path
                }
            }
        )
        throw "Section 22 outputs are incomplete: $($missingOutputs -join ', ')"
    }
    Write-Pass "Section 22 tables, evidence, and manifest were created"

    Write-Step "Validating evidence and scenario coverage"
    $evidence = Get-Content `
        -LiteralPath "reports\evidence\section22_cover_analysis.json" `
        -Raw | ConvertFrom-Json
    if ($evidence.final_decision -ne "PASS") {
        throw "Section 22 evidence final decision is not PASS."
    }
    if ([int]$evidence.scenario_count -lt 1) {
        throw "Section 22 did not analyze any scenarios."
    }

    $scenarioSummary = Import-Csv "reports\tables\cover_analysis_scenario_summary.csv"
    $requiredSummaryColumns = @(
        "cover_1_stressed_requirement_usd",
        "cover_2_stressed_requirement_usd",
        "cover_1_available_resources_usd",
        "cover_2_available_resources_usd",
        "cover_1_liquidity_coverage_ratio",
        "cover_2_liquidity_coverage_ratio",
        "cover_1_liquidity_shortfall_usd",
        "cover_2_liquidity_shortfall_usd",
        "cover_1_resource_utilization_ratio",
        "cover_2_resource_utilization_ratio",
        "cover_1_dominant_stress_component",
        "cover_2_dominant_stress_component"
    )
    $actualColumns = @($scenarioSummary[0].PSObject.Properties.Name)
    foreach ($column in $requiredSummaryColumns) {
        if ($column -notin $actualColumns) {
            throw "Required Section 22 summary column is missing: $column"
        }
    }
    Write-Pass "Every scenario contains the required Cover 1 and Cover 2 metrics"

    if (-not $SkipFullTests) {
        Write-Step "Running complete repository test suite with coverage gate"
        Invoke-Checked -FilePath $Python `
            -ArgumentList @("-m", "pytest", "-q") `
            -FailureMessage "Complete repository test suite failed."
    }
    else {
        Write-Warn "Complete repository test suite was skipped."
    }

    if (-not $SkipGit) {
        Write-Step "Checking Git diff integrity"
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("diff", "--check") `
            -FailureMessage "Git diff whitespace validation failed."

        $controlledPaths = @(
            $AutomationFileName,
            $AutomationRelativePath,
            "configs\cover_analysis.yaml",
            "src\ficc_liquidity\scenarios\cover_analysis.py",
            "scripts\run_cover_analysis.py",
            "tests\test_cover_analysis.py",
            "docs\cover_analysis_methodology.md"
        ) + $requiredOutputs

        foreach ($path in $controlledPaths) {
            Add-ControlledPath -Path $path
        }

        & git diff --cached --quiet
        $hasStagedChanges = $LASTEXITCODE -ne 0
        if ($hasStagedChanges -and -not $NoCommit) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("commit", "-m", $CommitMessage) `
                -FailureMessage "Unable to commit Section 22 changes."
            Write-Pass "Section 22 changes committed"
        }
        elseif ($hasStagedChanges) {
            Write-Warn "Changes are staged but were not committed because -NoCommit was used."
        }
        else {
            Write-Warn "No new Section 22 changes required a commit."
        }

        if (-not $SkipPush -and -not $NoCommit) {
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("push", "-u", "origin", $BranchName) `
                -FailureMessage "Unable to push $BranchName."
            Write-Pass "Shared scenario-library branch pushed"
        }
        elseif ($SkipPush) {
            Write-Warn "Push was skipped."
        }
    }

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Green
    Write-Host "SECTION 22 COMPLETED" -ForegroundColor Green
    Write-Host ("=" * 78) -ForegroundColor Green
    Write-Host "Branch: $BranchName"
    Write-Host "Scenarios analyzed: $($evidence.scenario_count)"
    Write-Host "Cover result rows: $($evidence.cover_result_rows)"
    Write-Host "Evidence: reports\evidence\section22_cover_analysis.md"
    Write-Host "Scenario summary: reports\tables\cover_analysis_scenario_summary.csv"
    Write-Host ""
    Write-Host "No pull request was opened. Continue Section 23 on the same branch."
}
catch {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Red
    Write-Host "SECTION 22 FAILED" -ForegroundColor Red
    Write-Host ("=" * 78) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    Set-Location $OriginalLocation
}
