#requires -Version 5.1
<#
.SYNOPSIS
    Resumes Phase II Section 10 after the settlement-fails series-resolution failure.

.DESCRIPTION
    Run this file from the repository root in the VS Code PowerShell terminal.

    The prior Section 10 implementation passed pytest, Ruff, and Mypy but could
    not resolve settlement-fail series from the Section 8 Parquet output. This
    recovery adds a controlled fallback that reads only the required FR 2004
    fails and financing series from the latest immutable raw New York Fed CSV,
    preserves source lineage, reruns all validation gates, executes calibration,
    and optionally commits, pushes, and opens the pull request.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [string]$Branch = "feature/08-historical-stress-calibration",

    [Parameter(Mandatory = $false)]
    [switch]$Publish,

    [Parameter(Mandatory = $false)]
    [switch]$CreatePullRequest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )

    Write-Host ("> {0} {1}" -f $FilePath, ($Arguments -join " ")) -ForegroundColor DarkGray
    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
Set-Location $ProjectRoot

Write-Step "Resolving repository, branch, and Python environment"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is not available on PATH."
}

$insideRepository = (& git rev-parse --is-inside-work-tree 2>$null)
if ($insideRepository -ne "true") {
    throw "ProjectRoot is not a Git repository: $ProjectRoot"
}

$activeBranch = (& git branch --show-current).Trim()
if ($activeBranch -ne $Branch) {
    throw "Remain on '$Branch' and rerun this recovery. Current branch: '$activeBranch'."
}
Write-Pass "Active branch is $activeBranch"

$PythonExe = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $PythonExe -PathType Leaf)) {
    throw "Python 3.11 virtual environment was not found at $PythonExe."
}

$pythonVersion = (& $PythonExe -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')").Trim()
if ($pythonVersion -ne "3.11") {
    throw "Section 10 requires Python 3.11; detected $pythonVersion."
}
Write-Pass "Python $pythonVersion detected"

$requiredFiles = @(
    "src\ficc_liquidity\analysis\historical_stress.py",
    "scripts\run_historical_stress_calibration.py",
    "tests\test_historical_stress.py",
    "configs\historical_scenarios.yaml",
    "data\processed\fed_liquidity_factors.parquet",
    "data\processed\treasury_market_factors.parquet"
)
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path (Join-Path $ProjectRoot $relativePath) -PathType Leaf)) {
        throw "Required file is missing: $relativePath"
    }
}

$rawFiles = @(Get-ChildItem (Join-Path $ProjectRoot "data\raw\fr2004") -Filter "fr2004_*.csv" -File -ErrorAction SilentlyContinue)
if ($rawFiles.Count -eq 0) {
    throw "No immutable FR 2004 raw CSV was found under data/raw/fr2004."
}
Write-Pass "FR 2004 raw fallback source is available"

Write-Step "Installing the controlled FR 2004 series-resolution repair"

$patchDirectory = Join-Path $ProjectRoot ".automation_tmp"
New-Item -ItemType Directory -Path $patchDirectory -Force | Out-Null
$patchScript = Join-Path $patchDirectory "patch_section10_fr2004_fallback.py"

$patchCode = @'
from __future__ import annotations

from pathlib import Path


ROOT = Path.cwd()
RUNNER = ROOT / "scripts" / "run_historical_stress_calibration.py"
TESTS = ROOT / "tests" / "test_historical_stress.py"
CONFIG = ROOT / "configs" / "historical_scenarios.yaml"
SCRIPTS_INIT = ROOT / "scripts" / "__init__.py"

