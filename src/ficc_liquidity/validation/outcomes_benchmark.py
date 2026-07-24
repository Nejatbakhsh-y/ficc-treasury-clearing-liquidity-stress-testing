"""Section 27 outcomes and benchmark analysis.

The module deliberately avoids calling production stress-calculation functions.
It consumes normalized model outputs or creates a controlled benchmark dataset
when model outputs are unavailable. Controlled results are explicitly labeled
and must not be represented as empirical FICC outcome validation.
"""

from __future__ import annotations

import csv
import hashlib
import itertools
import json
import math
import random
import statistics
from collections import defaultdict
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, cast

COMPONENT_NAMES: tuple[str, ...] = (
    "settlement_liquidity_need",
    "repo_rollover_need",
    "incremental_funding_cost",
    "additional_haircut_requirement",
    "treasury_liquidation_loss",
    "settlement_fail_requirement",
    "concentration_adjustment",
    "operational_liquidity_buffer",
)

DRIVER_NAMES: tuple[str, ...] = (
    "yield_shock_bps",
    "duration_years",
    "sofr_spike_bps",
    "rollover_failure_pct",
    "haircut_increase_pct",
    "settlement_fail_pct",
    "member_concentration_pct",
    "liquidation_horizon_days",
    "default_set_size",
    "available_resource_multiplier",
)

EXPOSURE_NAMES: tuple[str, ...] = (
    "settlement_obligation",
    "repo_maturity",
    "collateral_value",
    "treasury_market_value",
)

ALIASES: dict[str, tuple[str, ...]] = {
    "scenario_id": ("scenario_id", "scenario", "id"),
    "scenario_name": ("scenario_name", "name", "scenario"),
    "analysis_family": ("analysis_family", "family", "scenario_family"),
    "severity": ("severity", "scenario_severity", "stress_level"),
    "seed": ("seed", "random_seed"),
    "stressed_requirement": (
        "stressed_requirement",
        "stressed_liquidity_requirement",
        "total_requirement",
        "liquidity_requirement",
        "cover_requirement",
    ),
    "available_resources": (
        "available_resources",
        "available_qualified_liquid_resources",
        "aqlr",
        "qualified_liquid_resources",
    ),
    "lcr": ("lcr", "liquidity_coverage_ratio", "coverage_ratio"),
    "shortfall": ("shortfall", "liquidity_shortfall"),
    "resource_utilization": ("resource_utilization", "utilization", "resource_usage"),
    "dominant_component": ("dominant_component",),
    "settlement_liquidity_need": (
        "settlement_liquidity_need",
        "settlement_need",
        "settlement_requirement",
    ),
    "repo_rollover_need": ("repo_rollover_need", "rollover_need", "repo_funding_need"),
    "incremental_funding_cost": (
        "incremental_funding_cost",
        "funding_cost",
        "sofr_funding_cost",
    ),
    "additional_haircut_requirement": (
        "additional_haircut_requirement",
        "haircut_requirement",
        "haircut_need",
    ),
    "treasury_liquidation_loss": (
        "treasury_liquidation_loss",
        "liquidation_loss",
        "market_value_loss",
    ),
    "settlement_fail_requirement": (
        "settlement_fail_requirement",
        "settlement_fails_requirement",
        "fails_requirement",
    ),
    "concentration_adjustment": (
        "concentration_adjustment",
        "concentration_addon",
        "concentration_requirement",
    ),
    "operational_liquidity_buffer": (
        "operational_liquidity_buffer",
        "operational_buffer",
        "liquidity_buffer",
    ),
    "yield_shock_bps": ("yield_shock_bps", "treasury_yield_shock_bps", "yield_shock"),
    "duration_years": ("duration_years", "modified_duration", "duration"),
    "sofr_spike_bps": ("sofr_spike_bps", "sofr_shock_bps", "sofr_spike"),
    "rollover_failure_pct": (
        "rollover_failure_pct",
        "rollover_failure_rate",
        "rollover_failure_percentage",
    ),
    "haircut_increase_pct": (
        "haircut_increase_pct",
        "haircut_increase",
        "haircut_shock_pct",
    ),
    "settlement_fail_pct": (
        "settlement_fail_pct",
        "settlement_fail_rate",
        "settlement_fail_percentage",
    ),
    "member_concentration_pct": (
        "member_concentration_pct",
        "member_concentration",
        "concentration_pct",
    ),
    "liquidation_horizon_days": (
        "liquidation_horizon_days",
        "liquidation_horizon",
        "horizon_days",
    ),
    "default_set_size": ("default_set_size", "number_of_defaults", "cover_size"),
    "available_resource_multiplier": (
        "available_resource_multiplier",
        "resource_multiplier",
        "available_resources_multiplier",
    ),
    "settlement_obligation": ("settlement_obligation", "gross_settlement_obligation"),
    "repo_maturity": ("repo_maturity", "repo_financing_need", "repo_exposure"),
    "collateral_value": ("collateral_value", "eligible_collateral_value"),
    "treasury_market_value": ("treasury_market_value", "treasury_position_value"),
}

DEFAULT_CONFIG: dict[str, Any] = {
    "severity_order": ["baseline", "moderate", "severe", "extreme"],
    "tolerances": {
        "identity_absolute": 1e-6,
        "identity_relative": 1e-6,
        "monotonic_absolute": 1e-8,
        "component_reconciliation_relative": 0.005,
        "benchmark_relative": 0.25,
        "seed_cv": 0.05,
        "seed_range_relative": 0.15,
        "plausibility_pass_rate": 0.95,
    },
    "plausibility_bounds": {
        "stressed_requirement": [0.0, 1.0e15],
        "available_resources": [0.0, 1.0e15],
        "lcr": [0.0, 100.0],
        "resource_utilization": [0.0, 100.0],
        "yield_shock_bps": [0.0, 2000.0],
        "duration_years": [0.0, 30.0],
        "sofr_spike_bps": [0.0, 3000.0],
        "rollover_failure_pct": [0.0, 1.0],
        "haircut_increase_pct": [0.0, 1.0],
        "settlement_fail_pct": [0.0, 1.0],
        "member_concentration_pct": [0.0, 1.0],
        "liquidation_horizon_days": [0.0, 30.0],
        "default_set_size": [1.0, 10.0],
        "available_resource_multiplier": [0.0, 2.0],
    },
    "controlled": {
        "seeds": [2026, 2027, 2028, 2029, 2030],
        "base_exposures": {
            "settlement_obligation": 550.0,
            "repo_maturity": 420.0,
            "collateral_value": 650.0,
            "treasury_market_value": 900.0,
        },
        "base_available_resources": 700.0,
        "noise_scale": 0.004,
    },
}


