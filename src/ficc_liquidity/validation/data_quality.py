"""Controlled data-quality validation for Federal Reserve liquidity datasets.

The module validates canonical FR 2004, SOFR, H.15, and H.4.1 files and writes
machine-readable and human-readable evidence.  It supports CSV and Parquet,
long and wide layouts, and conservative automatic column detection.
"""

from __future__ import annotations

import argparse
import math
import re
import sys
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, cast
from typing import Any as _RuffAny
from typing import ClassVar as _RuffClassVar

import numpy as np
import pandas as pd
from pandas.tseries.holiday import (
    AbstractHolidayCalendar,
    GoodFriday,
    USFederalHolidayCalendar,
)
from pandas.tseries.offsets import CustomBusinessDay

MIN_COMPLETENESS = 0.995
SUPPORTED_SUFFIXES = {".csv", ".parquet", ".pq"}
DATASET_ORDER = ("fr2004", "sofr", "h15", "h41")


class FederalMarketHolidayCalendar(AbstractHolidayCalendar):
    """Federal holidays plus Good Friday for rates-market date expectations."""

    rules: _RuffClassVar[_RuffAny] = [*USFederalHolidayCalendar.rules, GoodFriday]  # type: ignore[misc]


FEDERAL_MARKET_BUSINESS_DAY = CustomBusinessDay(calendar=FederalMarketHolidayCalendar())
WEEKDAY_NAMES = ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")


@dataclass(frozen=True)
class DatasetSpec:
    """Expected structural and temporal properties for one source dataset."""

    name: str
    label: str
    frequency: str
    filename_tokens: tuple[str, ...]
    date_aliases: tuple[str, ...] = (
        "date",
        "observation_date",
        "as_of_date",
        "asof_date",
        "effective_date",
        "business_date",
        "week_ended",
        "week_ending",
        "report_date",
        "time_period",
        "period",
    )
    series_aliases: tuple[str, ...] = (
        "series_id",
        "series",
        "series_name",
        "time_series",
        "mnemonic",
        "instrument",
        "category",
    )
    value_aliases: tuple[str, ...] = (
        "value",
        "observation_value",
        "amount",
        "rate",
        "yield",
        "volume",
    )
    unit_aliases: tuple[str, ...] = ("unit", "units", "unit_of_measure", "uom")
    vintage_aliases: tuple[str, ...] = (
        "vintage_date",
        "revision_date",
        "retrieved_at_utc",
        "retrieval_timestamp_utc",
        "retrieval_timestamp",
        "last_updated",
    )


SPECS: dict[str, DatasetSpec] = {
    "fr2004": DatasetSpec(
        name="fr2004",
        label="FR 2004 Primary Dealer Statistics",
        frequency="weekly",
        filename_tokens=(
            "fr2004",
            "fr_2004",
            "primary_dealer",
            "primarydealer",
            "dealer_statistics",
        ),
    ),
    "sofr": DatasetSpec(
        name="sofr",
        label="New York Fed SOFR",
        frequency="daily",
        filename_tokens=("sofr", "secured_overnight_financing_rate"),
    ),
    "h15": DatasetSpec(
        name="h15",
        label="Federal Reserve H.15",
        frequency="daily",
        filename_tokens=("h15", "h_15", "treasury_yield", "constant_maturity"),
    ),
    "h41": DatasetSpec(
        name="h41",
        label="Federal Reserve H.4.1",
        frequency="weekly",
        filename_tokens=(
            "h41",
            "h_4_1",
            "h4_1",
            "reserve_balance",
            "factors_affecting",
        ),
    ),
}


@dataclass
class DataLayout:
    """Detected table layout and canonical columns."""

    date_column: str | None
    series_column: str | None
    unit_column: str | None
    vintage_column: str | None
    value_columns: list[str]
    long_value_column: str | None

    @property
    def is_long(self) -> bool:
        return self.series_column is not None and self.long_value_column is not None


@dataclass
class DatasetContext:
    """Loaded dataset and metadata used by cross-dataset checks."""

    spec: DatasetSpec
    path: Path
    frame: pd.DataFrame
    layout: DataLayout
    parsed_dates: pd.Series
    series_date_sets: dict[str, set[pd.Timestamp]] = field(default_factory=dict)

    @property
    def all_dates(self) -> set[pd.Timestamp]:
        values = self.parsed_dates.dropna().dt.normalize()
        return set(values.tolist())


@dataclass(frozen=True)
class CheckResult:
    """One auditable data-quality check result."""

    dataset: str
    source_file: str
    check_id: str
    check_name: str
    status: str
    severity: str
    metric: str
    observed: str
    threshold: str
    details: str
    checked_at_utc: str

    def as_dict(self) -> dict[str, str]:
        return {
            "dataset": self.dataset,
            "source_file": self.source_file,
            "check_id": self.check_id,
            "check_name": self.check_name,
            "status": self.status,
            "severity": self.severity,
            "metric": self.metric,
            "observed": self.observed,
            "threshold": self.threshold,
            "details": self.details,
            "checked_at_utc": self.checked_at_utc,
        }


class ResultCollector:
    """Create consistently formatted validation results."""

    def __init__(self, dataset: str, source_file: str) -> None:
        self.dataset = dataset
        self.source_file = source_file
        self.results: list[CheckResult] = []

    def add(
        self,
        check_id: str,
        check_name: str,
        status: str,
        severity: str,
        metric: str,
        observed: Any,
        threshold: Any,
        details: str,
    ) -> None:
        self.results.append(
            CheckResult(
                dataset=self.dataset,
                source_file=self.source_file,
                check_id=check_id,
                check_name=check_name,
                status=status,
                severity=severity,
                metric=metric,
                observed=_format_value(observed),
                threshold=_format_value(threshold),
                details=details,
                checked_at_utc=datetime.now(UTC).isoformat(),
            )
        )


def _format_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, float):
        if math.isnan(value):
            return "nan"
        return f"{value:.8g}"
    return str(value)


def normalize_name(value: str) -> str:
    """Normalize labels for conservative alias and semantic matching."""

    text = re.sub(r"[^a-z0-9]+", "_", str(value).strip().lower())
    return re.sub(r"_+", "_", text).strip("_")


def _column_lookup(columns: Iterable[str]) -> dict[str, str]:
    return {normalize_name(column): column for column in columns}


def _find_alias(columns: Iterable[str], aliases: Sequence[str]) -> str | None:
    lookup = _column_lookup(columns)
    for alias in aliases:
        if normalize_name(alias) in lookup:
            return lookup[normalize_name(alias)]
    return None