HELPER = r'''


def _normalized_column_name(value: object) -> str:
    return "_".join(
        part
        for part in "".join(
            character.lower() if character.isalnum() else " "
            for character in str(value).strip()
        ).split()
        if part
    )


def _raw_column(
    columns: list[str], candidates: frozenset[str]
) -> str | None:
    lookup = {_normalized_column_name(column): column for column in columns}
    for candidate in candidates:
        if candidate in lookup:
            return lookup[candidate]
    return None


def _raw_numeric(series: pd.Series) -> pd.Series:
    cleaned = (
        series.astype("string")
        .str.strip()
        .mask(
            lambda values: values.str.lower().isin(
                {"", ".", "-", "*", "na", "n/a", "null"}
            )
        )
        .str.replace(r"^\((.*)\)$", r"-\1", regex=True)
        .str.replace(",", "", regex=False)
        .str.replace("$", "", regex=False)
    )
    return pd.to_numeric(cleaned, errors="coerce")


def _raw_metric(series_id: str) -> str:
    return _normalized_column_name(series_id) or "unnamed"


def load_fr2004_raw_fallback(
    project_root: Path,
    raw_glob: str = "data/raw/fr2004/fr2004_*.csv",
) -> tuple[pd.DataFrame, dict[str, Any] | None]:
    """Recover controlled FR 2004 fails and financing series from the raw extract.

    Section 8 may contain an older canonicalization in which the New York Fed
    ``Time Series`` identifier was not preserved. This fallback reads the latest
    immutable raw FR 2004 CSV and creates only the weekly fails and financing
    rows required by Section 10.
    """

    candidates = sorted(
        project_root.glob(raw_glob),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    for path in candidates:
        source = pd.read_csv(path, dtype="string", low_memory=False)
        columns = [str(column) for column in source.columns]
        date_column = _raw_column(
            columns,
            frozenset(
                {
                    "as_of_date",
                    "asof_date",
                    "observation_date",
                    "date",
                    "report_date",
                }
            ),
        )
        series_column = _raw_column(
            columns,
            frozenset(
                {
                    "time_series",
                    "timeseries",
                    "time_series_id",
                    "series_id",
                    "keyid",
                    "key_id",
                }
            ),
        )
        value_column = _raw_column(
            columns,
            frozenset(
                {
                    "value",
                    "value_millions",
                    "value_in_millions",
                    "observation_value",
                    "amount",
                }
            ),
        )
        if date_column is None or series_column is None or value_column is None:
            continue

        series_ids = source[series_column].astype("string").str.strip()
        relevant = series_ids.str.contains(
            r"^(?:PDFT[RD]|PDS(?:ORA|IRRA|IOSB|OOS))[-_]",
            regex=True,
            case=False,
            na=False,
        )
        selected = source.loc[
            relevant, [date_column, series_column, value_column]
        ].copy()
        if selected.empty:
            continue

        selected["observation_date"] = pd.to_datetime(
            selected[date_column], errors="coerce"
        ).dt.normalize()
        selected["source_series_id"] = (
            selected[series_column].astype("string").str.strip()
        )
        selected["value"] = _raw_numeric(selected[value_column]) * 1_000_000.0
        selected = selected.dropna(
            subset=["observation_date", "source_series_id", "value"]
        )
        if selected.empty:
            continue

        output = pd.DataFrame(
            {
                "observation_date": selected["observation_date"],
                "alignment_frequency": "weekly",
                "source_name": "FR2004",
                "source_series_id": selected["source_series_id"],
                "source_metric": selected["source_series_id"].map(_raw_metric),
                "value": selected["value"],
                "standardized_unit": "USD",
                "metric_kind": "flow",
                "is_observed": True,
                "source_file": path.relative_to(project_root).as_posix(),
                "source_sha256": file_sha256(path),
            }
        )
        output["series_key"] = (
            output["source_name"].astype("string").str.upper()
            + "::"
            + output["source_series_id"].astype("string")
            + "::"
            + output["alignment_frequency"].astype("string").str.lower()
        )
        output = (
            output.sort_values(["observation_date", "source_series_id"])
            .drop_duplicates(
                [
                    "observation_date",
                    "alignment_frequency",
                    "source_name",
                    "source_series_id",
                ],
                keep="last",
            )
            .reset_index(drop=True)
        )
        lineage: dict[str, Any] = {
            "path": path.relative_to(project_root).as_posix(),
            "sha256": file_sha256(path),
            "rows": len(output),
            "columns": len(output.columns),
            "start_date": output["observation_date"].min().date().isoformat(),
            "end_date": output["observation_date"].max().date().isoformat(),
            "source_row_counts": {"FR2004_RAW_FALLBACK": len(output)},
        }
        return output, lineage

    return pd.DataFrame(), None


def augment_with_fr2004_raw(
    frame: pd.DataFrame,
    project_root: Path,
    raw_glob: str = "data/raw/fr2004/fr2004_*.csv",
) -> tuple[pd.DataFrame, dict[str, Any] | None]:
    """Append controlled raw FR 2004 rows when processed series are unresolved."""

    fallback, lineage = load_fr2004_raw_fallback(project_root, raw_glob)
    if fallback.empty:
        return frame, lineage

    combined = pd.concat([frame, fallback], ignore_index=True, sort=False)
    combined = (
        combined.sort_values(
            [
                "observation_date",
                "alignment_frequency",
                "source_name",
                "source_series_id",
            ]
        )
        .drop_duplicates(
            [
                "observation_date",
                "alignment_frequency",
                "source_name",
                "source_series_id",
            ],
            keep="last",
        )
        .reset_index(drop=True)
    )
    return combined, lineage
'''

