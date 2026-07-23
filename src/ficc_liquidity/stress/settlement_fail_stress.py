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
        additional_fails_to_receive_rate=_number(raw, "additional_fails_to_receive_rate"),
        additional_fails_to_deliver_rate=_number(raw, "additional_fails_to_deliver_rate"),
        incoming_payment_delay_buckets=_integer(raw, "incoming_payment_delay_buckets"),
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
        raise SettlementFailStressError("fails_to_receive_multiplier must be nonnegative.")
    if scenario.fails_to_deliver_multiplier < 0.0:
        raise SettlementFailStressError("fails_to_deliver_multiplier must be nonnegative.")
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
        raise SettlementFailStressError("incoming_payment_delay_buckets must be nonnegative.")
    if scenario.replacement_liquidity_rate < 0.0:
        raise SettlementFailStressError("replacement_liquidity_rate must be nonnegative.")
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
        incoming_settlement_receipt_ratio=_number(assumptions, "incoming_settlement_receipt_ratio"),
        persistence_liquidity_rate=_number(assumptions, "persistence_liquidity_rate"),
        fail_penalty_rate_per_day=_number(assumptions, "fail_penalty_rate_per_day"),
        tolerance_usd=_number(validation, "reconciliation_tolerance_usd"),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
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
        raise SettlementFailStressError("fail_penalty_rate_per_day must be nonnegative.")
    if settings.tolerance_usd < 0.0:
        raise SettlementFailStressError("reconciliation_tolerance_usd must be nonnegative.")

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
        raise SettlementFailStressError("Synthetic member identifiers cannot be missing.")
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
        raise SettlementFailStressError("Actual FICC participant records are prohibited.")
    if (
        "participant_level_inference" in frame.columns
        and frame["participant_level_inference"].fillna(False).astype(bool).any()
    ):
        raise SettlementFailStressError("Participant-level inference records are prohibited.")
    if (
        "value_class" in frame.columns
        and not frame["value_class"].astype(str).eq("synthetic").all()
    ):
        raise SettlementFailStressError("Every member record must use value_class='synthetic'.")