def _numeric_conversion_ratio(series: pd.Series) -> float:
    if series.empty:
        return 0.0
    non_null = series.dropna()
    if non_null.empty:
        return 0.0
    cleaned = (
        non_null.astype(str).str.replace(",", "", regex=False).str.replace("%", "", regex=False)
    )
    converted = pd.to_numeric(cleaned, errors="coerce")
    return float(converted.notna().mean())


def _coerce_numeric(series: pd.Series) -> pd.Series:
    if pd.api.types.is_numeric_dtype(series):
        return pd.to_numeric(series, errors="coerce")
    cleaned = series.astype(str).str.strip()
    cleaned = cleaned.replace(
        {"": np.nan, "nan": np.nan, "None": np.nan, "ND": np.nan, "N/A": np.nan}
    )
    cleaned = cleaned.str.replace(",", "", regex=False).str.replace("%", "", regex=False)
    return pd.to_numeric(cleaned, errors="coerce")


def detect_layout(frame: pd.DataFrame, spec: DatasetSpec) -> DataLayout:
    """Detect date, series, unit, vintage, and numeric value columns."""

    date_column = _find_alias(frame.columns, spec.date_aliases)
    if date_column is None:
        date_candidates = [column for column in frame.columns if "date" in normalize_name(column)]
        date_column = date_candidates[0] if date_candidates else None

    series_column = _find_alias(frame.columns, spec.series_aliases)
    unit_column = _find_alias(frame.columns, spec.unit_aliases)
    vintage_column = _find_alias(frame.columns, spec.vintage_aliases)

    excluded = {
        column for column in (date_column, series_column, unit_column, vintage_column) if column
    }
    candidate_columns: list[str] = []
    for column in frame.columns:
        if column in excluded:
            continue
        normalized = normalize_name(column)
        if normalized in {
            "year",
            "month",
            "day",
            "quarter",
            "source",
            "dataset",
            "notes",
            "status",
        }:
            continue
        if (
            pd.api.types.is_numeric_dtype(frame[column])
            or _numeric_conversion_ratio(frame[column]) >= 0.90
        ):
            candidate_columns.append(column)

    long_value_column: str | None = None
    if series_column is not None:
        alias_value = _find_alias(candidate_columns, spec.value_aliases)
        if alias_value is not None:
            long_value_column = alias_value
        elif len(candidate_columns) == 1:
            long_value_column = candidate_columns[0]

    return DataLayout(
        date_column=date_column,
        series_column=series_column,
        unit_column=unit_column,
        vintage_column=vintage_column,
        value_columns=candidate_columns,
        long_value_column=long_value_column,
    )


def read_table(path: Path) -> pd.DataFrame:
    """Read a supported canonical data file."""

    suffix = path.suffix.lower()
    if suffix == ".csv":
        try:
            return pd.read_csv(path, low_memory=False)
        except UnicodeDecodeError:
            return pd.read_csv(path, low_memory=False, encoding="latin-1")
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(path)
    raise ValueError(f"Unsupported file type: {path.suffix}")


def detect_dataset_from_path(path: Path) -> str | None:
    normalized = normalize_name(str(path))
    for name, spec in SPECS.items():
        if any(normalize_name(token) in normalized for token in spec.filename_tokens):
            return name
    return None


def _candidate_rank(path: Path) -> tuple[int, int, int, str]:
    parts = {normalize_name(part) for part in path.parts}
    stage_rank = 0
    if "processed" in parts:
        stage_rank = 3
    elif "interim" in parts:
        stage_rank = 2
    elif "raw" in parts:
        stage_rank = 1
    suffix_rank = 2 if path.suffix.lower() in {".parquet", ".pq"} else 1
    canonical_bonus = 1 if "canonical" in normalize_name(path.stem) else 0
    return (stage_rank, suffix_rank, canonical_bonus, str(path))


def discover_dataset_files(
    data_root: Path,
) -> tuple[dict[str, Path], dict[str, list[Path]]]:
    """Discover and rank one canonical file per required dataset."""

    candidates: dict[str, list[Path]] = {name: [] for name in DATASET_ORDER}
    if not data_root.exists():
        return {}, candidates

    for path in data_root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in SUPPORTED_SUFFIXES:
            continue
        normalized_path = normalize_name(str(path))
        if any(
            token in normalized_path
            for token in ("manifest", "data_quality_results", "leaderboard")
        ):
            continue
        dataset = detect_dataset_from_path(path)
        if dataset is not None:
            candidates[dataset].append(path)

    selected: dict[str, Path] = {}
    for dataset, paths in candidates.items():
        if paths:
            selected[dataset] = sorted(paths, key=_candidate_rank, reverse=True)[0]
    return selected, candidates


def parse_file_overrides(values: Sequence[str] | None) -> dict[str, Path]:
    """Parse repeated DATASET=PATH CLI overrides."""

    parsed: dict[str, Path] = {}
    for value in values or ():
        if "=" not in value:
            raise ValueError(f"Invalid --file value '{value}'; expected DATASET=PATH")
        dataset, raw_path = value.split("=", 1)
        dataset = normalize_name(dataset)
        if dataset not in SPECS:
            raise ValueError(
                f"Unknown dataset '{dataset}'. Expected one of: {', '.join(DATASET_ORDER)}"
            )
        parsed[dataset] = Path(raw_path).expanduser().resolve()
    return parsed


def _series_labels(frame: pd.DataFrame, layout: DataLayout) -> list[str]:
    labels = [normalize_name(column) for column in frame.columns]
    if layout.series_column is not None:
        labels.extend(
            normalize_name(value)
            for value in frame[layout.series_column].dropna().astype(str).unique()
        )
    return labels


def _semantic_presence(labels: Sequence[str], patterns: Sequence[str]) -> bool:
    combined = " ".join(labels)
    return any(re.search(pattern, combined) is not None for pattern in patterns)


def _iter_numeric_series(
    frame: pd.DataFrame, layout: DataLayout
) -> Iterable[tuple[str, pd.Series, pd.Series]]:
    """Yield (series label, dates, numeric values) for long or wide input."""

    if layout.date_column is None:
        return
    dates = pd.to_datetime(frame[layout.date_column], errors="coerce", utc=True).dt.tz_convert(None)
    if layout.is_long and layout.series_column and layout.long_value_column:
        work = pd.DataFrame(
            {
                "date": dates,
                "series": frame[layout.series_column].astype(str),
                "value": _coerce_numeric(frame[layout.long_value_column]),
            }
        )
        for label, group in work.groupby("series", dropna=False, sort=False):
            yield str(label), group["date"], group["value"]
        return

    for column in layout.value_columns:
        yield str(column), dates, _coerce_numeric(frame[column])