TEST = r'''


def test_raw_fr2004_fallback_resolves_official_fail_series(tmp_path: Path) -> None:
    raw_directory = tmp_path / "data" / "raw" / "fr2004"
    raw_directory.mkdir(parents=True)
    raw_path = raw_directory / "fr2004_20260720T012731Z_example.csv"
    raw_path.write_text(
        "As Of Date,Time Series,Value (millions)\n"
        "2020-03-04,PDFTR-USTET,1250\n"
        "2020-03-04,PDFTD-USTET,1350\n"
        "2020-03-04,PDSORA-UTSETTOT,850000\n",
        encoding="utf-8",
    )

    base = _synthetic_long_frame().loc[
        lambda frame: frame["source_name"] != "FR2004"
    ].copy()
    enriched, lineage = augment_with_fr2004_raw(base, tmp_path)

    assert lineage is not None
    assert lineage["source_row_counts"] == {"FR2004_RAW_FALLBACK": 3}
    assert {"PDFTR-USTET", "PDFTD-USTET"}.issubset(
        set(enriched["source_series_id"].astype(str))
    )
    mappings = resolve_series_map(enriched, _config())
    assert mappings["settlement_fails"]
    assert mappings["financing_volume"]
'''

runner_text = RUNNER.read_text(encoding="utf-8")
if "def load_fr2004_raw_fallback(" not in runner_text:
    marker = "\ndef _git_value(project_root: Path, *arguments: str) -> str:\n"
    if marker not in runner_text:
        raise RuntimeError("Unable to locate the Section 10 runner helper marker.")
    runner_text = runner_text.replace(marker, HELPER + marker, 1)
if "fallback_lineage = augment_with_fr2004_raw(" not in runner_text:
    old = (
        "    analytical_frame, lineage = load_analytical_inputs(configured_inputs)\n"
        "    result = calibrate_historical_windows(analytical_frame, config)\n"
    )
    new = (
        "    analytical_frame, lineage = load_analytical_inputs(configured_inputs)\n"
        "    analytical_frame, fallback_lineage = augment_with_fr2004_raw(\n"
        "        analytical_frame,\n"
        "        project_root,\n"
        "        str(config.get(\"fr2004_raw_glob\", \"data/raw/fr2004/fr2004_*.csv\")),\n"
        "    )\n"
        "    if fallback_lineage is not None:\n"
        "        lineage.append(fallback_lineage)\n"
        "    result = calibrate_historical_windows(analytical_frame, config)\n"
    )
    if old not in runner_text:
        raise RuntimeError("Unable to locate the Section 10 runner insertion marker.")
    runner_text = runner_text.replace(old, new, 1)
