"""Controlled hypothetical scenario framework for Phase VI, Section 21."""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml


class HypotheticalScenarioError(ValueError):
    """Raised when Section 21 scenario inputs or assumptions are invalid."""


REQUIRED_SCENARIOS: frozenset[str] = frozenset(
    {
        "moderate_stress",
        "severe_stress",
        "extreme_but_plausible_stress",
        "parallel_treasury_shock",
        "curve_steepening",
        "curve_flattening",
        "sofr_spike",
        "repo_rollover_failure",
        "collateral_haircut_increase",
        "settlement_fail_increase",
        "combined_systemic_stress",
    }
)

REQUIRED_FAMILIES: frozenset[str] = frozenset(
    {
        "broad_market",
        "treasury_parallel",
        "treasury_curve",
        "funding_rate",
        "funding_rollover",
        "collateral",
        "settlement",
        "systemic",
    }
)

FUNDING_FIELDS: tuple[str, ...] = (
    "sofr_spike_bp",
    "funding_spread_increase_bp",
    "repo_rollover_failure_rate",
    "lender_withdrawal_rate",
    "refinancing_horizon_hours",
    "collateral_haircut_increase",
    "collateral_call_rate",
    "concentration_threshold",
    "concentration_multiplier",
    "funding_dependency_multiplier",
    "max_effective_unavailability_rate",
)

SETTLEMENT_FIELDS: tuple[str, ...] = (
    "fails_to_receive_multiplier",
    "fails_to_deliver_multiplier",
    "additional_fails_to_receive_rate",
    "additional_fails_to_deliver_rate",
    "incoming_payment_delay_buckets",
    "replacement_liquidity_rate",
    "persistence_days",
    "persistence_decay",
    "funding_stress_weight",
)