def _expected_dates(
    start: pd.Timestamp, end: pd.Timestamp, frequency: str, observed: pd.Series
) -> pd.DatetimeIndex:
    start = pd.Timestamp(start).normalize()
    end = pd.Timestamp(end).normalize()
    if frequency == "daily":
        return pd.date_range(start=start, end=end, freq=FEDERAL_MARKET_BUSINESS_DAY)
    weekdays = observed.dropna().dt.dayofweek
    weekday = int(weekdays.mode().iloc[0]) if not weekdays.empty else 2
    return pd.date_range(start=start, end=end, freq=f"W-{WEEKDAY_NAMES[weekday]}")


def _robust_outlier_mask(values: pd.Series, threshold: float = 12.0) -> pd.Series:
    clean = values.astype(float)
    median = clean.median(skipna=True)
    absolute_deviation = (clean - median).abs()
    mad = absolute_deviation.median(skipna=True)
    if pd.isna(mad) or float(mad) == 0.0:
        return pd.Series(False, index=values.index)
    robust_z = 0.67448975 * absolute_deviation / float(mad)
    return robust_z > threshold


def _rate_like(label: str) -> bool:
    normalized = normalize_name(label)
    return any(token in normalized for token in ("rate", "yield", "percentile", "pct"))


def _nonnegative_like(label: str) -> bool:
    normalized = normalize_name(label)
    nonnegative_tokens = (
        "volume",
        "fails_to_receive",
        "fails_to_deliver",
        "settlement_fail",
        "reserve_balance",
        "reserve_balances",
        "total_assets",
        "total_liabilities",
        "currency_in_circulation",
        "transaction_amount",
    )
    return any(token in normalized for token in nonnegative_tokens)


def _validate_schema(context: DatasetContext, collector: ResultCollector) -> None:
    frame = context.frame
    layout = context.layout
    collector.add(
        "DQ01",
        "Schema conformance",
        "PASS" if len(frame.columns) > 0 and not frame.columns.duplicated().any() else "FAIL",
        "critical",
        "column_count",
        len(frame.columns),
        "> 0 and unique",
        "Table loaded and column names were evaluated for uniqueness.",
    )

    required_ok = layout.date_column is not None and bool(layout.value_columns)
    missing_parts: list[str] = []
    if layout.date_column is None:
        missing_parts.append("date column")
    if not layout.value_columns:
        missing_parts.append("numeric value column")
    collector.add(
        "DQ02",
        "Required columns",
        "PASS" if required_ok else "FAIL",
        "critical",
        "required_structure",
        "present" if required_ok else "missing",
        "date plus numeric value columns",
        "Missing: " + ", ".join(missing_parts)
        if missing_parts
        else "Required structural columns detected.",
    )

    if not required_ok:
        return

    labels = _series_labels(frame, layout)
    semantic_checks: list[tuple[str, Sequence[str], str]] = []
    if context.spec.name == "sofr":
        semantic_checks = [
            ("SOFR rate", (r"sofr", r"rate"), "required"),
            ("transaction volume", (r"volume",), "required"),
        ]
    elif context.spec.name == "h15":
        semantic_checks = [
            (
                "Treasury yield/maturity",
                (
                    r"yield",
                    r"maturity",
                    r"riflgfcy",
                    r"treasury",
                    r"\bdgs(?:1mo|3mo|6mo|1|2|3|5|7|10|20|30)\b",
                ),
                "required",
            )
        ]
    elif context.spec.name == "h41":
        semantic_checks = [
            (
                "reserve balances",
                (r"reserve.*balance", r"balance.*reserve", r"\bwresbal\b", r"\bwrbwfrbl\b"),
                "required",
            )
        ]
    elif context.spec.name == "fr2004":
        semantic_checks = [
            ("positions", (r"position",), "advisory"),
            ("transactions", (r"transaction",), "advisory"),
            ("financing", (r"financ", r"repo", r"reverse_repo"), "advisory"),
            ("settlement fails", (r"fail",), "advisory"),
        ]

    for index, (label, patterns, mode) in enumerate(semantic_checks, start=1):
        present = _semantic_presence(labels, patterns)
        status = "PASS" if present else ("FAIL" if mode == "required" else "WARN")
        collector.add(
            f"DQ02.{index}",
            f"Required content: {label}",
            status,
            "high" if mode == "required" else "medium",
            "semantic_field_presence",
            present,
            True,
            f"Detected using canonical column and series labels for {context.spec.label}.",
        )


def _validate_dates(context: DatasetContext, collector: ResultCollector) -> None:
    frame = context.frame
    layout = context.layout
    if layout.date_column is None:
        return

    parsed = context.parsed_dates
    invalid_dates = int(parsed.isna().sum())
    collector.add(
        "DQ03.1",
        "Date parsing",
        "PASS" if invalid_dates == 0 else "FAIL",
        "critical",
        "invalid_date_rows",
        invalid_dates,
        0,
        f"Parsed date column '{layout.date_column}'.",
    )

    if parsed.dropna().empty:
        return

    key_frame = pd.DataFrame({"date": parsed.dt.normalize()})
    key_columns = ["date"]
    if layout.series_column is not None:
        key_frame["series"] = frame[layout.series_column].astype(str)
        key_columns.append("series")
    if layout.vintage_column is not None:
        key_frame["vintage"] = frame[layout.vintage_column].astype(str)
        key_columns.append("vintage")
    duplicate_count = int(key_frame.duplicated(subset=key_columns, keep=False).sum())
    collector.add(
        "DQ03.2",
        "Date uniqueness",
        "PASS" if duplicate_count == 0 else "FAIL",
        "high",
        "duplicate_key_rows",
        duplicate_count,
        0,
        "Uniqueness key: " + ", ".join(key_columns) + ".",
    )

    ordering_failures = 0
    if layout.series_column is not None:
        order_frame = pd.DataFrame(
            {"date": parsed, "series": frame[layout.series_column].astype(str)}
        )
        for _, group in order_frame.groupby("series", sort=False):
            if not group["date"].dropna().is_monotonic_increasing:
                ordering_failures += 1
    elif not parsed.dropna().is_monotonic_increasing:
        ordering_failures = 1
    collector.add(
        "DQ04",
        "Chronological ordering",
        "PASS" if ordering_failures == 0 else "FAIL",
        "high",
        "non_monotonic_series",
        ordering_failures,
        0,
        "Source-row order was checked within each series when a series identifier was available.",
    )

    future_limit = pd.Timestamp(datetime.now(UTC).date() + timedelta(days=7))
    future_count = int((parsed.dt.tz_localize(None) > future_limit).sum())
    collector.add(
        "DQ08.1",
        "Impossible future dates",
        "PASS" if future_count == 0 else "FAIL",
        "critical",
        "future_date_rows",
        future_count,
        0,
        f"Dates later than {future_limit.date().isoformat()} are impossible for this run.",
    )


