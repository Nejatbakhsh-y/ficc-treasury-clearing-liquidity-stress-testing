"""Tests for Phase VII, Section 28 uncertainty assessment."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, cast

import numpy as np
import pandas as pd
import pytest
import yaml

from ficc_liquidity.validation import uncertainty_limitations as ul
from ficc_liquidity.validation.uncertainty_limitations import (
    REQUIRED_CATEGORIES,
    TriangularRange,
    build_report,
    build_uncertainty_register,
    load_config,
    one_at_a_time_analysis,
    risk_rating,
    run_assessment,
    simulate_joint_uncertainty,
    summarize_joint_results,
)

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "configs" / "validation" / "section_28_uncertainty.yaml"


def _raw_config() -> dict[str, Any]:
    raw = yaml.safe_load(CONFIG.read_text(encoding="utf-8-sig"))
    if not isinstance(raw, dict):
        raise TypeError("The controlled Section 28 test configuration must be a mapping.")
    return cast(dict[str, Any], raw)


def _write_config(tmp_path: Path, raw: Any) -> Path:
    path = tmp_path / "section_28_test.yaml"
    path.write_text(yaml.safe_dump(raw, sort_keys=False), encoding="utf-8")
    return path


def test_all_required_uncertainty_categories_are_present() -> None:
    config = load_config(CONFIG)
    assert {driver.key for driver in config.drivers} == set(REQUIRED_CATEGORIES)
    assert config.baseline_lcr == pytest.approx(
        config.baseline_resources / config.baseline_requirement
    )


def test_joint_simulation_is_reproducible() -> None:
    config = load_config(CONFIG)
    first = simulate_joint_uncertainty(config, samples=500, seed=2026)
    second = simulate_joint_uncertainty(config, samples=500, seed=2026)
    pd.testing.assert_frame_equal(first, second)


def test_adverse_one_at_a_time_settings_do_not_improve_lcr() -> None:
    config = load_config(CONFIG)
    analysis = one_at_a_time_analysis(config)
    assert (analysis["adverse_lcr"] <= analysis["baseline_lcr"] + 1e-12).all()
    assert (analysis["adverse_lcr_reduction"] >= -1e-12).all()


def test_mitigation_never_increases_residual_risk() -> None:
    config = load_config(CONFIG)
    register = build_uncertainty_register(config)
    assert (register["residual_score"] <= register["inherent_score"]).all()


def test_report_contains_required_sections_and_limitations() -> None:
    config = load_config(CONFIG)
    register = build_uncertainty_register(config)
    one_at_a_time = one_at_a_time_analysis(config)
    simulation = simulate_joint_uncertainty(config, samples=250, seed=2026)
    summary = summarize_joint_results(config, simulation)
    report = build_report(config, register, one_at_a_time, summary)

    required_phrases = (
        "Aggregate-data uncertainty",
        "Synthetic allocation uncertainty",
        "Scenario-selection uncertainty",
        "Parameter uncertainty",
        "Missing intraday information",
        "Participant-level data limitations",
        "Operational and legal assumptions",
        "Model risk from simplified liquidation functions",
        "Required model-use restrictions",
        "Conditionally acceptable for research and portfolio demonstration only",
    )
    for phrase in required_phrases:
        assert phrase in report


def test_shortfall_flag_matches_lcr_definition() -> None:
    config = load_config(CONFIG)
    simulation = simulate_joint_uncertainty(config, samples=500, seed=2026)
    expected = simulation["available_resources"] < simulation["stressed_liquidity_requirement"]
    pd.testing.assert_series_equal(
        simulation["shortfall_flag"].reset_index(drop=True),
        expected.reset_index(drop=True),
        check_names=False,
    )


def test_risk_rating_covers_all_controlled_bands() -> None:
    thresholds = {"low_max": 4, "moderate_max": 9, "high_max": 16}
    assert risk_rating(4, thresholds) == "Low"
    assert risk_rating(9, thresholds) == "Moderate"
    assert risk_rating(16, thresholds) == "High"
    assert risk_rating(17, thresholds) == "Critical"


def test_triangular_range_validation_and_constant_draw() -> None:
    rng = np.random.default_rng(2026)
    constant = TriangularRange(1.0, 1.0, 1.0)
    constant.validate("constant")
    assert (constant.draw(rng, 5) == 1.0).all()

    with pytest.raises(ValueError, match="minimum <= mode <= maximum"):
        TriangularRange(1.1, 1.0, 1.2).validate("invalid")
    with pytest.raises(ValueError, match="strictly positive"):
        TriangularRange(0.0, 0.5, 1.0).validate("invalid")


def test_invalid_configuration_controls(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="YAML mapping"):
        load_config(_write_config(tmp_path, ["not", "a", "mapping"]))

    cases: tuple[tuple[str, Any, str], ...] = (
        ("probability", 0, "probability must be in"),
        ("impact", 6, "impact must be in"),
        ("mitigation_effectiveness", 1.1, "mitigation_effectiveness must be in"),
        ("requirement_weight", -0.1, "weights cannot be negative"),
    )
    for field, value, message in cases:
        raw = _raw_config()
        raw["uncertainty_drivers"][0][field] = value
        with pytest.raises(ValueError, match=message):
            load_config(_write_config(tmp_path, raw))


def test_required_category_and_baseline_controls(tmp_path: Path) -> None:
    raw = _raw_config()
    raw["uncertainty_drivers"] = raw["uncertainty_drivers"][1:]
    with pytest.raises(ValueError, match="Missing required uncertainty categories"):
        load_config(_write_config(tmp_path, raw))

    raw = _raw_config()
    raw["uncertainty_drivers"].append(raw["uncertainty_drivers"][0].copy())
    with pytest.raises(ValueError, match="Duplicate uncertainty categories"):
        load_config(_write_config(tmp_path, raw))

    raw = _raw_config()
    raw["simulation"]["baseline"]["available_resources"] = 0
    with pytest.raises(ValueError, match="Baseline requirement and resources must be positive"):
        load_config(_write_config(tmp_path, raw))

    raw = _raw_config()
    raw["simulation"]["samples"] = 99
    with pytest.raises(ValueError, match="samples must be at least 100"):
        load_config(_write_config(tmp_path, raw))

    raw = _raw_config()
    raw["simulation"]["shortfall_threshold"] = 0
    with pytest.raises(ValueError, match="shortfall_threshold must be positive"):
        load_config(_write_config(tmp_path, raw))


def test_simulation_rejects_nonpositive_sample_count() -> None:
    config = load_config(CONFIG)
    with pytest.raises(ValueError, match="samples must be positive"):
        simulate_joint_uncertainty(config, samples=0)


def test_summary_handles_no_positive_shortfalls() -> None:
    config = load_config(CONFIG)
    simulation = pd.DataFrame(
        {
            "stressed_liquidity_requirement": [100.0, 100.0],
            "available_resources": [120.0, 130.0],
            "lcr": [1.2, 1.3],
            "liquidity_shortfall": [0.0, 0.0],
        }
    )
    summary = summarize_joint_results(config, simulation)
    lookup = dict(zip(summary["metric"], summary["value"], strict=True))
    assert lookup["expected_shortfall_given_shortfall"] == 0.0


def test_non_usd_formatting_and_low_residual_report_branch() -> None:
    assert ul._format_money(1234.0, "EUR") == "1,234 EUR"

    config = load_config(CONFIG)
    register = build_uncertainty_register(config).copy()
    register["residual_rating"] = "Low"
    one_at_a_time = one_at_a_time_analysis(config)
    simulation = simulate_joint_uncertainty(config, samples=100, seed=2026)
    summary = summarize_joint_results(config, simulation)
    report = build_report(config, register, one_at_a_time, summary)
    assert "No driver is rated High or Critical" in report


def test_run_assessment_writes_all_controlled_outputs(tmp_path: Path) -> None:
    outputs = run_assessment(CONFIG, tmp_path / "outputs", samples=150)
    assert set(outputs) == {
        "register",
        "one_at_a_time",
        "simulation",
        "summary",
        "report",
        "summary_json",
        "tornado_figure",
        "distribution_figure",
    }
    for path in outputs.values():
        assert path.exists()
        assert path.stat().st_size > 0


def test_cli_main_executes_with_explicit_paths(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    output_dir = tmp_path / "cli_outputs"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "uncertainty_limitations",
            "--config",
            str(CONFIG),
            "--output-dir",
            str(output_dir),
            "--samples",
            "100",
        ],
    )
    assert ul.main() == 0
    captured = capsys.readouterr()
    assert "Section 28 uncertainty assessment completed." in captured.out
    assert (output_dir / "section_28_uncertainty_limitations.md").exists()
