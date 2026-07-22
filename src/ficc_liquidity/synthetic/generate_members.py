"""Deterministic generator for fictional clearing-member liquidity profiles."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from typing import cast

import numpy as np
import pandas as pd
import yaml

from ficc_liquidity.synthetic.member_schema import (
    SyntheticMember,
    classify_risk,
    validate_members,
)

MATURITY_COLUMNS: tuple[str, ...] = (
    "treasury_position_bills_0_1y_usd",
    "treasury_position_notes_1_3y_usd",
    "treasury_position_notes_3_7y_usd",
    "treasury_position_notes_7_10y_usd",
    "treasury_position_bonds_10_30y_usd",
    "treasury_position_strips_30y_plus_usd",
)


@dataclass(frozen=True, slots=True)
class GenerationSettings:
    """Typed generator settings loaded from the controlled YAML contract."""

    member_count: int
    random_seed: int
    as_of_date: date
    generator_version: str
    ranges: Mapping[str, tuple[float, float]]
    risk_weights: Mapping[str, float]
    elevated_threshold: float
    high_threshold: float


def _require_mapping(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a YAML mapping.")
    return cast(dict[str, object], value)


def _require_scalar(mapping: Mapping[str, object], key: str) -> str | int | float:
    raw = mapping.get(key)
    if isinstance(raw, bool):
        raise ValueError(f"{key} must be a string or numeric scalar.")
    if not isinstance(raw, (str, int, float)):
        raise ValueError(f"{key} must be a string or numeric scalar.")
    return raw


def _as_int(mapping: Mapping[str, object], key: str) -> int:
    return int(_require_scalar(mapping, key))


def _as_float(mapping: Mapping[str, object], key: str) -> float:
    return float(_require_scalar(mapping, key))


def _range_from_mapping(ranges: Mapping[str, object], name: str) -> tuple[float, float]:
    raw = ranges.get(name)
    if not isinstance(raw, list) or len(raw) != 2:
        raise ValueError(f"ranges.{name} must contain exactly two values.")

    lower = float(raw[0])
    upper = float(raw[1])
    if not 0.0 <= lower <= upper:
        raise ValueError(f"ranges.{name} is invalid.")
    return lower, upper


def load_settings(config_path: Path) -> GenerationSettings:
    """Load and validate generator settings from YAML."""
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    root = _require_mapping(loaded, "Configuration")
    generation = _require_mapping(root.get("generation"), "generation")
    ranges_raw = _require_mapping(root.get("ranges"), "ranges")
    risk_raw = _require_mapping(root.get("risk_score"), "risk_score")

    range_names = (
        "total_treasury_position_usd",
        "treasury_turnover_ratio",
        "repo_financing_share",
        "reverse_repo_share",
        "settlement_obligation_share",
        "settlement_fail_rate",
        "collateral_coverage_ratio",
        "qualified_liquid_resource_share",
        "stress_multiplier",
        "maturity_dirichlet_alpha",
    )
    ranges = {name: _range_from_mapping(ranges_raw, name) for name in range_names}

    weights = {
        "concentration": _as_float(risk_raw, "concentration_weight"),
        "funding_dependency": _as_float(risk_raw, "funding_dependency_weight"),
        "settlement_fail": _as_float(risk_raw, "settlement_fail_weight"),
        "collateral_shortfall": _as_float(risk_raw, "collateral_shortfall_weight"),
        "liquidity_shortfall": _as_float(risk_raw, "liquidity_shortfall_weight"),
    }
    if not np.isclose(sum(weights.values()), 1.0):
        raise ValueError("Risk-score weights must sum to one.")

    member_count = _as_int(generation, "member_count")
    if member_count <= 0:
        raise ValueError("generation.member_count must be positive.")

    return GenerationSettings(
        member_count=member_count,
        random_seed=_as_int(generation, "random_seed"),
        as_of_date=date.fromisoformat(str(_require_scalar(generation, "as_of_date"))),
        generator_version=str(_require_scalar(generation, "generator_version")),
        ranges=ranges,
        risk_weights=weights,
        elevated_threshold=_as_float(risk_raw, "elevated_threshold"),
        high_threshold=_as_float(risk_raw, "high_threshold"),
    )


def _uniform(
    generator: np.random.Generator,
    bounds: tuple[float, float],
) -> float:
    return float(generator.uniform(bounds[0], bounds[1]))


def _risk_score(
    *,
    concentration: float,
    funding_dependency: float,
    fail_rate: float,
    collateral_coverage: float,
    liquidity_coverage: float,
    weights: Mapping[str, float],
    maximum_fail_rate: float,
) -> float:
    fail_component = min(fail_rate / maximum_fail_rate, 1.0)
    collateral_shortfall = max(1.0 - min(collateral_coverage, 1.0), 0.0)
    liquidity_shortfall = max(1.0 - min(liquidity_coverage, 1.0), 0.0)
    score = 100.0 * (
        weights["concentration"] * concentration
        + weights["funding_dependency"] * funding_dependency
        + weights["settlement_fail"] * fail_component
        + weights["collateral_shortfall"] * collateral_shortfall
        + weights["liquidity_shortfall"] * liquidity_shortfall
    )
    return min(max(score, 0.0), 100.0)


def generate_members(settings: GenerationSettings) -> list[SyntheticMember]:
    """Generate deterministic fictional member profiles."""
    generator = np.random.default_rng(settings.random_seed)
    members: list[SyntheticMember] = []
    fail_rate_maximum = settings.ranges["settlement_fail_rate"][1]

    for index in range(1, settings.member_count + 1):
        total_position = _uniform(
            generator,
            settings.ranges["total_treasury_position_usd"],
        )
        alpha = _uniform(generator, settings.ranges["maturity_dirichlet_alpha"])
        maturity_weights = generator.dirichlet(np.full(len(MATURITY_COLUMNS), alpha))
        maturity_positions = tuple(float(total_position * weight) for weight in maturity_weights)

        transaction_activity = total_position * _uniform(
            generator,
            settings.ranges["treasury_turnover_ratio"],
        )
        repo_need = transaction_activity * _uniform(
            generator,
            settings.ranges["repo_financing_share"],
        )
        reverse_repo = repo_need * _uniform(
            generator,
            settings.ranges["reverse_repo_share"],
        )
        settlement_obligation = transaction_activity * _uniform(
            generator,
            settings.ranges["settlement_obligation_share"],
        )
        fail_rate = _uniform(generator, settings.ranges["settlement_fail_rate"])
        settlement_fail = settlement_obligation * fail_rate
        stress_multiplier = _uniform(generator, settings.ranges["stress_multiplier"])
        stressed_need = (
            settlement_obligation + repo_need - (0.50 * reverse_repo)
        ) * stress_multiplier
        stressed_need = max(stressed_need, 1.0)

        collateral_coverage = _uniform(
            generator,
            settings.ranges["collateral_coverage_ratio"],
        )
        collateral = stressed_need * collateral_coverage
        qualified_resource_share = _uniform(
            generator,
            settings.ranges["qualified_liquid_resource_share"],
        )
        qualified_resources = collateral * qualified_resource_share

        concentration = max(maturity_positions) / total_position
        funding_dependency = min(repo_need / transaction_activity, 1.0)
        net_repo_dependency = (
            max(repo_need - reverse_repo, 0.0) / repo_need if repo_need > 0.0 else 0.0
        )
        liquidity_coverage = qualified_resources / stressed_need
        liquidity_gap = max(stressed_need - qualified_resources, 0.0)
        score = _risk_score(
            concentration=concentration,
            funding_dependency=funding_dependency,
            fail_rate=fail_rate,
            collateral_coverage=collateral_coverage,
            liquidity_coverage=liquidity_coverage,
            weights=settings.risk_weights,
            maximum_fail_rate=fail_rate_maximum,
        )
        band = classify_risk(
            score,
            elevated_threshold=settings.elevated_threshold,
            high_threshold=settings.high_threshold,
        )

        member = SyntheticMember(
            member_id=f"SYN-MBR-{index:04d}",
            member_label=f"Fictional Clearing Member {index:03d}",
            as_of_date=settings.as_of_date,
            value_class="synthetic",
            generator_version=settings.generator_version,
            actual_ficc_participant=False,
            treasury_position_bills_0_1y_usd=maturity_positions[0],
            treasury_position_notes_1_3y_usd=maturity_positions[1],
            treasury_position_notes_3_7y_usd=maturity_positions[2],
            treasury_position_notes_7_10y_usd=maturity_positions[3],
            treasury_position_bonds_10_30y_usd=maturity_positions[4],
            treasury_position_strips_30y_plus_usd=maturity_positions[5],
            total_treasury_position_usd=total_position,
            treasury_transaction_activity_usd=transaction_activity,
            repo_financing_need_usd=repo_need,
            reverse_repo_position_usd=reverse_repo,
            settlement_obligation_usd=settlement_obligation,
            settlement_fail_usd=settlement_fail,
            collateral_inventory_usd=collateral,
            available_qualified_liquid_resources_usd=qualified_resources,
            stressed_liquidity_need_usd=stressed_need,
            liquidity_gap_usd=liquidity_gap,
            member_concentration_ratio=concentration,
            funding_dependency_ratio=funding_dependency,
            net_repo_dependency_ratio=net_repo_dependency,
            settlement_fail_rate=fail_rate,
            collateral_coverage_ratio=collateral_coverage,
            liquidity_coverage_ratio=liquidity_coverage,
            liquidity_risk_score=score,
            risk_elevated_threshold=settings.elevated_threshold,
            risk_high_threshold=settings.high_threshold,
            liquidity_risk_band=band,
        )
        member.validate()
        members.append(member)

    validate_members(members)
    return members


def members_to_frame(members: Sequence[SyntheticMember]) -> pd.DataFrame:
    """Convert validated members to a stable tabular representation."""
    validate_members(members)
    frame = pd.DataFrame.from_records(member.to_record() for member in members)
    frame = frame.sort_values("member_id", kind="stable").reset_index(drop=True)
    frame["as_of_date"] = pd.to_datetime(frame["as_of_date"])
    return frame


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_outputs(
    members: Sequence[SyntheticMember],
    *,
    output_path: Path,
    manifest_path: Path,
    schema_path: Path,
) -> pd.DataFrame:
    """Write the runtime Parquet file and controlled lineage artifacts."""
    frame = members_to_frame(members)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    schema_path.parent.mkdir(parents=True, exist_ok=True)

    frame.to_parquet(output_path, index=False)

    schema_payload = {
        "schema_version": "1.0",
        "dataset": "synthetic_clearing_members",
        "grain": "one fictional clearing member per as-of date",
        "actual_ficc_participants_permitted": False,
        "required_columns": list(frame.columns),
        "row_count": len(frame),
        "currency": "USD",
        "value_class": "synthetic",
    }
    schema_path.write_text(
        json.dumps(schema_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    manifest = pd.DataFrame(
        [
            {
                "dataset": "synthetic_clearing_members",
                "runtime_file": output_path.as_posix(),
                "sha256": _sha256(output_path),
                "row_count": len(frame),
                "column_count": len(frame.columns),
                "minimum_as_of_date": frame["as_of_date"].min().date().isoformat(),
                "maximum_as_of_date": frame["as_of_date"].max().date().isoformat(),
                "value_class": "synthetic",
                "actual_ficc_participants": False,
                "generated_at_utc": datetime.now(UTC).isoformat(),
            }
        ]
    )
    manifest.to_csv(manifest_path, index=False)
    return frame


def build_parser() -> argparse.ArgumentParser:
    """Build the Section 11 command-line parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/synthetic_members.yaml"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("data/synthetic/synthetic_members.parquet"),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("data/manifests/synthetic_member_manifest.csv"),
    )
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path("data/manifests/synthetic_member_schema.json"),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Generate and validate the controlled Section 11 dataset."""
    arguments = build_parser().parse_args(argv)
    settings = load_settings(arguments.config)
    members = generate_members(settings)
    frame = write_outputs(
        members,
        output_path=arguments.output,
        manifest_path=arguments.manifest,
        schema_path=arguments.schema,
    )
    summary = {
        "actual_ficc_participants": bool(frame["actual_ficc_participant"].any()),
        "member_count": len(frame),
        "output": arguments.output.as_posix(),
        "risk_bands": {
            str(key): int(value)
            for key, value in frame["liquidity_risk_band"].value_counts().items()
        },
        "status": "PASS",
        "value_class": "synthetic",
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
