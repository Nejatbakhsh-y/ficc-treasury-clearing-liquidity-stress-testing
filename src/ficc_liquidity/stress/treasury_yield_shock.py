"""Treasury yield-shock valuation using modified duration and convexity."""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import yaml


class TreasuryYieldStressError(ValueError):
    """Raised when yield-stress inputs or configuration are invalid."""


POSITION_ALIASES: dict[str, tuple[str, ...]] = {
    "member_id": (
        "member_id",
        "synthetic_member_id",
        "clearing_member_id",
    ),
    "maturity_bucket": (
        "maturity_bucket",
        "treasury_maturity_bucket",
        "bucket",
    ),
    "market_value_usd": (
        "market_value_usd",
        "treasury_market_value_usd",
        "position_market_value_usd",
        "notional_usd",
    ),
    "par_value_usd": (
        "par_value_usd",
        "treasury_par_value_usd",
        "face_value_usd",
    ),
    "modified_duration": (
        "modified_duration",
        "mod_duration",
    ),
    "convexity": (
        "convexity",
        "price_convexity",
    ),
    "liquidation_days": (
        "liquidation_days",
        "liquidation_horizon_days",
    ),
    "as_of_date": (
        "as_of_date",
        "observation_date",
        "date",
    ),
}


def load_stress_config(path: str | Path) -> dict[str, Any]:
    """Load and minimally validate the Section 15 YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise FileNotFoundError(f"Stress configuration not found: {config_path}")

    with config_path.open("r", encoding="utf-8") as handle:
        config = yaml.safe_load(handle)

    if not isinstance(config, dict):
        raise TreasuryYieldStressError("Configuration root must be a mapping.")

    required = {"input", "valuation", "market_impact", "maturity_buckets", "scenarios"}
    missing = required.difference(config)
    if missing:
        raise TreasuryYieldStressError(
            f"Configuration is missing required sections: {sorted(missing)}"
        )

    if not config["maturity_buckets"]:
        raise TreasuryYieldStressError("At least one maturity bucket is required.")

    return config


def _first_present_column(
    frame: pd.DataFrame,
    candidates: tuple[str, ...] | list[str],
) -> str | None:
    normalized = {str(column).lower(): str(column) for column in frame.columns}
    for candidate in candidates:
        found = normalized.get(candidate.lower())
        if found is not None:
            return found
    return None


def _canonicalize_positions(
    positions: pd.DataFrame,
    config: dict[str, Any],
) -> pd.DataFrame:
    if positions.empty:
        raise TreasuryYieldStressError("Treasury position input is empty.")

    frame = positions.copy()
    rename_map: dict[str, str] = {}

    for canonical, aliases in POSITION_ALIASES.items():
        source = _first_present_column(frame, aliases)
        if source is not None and canonical not in frame.columns:
            rename_map[source] = canonical

    frame = frame.rename(columns=rename_map)

    if "member_id" not in frame.columns:
        raise TreasuryYieldStressError("Position input is missing a synthetic member identifier.")

    if "maturity_bucket" not in frame.columns:
        wide_candidates = config["input"].get(
            "wide_position_column_candidates",
            {},
        )
        identifier_columns = ["member_id"]
        if "as_of_date" in frame.columns:
            identifier_columns.append("as_of_date")

        wide_parts: list[pd.DataFrame] = []
        for bucket, candidates in wide_candidates.items():
            source = _first_present_column(frame, candidates)
            if source is None:
                continue
            part = frame[identifier_columns].copy()
            part["maturity_bucket"] = bucket
            part["market_value_usd"] = frame[source]
            part["valuation_source"] = f"wide_market_value:{source}"
            wide_parts.append(part)

        if not wide_parts:
            raise TreasuryYieldStressError(
                "Position input has neither a maturity_bucket column nor "
                "configured wide maturity-position columns."
            )
        frame = pd.concat(wide_parts, ignore_index=True)

    if "market_value_usd" not in frame.columns:
        allow_par = bool(config["input"].get("allow_par_value_as_market_value", False))
        if allow_par and "par_value_usd" in frame.columns:
            frame["market_value_usd"] = frame["par_value_usd"]
            frame["valuation_source"] = "par_value_proxy"
        else:
            raise TreasuryYieldStressError(
                "Position input requires market_value_usd or an approved par-value proxy."
            )
    elif "valuation_source" not in frame.columns:
        frame["valuation_source"] = "market_value"

    frame["member_id"] = frame["member_id"].astype(str)
    frame["maturity_bucket"] = frame["maturity_bucket"].astype(str)
    frame["market_value_usd"] = pd.to_numeric(
        frame["market_value_usd"],
        errors="raise",
    )

    if frame["market_value_usd"].isna().any():
        raise TreasuryYieldStressError("market_value_usd contains missing values.")

    pattern = config["input"].get("required_member_id_pattern")
    if pattern:
        invalid = ~frame["member_id"].str.match(re.compile(str(pattern)))
        if invalid.any():
            examples = sorted(frame.loc[invalid, "member_id"].unique())[:5]
            raise TreasuryYieldStressError(
                "Synthetic-member safeguard failed. Member IDs must match "
                f"{pattern!r}. Invalid examples: {examples}"
            )

    bucket_config = config["maturity_buckets"]
    unknown = sorted(set(frame["maturity_bucket"]).difference(bucket_config))
    if unknown:
        raise TreasuryYieldStressError(
            f"Position input contains unconfigured maturity buckets: {unknown}"
        )

    for field in ("modified_duration", "convexity", "liquidation_days"):
        configured = frame["maturity_bucket"].map(
            {bucket: values[field] for bucket, values in bucket_config.items()}
        )
        if field not in frame.columns:
            frame[field] = configured
        else:
            supplied = pd.to_numeric(frame[field], errors="coerce")
            frame[field] = supplied.fillna(configured)

    if "as_of_date" in frame.columns:
        frame["as_of_date"] = pd.to_datetime(frame["as_of_date"], errors="raise")
    else:
        frame["as_of_date"] = pd.NaT

    numeric_fields = [
        "market_value_usd",
        "modified_duration",
        "convexity",
        "liquidation_days",
    ]
    if not np.isfinite(frame[numeric_fields].to_numpy(dtype=float)).all():
        raise TreasuryYieldStressError("Position valuation fields must be finite.")

    if (frame["modified_duration"] < 0).any():
        raise TreasuryYieldStressError("Modified duration cannot be negative.")
    if (frame["convexity"] < 0).any():
        raise TreasuryYieldStressError("Convexity cannot be negative.")
    if (frame["liquidation_days"] <= 0).any():
        raise TreasuryYieldStressError("Liquidation days must be positive.")

    frame["gross_member_value_usd"] = frame.groupby("member_id")["market_value_usd"].transform(
        lambda series: series.abs().sum()
    )

    denominator = frame["gross_member_value_usd"].replace(0.0, np.nan)
    frame["member_position_concentration"] = (frame["market_value_usd"].abs() / denominator).fillna(
        0.0
    )

    return frame


def build_shock_vector(
    scenario: dict[str, Any],
    maturity_buckets: dict[str, dict[str, float]],
) -> dict[str, float]:
    """Return maturity-bucket yield shocks in basis points."""
    scenario_type = str(scenario.get("type", "")).lower()
    bucket_names = list(maturity_buckets)

    if scenario_type == "parallel":
        shock = float(scenario["shock_bp"])
        return {bucket: shock for bucket in bucket_names}

    if scenario_type == "bucket_vector":
        supplied = scenario.get("shocks_bp", {})
        missing = set(bucket_names).difference(supplied)
        if missing:
            raise TreasuryYieldStressError(
                f"Scenario {scenario.get('name')} is missing bucket shocks: {sorted(missing)}"
            )
        return {bucket: float(supplied[bucket]) for bucket in bucket_names}

    if scenario_type == "key_rate":
        key_rate = float(scenario["key_rate_years"])
        peak = float(scenario["peak_bp"])
        width = float(scenario["width_years"])
        floor = float(scenario.get("floor_bp", 0.0))
        if width <= 0:
            raise TreasuryYieldStressError("Key-rate width_years must be positive.")

        result: dict[str, float] = {}
        for bucket, assumptions in maturity_buckets.items():
            maturity = float(assumptions["midpoint_years"])
            triangular_weight = max(0.0, 1.0 - abs(maturity - key_rate) / width)
            result[bucket] = floor + (peak - floor) * triangular_weight
        return result

    if scenario_type == "h15_historical":
        shocks = scenario.get("shocks_bp")
        if not isinstance(shocks, dict):
            raise TreasuryYieldStressError(
                "An H.15 historical scenario must contain derived shocks_bp."
            )
        missing = set(bucket_names).difference(shocks)
        if missing:
            raise TreasuryYieldStressError(
                f"H.15 scenario is missing bucket shocks: {sorted(missing)}"
            )
        return {bucket: float(shocks[bucket]) for bucket in bucket_names}

    raise TreasuryYieldStressError(f"Unsupported scenario type: {scenario.get('type')!r}")


def derive_h15_bucket_shocks(
    market_data: pd.DataFrame,
    start_date: str,
    end_date: str,
    config: dict[str, Any],
) -> dict[str, float]:
    """Derive bucket shocks from changes in available H.15 constant-maturity yields."""
    if market_data.empty:
        raise TreasuryYieldStressError("H.15 market data are empty.")

    h15_config = config["h15"]
    date_column = _first_present_column(
        market_data,
        h15_config["date_column_candidates"],
    )
    if date_column is None:
        raise TreasuryYieldStressError("No configured H.15 observation-date column was found.")

    frame = market_data.copy()
    frame[date_column] = pd.to_datetime(frame[date_column], errors="raise")
    frame = frame.sort_values(date_column)

    start = pd.Timestamp(start_date)
    end = pd.Timestamp(end_date)
    if start >= end:
        raise TreasuryYieldStressError("H.15 start date must precede end date.")

    start_rows = frame.loc[frame[date_column] <= start]
    end_rows = frame.loc[frame[date_column] <= end]
    if start_rows.empty or end_rows.empty:
        raise TreasuryYieldStressError(
            "H.15 data do not contain observations on or before both requested dates."
        )

    start_row = start_rows.iloc[-1]
    end_row = end_rows.iloc[-1]
    unit = str(h15_config.get("yield_unit", "percent")).lower()
    unit_to_bp = {
        "percent": 100.0,
        "decimal": 10000.0,
        "basis_points": 1.0,
        "bp": 1.0,
    }
    if unit not in unit_to_bp:
        raise TreasuryYieldStressError(f"Unsupported H.15 yield unit: {unit}")

    observed_maturities: list[float] = []
    observed_shocks: list[float] = []

    for maturity_text, candidates in h15_config["key_rate_column_candidates"].items():
        column = _first_present_column(frame, candidates)
        if column is None:
            continue

        start_value = pd.to_numeric(pd.Series([start_row[column]]), errors="coerce").iloc[0]
        end_value = pd.to_numeric(pd.Series([end_row[column]]), errors="coerce").iloc[0]
        if pd.isna(start_value) or pd.isna(end_value):
            continue

        observed_maturities.append(float(maturity_text))
        observed_shocks.append(float(end_value - start_value) * unit_to_bp[unit])

    if len(observed_maturities) < 2:
        raise TreasuryYieldStressError("At least two usable H.15 key-rate columns are required.")

    order = np.argsort(np.asarray(observed_maturities))
    maturities = np.asarray(observed_maturities, dtype=float)[order]
    shocks = np.asarray(observed_shocks, dtype=float)[order]

    bucket_shocks: dict[str, float] = {}
    for bucket, assumptions in config["maturity_buckets"].items():
        midpoint = float(assumptions["midpoint_years"])
        bucket_shocks[bucket] = float(np.interp(midpoint, maturities, shocks))

    return bucket_shocks


@dataclass(frozen=True)
class StressRunResult:
    """Position-level and aggregate results for a stress run."""

    positions: pd.DataFrame
    member_summary: pd.DataFrame
    scenario_summary: pd.DataFrame


class TreasuryYieldShockModel:
    """Apply Treasury yield shocks to synthetic member positions."""

    def __init__(self, config: dict[str, Any]) -> None:
        self.config = config
        self.bucket_config = config["maturity_buckets"]
        self.valuation = config["valuation"]
        self.market_impact = config["market_impact"]

    def _market_impact_bp(self, frame: pd.DataFrame) -> pd.Series:
        if not bool(self.market_impact.get("enabled", True)):
            return pd.Series(0.0, index=frame.index, dtype=float)

        reference = float(self.market_impact["reference_position_usd"])
        base = float(self.market_impact["base_impact_bp"])
        exponent = float(self.market_impact["size_exponent"])
        cap = float(self.market_impact["maximum_impact_bp"])
        threshold = float(self.market_impact["concentration_threshold"])
        multiplier_per_excess = float(
            self.market_impact["concentration_multiplier_per_excess_share"]
        )

        if reference <= 0 or exponent < 0 or cap < 0:
            raise TreasuryYieldStressError("Invalid market-impact configuration.")

        size_ratio = frame["market_value_usd"].abs() / reference
        concentration_excess = (frame["member_position_concentration"] - threshold).clip(lower=0.0)
        concentration_multiplier = 1.0 + concentration_excess * multiplier_per_excess

        horizon_factor = np.sqrt(
            frame["liquidation_days"] / float(self.valuation["reference_liquidation_days"])
        )

        impact = base * np.power(size_ratio, exponent) * concentration_multiplier * horizon_factor
        return impact.clip(lower=0.0, upper=cap)

    def apply_scenario(
        self,
        positions: pd.DataFrame,
        scenario: dict[str, Any],
    ) -> pd.DataFrame:
        """Apply one configured scenario and return position-level losses."""
        frame = _canonicalize_positions(positions, self.config)
        shocks = build_shock_vector(scenario, self.bucket_config)

        frame["scenario_name"] = str(scenario["name"])
        frame["scenario_family"] = str(scenario.get("family", scenario.get("type", "unspecified")))
        frame["base_yield_shock_bp"] = frame["maturity_bucket"].map(shocks).astype(float)

        reference_days = float(self.valuation["reference_liquidation_days"])
        if reference_days <= 0:
            raise TreasuryYieldStressError("reference_liquidation_days must be positive.")

        if bool(self.valuation.get("scale_shocks_by_sqrt_liquidation_horizon", True)):
            frame["liquidation_horizon_factor"] = np.sqrt(
                frame["liquidation_days"] / reference_days
            )
        else:
            frame["liquidation_horizon_factor"] = 1.0

        frame["horizon_scaled_shock_bp"] = (
            frame["base_yield_shock_bp"] * frame["liquidation_horizon_factor"]
        )
        frame["market_impact_bp"] = self._market_impact_bp(frame)

        position_direction = np.sign(frame["market_value_usd"]).replace(0.0, 1.0)
        frame["effective_yield_shock_bp"] = (
            frame["horizon_scaled_shock_bp"] + position_direction * frame["market_impact_bp"]
        )
        frame["yield_change_decimal"] = frame["effective_yield_shock_bp"] / 10000.0

        dy = frame["yield_change_decimal"]
        frame["duration_return"] = -frame["modified_duration"] * dy
        frame["convexity_return"] = 0.5 * frame["convexity"] * np.square(dy)
        frame["estimated_price_return"] = frame["duration_return"] + frame["convexity_return"]

        floor = float(self.valuation.get("floor_price_factor", 0.0))
        frame["stressed_price_factor"] = (1.0 + frame["estimated_price_return"]).clip(lower=floor)
        frame["stressed_market_value_usd"] = (
            frame["market_value_usd"] * frame["stressed_price_factor"]
        )
        frame["treasury_pnl_usd"] = frame["stressed_market_value_usd"] - frame["market_value_usd"]
        frame["treasury_loss_usd"] = (-frame["treasury_pnl_usd"]).clip(lower=0.0)

        numeric_output = [
            "base_yield_shock_bp",
            "horizon_scaled_shock_bp",
            "market_impact_bp",
            "effective_yield_shock_bp",
            "estimated_price_return",
            "stressed_market_value_usd",
            "treasury_pnl_usd",
            "treasury_loss_usd",
        ]
        if not np.isfinite(frame[numeric_output].to_numpy(dtype=float)).all():
            raise TreasuryYieldStressError("Stress output contains non-finite values.")

        return frame

    def run(
        self,
        positions: pd.DataFrame,
        scenarios: list[dict[str, Any]] | None = None,
    ) -> StressRunResult:
        """Run all enabled scenarios and aggregate member and scenario results."""
        selected = scenarios or [
            scenario for scenario in self.config["scenarios"] if bool(scenario.get("enabled", True))
        ]
        if not selected:
            raise TreasuryYieldStressError("No enabled stress scenarios were supplied.")

        outputs = [self.apply_scenario(positions, scenario) for scenario in selected]
        position_results = pd.concat(outputs, ignore_index=True)

        member_summary = (
            position_results.groupby(
                ["scenario_name", "scenario_family", "member_id"],
                as_index=False,
            )
            .agg(
                gross_market_value_usd=("market_value_usd", lambda values: values.abs().sum()),
                stressed_market_value_usd=("stressed_market_value_usd", "sum"),
                treasury_pnl_usd=("treasury_pnl_usd", "sum"),
                treasury_loss_usd=("treasury_loss_usd", "sum"),
                maximum_effective_shock_bp=("effective_yield_shock_bp", "max"),
                maximum_position_concentration=(
                    "member_position_concentration",
                    "max",
                ),
                maximum_liquidation_days=("liquidation_days", "max"),
            )
            .sort_values(["scenario_name", "treasury_loss_usd"], ascending=[True, False])
        )

        scenario_summary = (
            member_summary.groupby(
                ["scenario_name", "scenario_family"],
                as_index=False,
            )
            .agg(
                aggregate_treasury_pnl_usd=("treasury_pnl_usd", "sum"),
                aggregate_treasury_loss_usd=("treasury_loss_usd", "sum"),
                largest_member_loss_usd=("treasury_loss_usd", "max"),
                affected_members=("member_id", "nunique"),
            )
            .sort_values("aggregate_treasury_loss_usd", ascending=False)
        )

        return StressRunResult(
            positions=position_results,
            member_summary=member_summary.reset_index(drop=True),
            scenario_summary=scenario_summary.reset_index(drop=True),
        )


def duration_convexity_price_return(
    modified_duration: float,
    convexity: float,
    yield_shock_bp: float,
) -> float:
    """Return the second-order price-return approximation."""
    dy = yield_shock_bp / 10000.0
    return -modified_duration * dy + 0.5 * convexity * math.pow(dy, 2)