@dataclass(frozen=True, slots=True)
class HypotheticalScenario:
    """One controlled Section 21 hypothetical scenario."""

    name: str
    label: str
    family: str
    severity: str
    display_order: int
    treasury: Mapping[str, Any]
    funding: Mapping[str, Any]
    haircut: Mapping[str, Any]
    settlement: Mapping[str, Any]
    integrated: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class HypotheticalSettings:
    """Validated Section 21 runtime settings."""

    model_version: str
    source: Mapping[str, Any]
    guardrails: Mapping[str, float]
    output_directory: Path
    evidence_directory: Path
    manifest_path: Path
    write_csv: bool
    write_parquet: bool
    tolerance_usd: float


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HypotheticalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _number(mapping: Mapping[str, Any], key: str) -> float:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise HypotheticalScenarioError(f"{key} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise HypotheticalScenarioError(f"{key} must be finite.")
    return result


def _integer(mapping: Mapping[str, Any], key: str) -> int:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise HypotheticalScenarioError(f"{key} must be an integer.")
    return int(value)


def _bounded(value: float, lower: float, upper: float, label: str) -> None:
    if not lower <= value <= upper:
        raise HypotheticalScenarioError(f"{label} must be between {lower:g} and {upper:g}.")


def load_yaml(path: str | Path) -> dict[str, Any]:
    """Load a UTF-8 YAML mapping."""
    yaml_path = Path(path)
    if not yaml_path.exists():
        raise HypotheticalScenarioError(f"Configuration does not exist: {yaml_path}")
    loaded = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    return _mapping(loaded, str(yaml_path))


def load_settings(config: Mapping[str, Any], root: Path) -> HypotheticalSettings:
    """Validate Section 21 top-level settings."""
    source = _mapping(config.get("source"), "source")
    output = _mapping(config.get("output"), "output")
    validation = _mapping(config.get("validation"), "validation")
    raw_guardrails = _mapping(config.get("guardrails"), "guardrails")
    guardrails: dict[str, float] = {}
    for key, value in raw_guardrails.items():
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise HypotheticalScenarioError(f"guardrails.{key} must be numeric.")
        number = float(value)
        if not math.isfinite(number) or number <= 0.0:
            raise HypotheticalScenarioError(f"guardrails.{key} must be finite and positive.")
        guardrails[str(key)] = number
    model_version = str(config.get("model_version", "section-21-v1")).strip()
    if not model_version:
        raise HypotheticalScenarioError("model_version cannot be empty.")
    tolerance = _number(validation, "reconciliation_tolerance_usd")
    if tolerance < 0.0:
        raise HypotheticalScenarioError(
            "validation.reconciliation_tolerance_usd must be nonnegative."
        )
    return HypotheticalSettings(
        model_version=model_version,
        source=source,
        guardrails=guardrails,
        output_directory=root / str(output.get("directory", "reports/tables")),
        evidence_directory=root / str(output.get("evidence_directory", "reports/evidence")),
        manifest_path=root
        / str(
            output.get(
                "manifest",
                "data/manifests/hypothetical_scenario_manifest.csv",
            )
        ),
        write_csv=bool(output.get("write_csv", True)),
        write_parquet=bool(output.get("write_parquet", True)),
        tolerance_usd=tolerance,
    )


def _validate_treasury(
    scenario_name: str,
    treasury: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    shape = str(treasury.get("shape", "")).strip().lower()
    if shape not in {"none", "parallel", "steepening", "flattening", "bucket_vector"}:
        raise HypotheticalScenarioError(f"{scenario_name}.treasury.shape is unsupported: {shape}")
    maximum = guardrails["maximum_absolute_treasury_shock_bp"]
    if shape == "parallel":
        _bounded(
            abs(_number(treasury, "parallel_bp")),
            0.0,
            maximum,
            f"{scenario_name}.treasury.parallel_bp",
        )
    elif shape in {"steepening", "flattening"}:
        short = _number(treasury, "short_end_bp")
        long = _number(treasury, "long_end_bp")
        _bounded(abs(short), 0.0, maximum, f"{scenario_name}.treasury.short_end_bp")
        _bounded(abs(long), 0.0, maximum, f"{scenario_name}.treasury.long_end_bp")
        if shape == "steepening" and long < short:
            raise HypotheticalScenarioError(
                f"{scenario_name} steepening requires long_end_bp >= short_end_bp."
            )
        if shape == "flattening" and short < long:
            raise HypotheticalScenarioError(
                f"{scenario_name} flattening requires short_end_bp >= long_end_bp."
            )
    elif shape == "bucket_vector":
        shocks = _mapping(treasury.get("shocks_bp"), f"{scenario_name}.treasury.shocks_bp")
        if not shocks:
            raise HypotheticalScenarioError(f"{scenario_name}.treasury.shocks_bp cannot be empty.")
        for bucket, value in shocks.items():
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise HypotheticalScenarioError(
                    f"{scenario_name}.treasury.shocks_bp.{bucket} must be numeric."
                )
            _bounded(
                abs(float(value)),
                0.0,
                maximum,
                f"{scenario_name}.treasury.shocks_bp.{bucket}",
            )


def _validate_funding(
    scenario_name: str,
    funding: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    for field in FUNDING_FIELDS:
        if field not in funding:
            raise HypotheticalScenarioError(f"{scenario_name}.funding.{field} is required.")
    _bounded(
        _number(funding, "sofr_spike_bp"),
        0.0,
        guardrails["maximum_sofr_spike_bp"],
        f"{scenario_name}.funding.sofr_spike_bp",
    )
    _bounded(
        _number(funding, "funding_spread_increase_bp"),
        0.0,
        guardrails["maximum_funding_spread_increase_bp"],
        f"{scenario_name}.funding.funding_spread_increase_bp",
    )
    _bounded(
        _number(funding, "repo_rollover_failure_rate"),
        0.0,
        guardrails["maximum_rollover_failure_rate"],
        f"{scenario_name}.funding.repo_rollover_failure_rate",
    )
    _bounded(
        _number(funding, "lender_withdrawal_rate"),
        0.0,
        guardrails["maximum_lender_withdrawal_rate"],
        f"{scenario_name}.funding.lender_withdrawal_rate",
    )
    horizon = _integer(funding, "refinancing_horizon_hours")
    if horizon <= 0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.funding.refinancing_horizon_hours must be positive."
        )
    for field in (
        "collateral_haircut_increase",
        "collateral_call_rate",
        "concentration_threshold",
        "max_effective_unavailability_rate",
    ):
        _bounded(
            _number(funding, field),
            0.0,
            1.0,
            f"{scenario_name}.funding.{field}",
        )
    for field in ("concentration_multiplier", "funding_dependency_multiplier"):
        if _number(funding, field) < 0.0:
            raise HypotheticalScenarioError(f"{scenario_name}.funding.{field} must be nonnegative.")


def _validate_haircut(
    scenario_name: str,
    haircut: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    stress_multiplier = _number(haircut, "stress_multiplier")
    if stress_multiplier < 1.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.haircut.stress_multiplier must be at least one."
        )
    _bounded(
        _number(haircut, "additive_haircut_rate"),
        0.0,
        guardrails["maximum_additive_haircut_rate"],
        f"{scenario_name}.haircut.additive_haircut_rate",
    )
    for field in ("bucket_addon_short_rate", "bucket_addon_long_rate"):
        _bounded(
            _number(haircut, field),
            0.0,
            guardrails["maximum_additive_haircut_rate"],
            f"{scenario_name}.haircut.{field}",
        )
    for field in (
        "concentration_threshold",
        "additional_collateral_call_rate",
        "inventory_availability_rate",
        "maximum_haircut_rate",
    ):
        _bounded(
            _number(haircut, field),
            0.0,
            1.0,
            f"{scenario_name}.haircut.{field}",
        )
    if _number(haircut, "maximum_haircut_rate") >= 1.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.haircut.maximum_haircut_rate must be below one."
        )
    if _number(haircut, "concentration_multiplier") < 0.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.haircut.concentration_multiplier must be nonnegative."
        )


