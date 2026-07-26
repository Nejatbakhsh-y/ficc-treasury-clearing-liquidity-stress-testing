from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

from ficc_liquidity.monitoring.governance import (
    MonitoringGovernanceEngine,
    build_demo_scorecard,
    main,
)

CONFIG_PATH = Path("configs/monitoring_governance.yaml")


def test_green_amber_red_mapping_and_due_dates() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    actions, summary = engine.evaluate(
        build_demo_scorecard(),
        as_of_date="2026-06-30",
        last_validation_date="2026-01-15",
    )

    by_control = actions.set_index("control")
    assert by_control.loc["data_completeness", "traffic_light"] == "GREEN"
    assert by_control.loc["exposure_concentration", "traffic_light"] == "AMBER"
    assert by_control.loc["lcr_distribution", "traffic_light"] == "RED"
    assert by_control.loc["exposure_concentration", "acknowledgment_due_date"] == "2026-07-02"
    assert by_control.loc["lcr_distribution", "remediation_due_date"] == "2026-07-07"
    assert summary.overall_traffic_light == "RED"
    assert summary.monthly_sign_off_status == "BLOCKED_PENDING_RED_BREACH_DECISION"
    assert summary.revalidation_required is True


def test_repeated_amber_triggers_revalidation() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    scorecard = build_demo_scorecard().query("control == 'exposure_concentration'")
    history = pd.DataFrame(
        {
            "as_of_date": ["2026-03-31", "2026-04-30"],
            "control": ["exposure_concentration", "exposure_concentration"],
            "traffic_light": ["AMBER", "AMBER"],
        }
    )

    actions, summary = engine.evaluate(
        scorecard,
        as_of_date="2026-06-30",
        history=history,
        last_validation_date="2026-01-15",
    )

    assert bool(actions.iloc[0]["revalidation_trigger"]) is True
    assert "exposure_concentration:persistent_amber_breach" in summary.revalidation_reasons


def test_material_change_and_overdue_validation_trigger_revalidation() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    scorecard = build_demo_scorecard().query("control == 'data_completeness'")
    change_log = pd.DataFrame({"material_change": [True]})

    _, summary = engine.evaluate(
        scorecard,
        as_of_date="2026-06-30",
        last_validation_date="2025-01-01",
        change_log=change_log,
    )

    assert summary.annual_validation_status == "OVERDUE"
    assert summary.revalidation_required is True
    assert "approved_material_model_change" in summary.revalidation_reasons


def test_write_outputs(tmp_path: Path) -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    actions, summary = engine.evaluate(
        build_demo_scorecard(),
        as_of_date="2026-06-30",
        last_validation_date="2026-01-15",
    )

    paths = engine.write_outputs(actions, summary, tmp_path)

    assert all(path.exists() for path in paths.values())
    payload = json.loads(paths["summary"].read_text(encoding="utf-8"))
    assert payload["overall_traffic_light"] == "RED"
    signoff = pd.read_csv(paths["signoff_template"])
    assert set(signoff["decision"]) == {"PENDING"}


def test_demo_cli(tmp_path: Path) -> None:
    exit_code = main(
        [
            "--demo",
            "--config",
            str(CONFIG_PATH),
            "--output-dir",
            str(tmp_path),
        ]
    )

    assert exit_code == 0
    assert list(tmp_path.glob("monitoring_breach_register_*.csv"))


def test_validation_errors_and_string_material_change() -> None:
    import pytest

    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    with pytest.raises(ValueError, match="Scorecard is missing required columns"):
        engine.evaluate(pd.DataFrame(), as_of_date="2026-06-30")

    bad_status = build_demo_scorecard().iloc[[0]].copy()
    bad_status.loc[:, "status"] = "UNKNOWN"
    with pytest.raises(ValueError, match="Unsupported monitoring status"):
        engine.evaluate(bad_status, as_of_date="2026-06-30")

    bad_history = pd.DataFrame({"control": ["data_completeness"]})
    with pytest.raises(ValueError, match="History is missing required columns"):
        engine.evaluate(
            build_demo_scorecard().iloc[[0]],
            as_of_date="2026-06-30",
            history=bad_history,
        )

    with pytest.raises(ValueError, match="material_change"):
        engine.evaluate(
            build_demo_scorecard().iloc[[0]],
            as_of_date="2026-06-30",
            change_log=pd.DataFrame({"other": [True]}),
        )

    _, summary = engine.evaluate(
        build_demo_scorecard().iloc[[0]],
        as_of_date="2026-06-30",
        last_validation_date="2026-01-15",
        change_log=pd.DataFrame({"material_change": ["yes"]}),
    )
    assert "approved_material_model_change" in summary.revalidation_reasons


