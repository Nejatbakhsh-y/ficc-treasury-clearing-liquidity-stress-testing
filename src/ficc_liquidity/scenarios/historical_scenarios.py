"""Empirical historical-scenario replay for Phase VI, Section 20.

The module converts Section 10 selected windows and Section 8 canonical long-form
Federal Reserve data into observed scenario shocks. It then maps the non-yield
components to the nearest already-validated Phase V component scenarios and uses
actual observed H.15 key-rate changes for Treasury valuation.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import yaml


class HistoricalScenarioError(ValueError):
    """Raised when Section 20 inputs, assumptions, or replay controls are invalid."""


FACTOR_GROUPS: tuple[str, ...] = (
    "sofr",
    "treasury_yields",
    "financing_volume",
    "settlement_fails",
    "reserve_balances",
)

RAW_SEVERITY_COLUMNS: tuple[str, ...] = (
    "sofr_spike_bp",
    "maximum_absolute_treasury_shock_bp",
    "financing_contraction_rate",
    "settlement_fail_increase_rate",
    "reserve_contraction_rate",
)


@dataclass(frozen=True, slots=True)
class HistoricalWindow:
    """One empirically selected Section 10 historical window."""

    scenario_id: str
    name: str
    start_date: pd.Timestamp
    peak_date: pd.Timestamp
    end_date: pd.Timestamp
    anchor_match: str | None
    trigger_components: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ReplaySettings:
    """Validated Section 20 runtime settings."""

    model_version: str
    scenario_catalog: Path
    analytical_inputs: tuple[Path, ...]
    maximum_asof_lookback_days: int
    observed_only: bool
    factor_weights: Mapping[str, float]
    factor_caps: Mapping[str, float]
    output_directory: Path
    evidence_directory: Path
    manifest_path: Path
    write_csv: bool
    write_parquet: bool


@dataclass(frozen=True, slots=True)
class CalibrationOutput:
    """Observed factor shocks and audit observations for all historical windows."""

    scenario_metrics: pd.DataFrame
    treasury_bucket_shocks: pd.DataFrame
    factor_observations: pd.DataFrame


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HistoricalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def load_yaml(path: str | Path) -> dict[str, Any]:
    """Load a UTF-8 YAML mapping."""
    yaml_path = Path(path)
    if not yaml_path.exists():
        raise HistoricalScenarioError(f"Configuration does not exist: {yaml_path}")
    loaded = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    return _mapping(loaded, str(yaml_path))


def load_replay_settings(config: Mapping[str, Any], root: Path) -> ReplaySettings:
    """Validate the Section 20 replay configuration."""
    source = _mapping(config.get("source"), "source")
    validation = _mapping(config.get("validation"), "validation")
    output = _mapping(config.get("output"), "output")
    raw_inputs = source.get("analytical_inputs")
    if not isinstance(raw_inputs, list) or not raw_inputs:
        raise HistoricalScenarioError("source.analytical_inputs must be a nonempty list.")
    raw_weights = _mapping(config.get("severity_weights"), "severity_weights")
    raw_caps = _mapping(config.get("factor_caps"), "factor_caps")
    weights: dict[str, float] = {}
    for factor in RAW_SEVERITY_COLUMNS:
        value = raw_weights.get(factor)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HistoricalScenarioError(f"severity_weights.{factor} must be numeric.")
        number = float(value)
        if not math.isfinite(number) or number < 0.0:
            raise HistoricalScenarioError(
                f"severity_weights.{factor} must be finite and nonnegative."
            )
        weights[factor] = number
    if sum(weights.values()) <= 0.0:
        raise HistoricalScenarioError("At least one severity weight must be positive.")
    caps: dict[str, float] = {}
    for factor in RAW_SEVERITY_COLUMNS:
        value = raw_caps.get(factor)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HistoricalScenarioError(f"factor_caps.{factor} must be numeric.")
        number = float(value)
        if not math.isfinite(number) or number <= 0.0:
            raise HistoricalScenarioError(f"factor_caps.{factor} must be finite and positive.")
        caps[factor] = number
    lookback = validation.get("maximum_asof_lookback_days", 35)
    if isinstance(lookback, bool) or not isinstance(lookback, int) or lookback < 0:
        raise HistoricalScenarioError(
            "validation.maximum_asof_lookback_days must be a nonnegative integer."
        )
    model_version = str(config.get("model_version", "section-20-v1")).strip()
    if not model_version:
        raise HistoricalScenarioError("model_version cannot be empty.")
    return ReplaySettings(
        model_version=model_version,
        scenario_catalog=root / str(source.get("scenario_catalog")),
        analytical_inputs=tuple(root / str(item) for item in raw_inputs),
        maximum_asof_lookback_days=lookback,
        observed_only=bool(validation.get("observed_only", True)),
        factor_weights=weights,
        factor_caps=caps,
        output_directory=root / str(output.get("directory", "reports/tables")),
        evidence_directory=root / str(output.get("evidence_directory", "reports/evidence")),
        manifest_path=root
        / str(output.get("manifest", "data/manifests/historical_scenario_manifest.csv")),
        write_csv=bool(output.get("write_csv", True)),
        write_parquet=bool(output.get("write_parquet", True)),
    )


def load_historical_windows(catalog: Mapping[str, Any]) -> tuple[HistoricalWindow, ...]:
    """Read Section 10 selected scenarios without substituting candidate anchors."""
    raw = catalog.get("selected_scenarios")
    if not isinstance(raw, list) or not raw:
        raise HistoricalScenarioError("selected_scenarios must be a nonempty list.")
    windows: list[HistoricalWindow] = []
    for item in raw:
        row = _mapping(item, "selected scenario")
        scenario_id = str(row.get("id", "")).strip()
        name = str(row.get("name", "")).strip()
        start = pd.Timestamp(str(row.get("start_date", ""))).normalize()
        peak = pd.Timestamp(str(row.get("peak_date", row.get("start_date", "")))).normalize()
        end = pd.Timestamp(str(row.get("end_date", ""))).normalize()
        if not scenario_id or not name:
            raise HistoricalScenarioError("Each selected scenario requires id and name.")
        if start > peak or peak > end:
            raise HistoricalScenarioError(
                f"Historical window {scenario_id} must satisfy start <= peak <= end."
            )
        selection = _mapping(row.get("selection", {}), f"{scenario_id}.selection")
        triggers_raw = selection.get("trigger_components", [])
        if not isinstance(triggers_raw, list):
            raise HistoricalScenarioError(
                f"{scenario_id}.selection.trigger_components must be a list."
            )
        anchor = row.get("anchor_match")
        windows.append(
            HistoricalWindow(
                scenario_id=scenario_id,
                name=name,
                start_date=start,
                peak_date=peak,
                end_date=end,
                anchor_match=None if anchor is None else str(anchor),
                trigger_components=tuple(str(value) for value in triggers_raw),
            )
        )
    if len({window.scenario_id for window in windows}) != len(windows):
        raise HistoricalScenarioError("Historical scenario identifiers must be unique.")
    return tuple(windows)


def prepare_long_form(frame: pd.DataFrame, observed_only: bool) -> pd.DataFrame:
    """Validate and canonicalize Section 8 long-form analytical data."""
    required = {
        "observation_date",
        "alignment_frequency",
        "source_name",
        "source_series_id",
        "source_metric",
        "value",
        "standardized_unit",
        "metric_kind",
    }
    missing = sorted(required - set(frame.columns))
    if missing:
        raise HistoricalScenarioError(f"Analytical data are missing fields: {missing}")
    result = frame.copy(deep=True)
    result["observation_date"] = pd.to_datetime(
        result["observation_date"], errors="coerce"
    ).dt.normalize()
    result["value"] = pd.to_numeric(result["value"], errors="coerce")
    result["source_name"] = result["source_name"].astype("string").str.upper()
    result["source_series_id"] = result["source_series_id"].astype("string")
    result["source_metric"] = result["source_metric"].astype("string")
    result["alignment_frequency"] = result["alignment_frequency"].astype("string").str.lower()
    result["standardized_unit"] = result["standardized_unit"].astype("string").str.upper()
    result["metric_kind"] = result["metric_kind"].astype("string").str.lower()
    result = result.dropna(subset=["observation_date", "value"])
    if observed_only and "is_observed" in result.columns:
        observed_mask = result["is_observed"].fillna(False).astype(bool)
        result = pd.DataFrame(result.loc[observed_mask].copy())
    result["series_key"] = (
        result["source_name"].astype(str)
        + "::"
        + result["source_series_id"].astype(str)
        + "::"
        + result["alignment_frequency"].astype(str)
    )
    result_any: Any = result
    ordered_any: Any = result_any.sort_values(
        by=["observation_date", "source_name", "source_series_id"],
        kind="stable",
    )
    reset_any: Any = ordered_any.reset_index(drop=True)
    return cast(pd.DataFrame, reset_any)


def _text(frame: pd.DataFrame) -> pd.Series:
    return (
        frame["source_series_id"].fillna("").astype(str)
        + " "
        + frame["source_metric"].fillna("").astype(str)
    ).str.lower()


def select_series_group(
    frame: pd.DataFrame,
    rule: Mapping[str, Any],
) -> pd.DataFrame:
    """Apply the controlled Section 10 series rule for one factor group."""
    mask = pd.Series(True, index=frame.index)
    sources = {str(value).upper() for value in rule.get("source_names", [])}
    if sources:
        mask &= frame["source_name"].isin(sources)
    frequency = str(rule.get("alignment_frequency", "")).strip().lower()
    if frequency:
        mask &= frame["alignment_frequency"].eq(frequency)
    units = {str(value).upper() for value in rule.get("standardized_units", [])}
    if units:
        mask &= frame["standardized_unit"].isin(units)
    kinds = {str(value).lower() for value in rule.get("metric_kinds", [])}
    if kinds:
        mask &= frame["metric_kind"].isin(kinds)
    if bool(rule.get("require_maturity", False)):
        if "maturity_months" not in frame.columns:
            return frame.iloc[0:0].copy()
        mask &= pd.to_numeric(frame["maturity_months"], errors="coerce").notna()
    exact = {str(value) for value in rule.get("exact_series_ids", [])}
    if exact:
        mask &= frame["source_series_id"].isin(exact)
    searchable = _text(frame)
    includes = [str(value) for value in rule.get("include_patterns", [])]
    if includes:
        include_mask = pd.Series(False, index=frame.index)
        for pattern in includes:
            include_mask |= searchable.str.contains(pattern, regex=True, na=False)
        mask &= include_mask
    for pattern in [str(value) for value in rule.get("exclude_patterns", [])]:
        mask &= ~searchable.str.contains(pattern, regex=True, na=False)
    return frame.loc[mask].copy()


def resolve_factor_groups(
    frame: pd.DataFrame,
    catalog: Mapping[str, Any],
) -> dict[str, pd.DataFrame]:
    """Resolve the five controlled Section 20 factor groups."""
    rules = _mapping(catalog.get("series_rules"), "series_rules")
    result: dict[str, pd.DataFrame] = {}
    for group in FACTOR_GROUPS:
        rule = _mapping(rules.get(group), f"series_rules.{group}")
        result[group] = select_series_group(frame, rule)
    return result


def _unit_multiplier_to_bp(unit: str) -> float:
    normalized = unit.upper()
    if normalized == "PERCENT":
        return 100.0
    if normalized in {"BASIS_POINTS", "BP", "BPS"}:
        return 1.0
    if normalized == "DECIMAL":
        return 10_000.0
    raise HistoricalScenarioError(f"Unsupported rate unit for basis-point conversion: {unit}")


def _asof_row(
    frame: pd.DataFrame,
    target_date: pd.Timestamp,
    maximum_lookback_days: int,
) -> pd.Series | None:
    eligible = frame.loc[frame["observation_date"] <= target_date]
    if eligible.empty:
        return None
    row = eligible.sort_values("observation_date", kind="stable").iloc[-1]
    age = int((target_date - pd.Timestamp(row["observation_date"])).days)
    if age > maximum_lookback_days:
        return None
    return row


def _aggregate_level_series(frame: pd.DataFrame) -> pd.DataFrame:
    if frame.empty:
        return pd.DataFrame(columns=["observation_date", "value"])

    grouped_any: Any = frame.groupby("observation_date", as_index=False)
    summed_any: Any = grouped_any["value"].sum()
    ordered_any: Any = summed_any.sort_values(
        by="observation_date",
        kind="stable",
    )
    return cast(pd.DataFrame, ordered_any.reset_index(drop=True))


def _level_metrics(
    frame: pd.DataFrame,
    window: HistoricalWindow,
    lookback_days: int,
    direction: str,
    factor_group: str,
) -> tuple[dict[str, float], list[dict[str, object]]]:
    series = _aggregate_level_series(frame)
    if series.empty:
        return {}, []
    start = _asof_row(series, window.start_date, lookback_days)
    end = _asof_row(series, window.end_date, lookback_days)
    within = series.loc[
        series["observation_date"].between(window.start_date, window.end_date, inclusive="both")
    ]
    if start is None or end is None or within.empty:
        return {}, []
    start_value = float(start["value"])
    end_value = float(end["value"])
    peak_value = float(within["value"].max())
    trough_value = float(within["value"].min())
    denominator = abs(start_value)
    if direction == "increase":
        stress_rate = max(0.0, (peak_value - start_value) / denominator) if denominator else 0.0
    elif direction == "contraction":
        stress_rate = max(0.0, (start_value - trough_value) / denominator) if denominator else 0.0
    else:
        raise HistoricalScenarioError(f"Unsupported level direction: {direction}")
    audit = [
        {
            "scenario_id": window.scenario_id,
            "factor_group": factor_group,
            "statistic": "start",
            "observation_date": pd.Timestamp(start["observation_date"]),
            "value": start_value,
        },
        {
            "scenario_id": window.scenario_id,
            "factor_group": factor_group,
            "statistic": "end",
            "observation_date": pd.Timestamp(end["observation_date"]),
            "value": end_value,
        },
    ]
    return {
        "start_value": start_value,
        "end_value": end_value,
        "peak_value": peak_value,
        "trough_value": trough_value,
        "stress_rate": stress_rate,
    }, audit


def _sofr_metrics(
    frame: pd.DataFrame,
    window: HistoricalWindow,
    lookback_days: int,
) -> tuple[dict[str, float], list[dict[str, object]]]:
    if frame.empty:
        return {}, []
    records: list[pd.DataFrame] = []
    for _, group in frame.groupby("series_key", sort=True):
        ordered = group.sort_values("observation_date", kind="stable")
        start = _asof_row(ordered, window.start_date, lookback_days)
        end = _asof_row(ordered, window.end_date, lookback_days)
        within = ordered.loc[
            ordered["observation_date"].between(
                window.start_date, window.end_date, inclusive="both"
            )
        ]
        if start is None or end is None or within.empty:
            continue
        multiplier = _unit_multiplier_to_bp(str(start["standardized_unit"]))
        part = within[["observation_date", "value"]].copy()
        part["value_bp"] = part["value"].astype(float) * multiplier
        part["start_bp"] = float(start["value"]) * multiplier
        part["end_bp"] = float(end["value"]) * multiplier
        records.append(part)
    if not records:
        return {}, []
    combined = pd.concat(records, ignore_index=True)
    start_bp = float(combined["start_bp"].median())
    end_bp = float(combined["end_bp"].median())
    peak_bp = float(combined["value_bp"].max())
    audit = [
        {
            "scenario_id": window.scenario_id,
            "factor_group": "sofr",
            "statistic": "start_bp",
            "observation_date": window.start_date,
            "value": start_bp,
        },
        {
            "scenario_id": window.scenario_id,
            "factor_group": "sofr",
            "statistic": "peak_bp",
            "observation_date": window.peak_date,
            "value": peak_bp,
        },
        {
            "scenario_id": window.scenario_id,
            "factor_group": "sofr",
            "statistic": "end_bp",
            "observation_date": window.end_date,
            "value": end_bp,
        },
    ]
    return {
        "sofr_start_bp": start_bp,
        "sofr_end_bp": end_bp,
        "sofr_peak_bp": peak_bp,
        "sofr_spike_bp": max(0.0, peak_bp - start_bp),
    }, audit


def derive_treasury_bucket_shocks(
    frame: pd.DataFrame,
    window: HistoricalWindow,
    maturity_buckets: Mapping[str, Mapping[str, Any]],
    lookback_days: int,
) -> tuple[dict[str, float], list[dict[str, object]]]:
    """Interpolate observed H.15 maturity shocks to Section 15 maturity buckets."""
    observed: list[tuple[float, float]] = []
    audit: list[dict[str, object]] = []
    if frame.empty or "maturity_months" not in frame.columns:
        return {}, audit
    for key, group in frame.groupby("series_key", sort=True):
        ordered = group.sort_values("observation_date", kind="stable")
        start = _asof_row(ordered, window.start_date, lookback_days)
        end = _asof_row(ordered, window.end_date, lookback_days)
        if start is None or end is None:
            continue
        maturity = pd.to_numeric(pd.Series([start.get("maturity_months")]), errors="coerce").iloc[0]
        if pd.isna(maturity):
            continue
        multiplier = _unit_multiplier_to_bp(str(start["standardized_unit"]))
        shock = (float(end["value"]) - float(start["value"])) * multiplier
        maturity_years = float(maturity) / 12.0
        observed.append((maturity_years, shock))
        audit.append(
            {
                "scenario_id": window.scenario_id,
                "factor_group": "treasury_yields",
                "statistic": str(key),
                "observation_date": pd.Timestamp(end["observation_date"]),
                "value": shock,
            }
        )
    if len(observed) < 2:
        return {}, audit
    ordered_observed = sorted(observed)
    maturities = np.asarray([item[0] for item in ordered_observed], dtype=float)
    shocks = np.asarray([item[1] for item in ordered_observed], dtype=float)
    bucket_shocks: dict[str, float] = {}
    for bucket, assumptions in maturity_buckets.items():
        midpoint = float(assumptions["midpoint_years"])
        bucket_shocks[str(bucket)] = float(np.interp(midpoint, maturities, shocks))
    return bucket_shocks, audit


def calibrate_historical_scenarios(
    frame: pd.DataFrame,
    windows: Sequence[HistoricalWindow],
    catalog: Mapping[str, Any],
    treasury_config: Mapping[str, Any],
    settings: ReplaySettings,
) -> CalibrationOutput:
    """Derive observed shocks and empirical cross-window severity scores."""
    prepared = prepare_long_form(frame, settings.observed_only)
    groups = resolve_factor_groups(prepared, catalog)
    maturity_buckets = _mapping(treasury_config.get("maturity_buckets"), "maturity_buckets")
    metric_rows: list[dict[str, object]] = []
    bucket_rows: list[dict[str, object]] = []
    audit_rows: list[dict[str, object]] = []
    for window in windows:
        row: dict[str, object] = {
            "scenario_id": window.scenario_id,
            "scenario_name": window.name,
            "start_date": window.start_date,
            "peak_date": window.peak_date,
            "end_date": window.end_date,
            "anchor_match": window.anchor_match or "",
            "trigger_components": "|".join(window.trigger_components),
        }
        sofr, audit = _sofr_metrics(groups["sofr"], window, settings.maximum_asof_lookback_days)
        row.update(sofr)
        audit_rows.extend(audit)
        financing, audit = _level_metrics(
            groups["financing_volume"],
            window,
            settings.maximum_asof_lookback_days,
            "contraction",
            "financing_volume",
        )
        row["financing_contraction_rate"] = financing.get("stress_rate", np.nan)
        audit_rows.extend(audit)
        fails, audit = _level_metrics(
            groups["settlement_fails"],
            window,
            settings.maximum_asof_lookback_days,
            "increase",
            "settlement_fails",
        )
        row["settlement_fail_increase_rate"] = fails.get("stress_rate", np.nan)
        audit_rows.extend(audit)
        reserves, audit = _level_metrics(
            groups["reserve_balances"],
            window,
            settings.maximum_asof_lookback_days,
            "contraction",
            "reserve_balances",
        )
        row["reserve_contraction_rate"] = reserves.get("stress_rate", np.nan)
        audit_rows.extend(audit)
        bucket_shocks, audit = derive_treasury_bucket_shocks(
            groups["treasury_yields"],
            window,
            maturity_buckets,
            settings.maximum_asof_lookback_days,
        )
        audit_rows.extend(audit)
        row["maximum_absolute_treasury_shock_bp"] = (
            max(abs(value) for value in bucket_shocks.values()) if bucket_shocks else np.nan
        )
        row["treasury_bucket_count"] = len(bucket_shocks)
        for bucket, shock in bucket_shocks.items():
            bucket_rows.append(
                {
                    "scenario_id": window.scenario_id,
                    "maturity_bucket": bucket,
                    "observed_yield_shock_bp": shock,
                }
            )
        metric_rows.append(row)
    metrics = pd.DataFrame.from_records(metric_rows)
    for factor in RAW_SEVERITY_COLUMNS:
        if factor not in metrics.columns:
            metrics[factor] = np.nan
        numeric = pd.to_numeric(metrics[factor], errors="coerce")
        cap = float(settings.factor_caps[factor])
        normalized = numeric.clip(lower=0.0, upper=cap) / cap
        metrics[f"normalized_{factor}"] = normalized
    weighted_numerator = pd.Series(0.0, index=metrics.index)
    weighted_denominator = pd.Series(0.0, index=metrics.index)
    for factor, weight in settings.factor_weights.items():
        normalized = pd.to_numeric(metrics[f"normalized_{factor}"], errors="coerce")
        available = normalized.notna()
        weighted_numerator = weighted_numerator.add(normalized.fillna(0.0) * weight)
        weighted_denominator = weighted_denominator.add(available.astype(float) * weight)
    metrics["empirical_severity_score"] = np.where(
        weighted_denominator > 0.0,
        weighted_numerator / weighted_denominator,
        0.0,
    )
    metrics["empirical_severity_rank"] = (
        metrics["empirical_severity_score"].rank(method="first", ascending=True).astype(int) - 1
    )
    metrics["available_factor_count"] = metrics[list(RAW_SEVERITY_COLUMNS)].notna().sum(axis=1)
    metrics["calibration_status"] = np.where(
        metrics["available_factor_count"] == len(RAW_SEVERITY_COLUMNS),
        "COMPLETE",
        np.where(metrics["available_factor_count"] > 0, "PARTIAL", "UNAVAILABLE"),
    )
    return CalibrationOutput(
        scenario_metrics=metrics.sort_values("scenario_id", kind="stable").reset_index(drop=True),
        treasury_bucket_shocks=pd.DataFrame.from_records(bucket_rows)
        .sort_values(["scenario_id", "maturity_bucket"], kind="stable")
        .reset_index(drop=True),
        factor_observations=pd.DataFrame.from_records(audit_rows)
        .sort_values(["scenario_id", "factor_group", "statistic"], kind="stable")
        .reset_index(drop=True),
    )


def choose_component_scenario(
    component_frame: pd.DataFrame,
    empirical_severity_score: float,
) -> tuple[str, int]:
    """Choose the nearest validated component scenario by ordered severity rank."""
    required = {"scenario_name", "severity_rank"}
    missing = sorted(required - set(component_frame.columns))
    if missing:
        raise HistoricalScenarioError(f"Component output is missing fields: {missing}")
    options = (
        component_frame[["scenario_name", "severity_rank"]]
        .drop_duplicates()
        .sort_values("severity_rank", kind="stable")
        .reset_index(drop=True)
    )
    if options.empty:
        raise HistoricalScenarioError("Component output contains no scenarios.")
    score = min(1.0, max(0.0, float(empirical_severity_score)))
    index = round(score * (len(options) - 1))
    selected = options.iloc[index]
    return str(selected["scenario_name"]), int(selected["severity_rank"])


def build_historical_treasury_scenarios(
    bucket_shocks: pd.DataFrame,
) -> list[dict[str, Any]]:
    """Build Section 15 bucket-vector scenarios from observed H.15 changes."""
    required = {"scenario_id", "maturity_bucket", "observed_yield_shock_bp"}
    missing = sorted(required - set(bucket_shocks.columns))
    if missing:
        raise HistoricalScenarioError(f"Treasury bucket shocks are missing fields: {missing}")
    scenarios: list[dict[str, Any]] = []
    for scenario_id, group in bucket_shocks.groupby("scenario_id", sort=True):
        scenarios.append(
            {
                "name": str(scenario_id),
                "enabled": True,
                "type": "bucket_vector",
                "family": "historical_observed",
                "shocks_bp": {
                    str(row["maturity_bucket"]): float(row["observed_yield_shock_bp"])
                    for _, row in group.iterrows()
                },
            }
        )
    return scenarios


def build_single_historical_integrated_config(
    base_config: Mapping[str, Any],
    scenario_id: str,
    funding_scenario_name: str,
    haircut_scenario_name: str,
    settlement_scenario_name: str,
    template_severity_score: float,
    model_version: str,
) -> dict[str, Any]:
    """Create a one-scenario Section 19 config for an independent historical replay."""
    config = deepcopy(dict(base_config))
    raw_templates = config.get("scenarios")
    if not isinstance(raw_templates, list) or not raw_templates:
        raise HistoricalScenarioError("Section 19 scenarios must be a nonempty list.")
    templates = sorted(
        (_mapping(item, "integrated scenario") for item in raw_templates),
        key=lambda item: int(item["severity_rank"]),
    )
    score = min(1.0, max(0.0, float(template_severity_score)))
    template = templates[round(score * (len(templates) - 1))]
    config["model_version"] = model_version
    config["scenarios"] = [
        {
            "name": scenario_id,
            "enabled": True,
            "severity_rank": 0,
            "funding_scenario_name": funding_scenario_name,
            "haircut_scenario_name": haircut_scenario_name,
            "treasury_scenario_name": scenario_id,
            "settlement_fail_scenario_name": settlement_scenario_name,
            "concentration_threshold": float(template["concentration_threshold"]),
            "concentration_multiplier": float(template["concentration_multiplier"]),
            "operational_liquidity_buffer_rate": float(
                template["operational_liquidity_buffer_rate"]
            ),
        }
    ]
    return config