def _numeric(frame: pd.DataFrame, columns: list[str], *, nonnegative: bool) -> None:
    for column in columns:
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
        if frame[column].isna().any() or (~frame[column].map(math.isfinite)).any():
            raise SettlementFailStressError(f"{column} contains missing or nonfinite values.")
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
        raise SettlementFailStressError(f"Required synthetic-member fields are missing: {missing}")
    frame = members.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame["member_id"].duplicated().any():
        raise SettlementFailStressError("Synthetic member identifiers must be unique.")
    _numeric(
        frame,
        ["settlement_obligation_usd", "settlement_fail_usd"],
        nonnegative=True,
    )
    if (frame["settlement_obligation_usd"] <= 0.0).any():
        raise SettlementFailStressError("settlement_obligation_usd must be positive.")
    if (frame["settlement_fail_usd"] > frame["settlement_obligation_usd"]).any():
        raise SettlementFailStressError("Settlement fails cannot exceed settlement obligations.")
    computed_rate = frame["settlement_fail_usd"] / frame["settlement_obligation_usd"]
    if "settlement_fail_rate" in frame.columns:
        _numeric(frame, ["settlement_fail_rate"], nonnegative=True)
        if (frame["settlement_fail_rate"] > 1.0).any():
            raise SettlementFailStressError("settlement_fail_rate must be between zero and one.")
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
        raise SettlementFailStressError(f"Required baseline fields are missing: {missing}")
    frame = baseline.copy(deep=True)
    frame["member_id"] = frame["member_id"].astype("string").str.strip()
    _validate_synthetic_identity(frame, settings.synthetic_id_pattern)
    if frame.duplicated(["member_id", "time_bucket"]).any():
        raise SettlementFailStressError(
            "Baseline member and time-bucket combinations must be unique."
        )
    numeric_columns = sorted(required - {"member_id", "time_bucket"})
    _numeric(frame, numeric_columns, nonnegative=True)
    if not frame["liquidity_horizon_hours"].eq(settings.liquidity_horizon_hours).all():
        raise SettlementFailStressError(
            "Baseline liquidity horizon does not match Section 18 configuration."
        )
    ordered = frame.sort_values(["member_id", "bucket_order"], kind="stable").reset_index(drop=True)
    if (
        not ordered.groupby("member_id")["elapsed_hours"]
        .apply(lambda values: values.is_monotonic_increasing)
        .all()
    ):
        raise SettlementFailStressError("Baseline time buckets must be chronologically ordered.")
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

    member_gross = frame.groupby("member_id")["gross_settlement_obligation_usd"].transform("sum")
    if (member_gross <= 0.0).any():
        raise SettlementFailStressError(
            "Every baseline member requires positive gross settlement obligations."
        )
    frame["settlement_bucket_weight"] = frame["gross_settlement_obligation_usd"] / member_gross
    frame["expected_incoming_settlement_payment_usd"] = (
        frame["gross_settlement_obligation_usd"] * settings.incoming_settlement_receipt_ratio
    )
    frame["base_fails_to_receive_bucket_usd"] = (
        frame["base_fails_to_receive_usd"] * frame["settlement_bucket_weight"]
    )
    frame["base_fails_to_deliver_bucket_usd"] = (
        frame["base_fails_to_deliver_usd"] * frame["settlement_bucket_weight"]
    )
    frame["fails_to_receive_usd"] = (
        frame["base_fails_to_receive_bucket_usd"] * scenario.fails_to_receive_multiplier
        + frame["expected_incoming_settlement_payment_usd"]
        * scenario.additional_fails_to_receive_rate
    ).clip(upper=frame["expected_incoming_settlement_payment_usd"])
    frame["fails_to_deliver_usd"] = (
        frame["base_fails_to_deliver_bucket_usd"] * scenario.fails_to_deliver_multiplier
        + frame["gross_settlement_obligation_usd"] * scenario.additional_fails_to_deliver_rate
    ).clip(upper=frame["gross_settlement_obligation_usd"])

    frame["delayed_incoming_payment_outflow_usd"] = frame["fails_to_receive_usd"]
    frame["delayed_incoming_payment_recovery_usd"] = 0.0
    delay = scenario.incoming_payment_delay_buckets
    if delay == 0:
        frame["delayed_incoming_payment_recovery_usd"] = frame["fails_to_receive_usd"]
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
        frame["section16_incremental_funding_outflow_usd"] * scenario.funding_stress_weight
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
        frame["total_cash_outflow_usd"] + frame["incremental_combined_stress_outflow_usd"]
    )
    frame["stressed_total_cash_inflow_usd"] = (
        frame["total_cash_inflow_usd"] + frame["delayed_incoming_payment_recovery_usd"]
    )
    frame["stressed_net_liquidity_outflow_usd"] = (
        frame["stressed_total_cash_outflow_usd"] - frame["stressed_total_cash_inflow_usd"]
    )
    frame["stressed_cumulative_net_liquidity_need_usd"] = frame.groupby(
        "member_id", sort=False, group_keys=False
    )["stressed_net_liquidity_outflow_usd"].apply(_cumulative_floor)
    frame["stressed_liquidity_headroom_usd"] = (
        frame["cumulative_available_resources_usd"]
        - frame["stressed_cumulative_net_liquidity_need_usd"]
    )
    frame["stressed_liquidity_shortfall_usd"] = (-frame["stressed_liquidity_headroom_usd"]).clip(
        lower=0.0
    )
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
    return frame.sort_values(["member_id", "bucket_order"], kind="stable").reset_index(drop=True)


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
        peak_need = float(ordered["stressed_cumulative_net_liquidity_need_usd"].max())
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
                "stressed_liquidity_coverage_ratio": final_resources / max(peak_need, 0.01),
                "first_shortfall_bucket": (
                    str(first_shortfall.iloc[0]) if not first_shortfall.empty else ""
                ),
                "settlement_fail_status": (
                    "COVERED"
                    if float(ordered["stressed_liquidity_shortfall_usd"].max()) <= 0.01
                    else "SHORTFALL"
                ),
                "model_version": str(ordered["model_version"].iloc[0]),
                "value_class": "synthetic",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    return (
        pd.DataFrame.from_records(rows)
        .sort_values(["severity_rank", "member_id"], kind="stable")
        .reset_index(drop=True)
    )


def _scenario_summary(member_summary: pd.DataFrame) -> pd.DataFrame:
    grouped = member_summary.groupby(["scenario_name", "severity_rank"], sort=True)
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
    finite = cashflows[numeric_columns].apply(lambda column: column.map(math.isfinite).all()).all()
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
        (
            cashflows["required_replacement_liquidity_usd"]
            - cashflows["fails_to_deliver_usd"] * cashflows["replacement_liquidity_rate"]
        )
        .abs()
        .le(tolerance)
        .all()
    )
    recovery_bound = True
    for _, group in cashflows.groupby(["scenario_name", "member_id"], sort=True):
        recovered = float(group["delayed_incoming_payment_recovery_usd"].sum())
        failed_to_receive = float(group["fails_to_receive_usd"].sum())
        if recovered > failed_to_receive + tolerance:
            recovery_bound = False
            break
    combined_identity = (
        (
            cashflows["incremental_combined_stress_outflow_usd"]
            - cashflows["incremental_settlement_fail_outflow_usd"]
            - cashflows["combined_funding_shock_outflow_usd"]
        )
        .abs()
        .le(tolerance)
        .all()
    )
    headroom_identity = (
        (
            cashflows["stressed_liquidity_headroom_usd"]
            - (
                cashflows["cumulative_available_resources_usd"]
                - cashflows["stressed_cumulative_net_liquidity_need_usd"]
            )
        )
        .abs()
        .le(tolerance)
        .all()
    )
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
        "scenario_aggregation_complete": len(scenario_summary) == len(settings.scenarios),
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
    cashflows = (
        pd.concat(frames, ignore_index=True)
        .sort_values(["severity_rank", "member_id", "bucket_order"], kind="stable")
        .reset_index(drop=True)
    )
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