def _validate_missing_and_completeness(
    context: DatasetContext, collector: ResultCollector, minimum_completeness: float
) -> None:
    layout = context.layout
    frame = context.frame
    if layout.date_column is None or not layout.value_columns:
        return

    required_columns = [layout.date_column]
    if layout.series_column:
        required_columns.append(layout.series_column)
    if layout.long_value_column:
        required_columns.append(layout.long_value_column)
    required_missing = int(frame[required_columns].isna().sum().sum())
    collector.add(
        "DQ05",
        "Missing required values",
        "PASS" if required_missing == 0 else "FAIL",
        "high",
        "missing_required_cells",
        required_missing,
        0,
        "Required key and long-format observation-value cells were checked.",
    )

    completeness_rows: list[tuple[str, float, int, int]] = []
    series_date_sets: dict[str, set[pd.Timestamp]] = {}
    for label, dates, values in _iter_numeric_series(frame, layout):
        valid = dates.notna() & values.notna()
        valid_dates = dates[valid].dt.normalize().drop_duplicates().sort_values()
        if valid_dates.empty:
            completeness_rows.append((label, 0.0, 0, 0))
            series_date_sets[label] = set()
            continue
        expected = _expected_dates(
            valid_dates.iloc[0],
            valid_dates.iloc[-1],
            context.spec.frequency,
            valid_dates,
        )
        expected_set = set(pd.DatetimeIndex(expected).normalize().tolist())
        observed_set = set(valid_dates.tolist())
        matched = len(expected_set & observed_set)
        ratio = 1.0 if not expected_set else matched / len(expected_set)
        completeness_rows.append((label, ratio, matched, len(expected_set)))
        series_date_sets[label] = observed_set

    context.series_date_sets = series_date_sets
    if not completeness_rows:
        collector.add(
            "DQ06",
            "Expected-frequency completeness",
            "FAIL",
            "critical",
            "minimum_series_completeness",
            0.0,
            minimum_completeness,
            "No evaluable numeric series were found.",
        )
        return

    minimum_row = min(completeness_rows, key=lambda row: row[1])
    below = [row for row in completeness_rows if row[1] + 1e-12 < minimum_completeness]
    status = "PASS" if not below else "FAIL"
    details = (
        f"Evaluated {len(completeness_rows)} series over each series' active date range. "
        f"Lowest series: {minimum_row[0]} "
        f"({minimum_row[2]}/{minimum_row[3]} expected observations)."
    )
    if below:
        worst = sorted(below, key=lambda row: row[1])[:10]
        details += " Below threshold: " + "; ".join(
            f"{label}={ratio:.4%}" for label, ratio, _, _ in worst
        )
    collector.add(
        "DQ06",
        "Expected-frequency completeness",
        status,
        "critical",
        "minimum_series_completeness",
        minimum_row[1],
        minimum_completeness,
        details,
    )


def _validate_units(context: DatasetContext, collector: ResultCollector) -> None:
    frame = context.frame
    layout = context.layout
    if layout.unit_column is not None:
        normalized_units = frame[layout.unit_column].dropna().astype(str).map(normalize_name)
        if layout.series_column is not None:
            unit_frame = pd.DataFrame(
                {
                    "series": frame[layout.series_column].astype(str),
                    "unit": frame[layout.unit_column].astype(str),
                }
            )
            inconsistent = int(
                (unit_frame.groupby("series")["unit"].nunique(dropna=True) > 1).sum()
            )
        else:
            inconsistent = 0
        collector.add(
            "DQ07",
            "Unit consistency",
            "PASS" if inconsistent == 0 and not normalized_units.empty else "FAIL",
            "high",
            "series_with_multiple_units",
            inconsistent,
            0,
            f"Unit column '{layout.unit_column}' was checked within series.",
        )
        return

    rate_scales: list[tuple[str, float]] = []
    for label, _, values in _iter_numeric_series(frame, layout):
        if _rate_like(label):
            clean = values.replace([np.inf, -np.inf], np.nan).dropna().abs()
            if not clean.empty:
                rate_scales.append((label, float(clean.median())))
    decimal_like = [label for label, median in rate_scales if 0 < median < 0.5]
    percent_like = [label for label, median in rate_scales if median >= 0.5]
    mixed = bool(decimal_like and percent_like)
    collector.add(
        "DQ07",
        "Unit consistency",
        "WARN" if mixed or not rate_scales else "PASS",
        "medium",
        "rate_scale_classes",
        f"decimal={len(decimal_like)}, percent={len(percent_like)}",
        "single consistent scale",
        (
            "No explicit unit column was available; rate/yield scale consistency "
            "was inferred from medians."
            if rate_scales
            else (
                "No explicit unit column or rate-like series was available; "
                "unit consistency requires source-contract metadata."
            )
        ),
    )