def _validate_settlement(
    scenario_name: str,
    settlement: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    for field in SETTLEMENT_FIELDS:
        if field not in settlement:
            raise HypotheticalScenarioError(f"{scenario_name}.settlement.{field} is required.")
    maximum_multiplier = guardrails["maximum_settlement_fail_multiplier"]
    for field in ("fails_to_receive_multiplier", "fails_to_deliver_multiplier"):
        _bounded(
            _number(settlement, field),
            0.0,
            maximum_multiplier,
            f"{scenario_name}.settlement.{field}",
        )
    for field in (
        "additional_fails_to_receive_rate",
        "additional_fails_to_deliver_rate",
        "persistence_decay",
        "funding_stress_weight",
    ):
        _bounded(
            _number(settlement, field),
            0.0,
            1.0,
            f"{scenario_name}.settlement.{field}",
        )
    if _integer(settlement, "incoming_payment_delay_buckets") < 0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.settlement.incoming_payment_delay_buckets must be nonnegative."
        )
    if _integer(settlement, "persistence_days") <= 0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.settlement.persistence_days must be positive."
        )
    if _number(settlement, "replacement_liquidity_rate") < 0.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.settlement.replacement_liquidity_rate must be nonnegative."
        )


def _validate_integrated(
    scenario_name: str,
    integrated: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> None:
    _bounded(
        _number(integrated, "concentration_threshold"),
        0.0,
        1.0,
        f"{scenario_name}.integrated.concentration_threshold",
    )
    if _number(integrated, "concentration_multiplier") < 0.0:
        raise HypotheticalScenarioError(
            f"{scenario_name}.integrated.concentration_multiplier must be nonnegative."
        )
    _bounded(
        _number(integrated, "operational_liquidity_buffer_rate"),
        0.0,
        guardrails["maximum_operational_liquidity_buffer_rate"],
        f"{scenario_name}.integrated.operational_liquidity_buffer_rate",
    )


def load_scenarios(
    config: Mapping[str, Any],
    guardrails: Mapping[str, float],
) -> tuple[HypotheticalScenario, ...]:
    """Load and validate all required Section 21 hypothetical scenarios."""
    raw_scenarios = config.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise HypotheticalScenarioError("scenarios must be a nonempty list.")
    scenarios: list[HypotheticalScenario] = []
    for raw in raw_scenarios:
        row = _mapping(raw, "scenario")
        name = str(row.get("name", "")).strip()
        label = str(row.get("label", "")).strip()
        family = str(row.get("family", "")).strip()
        severity = str(row.get("severity", "")).strip()
        display_order = _integer(row, "display_order")
        if not name or not label or not family or not severity:
            raise HypotheticalScenarioError(
                "Each scenario requires name, label, family, and severity."
            )
        if display_order <= 0:
            raise HypotheticalScenarioError("display_order must be positive.")
        treasury = _mapping(row.get("treasury"), f"{name}.treasury")
        funding = _mapping(row.get("funding"), f"{name}.funding")
        haircut = _mapping(row.get("haircut"), f"{name}.haircut")
        settlement = _mapping(row.get("settlement"), f"{name}.settlement")
        integrated = _mapping(row.get("integrated"), f"{name}.integrated")
        _validate_treasury(name, treasury, guardrails)
        _validate_funding(name, funding, guardrails)
        _validate_haircut(name, haircut, guardrails)
        _validate_settlement(name, settlement, guardrails)
        _validate_integrated(name, integrated, guardrails)
        scenarios.append(
            HypotheticalScenario(
                name=name,
                label=label,
                family=family,
                severity=severity,
                display_order=display_order,
                treasury=treasury,
                funding=funding,
                haircut=haircut,
                settlement=settlement,
                integrated=integrated,
            )
        )
    names = [scenario.name for scenario in scenarios]
    orders = [scenario.display_order for scenario in scenarios]
    if len(set(names)) != len(names):
        raise HypotheticalScenarioError("Scenario names must be unique.")
    if len(set(orders)) != len(orders):
        raise HypotheticalScenarioError("Scenario display_order values must be unique.")
    missing_names = sorted(REQUIRED_SCENARIOS - set(names))
    if missing_names:
        raise HypotheticalScenarioError(
            f"Required hypothetical scenarios are missing: {missing_names}"
        )
    families = {scenario.family for scenario in scenarios}
    missing_families = sorted(REQUIRED_FAMILIES - families)
    if missing_families:
        raise HypotheticalScenarioError(
            f"Required hypothetical scenario families are missing: {missing_families}"
        )
    return tuple(sorted(scenarios, key=lambda item: item.display_order))


def _maturity_buckets(
    treasury_config: Mapping[str, Any],
) -> list[tuple[str, float]]:
    raw = _mapping(treasury_config.get("maturity_buckets"), "maturity_buckets")
    buckets: list[tuple[str, float]] = []
    for name, assumptions in raw.items():
        row = _mapping(assumptions, f"maturity_buckets.{name}")
        buckets.append((str(name), _number(row, "midpoint_years")))
    if not buckets:
        raise HypotheticalScenarioError("Treasury maturity buckets cannot be empty.")
    return sorted(buckets, key=lambda item: item[1])


def expand_treasury_shock(
    scenario: HypotheticalScenario,
    treasury_config: Mapping[str, Any],
) -> dict[str, float]:
    """Expand parallel and curve shapes into a complete maturity-bucket vector."""
    buckets = _maturity_buckets(treasury_config)
    shape = str(scenario.treasury["shape"]).lower()
    if shape == "none":
        return {}
    if shape == "parallel":
        shock = float(scenario.treasury["parallel_bp"])
        return {name: shock for name, _ in buckets}
    if shape == "bucket_vector":
        raw = _mapping(
            scenario.treasury.get("shocks_bp"),
            f"{scenario.name}.treasury.shocks_bp",
        )
        unknown = sorted(set(raw) - {name for name, _ in buckets})
        if unknown:
            raise HypotheticalScenarioError(
                f"{scenario.name} has unknown Treasury buckets: {unknown}"
            )
        return {name: float(raw.get(name, 0.0)) for name, _ in buckets}
    short = float(scenario.treasury["short_end_bp"])
    long = float(scenario.treasury["long_end_bp"])
    minimum = buckets[0][1]
    maximum = buckets[-1][1]
    span = maximum - minimum
    vector: dict[str, float] = {}
    for name, midpoint in buckets:
        weight = 0.0 if span <= 0.0 else (midpoint - minimum) / span
        vector[name] = short + weight * (long - short)
    return vector


def build_treasury_scenarios(
    scenarios: Sequence[HypotheticalScenario],
    treasury_config: Mapping[str, Any],
) -> list[dict[str, Any]]:
    """Build Section 15 bucket-vector scenarios for every nonzero yield shock."""
    result: list[dict[str, Any]] = []
    for scenario in scenarios:
        vector = expand_treasury_shock(scenario, treasury_config)
        if not vector:
            continue
        result.append(
            {
                "name": scenario.name,
                "enabled": True,
                "family": scenario.family,
                "type": "bucket_vector",
                "shocks_bp": vector,
            }
        )
    return result


def _base_control(
    base_config: Mapping[str, Any],
    label: str,
) -> dict[str, Any]:
    raw = base_config.get("scenarios")
    if not isinstance(raw, list) or not raw:
        raise HypotheticalScenarioError(f"{label}.scenarios must be nonempty.")
    for item in raw:
        scenario = _mapping(item, f"{label}.scenario")
        if str(scenario.get("name", "")).strip() == "control":
            control = deepcopy(scenario)
            control["severity_rank"] = 0
            control["enabled"] = True
            return control
    raise HypotheticalScenarioError(f"{label} does not contain a control scenario.")


def build_funding_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
) -> dict[str, Any]:
    """Create a control-plus-target Section 16 configuration."""
    config = deepcopy(dict(base_config))
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        **{field: scenario.funding[field] for field in FUNDING_FIELDS},
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "funding"), target]
    return config