RUNNER.write_text(runner_text, encoding="utf-8", newline="\n")

test_text = TESTS.read_text(encoding="utf-8")
if "from scripts.run_historical_stress_calibration import (" not in test_text:
    import_marker = "import yaml\n\n"
    if import_marker not in test_text:
        raise RuntimeError("Unable to locate the Section 10 test import marker.")
    test_text = test_text.replace(
        import_marker,
        import_marker
        + "from scripts.run_historical_stress_calibration import (\n"
        + "    augment_with_fr2004_raw,\n"
        + ")\n\n",
        1,
    )
if "def test_raw_fr2004_fallback_resolves_official_fail_series(" not in test_text:
    test_text = test_text.rstrip() + TEST + "\n"
TESTS.write_text(test_text, encoding="utf-8", newline="\n")

if not SCRIPTS_INIT.exists():
    SCRIPTS_INIT.write_text(
        '"""Controlled executable scripts for the FICC liquidity project."""\n',
        encoding="utf-8",
        newline="\n",
    )

config_text = CONFIG.read_text(encoding="utf-8")
if "fr2004_raw_glob:" not in config_text:
    marker = (
        "input_files:\n"
        "  - data/processed/fed_liquidity_factors.parquet\n"
        "  - data/processed/treasury_market_factors.parquet\n"
    )
    if marker not in config_text:
        raise RuntimeError("Unable to locate the historical-scenarios input block.")
    config_text = config_text.replace(
        marker,
        marker + "\nfr2004_raw_glob: data/raw/fr2004/fr2004_*.csv\n",
        1,
    )
    CONFIG.write_text(config_text, encoding="utf-8", newline="\n")

print("Section 10 FR 2004 fallback patch installed.")
'@

Write-Utf8NoBom -Path $patchScript -Content $patchCode
Invoke-External -FilePath $PythonExe -Arguments @($patchScript)
Remove-Item $patchScript -Force

$automationTarget = Join-Path $ProjectRoot "scripts\automation\P2S10_Resume_After_Series_Resolution_Failure.ps1"
Copy-Item $PSCommandPath $automationTarget -Force
Write-Pass "Repair source and regression test installed"

Write-Step "Running formatting, linting, typing, and tests"

$qualityPaths = @(
    "src/ficc_liquidity/analysis/historical_stress.py",
    "scripts/run_historical_stress_calibration.py",
    "tests/test_historical_stress.py"
)

Invoke-External -FilePath $PythonExe -Arguments (@("-m", "ruff", "check", "--fix") + $qualityPaths)
Invoke-External -FilePath $PythonExe -Arguments (@("-m", "ruff", "format") + $qualityPaths)
Invoke-External -FilePath $PythonExe -Arguments (@("-m", "ruff", "format", "--check") + $qualityPaths)
Invoke-External -FilePath $PythonExe -Arguments (@("-m", "ruff", "check") + $qualityPaths)
Invoke-External -FilePath $PythonExe -Arguments @(
    "-m", "mypy",
    "src/ficc_liquidity/analysis/historical_stress.py",
    "scripts/run_historical_stress_calibration.py",
    "tests/test_historical_stress.py"
)
Invoke-External -FilePath $PythonExe -Arguments @(
    "-m", "pytest", "-q", "tests/test_historical_stress.py", "-o", "addopts="
)
Invoke-External -FilePath $PythonExe -Arguments @("-m", "pytest", "-q")
Write-Pass "All local quality gates passed"

Write-Step "Executing historical stress-window calibration"

Invoke-External -FilePath $PythonExe -Arguments @(
    "scripts/run_historical_stress_calibration.py",
    "--project-root", $ProjectRoot
)