@dataclass(frozen=True)
class OutcomeRecord:
    scenario_id: str
    scenario_name: str
    analysis_family: str
    severity: str
    seed: int
    stressed_requirement: float
    available_resources: float
    lcr: float
    shortfall: float
    resource_utilization: float
    dominant_component: str
    components: dict[str, float] = field(default_factory=dict)
    drivers: dict[str, float] = field(default_factory=dict)
    exposures: dict[str, float] = field(default_factory=dict)

    def to_flat_dict(self) -> dict[str, Any]:
        row: dict[str, Any] = {
            "scenario_id": self.scenario_id,
            "scenario_name": self.scenario_name,
            "analysis_family": self.analysis_family,
            "severity": self.severity,
            "seed": self.seed,
            "stressed_requirement": self.stressed_requirement,
            "available_resources": self.available_resources,
            "lcr": self.lcr,
            "shortfall": self.shortfall,
            "resource_utilization": self.resource_utilization,
            "dominant_component": self.dominant_component,
        }
        row.update(self.components)
        row.update(self.drivers)
        row.update(self.exposures)
        return row


@dataclass
class ValidationResult:
    name: str
    status: str
    evaluated: int
    passed: int
    failed: int
    metrics: dict[str, Any] = field(default_factory=dict)
    rows: list[dict[str, Any]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def pass_rate(self) -> float | None:
        if self.evaluated == 0:
            return None
        return self.passed / self.evaluated

    def to_summary(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "status": self.status,
            "evaluated": self.evaluated,
            "passed": self.passed,
            "failed": self.failed,
            "pass_rate": self.pass_rate,
            "metrics": self.metrics,
            "notes": self.notes,
        }


def deep_merge(base: Mapping[str, Any], override: Mapping[str, Any]) -> dict[str, Any]:
    merged: dict[str, Any] = dict(base)
    for key, value in override.items():
        merged_value = merged.get(key)
        if isinstance(value, Mapping) and isinstance(merged_value, Mapping):
            merged[key] = deep_merge(merged_value, value)
        else:
            merged[key] = value
    return merged


def load_config(path: str | Path | None = None) -> dict[str, Any]:
    config = cast(dict[str, Any], json.loads(json.dumps(DEFAULT_CONFIG)))
    if path is None:
        return config
    config_path = Path(path)
    if not config_path.exists():
        raise FileNotFoundError(f"Configuration file does not exist: {config_path}")
    text = config_path.read_text(encoding="utf-8")
    try:
        loaded = json.loads(text)
    except json.JSONDecodeError:
        try:
            import yaml
        except ImportError as exc:
            raise ValueError(
                "Configuration is not JSON-compatible YAML and PyYAML is unavailable."
            ) from exc
        loaded = yaml.safe_load(text)
    if not isinstance(loaded, Mapping):
        raise ValueError("Configuration root must be a mapping.")
    return deep_merge(config, loaded)


def _normalise_key(value: str) -> str:
    return value.strip().lower().replace(" ", "_").replace("-", "_")


def _first_value(row: Mapping[str, Any], canonical: str, default: Any = None) -> Any:
    normalized = {_normalise_key(str(key)): value for key, value in row.items()}
    for alias in ALIASES.get(canonical, (canonical,)):
        key = _normalise_key(alias)
        value = normalized.get(key)
        if value not in (None, ""):
            return value
    return default


def _to_float(value: Any, default: float = 0.0) -> float:
    if value in (None, ""):
        return default
    if isinstance(value, int | float):
        return float(value)
    text = str(value).strip().replace(",", "")
    if text.endswith("%"):
        return float(text[:-1]) / 100.0
    return float(text)


def _to_int(value: Any, default: int = 0) -> int:
    if value in (None, ""):
        return default
    return int(float(str(value).strip()))


def _infer_family(name: str, severity: str) -> str:
    lower = name.lower()
    if lower.startswith("sweep_") or "sensitivity" in lower:
        for driver in DRIVER_NAMES:
            if driver in lower:
                return f"sensitivity_{driver}"
        return "sensitivity_unknown"
    if severity.lower() in {"baseline", "moderate", "severe", "extreme"}:
        return "scenario_ladder"
    return "external_scenarios"


def _detect_lcr_orientation(raw_rows: Sequence[Mapping[str, Any]]) -> str:
    direct_errors: list[float] = []
    inverse_errors: list[float] = []
    for row in raw_rows:
        req = _to_float(_first_value(row, "stressed_requirement"), 0.0)
        res = _to_float(_first_value(row, "available_resources"), 0.0)
        reported = _to_float(_first_value(row, "lcr"), math.nan)
        if req <= 0.0 or res <= 0.0 or not math.isfinite(reported):
            continue
        direct_errors.append(abs(reported - (res / req)))
        inverse_errors.append(abs(reported - (req / res)))
    if not direct_errors:
        return "resources_over_requirement"
    return (
        "resources_over_requirement"
        if statistics.median(direct_errors) <= statistics.median(inverse_errors)
        else "requirement_over_resources"
    )


def normalize_records(
    raw_rows: Sequence[Mapping[str, Any]],
) -> tuple[list[OutcomeRecord], dict[str, Any]]:
    if not raw_rows:
        raise ValueError("Input contains no rows.")
    orientation = _detect_lcr_orientation(raw_rows)
    records: list[OutcomeRecord] = []
    warnings: list[str] = []
    for index, row in enumerate(raw_rows, start=1):
        name = str(_first_value(row, "scenario_name", f"scenario_{index}"))
        severity = str(_first_value(row, "severity", "unspecified")).lower()
        family = str(_first_value(row, "analysis_family", _infer_family(name, severity)))
        scenario_id = str(_first_value(row, "scenario_id", f"row_{index:05d}"))
        seed = _to_int(_first_value(row, "seed", 0), 0)
        components = {
            component: _to_float(_first_value(row, component), 0.0) for component in COMPONENT_NAMES
        }
        component_sum = sum(components.values())
        requirement = _to_float(
            _first_value(row, "stressed_requirement"),
            component_sum,
        )
        resources = _to_float(_first_value(row, "available_resources"), 0.0)
        reported_lcr = _first_value(row, "lcr")
        if reported_lcr in (None, ""):
            numerator, denominator = (
                (resources, requirement)
                if orientation == "resources_over_requirement"
                else (requirement, resources)
            )
            lcr = numerator / denominator if denominator > 0.0 else math.nan
        else:
            lcr = _to_float(reported_lcr, math.nan)
        shortfall = _to_float(
            _first_value(row, "shortfall"),
            max(requirement - resources, 0.0),
        )
        utilization = _to_float(
            _first_value(row, "resource_utilization"),
            requirement / resources if resources > 0 else math.inf,
        )
        drivers = {driver: _to_float(_first_value(row, driver), 0.0) for driver in DRIVER_NAMES}
        if drivers["available_resource_multiplier"] == 0.0:
            drivers["available_resource_multiplier"] = 1.0
        exposures = {
            exposure: _to_float(_first_value(row, exposure), 0.0) for exposure in EXPOSURE_NAMES
        }
        dominant = str(_first_value(row, "dominant_component", ""))
        if not dominant:
            dominant = (
                max(components, key=lambda name: components[name]) if components else "unavailable"
            )
        if component_sum == 0.0:
            warnings.append(f"{scenario_id}: no recognized component columns were found.")
        records.append(
            OutcomeRecord(
                scenario_id=scenario_id,
                scenario_name=name,
                analysis_family=family,
                severity=severity,
                seed=seed,
                stressed_requirement=requirement,
                available_resources=resources,
                lcr=lcr,
                shortfall=shortfall,
                resource_utilization=utilization,
                dominant_component=dominant,
                components=components,
                drivers=drivers,
                exposures=exposures,
            )
        )
    return records, {"lcr_orientation": orientation, "warnings": warnings}


def load_records(path: str | Path) -> tuple[list[OutcomeRecord], dict[str, Any]]:
    input_path = Path(path)
    if not input_path.exists():
        raise FileNotFoundError(f"Input file does not exist: {input_path}")
    suffix = input_path.suffix.lower()
    raw_objects: list[Any]
    if suffix == ".csv":
        with input_path.open(encoding="utf-8-sig", newline="") as handle:
            raw_objects = list(csv.DictReader(handle))
    elif suffix in {".json", ".jsonl"}:
        if suffix == ".jsonl":
            raw_objects = [
                json.loads(line)
                for line in input_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
        else:
            payload: Any = json.loads(input_path.read_text(encoding="utf-8"))
            if isinstance(payload, Mapping):
                candidate: Any = payload.get(
                    "records",
                    payload.get("results", payload.get("data", payload)),
                )
                raw_objects = candidate if isinstance(candidate, list) else [candidate]
            elif isinstance(payload, list):
                raw_objects = payload
            else:
                raise ValueError("JSON input must be a list or mapping.")
    else:
        raise ValueError(f"Unsupported input format: {suffix}. Use CSV, JSON, or JSONL.")
    if not all(isinstance(row, Mapping) for row in raw_objects):
        raise ValueError("Every input record must be a mapping.")
    raw_rows = [cast(Mapping[str, Any], row) for row in raw_objects]
    return normalize_records(raw_rows)


def _severity_drivers() -> dict[str, dict[str, float]]:
    return {
        "baseline": {
            "yield_shock_bps": 10.0,
            "duration_years": 4.0,
            "sofr_spike_bps": 5.0,
            "rollover_failure_pct": 0.03,
            "haircut_increase_pct": 0.01,
            "settlement_fail_pct": 0.01,
            "member_concentration_pct": 0.20,
            "liquidation_horizon_days": 1.0,
            "default_set_size": 1.0,
            "available_resource_multiplier": 1.00,
        },
        "moderate": {
            "yield_shock_bps": 75.0,
            "duration_years": 4.5,
            "sofr_spike_bps": 75.0,
            "rollover_failure_pct": 0.15,
            "haircut_increase_pct": 0.04,
            "settlement_fail_pct": 0.06,
            "member_concentration_pct": 0.30,
            "liquidation_horizon_days": 2.0,
            "default_set_size": 1.0,
            "available_resource_multiplier": 0.95,
        },
        "severe": {
            "yield_shock_bps": 175.0,
            "duration_years": 5.0,
            "sofr_spike_bps": 200.0,
            "rollover_failure_pct": 0.35,
            "haircut_increase_pct": 0.10,
            "settlement_fail_pct": 0.18,
            "member_concentration_pct": 0.48,
            "liquidation_horizon_days": 3.0,
            "default_set_size": 2.0,
            "available_resource_multiplier": 0.88,
        },
        "extreme": {
            "yield_shock_bps": 350.0,
            "duration_years": 6.0,
            "sofr_spike_bps": 400.0,
            "rollover_failure_pct": 0.60,
            "haircut_increase_pct": 0.20,
            "settlement_fail_pct": 0.35,
            "member_concentration_pct": 0.70,
            "liquidation_horizon_days": 5.0,
            "default_set_size": 2.0,
            "available_resource_multiplier": 0.75,
        },
    }


def deterministic_component_benchmark(
    drivers: Mapping[str, float], exposures: Mapping[str, float]
) -> dict[str, float]:
    settlement = max(exposures.get("settlement_obligation", 0.0), 0.0)
    repo = max(exposures.get("repo_maturity", 0.0), 0.0)
    collateral = max(exposures.get("collateral_value", 0.0), 0.0)
    treasury = max(exposures.get("treasury_market_value", 0.0), 0.0)
    yield_decimal = max(drivers.get("yield_shock_bps", 0.0), 0.0) / 10_000.0
    duration = max(drivers.get("duration_years", 0.0), 0.0)
    sofr_decimal = max(drivers.get("sofr_spike_bps", 0.0), 0.0) / 10_000.0
    rollover = min(max(drivers.get("rollover_failure_pct", 0.0), 0.0), 1.0)
    haircut = min(max(drivers.get("haircut_increase_pct", 0.0), 0.0), 1.0)
    fail = min(max(drivers.get("settlement_fail_pct", 0.0), 0.0), 1.0)
    concentration = min(max(drivers.get("member_concentration_pct", 0.0), 0.0), 1.0)
    horizon = max(drivers.get("liquidation_horizon_days", 1.0), 1.0)
    default_size = max(drivers.get("default_set_size", 1.0), 1.0)

    result = {
        "settlement_liquidity_need": settlement * (0.28 + 0.18 * (default_size - 1.0)),
        "repo_rollover_need": repo * rollover,
        "incremental_funding_cost": repo * sofr_decimal * horizon / 360.0,
        "additional_haircut_requirement": collateral * haircut,
        "treasury_liquidation_loss": treasury * duration * yield_decimal * math.sqrt(horizon),
        "settlement_fail_requirement": settlement * fail,
        "concentration_adjustment": 0.0,
        "operational_liquidity_buffer": 0.0,
    }
    pre_addon = sum(result.values())
    result["concentration_adjustment"] = pre_addon * concentration * 0.12
    result["operational_liquidity_buffer"] = pre_addon * (0.04 + 0.01 * min(horizon, 5.0))
    return result


def _controlled_record(
    *,
    scenario_name: str,
    family: str,
    severity: str,
    seed: int,
    drivers: Mapping[str, float],
    exposures: Mapping[str, float],
    base_resources: float,
    noise_scale: float,
) -> OutcomeRecord:
    rng = random.Random(f"{seed}:{scenario_name}")
    benchmark = deterministic_component_benchmark(drivers, exposures)
    components: dict[str, float] = {}
    for index, (name, value) in enumerate(benchmark.items()):
        model_overlay = 1.015 + 0.002 * index
        noise = 1.0 + rng.uniform(-noise_scale, noise_scale)
        components[name] = max(value * model_overlay * noise, 0.0)
    requirement = sum(components.values())
    resource_multiplier = drivers.get("available_resource_multiplier", 1.0)
    seed_resource_noise = 1.0 + rng.uniform(-noise_scale / 2.0, noise_scale / 2.0)
    resources = max(base_resources * resource_multiplier * seed_resource_noise, 0.0)
    lcr = resources / requirement if requirement > 0.0 else math.inf
    shortfall = max(requirement - resources, 0.0)
    utilization = requirement / resources if resources > 0.0 else math.inf
    dominant = max(components, key=lambda name: components[name])
    return OutcomeRecord(
        scenario_id=(
            f"{family}_{severity}_{seed}_"
            f"{hashlib.sha256(scenario_name.encode('utf-8')).hexdigest()[:8]}"
        ),
        scenario_name=scenario_name,
        analysis_family=family,
        severity=severity,
        seed=seed,
        stressed_requirement=requirement,
        available_resources=resources,
        lcr=lcr,
        shortfall=shortfall,
        resource_utilization=utilization,
        dominant_component=dominant,
        components=components,
        drivers=dict(drivers),
        exposures=dict(exposures),
    )


def generate_controlled_records(config: Mapping[str, Any]) -> list[OutcomeRecord]:
    controlled = config["controlled"]
    seeds = [int(seed) for seed in controlled["seeds"]]
    exposures = {name: float(controlled["base_exposures"][name]) for name in EXPOSURE_NAMES}
    base_resources = float(controlled["base_available_resources"])
    noise_scale = float(controlled["noise_scale"])
    records: list[OutcomeRecord] = []

    severity_drivers = _severity_drivers()
    for severity, drivers in severity_drivers.items():
        for seed in seeds:
            records.append(
                _controlled_record(
                    scenario_name=f"{severity}_combined_stress",
                    family="scenario_ladder",
                    severity=severity,
                    seed=seed,
                    drivers=drivers,
                    exposures=exposures,
                    base_resources=base_resources,
                    noise_scale=noise_scale,
                )
            )

    sweep_values: dict[str, list[float]] = {
        "yield_shock_bps": [0.0, 50.0, 100.0, 200.0, 350.0],
        "duration_years": [2.0, 3.0, 4.0, 5.0, 7.0],
        "sofr_spike_bps": [0.0, 50.0, 100.0, 200.0, 400.0],
        "rollover_failure_pct": [0.0, 0.10, 0.25, 0.45, 0.70],
        "haircut_increase_pct": [0.0, 0.03, 0.07, 0.12, 0.20],
        "settlement_fail_pct": [0.0, 0.05, 0.12, 0.22, 0.35],
        "member_concentration_pct": [0.10, 0.25, 0.40, 0.55, 0.75],
        "liquidation_horizon_days": [1.0, 2.0, 3.0, 5.0, 7.0],
        "default_set_size": [1.0, 2.0, 3.0, 4.0, 5.0],
        "available_resource_multiplier": [0.60, 0.75, 0.90, 1.00, 1.10],
    }
    baseline = dict(severity_drivers["moderate"])
    for driver, values in sweep_values.items():
        for level, value in enumerate(values):
            drivers = dict(baseline)
            drivers[driver] = value
            for seed in seeds:
                records.append(
                    _controlled_record(
                        scenario_name=f"sweep_{driver}_level_{level}",
                        family=f"sensitivity_{driver}",
                        severity="sensitivity",
                        seed=seed,
                        drivers=drivers,
                        exposures=exposures,
                        base_resources=base_resources,
                        noise_scale=0.0,
                    )
                )
    return records


def _is_close(actual: float, expected: float, absolute: float, relative: float) -> bool:
    if not math.isfinite(actual) or not math.isfinite(expected):
        return actual == expected
    return abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected), 1.0)