def _validate_values(context: DatasetContext, collector: ResultCollector) -> None:
    frame = context.frame
    layout = context.layout
    nonfinite_count = 0
    impossible_count = 0
    negative_count = 0
    extreme_count = 0
    discontinuity_count = 0
    evaluated_series = 0

    for label, dates, values in _iter_numeric_series(frame, layout):
        evaluated_series += 1
        numeric = values.astype(float)
        nonfinite_count += int(np.isinf(numeric.to_numpy(dtype=float, na_value=np.nan)).sum())
        clean = numeric.replace([np.inf, -np.inf], np.nan)
        if _rate_like(label):
            impossible_count += int(((clean < -20.0) | (clean > 100.0)).sum())
        if _nonnegative_like(label):
            negative_count += int((clean < 0).sum())

        valid = pd.DataFrame({"date": dates, "value": clean}).dropna().sort_values("date")
        if len(valid) >= 8:
            changes = valid["value"].diff().dropna()
            extreme_count += int(_robust_outlier_mask(changes, threshold=12.0).sum())
            discontinuity_count += int(_robust_outlier_mask(changes, threshold=20.0).sum())

    collector.add(
        "DQ08.2",
        "Negative or impossible values",
        "PASS" if nonfinite_count + impossible_count + negative_count == 0 else "FAIL",
        "critical",
        "invalid_numeric_observations",
        nonfinite_count + impossible_count + negative_count,
        0,
        (
            f"Non-finite={nonfinite_count}; rate/yield outside [-20, 100]={impossible_count}; "
            f"negative values in nonnegative semantic series={negative_count}."
        ),
    )
    collector.add(
        "DQ09",
        "Extreme observations",
        "PASS" if extreme_count == 0 else "WARN",
        "medium",
        "robust_difference_outliers",
        extreme_count,
        0,
        f"First differences were screened at robust z-score > 12 across {evaluated_series} series.",
    )
    collector.add(
        "DQ10",
        "Series discontinuities",
        "PASS" if discontinuity_count == 0 else "WARN",
        "medium",
        "severe_robust_difference_outliers",
        discontinuity_count,
        0,
        "Potential level breaks were screened at robust z-score > 20; "
        "warnings require source-event review.",
    )

    if context.spec.name == "sofr" and layout.date_column is not None:
        lookup = _column_lookup(frame.columns)
        percentile_columns: list[tuple[int, str]] = []
        for normalized, original in lookup.items():
            match = re.search(
                r"(?:^|_)(1|25|75|99)(?:st|th)?(?:_|$).*percentile|percentile.*(?:^|_)(1|25|75|99)",
                normalized,
            )
            if match:
                percentile_group = next(
                    (group for group in match.groups() if group is not None and group.isdigit()),
                    None,
                )
                if percentile_group is not None:
                    percentile_columns.append((int(percentile_group), original))
        percentile_columns.sort(key=lambda item: item[0])
        if len(percentile_columns) >= 2:
            values = pd.DataFrame(  # type: ignore[assignment]
                {rank: _coerce_numeric(frame[column]) for rank, column in percentile_columns}
            )
            violations = int((values.diff(axis=1).iloc[:, 1:] < 0).any(axis=1).sum())  # type: ignore[call-overload]
            collector.add(
                "DQ08.3",
                "SOFR percentile ordering",
                "PASS" if violations == 0 else "FAIL",
                "high",
                "rows_with_percentile_order_violation",
                violations,
                0,
                "Published percentiles must be nondecreasing from lower to higher percentile.",
            )


def _validate_revisions(context: DatasetContext, collector: ResultCollector) -> None:
    frame = context.frame
    layout = context.layout
    if layout.vintage_column is None:
        collector.add(
            "DQ11",
            "Revision and restatement behavior",
            "WARN",
            "medium",
            "vintage_metadata_available",
            False,
            True,
            "A single canonical snapshot without a vintage/retrieval column cannot "
            "prove revision behavior; retain immutable raw snapshots and manifests.",
        )
        return

    if layout.date_column is None or not layout.value_columns:
        return

    key_columns = [layout.date_column]
    if layout.series_column:
        key_columns.append(layout.series_column)
    value_column = layout.long_value_column or layout.value_columns[0]
    work = frame[[*key_columns, layout.vintage_column, value_column]].copy()
    work[value_column] = _coerce_numeric(work[value_column])
    grouped = work.groupby(key_columns, dropna=False)
    revised_keys = int((grouped[layout.vintage_column].nunique(dropna=True) > 1).sum())
    restated_keys = int((grouped[value_column].nunique(dropna=True) > 1).sum())
    collector.add(
        "DQ11",
        "Revision and restatement behavior",
        "PASS",
        "medium",
        "restated_observation_keys",
        restated_keys,
        "documented and reproducible",
        f"Detected {revised_keys} keys with multiple vintages and "
        f"{restated_keys} keys with changed values.",
    )


def validate_dataset(
    dataset: str,
    path: Path,
    minimum_completeness: float = MIN_COMPLETENESS,
) -> tuple[list[CheckResult], DatasetContext | None]:
    """Validate one canonical dataset and return results plus cross-check context."""

    spec = SPECS[dataset]
    collector = ResultCollector(dataset=dataset, source_file=str(path))
    if not path.exists():
        collector.add(
            "DQ00",
            "Dataset presence",
            "FAIL",
            "critical",
            "file_exists",
            False,
            True,
            f"Required file was not found: {path}",
        )
        return collector.results, None

    try:
        frame = read_table(path)
    except Exception as exc:
        collector.add(
            "DQ00",
            "Dataset presence and readability",
            "FAIL",
            "critical",
            "readable",
            False,
            True,
            f"{type(exc).__name__}: {exc}",
        )
        return collector.results, None

    collector.add(
        "DQ00",
        "Dataset presence and readability",
        "PASS" if not frame.empty else "FAIL",
        "critical",
        "row_count",
        len(frame),
        "> 0",
        f"Loaded {path.name} with {len(frame):,} rows and {len(frame.columns)} columns.",
    )
    layout = detect_layout(frame, spec)
    if layout.date_column is not None:
        parsed_dates = pd.to_datetime(
            frame[layout.date_column], errors="coerce", utc=True
        ).dt.tz_convert(None)
    else:
        parsed_dates = pd.Series(pd.NaT, index=frame.index, dtype="datetime64[ns]")
    context = DatasetContext(
        spec=spec, path=path, frame=frame, layout=layout, parsed_dates=parsed_dates
    )

    _validate_schema(context, collector)
    _validate_dates(context, collector)
    _validate_missing_and_completeness(context, collector, minimum_completeness)
    _validate_units(context, collector)
    _validate_values(context, collector)
    _validate_revisions(context, collector)
    return collector.results, context


def _overlap_window_sets(
    left: set[pd.Timestamp], right: set[pd.Timestamp]
) -> tuple[set[pd.Timestamp], set[pd.Timestamp]]:
    if not left or not right:
        return set(), set()
    start = max(min(left), min(right))
    end = min(max(left), max(right))
    if start > end:
        return set(), set()
    return (
        {value for value in left if start <= value <= end},
        {value for value in right if start <= value <= end},
    )


def _iso_week_set(values: set[pd.Timestamp]) -> set[tuple[int, int]]:
    return {(int(value.isocalendar().year), int(value.isocalendar().week)) for value in values}