def _linear_bucket_addons(
    bucket_names: Sequence[str],
    short_rate: float,
    long_rate: float,
) -> dict[str, float]:
    if not bucket_names:
        raise HypotheticalScenarioError("Haircut maturity buckets cannot be empty.")
    if len(bucket_names) == 1:
        return {str(bucket_names[0]): float(short_rate)}
    denominator = float(len(bucket_names) - 1)
    return {
        str(name): short_rate + (index / denominator) * (long_rate - short_rate)
        for index, name in enumerate(bucket_names)
    }


def build_haircut_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
) -> dict[str, Any]:
    """Create a control-plus-target Section 17 configuration."""
    config = deepcopy(dict(base_config))
    raw_buckets = _mapping(base_config.get("maturity_buckets"), "maturity_buckets")
    bucket_names = [str(name) for name in raw_buckets]
    haircut = scenario.haircut
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        "stress_multiplier": haircut["stress_multiplier"],
        "additive_haircut_rate": haircut["additive_haircut_rate"],
        "bucket_addons": _linear_bucket_addons(
            bucket_names,
            float(haircut["bucket_addon_short_rate"]),
            float(haircut["bucket_addon_long_rate"]),
        ),
        "concentration_threshold": haircut["concentration_threshold"],
        "concentration_multiplier": haircut["concentration_multiplier"],
        "additional_collateral_call_rate": haircut["additional_collateral_call_rate"],
        "inventory_availability_rate": haircut["inventory_availability_rate"],
        "maximum_haircut_rate": haircut["maximum_haircut_rate"],
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "haircut"), target]
    return config