def _status(evaluated: int, failed: int) -> str:
    if evaluated == 0:
        return "NOT_EVALUATED"
    return "PASS" if failed == 0 else "FAIL"


def analyze_historical_plausibility(
    records: Sequence[OutcomeRecord], config: Mapping[str, Any], lcr_orientation: str
) -> ValidationResult:
    bounds = config["plausibility_bounds"]
    tol = config["tolerances"]
    rows: list[dict[str, Any]] = []
    passed = 0
    for record in records:
        checks: dict[str, bool] = {}
        numeric_values = [
            record.stressed_requirement,
            record.available_resources,
            record.lcr,
            record.shortfall,
            record.resource_utilization,
            *record.components.values(),
            *record.drivers.values(),
        ]
        checks["finite_values"] = all(math.isfinite(value) for value in numeric_values)
        checks["nonnegative_components"] = all(value >= 0.0 for value in record.components.values())
        checks["nonnegative_shortfall"] = record.shortfall >= 0.0
        for metric in (
            "stressed_requirement",
            "available_resources",
            "lcr",
            "resource_utilization",
        ):
            lower, upper = bounds[metric]
            value = float(getattr(record, metric))
            checks[f"{metric}_bounds"] = lower <= value <= upper
        for driver in DRIVER_NAMES:
            lower, upper = bounds[driver]
            checks[f"{driver}_bounds"] = lower <= record.drivers.get(driver, 0.0) <= upper
        expected_shortfall = max(record.stressed_requirement - record.available_resources, 0.0)
        checks["shortfall_identity"] = _is_close(
            record.shortfall,
            expected_shortfall,
            tol["identity_absolute"],
            tol["identity_relative"],
        )
        expected_utilization = (
            record.stressed_requirement / record.available_resources
            if record.available_resources > 0.0
            else math.inf
        )
        checks["utilization_identity"] = _is_close(
            record.resource_utilization,
            expected_utilization,
            tol["identity_absolute"],
            tol["identity_relative"],
        )
        expected_lcr = (
            record.available_resources / record.stressed_requirement
            if lcr_orientation == "resources_over_requirement" and record.stressed_requirement > 0.0
            else record.stressed_requirement / record.available_resources
            if record.available_resources > 0.0
            else math.inf
        )
        checks["lcr_identity"] = _is_close(
            record.lcr,
            expected_lcr,
            tol["identity_absolute"],
            tol["identity_relative"],
        )
        row_pass = all(checks.values())
        passed += int(row_pass)
        failed_checks = [name for name, value in checks.items() if not value]
        rows.append(
            {
                "scenario_id": record.scenario_id,
                "scenario_name": record.scenario_name,
                "seed": record.seed,
                "status": "PASS" if row_pass else "FAIL",
                "failed_checks": ";".join(failed_checks),
            }
        )
    pass_rate = passed / len(records) if records else 0.0
    minimum = float(tol["plausibility_pass_rate"])
    failed = 0 if records and pass_rate >= minimum else 1
    return ValidationResult(
        name="historical_plausibility",
        status=_status(1 if records else 0, failed),
        evaluated=len(records),
        passed=passed,
        failed=len(records) - passed,
        metrics={"record_pass_rate": pass_rate, "minimum_required": minimum},
        rows=rows,
        notes=[
            (
                "Plausibility tests are structural and economically bounded; "
                "they do not establish empirical FICC calibration."
            )
        ],
    )


