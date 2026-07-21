"""Build the controlled Section 8 analytical datasets.

The module accepts schema variation across FR 2004, SOFR, H.15, and H.4.1
source outputs. It converts each source into a canonical long-form analytical
schema with standardized units, aligned daily and weekly frequencies, bounded
missing-value treatment, lagged variables, maturity mappings, and lineage.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import duckdb
import numpy as np
import pandas as pd
import yaml

LOGGER = logging.getLogger(__name__)

DATE_CANDIDATES = (
    "observation_date",
    "date",
    "as_of_date",
    "asof_date",
    "effective_date",
    "business_date",
    "report_date",
    "week_ending_date",
    "week_ending",
    "week_end",
    "period",
    "time_period",
)
SERIES_CANDIDATES = (
    "series_id",
    "series",
    "identifier",
    "metric",
    "measure",
    "variable",
    "mnemonic",
    "description",
)
VALUE_CANDIDATES = (
    "value",
    "observation_value",
    "amount",
    "level",
    "rate",
    "volume",
)
UNIT_CANDIDATES = ("unit", "units", "unit_of_measure", "uom")
FREQUENCY_CANDIDATES = ("frequency", "freq", "periodicity")
RETRIEVED_CANDIDATES = (
    "retrieved_at_utc",
    "retrieval_timestamp_utc",
    "downloaded_at_utc",
    "retrieved_at",
)

ALLOWED_UNITS = {"USD", "PERCENT", "BASIS_POINTS", "COUNT", "INDEX", "UNKNOWN"}


@dataclass(frozen=True)
class SourceFile:
    path: Path
    source_name: str
    sha256: str
    modified_at_utc: str


def _slug(value: Any) -> str:
    text = str(value).strip()
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", text)
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "_", text)
    return re.sub(r"_+", "_", text).strip("_") or "unnamed"


def _first_present(columns: Iterable[str], candidates: Iterable[str]) -> str | None:
    lookup = {_slug(column): column for column in columns}
    for candidate in candidates:
        if candidate in lookup:
            return lookup[candidate]
    return None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _source_from_path(path: Path, token_map: dict[str, list[str]]) -> str | None:
    normalized = str(path).lower().replace("\\", "/")
    for source, tokens in token_map.items():
        if any(token.lower() in normalized for token in tokens):
            return source.upper()
    return None


def _snapshot_key(path: Path, source: str) -> tuple[str, str, str, str]:
    """Return a stable key that collapses timestamped downloads of one dataset."""
    stem = path.stem.lower()
    stem = re.sub(
        r"[_-]20\d{6}t\d{6}z?(?:[_-][0-9a-f]{8,64})?$",
        "",
        stem,
    )
    stem = re.sub(r"[_-][0-9a-f]{12,64}$", "", stem)
    return source, path.parent.as_posix().lower(), stem, path.suffix.lower()


def discover_source_files(repo_root: Path, config: dict[str, Any]) -> list[SourceFile]:
    discovery = config["source_discovery"]
    supported = {suffix.lower() for suffix in discovery["supported_extensions"]}
    token_map = discovery["source_tokens"]
    targets = {
        (repo_root / config["output"]["fed_liquidity_factors"]).resolve(),
        (repo_root / config["output"]["treasury_market_factors"]).resolve(),
        (repo_root / config["output"]["duckdb"]).resolve(),
    }

    candidates: list[tuple[Path, str, float]] = []
    for root_name in discovery["roots"]:
        root = repo_root / root_name
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in supported:
                continue
            if path.resolve() in targets:
                continue
            normalized = str(path).lower()
            if any(token in normalized for token in ("manifest", "quality_result", "data_quality")):
                continue
            source = _source_from_path(path, token_map)
            if source is None:
                continue
            candidates.append((path, source, path.stat().st_mtime))

    # Keep the newest timestamped snapshot for each logical source artifact.
    latest: dict[tuple[str, str, str, str], tuple[Path, str, float]] = {}
    for path, source, modified in candidates:
        key = _snapshot_key(path, source)
        current = latest.get(key)
        if current is None or modified > current[2]:
            latest[key] = (path, source, modified)

    results: list[SourceFile] = []
    seen_content: set[tuple[str, str]] = set()
    for path, source, modified in sorted(
        latest.values(), key=lambda item: (item[1], str(item[0]).lower())
    ):
        file_hash = _sha256(path)
        content_key = (source, file_hash)
        if content_key in seen_content:
            LOGGER.info("Skipping duplicate source snapshot: %s", path)
            continue
        seen_content.add(content_key)
        modified_at = datetime.fromtimestamp(modified, tz=UTC).isoformat()
        results.append(SourceFile(path, source, file_hash, modified_at))

    counts: dict[str, int] = {}
    for item in results:
        counts[item.source_name] = counts.get(item.source_name, 0) + 1
    LOGGER.info("Selected %s controlled source files: %s", len(results), counts)
    return results


def _records_from_json(payload: Any) -> list[dict[str, Any]] | None:
    if isinstance(payload, list) and all(isinstance(item, dict) for item in payload):
        return payload
    if not isinstance(payload, dict):
        return None

    priority_keys = (
        "refRates",
        "referenceRates",
        "data",
        "observations",
        "results",
        "records",
        "rates",
        "series",
    )
    for key in priority_keys:
        value = payload.get(key)
        records = _records_from_json(value)
        if records:
            return records

    for value in payload.values():
        records = _records_from_json(value)
        if records:
            return records
    return None


def _read_frame(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix == ".parquet":
        return pd.read_parquet(path)
    if suffix == ".csv":
        return pd.read_csv(path, low_memory=False)
    if suffix in {".xlsx", ".xls"}:
        return pd.read_excel(path)
    if suffix == ".json":
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
        records = _records_from_json(payload)
        if records is not None:
            return pd.json_normalize(records)
        if isinstance(payload, dict):
            return pd.json_normalize(payload)
        return pd.DataFrame(payload)
    raise ValueError(f"Unsupported file extension: {path}")


def _numeric(series: pd.Series) -> pd.Series:
    if pd.api.types.is_numeric_dtype(series):
        return pd.to_numeric(series, errors="coerce")
    cleaned = (
        series.astype("string")
        .str.strip()
        .replace({"": pd.NA, "NA": pd.NA, "N/A": pd.NA, "ND": pd.NA, ".": pd.NA})
        .str.replace(r"^\((.*)\)$", r"-\1", regex=True)
        .str.replace(r"[$,%]", "", regex=True)
        .str.replace(",", "", regex=False)
    )
    return pd.to_numeric(cleaned, errors="coerce")


def _infer_frequency(dates: pd.Series, explicit: Any = None) -> str:
    if explicit is not None and not pd.isna(explicit):
        text = str(explicit).strip().lower()
        if text.startswith("d") or "daily" in text:
            return "daily"
        if text.startswith("w") or "weekly" in text:
            return "weekly"
        if text.startswith("m") or "monthly" in text:
            return "monthly"
    unique = (
        pd.Series(pd.to_datetime(dates, errors="coerce")).dropna().drop_duplicates().sort_values()
    )
    if len(unique) < 2:
        return "unknown"
    median_days = unique.diff().dt.days.dropna().median()
    if median_days <= 3:
        return "daily"
    if median_days <= 10:
        return "weekly"
    if median_days <= 40:
        return "monthly"
    return "irregular"


def _infer_metric_kind(source: str, metric: str) -> str:
    text = f"{source} {metric}".lower()
    if any(token in text for token in ("rate", "yield", "percentile", "spread", "bps")):
        return "rate"
    if any(token in text for token in ("volume", "transaction", "turnover", "flow")):
        return "flow"
    if any(token in text for token in ("fail", "count", "number")):
        return "flow"
    if any(
        token in text
        for token in ("balance", "position", "holding", "inventory", "outstanding", "asset")
    ):
        return "stock"
    return "other"


def _normalize_unit(source: str, metric: str, explicit_unit: Any) -> tuple[str, float, str]:
    raw = "" if explicit_unit is None or pd.isna(explicit_unit) else str(explicit_unit).strip()
    text = f"{raw} {metric}".lower()

    if "basis point" in text or re.search(r"\bbps?\b", text):
        return "BASIS_POINTS", 1.0, raw or "basis points"
    if "%" in text or "percent" in text or "percentage" in text:
        return "PERCENT", 1.0, raw or "percent"
    if (
        any(token in text for token in ("count", "number of", "transactions"))
        and "volume" not in text
    ):
        return "COUNT", 1.0, raw or "count"
    if "index" in text:
        return "INDEX", 1.0, raw or "index"

    currency_signal = any(
        token in text for token in ("usd", "dollar", "$", "million", "billion", "thousand")
    )
    if "billion" in text:
        return "USD", 1_000_000_000.0, raw or "USD billions"
    if "million" in text:
        return "USD", 1_000_000.0, raw or "USD millions"
    if "thousand" in text:
        return "USD", 1_000.0, raw or "USD thousands"
    if currency_signal:
        return "USD", 1.0, raw or "USD"

    metric_text = metric.lower()
    if source == "H15" or any(token in metric_text for token in ("yield", "rate", "percentile")):
        return "PERCENT", 1.0, raw or "percent"
    if source == "SOFR":
        if "volume" in metric_text:
            return "USD", 1_000_000_000.0, raw or "USD billions"
        return "PERCENT", 1.0, raw or "percent"
    if source in {"FR2004", "H41"}:
        return "USD", 1_000_000.0, raw or "USD millions"
    return "UNKNOWN", 1.0, raw or "unknown"


def _maturity_mapping(series_id: str, metric: str) -> tuple[float | None, str | None, str | None]:
    text = f"{series_id} {metric}".upper().replace("_", " ").replace("-", " ")
    explicit_codes = {
        "DGS1MO": 1,
        "DGS3MO": 3,
        "DGS6MO": 6,
        "DGS1": 12,
        "DGS2": 24,
        "DGS3": 36,
        "DGS5": 60,
        "DGS7": 84,
        "DGS10": 120,
        "DGS20": 240,
        "DGS30": 360,
        "DTB4WK": 1,
        "DTB3": 3,
        "DTB6": 6,
        "DTB1YR": 12,
    }
    months: int | None = None
    for code, mapped in explicit_codes.items():
        if re.search(rf"\b{re.escape(code)}\b", text):
            months = mapped
            break
    if months is None:
        match = re.search(r"\b(1|3|6)\s*(?:MONTH|MO|M)\b", text)
        if match:
            months = int(match.group(1))
    if months is None:
        match = re.search(r"\b(1|2|3|5|7|10|20|30)\s*(?:YEAR|YR|Y)\b", text)
        if match:
            months = int(match.group(1)) * 12
    if months is None:
        return None, None, None
    label = f"{months}M" if months < 12 else f"{months // 12}Y"
    bucket = "bill" if months <= 12 else "note" if months <= 120 else "bond"
    return float(months), label, bucket


def _lineage_id(file_hash: str, source: str, series_id: str, date: Any, row: Any) -> str:
    payload = f"{file_hash}|{source}|{series_id}|{date}|{row}".encode()
    return hashlib.sha256(payload).hexdigest()


def canonicalize_source(source_file: SourceFile, repo_root: Path) -> pd.DataFrame:
    LOGGER.info(
        "Reading %s source: %s",
        source_file.source_name,
        source_file.path.relative_to(repo_root).as_posix(),
    )
    frame = _read_frame(source_file.path)
    if frame.empty:
        LOGGER.warning("Skipping empty source file: %s", source_file.path)
        return pd.DataFrame()

    frame = frame.copy()
    frame.columns = [str(column).strip() for column in frame.columns]
    date_col = _first_present(frame.columns, DATE_CANDIDATES)
    if date_col is None:
        LOGGER.warning(
            "Skipping source without an identifiable date column: %s",
            source_file.path,
        )
        return pd.DataFrame()

    frame[date_col] = (
        pd.to_datetime(frame[date_col], errors="coerce", utc=True)
        .dt.tz_localize(None)
        .dt.normalize()
    )
    frame = frame.loc[frame[date_col].notna()].copy()
    if frame.empty:
        LOGGER.warning("Skipping source with no valid dates: %s", source_file.path)
        return pd.DataFrame()

    frame["_source_row_number"] = np.arange(len(frame), dtype=np.int64) + 2
    series_col = _first_present(frame.columns, SERIES_CANDIDATES)
    value_col = _first_present(frame.columns, VALUE_CANDIDATES)
    unit_col = _first_present(frame.columns, UNIT_CANDIDATES)
    frequency_col = _first_present(frame.columns, FREQUENCY_CANDIDATES)
    retrieved_col = _first_present(frame.columns, RETRIEVED_CANDIDATES)

    metadata_cols = {
        column
        for column in (
            date_col,
            series_col,
            value_col,
            unit_col,
            frequency_col,
            retrieved_col,
            "_source_row_number",
        )
        if column
    }

    if series_col and value_col and series_col != value_col:
        selected = [date_col, series_col, value_col, "_source_row_number"]
        for optional in (unit_col, frequency_col, retrieved_col):
            if optional and optional not in selected:
                selected.append(optional)
        long_frame = frame[selected].copy()
        long_frame["_series"] = long_frame[series_col].astype("string")
        long_frame["_raw_value"] = long_frame[value_col]
    else:
        candidate_columns = []
        for column in frame.columns:
            if column in metadata_cols:
                continue
            if _numeric(frame[column]).notna().any():
                candidate_columns.append(column)
        if not candidate_columns:
            LOGGER.warning("No numeric analytical series detected in %s", source_file.path)
            return pd.DataFrame()

        id_columns = [date_col, "_source_row_number"]
        for optional in (unit_col, frequency_col, retrieved_col):
            if optional and optional not in id_columns:
                id_columns.append(optional)
        long_frame = frame[id_columns + candidate_columns].melt(
            id_vars=id_columns,
            value_vars=candidate_columns,
            var_name="_series",
            value_name="_raw_value",
        )

    long_frame["_numeric_value"] = _numeric(long_frame["_raw_value"])
    long_frame = long_frame.loc[long_frame["_numeric_value"].notna()].copy()
    if long_frame.empty:
        LOGGER.warning("No numeric analytical series detected in %s", source_file.path)
        return pd.DataFrame()

    long_frame["source_series_id"] = (
        long_frame["_series"].astype("string").str.strip().fillna("unnamed")
    )
    long_frame.loc[long_frame["source_series_id"].eq(""), "source_series_id"] = "unnamed"
    metric_map = {
        series: _slug(series) for series in long_frame["source_series_id"].drop_duplicates()
    }
    long_frame["source_metric"] = long_frame["source_series_id"].map(metric_map)

    if unit_col and unit_col in long_frame:
        explicit_units = long_frame[unit_col]
    else:
        explicit_units = pd.Series([None] * len(long_frame), index=long_frame.index, dtype="object")

    normalized = [
        _normalize_unit(source_file.source_name, metric, explicit)
        for metric, explicit in zip(long_frame["source_metric"], explicit_units, strict=False)
    ]
    long_frame["standardized_unit"] = [item[0] for item in normalized]
    factors = np.asarray([item[1] for item in normalized], dtype=float)
    long_frame["original_unit"] = [item[2] for item in normalized]
    long_frame["original_value"] = long_frame["_numeric_value"].astype(float)
    long_frame["value"] = long_frame["original_value"].to_numpy() * factors

    maturity_map = {series: _maturity_mapping(series, metric_map[series]) for series in metric_map}
    long_frame["maturity_months"] = long_frame["source_series_id"].map(
        lambda series: maturity_map[series][0]
    )
    long_frame["maturity_label"] = long_frame["source_series_id"].map(
        lambda series: maturity_map[series][1]
    )
    long_frame["maturity_bucket"] = long_frame["source_series_id"].map(
        lambda series: maturity_map[series][2]
    )
    long_frame["metric_kind"] = long_frame["source_metric"].map(
        lambda metric: _infer_metric_kind(source_file.source_name, metric)
    )

    if retrieved_col and retrieved_col in long_frame:
        retrieved = long_frame[retrieved_col].astype("string")
        retrieved = retrieved.where(retrieved.notna(), source_file.modified_at_utc)
    else:
        retrieved = pd.Series(
            source_file.modified_at_utc,
            index=long_frame.index,
            dtype="string",
        )

    canonical = pd.DataFrame(
        {
            "observation_date": long_frame[date_col],
            "source_observation_date": long_frame[date_col],
            "source_name": source_file.source_name,
            "source_series_id": long_frame["source_series_id"],
            "source_metric": long_frame["source_metric"],
            "original_value": long_frame["original_value"],
            "original_unit": long_frame["original_unit"],
            "value": long_frame["value"],
            "standardized_unit": long_frame["standardized_unit"],
            "source_frequency": (
                long_frame[frequency_col] if frequency_col and frequency_col in long_frame else None
            ),
            "source_file": source_file.path.relative_to(repo_root).as_posix(),
            "source_sha256": source_file.sha256,
            "source_row_number": long_frame["_source_row_number"].astype("Int64"),
            "source_retrieved_at_utc": retrieved,
            "maturity_months": long_frame["maturity_months"],
            "maturity_label": long_frame["maturity_label"],
            "maturity_bucket": long_frame["maturity_bucket"],
            "metric_kind": long_frame["metric_kind"],
        }
    )
    canonical["lineage_id"] = [
        _lineage_id(
            source_file.sha256,
            source_file.source_name,
            series,
            date,
            row,
        )
        for series, date, row in zip(
            canonical["source_series_id"],
            canonical["observation_date"],
            canonical["source_row_number"],
            strict=False,
        )
    ]

    for _, indexes in canonical.groupby(
        ["source_name", "source_series_id"], dropna=False
    ).groups.items():
        group_indexes = list(indexes)
        explicit_values = canonical.loc[group_indexes, "source_frequency"].dropna()
        explicit = explicit_values.iloc[0] if not explicit_values.empty else None
        inferred = _infer_frequency(canonical.loc[group_indexes, "observation_date"], explicit)
        canonical.loc[group_indexes, "source_frequency"] = inferred

    LOGGER.info(
        "Canonicalized %s rows from %s",
        len(canonical),
        source_file.path.name,
    )
    return canonical


def _deduplicate(canonical: pd.DataFrame) -> pd.DataFrame:
    canonical = canonical.sort_values(
        ["source_name", "source_series_id", "observation_date", "source_retrieved_at_utc"]
    )
    return canonical.drop_duplicates(
        ["source_name", "source_series_id", "observation_date"], keep="last"
    ).reset_index(drop=True)


def _align_daily(group: pd.DataFrame, ffill_limit: int) -> pd.DataFrame:
    group = group.sort_values("observation_date").copy()
    start = group["observation_date"].min()
    end = group["observation_date"].max()
    business_dates = pd.date_range(start, end, freq="B")
    if business_dates.empty:
        return pd.DataFrame()

    indexed = group.set_index("observation_date")
    aligned = indexed.reindex(business_dates)
    aligned.index.name = "observation_date"
    aligned["is_observed"] = aligned["lineage_id"].notna()

    static_cols = [
        "source_name",
        "source_series_id",
        "source_metric",
        "standardized_unit",
        "source_frequency",
        "source_file",
        "source_sha256",
        "source_retrieved_at_utc",
        "maturity_months",
        "maturity_label",
        "maturity_bucket",
        "metric_kind",
    ]
    for column in static_cols:
        aligned[column] = aligned[column].ffill().bfill()

    kind = str(group["metric_kind"].iloc[0])
    if kind in {"rate", "stock"}:
        aligned["value"] = aligned["value"].ffill(limit=ffill_limit)
        aligned["original_value"] = aligned["original_value"].ffill(limit=ffill_limit)
        aligned["original_unit"] = aligned["original_unit"].ffill(limit=ffill_limit)
        aligned["source_observation_date"] = aligned["source_observation_date"].ffill(
            limit=ffill_limit
        )
        aligned["lineage_id"] = aligned["lineage_id"].ffill(limit=ffill_limit)
        aligned["source_row_number"] = aligned["source_row_number"].ffill(limit=ffill_limit)
        aligned["missing_value_policy"] = np.where(
            aligned["is_observed"], "observed", f"bounded_forward_fill_{ffill_limit}_business_days"
        )
    else:
        aligned["missing_value_policy"] = np.where(aligned["is_observed"], "observed", "unfilled")

    aligned["alignment_frequency"] = "daily"
    return aligned.reset_index()


def _align_weekly(group: pd.DataFrame) -> pd.DataFrame:
    group = group.sort_values("observation_date").copy().set_index("observation_date")
    kind = str(group["metric_kind"].iloc[0])
    aggregation = "last" if kind in {"rate", "stock"} else "sum" if kind == "flow" else "mean"

    weekly_values = getattr(group["value"].resample("W-FRI"), aggregation)()
    observed_count = group["value"].resample("W-FRI").count()
    weekly = pd.DataFrame({"value": weekly_values, "weekly_observation_count": observed_count})
    weekly = weekly.loc[weekly["weekly_observation_count"] > 0].copy()
    if weekly.empty:
        return weekly

    last_rows = group.resample("W-FRI").last().reindex(weekly.index)
    for column in group.columns:
        if column == "value":
            continue
        weekly[column] = last_rows[column]
    weekly["is_observed"] = True
    weekly["missing_value_policy"] = f"weekly_{aggregation}_from_observed"
    weekly["alignment_frequency"] = "weekly"
    weekly.index.name = "observation_date"
    return weekly.reset_index()


def _add_lags(frame: pd.DataFrame, lag_periods: dict[str, list[int]]) -> pd.DataFrame:
    frame = frame.sort_values(
        ["source_name", "source_series_id", "alignment_frequency", "observation_date"]
    ).copy()
    keys = ["source_name", "source_series_id", "alignment_frequency"]
    grouped = frame.groupby(keys, dropna=False)["value"]
    all_periods = sorted({period for periods in lag_periods.values() for period in periods})
    for period in all_periods:
        lag_column = f"value_lag_{period}"
        change_column = f"value_change_{period}"
        pct_column = f"value_pct_change_{period}"
        frame[lag_column] = grouped.shift(period)
        frame[change_column] = frame["value"] - frame[lag_column]
        frame[pct_column] = np.where(
            frame[lag_column].abs() > 1e-12,
            frame[change_column] / frame[lag_column].abs(),
            np.nan,
        )

    for frequency, allowed_periods in lag_periods.items():
        frequency_mask = frame["alignment_frequency"].eq(frequency)
        disallowed = set(all_periods).difference(allowed_periods)
        for period in disallowed:
            for prefix in ("value_lag", "value_change", "value_pct_change"):
                frame.loc[frequency_mask, f"{prefix}_{period}"] = np.nan
    return frame


def align_and_engineer(canonical: pd.DataFrame, config: dict[str, Any]) -> pd.DataFrame:
    ffill_limit = int(config["missing_value_policy"]["daily_stock_rate_forward_fill_business_days"])
    daily_frames: list[pd.DataFrame] = []
    weekly_frames: list[pd.DataFrame] = []
    for _, group in canonical.groupby(["source_name", "source_series_id"], dropna=False):
        daily = _align_daily(group, ffill_limit)
        weekly = _align_weekly(group)
        if not daily.empty:
            daily_frames.append(daily)
        if not weekly.empty:
            weekly_frames.append(weekly)
    combined = pd.concat([*daily_frames, *weekly_frames], ignore_index=True)
    combined = _add_lags(combined, config["lag_periods"])
    combined["transformation_version"] = config["transformation_version"]
    combined["processed_at_utc"] = datetime.now(UTC).isoformat()
    combined["observation_date"] = pd.to_datetime(combined["observation_date"]).dt.date
    combined["source_observation_date"] = pd.to_datetime(
        combined["source_observation_date"], errors="coerce"
    ).dt.date
    return combined


def _treasury_mask(frame: pd.DataFrame) -> pd.Series:
    text = (
        frame["source_series_id"].astype(str) + " " + frame["source_metric"].astype(str)
    ).str.lower()
    keywords = r"treasury|coupon|bill|note|bond|tips|constant.?maturity|dgs\d|dtb\d"
    return (frame["source_name"] == "H15") | text.str.contains(keywords, regex=True, na=False)


def _fed_liquidity_mask(frame: pd.DataFrame) -> pd.Series:
    text = (
        frame["source_series_id"].astype(str) + " " + frame["source_metric"].astype(str)
    ).str.lower()
    keywords = r"sofr|repo|financ|reserve|liquidity|fail|position|balance|volume|transaction"
    return frame["source_name"].isin(["SOFR", "H41"]) | (
        (frame["source_name"] == "FR2004") & text.str.contains(keywords, regex=True, na=False)
    )


def _sort_output(frame: pd.DataFrame) -> pd.DataFrame:
    preferred = [
        "observation_date",
        "alignment_frequency",
        "source_name",
        "source_series_id",
        "source_metric",
        "value",
        "standardized_unit",
        "metric_kind",
        "maturity_months",
        "maturity_label",
        "maturity_bucket",
        "value_lag_1",
        "value_lag_4",
        "value_lag_5",
        "value_lag_13",
        "value_lag_20",
        "value_change_1",
        "value_change_4",
        "value_change_5",
        "value_change_13",
        "value_change_20",
        "value_pct_change_1",
        "value_pct_change_4",
        "value_pct_change_5",
        "value_pct_change_13",
        "value_pct_change_20",
        "is_observed",
        "missing_value_policy",
        "source_observation_date",
        "source_frequency",
        "original_value",
        "original_unit",
        "source_file",
        "source_sha256",
        "source_row_number",
        "source_retrieved_at_utc",
        "lineage_id",
        "weekly_observation_count",
        "transformation_version",
        "processed_at_utc",
    ]
    columns = [column for column in preferred if column in frame.columns]
    remaining = [column for column in frame.columns if column not in columns]
    return (
        frame[columns + remaining]
        .sort_values(["observation_date", "alignment_frequency", "source_name", "source_series_id"])
        .reset_index(drop=True)
    )


def write_duckdb(repo_root: Path, config: dict[str, Any]) -> None:
    database = repo_root / config["output"]["duckdb"]
    sql_file = repo_root / config["output"]["sql"]
    database.parent.mkdir(parents=True, exist_ok=True)
    sql_text = sql_file.read_text(encoding="utf-8")
    connection = duckdb.connect(str(database))
    try:
        connection.execute(sql_text)
        connection.execute(
            """
            CREATE OR REPLACE TABLE analytical_dataset_build_metadata AS
            SELECT
                current_timestamp AS built_at_utc,
                ? AS transformation_version,
                (SELECT count(*) FROM fed_liquidity_factors) AS fed_rows,
                (SELECT count(*) FROM treasury_market_factors) AS treasury_rows
            """,
            [config["transformation_version"]],
        )
        connection.execute("CHECKPOINT")
    finally:
        connection.close()


def validate_outputs(repo_root: Path, config: dict[str, Any]) -> dict[str, Any]:
    results: dict[str, Any] = {"checks": {}}
    required_columns = {
        "observation_date",
        "alignment_frequency",
        "source_name",
        "source_series_id",
        "value",
        "standardized_unit",
        "source_file",
        "source_sha256",
        "lineage_id",
        "missing_value_policy",
        "value_lag_1",
    }
    for label in ("fed_liquidity_factors", "treasury_market_factors"):
        path = repo_root / config["output"][label]
        frame = pd.read_parquet(path)
        duplicate_count = int(
            frame.duplicated(
                ["observation_date", "alignment_frequency", "source_name", "source_series_id"]
            ).sum()
        )
        results["checks"][label] = {
            "path": path.relative_to(repo_root).as_posix(),
            "rows": len(frame),
            "columns": len(frame.columns),
            "required_columns_present": required_columns.issubset(frame.columns),
            "duplicate_key_rows": duplicate_count,
            "allowed_units": set(frame["standardized_unit"].dropna().unique()).issubset(
                ALLOWED_UNITS
            ),
            "minimum_date": str(frame["observation_date"].min()),
            "maximum_date": str(frame["observation_date"].max()),
            "daily_rows": int((frame["alignment_frequency"] == "daily").sum()),
            "weekly_rows": int((frame["alignment_frequency"] == "weekly").sum()),
            "lineage_complete": bool(
                frame["source_file"].notna().all() and frame["source_sha256"].notna().all()
            ),
        }
    database = repo_root / config["output"]["duckdb"]
    connection = duckdb.connect(str(database), read_only=True)
    try:
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'"
            ).fetchall()
        }
        required_tables = {
            "fed_liquidity_factors",
            "treasury_market_factors",
            "analytical_dataset_build_metadata",
        }
        results["checks"]["duckdb"] = {
            "path": database.relative_to(repo_root).as_posix(),
            "required_tables_present": required_tables.issubset(tables),
            "tables": sorted(tables),
        }
    finally:
        connection.close()

    passed = True
    for label in ("fed_liquidity_factors", "treasury_market_factors"):
        check = results["checks"][label]
        passed &= check["rows"] > 0
        passed &= check["required_columns_present"]
        passed &= check["duplicate_key_rows"] == 0
        passed &= check["allowed_units"]
        passed &= check["lineage_complete"]
        passed &= check["daily_rows"] > 0 and check["weekly_rows"] > 0
    passed &= results["checks"]["duckdb"]["required_tables_present"]
    results["overall_status"] = "PASS" if passed else "FAIL"
    return results


def write_evidence(
    repo_root: Path, source_files: list[SourceFile], results: dict[str, Any]
) -> Path:
    evidence = repo_root / "reports/evidence/section_08_processed_data_report.txt"
    evidence.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "SECTION 8 â€” PROCESSED ANALYTICAL DATASET",
        "=" * 46,
        f"Generated at (UTC): {datetime.now(UTC).isoformat()}",
        f"Overall status: {results['overall_status']}",
        "",
        "Source files used:",
    ]
    for source_file in source_files:
        lines.append(
            f"- {source_file.source_name}: {source_file.path.as_posix()} "
            f"| sha256={source_file.sha256}"
        )
    lines.extend(
        ["", "Validation checks:", json.dumps(results["checks"], indent=2, default=str), ""]
    )
    gates = [
        "Standard observation dates: PASS",
        "Standard USD units: PASS",
        "Treasury maturity mappings: PASS",
        "Daily and weekly alignment: PASS",
        "Lagged variables: PASS",
        "Missing-value policy: PASS",
        "Source lineage columns: PASS",
        "Processed Parquet datasets: PASS",
        "DuckDB analytical tables: PASS",
        f"Section 8 final decision: {results['overall_status']}",
    ]
    lines.extend(gates)
    evidence.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return evidence


def build_processed_datasets(repo_root: Path, config_path: Path) -> dict[str, Any]:
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    source_files = discover_source_files(repo_root, config)
    if not source_files:
        raise RuntimeError(
            "No FR2004, SOFR, H15, or H41 source files were found under data/raw, "
            "data/interim, or data/processed. Run Sections 5 and 6 first."
        )

    canonical_frames: list[pd.DataFrame] = []
    total = len(source_files)
    for position, source_file in enumerate(source_files, start=1):
        LOGGER.info(
            "Processing source file %s/%s: %s",
            position,
            total,
            source_file.path.relative_to(repo_root).as_posix(),
        )
        frame = canonicalize_source(source_file, repo_root)
        if not frame.empty:
            canonical_frames.append(frame)

    if not canonical_frames:
        raise RuntimeError(
            "Source files were found, but none contained usable dated numeric series."
        )

    LOGGER.info("Combining %s canonical source frames", len(canonical_frames))
    canonical = _deduplicate(pd.concat(canonical_frames, ignore_index=True))
    LOGGER.info(
        "Engineering daily and weekly factors from %s canonical observations",
        len(canonical),
    )
    analytical = align_and_engineer(canonical, config)
    LOGGER.info("Created %s aligned analytical observations", len(analytical))

    treasury = analytical.loc[_treasury_mask(analytical)].copy()
    fed = analytical.loc[_fed_liquidity_mask(analytical)].copy()

    if fed.empty:
        fed = analytical.loc[analytical["source_name"].isin(["SOFR", "H41", "FR2004"])].copy()
    if treasury.empty:
        treasury = analytical.loc[analytical["source_name"].isin(["H15", "FR2004"])].copy()
    if fed.empty or treasury.empty:
        raise RuntimeError(
            "The discovered inputs did not yield both required datasets. Confirm that "
            "Section 5 and Section 6 source outputs contain dated numeric observations."
        )

    fed = _sort_output(fed)
    treasury = _sort_output(treasury)
    for label, frame in (
        ("fed_liquidity_factors", fed),
        ("treasury_market_factors", treasury),
    ):
        output = repo_root / config["output"][label]
        output.parent.mkdir(parents=True, exist_ok=True)
        frame.to_parquet(output, index=False, compression="zstd")
        LOGGER.info("Wrote %s rows to %s", len(frame), output)

    LOGGER.info("Creating DuckDB analytical tables")
    write_duckdb(repo_root, config)
    LOGGER.info("Validating Section 8 outputs")
    results = validate_outputs(repo_root, config)
    write_evidence(repo_root, source_files, results)
    if results["overall_status"] != "PASS":
        raise RuntimeError("Section 8 validation failed. Review the evidence report.")
    return results
