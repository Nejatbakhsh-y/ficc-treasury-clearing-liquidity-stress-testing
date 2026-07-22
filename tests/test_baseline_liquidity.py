from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.liquidity import baseline_cashflow as model


def _config() -> dict[str, Any]:
    return {
        "model_version": "section-14-v1",
        "source": {
            "member_id_column": "member_id",
            "synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$",
        },
        "liquidity_horizon": {
            "hours": 48,
            "buckets": [
                {"name": "day1_open", "elapsed_hours": 0},
                {"name": "day1_midday", "elapsed_hours": 6},
                {"name": "day1_close", "elapsed_hours": 12},
                {"name": "day2_open", "elapsed_hours": 24},
                {"name": "day2_close", "elapsed_hours": 36},
            ],
        },
        "payment_timing": {
            "settlement_obligations": {
                "day1_open": 0.35,
                "day1_midday": 0.30,
                "day1_close": 0.25,
                "day2_open": 0.10,
                "day2_close": 0.00,
            },
            "repo_maturities": {
                "day1_open": 0.20,
                "day1_midday": 0.30,
                "day1_close": 0.30,
                "day2_open": 0.15,
                "day2_close": 0.05,
            },
            "financing_inflows": {
                "day1_open": 0.10,
                "day1_midday": 0.25,
                "day1_close": 0.30,
                "day2_open": 0.25,
                "day2_close": 0.10,
            },
            "eligible_collateral_availability": {
                "day1_open": 0.00,
                "day1_midday": 0.25,
                "day1_close": 0.45,
                "day2_open": 0.20,
                "day2_close": 0.10,
            },
        },
        "assumptions": {
            "settlement_netting_rate": 0.25,
            "repo_roll_rate": 0.80,
            "reverse_repo_inflow_recognition_rate": 0.95,
            "financing_netting_enabled": True,
            "available_cash_share_of_aqlr": 0.35,
            "eligible_collateral_haircut": 0.05,
            "collateral_operational_availability_rate": 0.90,
        },
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


def _members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "member_id": ["SYN-MBR-0001", "SYN-MBR-0002"],
            "as_of_date": ["2026-07-01", "2026-07-01"],
            "value_class": ["synthetic", "synthetic"],
            "actual_ficc_participant": [False, False],
            "participant_level_inference": [False, False],
            "settlement_obligation_usd": [1_000.0, 800.0],
            "repo_financing_need_usd": [600.0, 400.0],
            "reverse_repo_position_usd": [200.0, 100.0],
            "collateral_inventory_usd": [1_000.0, 800.0],
            "available_qualified_liquid_resources_usd": [700.0, 500.0],
        }
    )


def test_engine_reconciles_all_baseline_components() -> None:
    cashflows, summary, validation = model.run_engine(_members(), _config())

    assert validation.passed
    assert len(cashflows) == 10
    assert len(summary) == 2
    assert summary["gross_settlement_obligation_usd"].tolist() == pytest.approx([1_000.0, 800.0])
    assert summary["repo_maturity_usd"].tolist() == pytest.approx([600.0, 400.0])
    assert summary["financing_inflow_usd"].tolist() == pytest.approx([190.0, 95.0])
    assert summary["modeled_aqlr_usd"].tolist() == pytest.approx([700.0, 500.0])
    assert not cashflows["actual_ficc_participant"].any()


def test_engine_is_independent_of_input_row_order() -> None:
    first = model.run_engine(_members(), _config())
    shuffled = _members().iloc[::-1].reset_index(drop=True)
    second = model.run_engine(shuffled, _config())

    assert first[0].equals(second[0])
    assert first[1].equals(second[1])
    assert first[2].passed and second[2].passed


def test_financing_netting_can_be_disabled() -> None:
    config = _config()
    config["assumptions"]["financing_netting_enabled"] = False
    cashflows, summary, validation = model.run_engine(_members(), config)

    assert validation.passed
    assert cashflows["net_financing_outflow_usd"].sum() == pytest.approx(
        summary["financing_outflow_usd"].sum()
    )
    assert cashflows["recognized_financing_inflow_usd"].sum() == pytest.approx(
        summary["financing_inflow_usd"].sum()
    )


def test_member_id_alias_is_supported() -> None:
    config = _config()
    config["source"]["member_id_column"] = "synthetic_member_id"
    members = _members().rename(columns={"member_id": "synthetic_member_id"})

    _, summary, validation = model.run_engine(members, config)

    assert validation.passed
    assert summary["member_id"].tolist() == ["SYN-MBR-0001", "SYN-MBR-0002"]


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (
            lambda config: config["payment_timing"]["repo_maturities"].update({"day2_close": 0.10}),
            "weights must sum to one",
        ),
        (
            lambda config: config["assumptions"].update({"settlement_netting_rate": 1.10}),
            "must be between zero and one",
        ),
        (
            lambda config: config["liquidity_horizon"].update({"hours": 12}),
            "cover the final time bucket",
        ),
    ],
)
def test_invalid_model_configurations_are_rejected(mutation: Any, message: str) -> None:
    config = _config()
    mutation(config)
    with pytest.raises(model.BaselineLiquidityError, match=message):
        model.load_settings(config)


