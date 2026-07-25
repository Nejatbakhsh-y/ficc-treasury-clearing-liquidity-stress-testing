from __future__ import annotations

from pathlib import Path

import pandas as pd

from ficc_liquidity.monitoring.monthly import MonthlyMonitoringEngine, build_demo_inputs

CONFIG = Path(__file__).parents[1] / "configs" / "monitoring.yaml"


def test_demo_run_executes_all_section_29_controls() -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    scorecard, summary = engine.run(**build_demo_inputs(), as_of_date="2026-06-30")

    assert summary.control_count == 11
    assert set(scorecard["control"]) == {
        "data_completeness",
        "schema_changes",
        "missing_observations",
        "historical_range_breaches",
        "parameter_changes",
        "exposure_concentration",
        "lcr_distribution",
        "scenario_rank_stability",
        "component_contribution_drift",
        "sensitivity_changes",
        "reconciliation_failures",
    }
    assert summary.failure_count == 0


def test_framework_detects_material_monitoring_failures() -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    inputs = build_demo_inputs()
    current = inputs["current"].copy()
    current.loc[current.index[:100], "lcr"] = 0.70
    current.loc[current["member_id"] != "SYNTH_MEMBER_01", "exposure"] = 1.0
    inputs["current"] = current
    inputs["reconciliation"] = pd.DataFrame({"check_name": ["a", "b"], "passed": [False, False]})

    scorecard, summary = engine.run(**inputs, as_of_date="2026-06-30")
    status_by_control = scorecard.set_index("control")["status"].to_dict()

    assert summary.overall_status == "FAIL"
    assert status_by_control["lcr_distribution"] == "FAIL"
    assert status_by_control["exposure_concentration"] == "FAIL"
    assert status_by_control["reconciliation_failures"] == "FAIL"


def test_outputs_are_persisted(tmp_path: Path) -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    scorecard, summary = engine.run(**build_demo_inputs(), as_of_date="2026-06-30")

    paths = engine.write_outputs(scorecard, summary, tmp_path)

    assert all(path.exists() for path in paths.values())
    assert "Monthly Model Monitoring Report" in paths["report"].read_text(encoding="utf-8")


def test_unavailable_inputs_schema_and_parameter_change_branches() -> None:
    engine = MonthlyMonitoringEngine.from_yaml(CONFIG)
    current = pd.DataFrame(
        {
            "member_id": ["SYNTH_MEMBER_01"],
            "scenario": ["moderate"],
            "exposure": [1.0],
        }
    )

    scorecard, summary = engine.run(
        current,
        baseline=pd.DataFrame(),
        current_parameters={"nested": {"alpha": 2.0}, "mode": "new"},
        previous_parameters={
            "nested": {"alpha": 1.0},
            "mode": "old",
            "removed": 1,
        },
        current_sensitivity=pd.DataFrame({"parameter": ["x"]}),
        previous_sensitivity=pd.DataFrame({"parameter": ["x"]}),
        reconciliation=pd.DataFrame({"difference": [2.0], "tolerance": [1.0]}),
    )

    statuses = scorecard.set_index("control")["status"].to_dict()
    assert summary.overall_status == "FAIL"
    assert statuses["data_completeness"] == "FAIL"
    assert statuses["schema_changes"] == "FAIL"
    assert statuses["parameter_changes"] == "FAIL"
    assert statuses["reconciliation_failures"] == "WARN"


def test_cli_demo_run(tmp_path: Path) -> None:
    from ficc_liquidity.monitoring.monthly import main

    exit_code = main(
        [
            "--config",
            str(CONFIG),
            "--demo",
            "--output-dir",
            str(tmp_path),
            "--as-of-date",
            "2026-06-30",
        ]
    )

    assert exit_code == 0
    assert list(tmp_path.glob("monthly_monitoring_report_*.md"))