$deliverables = @(
    "reports\tables\historical_stress_windows.csv",
    "reports\tables\historical_stress_daily_scores.csv",
    "reports\evidence\historical_stress_calibration.txt",
    "configs\historical_scenarios.yaml"
)
foreach ($relativePath in $deliverables) {
    $fullPath = Join-Path $ProjectRoot $relativePath
    if (-not (Test-Path $fullPath -PathType Leaf)) {
        throw "Section 10 deliverable was not created: $relativePath"
    }
    if ((Get-Item $fullPath).Length -eq 0) {
        throw "Section 10 deliverable is empty: $relativePath"
    }
}

$windowRows = @(Import-Csv (Join-Path $ProjectRoot "reports\tables\historical_stress_windows.csv"))
if ($windowRows.Count -eq 0) {
    throw "Historical calibration produced no selected windows."
}
Write-Pass "Historical calibration selected $($windowRows.Count) stress window(s)"

Write-Step "Committing and publishing Section 10"

$pathsToAdd = @(
    "configs/historical_scenarios.yaml",
    "src/ficc_liquidity/analysis/__init__.py",
    "src/ficc_liquidity/analysis/historical_stress.py",
    "scripts/run_historical_stress_calibration.py",
    "scripts/__init__.py",
    "tests/test_historical_stress.py",
    "docs/section_10_historical_stress_methodology.md",
    "reports/tables/historical_stress_windows.csv",
    "reports/tables/historical_stress_daily_scores.csv",
    "reports/evidence/historical_stress_calibration.txt",
    "scripts/automation/P2S10_Resume_After_Series_Resolution_Failure.ps1"
)

Invoke-External -FilePath "git" -Arguments (@("add", "--") + $pathsToAdd)

& git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Invoke-External -FilePath "git" -Arguments @(
        "commit",
        "-m",
        "feat: calibrate historical liquidity stress windows"
    )
    Write-Pass "Section 10 changes committed"
}
else {
    Write-Pass "No additional commit was required"
}

if ($Publish -or $CreatePullRequest) {
    Invoke-External -FilePath "git" -Arguments @("push", "-u", "origin", $Branch)
    Write-Pass "Branch pushed to origin"
}

if ($CreatePullRequest) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI is required for -CreatePullRequest."
    }

    $existingUrl = (& gh pr view $Branch --json url --jq ".url" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $existingUrl) {
        Write-Pass "Pull request already exists: $existingUrl"
    }
    else {
        $prBody = @"
Completes Phase II Section 10 historical stress-window identification.

Implemented controls:
- SOFR spike calibration
- Treasury-yield shock calibration
- FR 2004 settlement-fail increases
- Financing-volume disruptions
- Reserve-balance contractions
- Combined empirical market-stress indicator
- Objective tail-window clustering
- Controlled historical scenario YAML
- Source-lineage and calibration evidence

The FR 2004 fallback reads only the required fails and financing series from the latest immutable raw extract when the Section 8 long-form output does not preserve the New York Fed time-series identifier.

Validation:
- Ruff formatting: PASS
- Ruff linting: PASS
- Mypy: PASS
- Section 10 tests: PASS
- Full test suite: PASS
- Historical calibration execution: PASS
"@
        Invoke-External -FilePath "gh" -Arguments @(
            "pr", "create",
            "--base", "main",
            "--head", $Branch,
            "--title", "Phase II Section 10: Historical stress-window calibration",
            "--body", $prBody
        )
        Write-Pass "Pull request created"
    }
}

Write-Step "Section 10 completion summary"
Write-Pass "Historical stress-window identification: COMPLETE"
Write-Host "Branch: $Branch"
Write-Host "Selected windows: $($windowRows.Count)"
Write-Host "Table: reports/tables/historical_stress_windows.csv"
Write-Host "Configuration: configs/historical_scenarios.yaml"
Write-Host "Evidence: reports/evidence/historical_stress_calibration.txt"
Write-Host ""
Write-Host "Note: downloaded PowerShell files left in the repository root remain untracked unless you remove them manually." -ForegroundColor Yellow
