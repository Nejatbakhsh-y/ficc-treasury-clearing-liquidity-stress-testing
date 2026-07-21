"""Objective historical stress-window calibration for Section 10.

Section 8 stores the processed Federal Reserve data in a canonical long-form
schema. This module selects controlled series groups, converts them into five
comparable empirical-percentile stress components, and clusters combined-score
tail observations into historical calibration windows.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import yaml

COMPONENT_COLUMNS: tuple[str, ...] = (
    "sofr_spike_score",
    "treasury_yield_shock_score",
    "settlement_fail_score",
    "financing_disruption_score",
    "reserve_contraction_score",
)

REQUIRED_LONG_COLUMNS: frozenset[str] = frozenset(
    {
        "observation_date",
        "alignment_frequency",
        "source_name",
        "source_series_id",
        "source_metric",
        "value",
        "standardized_unit",
        "metric_kind",
    }
)


@dataclass(frozen=True)
class CalibrationResult:
    """Controlled outputs returned by the calibration pipeline."""

    daily_scores: pd.DataFrame
    windows: pd.DataFrame
    mappings: dict[str, list[str]]
    threshold: float


def file_sha256(path: Path) -> str:
    """Return a SHA-256 digest for a controlled file."""

    digest = sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_table(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(path)
    if suffix == ".csv":
        return pd.read_csv(path, low_memory=False)
    raise ValueError(f"Unsupported analytical input format: {path}")


def _series_key(frame: pd.DataFrame) -> pd.Series:
    return (
        frame["source_name"].astype("string").str.upper()
        + "::"
        + frame["source_series_id"].astype("string")
        + "::"
        + frame["alignment_frequency"].astype("string").str.lower()
    )


def load_analytical_inputs(
    paths: Sequence[Path],
) -> tuple[pd.DataFrame, list[dict[str, Any]]]:
    """Read, validate, concatenate, and de-duplicate Section 8 long-form outputs."""

    frames: list[pd.DataFrame] = []
    lineage: list[dict[str, Any]] = []

    for path in paths:
        if not path.exists():
            continue
        frame = _read_table(path)
        missing = REQUIRED_LONG_COLUMNS.difference(frame.columns)
        if missing:
            raise ValueError(f"{path} is missing canonical columns: {sorted(missing)}")

        frame = frame.copy()
        frame["observation_date"] = pd.to_datetime(
            frame["observation_date"], errors="coerce"
        ).dt.normalize()
        frame["value"] = pd.to_numeric(frame["value"], errors="coerce")
        frame["source_name"] = frame["source_name"].astype("string").str.upper()
        frame["alignment_frequency"] = frame["alignment_frequency"].astype("string").str.lower()
        frame["source_series_id"] = frame["source_series_id"].astype("string")
        frame["source_metric"] = frame["source_metric"].astype("string")
        frame["standardized_unit"] = frame["standardized_unit"].astype("string").str.upper()
        frame["metric_kind"] = frame["metric_kind"].astype("string").str.lower()
        frame = frame.dropna(subset=["observation_date", "value"])
        frame["series_key"] = _series_key(frame)
        frame = frame.sort_values(
            [
                "observation_date",
                "alignment_frequency",
                "source_name",
                "source_series_id",
            ]
        ).drop_duplicates(
            [
                "observation_date",
                "alignment_frequency",
                "source_name",
                "source_series_id",
            ],
            keep="last",
        )
        frames.append(frame)

        source_counts = {
            str(key): int(value)
            for key, value in frame["source_name"].value_counts().sort_index().items()
        }
        lineage.append(
            {
                "path": path.as_posix(),
                "sha256": file_sha256(path),
                "rows": len(frame),
                "columns": len(frame.columns),
                "start_date": frame["observation_date"].min().date().isoformat(),
                "end_date": frame["observation_date"].max().date().isoformat(),
                "source_row_counts": source_counts,
            }
        )

    if not frames:
        raise FileNotFoundError(
            "No Section 8 processed inputs were found. Confirm both processed Parquet "
            "files exist before running Section 10."
        )

    combined = pd.concat(frames, ignore_index=True, sort=False)
    combined = combined.sort_values(
        [
            "observation_date",
            "alignment_frequency",
            "source_name",
            "source_series_id",
        ]
    ).reset_index(drop=True)
    return combined, lineage


def _text_field(frame: pd.DataFrame) -> pd.Series:
    return (
        frame["source_series_id"].fillna("").astype(str)
        + " "
        + frame["source_metric"].fillna("").astype(str)
    ).str.lower()


def _select_rule(frame: pd.DataFrame, rule: Mapping[str, Any]) -> pd.DataFrame:
    mask = pd.Series(True, index=frame.index)

    source_names = {str(item).upper() for item in rule.get("source_names", [])}
    if source_names:
        mask &= frame["source_name"].isin(source_names)

    frequency = str(rule.get("alignment_frequency", "")).lower().strip()
    if frequency:
        mask &= frame["alignment_frequency"].eq(frequency)

    units = {str(item).upper() for item in rule.get("standardized_units", [])}
    if units:
        mask &= frame["standardized_unit"].isin(units)

    kinds = {str(item).lower() for item in rule.get("metric_kinds", [])}
    if kinds:
        mask &= frame["metric_kind"].isin(kinds)

    if bool(rule.get("require_maturity", False)):
        if "maturity_months" not in frame.columns:
            mask &= False
        else:
            maturity = pd.to_numeric(frame["maturity_months"], errors="coerce")
            mask &= maturity.notna()

    exact_series = {str(item) for item in rule.get("exact_series_ids", [])}
    if exact_series:
        mask &= frame["source_series_id"].isin(exact_series)

    text = _text_field(frame)
    include_patterns = [str(item) for item in rule.get("include_patterns", [])]
    if include_patterns:
        include_mask = pd.Series(False, index=frame.index)
        for pattern in include_patterns:
            include_mask |= text.str.contains(pattern, regex=True, case=False, na=False)
        mask &= include_mask

    exclude_patterns = [str(item) for item in rule.get("exclude_patterns", [])]
    for pattern in exclude_patterns:
        mask &= ~text.str.contains(pattern, regex=True, case=False, na=False)

    selected = frame.loc[mask].copy()
    if "is_observed" in selected.columns and bool(rule.get("observed_only", False)):
        selected = selected.loc[selected["is_observed"].fillna(False).astype(bool)]
    return selected


def resolve_series_map(frame: pd.DataFrame, config: Mapping[str, Any]) -> dict[str, list[str]]:
    """Resolve controlled series groups from YAML rules and canonical metadata."""

    rules = config.get("series_rules", {})
    mappings: dict[str, list[str]] = {}
    for group in (
        "sofr",
        "treasury_yields",
        "settlement_fails",
        "financing_volume",
        "reserve_balances",
    ):
        selected = _select_rule(frame, rules.get(group, {}))
        mappings[group] = sorted(selected["series_key"].dropna().unique().tolist())
    return mappings


def _component_matrix(
    frame: pd.DataFrame,
    series_keys: Sequence[str],
    value_mode: str = "raw",
) -> pd.DataFrame:
    selected = frame.loc[frame["series_key"].isin(series_keys)].copy()
    if selected.empty:
        return pd.DataFrame()

    selected["component_value"] = selected["value"]
    if value_mode == "basis_points":
        percent_mask = selected["standardized_unit"].eq("PERCENT")
        selected.loc[percent_mask, "component_value"] *= 100.0

    matrix = selected.pivot_table(
        index="observation_date",
        columns="series_key",
        values="component_value",
        aggfunc="last",
    ).sort_index()
    return matrix


def _observed_diff(series: pd.Series) -> pd.Series:
    observed = pd.to_numeric(series, errors="coerce").dropna()
    return observed.diff().reindex(series.index)


def _observed_frame_diff(frame: pd.DataFrame) -> pd.DataFrame:
    return pd.DataFrame(
        {column: _observed_diff(frame[column]) for column in frame.columns},
        index=frame.index,
    )


def _percentile_score(signal: pd.Series) -> pd.Series:
    signal = pd.to_numeric(signal, errors="coerce").replace([np.inf, -np.inf], np.nan)
    if signal.notna().sum() < 3:
        return pd.Series(np.nan, index=signal.index, dtype=float)
    return signal.rank(method="average", pct=True).clip(lower=0.0, upper=1.0)


def _rolling_positive_deviation(series: pd.Series, window: int) -> pd.Series:
    observed = pd.to_numeric(series, errors="coerce").dropna()
    minimum = max(5, window // 4)
    centre = observed.rolling(window=window, min_periods=minimum).median()
    absolute_deviation = (observed - centre).abs()
    scale = absolute_deviation.rolling(window=window, min_periods=minimum).median()
    robust_z = (observed - centre) / (1.4826 * scale.replace(0.0, np.nan))
    return robust_z.clip(lower=0.0).reindex(series.index)


def _max_score(index: pd.Index, *scores: pd.Series) -> pd.Series:
    valid = [score for score in scores if score.notna().any()]
    if not valid:
        return pd.Series(np.nan, index=index, dtype=float)
    return pd.concat(valid, axis=1).max(axis=1, skipna=True).reindex(index)


def _aggregate_matrix(matrix: pd.DataFrame, method: str) -> pd.Series:
    if matrix.empty:
        return pd.Series(dtype=float)
    if method == "mean":
        return matrix.mean(axis=1, skipna=True)
    if method == "absolute_sum":
        return matrix.abs().sum(axis=1, min_count=1)
    return matrix.sum(axis=1, min_count=1)


def build_component_scores(
    frame: pd.DataFrame,
    mappings: Mapping[str, Sequence[str]],
    rolling_window: int = 60,
) -> pd.DataFrame:
    """Build five stress channels on a common zero-to-one percentile scale."""

    date_index = pd.DatetimeIndex(sorted(frame["observation_date"].dropna().unique()))
    output = pd.DataFrame(index=date_index)
    output.index.name = "observation_date"

    sofr_matrix = _component_matrix(frame, mappings.get("sofr", []))
    sofr = _aggregate_matrix(sofr_matrix, "mean").reindex(date_index)
    sofr_change = _observed_diff(sofr).clip(lower=0.0)
    sofr_deviation = _rolling_positive_deviation(sofr, rolling_window)
    output["sofr_spike_score"] = _max_score(
        date_index,
        _percentile_score(sofr_change),
        _percentile_score(sofr_deviation),
    )

    yield_matrix = _component_matrix(
        frame, mappings.get("treasury_yields", []), value_mode="basis_points"
    )
    if yield_matrix.empty:
        maximum_yield_change = pd.Series(np.nan, index=date_index, dtype=float)
    else:
        maximum_yield_change = (
            _observed_frame_diff(yield_matrix).abs().max(axis=1, skipna=True).reindex(date_index)
        )
    output["treasury_yield_shock_score"] = _percentile_score(maximum_yield_change)

    fails_matrix = _component_matrix(frame, mappings.get("settlement_fails", []))
    fails = _aggregate_matrix(fails_matrix, "absolute_sum").reindex(date_index)
    logged_fails = np.log1p(fails.clip(lower=0.0))
    fails_level = _rolling_positive_deviation(logged_fails, rolling_window)
    fails_increase = _observed_diff(logged_fails).clip(lower=0.0)
    output["settlement_fail_score"] = _max_score(
        date_index,
        _percentile_score(fails_level),
        _percentile_score(fails_increase),
    )

    financing_matrix = _component_matrix(frame, mappings.get("financing_volume", []))
    financing = _aggregate_matrix(financing_matrix, "absolute_sum").reindex(date_index)
    financing_log_change = _observed_diff(np.log(financing.where(financing > 0.0)))
    financing_disruption = pd.concat(
        [financing_log_change.abs(), (-financing_log_change).clip(lower=0.0)], axis=1
    ).max(axis=1, skipna=True)
    output["financing_disruption_score"] = _percentile_score(financing_disruption)

    reserve_matrix = _component_matrix(frame, mappings.get("reserve_balances", []))
    reserves = _aggregate_matrix(reserve_matrix, "sum").reindex(date_index)
    reserve_log_change = _observed_diff(np.log(reserves.where(reserves > 0.0)))
    reserve_contraction = (-reserve_log_change).clip(lower=0.0)
    output["reserve_contraction_score"] = _percentile_score(reserve_contraction)

    return output.reset_index()


def combine_components(
    scores: pd.DataFrame,
    weights: Mapping[str, float],
    minimum_components: int,
) -> pd.DataFrame:
    """Calculate a weighted combined score without imputing missing channels."""

    output = scores.copy()
    component_values = output[list(COMPONENT_COLUMNS)].apply(pd.to_numeric, errors="coerce")
    weight_vector = pd.Series(
        {column: float(weights.get(column, 1.0)) for column in COMPONENT_COLUMNS},
        dtype=float,
    )
    weighted_values = component_values.mul(weight_vector, axis=1)
    available_weights = component_values.notna().mul(weight_vector, axis=1).sum(axis=1)
    output["available_component_count"] = component_values.notna().sum(axis=1)
    output["combined_stress_score"] = weighted_values.sum(axis=1, min_count=1) / available_weights
    output.loc[
        output["available_component_count"] < int(minimum_components),
        "combined_stress_score",
    ] = np.nan
    return output


def _anchor_match(
    start_date: pd.Timestamp,
    end_date: pd.Timestamp,
    anchors: Sequence[Mapping[str, Any]],
) -> tuple[str, str]:
    matches: list[tuple[str, str]] = []
    for anchor in anchors:
        anchor_start = pd.Timestamp(anchor["start_date"])
        anchor_end = pd.Timestamp(anchor["end_date"])
        if start_date <= anchor_end and end_date >= anchor_start:
            matches.append((str(anchor["id"]), str(anchor["name"])))
    if not matches:
        return "", ""
    return ";".join(item[0] for item in matches), ";".join(item[1] for item in matches)


def identify_windows(
    daily_scores: pd.DataFrame,
    quantile: float,
    merge_gap_days: int,
    pre_window_days: int,
    post_window_days: int,
    minimum_exceedance_days: int,
    maximum_windows: int,
    anchors: Sequence[Mapping[str, Any]],
) -> tuple[pd.DataFrame, float]:
    """Cluster tail observations into controlled historical stress windows."""

    scores = daily_scores.copy().sort_values("observation_date").reset_index(drop=True)
    valid = scores["combined_stress_score"].dropna()
    if len(valid) < 10:
        raise ValueError("At least ten combined-score observations are required for calibration.")

    threshold = float(valid.quantile(float(quantile)))
    tail = scores.loc[scores["combined_stress_score"] >= threshold].copy()
    if tail.empty:
        raise ValueError("No observations met the configured combined-score threshold.")

    tail["cluster_break"] = tail["observation_date"].diff().dt.days.fillna(0) > int(merge_gap_days)
    tail["cluster_id"] = tail["cluster_break"].cumsum()

    coverage_start = scores["observation_date"].min()
    coverage_end = scores["observation_date"].max()
    records: list[dict[str, Any]] = []

    for _, exceedances in tail.groupby("cluster_id", sort=True):
        if len(exceedances) < int(minimum_exceedance_days):
            continue

        core_start = exceedances["observation_date"].min()
        core_end = exceedances["observation_date"].max()
        start_date = max(coverage_start, core_start - pd.Timedelta(days=int(pre_window_days)))
        end_date = min(coverage_end, core_end + pd.Timedelta(days=int(post_window_days)))
        window = scores.loc[
            scores["observation_date"].between(start_date, end_date, inclusive="both")
        ].copy()
        peak_index = window["combined_stress_score"].idxmax()
        peak_row = cast(pd.Series, window.loc[peak_index])

        trigger_components = [
            column
            for column in COMPONENT_COLUMNS
            if pd.notna(peak_row[column]) and float(peak_row[column]) >= float(quantile)
        ]
        if not trigger_components:
            component_slice = peak_row.loc[list(COMPONENT_COLUMNS)]
            ranked = component_slice.dropna().sort_values(ascending=False)
            trigger_components = [str(column) for column in ranked.head(2).index]

        anchor_ids, anchor_names = _anchor_match(start_date, end_date, anchors)
        record: dict[str, Any] = {
            "scenario_name": anchor_names or "Empirical tail window",
            "start_date": start_date.date().isoformat(),
            "peak_date": pd.Timestamp(peak_row["observation_date"]).date().isoformat(),
            "end_date": end_date.date().isoformat(),
            "core_start_date": core_start.date().isoformat(),
            "core_end_date": core_end.date().isoformat(),
            "exceedance_days": len(exceedances),
            "observations": len(window),
            "peak_combined_score": float(peak_row["combined_stress_score"]),
            "mean_combined_score": float(window["combined_stress_score"].mean()),
            "threshold": threshold,
            "component_count_at_peak": int(peak_row["available_component_count"]),
            "trigger_components": ";".join(trigger_components),
            "anchor_match": anchor_ids,
            "selection_method": "combined-score empirical quantile exceedance",
            "data_coverage_start": coverage_start.date().isoformat(),
            "data_coverage_end": coverage_end.date().isoformat(),
        }
        for column in COMPONENT_COLUMNS:
            record[f"peak_{column}"] = (
                float(window[column].max()) if window[column].notna().any() else np.nan
            )
        records.append(record)

    if not records:
        raise ValueError("No windows survived the configured minimum-exceedance rule.")

    windows = pd.DataFrame(records)
    windows = windows.sort_values(
        ["peak_combined_score", "mean_combined_score", "start_date"],
        ascending=[False, False, True],
    ).head(int(maximum_windows))
    windows = windows.sort_values("start_date").reset_index(drop=True)
    windows.insert(0, "window_id", [f"HIST_{index:03d}" for index in range(1, len(windows) + 1)])
    return windows, threshold


def calibrate_historical_windows(
    analytical_frame: pd.DataFrame,
    config: Mapping[str, Any],
) -> CalibrationResult:
    """Run the complete long-form historical calibration."""

    methodology = config.get("methodology", {})
    mappings = resolve_series_map(analytical_frame, config)
    missing_groups = [group for group, columns in mappings.items() if not columns]
    if methodology.get("require_all_series_groups", True) and missing_groups:
        raise ValueError(
            "Required stress-series groups were not resolved: "
            + ", ".join(missing_groups)
            + ". Review series_rules in configs/historical_scenarios.yaml."
        )

    component_scores = build_component_scores(
        analytical_frame,
        mappings,
        rolling_window=int(methodology.get("rolling_window_observations", 60)),
    )
    daily_scores = combine_components(
        component_scores,
        weights=methodology.get("component_weights", {}),
        minimum_components=int(methodology.get("minimum_available_components", 2)),
    )
    windows, threshold = identify_windows(
        daily_scores=daily_scores,
        quantile=float(methodology.get("tail_quantile", 0.95)),
        merge_gap_days=int(methodology.get("merge_gap_days", 7)),
        pre_window_days=int(methodology.get("pre_window_days", 3)),
        post_window_days=int(methodology.get("post_window_days", 3)),
        minimum_exceedance_days=int(methodology.get("minimum_exceedance_days", 1)),
        maximum_windows=int(methodology.get("maximum_windows", 12)),
        anchors=config.get("candidate_anchors", []),
    )
    return CalibrationResult(daily_scores, windows, mappings, threshold)


def load_config(path: Path) -> dict[str, Any]:
    """Read and minimally validate the historical-scenario YAML file."""

    with path.open("r", encoding="utf-8") as handle:
        config = yaml.safe_load(handle) or {}
    if "methodology" not in config or "series_rules" not in config:
        raise ValueError(
            "historical_scenarios.yaml must contain methodology and series_rules sections."
        )
    return dict(config)


def update_selected_scenarios(
    config_path: Path,
    config: Mapping[str, Any],
    windows: pd.DataFrame,
) -> None:
    """Write calibrated windows back to YAML as controlled scenario definitions."""

    updated = dict(config)
    scenarios: list[dict[str, Any]] = []
    for record in windows.to_dict(orient="records"):
        scenarios.append(
            {
                "id": record["window_id"],
                "name": record["scenario_name"],
                "start_date": record["start_date"],
                "peak_date": record["peak_date"],
                "end_date": record["end_date"],
                "anchor_match": record["anchor_match"] or None,
                "selection": {
                    "peak_combined_score": round(float(record["peak_combined_score"]), 6),
                    "mean_combined_score": round(float(record["mean_combined_score"]), 6),
                    "threshold": round(float(record["threshold"]), 6),
                    "trigger_components": [
                        item for item in str(record["trigger_components"]).split(";") if item
                    ],
                },
            }
        )
    updated["selected_scenarios"] = scenarios
    with config_path.open("w", encoding="utf-8", newline="\n") as handle:
        yaml.safe_dump(updated, handle, sort_keys=False, allow_unicode=True)