def test_missing_or_extra_schedule_buckets_are_rejected() -> None:
    config = _config()
    del config["payment_timing"]["settlement_obligations"]["day2_close"]
    config["payment_timing"]["settlement_obligations"]["unexpected"] = 0.0

    with pytest.raises(model.BaselineLiquidityError, match="define every bucket"):
        model.load_settings(config)


@pytest.mark.parametrize(
    ("column", "value", "message"),
    [
        ("member_id", "REAL-MEMBER", "Non-synthetic"),
        ("settlement_obligation_usd", -1.0, "negative"),
        ("reverse_repo_position_usd", 700.0, "exceed repo financing"),
        (
            "available_qualified_liquid_resources_usd",
            1_500.0,
            "exceed collateral inventory",
        ),
    ],
)
def test_invalid_synthetic_member_values_are_rejected(
    column: str,
    value: object,
    message: str,
) -> None:
    members = _members()
    members.loc[0, column] = cast(Any, value)
    settings = model.load_settings(_config())

    with pytest.raises(model.BaselineLiquidityError, match=message):
        model.prepare_members(members, settings)


def test_actual_participant_and_inference_flags_are_rejected() -> None:
    settings = model.load_settings(_config())
    actual = _members()
    actual.loc[0, "actual_ficc_participant"] = True
    inferred = _members()
    inferred.loc[0, "participant_level_inference"] = True

    with pytest.raises(model.BaselineLiquidityError, match="Actual FICC"):
        model.prepare_members(actual, settings)
    with pytest.raises(model.BaselineLiquidityError, match="Participant-level inference"):
        model.prepare_members(inferred, settings)


def test_missing_required_member_column_is_rejected() -> None:
    members = _members().drop(columns="collateral_inventory_usd")
    settings = model.load_settings(_config())

    with pytest.raises(model.BaselineLiquidityError, match="Required synthetic member columns"):
        model.prepare_members(members, settings)


def test_csv_reader_and_configuration_loader(tmp_path: Path) -> None:
    member_path = tmp_path / "members.csv"
    config_path = tmp_path / "config.yaml"
    _members().to_csv(member_path, index=False)
    config_path.write_text(yaml.safe_dump(_config(), sort_keys=False), encoding="utf-8")

    assert len(model.read_member_data(member_path)) == 2
    assert model.load_config(config_path)["model_version"] == "section-14-v1"

    invalid_path = tmp_path / "members.txt"
    invalid_path.write_text("x", encoding="utf-8")
    with pytest.raises(model.BaselineLiquidityError, match="must be CSV or Parquet"):
        model.read_member_data(invalid_path)


def test_cli_writes_controlled_outputs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    member_path = tmp_path / "members.csv"
    config_path = tmp_path / "config.yaml"
    cashflow_path = tmp_path / "cashflows.csv"
    summary_path = tmp_path / "summary.csv"
    manifest_path = tmp_path / "manifest.csv"
    evidence_path = tmp_path / "evidence.txt"
    _members().to_csv(member_path, index=False)
    config_path.write_text(yaml.safe_dump(_config(), sort_keys=False), encoding="utf-8")

    monkeypatch.setattr(
        sys,
        "argv",
        [
            "baseline_cashflow",
            "--members",
            str(member_path),
            "--config",
            str(config_path),
            "--cashflows",
            str(cashflow_path),
            "--summary",
            str(summary_path),
            "--manifest",
            str(manifest_path),
            "--evidence",
            str(evidence_path),
        ],
    )

    assert model.main() == 0
    assert cashflow_path.exists()
    assert summary_path.exists()
    assert manifest_path.exists()
    assert "Section 14 final decision: PASS" in evidence_path.read_text(encoding="utf-8")
    manifest = pd.read_csv(manifest_path)
    assert manifest.loc[0, "gate_status"] == "PASS"
    assert not bool(manifest.loc[0, "actual_ficc_participants"])


def test_invalid_output_extension_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(model.BaselineLiquidityError, match="Output paths"):
        model._write_frame(pd.DataFrame({"a": [1]}), tmp_path / "output.txt")


def test_load_config_rejects_missing_and_nonmapping_files(tmp_path: Path) -> None:
    with pytest.raises(model.BaselineLiquidityError, match="does not exist"):
        model.load_config(tmp_path / "missing.yaml")

    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(model.BaselineLiquidityError, match="must be a YAML mapping"):
        model.load_config(invalid)