def test_green_reporting_and_annual_validation_states(tmp_path: Path) -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    green = build_demo_scorecard().query("control == 'data_completeness'")

    actions, not_evidenced = engine.evaluate(green, as_of_date="2026-06-30")
    assert not_evidenced.annual_validation_status == "NOT_EVIDENCED"
    assert not_evidenced.monthly_sign_off_status == "READY_FOR_SIGNATURE"
    paths = engine.write_outputs(actions, not_evidenced, tmp_path / "not_evidenced")
    report = paths["report"].read_text(encoding="utf-8")
    assert "No amber or red breaches were identified." in report

    _, due_soon = engine.evaluate(
        green,
        as_of_date="2026-06-30",
        last_validation_date="2025-08-15",
    )
    assert due_soon.annual_validation_status == "DUE_SOON"

    _, current = engine.evaluate(
        green,
        as_of_date="2026-06-30",
        last_validation_date="2025-10-15",
    )
    assert current.annual_validation_status == "CURRENT"
    assert current.revalidation_reasons == ()


def test_repeated_red_and_unmatched_history_paths() -> None:
    engine = MonitoringGovernanceEngine.from_yaml(CONFIG_PATH)
    red = build_demo_scorecard().query("control == 'lcr_distribution'").copy()
    red.loc[:, "severity"] = "High"
    red_history = pd.DataFrame(
        {
            "as_of_date": ["2026-05-31"],
            "control": ["lcr_distribution"],
            "traffic_light": ["RED"],
        }
    )
    actions, summary = engine.evaluate(
        red,
        as_of_date="2026-06-30",
        history=red_history,
        last_validation_date="2026-01-15",
    )
    assert bool(actions.iloc[0]["revalidation_trigger"]) is True
    assert "lcr_distribution:repeated_red_breach" in summary.revalidation_reasons

    amber = build_demo_scorecard().query("control == 'exposure_concentration'")
    unrelated_history = pd.DataFrame(
        {
            "as_of_date": ["2026-05-31"],
            "control": ["different_control"],
            "traffic_light": ["AMBER"],
        }
    )
    actions, _ = engine.evaluate(
        amber,
        as_of_date="2026-06-30",
        history=unrelated_history,
        last_validation_date="2026-01-15",
    )
    assert bool(actions.iloc[0]["revalidation_trigger"]) is False


def test_non_demo_cli_and_required_argument_errors(tmp_path: Path) -> None:
    import pytest

    scorecard_path = tmp_path / "scorecard.csv"
    history_path = tmp_path / "history.csv"
    change_path = tmp_path / "change.csv"
    build_demo_scorecard().to_csv(scorecard_path, index=False)
    pd.DataFrame(
        {
            "as_of_date": ["2026-05-31"],
            "control": ["lcr_distribution"],
            "traffic_light": ["RED"],
        }
    ).to_csv(history_path, index=False)
    pd.DataFrame({"material_change": [True]}).to_csv(change_path, index=False)

    exit_code = main(
        [
            "--scorecard",
            str(scorecard_path),
            "--history",
            str(history_path),
            "--change-log",
            str(change_path),
            "--as-of-date",
            "2026-06-30",
            "--last-validation-date",
            "2026-01-15",
            "--output-dir",
            str(tmp_path / "outputs"),
            "--fail-on-red",
        ]
    )
    assert exit_code == 2

    with pytest.raises(ValueError, match="--scorecard"):
        main(["--as-of-date", "2026-06-30"])
    with pytest.raises(ValueError, match="--as-of-date"):
        main(["--scorecard", str(scorecard_path)])