def build_settlement_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
) -> dict[str, Any]:
    """Create a control-plus-target Section 18 configuration."""
    config = deepcopy(dict(base_config))
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        **{field: scenario.settlement[field] for field in SETTLEMENT_FIELDS},
        "funding_scenario_name": scenario.name,
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "settlement"), target]
    return config


def build_integrated_config(
    base_config: Mapping[str, Any],
    scenario: HypotheticalScenario,
    model_version: str,
    treasury_active: bool,
) -> dict[str, Any]:
    """Create a control-plus-target Section 19 configuration."""
    config = deepcopy(dict(base_config))
    integrated = scenario.integrated
    target = {
        "name": scenario.name,
        "enabled": True,
        "severity_rank": 1,
        "funding_scenario_name": scenario.name,
        "haircut_scenario_name": scenario.name,
        "treasury_scenario_name": scenario.name if treasury_active else "NONE",
        "settlement_fail_scenario_name": scenario.name,
        "concentration_threshold": integrated["concentration_threshold"],
        "concentration_multiplier": integrated["concentration_multiplier"],
        "operational_liquidity_buffer_rate": integrated["operational_liquidity_buffer_rate"],
    }
    config["model_version"] = model_version
    config["scenarios"] = [_base_control(base_config, "integrated"), target]
    return config