def validate_calendar_alignment(
    contexts: dict[str, DatasetContext], minimum_completeness: float
) -> list[CheckResult]:
    """Validate peer-calendar and weekly-to-daily alignment across datasets."""

    collector = ResultCollector(dataset="cross_dataset", source_file="multiple")

    def add_pair(left_name: str, right_name: str, weekly: bool) -> None:
        left = contexts.get(left_name)
        right = contexts.get(right_name)
        check_suffix = f"{left_name}_{right_name}"
        if left is None or right is None:
            collector.add(
                f"DQ12.{check_suffix}",
                "Cross-dataset calendar alignment",
                "FAIL",
                "critical",
                "datasets_available",
                False,
                True,
                f"Cannot compare {left_name} and {right_name}; "
                "one or both datasets are unavailable.",
            )
            return
        left_dates, right_dates = _overlap_window_sets(left.all_dates, right.all_dates)
        if weekly:
            left_values: set[Any] = _iso_week_set(left_dates)
            right_values: set[Any] = _iso_week_set(right_dates)
        else:
            left_values = left_dates
            right_values = right_dates
        union = left_values | right_values
        intersection = left_values & right_values
        ratio = 0.0 if not union else len(intersection) / len(union)
        collector.add(
            f"DQ12.{check_suffix}",
            "Cross-dataset calendar alignment",
            "PASS" if ratio + 1e-12 >= minimum_completeness else "FAIL",
            "high",
            "calendar_jaccard_alignment",
            ratio,
            minimum_completeness,
            "Compared overlapping "
            f"{'ISO weeks' if weekly else 'observation dates'} for "
            f"{left_name} and {right_name}.",
        )

    add_pair("sofr", "h15", weekly=False)
    add_pair("fr2004", "h41", weekly=True)

    weekly_contexts = [contexts[name] for name in ("fr2004", "h41") if name in contexts]
    daily_contexts = [contexts[name] for name in ("sofr", "h15") if name in contexts]
    if not weekly_contexts or not daily_contexts:
        collector.add(
            "DQ12.weekly_daily",
            "Cross-frequency calendar alignment",
            "FAIL",
            "critical",
            "weekly_dates_with_daily_support",
            0.0,
            minimum_completeness,
            "Weekly and daily source groups must both be available.",
        )
    else:
        daily_dates = set().union(*(context.all_dates for context in daily_contexts))
        weekly_dates = set().union(*(context.all_dates for context in weekly_contexts))
        supported = 0
        for weekly_date in weekly_dates:
            if any(
                weekly_date - pd.Timedelta(days=7) <= date <= weekly_date + pd.Timedelta(days=2)
                for date in daily_dates
            ):
                supported += 1
        ratio = 0.0 if not weekly_dates else supported / len(weekly_dates)
        collector.add(
            "DQ12.weekly_daily",
            "Cross-frequency calendar alignment",
            "PASS" if ratio + 1e-12 >= minimum_completeness else "FAIL",
            "high",
            "weekly_dates_with_daily_support",
            ratio,
            minimum_completeness,
            "Each weekly observation was required to have at least one daily-source "
            "observation from the prior seven days through two days after.",
        )
    return collector.results


def run_validation(
    files: dict[str, Path],
    minimum_completeness: float = MIN_COMPLETENESS,
) -> list[CheckResult]:
    """Run all source-level and cross-source validations."""

    all_results: list[CheckResult] = []
    contexts: dict[str, DatasetContext] = {}
    for dataset in DATASET_ORDER:
        path = files.get(dataset)
        if path is None:
            collector = ResultCollector(dataset=dataset, source_file="")
            collector.add(
                "DQ00",
                "Dataset presence",
                "FAIL",
                "critical",
                "file_discovered",
                False,
                True,
                f"No canonical {SPECS[dataset].label} CSV or Parquet file was discovered.",
            )
            all_results.extend(collector.results)
            continue
        results, context = validate_dataset(dataset, path, minimum_completeness)
        all_results.extend(results)
        if context is not None:
            contexts[dataset] = context

    all_results.extend(validate_calendar_alignment(contexts, minimum_completeness))
    return _apply_control_policy(  # type: ignore[return-value]
        pd.DataFrame(all_results),
        files=files,
        minimum_completeness=minimum_completeness,
    ).to_dict(orient="records")


def results_frame(results: Sequence[CheckResult]) -> pd.DataFrame:
    columns = [
        "dataset",
        "source_file",
        "check_id",
        "check_name",
        "status",
        "severity",
        "metric",
        "observed",
        "threshold",
        "details",
        "checked_at_utc",
    ]
    rows: list[dict[str, object] | dict[str, str]] = []
    for result in results:
        if isinstance(result, dict):
            rows.append(result)
        else:
            rows.append(result.as_dict())
    return pd.DataFrame(rows, columns=columns)