def _nondecreasing(values: Sequence[float], tolerance: float) -> bool:
    pairs = itertools.pairwise(values)
    return all(next_value + tolerance >= current for current, next_value in pairs)


def _nonincreasing(values: Sequence[float], tolerance: float) -> bool:
    pairs = itertools.pairwise(values)
    return all(next_value <= current + tolerance for current, next_value in pairs)


def analyze_scenario_rank_ordering(
    records: Sequence[OutcomeRecord], config: Mapping[str, Any], lcr_orientation: str
) -> ValidationResult:
    order = {name: index for index, name in enumerate(config["severity_order"])}
    tolerance = float(config["tolerances"]["monotonic_absolute"])
    grouped: dict[int, list[OutcomeRecord]] = defaultdict(list)
    for record in records:
        if record.analysis_family == "scenario_ladder" and record.severity in order:
            grouped[record.seed].append(record)
    rows: list[dict[str, Any]] = []
    passed = 0
    evaluated = 0
    for seed, group in sorted(grouped.items()):
        ordered = sorted(group, key=lambda item: order[item.severity])
        if len({item.severity for item in ordered}) < len(order):
            rows.append(
                {
                    "seed": seed,
                    "metric": "complete_severity_ladder",
                    "status": "FAIL",
                    "details": "One or more configured severity levels are missing.",
                }
            )
            evaluated += 1
            continue
        metrics: list[tuple[str, Sequence[float], str]] = [
            (
                "stressed_requirement",
                [item.stressed_requirement for item in ordered],
                "nondecreasing",
            ),
            (
                "available_resources",
                [item.available_resources for item in ordered],
                "nonincreasing",
            ),
            ("shortfall", [item.shortfall for item in ordered], "nondecreasing"),
            (
                "resource_utilization",
                [item.resource_utilization for item in ordered],
                "nondecreasing",
            ),
            (
                "lcr",
                [item.lcr for item in ordered],
                (
                    "nonincreasing"
                    if lcr_orientation == "resources_over_requirement"
                    else "nondecreasing"
                ),
            ),
        ]
        for metric, values, direction in metrics:
            evaluated += 1
            is_pass = (
                _nondecreasing(values, tolerance)
                if direction == "nondecreasing"
                else _nonincreasing(values, tolerance)
            )
            passed += int(is_pass)
            rows.append(
                {
                    "seed": seed,
                    "metric": metric,
                    "expected_direction": direction,
                    "ordered_values": json.dumps(values),
                    "status": "PASS" if is_pass else "FAIL",
                }
            )
    return ValidationResult(
        name="scenario_rank_ordering",
        status=_status(evaluated, evaluated - passed),
        evaluated=evaluated,
        passed=passed,
        failed=evaluated - passed,
        metrics={"seeds_evaluated": len(grouped), "severity_order": list(order)},
        rows=rows,
    )


