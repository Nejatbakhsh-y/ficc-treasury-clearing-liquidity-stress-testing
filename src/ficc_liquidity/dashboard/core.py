"""Data discovery and deterministic fallback data for the Streamlit dashboard."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Final

import numpy as np
import pandas as pd

SUPPORTED_SUFFIXES: Final[set[str]] = {".csv", ".parquet", ".json"}
EXCLUDED_PARTS: Final[set[str]] = {
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "node_modules",
    "setup_backups",
}

DATASET_SPECS: Final[dict[str, tuple[str, ...]]] = {
    "market_conditions": (
        "*federal*reserve*market*",
        "*market*conditions*",
        "*sofr*",
        "*treasury*yield*",
        "*h15*",
        "*h4*1*",
        "*primary*dealer*",
    ),
    "member_exposures": (
        "*synthetic*member*exposure*",
        "*synthetic*member*",
        "*member*portfolio*",
        "*member*exposure*",
    ),
    "cover_results": (
        "*cover*1*cover*2*",
        "*cover*results*",
        "*default*set*result*",
        "*scenario*summary*",
    ),
    "historical_scenarios": (
        "*historical*stress*",
        "*historical*scenario*",
        "*historical*replay*",
    ),
    "hypothetical_scenarios": (
        "*hypothetical*scenario*",
        "*scenario*library*",
        "*combined*systemic*",
    ),
    "lcr_results": (
        "*lcr*result*",
        "*integrated*stress*",
        "*liquidity*coverage*",
        "*scenario*result*",
    ),
    "component_contributions": (
        "*component*contribution*",
        "*stress*component*",
        "*integrated*stress*",
    ),
    "sensitivity_results": (
        "*sensitivity*result*",
        "*sensitivity*summary*",
        "*elasticity*",
    ),
    "reverse_stress": (
        "*reverse*stress*",
        "*minimum*shock*",
        "*vulnerable*member*",
    ),
    "monitoring_results": (
        "*monitoring*scorecard*",
        "*monthly*monitoring*",
        "*monitoring*summary*",
    ),
    "findings": (
        "*finding*register*",
        "*validation*finding*",
        "*findings*",
    ),
    "limitations": (
        "*uncertainty*limitation*",
        "*limitations*governance*",
        "*model*limitation*",
    ),
}

COMPONENT_COLUMNS: Final[tuple[str, ...]] = (
    "settlement_liquidity_need",
    "repo_rollover_need",
    "incremental_funding_cost",
    "additional_haircut_requirement",
    "treasury_liquidation_loss",
    "settlement_fail_requirement",
    "concentration_adjustment",
    "operational_liquidity_buffer",
)


@dataclass(frozen=True)
class DatasetBundle:
    """A loaded dashboard dataset and its lineage."""

    key: str
    data: pd.DataFrame
    source: str
    is_demo: bool
    note: str


def _normalise_columns(frame: pd.DataFrame) -> pd.DataFrame:
    result = frame.copy()
    result.columns = [
        str(column).strip().lower().replace(" ", "_").replace("-", "_") for column in result.columns
    ]
    for column in result.columns:
        if column == "date" or column.endswith("_date") or column == "as_of_date":
            converted = pd.to_datetime(result[column], errors="coerce")
            if converted.notna().any():
                result[column] = converted
    return result


def _candidate_score(path: Path, root: Path, patterns: tuple[str, ...]) -> tuple[int, int, float]:
    relative = path.relative_to(root).as_posix().lower()
    exact_hits = sum(1 for pattern in patterns if path.match(pattern))
    evidence_bonus = 5 if "evidence" in relative else 0
    report_bonus = 3 if relative.startswith("reports/") else 0
    processed_bonus = 2 if "processed" in relative or "analytical" in relative else 0
    return (
        exact_hits + evidence_bonus + report_bonus + processed_bonus,
        -len(relative),
        path.stat().st_mtime,
    )


def discover_candidates(root: Path, key: str) -> list[Path]:
    """Return ranked data files that can support one dashboard subject."""

    if key not in DATASET_SPECS:
        raise KeyError(f"Unknown dashboard dataset key: {key}")

    root = root.resolve()
    patterns = DATASET_SPECS[key]
    candidates: list[Path] = []

    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in SUPPORTED_SUFFIXES:
            continue
        relative_parts = set(path.relative_to(root).parts)
        if relative_parts.intersection(EXCLUDED_PARTS):
            continue
        name = path.name.lower()
        relative = path.relative_to(root).as_posix().lower()
        if (
            (
                any(path.match(pattern) for pattern in patterns)
                or any(
                    token.strip("*") in relative
                    for pattern in patterns
                    for token in pattern.split("*")
                    if len(token.strip("*")) >= 5
                )
            )
            and "manifest" not in name
            and "lineage" not in name
        ):
            candidates.append(path)

    return sorted(
        set(candidates),
        key=lambda item: _candidate_score(item, root, patterns),
        reverse=True,
    )


def _load_path(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix == ".csv":
        frame = pd.read_csv(path)
    elif suffix == ".parquet":
        frame = pd.read_parquet(path)
    elif suffix == ".json":
        try:
            frame = pd.read_json(path)
        except ValueError:
            payload = pd.read_json(path, typ="series")
            frame = payload.to_frame().T
    else:
        raise ValueError(f"Unsupported dashboard file: {path}")
    return _normalise_columns(frame)


def load_dataset(root: Path, key: str, *, allow_demo: bool = True) -> DatasetBundle:
    """Load the highest-priority usable artifact or deterministic fallback data."""

    errors: list[str] = []
    for candidate in discover_candidates(root, key):
        try:
            frame = _load_path(candidate)
            if not frame.empty:
                return DatasetBundle(
                    key=key,
                    data=frame,
                    source=candidate.relative_to(root).as_posix(),
                    is_demo=False,
                    note="Repository evidence artifact",
                )
        except (OSError, ValueError, TypeError) as exc:
            errors.append(f"{candidate.name}: {exc}")

    if not allow_demo:
        detail = "; ".join(errors[:3])
        raise FileNotFoundError(f"No usable artifact for {key}. {detail}".strip())

    return DatasetBundle(
        key=key,
        data=build_demo_data(key),
        source="deterministic synthetic fallback",
        is_demo=True,
        note=(
            "No compatible repository artifact was found. Values are deterministic, "
            "fictional, and provided only to validate dashboard behavior."
        ),
    )


def _scenario_frame() -> pd.DataFrame:
    scenarios = [
        ("Baseline", "Baseline", 1.34, 0.0),
        ("2019 Repo Stress Replay", "Historical", 1.12, 0.0),
        ("March 2020 Treasury Stress", "Historical", 0.96, 210.0),
        ("Moderate Parallel Shock", "Hypothetical", 1.18, 0.0),
        ("Severe Funding and Haircut", "Hypothetical", 0.88, 475.0),
        ("Extreme Combined Systemic", "Hypothetical", 0.72, 910.0),
    ]
    rows: list[dict[str, object]] = []
    for index, (scenario, scenario_type, lcr, shortfall) in enumerate(scenarios):
        requirement = 2_500.0 + index * 320.0
        available = requirement * lcr
        rows.append(
            {
                "date": pd.Timestamp("2026-06-30"),
                "scenario": scenario,
                "scenario_type": scenario_type,
                "cover_standard": "Cover 2" if index >= 2 else "Cover 1",
                "stressed_liquidity_requirement_usd_mm": requirement,
                "available_resources_usd_mm": available,
                "lcr": lcr,
                "liquidity_shortfall_usd_mm": shortfall,
                "dominant_component": [
                    "Settlement liquidity",
                    "Repo rollover",
                    "Treasury liquidation",
                    "Repo rollover",
                    "Additional haircut",
                    "Combined funding and settlement",
                ][index],
            }
        )
    return pd.DataFrame(rows)


def build_demo_data(key: str) -> pd.DataFrame:
    """Create deterministic synthetic data for a dashboard subject."""

    rng = np.random.default_rng(2026)

    if key == "market_conditions":
        dates = pd.date_range("2025-07-01", periods=52, freq="W-TUE")
        return pd.DataFrame(
            {
                "date": dates,
                "sofr_rate_pct": 4.35 + np.cumsum(rng.normal(0.0, 0.025, len(dates))),
                "sofr_volume_usd_bn": 1_850 + rng.normal(0.0, 95.0, len(dates)),
                "treasury_2y_yield_pct": 4.10 + np.cumsum(rng.normal(0.0, 0.035, len(dates))),
                "treasury_10y_yield_pct": 4.35 + np.cumsum(rng.normal(0.0, 0.030, len(dates))),
                "reserve_balances_usd_bn": 3_250 + np.cumsum(rng.normal(0.0, 18.0, len(dates))),
                "settlement_fails_usd_bn": np.maximum(5.0, 32.0 + rng.normal(0.0, 8.0, len(dates))),
            }
        )

    if key == "member_exposures":
        members = [f"SYN-MEMBER-{number:03d}" for number in range(1, 21)]
        buckets = ["Bills", "2Y", "5Y", "10Y", "30Y"]
        rows = []
        for member_index, member in enumerate(members, start=1):
            for bucket_index, bucket in enumerate(buckets, start=1):
                treasury = 210.0 + 35.0 * member_index + 22.0 * bucket_index
                rows.append(
                    {
                        "member_id": member,
                        "maturity_bucket": bucket,
                        "treasury_position_usd_mm": treasury,
                        "repo_financing_need_usd_mm": treasury * (0.42 + 0.01 * bucket_index),
                        "settlement_obligation_usd_mm": treasury * 0.29,
                        "available_resources_usd_mm": treasury * 0.63,
                        "concentration_score": min(1.0, 0.18 + 0.025 * member_index),
                        "funding_dependency": min(1.0, 0.22 + 0.022 * member_index),
                    }
                )
        return pd.DataFrame(rows)

    if key in {"cover_results", "lcr_results"}:
        return _scenario_frame()

    if key == "historical_scenarios":
        frame = _scenario_frame()
        return frame.loc[frame["scenario_type"] == "Historical"].reset_index(drop=True)

    if key == "hypothetical_scenarios":
        frame = _scenario_frame()
        return frame.loc[frame["scenario_type"] == "Hypothetical"].reset_index(drop=True)

    if key == "component_contributions":
        scenarios = _scenario_frame()["scenario"].tolist()
        rows = []
        for index, scenario in enumerate(scenarios):
            base = 320.0 + index * 55.0
            values = {
                "settlement_liquidity_need": base * 1.25,
                "repo_rollover_need": base * (1.05 + 0.11 * index),
                "incremental_funding_cost": base * 0.12,
                "additional_haircut_requirement": base * (0.32 + 0.04 * index),
                "treasury_liquidation_loss": base * (0.38 + 0.05 * index),
                "settlement_fail_requirement": base * 0.46,
                "concentration_adjustment": base * 0.18,
                "operational_liquidity_buffer": base * 0.15,
            }
            rows.append({"scenario": scenario, **values})
        return pd.DataFrame(rows)

    if key == "sensitivity_results":
        drivers = [
            "Yield shock",
            "Duration",
            "SOFR spike",
            "Rollover failure",
            "Haircut increase",
            "Settlement fails",
            "Member concentration",
            "Liquidation horizon",
            "Default-set size",
            "Available resources",
        ]
        elasticities = [0.31, 0.16, 0.18, 0.44, 0.37, 0.28, 0.21, 0.24, 0.39, -0.52]
        return pd.DataFrame(
            {
                "risk_driver": drivers,
                "low_assumption": [-25, -20, -50, -20, -25, -20, -15, -25, -50, -15],
                "high_assumption": [25, 20, 50, 20, 25, 20, 15, 25, 50, 15],
                "lcr_low": [1.11, 1.16, 1.15, 1.05, 1.08, 1.10, 1.13, 1.12, 1.02, 0.98],
                "lcr_high": [0.91, 0.96, 0.95, 0.82, 0.86, 0.89, 0.92, 0.90, 0.78, 1.22],
                "elasticity": elasticities,
                "monotonicity_status": ["PASS"] * len(drivers),
            }
        )

    if key == "reverse_stress":
        return pd.DataFrame(
            {
                "reverse_stress_test": [
                    "Yield shock threshold",
                    "Rollover-failure threshold",
                    "Haircut threshold",
                    "Combined-scenario threshold",
                    "Most vulnerable member pair",
                ],
                "threshold": [184.0, 0.37, 0.082, 0.61, np.nan],
                "unit": ["basis points", "fraction", "fraction", "severity index", "identifier"],
                "result": [
                    "LCR below 1.0",
                    "Positive liquidity shortfall",
                    "Positive liquidity shortfall",
                    "Positive liquidity shortfall",
                    "SYN-MEMBER-019 + SYN-MEMBER-020",
                ],
                "status": ["BREACH"] * 5,
            }
        )

    if key == "monitoring_results":
        controls = [
            "Data completeness",
            "Schema changes",
            "Missing observations",
            "Historical-range breaches",
            "Parameter changes",
            "Exposure concentration",
            "LCR distribution",
            "Scenario rank stability",
            "Component contribution drift",
            "Sensitivity changes",
            "Reconciliation failures",
        ]
        statuses = [
            "PASS",
            "PASS",
            "PASS",
            "WARN",
            "PASS",
            "WARN",
            "FAIL",
            "PASS",
            "PASS",
            "PASS",
            "PASS",
        ]
        return pd.DataFrame(
            {
                "as_of_date": pd.Timestamp("2026-06-30"),
                "control": controls,
                "status": statuses,
                "measure": [0.998, 0, 0, 0.014, 0.022, 0.214, 0.97, 0.96, 0.031, 0.08, 0],
                "threshold": [0.995, 0, 1, 0.010, 0.050, 0.200, 1.00, 0.900, 0.050, 0.150, 0],
                "owner": [
                    "Data Owner",
                    "Model Owner",
                    "Data Owner",
                    "Data Owner",
                    "Model Owner",
                    "Risk Analytics",
                    "Liquidity Risk",
                    "Model Validation",
                    "Model Owner",
                    "Model Validation",
                    "Independent Verification",
                ],
            }
        )

    if key == "findings":
        return pd.DataFrame(
            {
                "finding_id": ["FICC-LST-001", "FICC-LST-002", "FICC-LST-003", "FICC-LST-004"],
                "classification": ["Critical", "High", "Medium", "Observation"],
                "category": [
                    "Conceptual soundness",
                    "Data limitation",
                    "Implementation",
                    "Governance",
                ],
                "condition": [
                    "Intraday liquidity timing is not directly observed.",
                    "Participant-level calibration data are unavailable.",
                    "Fallback artifact mapping requires owner approval.",
                    "Dashboard lineage should be reviewed monthly.",
                ],
                "recommendation": [
                    "Restrict use and obtain intraday evidence.",
                    "Recalibrate when controlled participant data become available.",
                    "Approve and lock the artifact contract.",
                    "Include dashboard lineage in monthly sign-off.",
                ],
                "owner": ["Model Owner", "Data Owner", "Technology Owner", "Governance Owner"],
                "target_date": pd.to_datetime(
                    ["2026-09-30", "2026-12-31", "2026-08-31", "2026-08-15"]
                ),
                "status": ["Open", "In remediation", "Open", "Open"],
            }
        )

    if key == "limitations":
        return pd.DataFrame(
            {
                "limitation": [
                    "Aggregate-data uncertainty",
                    "Synthetic allocation uncertainty",
                    "Scenario-selection uncertainty",
                    "Parameter uncertainty",
                    "Missing intraday information",
                    "Participant-level data limitations",
                    "Operational and legal assumptions",
                    "Simplified liquidation functions",
                ],
                "residual_risk": [
                    "Medium",
                    "High",
                    "Medium",
                    "Medium",
                    "High",
                    "High",
                    "Medium",
                    "Medium",
                ],
                "model_use_restriction": [
                    "Use for directional market-level analysis only.",
                    "Do not infer actual participant exposures.",
                    "Maintain independent scenario challenge.",
                    "Report sensitivity ranges with point estimates.",
                    "Do not represent results as intraday liquidity forecasts.",
                    "Do not represent outputs as actual FICC outcomes.",
                    "Obtain legal and operational owner confirmation.",
                    "Benchmark against alternative liquidation functions.",
                ],
            }
        )

    raise KeyError(f"No deterministic fallback is defined for: {key}")
