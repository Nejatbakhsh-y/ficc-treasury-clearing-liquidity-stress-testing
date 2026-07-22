"""Baseline liquidity cash-flow engine for fictional clearing members.

The engine models unstressed, time-bucketed liquidity cash flows. It operates
only on synthetic member records and does not represent actual FICC participants.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class BaselineLiquidityError(ValueError):
    """Raised when baseline-liquidity inputs or assumptions are invalid."""


@dataclass(frozen=True, slots=True)
class TimeBucket:
    """One ordered payment-timing bucket in the liquidity horizon."""

    name: str
    elapsed_hours: int


@dataclass(frozen=True, slots=True)
class BaselineSettings:
    """Validated assumptions for the baseline cash-flow engine."""

    model_version: str
    horizon_hours: int
    buckets: tuple[TimeBucket, ...]
    settlement_schedule: Mapping[str, float]
    repo_maturity_schedule: Mapping[str, float]
    financing_inflow_schedule: Mapping[str, float]
    collateral_availability_schedule: Mapping[str, float]
    settlement_netting_rate: float
    repo_roll_rate: float
    reverse_repo_inflow_recognition_rate: float
    financing_netting_enabled: bool
    available_cash_share_of_aqlr: float
    collateral_haircut: float
    collateral_operational_availability_rate: float
    tolerance_usd: float
    member_id_column: str
    synthetic_id_pattern: str


@dataclass(frozen=True, slots=True)
class ValidationResult:
    """Structured Section 14 validation result."""

    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return true only when every validation check passes."""
        return all(self.checks.values())


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise BaselineLiquidityError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise BaselineLiquidityError(f"{key} must be numeric.")
    return float(value)


def _boolean(mapping: Mapping[str, Any], key: str) -> bool:
    value = mapping.get(key)
    if not isinstance(value, bool):
        raise BaselineLiquidityError(f"{key} must be true or false.")
    return value