def analyze_monotonicity(
    records: Sequence[OutcomeRecord], config: Mapping[str, Any], lcr_orientation: str
) -> ValidationResult:
    tolerance = float(config["tolerances"]["monotonic_absolute"])
    grouped: dict[tuple[str, int], list[OutcomeRecord]] = defaultdict(list)
    for record in records:
        if record.analysis_family.startswith("sensitivity_"):
            driver = record.analysis_family.removeprefix("sensitivity_")
            if driver in DRIVER_NAMES:
                grouped[(driver, record.seed)].append(record)
    rows: list[dict[str, Any]] = []
    passed = 0
    evaluated = 0
    for (driver, seed), group in sorted(grouped.items()):
        ordered = sorted(group, key=lambda item: item.drivers.get(driver, 0.0))
        values = [item.drivers.get(driver, 0.0) for item in ordered]
        if len(set(values)) < 2:
            continue
        requirement_values = [item.stressed_requirement for item in ordered]
        lcr_values = [item.lcr for item in ordered]
        resource_values = [item.available_resources for item in ordered]
        if driver == "available_resource_multiplier":
            checks = [
                ("available_resources", resource_values, "nondecreasing"),
                (
                    "lcr",
                    lcr_values,
                    (
                        "nondecreasing"
                        if lcr_orientation == "resources_over_requirement"
                        else "nonincreasing"
                    ),
                ),
            ]
        else:
            checks = [
                ("stressed_requirement", requirement_values, "nondecreasing"),
                (
                    "lcr",
                    lcr_values,
                    (
                        "nonincreasing"
                        if lcr_orientation == "resources_over_requirement"
                        else "nondecreasing"
                    ),
                ),
            ]
        for metric, observed, direction in checks:
            evaluated += 1
            is_pass = (
                _nondecreasing(observed, tolerance)
                if direction == "nondecreasing"
                else _nonincreasing(observed, tolerance)
            )
            passed += int(is_pass)
            rows.append(
                {
                    "driver": driver,
                    "seed": seed,
                    "metric": metric,
                    "driver_values": json.dumps(values),
                    "observed_values": json.dumps(observed),
                    "expected_direction": direction,
                    "status": "PASS" if is_pass else "FAIL",
                }
            )
    return ValidationResult(
        name="monotonicity",
        status=_status(evaluated, evaluated - passed),
        evaluated=evaluated,
        passed=passed,
        failed=evaluated - passed,
        metrics={"driver_seed_groups": len(grouped)},
        rows=rows,
        notes=[] if evaluated else ["No recognized sensitivity sweep families were available."],
    )