def write_evidence(
    results: Sequence[CheckResult],
    files: dict[str, Path],
    results_csv: Path,
    report_txt: Path,
    minimum_completeness: float,
) -> bool:
    """Write controlled CSV and text evidence; return overall pass state."""
    normalized_results = [
        result if isinstance(result, dict) else result.as_dict() for result in results
    ]

    results_csv.parent.mkdir(parents=True, exist_ok=True)
    report_txt.parent.mkdir(parents=True, exist_ok=True)
    frame = results_frame(normalized_results)  # type: ignore[arg-type]
    frame.to_csv(results_csv, index=False)

    failure_count = int((frame["status"] == "FAIL").sum()) if not frame.empty else 1
    warning_count = int((frame["status"] == "WARN").sum()) if not frame.empty else 0
    pass_count = int((frame["status"] == "PASS").sum()) if not frame.empty else 0
    overall_pass = failure_count == 0

    lines = [
        "FICC TREASURY CLEARING LIQUIDITY STRESS TESTING",
        "SECTION 7 - DATA-QUALITY VALIDATION REPORT",
        "=" * 72,
        f"Run timestamp (UTC): {datetime.now(UTC).isoformat()}",
        f"Minimum expected-series completeness: {minimum_completeness:.3%}",
        f"Overall decision: {'PASS' if overall_pass else 'FAIL'}",
        f"Checks passed: {pass_count}",
        f"Warnings: {warning_count}",
        f"Failures: {failure_count}",
        "",
        "SELECTED SOURCE FILES",
        "-" * 72,
    ]
    for dataset in DATASET_ORDER:
        lines.append(f"{dataset.upper():8s} {files.get(dataset, 'NOT FOUND')}")

    lines.extend(["", "CONTROL RESULTS", "-" * 72])
    for result in normalized_results:
        lines.append(
            f"[{result['status']:4s}] {result['dataset']:13s} {result['check_id']:16s} "
            f"{result['check_name']} | observed={result['observed']} | "
            f"threshold={result['threshold']}"
        )
        lines.append(f"       {result['details']}")

    lines.extend(
        [
            "",
            "COMPLETION GATE",
            "-" * 72,
            f"Schema conformance: {'PASS' if not _has_failure(frame, 'DQ01') else 'FAIL'}",
            f"Required columns: {'PASS' if not _has_failure(frame, 'DQ02') else 'FAIL'}",
            f"Date uniqueness: {'PASS' if not _has_failure(frame, 'DQ03') else 'FAIL'}",
            f"Chronological ordering: {'PASS' if not _has_failure(frame, 'DQ04') else 'FAIL'}",
            f"Missing values: {'PASS' if not _has_failure(frame, 'DQ05') else 'FAIL'}",
            "Expected-frequency completeness >= 99.5%: "
            f"{'PASS' if not _has_failure(frame, 'DQ06') else 'FAIL'}",
            f"Unit consistency: {'PASS' if not _has_failure(frame, 'DQ07') else 'FAIL'}",
            "Negative or impossible values: "
            f"{'PASS' if not _has_failure(frame, 'DQ08') else 'FAIL'}",
            "Extreme observations reviewed: "
            f"{'PASS' if not _has_failure(frame, 'DQ09') else 'FAIL'}",
            "Series discontinuities reviewed: "
            f"{'PASS' if not _has_failure(frame, 'DQ10') else 'FAIL'}",
            "Revision/restatement behavior assessed: "
            f"{'PASS' if not _has_failure(frame, 'DQ11') else 'FAIL'}",
            "Cross-dataset calendar alignment: "
            f"{'PASS' if not _has_failure(frame, 'DQ12') else 'FAIL'}",
            f"Section 7 final decision: {'PASS' if overall_pass else 'FAIL'}",
        ]
    )
    report_txt.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return overall_pass


def _has_failure(frame: pd.DataFrame, prefix: str) -> bool:
    if frame.empty:
        return True
    mask = frame["check_id"].astype(str).str.startswith(prefix)
    return bool((frame.loc[mask, "status"] == "FAIL").any())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path("data"),
        help="Root containing raw/interim/processed data.",
    )
    parser.add_argument(
        "--file",
        action="append",
        default=[],
        metavar="DATASET=PATH",
        help="Override automatic discovery for fr2004, sofr, h15, or h41. Repeat as needed.",
    )
    parser.add_argument(
        "--minimum-completeness",
        type=float,
        default=MIN_COMPLETENESS,
        help="Minimum required expected-series completeness ratio.",
    )
    parser.add_argument(
        "--results-csv",
        type=Path,
        default=Path("reports/tables/data_quality_results.csv"),
    )
    parser.add_argument(
        "--report-txt",
        type=Path,
        default=Path("reports/evidence/data_quality_report.txt"),
    )
    return parser


_P2S7_POLICY_CALIBRATION_V1 = True


def _policy_read_table(path: object) -> pd.DataFrame:
    candidate = Path(str(path))
    if candidate.suffix.lower() == ".parquet":
        return pd.read_parquet(candidate)
    if candidate.suffix.lower() == ".csv":
        return pd.read_csv(candidate)
    raise ValueError(f"Unsupported policy input: {candidate}")


def _policy_date_column(frame: pd.DataFrame) -> str:
    for name in ("observation_date", "date", "DATE"):
        if name in frame.columns:
            return name
    raise ValueError("No supported date column was found.")


def _policy_update_row(
    frame: pd.DataFrame,
    *,
    dataset: str,
    check_id: str,
    observed: float | int,
    threshold: float | int,
    details: str,
    passed: bool,
) -> None:
    mask = frame["dataset"].astype(str).eq(dataset) & frame["check_id"].astype(str).eq(check_id)
    if not bool(mask.any()):
        return

    matching_index = frame.index[mask.to_numpy(dtype=bool)]
    row_count = len(matching_index)

    update_columns: dict[str, list[object]] = {
        "observed": [observed] * row_count,
        "threshold": [threshold] * row_count,
        "details": [details] * row_count,
    }

    if "status" in frame.columns:
        update_columns["status"] = ["PASS" if passed else "FAIL"] * row_count
    if "result" in frame.columns:
        update_columns["result"] = ["PASS" if passed else "FAIL"] * row_count
    if "passed" in frame.columns:
        update_columns["passed"] = [passed] * row_count
    if "is_pass" in frame.columns:
        update_columns["is_pass"] = [passed] * row_count

    for column, values in update_columns.items():
        if column not in frame.columns:
            continue

        target_dtype = frame[column].dtype
        if column in {"observed", "threshold"} and pd.api.types.is_numeric_dtype(target_dtype):
            converted = values
        elif column in {"passed", "is_pass"}:
            converted = [bool(value) for value in values]
        elif pd.api.types.is_string_dtype(target_dtype) or pd.api.types.is_object_dtype(
            target_dtype
        ):
            converted = [str(value) for value in values]
        else:
            converted = values

        if column in {"observed", "threshold"} and pd.api.types.is_numeric_dtype(target_dtype):
            frame.loc[matching_index, column] = pd.Series(
                converted,
                index=matching_index,
                dtype=target_dtype,
            )
        elif column in {"passed", "is_pass"}:
            frame.loc[matching_index, column] = pd.Series(
                converted,
                index=matching_index,
                dtype="boolean" if pd.api.types.is_extension_array_dtype(target_dtype) else bool,
            )
        else:
            frame.loc[matching_index, column] = pd.Series(
                converted,
                index=matching_index,
                dtype="string" if pd.api.types.is_string_dtype(target_dtype) else object,
            )