def scenario_catalog_frame(
    scenarios: Sequence[HypotheticalScenario],
    treasury_config: Mapping[str, Any],
) -> pd.DataFrame:
    """Return a flat, audit-ready scenario catalog."""
    rows: list[dict[str, object]] = []
    for scenario in scenarios:
        vector = expand_treasury_shock(scenario, treasury_config)
        rows.append(
            {
                "scenario_name": scenario.name,
                "scenario_label": scenario.label,
                "scenario_family": scenario.family,
                "severity": scenario.severity,
                "display_order": scenario.display_order,
                "treasury_shape": str(scenario.treasury["shape"]),
                "maximum_absolute_treasury_shock_bp": (
                    max(abs(value) for value in vector.values()) if vector else 0.0
                ),
                "sofr_spike_bp": float(scenario.funding["sofr_spike_bp"]),
                "repo_rollover_failure_rate": float(scenario.funding["repo_rollover_failure_rate"]),
                "additive_haircut_rate": float(scenario.haircut["additive_haircut_rate"]),
                "fails_to_receive_multiplier": float(
                    scenario.settlement["fails_to_receive_multiplier"]
                ),
                "fails_to_deliver_multiplier": float(
                    scenario.settlement["fails_to_deliver_multiplier"]
                ),
                "operational_liquidity_buffer_rate": float(
                    scenario.integrated["operational_liquidity_buffer_rate"]
                ),
                "value_class": "hypothetical_assumptions_on_synthetic_members",
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    result = pd.DataFrame.from_records(rows)
    result_any: Any = result
    ordered_any: Any = result_any.sort_values(
        by=["display_order", "scenario_name"],
        kind="stable",
    )
    reset_any: Any = ordered_any.reset_index(drop=True)
    return cast(pd.DataFrame, reset_any)


def treasury_shock_frame(
    scenarios: Sequence[HypotheticalScenario],
    treasury_config: Mapping[str, Any],
) -> pd.DataFrame:
    """Return the complete scenario-by-maturity Treasury shock matrix."""
    rows: list[dict[str, object]] = []
    for scenario in scenarios:
        for bucket, shock in expand_treasury_shock(
            scenario,
            treasury_config,
        ).items():
            rows.append(
                {
                    "scenario_name": scenario.name,
                    "scenario_family": scenario.family,
                    "display_order": scenario.display_order,
                    "maturity_bucket": bucket,
                    "yield_shock_bp": shock,
                    "value_class": "hypothetical_assumption",
                }
            )
    result = pd.DataFrame.from_records(rows)
    if result.empty:
        return pd.DataFrame(
            columns=[
                "scenario_name",
                "scenario_family",
                "display_order",
                "maturity_bucket",
                "yield_shock_bp",
                "value_class",
            ]
        )
    result_any: Any = result
    ordered_any: Any = result_any.sort_values(
        by=["display_order", "maturity_bucket"],
        kind="stable",
    )
    reset_any: Any = ordered_any.reset_index(drop=True)
    return cast(pd.DataFrame, reset_any)


__all__ = [
    "REQUIRED_FAMILIES",
    "REQUIRED_SCENARIOS",
    "HypotheticalScenario",
    "HypotheticalScenarioError",
    "HypotheticalSettings",
    "build_funding_config",
    "build_haircut_config",
    "build_integrated_config",
    "build_settlement_config",
    "build_treasury_scenarios",
    "expand_treasury_shock",
    "load_scenarios",
    "load_settings",
    "load_yaml",
    "scenario_catalog_frame",
    "treasury_shock_frame",
]