def analyze_component_reconciliation(
    records: Sequence[OutcomeRecord], config: Mapping[str, Any]
) -> ValidationResult:
    threshold = float(config["tolerances"]["component_reconciliation_relative"])
    rows: list[dict[str, Any]] = []
    passed = 0
    evaluated = 0
    for record in records:
        component_sum = sum(record.components.values())
        if component_sum == 0.0:
            continue
        evaluated += 1
        difference = record.stressed_requirement - component_sum
        relative = abs(difference) / max(abs(record.stressed_requirement), abs(component_sum), 1.0)
        is_pass = relative <= threshold
        passed += int(is_pass)
        rows.append(
            {
                "scenario_id": record.scenario_id,
                "scenario_name": record.scenario_name,
                "seed": record.seed,
                "reported_requirement": record.stressed_requirement,
                "component_sum": component_sum,
                "difference": difference,
                "relative_difference": relative,
                "threshold": threshold,
                "status": "PASS" if is_pass else "FAIL",
            }
        )
    return ValidationResult(
        name="component_reconciliation",
        status=_status(evaluated, evaluated - passed),
        evaluated=evaluated,
        passed=passed,
        failed=evaluated - passed,
        metrics={"threshold": threshold},
        rows=rows,
        notes=[] if evaluated else ["No recognized component columns were available."],
    )


def analyze_independent_benchmarks(
    records: Sequence[OutcomeRecord], config: Mapping[str, Any]
) -> ValidationResult:
    threshold = float(config["tolerances"]["benchmark_relative"])
    rows: list[dict[str, Any]] = []
    passed = 0
    evaluated = 0
    directional_matches = 0
    by_family_seed: dict[tuple[str, int], list[tuple[float, float]]] = defaultdict(list)
    for record in records:
        if not any(record.exposures.values()):
            continue
        benchmark_components = deterministic_component_benchmark(record.drivers, record.exposures)
        benchmark_total = sum(benchmark_components.values())
        if benchmark_total <= 0.0:
            continue
        evaluated += 1
        relative = abs(record.stressed_requirement - benchmark_total) / max(
            abs(record.stressed_requirement), abs(benchmark_total), 1.0
        )
        is_pass = relative <= threshold
        passed += int(is_pass)
        rows.append(
            {
                "scenario_id": record.scenario_id,
                "scenario_name": record.scenario_name,
                "analysis_family": record.analysis_family,
                "seed": record.seed,
                "model_requirement": record.stressed_requirement,
                "deterministic_benchmark": benchmark_total,
                "model_minus_benchmark": record.stressed_requirement - benchmark_total,
                "relative_difference": relative,
                "threshold": threshold,
                "status": "PASS" if is_pass else "FAIL",
            }
        )
        by_family_seed[(record.analysis_family, record.seed)].append(
            (benchmark_total, record.stressed_requirement)
        )
    direction_evaluated = 0
    for pairs in by_family_seed.values():
        ordered = sorted(pairs)
        adjacent_pairs = itertools.pairwise(ordered)
        for (benchmark_a, model_a), (benchmark_b, model_b) in adjacent_pairs:
            if benchmark_b == benchmark_a:
                continue
            direction_evaluated += 1
            directional_matches += int((benchmark_b - benchmark_a) * (model_b - model_a) >= 0.0)
    return ValidationResult(
        name="independent_benchmarks",
        status=_status(evaluated, evaluated - passed),
        evaluated=evaluated,
        passed=passed,
        failed=evaluated - passed,
        metrics={
            "threshold": threshold,
            "directional_agreement": (
                directional_matches / direction_evaluated if direction_evaluated else None
            ),
            "directional_pairs": direction_evaluated,
        },
        rows=rows,
        notes=[]
        if evaluated
        else ["Exposure inputs required by the deterministic challenger were unavailable."],
    )


def _coefficient_of_variation(values: Sequence[float]) -> float:
    if len(values) < 2:
        return 0.0
    mean = statistics.fmean(values)
    if mean == 0.0:
        return 0.0 if all(value == 0.0 for value in values) else math.inf
    return statistics.pstdev(values) / abs(mean)


def analyze_seed_stability(
    records: Sequence[OutcomeRecord], config: Mapping[str, Any]
) -> ValidationResult:
    cv_threshold = float(config["tolerances"]["seed_cv"])
    range_threshold = float(config["tolerances"]["seed_range_relative"])
    grouped: dict[str, list[OutcomeRecord]] = defaultdict(list)
    for record in records:
        grouped[record.scenario_name].append(record)
    rows: list[dict[str, Any]] = []
    passed = 0
    evaluated = 0
    for scenario_name, group in sorted(grouped.items()):
        if len({item.seed for item in group}) < 2:
            continue
        for metric in ("stressed_requirement", "lcr"):
            values = [float(getattr(item, metric)) for item in group]
            cv = _coefficient_of_variation(values)
            mean = statistics.fmean(values)
            relative_range = (max(values) - min(values)) / max(abs(mean), 1.0)
            is_pass = cv <= cv_threshold and relative_range <= range_threshold
            evaluated += 1
            passed += int(is_pass)
            rows.append(
                {
                    "scenario_name": scenario_name,
                    "metric": metric,
                    "seed_count": len(values),
                    "mean": mean,
                    "standard_deviation": statistics.pstdev(values),
                    "coefficient_of_variation": cv,
                    "relative_range": relative_range,
                    "cv_threshold": cv_threshold,
                    "range_threshold": range_threshold,
                    "status": "PASS" if is_pass else "FAIL",
                }
            )
    return ValidationResult(
        name="seed_stability",
        status=_status(evaluated, evaluated - passed),
        evaluated=evaluated,
        passed=passed,
        failed=evaluated - passed,
        metrics={"cv_threshold": cv_threshold, "range_threshold": range_threshold},
        rows=rows,
        notes=[] if evaluated else ["At least two seeds per scenario are required."],
    )