def load_config(path: str | Path) -> dict[str, Any]:
    """Load a controlled YAML configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise BaselineLiquidityError(f"Configuration does not exist: {config_path}")
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def _schedule(
    payment_timing: Mapping[str, Any],
    key: str,
    bucket_names: Sequence[str],
) -> dict[str, float]:
    raw = _mapping(payment_timing.get(key), f"payment_timing.{key}")
    actual_names = set(str(name) for name in raw)
    expected_names = set(bucket_names)
    if actual_names != expected_names:
        missing = sorted(expected_names - actual_names)
        extra = sorted(actual_names - expected_names)
        raise BaselineLiquidityError(
            f"payment_timing.{key} must define every bucket exactly once; "
            f"missing={missing}, extra={extra}."
        )
    schedule = {name: float(raw[name]) for name in bucket_names}
    if any(not math.isfinite(value) or value < 0.0 for value in schedule.values()):
        raise BaselineLiquidityError(f"payment_timing.{key} contains invalid weights.")
    if not math.isclose(sum(schedule.values()), 1.0, abs_tol=1e-12):
        raise BaselineLiquidityError(f"payment_timing.{key} weights must sum to one.")
    return schedule


def load_settings(config: Mapping[str, Any]) -> BaselineSettings:
    """Validate and convert the baseline-liquidity configuration."""
    source = _mapping(config.get("source"), "source")
    horizon = _mapping(config.get("liquidity_horizon"), "liquidity_horizon")
    payment_timing = _mapping(config.get("payment_timing"), "payment_timing")
    assumptions = _mapping(config.get("assumptions"), "assumptions")
    validation = _mapping(config.get("validation"), "validation")

    raw_buckets = horizon.get("buckets")
    if not isinstance(raw_buckets, list) or not raw_buckets:
        raise BaselineLiquidityError("liquidity_horizon.buckets must be a nonempty list.")

    buckets: list[TimeBucket] = []
    names: set[str] = set()
    previous_hour = -1
    for raw_bucket in raw_buckets:
        bucket = _mapping(raw_bucket, "liquidity_horizon bucket")
        name = str(bucket.get("name", "")).strip()
        elapsed_hours = int(bucket.get("elapsed_hours", -1))
        if not name or name in names:
            raise BaselineLiquidityError(
                "Liquidity-horizon bucket names must be unique and nonempty."
            )
        if elapsed_hours < 0 or elapsed_hours <= previous_hour:
            raise BaselineLiquidityError(
                "Liquidity-horizon bucket hours must be strictly increasing."
            )
        names.add(name)
        previous_hour = elapsed_hours
        buckets.append(TimeBucket(name=name, elapsed_hours=elapsed_hours))

    horizon_hours = int(horizon.get("hours", 0))
    if horizon_hours <= 0 or buckets[-1].elapsed_hours > horizon_hours:
        raise BaselineLiquidityError(
            "liquidity_horizon.hours must be positive and cover the final time bucket."
        )

    bucket_names = [bucket.name for bucket in buckets]
    settings = BaselineSettings(
        model_version=str(config.get("model_version", "section-14-v1")),
        horizon_hours=horizon_hours,
        buckets=tuple(buckets),
        settlement_schedule=_schedule(payment_timing, "settlement_obligations", bucket_names),
        repo_maturity_schedule=_schedule(payment_timing, "repo_maturities", bucket_names),
        financing_inflow_schedule=_schedule(payment_timing, "financing_inflows", bucket_names),
        collateral_availability_schedule=_schedule(
            payment_timing,
            "eligible_collateral_availability",
            bucket_names,
        ),
        settlement_netting_rate=_number(assumptions, "settlement_netting_rate"),
        repo_roll_rate=_number(assumptions, "repo_roll_rate"),
        reverse_repo_inflow_recognition_rate=_number(
            assumptions,
            "reverse_repo_inflow_recognition_rate",
        ),
        financing_netting_enabled=_boolean(assumptions, "financing_netting_enabled"),
        available_cash_share_of_aqlr=_number(
            assumptions,
            "available_cash_share_of_aqlr",
        ),
        collateral_haircut=_number(assumptions, "eligible_collateral_haircut"),
        collateral_operational_availability_rate=_number(
            assumptions,
            "collateral_operational_availability_rate",
        ),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        member_id_column=str(source.get("member_id_column", "member_id")),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
    )

    bounded = {
        "settlement_netting_rate": settings.settlement_netting_rate,
        "repo_roll_rate": settings.repo_roll_rate,
        "reverse_repo_inflow_recognition_rate": settings.reverse_repo_inflow_recognition_rate,
        "available_cash_share_of_aqlr": settings.available_cash_share_of_aqlr,
        "eligible_collateral_haircut": settings.collateral_haircut,
        "collateral_operational_availability_rate": (
            settings.collateral_operational_availability_rate
        ),
    }
    for label, value in bounded.items():
        if not 0.0 <= value <= 1.0:
            raise BaselineLiquidityError(f"{label} must be between zero and one.")
    if settings.collateral_haircut >= 1.0:
        raise BaselineLiquidityError("eligible_collateral_haircut must be less than one.")
    if settings.tolerance_usd < 0.0:
        raise BaselineLiquidityError("reconciliation_tolerance_usd must be nonnegative.")
    if not settings.model_version.strip():
        raise BaselineLiquidityError("model_version must be populated.")
    return settings


def read_member_data(path: str | Path) -> pd.DataFrame:
    """Read synthetic member portfolios from CSV or Parquet."""
    data_path = Path(path)
    if not data_path.exists():
        raise BaselineLiquidityError(f"Synthetic member portfolios do not exist: {data_path}")
    if data_path.suffix.lower() == ".csv":
        return pd.read_csv(data_path)
    if data_path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(data_path)
    raise BaselineLiquidityError("Synthetic member portfolios must be CSV or Parquet.")


def prepare_members(members: pd.DataFrame, settings: BaselineSettings) -> pd.DataFrame:
    """Canonicalize and validate synthetic member inputs."""
    if members.empty:
        raise BaselineLiquidityError("Synthetic member portfolio dataset is empty.")
    frame = members.copy(deep=True)
    if settings.member_id_column not in frame.columns:
        raise BaselineLiquidityError(
            f"Configured member identifier column is missing: {settings.member_id_column}"
        )
    if settings.member_id_column != "member_id":
        frame = frame.rename(columns={settings.member_id_column: "member_id"})

    required = {
        "member_id",
        "settlement_obligation_usd",
        "repo_financing_need_usd",
        "reverse_repo_position_usd",
        "collateral_inventory_usd",
        "available_qualified_liquid_resources_usd",
    }
    missing = sorted(required - set(frame.columns))
    if missing:
        raise BaselineLiquidityError(f"Required synthetic member columns are missing: {missing}")

    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    if frame["member_id"].isna().any() or frame["member_id"].duplicated().any():
        raise BaselineLiquidityError("Synthetic member identifiers must be unique and nonmissing.")
    invalid_ids = [
        member_id
        for member_id in frame["member_id"].astype(str)
        if re.fullmatch(settings.synthetic_id_pattern, member_id) is None
    ]
    if invalid_ids:
        raise BaselineLiquidityError(
            f"Non-synthetic or invalid member identifiers detected: {sorted(invalid_ids)}"
        )

    if (
        "actual_ficc_participant" in frame.columns
        and frame["actual_ficc_participant"].fillna(False).astype(bool).any()
    ):
        raise BaselineLiquidityError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise BaselineLiquidityError("Participant-level inference records are prohibited.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise BaselineLiquidityError("Every input record must use value_class='synthetic'.")

    monetary_columns = sorted(required - {"member_id"})
    for column in monetary_columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise BaselineLiquidityError(f"{column} contains missing or nonfinite values.")
        if (frame[column] < 0.0).any():
            raise BaselineLiquidityError(f"{column} contains negative values.")

    if (frame["reverse_repo_position_usd"] > frame["repo_financing_need_usd"]).any():
        raise BaselineLiquidityError("Reverse-repo positions exceed repo financing needs.")
    if (
        frame["available_qualified_liquid_resources_usd"] > frame["collateral_inventory_usd"]
    ).any():
        raise BaselineLiquidityError(
            "Available qualified liquid resources exceed collateral inventory."
        )

    if "as_of_date" not in frame.columns:
        frame["as_of_date"] = pd.NaT
    else:
        frame["as_of_date"] = pd.to_datetime(frame["as_of_date"], errors="coerce")

    frame["value_class"] = "synthetic"
    frame["actual_ficc_participant"] = False
    frame["participant_level_inference"] = False
    return frame.sort_values("member_id", kind="stable").reset_index(drop=True)


def _resource_decomposition(
    member: pd.Series,
    settings: BaselineSettings,
) -> tuple[float, float, float, float]:
    source_aqlr = float(member["available_qualified_liquid_resources_usd"])
    collateral_inventory = float(member["collateral_inventory_usd"])
    available_cash = source_aqlr * settings.available_cash_share_of_aqlr
    remaining_post_haircut = max(source_aqlr - available_cash, 0.0)
    operational_collateral = (
        collateral_inventory * settings.collateral_operational_availability_rate
    )
    gross_needed = remaining_post_haircut / (1.0 - settings.collateral_haircut)
    eligible_collateral_market_value = min(operational_collateral, gross_needed)
    eligible_collateral_liquidity = eligible_collateral_market_value * (
        1.0 - settings.collateral_haircut
    )
    modeled_aqlr = available_cash + eligible_collateral_liquidity
    return (
        available_cash,
        eligible_collateral_market_value,
        eligible_collateral_liquidity,
        modeled_aqlr,
    )


def calculate_cashflows(
    members: pd.DataFrame,
    settings: BaselineSettings,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Calculate time-bucketed baseline cash flows and member summaries."""
    frame = prepare_members(members, settings)
    cashflow_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []

    for _, member in frame.iterrows():
        member_id = str(member["member_id"])
        available_cash, collateral_mv, collateral_liquidity, modeled_aqlr = _resource_decomposition(
            member, settings
        )
        cumulative_need = 0.0
        cumulative_collateral = 0.0
        member_rows: list[dict[str, object]] = []

        for bucket_order, bucket in enumerate(settings.buckets, start=1):
            settlement_gross = float(member["settlement_obligation_usd"]) * float(
                settings.settlement_schedule[bucket.name]
            )
            settlement_netting_benefit = settlement_gross * settings.settlement_netting_rate
            settlement_net = settlement_gross - settlement_netting_benefit

            repo_maturity = float(member["repo_financing_need_usd"]) * float(
                settings.repo_maturity_schedule[bucket.name]
            )
            repo_roll_amount = repo_maturity * settings.repo_roll_rate
            financing_outflow = repo_maturity - repo_roll_amount
            financing_inflow = (
                float(member["reverse_repo_position_usd"])
                * settings.reverse_repo_inflow_recognition_rate
                * float(settings.financing_inflow_schedule[bucket.name])
            )

            if settings.financing_netting_enabled:
                net_financing_outflow = max(financing_outflow - financing_inflow, 0.0)
                recognized_financing_inflow = max(financing_inflow - financing_outflow, 0.0)
            else:
                net_financing_outflow = financing_outflow
                recognized_financing_inflow = financing_inflow

            total_outflow = settlement_net + net_financing_outflow
            total_inflow = recognized_financing_inflow
            net_cash_flow = total_inflow - total_outflow
            cumulative_need = max(cumulative_need + total_outflow - total_inflow, 0.0)

            incremental_collateral = collateral_liquidity * float(
                settings.collateral_availability_schedule[bucket.name]
            )
            cumulative_collateral += incremental_collateral
            cumulative_resources = available_cash + cumulative_collateral
            headroom = cumulative_resources - cumulative_need
            shortfall = max(-headroom, 0.0)

            row: dict[str, object] = {
                "member_id": member_id,
                "as_of_date": member["as_of_date"],
                "bucket_order": bucket_order,
                "time_bucket": bucket.name,
                "elapsed_hours": bucket.elapsed_hours,
                "liquidity_horizon_hours": settings.horizon_hours,
                "gross_settlement_obligation_usd": settlement_gross,
                "settlement_netting_benefit_usd": settlement_netting_benefit,
                "net_settlement_outflow_usd": settlement_net,
                "repo_maturity_usd": repo_maturity,
                "repo_roll_amount_usd": repo_roll_amount,
                "financing_outflow_usd": financing_outflow,
                "financing_inflow_usd": financing_inflow,
                "net_financing_outflow_usd": net_financing_outflow,
                "recognized_financing_inflow_usd": recognized_financing_inflow,
                "total_cash_outflow_usd": total_outflow,
                "total_cash_inflow_usd": total_inflow,
                "net_cash_flow_usd": net_cash_flow,
                "cumulative_net_liquidity_need_usd": cumulative_need,
                "available_cash_usd": available_cash,
                "eligible_collateral_market_value_usd": collateral_mv,
                "incremental_eligible_collateral_liquidity_usd": incremental_collateral,
                "eligible_collateral_liquidity_usd": collateral_liquidity,
                "cumulative_available_resources_usd": cumulative_resources,
                "liquidity_headroom_usd": headroom,
                "liquidity_shortfall_usd": shortfall,
                "source_aqlr_usd": float(member["available_qualified_liquid_resources_usd"]),
                "modeled_aqlr_usd": modeled_aqlr,
                "settlement_netting_rate": settings.settlement_netting_rate,
                "repo_roll_rate": settings.repo_roll_rate,
                "financing_netting_enabled": settings.financing_netting_enabled,
                "model_version": settings.model_version,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
            member_rows.append(row)
            cashflow_rows.append(row)

        member_frame = pd.DataFrame.from_records(member_rows)
        peak_need = float(member_frame["cumulative_net_liquidity_need_usd"].max())
        minimum_headroom = float(member_frame["liquidity_headroom_usd"].min())
        maximum_shortfall = float(member_frame["liquidity_shortfall_usd"].max())
        first_shortfall = member_frame.loc[
            member_frame["liquidity_shortfall_usd"] > settings.tolerance_usd,
            "time_bucket",
        ]
        coverage_ratio = modeled_aqlr / max(peak_need, 0.01)
        summary_rows.append(
            {
                "member_id": member_id,
                "as_of_date": member["as_of_date"],
                "liquidity_horizon_hours": settings.horizon_hours,
                "gross_settlement_obligation_usd": float(
                    member_frame["gross_settlement_obligation_usd"].sum()
                ),
                "net_settlement_outflow_usd": float(
                    member_frame["net_settlement_outflow_usd"].sum()
                ),
                "repo_maturity_usd": float(member_frame["repo_maturity_usd"].sum()),
                "financing_outflow_usd": float(member_frame["financing_outflow_usd"].sum()),
                "financing_inflow_usd": float(member_frame["financing_inflow_usd"].sum()),
                "available_cash_usd": available_cash,
                "eligible_collateral_market_value_usd": collateral_mv,
                "eligible_collateral_liquidity_usd": collateral_liquidity,
                "source_aqlr_usd": float(member["available_qualified_liquid_resources_usd"]),
                "modeled_aqlr_usd": modeled_aqlr,
                "peak_liquidity_need_usd": peak_need,
                "minimum_liquidity_headroom_usd": minimum_headroom,
                "maximum_liquidity_shortfall_usd": maximum_shortfall,
                "liquidity_coverage_ratio": coverage_ratio,
                "first_shortfall_bucket": (
                    str(first_shortfall.iloc[0]) if not first_shortfall.empty else ""
                ),
                "baseline_liquidity_status": (
                    "COVERED" if maximum_shortfall <= settings.tolerance_usd else "SHORTFALL"
                ),
                "model_version": settings.model_version,
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )

    cashflows = (
        pd.DataFrame.from_records(cashflow_rows)
        .sort_values(
            ["member_id", "bucket_order"],
            kind="stable",
        )
        .reset_index(drop=True)
    )
    summary = (
        pd.DataFrame.from_records(summary_rows)
        .sort_values(
            "member_id",
            kind="stable",
        )
        .reset_index(drop=True)
    )
    return cashflows, summary


def _within_tolerance(left: pd.Series, right: pd.Series, tolerance: float) -> bool:
    differences = (pd.to_numeric(left) - pd.to_numeric(right)).abs()
    return bool((differences <= tolerance).all())


def validate_results(
    members: pd.DataFrame,
    cashflows: pd.DataFrame,
    summary: pd.DataFrame,
    settings: BaselineSettings,
) -> ValidationResult:
    """Validate Section 14 accounting, timing, resource, and identity controls."""
    source = prepare_members(members, settings).set_index("member_id")
    summary_indexed = summary.set_index("member_id")
    grouped = cashflows.groupby("member_id", sort=True)

    member_bucket_complete = len(cashflows) == len(source) * len(settings.buckets)
    unique_member_bucket = not cashflows.duplicated(["member_id", "time_bucket"]).any()
    horizon_ordered = bool(
        grouped["elapsed_hours"].apply(lambda values: values.is_monotonic_increasing).all()
    )

    settlement_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "gross_settlement_obligation_usd"],
        source["settlement_obligation_usd"],
        settings.tolerance_usd,
    )
    repo_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "repo_maturity_usd"],
        source["repo_financing_need_usd"],
        settings.tolerance_usd,
    )
    expected_financing_inflow = (
        source["reverse_repo_position_usd"] * settings.reverse_repo_inflow_recognition_rate
    )
    financing_inflow_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "financing_inflow_usd"],
        expected_financing_inflow,
        settings.tolerance_usd,
    )
    expected_financing_outflow = source["repo_financing_need_usd"] * (1.0 - settings.repo_roll_rate)
    financing_outflow_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "financing_outflow_usd"],
        expected_financing_outflow,
        settings.tolerance_usd,
    )
    aqlr_reconciliation = _within_tolerance(
        summary_indexed.loc[source.index, "modeled_aqlr_usd"],
        source["available_qualified_liquid_resources_usd"],
        settings.tolerance_usd,
    )

    nonnegative_columns = [
        column
        for column in cashflows.columns
        if column.endswith("_usd") and column not in {"net_cash_flow_usd", "liquidity_headroom_usd"}
    ]
    nonnegative_cashflow_components = bool(
        (cashflows[nonnegative_columns] >= -settings.tolerance_usd).all().all()
    )
    synthetic_only = bool(
        cashflows["value_class"].eq("synthetic").all()
        and not cashflows["actual_ficc_participant"].astype(bool).any()
        and not cashflows["participant_level_inference"].astype(bool).any()
        and summary["value_class"].eq("synthetic").all()
        and not summary["actual_ficc_participant"].astype(bool).any()
        and not summary["participant_level_inference"].astype(bool).any()
    )
    shortfall_identity = bool(
        (
            cashflows["liquidity_shortfall_usd"]
            - (-cashflows["liquidity_headroom_usd"]).clip(lower=0.0)
        )
        .abs()
        .le(settings.tolerance_usd)
        .all()
    )
    resource_timing_reconciliation = bool(
        grouped["incremental_eligible_collateral_liquidity_usd"]
        .sum()
        .sort_index()
        .sub(summary_indexed["eligible_collateral_liquidity_usd"].sort_index())
        .abs()
        .le(settings.tolerance_usd)
        .all()
    )

    checks = {
        "member_bucket_completeness": member_bucket_complete,
        "unique_member_time_buckets": unique_member_bucket,
        "payment_timing_is_ordered": horizon_ordered,
        "settlement_obligations_reconcile": settlement_reconciliation,
        "repo_maturities_reconcile": repo_reconciliation,
        "financing_inflows_reconcile": financing_inflow_reconciliation,
        "financing_outflows_reconcile": financing_outflow_reconciliation,
        "available_qualified_liquid_resources_reconcile": aqlr_reconciliation,
        "eligible_collateral_timing_reconciles": resource_timing_reconciliation,
        "nonnegative_cashflow_components": nonnegative_cashflow_components,
        "liquidity_shortfall_identity": shortfall_identity,
        "synthetic_members_only": synthetic_only,
    }
    return ValidationResult(checks=checks)