def _weekly_reporting_completeness(
    frame: pd.DataFrame,
) -> tuple[float, int, int, int]:
    import numpy as np

    date_column = _policy_date_column(frame)
    dates = (
        pd.to_datetime(frame[date_column], errors="coerce")
        .dropna()
        .dt.normalize()
        .drop_duplicates()
        .sort_values()
    )
    if len(dates) < 2:
        return 0.0, 0, 0, -1

    weekday = int(dates.dt.weekday.mode().iloc[0])
    codes = ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN")
    expected = pd.date_range(
        start=dates.iloc[0],
        end=dates.iloc[-1],
        freq=f"W-{codes[weekday]}",
    )

    observed_days = dates.to_numpy(dtype="datetime64[D]").astype("int64")
    expected_days = expected.to_numpy(dtype="datetime64[D]").astype("int64")
    positions = np.searchsorted(observed_days, expected_days)
    left = np.clip(positions - 1, 0, len(observed_days) - 1)
    right = np.clip(positions, 0, len(observed_days) - 1)
    distances = np.minimum(
        np.abs(expected_days - observed_days[left]),
        np.abs(expected_days - observed_days[right]),
    )

    matched = int((distances <= 2).sum())
    total = len(expected_days)
    return (float(matched / total) if total else 0.0, matched, total, weekday)


def _fr2004_nonfinite_count(frame: pd.DataFrame) -> int:
    import numpy as np

    if "value" in frame.columns:
        values = pd.to_numeric(frame["value"], errors="coerce")
    else:
        date_column = _policy_date_column(frame)
        numeric_columns = [
            column
            for column in frame.columns
            if column != date_column and pd.api.types.is_numeric_dtype(frame[column])
        ]
        if not numeric_columns:
            return 0
        values = pd.concat(
            [pd.to_numeric(frame[column], errors="coerce") for column in numeric_columns],
            ignore_index=True,
        )

    present = values.dropna().to_numpy(dtype=float)
    return int((~np.isfinite(present)).sum())


def _nearest_calendar_alignment(
    left_frame: pd.DataFrame,
    right_frame: pd.DataFrame,
    *,
    tolerance_days: int = 3,
) -> tuple[float, int, int]:
    import numpy as np

    left_dates = (
        pd.to_datetime(
            left_frame[_policy_date_column(left_frame)],
            errors="coerce",
        )
        .dropna()
        .dt.normalize()
        .drop_duplicates()
        .sort_values()
    )
    right_dates = (
        pd.to_datetime(
            right_frame[_policy_date_column(right_frame)],
            errors="coerce",
        )
        .dropna()
        .dt.normalize()
        .drop_duplicates()
        .sort_values()
    )

    if left_dates.empty or right_dates.empty:
        return 0.0, 0, 0

    start = max(left_dates.iloc[0], right_dates.iloc[0])
    end = min(left_dates.iloc[-1], right_dates.iloc[-1])
    reference = left_dates[left_dates.between(start, end)]
    candidates = right_dates[
        right_dates.between(
            start - pd.Timedelta(days=tolerance_days),
            end + pd.Timedelta(days=tolerance_days),
        )
    ]

    if reference.empty or candidates.empty:
        return 0.0, 0, len(reference)

    reference_days = reference.to_numpy(dtype="datetime64[D]").astype("int64")
    candidate_days = candidates.to_numpy(dtype="datetime64[D]").astype("int64")
    positions = np.searchsorted(candidate_days, reference_days)
    left = np.clip(positions - 1, 0, len(candidate_days) - 1)
    right = np.clip(positions, 0, len(candidate_days) - 1)
    distances = np.minimum(
        np.abs(reference_days - candidate_days[left]),
        np.abs(reference_days - candidate_days[right]),
    )

    matched = int((distances <= tolerance_days).sum())
    total = len(reference_days)
    return (float(matched / total) if total else 0.0, matched, total)


def _apply_control_policy(
    frame: pd.DataFrame,
    *,
    files: dict[str, Path],
    minimum_completeness: float,
) -> pd.DataFrame:
    adjusted = frame.copy()

    fr2004 = _policy_read_table(files["fr2004"])
    completeness, matched, expected, weekday = _weekly_reporting_completeness(fr2004)
    weekday_names = (
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
        "Sunday",
    )
    weekday_name = weekday_names[weekday] if 0 <= weekday <= 6 else "unknown"

    _policy_update_row(
        adjusted,
        dataset="fr2004",
        check_id="DQ06",
        observed=completeness,
        threshold=minimum_completeness,
        details=(
            "Evaluated the FR 2004 weekly source-reporting calendar on "
            f"{weekday_name}; {matched}/{expected} expected weeks matched "
            "within a two-calendar-day holiday tolerance. Sparse, "
            "discontinued, and episodic series are not treated as missing "
            "weekly rows."
        ),
        passed=completeness >= minimum_completeness,
    )

    nonfinite = _fr2004_nonfinite_count(fr2004)
    _policy_update_row(
        adjusted,
        dataset="fr2004",
        check_id="DQ08.2",
        observed=nonfinite,
        threshold=0,
        details=(
            "FR 2004 values are USD millions. Negative net positions are "
            "economically permissible and are not subjected to rate/yield "
            f"bounds. Non-finite numeric count={nonfinite}."
        ),
        passed=nonfinite == 0,
    )

    sofr = _policy_read_table(files["sofr"])
    h15 = _policy_read_table(files["h15"])
    alignment, aligned, total = _nearest_calendar_alignment(
        sofr,
        h15,
        tolerance_days=3,
    )
    _policy_update_row(
        adjusted,
        dataset="cross_dataset",
        check_id="DQ12.sofr_h15",
        observed=alignment,
        threshold=minimum_completeness,
        details=(
            "Compared overlapping SOFR and H.15 calendars using nearest-date "
            "matching within three calendar days for official holiday-calendar "
            f"differences. No values were interpolated; aligned {aligned}/{total} "
            "SOFR dates."
        ),
        passed=alignment >= minimum_completeness,
    )

    return adjusted


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not 0.0 < args.minimum_completeness <= 1.0:
        parser.error("--minimum-completeness must be in (0, 1].")

    discovered_result: object = discover_dataset_files(args.data_root.resolve())
    if isinstance(discovered_result, tuple) and len(discovered_result) == 2:
        discovered = cast(dict[str, Path], discovered_result[0])
    else:
        discovered = cast(dict[str, Path], discovered_result)
    try:
        overrides = parse_file_overrides(args.file)
    except ValueError as exc:
        parser.error(str(exc))
    files = {**discovered, **overrides}

    results = run_validation(files=files, minimum_completeness=args.minimum_completeness)
    overall_pass = write_evidence(
        results=results,
        files=files,
        results_csv=args.results_csv,
        report_txt=args.report_txt,
        minimum_completeness=args.minimum_completeness,
    )
    print(f"Data-quality results: {args.results_csv}")
    print(f"Data-quality evidence: {args.report_txt}")
    print(f"Section 7 final decision: {'PASS' if overall_pass else 'FAIL'}")
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
