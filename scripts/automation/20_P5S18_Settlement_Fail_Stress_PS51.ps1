#requires -Version 5.1
<#
.SYNOPSIS
    Completes Phase V, Section 18: settlement-fail stress.

.DESCRIPTION
    Run this single PowerShell automation from the VS Code PowerShell terminal.

    The automation updates main, prepares feature/16-settlement-fails, writes the
    controlled YAML configuration, Python model, runner, tests, methodology,
    lineage manifest, evidence, and output tables; executes the Section 16 repo
    funding model needed for combined shocks; validates Section 18 with Ruff,
    strict Mypy, focused branch coverage, the controlled model run, and the full
    repository test suite; then commits, pushes, and opens a pull request.

    Implemented channels:
      - Fails to receive
      - Fails to deliver
      - Delayed incoming payments
      - Required replacement liquidity
      - Persistent multi-day fails
      - Combined settlement and funding shocks

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & "$env:USERPROFILE\Downloads\20_P5S18_Settlement_Fail_Stress_PS51.ps1"

.EXAMPLE
    & "$env:USERPROFILE\Downloads\20_P5S18_Settlement_Fail_Stress_PS51.ps1" `
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
$BranchName = "feature/16-settlement-fails"
$CommitMessage = "Phase V Section 18: add settlement-fail stress"
$PullRequestTitle = "Phase V Section 18: Settlement-fail stress"
$AutomationRelativePath = "scripts\automation\20_P5S18_Settlement_Fail_Stress_PS51.ps1"

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
Use -AllowDirty only when rerunning Section 18 on its feature branch.
"@
            }
            if ($currentBranch -ne $BranchName) {
                throw @"
-AllowDirty is safe only when the current branch is $BranchName.
The current branch is $currentBranch. Commit or stash existing changes first.
"@
            }
            $skipBranchRefresh = $true
            Write-Warn "Dirty Section 18 branch retained; main refresh and merge were skipped."
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
        "configs\repo_funding_stress.yaml",
        "src\ficc_liquidity\stress\repo_funding_stress.py",
        "scripts\run_repo_funding_stress.py",
        "configs\collateral_haircut_stress.yaml",
        "src\ficc_liquidity\stress\collateral_haircut_stress.py"
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
    Write-Pass "Sections 12, 14, 16, and 17 dependencies are available"

    Write-Step "Creating Section 18 directories and controlled files"
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
section: 18
model_name: settlement_fail_stress
model_version: "section-18-v1"
currency: USD
random_seed: 2026

classification:
  baseline_cash_flows: modeled
  synthetic_member_profiles: synthetic
  settlement_fail_assumptions: assumed
  repo_funding_stress_results: modeled
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
  funding_stress_candidates:
    - reports/tables/repo_funding_stress_cashflows.parquet
    - reports/tables/repo_funding_stress_cashflows.csv
  synthetic_id_pattern: '^SYN-MBR-[0-9]{4}$'

assumptions:
  liquidity_horizon_hours: 48
  fails_to_receive_share: 0.50
  fails_to_deliver_share: 0.50
  incoming_settlement_receipt_ratio: 0.85
  persistence_liquidity_rate: 0.20
  fail_penalty_rate_per_day: 0.0005

scenarios:
  - name: control
    enabled: true
    severity_rank: 0
    fails_to_receive_multiplier: 0.0
    fails_to_deliver_multiplier: 0.0
    additional_fails_to_receive_rate: 0.0
    additional_fails_to_deliver_rate: 0.0
    incoming_payment_delay_buckets: 0
    replacement_liquidity_rate: 0.0
    persistence_days: 1
    persistence_decay: 0.0
    funding_scenario_name: control
    funding_stress_weight: 0.0

  - name: moderate_settlement_disruption
    enabled: true
    severity_rank: 1
    fails_to_receive_multiplier: 1.50
    fails_to_deliver_multiplier: 1.25
    additional_fails_to_receive_rate: 0.02
    additional_fails_to_deliver_rate: 0.01
    incoming_payment_delay_buckets: 1
    replacement_liquidity_rate: 1.00
    persistence_days: 2
    persistence_decay: 0.70
    funding_scenario_name: moderate_market_stress
    funding_stress_weight: 0.50

  - name: severe_multi_day_fails
    enabled: true
    severity_rank: 2
    fails_to_receive_multiplier: 2.50
    fails_to_deliver_multiplier: 2.00
    additional_fails_to_receive_rate: 0.05
    additional_fails_to_deliver_rate: 0.03
    incoming_payment_delay_buckets: 2
    replacement_liquidity_rate: 1.10
    persistence_days: 4
    persistence_decay: 0.80
    funding_scenario_name: severe_market_stress
    funding_stress_weight: 0.75

  - name: combined_settlement_funding_crisis
    enabled: true
    severity_rank: 3
    fails_to_receive_multiplier: 4.00
    fails_to_deliver_multiplier: 3.00
    additional_fails_to_receive_rate: 0.10
    additional_fails_to_deliver_rate: 0.07
    incoming_payment_delay_buckets: 4
    replacement_liquidity_rate: 1.25
    persistence_days: 7
    persistence_decay: 0.90
    funding_scenario_name: concentrated_funding_freeze
    funding_stress_weight: 1.00

validation:
  reconciliation_tolerance_usd: 0.01
  require_deterministic_reproduction: true
  require_synthetic_identifiers: true
  require_all_six_stress_channels: true
  require_section16_combination: true

output:
  directory: reports/tables
  evidence_directory: reports/evidence
  manifest: data/manifests/settlement_fail_stress_manifest.csv
  write_csv: true
  write_parquet: true
'@

$ModuleContent = @'
"""Settlement-fail stress for synthetic clearing-member liquidity analysis.

Section 18 models fails to receive, fails to deliver, delayed incoming payments,
replacement liquidity, persistent multi-day fails, and combined settlement and
repo-funding shocks. All member records are fictional and synthetic.
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


class SettlementFailStressError(ValueError):
    """Raised when Section 18 inputs or assumptions are invalid."""


@dataclass(frozen=True, slots=True)
class SettlementFailScenario:
    """One controlled settlement-fail scenario."""

    name: str
    severity_rank: int
    fails_to_receive_multiplier: float
    fails_to_deliver_multiplier: float
    additional_fails_to_receive_rate: float
    additional_fails_to_deliver_rate: float
    incoming_payment_delay_buckets: int
    replacement_liquidity_rate: float
    persistence_days: int
    persistence_decay: float
    funding_scenario_name: str
    funding_stress_weight: float


@dataclass(frozen=True, slots=True)
class SettlementFailStressSettings:
    """Validated Section 18 settings."""

    model_version: str
    liquidity_horizon_hours: int
    fails_to_receive_share: float
    fails_to_deliver_share: float
    incoming_settlement_receipt_ratio: float
    persistence_liquidity_rate: float
    fail_penalty_rate_per_day: float
    tolerance_usd: float
    synthetic_id_pattern: str
    scenarios: tuple[SettlementFailScenario, ...]


@dataclass(frozen=True, slots=True)
class SettlementFailStressResult:
    """Section 18 outputs and validation checks."""

    cashflows: pd.DataFrame
    member_summary: pd.DataFrame
    scenario_summary: pd.DataFrame
    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when all validation checks pass."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SettlementFailStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SettlementFailStressError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise SettlementFailStressError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise SettlementFailStressError(f"{key} must be an integer.")
    return int(value)


def _bounded_rate(value: float, label: str) -> None:
    if not 0.0 <= value <= 1.0:
        raise SettlementFailStressError(f"{label} must be between zero and one.")


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled Section 18 YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise SettlementFailStressError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _load_scenario(raw: Mapping[str, Any]) -> SettlementFailScenario:
    scenario = SettlementFailScenario(
        name=str(raw.get("name", "")).strip(),
        severity_rank=_integer(raw, "severity_rank"),
        fails_to_receive_multiplier=_number(raw, "fails_to_receive_multiplier"),
        fails_to_deliver_multiplier=_number(raw, "fails_to_deliver_multiplier"),
        additional_fails_to_receive_rate=_number(
            raw, "additional_fails_to_receive_rate"
        ),
        additional_fails_to_deliver_rate=_number(
            raw, "additional_fails_to_deliver_rate"
        ),
        incoming_payment_delay_buckets=_integer(
            raw, "incoming_payment_delay_buckets"
        ),
        replacement_liquidity_rate=_number(raw, "replacement_liquidity_rate"),
        persistence_days=_integer(raw, "persistence_days"),
        persistence_decay=_number(raw, "persistence_decay"),
        funding_scenario_name=str(raw.get("funding_scenario_name", "")).strip(),
        funding_stress_weight=_number(raw, "funding_stress_weight"),
    )
    if not scenario.name:
        raise SettlementFailStressError("Every scenario must have a nonempty name.")
    if scenario.severity_rank < 0:
        raise SettlementFailStressError("severity_rank must be nonnegative.")
    if scenario.fails_to_receive_multiplier < 0.0:
        raise SettlementFailStressError(
            "fails_to_receive_multiplier must be nonnegative."
        )
    if scenario.fails_to_deliver_multiplier < 0.0:
        raise SettlementFailStressError(
            "fails_to_deliver_multiplier must be nonnegative."
        )
    for label, value in (
        (
            "additional_fails_to_receive_rate",
            scenario.additional_fails_to_receive_rate,
        ),
        (
            "additional_fails_to_deliver_rate",
            scenario.additional_fails_to_deliver_rate,
        ),
        ("persistence_decay", scenario.persistence_decay),
        ("funding_stress_weight", scenario.funding_stress_weight),
    ):
        _bounded_rate(value, f"{scenario.name}.{label}")
    if scenario.incoming_payment_delay_buckets < 0:
        raise SettlementFailStressError(
            "incoming_payment_delay_buckets must be nonnegative."
        )
    if scenario.replacement_liquidity_rate < 0.0:
        raise SettlementFailStressError(
            "replacement_liquidity_rate must be nonnegative."
        )
    if scenario.persistence_days <= 0:
        raise SettlementFailStressError("persistence_days must be positive.")
    if scenario.funding_stress_weight > 0.0 and not scenario.funding_scenario_name:
        raise SettlementFailStressError(
            "A funding scenario name is required when funding_stress_weight is positive."
        )
    return scenario


def load_settings(config: Mapping[str, Any]) -> SettlementFailStressSettings:
    """Validate and convert the Section 18 configuration."""
    assumptions = _mapping(config.get("assumptions"), "assumptions")
    validation = _mapping(config.get("validation"), "validation")
    source = _mapping(config.get("source"), "source")
    raw_scenarios = config.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise SettlementFailStressError("scenarios must be a nonempty list.")

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
        raise SettlementFailStressError("At least one enabled scenario is required.")
    if len({item.name for item in scenarios}) != len(scenarios):
        raise SettlementFailStressError("Scenario names must be unique.")
    if len({item.severity_rank for item in scenarios}) != len(scenarios):
        raise SettlementFailStressError("Scenario severity ranks must be unique.")

    settings = SettlementFailStressSettings(
        model_version=str(config.get("model_version", "section-18-v1")).strip(),
        liquidity_horizon_hours=_integer(assumptions, "liquidity_horizon_hours"),
        fails_to_receive_share=_number(assumptions, "fails_to_receive_share"),
        fails_to_deliver_share=_number(assumptions, "fails_to_deliver_share"),
        incoming_settlement_receipt_ratio=_number(
            assumptions, "incoming_settlement_receipt_ratio"
        ),
        persistence_liquidity_rate=_number(
            assumptions, "persistence_liquidity_rate"
        ),
        fail_penalty_rate_per_day=_number(
            assumptions, "fail_penalty_rate_per_day"
        ),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        synthetic_id_pattern=str(
            source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")
        ),
        scenarios=scenarios,
    )
    if not settings.model_version:
        raise SettlementFailStressError("model_version must be populated.")
    if settings.liquidity_horizon_hours <= 0:
        raise SettlementFailStressError("liquidity_horizon_hours must be positive.")
    for label, value in (
        ("fails_to_receive_share", settings.fails_to_receive_share),
        ("fails_to_deliver_share", settings.fails_to_deliver_share),
        (
            "incoming_settlement_receipt_ratio",
            settings.incoming_settlement_receipt_ratio,
        ),
        ("persistence_liquidity_rate", settings.persistence_liquidity_rate),
    ):
        _bounded_rate(value, label)
    if not math.isclose(
        settings.fails_to_receive_share + settings.fails_to_deliver_share,
        1.0,
        abs_tol=1e-12,
    ):
        raise SettlementFailStressError(
            "Fails-to-receive and fails-to-deliver shares must sum to one."
        )
    if settings.fail_penalty_rate_per_day < 0.0:
        raise SettlementFailStressError(
            "fail_penalty_rate_per_day must be nonnegative."
        )
    if settings.tolerance_usd < 0.0:
        raise SettlementFailStressError(
            "reconciliation_tolerance_usd must be nonnegative."
        )

    previous: SettlementFailScenario | None = None
    for scenario in settings.scenarios:
        if previous is not None:
            monotonic_pairs = (
                (
                    scenario.fails_to_receive_multiplier,
                    previous.fails_to_receive_multiplier,
                ),
                (
                    scenario.fails_to_deliver_multiplier,
                    previous.fails_to_deliver_multiplier,
                ),
                (
                    scenario.additional_fails_to_receive_rate,
                    previous.additional_fails_to_receive_rate,
                ),
                (
                    scenario.additional_fails_to_deliver_rate,
                    previous.additional_fails_to_deliver_rate,
                ),
                (scenario.persistence_days, previous.persistence_days),
                (scenario.funding_stress_weight, previous.funding_stress_weight),
            )
            if any(current < prior for current, prior in monotonic_pairs):
                raise SettlementFailStressError(
                    "Core stress assumptions must be nondecreasing by severity."
                )
        previous = scenario
    return settings


def read_table(path: str | Path) -> pd.DataFrame:
    """Read a CSV or Parquet table."""
    table_path = Path(path)
    if not table_path.exists():
        raise SettlementFailStressError(f"Input table does not exist: {table_path}")
    if table_path.suffix.lower() == ".csv":
        return pd.read_csv(table_path)
    if table_path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(table_path)
    raise SettlementFailStressError("Input tables must be CSV or Parquet.")


def dataframe_digest(frame: pd.DataFrame) -> str:
    """Return a deterministic SHA-256 digest for a result frame."""
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


def _validate_synthetic_identity(
    frame: pd.DataFrame,
    synthetic_id_pattern: str,
) -> None:
    if "member_id" not in frame.columns:
        raise SettlementFailStressError("Synthetic inputs require member_id.")
    member_ids = frame["member_id"].astype("string").str.strip()
    if member_ids.isna().any() or (member_ids == "").any():
        raise SettlementFailStressError(
            "Synthetic member identifiers cannot be missing."
        )
    invalid = [
        member_id
        for member_id in member_ids.astype(str)
        if re.fullmatch(synthetic_id_pattern, member_id) is None
    ]
    if invalid:
        raise SettlementFailStressError(
            f"Non-synthetic or invalid member identifiers detected: {sorted(set(invalid))}"
        )
    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise SettlementFailStressError(
            "Actual FICC participant records are prohibited."
        )
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise SettlementFailStressError(
            "Participant-level inference records are prohibited."
        )
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise SettlementFailStressError(
            "Every member record must use value_class='synthetic'."
        )


def _numeric(frame: pd.DataFrame, columns: list[str], *, nonnegative: bool) -> None:
    for column in columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise SettlementFailStressError(
                f"{column} contains missing or nonfinite values."
            )
        if nonnegative and (frame[column] < 0.0).any():
            raise SettlementFailStressError(f"{column} must be nonnegative.")


def prepare_members(
    members: pd.DataFrame,
    settings: SettlementFailStressSettings,
) -> pd.DataFrame:
    """Validate and canonicalize synthetic settlement-fail profiles."""
    if members.empty:
        raise SettlementFailStressError("Synthetic member input is empty.")
    required = {
        "member_id",
        "settlement_obligation_usd",
        "settlement_fail_usd",
    }
    missing = sorted(required - set(members.columns))
    if missing:
        raise SettlementFailStressError(
            f"Required synthetic-member fields are missing: {missing}"
        )
    frame = members.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame["member_id"].duplicated().any():
        raise SettlementFailStressError(
            "Synthetic member identifiers must be unique."
        )
    _numeric(
        frame,
        ["settlement_obligation_usd", "settlement_fail_usd"],
        nonnegative=True,
    )
    if (frame["settlement_obligation_usd"] <= 0.0).any():
        raise SettlementFailStressError(
            "settlement_obligation_usd must be positive."
        )
    if (frame["settlement_fail_usd"] > frame["settlement_obligation_usd"]).any():
        raise SettlementFailStressError(
            "Settlement fails cannot exceed settlement obligations."
        )
    computed_rate = frame["settlement_fail_usd"] / frame["settlement_obligation_usd"]
    if "settlement_fail_rate" in frame.columns:
        _numeric(frame, ["settlement_fail_rate"], nonnegative=True)
        if (frame["settlement_fail_rate"] > 1.0).any():
            raise SettlementFailStressError(
                "settlement_fail_rate must be between zero and one."
            )
        if (
            (frame["settlement_fail_rate"] - computed_rate).abs()
            > max(settings.tolerance_usd / 1_000_000.0, 1e-10)
        ).any():
            raise SettlementFailStressError(
                "settlement_fail_rate is inconsistent with fail amounts."
            )
    frame["settlement_fail_rate"] = computed_rate
    frame["base_fails_to_receive_usd"] = (
        frame["settlement_fail_usd"] * settings.fails_to_receive_share
    )
    frame["base_fails_to_deliver_usd"] = (
        frame["settlement_fail_usd"] * settings.fails_to_deliver_share
    )
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values("member_id", kind="stable").reset_index(drop=True)


def prepare_baseline(
    baseline: pd.DataFrame,
    settings: SettlementFailStressSettings,
) -> pd.DataFrame:
    """Validate Section 14 baseline cash flows."""
    if baseline.empty:
        raise SettlementFailStressError("Baseline liquidity input is empty.")
    required = {
        "member_id",
        "bucket_order",
        "time_bucket",
        "elapsed_hours",
        "liquidity_horizon_hours",
        "gross_settlement_obligation_usd",
        "total_cash_outflow_usd",
        "total_cash_inflow_usd",
        "cumulative_available_resources_usd",
    }
    missing = sorted(required - set(baseline.columns))
    if missing:
        raise SettlementFailStressError(
            f"Required baseline fields are missing: {missing}"
        )
    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame.duplicated(["member_id", "time_bucket"]).any():
        raise SettlementFailStressError(
            "Baseline member and time-bucket combinations must be unique."
        )
    numeric_columns = sorted(required - {"member_id", "time_bucket"})
    _numeric(frame, numeric_columns, nonnegative=True)
    if not frame["liquidity_horizon_hours"].eq(
        settings.liquidity_horizon_hours
    ).all():
        raise SettlementFailStressError(
            "Baseline liquidity horizon does not match Section 18 configuration."
        )
    ordered = frame.sort_values(
        ["member_id", "bucket_order"], kind="stable"
    ).reset_index(drop=True)
    if not ordered.groupby("member_id")["elapsed_hours"].apply(
        lambda values: values.is_monotonic_increasing
    ).all():
        raise SettlementFailStressError(
            "Baseline time buckets must be chronologically ordered."
        )
    ordered["value_class"] = "synthetic"
    ordered["actual_ficc_participant"] = False
    ordered["participant_level_inference"] = False
    return ordered


def prepare_funding(
    funding: pd.DataFrame,
    settings: SettlementFailStressSettings,
) -> pd.DataFrame:
    """Validate Section 16 incremental funding-stress cash flows."""
    if funding.empty:
        raise SettlementFailStressError("Repo funding-stress input is empty.")
    required = {
        "member_id",
        "bucket_order",
        "time_bucket",
        "scenario_name",
        "incremental_repo_funding_stress_outflow_usd",
    }
    missing = sorted(required - set(funding.columns))
    if missing:
        raise SettlementFailStressError(
            f"Required Section 16 funding fields are missing: {missing}"
        )
    frame = funding.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    _numeric(
        frame,
        ["bucket_order", "incremental_repo_funding_stress_outflow_usd"],
        nonnegative=True,
    )
    if frame.duplicated(["scenario_name", "member_id", "time_bucket"]).any():
        raise SettlementFailStressError(
            "Section 16 scenario, member, and bucket keys must be unique."
        )
    return frame.sort_values(
        ["scenario_name", "member_id", "bucket_order"], kind="stable"
    ).reset_index(drop=True)


def _persistence_factor(days: int, decay: float) -> float:
    return sum(decay**day for day in range(days))


def _cumulative_floor(values: pd.Series) -> pd.Series:
    running = 0.0
    result: list[float] = []
    for value in values.astype(float):
        running = max(running + value, 0.0)
        result.append(running)
    return pd.Series(result, index=values.index, dtype=float)


def _scenario_cashflows(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
    scenario: SettlementFailScenario,
    settings: SettlementFailStressSettings,
) -> pd.DataFrame:
    frame = baseline.merge(
        members[
            [
                "member_id",
                "settlement_obligation_usd",
                "settlement_fail_usd",
                "settlement_fail_rate",
                "base_fails_to_receive_usd",
                "base_fails_to_deliver_usd",
            ]
        ],
        on="member_id",
        how="left",
        validate="many_to_one",
    )
    if frame["settlement_fail_usd"].isna().any():
        raise SettlementFailStressError(
            "Every baseline member must have a synthetic settlement-fail profile."
        )

    member_gross = frame.groupby("member_id")[
        "gross_settlement_obligation_usd"
    ].transform("sum")
    if (member_gross <= 0.0).any():
        raise SettlementFailStressError(
            "Every baseline member requires positive gross settlement obligations."
        )
    frame["settlement_bucket_weight"] = (
        frame["gross_settlement_obligation_usd"] / member_gross
    )
    frame["expected_incoming_settlement_payment_usd"] = (
        frame["gross_settlement_obligation_usd"]
        * settings.incoming_settlement_receipt_ratio
    )
    frame["base_fails_to_receive_bucket_usd"] = (
        frame["base_fails_to_receive_usd"] * frame["settlement_bucket_weight"]
    )
    frame["base_fails_to_deliver_bucket_usd"] = (
        frame["base_fails_to_deliver_usd"] * frame["settlement_bucket_weight"]
    )
    frame["fails_to_receive_usd"] = (
        frame["base_fails_to_receive_bucket_usd"]
        * scenario.fails_to_receive_multiplier
        + frame["expected_incoming_settlement_payment_usd"]
        * scenario.additional_fails_to_receive_rate
    ).clip(upper=frame["expected_incoming_settlement_payment_usd"])
    frame["fails_to_deliver_usd"] = (
        frame["base_fails_to_deliver_bucket_usd"]
        * scenario.fails_to_deliver_multiplier
        + frame["gross_settlement_obligation_usd"]
        * scenario.additional_fails_to_deliver_rate
    ).clip(upper=frame["gross_settlement_obligation_usd"])

    frame["delayed_incoming_payment_outflow_usd"] = frame[
        "fails_to_receive_usd"
    ]
    frame["delayed_incoming_payment_recovery_usd"] = 0.0
    delay = scenario.incoming_payment_delay_buckets
    if delay == 0:
        frame["delayed_incoming_payment_recovery_usd"] = frame[
            "fails_to_receive_usd"
        ]
    else:
        for _, index_values in frame.groupby("member_id", sort=False).groups.items():
            indices = list(index_values)
            for position, source_index in enumerate(indices):
                target_position = position + delay
                if target_position < len(indices):
                    target_index = indices[target_position]
                    frame.loc[
                        target_index,
                        "delayed_incoming_payment_recovery_usd",
                    ] += float(frame.loc[source_index, "fails_to_receive_usd"])

    frame["required_replacement_liquidity_usd"] = (
        frame["fails_to_deliver_usd"] * scenario.replacement_liquidity_rate
    )
    persistence_factor = _persistence_factor(
        scenario.persistence_days,
        scenario.persistence_decay,
    )
    frame["persistence_factor"] = persistence_factor
    frame["persistent_multi_day_fail_liquidity_usd"] = (
        (frame["fails_to_receive_usd"] + frame["fails_to_deliver_usd"])
        * max(persistence_factor - 1.0, 0.0)
        * settings.persistence_liquidity_rate
    )
    frame["settlement_fail_penalty_usd"] = (
        frame["fails_to_deliver_usd"]
        * settings.fail_penalty_rate_per_day
        * scenario.persistence_days
    )

    funding_scenario = funding.loc[
        funding["scenario_name"].astype(str).eq(scenario.funding_scenario_name),
        [
            "member_id",
            "time_bucket",
            "incremental_repo_funding_stress_outflow_usd",
        ],
    ].rename(
        columns={
            "incremental_repo_funding_stress_outflow_usd": (
                "section16_incremental_funding_outflow_usd"
            )
        }
    )
    if scenario.funding_stress_weight > 0.0 and funding_scenario.empty:
        raise SettlementFailStressError(
            f"Section 16 scenario was not found: {scenario.funding_scenario_name}"
        )
    frame = frame.merge(
        funding_scenario,
        on=["member_id", "time_bucket"],
        how="left",
        validate="one_to_one",
    )
    frame["section16_incremental_funding_outflow_usd"] = frame[
        "section16_incremental_funding_outflow_usd"
    ].fillna(0.0)
    if (
        scenario.funding_stress_weight > 0.0
        and frame["section16_incremental_funding_outflow_usd"].eq(0.0).all()
    ):
        raise SettlementFailStressError(
            "The selected Section 16 scenario contains no incremental funding stress."
        )
    frame["combined_funding_shock_outflow_usd"] = (
        frame["section16_incremental_funding_outflow_usd"]
        * scenario.funding_stress_weight
    )
    frame["incremental_settlement_fail_outflow_usd"] = (
        frame["delayed_incoming_payment_outflow_usd"]
        + frame["required_replacement_liquidity_usd"]
        + frame["persistent_multi_day_fail_liquidity_usd"]
        + frame["settlement_fail_penalty_usd"]
    )
    frame["incremental_combined_stress_outflow_usd"] = (
        frame["incremental_settlement_fail_outflow_usd"]
        + frame["combined_funding_shock_outflow_usd"]
    )
    frame["stressed_total_cash_outflow_usd"] = (
        frame["total_cash_outflow_usd"]
        + frame["incremental_combined_stress_outflow_usd"]
    )
    frame["stressed_total_cash_inflow_usd"] = (
        frame["total_cash_inflow_usd"]
        + frame["delayed_incoming_payment_recovery_usd"]
    )
    frame["stressed_net_liquidity_outflow_usd"] = (
        frame["stressed_total_cash_outflow_usd"]
        - frame["stressed_total_cash_inflow_usd"]
    )
    frame["stressed_cumulative_net_liquidity_need_usd"] = frame.groupby(
        "member_id", sort=False, group_keys=False
    )["stressed_net_liquidity_outflow_usd"].apply(_cumulative_floor)
    frame["stressed_liquidity_headroom_usd"] = (
        frame["cumulative_available_resources_usd"]
        - frame["stressed_cumulative_net_liquidity_need_usd"]
    )
    frame["stressed_liquidity_shortfall_usd"] = (
        -frame["stressed_liquidity_headroom_usd"]
    ).clip(lower=0.0)
    frame["scenario_name"] = scenario.name
    frame["severity_rank"] = scenario.severity_rank
    frame["incoming_payment_delay_buckets"] = delay
    frame["replacement_liquidity_rate"] = scenario.replacement_liquidity_rate
    frame["persistence_days"] = scenario.persistence_days
    frame["persistence_decay"] = scenario.persistence_decay
    frame["funding_scenario_name"] = scenario.funding_scenario_name
    frame["funding_stress_weight"] = scenario.funding_stress_weight
    frame["model_version"] = settings.model_version
    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values(
        ["member_id", "bucket_order"], kind="stable"
    ).reset_index(drop=True)


def _member_summary(cashflows: pd.DataFrame) -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for (scenario_name, severity_rank, member_id), group in cashflows.groupby(
        ["scenario_name", "severity_rank", "member_id"], sort=True
    ):
        ordered = group.sort_values("bucket_order", kind="stable")
        first_shortfall = ordered.loc[
            ordered["stressed_liquidity_shortfall_usd"] > 0.01,
            "time_bucket",
        ]
        peak_need = float(
            ordered["stressed_cumulative_net_liquidity_need_usd"].max()
        )
        final_resources = float(ordered["cumulative_available_resources_usd"].iloc[-1])
        rows.append(
            {
                "scenario_name": str(scenario_name),
                "severity_rank": int(cast(Any, severity_rank)),
                "member_id": str(member_id),
                "fails_to_receive_usd": float(ordered["fails_to_receive_usd"].sum()),
                "fails_to_deliver_usd": float(ordered["fails_to_deliver_usd"].sum()),
                "required_replacement_liquidity_usd": float(
                    ordered["required_replacement_liquidity_usd"].sum()
                ),
                "persistent_multi_day_fail_liquidity_usd": float(
                    ordered["persistent_multi_day_fail_liquidity_usd"].sum()
                ),
                "combined_funding_shock_outflow_usd": float(
                    ordered["combined_funding_shock_outflow_usd"].sum()
                ),
                "incremental_combined_stress_outflow_usd": float(
                    ordered["incremental_combined_stress_outflow_usd"].sum()
                ),
                "peak_stressed_liquidity_need_usd": peak_need,
                "maximum_stressed_liquidity_shortfall_usd": float(
                    ordered["stressed_liquidity_shortfall_usd"].max()
                ),
                "minimum_stressed_liquidity_headroom_usd": float(
                    ordered["stressed_liquidity_headroom_usd"].min()
                ),
                "stressed_liquidity_coverage_ratio": final_resources
                / max(peak_need, 0.01),
                "first_shortfall_bucket": (
                    str(first_shortfall.iloc[0]) if not first_shortfall.empty else ""
                ),
                "settlement_fail_status": (
                    "COVERED"
                    if float(ordered["stressed_liquidity_shortfall_usd"].max())
                    <= 0.01
                    else "SHORTFALL"
                ),
                "model_version": str(ordered["model_version"].iloc[0]),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return pd.DataFrame.from_records(rows).sort_values(
        ["severity_rank", "member_id"], kind="stable"
    ).reset_index(drop=True)


def _scenario_summary(member_summary: pd.DataFrame) -> pd.DataFrame:
    grouped = member_summary.groupby(
        ["scenario_name", "severity_rank"], sort=True
    )
    summary = grouped.agg(
        member_count=("member_id", "nunique"),
        total_fails_to_receive_usd=("fails_to_receive_usd", "sum"),
        total_fails_to_deliver_usd=("fails_to_deliver_usd", "sum"),
        total_replacement_liquidity_usd=(
            "required_replacement_liquidity_usd",
            "sum",
        ),
        total_persistent_fail_liquidity_usd=(
            "persistent_multi_day_fail_liquidity_usd",
            "sum",
        ),
        total_combined_funding_shock_usd=(
            "combined_funding_shock_outflow_usd",
            "sum",
        ),
        total_incremental_combined_stress_usd=(
            "incremental_combined_stress_outflow_usd",
            "sum",
        ),
        peak_stressed_liquidity_need_usd=(
            "peak_stressed_liquidity_need_usd",
            "sum",
        ),
        maximum_member_shortfall_usd=(
            "maximum_stressed_liquidity_shortfall_usd",
            "max",
        ),
        total_member_shortfall_usd=(
            "maximum_stressed_liquidity_shortfall_usd",
            "sum",
        ),
        shortfall_member_count=(
            "settlement_fail_status",
            lambda values: int((values == "SHORTFALL").sum()),
        ),
    ).reset_index()
    return summary.sort_values("severity_rank", kind="stable").reset_index(drop=True)


def validate_results(
    cashflows: pd.DataFrame,
    member_summary: pd.DataFrame,
    scenario_summary: pd.DataFrame,
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    settings: SettlementFailStressSettings,
) -> dict[str, bool]:
    """Validate Section 18 accounting, timing, and identity controls."""
    expected_rows = len(baseline) * len(settings.scenarios)
    expected_member_rows = members["member_id"].nunique() * len(settings.scenarios)
    numeric_columns = [
        "fails_to_receive_usd",
        "fails_to_deliver_usd",
        "required_replacement_liquidity_usd",
        "persistent_multi_day_fail_liquidity_usd",
        "combined_funding_shock_outflow_usd",
        "incremental_combined_stress_outflow_usd",
        "stressed_cumulative_net_liquidity_need_usd",
        "stressed_liquidity_shortfall_usd",
    ]
    finite = cashflows[numeric_columns].apply(
        lambda column: column.map(math.isfinite).all()
    ).all()
    nonnegative = (cashflows[numeric_columns] >= 0.0).all().all()
    tolerance = settings.tolerance_usd
    ftr_bound = (
        cashflows["fails_to_receive_usd"]
        <= cashflows["expected_incoming_settlement_payment_usd"] + tolerance
    ).all()
    ftd_bound = (
        cashflows["fails_to_deliver_usd"]
        <= cashflows["gross_settlement_obligation_usd"] + tolerance
    ).all()
    replacement_identity = (
        cashflows["required_replacement_liquidity_usd"]
        - cashflows["fails_to_deliver_usd"]
        * cashflows["replacement_liquidity_rate"]
    ).abs().le(tolerance).all()
    recovery_bound = True
    for _, group in cashflows.groupby(
        ["scenario_name", "member_id"], sort=True
    ):
        recovered = float(
            group["delayed_incoming_payment_recovery_usd"].sum()
        )
        failed_to_receive = float(group["fails_to_receive_usd"].sum())
        if recovered > failed_to_receive + tolerance:
            recovery_bound = False
            break
    combined_identity = (
        cashflows["incremental_combined_stress_outflow_usd"]
        - cashflows["incremental_settlement_fail_outflow_usd"]
        - cashflows["combined_funding_shock_outflow_usd"]
    ).abs().le(tolerance).all()
    headroom_identity = (
        cashflows["stressed_liquidity_headroom_usd"]
        - (
            cashflows["cumulative_available_resources_usd"]
            - cashflows["stressed_cumulative_net_liquidity_need_usd"]
        )
    ).abs().le(tolerance).all()
    control = cashflows.loc[cashflows["severity_rank"].eq(0)]
    control_zero = (
        control["incremental_combined_stress_outflow_usd"].abs().le(tolerance).all()
        and control["fails_to_receive_usd"].abs().le(tolerance).all()
        and control["fails_to_deliver_usd"].abs().le(tolerance).all()
    )
    severity_values = scenario_summary.sort_values("severity_rank")[
        "total_incremental_combined_stress_usd"
    ]
    severity_monotonic = severity_values.is_monotonic_increasing
    combined_scenarios = cashflows.loc[cashflows["funding_stress_weight"].gt(0.0)]
    funding_combination = (
        not combined_scenarios.empty
        and combined_scenarios["combined_funding_shock_outflow_usd"].gt(0.0).any()
    )
    synthetic_only = (
        cashflows["member_id"]
        .astype(str)
        .map(lambda value: re.fullmatch(settings.synthetic_id_pattern, value) is not None)
        .all()
        and not cashflows["actual_ficc_participant"].astype(bool).any()
        and not cashflows["participant_level_inference"].astype(bool).any()
    )
    return {
        "complete_cashflow_matrix": len(cashflows) == expected_rows,
        "complete_member_matrix": len(member_summary) == expected_member_rows,
        "unique_cashflow_keys": not cashflows.duplicated(
            ["scenario_name", "member_id", "time_bucket"]
        ).any(),
        "finite_nonnegative_stress_amounts": bool(finite and nonnegative),
        "fails_to_receive_bounds": bool(ftr_bound),
        "fails_to_deliver_bounds": bool(ftd_bound),
        "replacement_liquidity_identity": bool(replacement_identity),
        "delayed_payment_recovery_bounds": bool(recovery_bound),
        "combined_stress_identity": bool(combined_identity),
        "liquidity_headroom_identity": bool(headroom_identity),
        "zero_shock_control": bool(control_zero),
        "severity_monotonicity": bool(severity_monotonic),
        "section16_funding_combination": bool(funding_combination),
        "scenario_aggregation_complete": len(scenario_summary)
        == len(settings.scenarios),
        "synthetic_identity_controls": bool(synthetic_only),
    }


def calculate_settlement_fail_stress(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
    settings: SettlementFailStressSettings,
) -> SettlementFailStressResult:
    """Calculate controlled Section 18 settlement-fail stress."""
    prepared_baseline = prepare_baseline(baseline, settings)
    prepared_members = prepare_members(members, settings)
    prepared_funding = prepare_funding(funding, settings)
    frames = [
        _scenario_cashflows(
            prepared_baseline,
            prepared_members,
            prepared_funding,
            scenario,
            settings,
        )
        for scenario in settings.scenarios
    ]
    cashflows = pd.concat(frames, ignore_index=True).sort_values(
        ["severity_rank", "member_id", "bucket_order"], kind="stable"
    ).reset_index(drop=True)
    member_summary = _member_summary(cashflows)
    scenario_summary = _scenario_summary(member_summary)
    checks = validate_results(
        cashflows,
        member_summary,
        scenario_summary,
        prepared_baseline,
        prepared_members,
        settings,
    )
    return SettlementFailStressResult(
        cashflows=cashflows,
        member_summary=member_summary,
        scenario_summary=scenario_summary,
        checks=checks,
    )


def run_model(
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
    config: Mapping[str, Any],
) -> SettlementFailStressResult:
    """Load settings and execute the Section 18 model."""
    return calculate_settlement_fail_stress(
        baseline,
        members,
        funding,
        load_settings(config),
    )
'@

$RunnerContent = @'
"""Run Phase V, Section 18 settlement-fail stress."""

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

from ficc_liquidity.stress.settlement_fail_stress import (  # noqa: E402
    SettlementFailStressError,
    dataframe_digest,
    load_config,
    read_table,
    run_model,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Run Phase V Section 18 settlement-fail stress."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "settlement_fail_stress.yaml",
    )
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--funding", type=Path, default=None)
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
        default=ROOT / "data" / "manifests" / "settlement_fail_stress_manifest.csv",
    )
    parser.add_argument("--allow-demo", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SettlementFailStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing controlled input candidate."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _demo_members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002", "SYN-MBR-0003"],
            "settlement_obligation_usd": [400_000_000.0, 650_000_000.0, 900_000_000.0],
            "settlement_fail_usd": [8_000_000.0, 26_000_000.0, 63_000_000.0],
            "settlement_fail_rate": [0.02, 0.04, 0.07],
            "value_class": ["synthetic"] * 3,
            "actual_ficc_participant": [False] * 3,
            "participant_level_inference": [False] * 3,
        }
    )


def _demo_baseline() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    buckets = (
        ("day1_open", 0, 0.20),
        ("day1_midday", 6, 0.30),
        ("day1_close", 12, 0.30),
        ("day2_open", 24, 0.15),
        ("day2_close", 48, 0.05),
    )
    for member_number, scale in ((1, 1.0), (2, 1.4), (3, 1.9)):
        member_id = f"SYN-MBR-{member_number:04d}"
        resources = 350_000_000.0 * scale
        cumulative = 0.0
        for order, (bucket, elapsed, weight) in enumerate(buckets, start=1):
            gross_settlement = 400_000_000.0 * scale * weight
            outflow = gross_settlement * 0.35
            inflow = gross_settlement * 0.10
            cumulative = max(cumulative + outflow - inflow, 0.0)
            rows.append(
                {
                    "member_id": member_id,
                    "bucket_order": order,
                    "time_bucket": bucket,
                    "elapsed_hours": elapsed,
                    "liquidity_horizon_hours": 48,
                    "gross_settlement_obligation_usd": gross_settlement,
                    "total_cash_outflow_usd": outflow,
                    "total_cash_inflow_usd": inflow,
                    "cumulative_available_resources_usd": resources,
                    "cumulative_net_liquidity_need_usd": cumulative,
                    "liquidity_headroom_usd": resources - cumulative,
                    "liquidity_shortfall_usd": max(cumulative - resources, 0.0),
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


def _demo_funding() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    scenario_scales = {
        "control": 0.0,
        "moderate_market_stress": 0.04,
        "severe_market_stress": 0.10,
        "concentrated_funding_freeze": 0.20,
    }
    for scenario_name, scenario_scale in scenario_scales.items():
        for member_number, member_scale in ((1, 1.0), (2, 1.4), (3, 1.9)):
            for order, bucket in enumerate(
                ("day1_open", "day1_midday", "day1_close", "day2_open", "day2_close"),
                start=1,
            ):
                rows.append(
                    {
                        "scenario_name": scenario_name,
                        "member_id": f"SYN-MBR-{member_number:04d}",
                        "bucket_order": order,
                        "time_bucket": bucket,
                        "incremental_repo_funding_stress_outflow_usd": (
                            20_000_000.0 * member_scale * scenario_scale * order
                        ),
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )
    return pd.DataFrame.from_records(rows)


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
    """Write controlled result files."""
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


def write_manifest(
    manifest_path: Path,
    files: list[tuple[Path, str, int | None]],
) -> None:
    """Write source-lineage and output-integrity metadata."""
    generated_at = datetime.now(UTC).isoformat()
    records = [
        {
            "section": 18,
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


def main() -> int:
    """Execute the controlled Section 18 workflow."""
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
    funding_path = args.funding or discover_input(
        ROOT,
        [str(item) for item in source.get("funding_stress_candidates", [])],
    )

    if baseline_path is None or member_path is None or funding_path is None:
        if not args.allow_demo:
            raise FileNotFoundError(
                "Section 14 baseline cash flows, Section 12 synthetic members, and "
                "Section 16 funding-stress cash flows are required."
            )
        baseline = _demo_baseline()
        members = _demo_members()
        funding = _demo_funding()
        baseline_source = "CONTROLLED_SYNTHETIC_BASELINE_SMOKE_DATA"
        member_source = "CONTROLLED_SYNTHETIC_MEMBER_SMOKE_DATA"
        funding_source = "CONTROLLED_SYNTHETIC_FUNDING_SMOKE_DATA"
    else:
        baseline = read_table(baseline_path)
        members = read_table(member_path)
        funding = read_table(funding_path)
        baseline_source = str(baseline_path.resolve())
        member_source = str(member_path.resolve())
        funding_source = str(funding_path.resolve())

    first = run_model(baseline, members, funding, config)
    second = run_model(
        baseline.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        members.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        funding.sample(frac=1.0, random_state=2026).reset_index(drop=True),
        config,
    )
    deterministic = dataframe_digest(first.cashflows) == dataframe_digest(second.cashflows)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    suffix = "_smoke" if args.smoke else ""
    written: list[Path] = []
    written.extend(
        write_frame(
            first.cashflows,
            args.output_dir / f"settlement_fail_stress_cashflows{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.member_summary,
            args.output_dir / f"settlement_fail_stress_member_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )
    written.extend(
        write_frame(
            first.scenario_summary,
            args.output_dir / f"settlement_fail_stress_scenario_summary{suffix}",
            write_csv=bool(output.get("write_csv", True)),
            write_parquet=bool(output.get("write_parquet", True)),
        )
    )

    gates = {
        **{name: "PASS" if passed else "FAIL" for name, passed in first.checks.items()},
        "deterministic_reproduction": "PASS" if deterministic else "FAIL",
    }
    generated_at = datetime.now(UTC).isoformat()
    evidence = {
        "section": 18,
        "model": config.get("model_name", "settlement_fail_stress"),
        "model_version": config.get("model_version", "section-18-v1"),
        "generated_at_utc": generated_at,
        "run_type": "SMOKE_TEST" if args.smoke else "CONTROLLED_MODEL_RUN",
        "baseline_source": baseline_source,
        "member_source": member_source,
        "funding_source": funding_source,
        "cashflow_rows": len(first.cashflows),
        "member_scenario_rows": len(first.member_summary),
        "scenario_rows": len(first.scenario_summary),
        "scenario_names": first.scenario_summary["scenario_name"].tolist(),
        "result_sha256": dataframe_digest(first.cashflows),
        "gates": gates,
        "limitations": [
            "All member-level records are fictional synthetic observations.",
            "Fail splits, delays, persistence, replacement rates, and penalties are assumptions.",
            "Section 16 funding outflows are scenario overlays, not bilateral lender forecasts.",
            "Public aggregate data do not reveal actual FICC participant settlement behavior.",
        ],
    }
    evidence_json = args.evidence_dir / f"section18_settlement_fail_stress{suffix}.json"
    evidence_json.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    evidence_md = args.evidence_dir / f"section18_settlement_fail_stress{suffix}.md"
    gate_lines = "\n".join(f"- {name}: **{status}**" for name, status in gates.items())
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 18 Settlement-Fail Stress Evidence",
                "",
                f"- Generated at (UTC): {generated_at}",
                f"- Run type: {evidence['run_type']}",
                f"- Baseline source: `{baseline_source}`",
                f"- Synthetic member source: `{member_source}`",
                f"- Section 16 funding source: `{funding_source}`",
                f"- Cash-flow scenario rows: {len(first.cashflows):,}",
                f"- Result SHA-256: `{evidence['result_sha256']}`",
                "",
                "## Completion gates",
                "",
                gate_lines,
                "",
                "## Scope limitation",
                "",
                "All member records are fictional and synthetic. No output identifies, ",
                "represents, ranks, or infers an actual FICC participant.",
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
                len(first.cashflows)
                if "cashflows" in path.name
                else len(first.member_summary)
                if "member_summary" in path.name
                else len(first.scenario_summary),
            )
            for path in written
        ],
        (evidence_json, "modeled", None),
        (evidence_md, "modeled", None),
    ]
    if baseline_path is not None:
        manifest_files.append((baseline_path, "modeled", len(baseline)))
    if member_path is not None:
        manifest_files.append((member_path, "synthetic", len(members)))
    if funding_path is not None:
        manifest_files.append((funding_path, "modeled", len(funding)))
    write_manifest(args.manifest, manifest_files)

    print(first.scenario_summary.to_string(index=False))
    print("\nCompletion gates:")
    for name, status in gates.items():
        print(f"  {name}: {status}")
    print(f"\nEvidence: {evidence_md}")
    print(f"Manifest: {args.manifest}")
    return 0 if all(status == "PASS" for status in gates.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
'@

$TestContent = @'
"""Tests for Phase V, Section 18 settlement-fail stress."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any

import pandas as pd
import pytest

from ficc_liquidity.stress.settlement_fail_stress import (
    SettlementFailStressError,
    dataframe_digest,
    load_config,
    load_settings,
    prepare_baseline,
    prepare_funding,
    prepare_members,
    read_table,
    run_model,
)


@pytest.fixture
def config() -> dict[str, Any]:
    return {
        "model_version": "test-v1",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "assumptions": {
            "liquidity_horizon_hours": 48,
            "fails_to_receive_share": 0.5,
            "fails_to_deliver_share": 0.5,
            "incoming_settlement_receipt_ratio": 0.8,
            "persistence_liquidity_rate": 0.2,
            "fail_penalty_rate_per_day": 0.001,
        },
        "scenarios": [
            {
                "name": "control",
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
            },
            {
                "name": "stress",
                "severity_rank": 1,
                "fails_to_receive_multiplier": 2.0,
                "fails_to_deliver_multiplier": 1.5,
                "additional_fails_to_receive_rate": 0.05,
                "additional_fails_to_deliver_rate": 0.03,
                "incoming_payment_delay_buckets": 1,
                "replacement_liquidity_rate": 1.1,
                "persistence_days": 3,
                "persistence_decay": 0.8,
                "funding_scenario_name": "severe_market_stress",
                "funding_stress_weight": 0.75,
            },
        ],
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


@pytest.fixture
def members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "settlement_obligation_usd": [1000.0, 2000.0],
            "settlement_fail_usd": [20.0, 80.0],
            "settlement_fail_rate": [0.02, 0.04],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
        }
    )


@pytest.fixture
def baseline() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for member_id, scale in (("SYN-MBR-0001", 1.0), ("SYN-MBR-0002", 2.0)):
        for order, bucket in enumerate(("open", "mid", "close"), start=1):
            rows.append(
                {
                    "member_id": member_id,
                    "bucket_order": order,
                    "time_bucket": bucket,
                    "elapsed_hours": (order - 1) * 24,
                    "liquidity_horizon_hours": 48,
                    "gross_settlement_obligation_usd": 100.0 * scale,
                    "total_cash_outflow_usd": 60.0 * scale,
                    "total_cash_inflow_usd": 10.0 * scale,
                    "cumulative_available_resources_usd": 500.0 * scale,
                    "value_class": "synthetic",
                    "actual_ficc_participant": False,
                    "participant_level_inference": False,
                }
            )
    return pd.DataFrame.from_records(rows)


@pytest.fixture
def funding() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    for scenario, amount in (("control", 0.0), ("severe_market_stress", 25.0)):
        for member_id in ("SYN-MBR-0001", "SYN-MBR-0002"):
            for order, bucket in enumerate(("open", "mid", "close"), start=1):
                rows.append(
                    {
                        "scenario_name": scenario,
                        "member_id": member_id,
                        "bucket_order": order,
                        "time_bucket": bucket,
                        "incremental_repo_funding_stress_outflow_usd": amount,
                        "value_class": "synthetic",
                        "actual_ficc_participant": False,
                        "participant_level_inference": False,
                    }
                )
    return pd.DataFrame.from_records(rows)


def test_load_settings(config: dict[str, Any]) -> None:
    settings = load_settings(config)
    assert settings.model_version == "test-v1"
    assert len(settings.scenarios) == 2


def test_model_passes(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    assert result.passed
    assert len(result.scenario_summary) == 2


def test_zero_control(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    control = result.cashflows.loc[result.cashflows["scenario_name"].eq("control")]
    assert control["incremental_combined_stress_outflow_usd"].eq(0.0).all()


def test_stress_has_all_channels(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    stress = result.cashflows.loc[result.cashflows["scenario_name"].eq("stress")]
    for column in (
        "fails_to_receive_usd",
        "fails_to_deliver_usd",
        "delayed_incoming_payment_outflow_usd",
        "required_replacement_liquidity_usd",
        "persistent_multi_day_fail_liquidity_usd",
        "combined_funding_shock_outflow_usd",
    ):
        assert stress[column].gt(0.0).any()


def test_delayed_recovery_is_shifted(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    stress = result.cashflows.loc[
        result.cashflows["scenario_name"].eq("stress")
        & result.cashflows["member_id"].eq("SYN-MBR-0001")
    ].sort_values("bucket_order")
    assert stress["delayed_incoming_payment_recovery_usd"].iloc[0] == 0.0
    assert stress["delayed_incoming_payment_recovery_usd"].iloc[1] > 0.0


def test_replacement_identity(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    result = run_model(baseline, members, funding, config)
    stress = result.cashflows.loc[result.cashflows["scenario_name"].eq("stress")]
    expected = stress["fails_to_deliver_usd"] * 1.1
    pd.testing.assert_series_equal(
        stress["required_replacement_liquidity_usd"].reset_index(drop=True),
        expected.reset_index(drop=True),
        check_names=False,
    )


def test_deterministic_row_order_independent(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    first = run_model(baseline, members, funding, config)
    second = run_model(
        baseline.sample(frac=1.0, random_state=1),
        members.sample(frac=1.0, random_state=2),
        funding.sample(frac=1.0, random_state=3),
        config,
    )
    assert dataframe_digest(first.cashflows) == dataframe_digest(second.cashflows)


def test_invalid_identity_rejected(
    config: dict[str, Any], members: pd.DataFrame
) -> None:
    invalid = members.copy()
    invalid.loc[0, "member_id"] = "ACTUAL-MEMBER"
    with pytest.raises(SettlementFailStressError, match="Non-synthetic"):
        prepare_members(invalid, load_settings(config))


def test_actual_participant_rejected(
    config: dict[str, Any], members: pd.DataFrame
) -> None:
    invalid = members.copy()
    invalid.loc[0, "actual_ficc_participant"] = True
    with pytest.raises(SettlementFailStressError, match="Actual FICC"):
        prepare_members(invalid, load_settings(config))


def test_fail_above_obligation_rejected(
    config: dict[str, Any], members: pd.DataFrame
) -> None:
    invalid = members.copy()
    invalid.loc[0, "settlement_fail_usd"] = 2000.0
    with pytest.raises(SettlementFailStressError, match="cannot exceed"):
        prepare_members(invalid, load_settings(config))


def test_inconsistent_fail_rate_rejected(
    config: dict[str, Any], members: pd.DataFrame
) -> None:
    invalid = members.copy()
    invalid.loc[0, "settlement_fail_rate"] = 0.90
    with pytest.raises(SettlementFailStressError, match="inconsistent"):
        prepare_members(invalid, load_settings(config))


def test_missing_member_field_rejected(
    config: dict[str, Any], members: pd.DataFrame
) -> None:
    with pytest.raises(SettlementFailStressError, match="fields are missing"):
        prepare_members(members.drop(columns="settlement_fail_usd"), load_settings(config))


def test_duplicate_baseline_key_rejected(
    config: dict[str, Any], baseline: pd.DataFrame
) -> None:
    invalid = pd.concat([baseline, baseline.iloc[[0]]], ignore_index=True)
    with pytest.raises(SettlementFailStressError, match="must be unique"):
        prepare_baseline(invalid, load_settings(config))


def test_bad_horizon_rejected(
    config: dict[str, Any], baseline: pd.DataFrame
) -> None:
    invalid = baseline.copy()
    invalid["liquidity_horizon_hours"] = 24
    with pytest.raises(SettlementFailStressError, match="horizon"):
        prepare_baseline(invalid, load_settings(config))


def test_duplicate_funding_key_rejected(
    config: dict[str, Any], funding: pd.DataFrame
) -> None:
    invalid = pd.concat([funding, funding.iloc[[0]]], ignore_index=True)
    with pytest.raises(SettlementFailStressError, match="keys must be unique"):
        prepare_funding(invalid, load_settings(config))


def test_missing_funding_scenario_rejected(
    config: dict[str, Any],
    baseline: pd.DataFrame,
    members: pd.DataFrame,
    funding: pd.DataFrame,
) -> None:
    invalid = funding.loc[~funding["scenario_name"].eq("severe_market_stress")]
    with pytest.raises(SettlementFailStressError, match="was not found"):
        run_model(baseline, members, invalid, config)


def test_invalid_share_sum_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["assumptions"]["fails_to_receive_share"] = 0.8
    with pytest.raises(SettlementFailStressError, match="sum to one"):
        load_settings(invalid)


def test_nonmonotonic_scenarios_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1]["persistence_days"] = 0
    with pytest.raises(SettlementFailStressError, match="must be positive"):
        load_settings(invalid)



@pytest.mark.parametrize(
    ("key", "value", "match"),
    [
        ("name", "", "nonempty name"),
        ("severity_rank", -1, "nonnegative"),
        ("fails_to_receive_multiplier", -1.0, "nonnegative"),
        ("fails_to_deliver_multiplier", -1.0, "nonnegative"),
        ("additional_fails_to_receive_rate", 1.1, "between zero and one"),
        ("incoming_payment_delay_buckets", -1, "nonnegative"),
        ("replacement_liquidity_rate", -0.1, "nonnegative"),
    ],
)
def test_invalid_scenario_controls_rejected(
    config: dict[str, Any], key: str, value: object, match: str
) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1][key] = value
    with pytest.raises(SettlementFailStressError, match=match):
        load_settings(invalid)


def test_funding_name_required(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1]["funding_scenario_name"] = ""
    with pytest.raises(SettlementFailStressError, match="funding scenario name"):
        load_settings(invalid)


def test_empty_scenario_list_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"] = []
    with pytest.raises(SettlementFailStressError, match="nonempty list"):
        load_settings(invalid)


def test_duplicate_scenario_name_rejected(config: dict[str, Any]) -> None:
    invalid = deepcopy(config)
    invalid["scenarios"][1]["name"] = "control"
    with pytest.raises(SettlementFailStressError, match="names must be unique"):
        load_settings(invalid)


def test_empty_inputs_rejected(
    config: dict[str, Any],
) -> None:
    settings = load_settings(config)
    with pytest.raises(SettlementFailStressError, match="member input is empty"):
        prepare_members(pd.DataFrame(), settings)
    with pytest.raises(SettlementFailStressError, match="Baseline liquidity input is empty"):
        prepare_baseline(pd.DataFrame(), settings)
    with pytest.raises(SettlementFailStressError, match="funding-stress input is empty"):
        prepare_funding(pd.DataFrame(), settings)


def test_missing_baseline_and_funding_fields_rejected(
    config: dict[str, Any], baseline: pd.DataFrame, funding: pd.DataFrame
) -> None:
    settings = load_settings(config)
    with pytest.raises(SettlementFailStressError, match="baseline fields are missing"):
        prepare_baseline(baseline.drop(columns="elapsed_hours"), settings)
    with pytest.raises(SettlementFailStressError, match="funding fields are missing"):
        prepare_funding(funding.drop(columns="scenario_name"), settings)


def test_duplicate_member_rejected(
    config: dict[str, Any], members: pd.DataFrame
) -> None:
    invalid = pd.concat([members, members.iloc[[0]]], ignore_index=True)
    with pytest.raises(SettlementFailStressError, match="must be unique"):
        prepare_members(invalid, load_settings(config))


def test_config_missing_rejected(tmp_path: Path) -> None:
    with pytest.raises(SettlementFailStressError, match="does not exist"):
        load_config(tmp_path / "missing.yaml")

def test_config_round_trip(tmp_path: Path, config: dict[str, Any]) -> None:
    import yaml

    path = tmp_path / "config.yaml"
    path.write_text(yaml.safe_dump(config), encoding="utf-8")
    loaded = load_config(path)
    assert loaded["model_version"] == "test-v1"


def test_read_table_csv(tmp_path: Path, members: pd.DataFrame) -> None:
    path = tmp_path / "members.csv"
    members.to_csv(path, index=False)
    loaded = read_table(path)
    assert len(loaded) == len(members)


def test_read_table_missing_rejected(tmp_path: Path) -> None:
    with pytest.raises(SettlementFailStressError, match="does not exist"):
        read_table(tmp_path / "missing.csv")


def test_read_table_extension_rejected(tmp_path: Path) -> None:
    path = tmp_path / "data.txt"
    path.write_text("x", encoding="utf-8")
    with pytest.raises(SettlementFailStressError, match="CSV or Parquet"):
        read_table(path)
'@

$DocsContent = @'
# Section 18 — Settlement-Fail Stress

## Purpose

This module applies controlled settlement-fail shocks to the Phase V liquidity
cash-flow framework. It operates only on fictional synthetic member records and
does not identify, estimate, rank, or infer any actual FICC participant.

## Implemented channels

1. **Fails to receive.** Expected incoming settlement payments are subjected to
   scenario-specific fail multipliers and incremental fail rates.
2. **Fails to deliver.** Gross settlement obligations are subjected to separate
   deliver-fail assumptions, bounded by the obligation in each time bucket.
3. **Delayed incoming payments.** Failed receipts create an immediate liquidity
   need and are recovered only after the configured number of time buckets. A
   delay beyond the modeled horizon remains unrecovered during the horizon.
4. **Required replacement liquidity.** Deliver fails generate replacement
   liquidity equal to the failed amount times the configured replacement rate.
5. **Persistent multi-day fails.** A geometric persistence factor converts fail
   balances into additional carrying liquidity and explicit daily penalties.
6. **Combined settlement and funding shocks.** Each settlement scenario maps to
   a Section 16 repo-funding scenario. The model imports Section 16 incremental
   funding outflows and applies the controlled combination weight.

## Core calculations

For each member and time bucket, the model calculates bounded fails to receive
and fails to deliver. The incremental settlement-fail outflow is:

```text
delayed receipt need
+ replacement liquidity
+ persistent fail liquidity
+ deliver-fail penalty
```

The combined incremental outflow adds the weighted Section 16 funding-stress
outflow. Stressed liquidity need is then recomputed in chronological order using
a zero floor, and stressed headroom equals available resources minus stressed
cumulative liquidity need.

## Inputs

Preferred controlled inputs are:

- `reports/tables/baseline_liquidity_cashflows.parquet`
- `data/synthetic/calibrated_member_portfolios.parquet`
- `reports/tables/repo_funding_stress_cashflows.parquet`

The member dataset must provide `settlement_obligation_usd`,
`settlement_fail_usd`, and a consistent `settlement_fail_rate` when that ratio is
present. The funding dataset must provide Section 16 scenario, member, bucket,
and incremental repo-funding stress outflow fields.

## Outputs

The runner writes CSV and Parquet versions of:

- `reports/tables/settlement_fail_stress_cashflows`
- `reports/tables/settlement_fail_stress_member_summary`
- `reports/tables/settlement_fail_stress_scenario_summary`

It also writes:

- `reports/evidence/section18_settlement_fail_stress.json`
- `reports/evidence/section18_settlement_fail_stress.md`
- `data/manifests/settlement_fail_stress_manifest.csv`

## Model-risk limitations

- Fail splits, incremental fail rates, delays, persistence, replacement rates,
  penalties, and funding-combination weights are explicit assumptions.
- Public aggregate data do not reveal actual participant-level settlement fails,
  bilateral counterparties, operational causes, or contractual remedies.
- Delayed receipts are modeled as liquidity timing shocks, not credit losses.
- Replacement liquidity is a conservative cash requirement, not a prediction of
  an actual buy-in, close-out, or contractual settlement process.
- Section 16 funding outflows are imported scenario overlays and do not infer
  lender identities or bilateral financing terms.
'@

    Write-Utf8File -Path "configs\settlement_fail_stress.yaml" -Content $ConfigContent
    Write-Utf8File `
        -Path "src\ficc_liquidity\stress\settlement_fail_stress.py" `
        -Content $ModuleContent
    Write-Utf8File -Path "scripts\run_settlement_fail_stress.py" -Content $RunnerContent
    Write-Utf8File -Path "tests\test_settlement_fail_stress.py" -Content $TestContent
    Write-Utf8File -Path "docs\settlement_fail_stress_methodology.md" -Content $DocsContent
    Write-Pass "Section 18 controlled source files written"

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
        "src/ficc_liquidity/stress/settlement_fail_stress.py",
        "scripts/run_settlement_fail_stress.py",
        "tests/test_settlement_fail_stress.py"
    )

    Write-Step "Formatting and linting Section 18"
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

    Write-Step "Running focused Section 18 branch coverage"
    Invoke-Checked -FilePath $Python `
        -ArgumentList @(
            "-m", "pytest",
            "-o", "addopts=",
            "tests/test_settlement_fail_stress.py",
            "--cov=ficc_liquidity.stress.settlement_fail_stress",
            "--cov-branch",
            "--cov-report=term-missing",
            "--cov-fail-under=85"
        ) `
        -FailureMessage "Section 18 focused tests or coverage failed."
    Write-Pass "Focused tests and branch coverage"

    Write-Step "Generating Section 16 funding-stress inputs"
    $section16Args = @("scripts/run_repo_funding_stress.py")
    if ($AllowDemo) {
        $section16Args += @("--allow-demo", "--smoke")
    }
    Invoke-Checked -FilePath $Python `
        -ArgumentList $section16Args `
        -FailureMessage "Section 16 funding-stress input generation failed."
    Write-Pass "Section 16 funding-stress cash flows available"

    Write-Step "Executing the controlled Section 18 model"
    $section18Args = @("scripts/run_settlement_fail_stress.py")
    if ($AllowDemo) {
        $section18Args += @("--allow-demo", "--smoke")
    }
    Invoke-Checked -FilePath $Python `
        -ArgumentList $section18Args `
        -FailureMessage "Section 18 controlled model run failed."
    Write-Pass "Section 18 model and completion gates"

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

    Write-Step "Checking patch integrity"
    if (-not $SkipGit) {
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("diff", "--check") `
            -FailureMessage "Git diff whitespace validation failed."
        Write-Pass "Git diff validation"
    }

    $requiredOutputs = @(
        "configs\settlement_fail_stress.yaml",
        "src\ficc_liquidity\stress\settlement_fail_stress.py",
        "scripts\run_settlement_fail_stress.py",
        "tests\test_settlement_fail_stress.py",
        "docs\settlement_fail_stress_methodology.md",
        "reports\tables\settlement_fail_stress_cashflows.csv",
        "reports\tables\settlement_fail_stress_member_summary.csv",
        "reports\tables\settlement_fail_stress_scenario_summary.csv",
        "reports\evidence\section18_settlement_fail_stress.json",
        "reports\evidence\section18_settlement_fail_stress.md",
        "data\manifests\settlement_fail_stress_manifest.csv",
        $AutomationRelativePath
    )
    if ($AllowDemo) {
        $requiredOutputs = $requiredOutputs | ForEach-Object {
            $_.Replace("settlement_fail_stress_cashflows.csv", "settlement_fail_stress_cashflows_smoke.csv").Replace(
                "settlement_fail_stress_member_summary.csv",
                "settlement_fail_stress_member_summary_smoke.csv"
            ).Replace(
                "settlement_fail_stress_scenario_summary.csv",
                "settlement_fail_stress_scenario_summary_smoke.csv"
            ).Replace(
                "section18_settlement_fail_stress.json",
                "section18_settlement_fail_stress_smoke.json"
            ).Replace(
                "section18_settlement_fail_stress.md",
                "section18_settlement_fail_stress_smoke.md"
            )
        }
    }
    if (-not (Test-RequiredFiles -Paths $requiredOutputs)) {
        $missingOutputs = @(
            foreach ($path in $requiredOutputs) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $path
                }
            }
        )
        throw "Section 18 outputs are incomplete: $($missingOutputs -join ', ')"
    }
    Write-Pass "All controlled Section 18 deliverables are present"

    if (-not $SkipGit) {
        Write-Step "Staging Section 18 controlled artifacts"
        $pathsToStage = @(
            "configs/settlement_fail_stress.yaml",
            "src/ficc_liquidity/stress/settlement_fail_stress.py",
            "scripts/run_settlement_fail_stress.py",
            "tests/test_settlement_fail_stress.py",
            "docs/settlement_fail_stress_methodology.md",
            "data/manifests/settlement_fail_stress_manifest.csv",
            "reports/evidence/section18_settlement_fail_stress*.json",
            "reports/evidence/section18_settlement_fail_stress*.md",
            "reports/tables/settlement_fail_stress_cashflows*",
            "reports/tables/settlement_fail_stress_member_summary*",
            "reports/tables/settlement_fail_stress_scenario_summary*",
            $AutomationRelativePath.Replace("\", "/")
        )
        $expandedPathsToStage = @()
        foreach ($path in $pathsToStage) {
            if ($path -match '[*?\[]') {
                $matchingFiles = @(
                    Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue
                )
                if ($matchingFiles.Count -eq 0) {
                    throw "Section 18 staging pattern did not match any files: $path"
                }
                $expandedPathsToStage += @($matchingFiles.FullName)
            }
            else {
                $expandedPathsToStage += $path
            }
        }

        foreach ($path in ($expandedPathsToStage | Sort-Object -Unique)) {
            & git check-ignore -q -- $path
            $isIgnoredSection18Path = $LASTEXITCODE -eq 0

            if ($isIgnoredSection18Path) {
                & git add -f -- $path
            }
            else {
                & git add -- $path
            }

            if ($LASTEXITCODE -ne 0) {
                throw "Unable to stage Section 18 path: $path"
            }
        }
        Invoke-Checked -FilePath "git" `
            -ArgumentList @("diff", "--cached", "--check") `
            -FailureMessage "Staged Section 18 artifacts failed whitespace validation."

        $stagedNames = @(& git diff --cached --name-only)
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to inspect staged Section 18 artifacts."
        }
        if (-not $NoCommit -and $stagedNames.Count -gt 0) {
            Write-Step "Committing Section 18"
            Invoke-Checked -FilePath "git" `
                -ArgumentList @("commit", "-m", $CommitMessage) `
                -FailureMessage "Unable to commit Section 18 changes."
            Write-Pass "Section 18 commit created"
        }
        elseif ($NoCommit) {
            Write-Warn "Commit was skipped by request; changes remain staged."
        }
        else {
            Write-Warn "No new Section 18 changes required a commit."
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

            $existingPrJson = (
                & gh pr list `
                    --repo $RepoFullName `
                    --head $BranchName `
                    --state open `
                    --json url `
                    --limit 1 |
                Out-String
            ).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect existing pull requests for $BranchName."
            }
            $existingPr = @()
            if (-not [string]::IsNullOrWhiteSpace($existingPrJson)) {
                $parsedPr = $existingPrJson | ConvertFrom-Json
                if ($null -ne $parsedPr) {
                    $existingPr = @(
                        @($parsedPr) |
                        Where-Object {
                            $null -ne $_ -and
                            $_.PSObject.Properties.Name -contains "url"
                        }
                    )
                }
            }

            if ($existingPr.Count -gt 0) {
                $pullRequestUrl = [string]$existingPr[0].url
                Write-Warn "An open pull request already exists: $pullRequestUrl"
            }
            else {
                $PullRequestBody = @"
## Summary

Completes Phase V, Section 18: settlement-fail stress.

## Implemented stress channels

- Fails to receive
- Fails to deliver
- Delayed incoming payments
- Required replacement liquidity
- Persistent multi-day fails
- Combined settlement and Section 16 repo-funding shocks

## Model integration

- Uses Section 12 calibrated synthetic member settlement obligations and fails.
- Uses Section 14 time-bucketed baseline liquidity cash flows.
- Imports Section 16 incremental repo-funding stress outflows by scenario.
- Preserves synthetic-only controls and prohibits participant-level inference.

## Validation

- Ruff formatting and linting
- Strict Mypy
- Focused Pytest branch coverage above 85 percent
- Deterministic reproduction
- Fail bounds, delay recovery, replacement-liquidity, persistence, funding, and liquidity identities
- Complete repository quality gates
"@
                Write-Step "Opening the Section 18 pull request"
                $pullRequestUrl = (
                    & gh pr create `
                        --repo $RepoFullName `
                        --base main `
                        --head $BranchName `
                        --title $PullRequestTitle `
                        --body $PullRequestBody |
                    Out-String
                ).Trim()
                if ($LASTEXITCODE -ne 0) {
                    throw "Unable to create the Section 18 pull request."
                }
                Write-Pass "Pull request created: $pullRequestUrl"
            }

            if ($WatchChecks) {
                Invoke-Checked -FilePath "gh" `
                    -ArgumentList @(
                        "pr", "checks", $BranchName,
                        "--repo", $RepoFullName,
                        "--watch"
                    ) `
                    -FailureMessage "One or more Section 18 pull-request checks failed."
                Write-Pass "Pull-request checks passed"
            }
        }
    }

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Green
    Write-Host "SECTION 18 COMPLETE" -ForegroundColor Green
    Write-Host ("=" * 78) -ForegroundColor Green
    Write-Host "Repository: $RepoPath"
    Write-Host "Branch: $BranchName"
    Write-Host "Fails to receive: PASS"
    Write-Host "Fails to deliver: PASS"
    Write-Host "Delayed incoming payments: PASS"
    Write-Host "Required replacement liquidity: PASS"
    Write-Host "Persistent multi-day fails: PASS"
    Write-Host "Combined settlement and funding shocks: PASS"
    Write-Host "Synthetic-member controls: PASS"
    Write-Host "Evidence: reports\evidence\section18_settlement_fail_stress.md"
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Red
    Write-Host "SECTION 18 AUTOMATION STOPPED" -ForegroundColor Red
    Write-Host ("=" * 78) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