def run_engine(
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> tuple[pd.DataFrame, pd.DataFrame, ValidationResult]:
    """Run the deterministic baseline engine and validate outputs."""
    settings = load_settings(config)
    cashflows, summary = calculate_cashflows(members, settings)
    validation = validate_results(members, cashflows, summary, settings)

    shuffled = members.sample(frac=1.0, random_state=2026).reset_index(drop=True)
    repeated_cashflows, repeated_summary = calculate_cashflows(shuffled, settings)
    deterministic = cashflows.equals(repeated_cashflows) and summary.equals(repeated_summary)
    checks = dict(validation.checks)
    checks["deterministic_reproduction"] = deterministic
    return cashflows, summary, ValidationResult(checks=checks)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_frame(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix.lower() == ".csv":
        frame.to_csv(path, index=False)
    elif path.suffix.lower() in {".parquet", ".pq"}:
        frame.to_parquet(path, index=False)
    else:
        raise BaselineLiquidityError("Output paths must use .csv or .parquet.")


def write_outputs(
    cashflows: pd.DataFrame,
    summary: pd.DataFrame,
    validation: ValidationResult,
    *,
    source_path: Path,
    config_path: Path,
    cashflow_path: Path,
    summary_path: Path,
    manifest_path: Path,
    evidence_path: Path,
) -> None:
    """Write controlled model outputs, lineage manifest, and evidence."""
    _write_frame(cashflows, cashflow_path)
    _write_frame(summary, summary_path)

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = pd.DataFrame(
        [
            {
                "dataset": "baseline_liquidity_cashflows",
                "value_class": "modeled_from_synthetic_inputs",
                "source_file": source_path.as_posix(),
                "source_sha256": _sha256(source_path),
                "config_file": config_path.as_posix(),
                "config_sha256": _sha256(config_path),
                "cashflow_file": cashflow_path.as_posix(),
                "cashflow_sha256": _sha256(cashflow_path),
                "summary_file": summary_path.as_posix(),
                "summary_sha256": _sha256(summary_path),
                "cashflow_row_count": len(cashflows),
                "summary_row_count": len(summary),
                "actual_ficc_participants": False,
                "participant_level_inference": False,
                "generated_at_utc": datetime.now(UTC).isoformat(),
                "gate_status": "PASS" if validation.passed else "FAIL",
            }
        ]
    )
    manifest.to_csv(manifest_path, index=False)

    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "PHASE V â€” SECTION 14: BASELINE LIQUIDITY CASH-FLOW ENGINE",
        "=" * 74,
        f"Generated at UTC: {datetime.now(UTC).isoformat()}",
        f"Source synthetic portfolio: {source_path.as_posix()}",
        f"Configuration: {config_path.as_posix()}",
        f"Synthetic members: {summary['member_id'].nunique()}",
        f"Cash-flow rows: {len(cashflows)}",
        f"Liquidity horizon hours: {int(cashflows['liquidity_horizon_hours'].iloc[0])}",
        "Actual FICC participants represented: NO",
        "Participant-level inference performed: NO",
        "",
        "CONTROL RESULTS",
    ]
    for name, passed in validation.checks.items():
        lines.append(f"{name}: {'PASS' if passed else 'FAIL'}")
    lines.extend(
        [
            "",
            f"Members with baseline shortfall: "
            f"{int(summary['baseline_liquidity_status'].eq('SHORTFALL').sum())}",
            f"Maximum baseline shortfall USD: "
            f"{float(summary['maximum_liquidity_shortfall_usd'].max()):.2f}",
            "",
            "Section 14 final decision: " + ("PASS" if validation.passed else "FAIL"),
        ]
    )
    evidence_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    """Build the Section 14 command-line interface."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--members",
        type=Path,
        default=Path("data/synthetic/calibrated_member_portfolios.parquet"),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/baseline_liquidity.yaml"),
    )
    parser.add_argument(
        "--cashflows",
        type=Path,
        default=Path("reports/tables/baseline_liquidity_cashflows.csv"),
    )
    parser.add_argument(
        "--summary",
        type=Path,
        default=Path("reports/tables/baseline_liquidity_summary.csv"),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("data/manifests/baseline_liquidity_manifest.csv"),
    )
    parser.add_argument(
        "--evidence",
        type=Path,
        default=Path("reports/evidence/section14_baseline_liquidity_validation.txt"),
    )
    return parser


def main() -> int:
    """Run the Section 14 command-line workflow."""
    args = build_parser().parse_args()
    config = load_config(args.config)
    members = read_member_data(args.members)
    cashflows, summary, validation = run_engine(members, config)
    write_outputs(
        cashflows,
        summary,
        validation,
        source_path=args.members,
        config_path=args.config,
        cashflow_path=args.cashflows,
        summary_path=args.summary,
        manifest_path=args.manifest,
        evidence_path=args.evidence,
    )
    print(json.dumps({"checks": validation.checks, "passed": validation.passed}, indent=2))
    return 0 if validation.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
