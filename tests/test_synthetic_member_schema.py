"""Tests for the controlled synthetic clearing-member data model."""

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

import pandas as pd
import pytest
import yaml

from ficc_liquidity.synthetic.generate_members import (
    generate_members,
    load_settings,
    main,
    members_to_frame,
    write_outputs,
)
from ficc_liquidity.synthetic.member_schema import classify_risk, validate_members

CONFIG_PATH = Path("configs/synthetic_members.yaml")
MATURITY_COLUMNS = [
    "treasury_position_bills_0_1y_usd",
    "treasury_position_notes_1_3y_usd",
    "treasury_position_notes_3_7y_usd",
    "treasury_position_notes_7_10y_usd",
    "treasury_position_bonds_10_30y_usd",
    "treasury_position_strips_30y_plus_usd",
]


def test_generation_is_deterministic_and_complete() -> None:
    settings = load_settings(CONFIG_PATH)
    first = members_to_frame(generate_members(settings))
    second = members_to_frame(generate_members(settings))

    pd.testing.assert_frame_equal(first, second)
    assert len(first) == settings.member_count
    assert first["member_id"].is_unique
    assert not first["actual_ficc_participant"].any()
    assert set(first["value_class"]) == {"synthetic"}
    assert first["member_label"].str.fullmatch(r"Fictional Clearing Member \d{3}").all()


def test_member_accounting_and_risk_controls() -> None:
    frame = members_to_frame(generate_members(load_settings(CONFIG_PATH)))

    assert (
        frame[MATURITY_COLUMNS].sum(axis=1) - frame["total_treasury_position_usd"]
    ).abs().max() < 5.0
    assert (frame["settlement_fail_usd"] <= frame["settlement_obligation_usd"]).all()
    assert (
        frame["available_qualified_liquid_resources_usd"] <= frame["collateral_inventory_usd"]
    ).all()
    assert frame["member_concentration_ratio"].between(0.0, 1.0).all()
    assert frame["funding_dependency_ratio"].between(0.0, 1.0).all()
    assert frame["net_repo_dependency_ratio"].between(0.0, 1.0).all()
    assert frame["settlement_fail_rate"].between(0.0, 1.0).all()
    assert frame["liquidity_risk_score"].between(0.0, 100.0).all()
    assert set(frame["liquidity_risk_band"]).issubset({"moderate", "elevated", "high"})


def test_schema_rejects_identity_and_consistency_violations() -> None:
    member = generate_members(load_settings(CONFIG_PATH))[0]

    with pytest.raises(ValueError, match="actual FICC"):
        replace(member, actual_ficc_participant=True).validate()

    with pytest.raises(ValueError, match="fictional naming"):
        replace(member, member_label="Named Financial Institution").validate()

    with pytest.raises(ValueError, match="Settlement fails"):
        replace(
            member,
            settlement_fail_usd=member.settlement_obligation_usd + 1.0,
        ).validate()

    with pytest.raises(ValueError, match="Duplicate"):
        validate_members([member, member])

    with pytest.raises(ValueError, match="At least one"):
        validate_members([])


def test_risk_classification_boundaries() -> None:
    assert classify_risk(0.0) == "moderate"
    assert classify_risk(39.999) == "moderate"
    assert classify_risk(40.0) == "elevated"
    assert classify_risk(65.0) == "high"
    with pytest.raises(ValueError, match="between 0 and 100"):
        classify_risk(100.1)


def test_outputs_include_manifest_and_schema(tmp_path: Path) -> None:
    settings = load_settings(CONFIG_PATH)
    members = generate_members(settings)
    output = tmp_path / "synthetic_members.parquet"
    manifest = tmp_path / "synthetic_member_manifest.csv"
    schema = tmp_path / "synthetic_member_schema.json"

    frame = write_outputs(
        members,
        output_path=output,
        manifest_path=manifest,
        schema_path=schema,
    )

    assert output.exists()
    assert manifest.exists()
    assert schema.exists()
    assert len(pd.read_parquet(output)) == len(frame)

    manifest_frame = pd.read_csv(manifest)
    assert manifest_frame.loc[0, "value_class"] == "synthetic"
    assert not bool(manifest_frame.loc[0, "actual_ficc_participants"])

    schema_payload = json.loads(schema.read_text(encoding="utf-8"))
    assert schema_payload["actual_ficc_participants_permitted"] is False
    assert schema_payload["row_count"] == settings.member_count


def test_cli_generates_requested_paths(tmp_path: Path) -> None:
    output = tmp_path / "members.parquet"
    manifest = tmp_path / "manifest.csv"
    schema = tmp_path / "schema.json"

    exit_code = main(
        [
            "--config",
            str(CONFIG_PATH),
            "--output",
            str(output),
            "--manifest",
            str(manifest),
            "--schema",
            str(schema),
        ]
    )

    assert exit_code == 0
    assert output.exists()
    assert manifest.exists()
    assert schema.exists()


def test_configuration_validation_errors(tmp_path: Path) -> None:
    invalid_root = tmp_path / "invalid_root.yaml"
    invalid_root.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(ValueError, match="Configuration"):
        load_settings(invalid_root)

    payload = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    payload["risk_score"]["liquidity_shortfall_weight"] = 0.99
    invalid_weights = tmp_path / "invalid_weights.yaml"
    invalid_weights.write_text(yaml.safe_dump(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="sum to one"):
        load_settings(invalid_weights)

    payload = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    payload["ranges"]["settlement_fail_rate"] = [0.1]
    invalid_range_length = tmp_path / "invalid_range_length.yaml"
    invalid_range_length.write_text(yaml.safe_dump(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="exactly two"):
        load_settings(invalid_range_length)

    payload = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    payload["ranges"]["settlement_fail_rate"] = [0.5, 0.1]
    invalid_range_order = tmp_path / "invalid_range_order.yaml"
    invalid_range_order.write_text(yaml.safe_dump(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="is invalid"):
        load_settings(invalid_range_order)

    payload = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    payload["generation"]["member_count"] = 0
    invalid_count = tmp_path / "invalid_count.yaml"
    invalid_count.write_text(yaml.safe_dump(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="must be positive"):
        load_settings(invalid_count)

    payload = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    payload["generation"]["member_count"] = True
    invalid_scalar = tmp_path / "invalid_scalar.yaml"
    invalid_scalar.write_text(yaml.safe_dump(payload), encoding="utf-8")
    with pytest.raises(ValueError, match="string or numeric scalar"):
        load_settings(invalid_scalar)