def _quantile(values: Sequence[float], probability: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * probability
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def analyze_tail_behavior(
    records: Sequence[OutcomeRecord], config: Mapping[str, Any], lcr_orientation: str
) -> ValidationResult:
    if len(records) < 5:
        return ValidationResult(
            name="tail_behavior",
            status="NOT_EVALUATED",
            evaluated=0,
            passed=0,
            failed=0,
            notes=["At least five records are required for tail analysis."],
        )
    requirements = [item.stressed_requirement for item in records]
    shortfalls = [item.shortfall for item in records]
    lcrs = [item.lcr for item in records]
    q50 = _quantile(requirements, 0.50)
    q95 = _quantile(requirements, 0.95)
    q99 = _quantile(requirements, 0.99)
    tail_records = [item for item in records if item.stressed_requirement >= q95]
    non_tail_records = [item for item in records if item.stressed_requirement < q95]
    tail_shortfall_rate = (
        sum(item.shortfall > 0.0 for item in tail_records) / len(tail_records)
        if tail_records
        else 0.0
    )
    body_shortfall_rate = (
        sum(item.shortfall > 0.0 for item in non_tail_records) / len(non_tail_records)
        if non_tail_records
        else 0.0
    )
    tail_lcr = statistics.fmean(item.lcr for item in tail_records)
    body_lcr = statistics.fmean(item.lcr for item in non_tail_records)
    checks = {
        "positive_tail_amplification": q95 >= q50,
        "ordered_tail_quantiles": q99 >= q95 >= q50,
        "tail_shortfall_not_lower": tail_shortfall_rate >= body_shortfall_rate,
        "tail_lcr_direction": tail_lcr <= body_lcr
        if lcr_orientation == "resources_over_requirement"
        else tail_lcr >= body_lcr,
    }
    rows = [
        {"metric": name, "status": "PASS" if value else "FAIL"} for name, value in checks.items()
    ]
    passed = sum(checks.values())
    return ValidationResult(
        name="tail_behavior",
        status=_status(len(checks), len(checks) - passed),
        evaluated=len(checks),
        passed=passed,
        failed=len(checks) - passed,
        metrics={
            "requirement_q50": q50,
            "requirement_q95": q95,
            "requirement_q99": q99,
            "tail_amplification_q95_over_q50": q95 / q50 if q50 else math.inf,
            "shortfall_q95": _quantile(shortfalls, 0.95),
            "lcr_q05": _quantile(lcrs, 0.05),
            "tail_shortfall_rate": tail_shortfall_rate,
            "body_shortfall_rate": body_shortfall_rate,
            "tail_mean_lcr": tail_lcr,
            "body_mean_lcr": body_lcr,
            "tail_record_count": len(tail_records),
        },
        rows=rows,
    )


def analyze_economic_interpretation(records: Sequence[OutcomeRecord]) -> ValidationResult:
    rows: list[dict[str, Any]] = []
    grouped: dict[str, list[OutcomeRecord]] = defaultdict(list)
    for record in records:
        grouped[record.analysis_family].append(record)
    for family, group in sorted(grouped.items()):
        component_totals = {
            component: sum(item.components.get(component, 0.0) for item in group)
            for component in COMPONENT_NAMES
        }
        total = sum(component_totals.values())
        dominant = (
            max(component_totals, key=lambda name: component_totals[name])
            if total > 0.0
            else "unavailable"
        )
        dominant_share = component_totals.get(dominant, 0.0) / total if total > 0.0 else 0.0
        mean_requirement = statistics.fmean(item.stressed_requirement for item in group)
        mean_resources = statistics.fmean(item.available_resources for item in group)
        shortfall_frequency = sum(item.shortfall > 0.0 for item in group) / len(group)
        rows.append(
            {
                "analysis_family": family,
                "record_count": len(group),
                "dominant_component": dominant,
                "dominant_component_share": dominant_share,
                "mean_stressed_requirement": mean_requirement,
                "mean_available_resources": mean_resources,
                "shortfall_frequency": shortfall_frequency,
                "interpretation": (
                    f"{dominant} is the largest aggregate contributor; "
                    f"its share is {dominant_share:.1%}. Shortfalls occur in "
                    f"{shortfall_frequency:.1%} of observations."
                ),
            }
        )
    return ValidationResult(
        name="economic_interpretation",
        status=_status(len(rows), 0),
        evaluated=len(rows),
        passed=len(rows),
        failed=0,
        metrics={"families_interpreted": len(rows)},
        rows=rows,
    )


def run_validation_suite(
    records: Sequence[OutcomeRecord],
    config: Mapping[str, Any],
    *,
    lcr_orientation: str = "resources_over_requirement",
) -> list[ValidationResult]:
    return [
        analyze_historical_plausibility(records, config, lcr_orientation),
        analyze_scenario_rank_ordering(records, config, lcr_orientation),
        analyze_monotonicity(records, config, lcr_orientation),
        analyze_independent_benchmarks(records, config),
        analyze_component_reconciliation(records, config),
        analyze_seed_stability(records, config),
        analyze_tail_behavior(records, config, lcr_orientation),
        analyze_economic_interpretation(records),
    ]


def determine_overall_status(results: Sequence[ValidationResult], evidence_mode: str) -> str:
    statuses = {result.status for result in results}
    if "FAIL" in statuses:
        return "FAIL"
    if "NOT_EVALUATED" in statuses:
        return "REVIEW"
    return "PASS_CONTROLLED_ONLY" if evidence_mode == "controlled_benchmark" else "PASS"


def write_csv(path: Path, rows: Sequence[Mapping[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("status\nNOT_EVALUATED\n", encoding="utf-8")
        return
    fieldnames: list[str] = []
    seen: set[str] = set()
    for row in rows:
        for key in row:
            if key not in seen:
                fieldnames.append(key)
                seen.add(key)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def _format_metric(value: Any) -> str:
    if value is None:
        return "N/A"
    if isinstance(value, float):
        if math.isfinite(value):
            return f"{value:.6g}"
        return str(value)
    return str(value)


def render_report(
    *,
    evidence_mode: str,
    input_path: str | None,
    records: Sequence[OutcomeRecord],
    results: Sequence[ValidationResult],
    overall_status: str,
    metadata: Mapping[str, Any],
) -> str:
    lines = [
        "# Section 27 â€” Outcomes and Benchmark Analysis",
        "",
        f"**Overall status:** {overall_status}",
        f"**Evidence mode:** {evidence_mode}",
        (
            "**Input:** "
            f"{input_path or 'controlled benchmark dataset generated by the independent validator'}"
        ),
        f"**Records analyzed:** {len(records)}",
        (
            "**LCR orientation detected/used:** "
            f"{metadata.get('lcr_orientation', 'resources_over_requirement')}"
        ),
        "",
        "## Scope limitation",
        "",
        (
            "Actual FICC outcome data are not used. Historical plausibility is therefore "
            "assessed through structural identities, bounded assumptions, scenario ordering, "
            "independent deterministic challenge calculations, seed stability, and tail "
            "behavior. A controlled-benchmark PASS is not empirical validation of FICC "
            "outcomes or calibration."
        ),
        "",
        "## Gate summary",
        "",
        "| Test | Status | Evaluated | Passed | Failed | Pass rate |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for result in results:
        pass_rate = "N/A" if result.pass_rate is None else f"{result.pass_rate:.1%}"
        lines.append(
            f"| {result.name} | {result.status} | {result.evaluated} | "
            f"{result.passed} | {result.failed} | {pass_rate} |"
        )
    lines.extend(["", "## Key metrics", ""])
    for result in results:
        lines.append(f"### {result.name}")
        if result.metrics:
            for key, value in result.metrics.items():
                lines.append(f"- **{key}:** {_format_metric(value)}")
        if result.notes:
            for note in result.notes:
                lines.append(f"- {note}")
        lines.append("")
    economic = next(
        (result for result in results if result.name == "economic_interpretation"),
        None,
    )
    if economic and economic.rows:
        lines.extend(["## Economic interpretation", ""])
        for row in economic.rows:
            lines.append(f"- **{row['analysis_family']}:** {row['interpretation']}")
        lines.append("")
    warnings = cast(Sequence[str], metadata.get("warnings", []))
    if warnings:
        lines.extend(["## Input warnings", ""])
        lines.extend(f"- {warning}" for warning in warnings)
        lines.append("")
    lines.extend(
        [
            "## Independent-validation conclusion",
            "",
            (
                "The outcome analysis evaluates behavior rather than matching unavailable "
                "realized FICC losses or liquidity calls. Final model-risk conclusions must "
                "distinguish controlled engineering evidence from external model-output "
                "evidence and must retain unresolved NOT_EVALUATED gates as limitations."
            ),
            "",
        ]
    )
    return "\n".join(lines)


def export_validation_outputs(
    output_dir: str | Path,
    *,
    evidence_mode: str,
    input_path: str | None,
    records: Sequence[OutcomeRecord],
    results: Sequence[ValidationResult],
    metadata: Mapping[str, Any],
) -> dict[str, Any]:
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    overall_status = determine_overall_status(results, evidence_mode)
    write_csv(output / "normalized_outcomes.csv", [record.to_flat_dict() for record in records])
    file_map = {
        "historical_plausibility": "historical_plausibility.csv",
        "scenario_rank_ordering": "scenario_rank_ordering.csv",
        "monotonicity": "monotonicity_results.csv",
        "independent_benchmarks": "independent_benchmark_comparison.csv",
        "component_reconciliation": "component_reconciliation.csv",
        "seed_stability": "seed_stability.csv",
        "tail_behavior": "tail_behavior.csv",
        "economic_interpretation": "economic_interpretation.csv",
    }
    for result in results:
        write_csv(output / file_map[result.name], result.rows)
    summary = {
        "section": 27,
        "title": "Outcomes and benchmark analysis",
        "overall_status": overall_status,
        "evidence_mode": evidence_mode,
        "input_path": input_path,
        "record_count": len(records),
        "metadata": dict(metadata),
        "results": [result.to_summary() for result in results],
        "limitations": [
            "Actual FICC outcomes are unavailable and are not inferred.",
            (
                "Controlled benchmark results are engineering evidence, not empirical "
                "outcome validation."
            ),
            "External model outputs require compatible fields for every gate to be evaluated.",
        ],
    }
    (output / "section27_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8"
    )
    report = render_report(
        evidence_mode=evidence_mode,
        input_path=input_path,
        records=records,
        results=results,
        overall_status=overall_status,
        metadata=metadata,
    )
    (output / "section27_validation_report.md").write_text(report, encoding="utf-8")
    return summary


def execute_section27(
    *,
    config_path: str | Path | None,
    output_dir: str | Path,
    input_path: str | Path | None = None,
) -> dict[str, Any]:
    config = load_config(config_path)
    if input_path:
        records, metadata = load_records(input_path)
        evidence_mode = "external_model_output"
        resolved_input = str(Path(input_path))
    else:
        records = generate_controlled_records(config)
        metadata = {
            "lcr_orientation": "resources_over_requirement",
            "warnings": [
                "No external model-output file was supplied; controlled benchmark mode was used."
            ],
        }
        evidence_mode = "controlled_benchmark"
        resolved_input = None
    results = run_validation_suite(
        records,
        config,
        lcr_orientation=str(metadata.get("lcr_orientation", "resources_over_requirement")),
    )
    return export_validation_outputs(
        output_dir,
        evidence_mode=evidence_mode,
        input_path=resolved_input,
        records=records,
        results=results,
        metadata=metadata,
    )


__all__ = [
    "COMPONENT_NAMES",
    "DRIVER_NAMES",
    "OutcomeRecord",
    "ValidationResult",
    "analyze_component_reconciliation",
    "analyze_historical_plausibility",
    "analyze_independent_benchmarks",
    "analyze_monotonicity",
    "analyze_scenario_rank_ordering",
    "analyze_seed_stability",
    "analyze_tail_behavior",
    "determine_overall_status",
    "deterministic_component_benchmark",
    "execute_section27",
    "export_validation_outputs",
    "generate_controlled_records",
    "load_config",
    "load_records",
    "normalize_records",
    "run_validation_suite",
]
