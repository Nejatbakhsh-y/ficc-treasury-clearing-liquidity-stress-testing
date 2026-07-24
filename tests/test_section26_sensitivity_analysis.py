from __future__ import annotations

from pathlib import Path
from typing import Any

import pandas as pd
import pytest
import yaml

from ficc_liquidity.validation.independent_implementation import (
    calculate_member_stress,
    calculate_qualified_resources,
)
from ficc_liquidity.validation.sensitivity_analysis import (
    REQUIRED_SENSITIVITIES,
    apply_sensitivity,
    calculate_default_set_result,
    load_sensitivity_specs,
    run_analysis,
    run_sensitivity_grid,
    summarize_sensitivities,
)

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "configs" / "sensitivity_analysis.yaml"


def _load() -> tuple[dict[str, Any], pd.DataFrame, pd.DataFrame]:
    config = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
    members = pd.read_csv(ROOT / "data" / "validation" / "fixtures" / "section25_members.csv")
    resources = pd.read_csv(
        ROOT / "data" / "validation" / "fixtures" / "section25_resources.csv",
        keep_default_na=False,
    )
    return config, members, resources


def test_all_required_sensitivities_are_configured() -> None:
    config, _, _ = _load()
    specs = load_sensitivity_specs(config)
    assert tuple(spec.name for spec in specs) == REQUIRED_SENSITIVITIES


def test_baseline_reproduces_independent_cover_results() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    independent_members = calculate_member_stress(members)
    independent_resources = calculate_qualified_resources(resources)
    baseline = detailed.loc[
        detailed["sensitivity_name"].eq("yield_shocks") & detailed["sensitivity_value"].eq(1.0)
    ]
    for _, row in baseline.iterrows():
        size = 1 if row["coverage_basis"] == "cover1" else 2
        direct = calculate_default_set_result(
            independent_members, independent_resources, str(row["scenario_id"]), size
        )
        assert float(row["stressed_requirement"]) == pytest.approx(
            direct["stressed_requirement"], rel=1.0e-12
        )
        assert float(row["available_resources"]) == pytest.approx(
            direct["available_resources"], rel=1.0e-12
        )
        assert float(row["lcr"]) == pytest.approx(direct["lcr"], rel=1.0e-12)


def test_all_directional_controls_pass() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    summary = summarize_sensitivities(detailed, specs, 1.0e-10)
    assert summary["overall_status"].eq("PASS").all(), summary.loc[
        summary["overall_status"].eq("FAIL")
    ].to_dict("records")


def test_available_resource_assumption_leaves_requirement_flat() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    subset = detailed.loc[detailed["sensitivity_name"].eq("available_resource_assumptions")]
    requirement_counts = subset.groupby(["scenario_id", "coverage_basis"])[
        "stressed_requirement"
    ].nunique()
    assert requirement_counts.eq(1).all()
    for _, group in subset.groupby(["scenario_id", "coverage_basis"]):
        ordered = group.sort_values("sensitivity_value")
        assert ordered["available_resources"].is_monotonic_increasing
        assert ordered["lcr"].is_monotonic_increasing


def test_default_set_size_is_nested_and_requirement_is_nondecreasing() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    detailed = run_sensitivity_grid(members, resources, specs)
    subset = detailed.loc[detailed["sensitivity_name"].eq("default_set_size")]
    for _, group in subset.groupby("scenario_id"):
        ordered = group.sort_values("sensitivity_value")
        assert ordered["stressed_requirement"].is_monotonic_increasing
        prior: set[str] = set()
        for members_value in ordered["default_members"].astype(str):
            current = set(members_value.split("|"))
            assert prior.issubset(current)
            prior = current


def test_fraction_sensitivities_are_capped() -> None:
    config, members, resources = _load()
    specs = {spec.name: spec for spec in load_sensitivity_specs(config)}
    shocked, _, _ = apply_sensitivity(
        members, resources, specs["rollover_failure_percentages"], 2.0
    )
    assert shocked["repo_rollover_failure_rate"].max() <= 1.0
    shocked, _, _ = apply_sensitivity(members, resources, specs["haircut_increases"], 3.0)
    assert shocked["haircut_increase_pct"].max() <= 1.0
    _, shocked_resources, _ = apply_sensitivity(
        members, resources, specs["available_resource_assumptions"], 1.25
    )
    assert shocked_resources["availability_factor"].max() <= 1.0


def test_analysis_is_deterministic_and_inputs_are_immutable() -> None:
    config, members, resources = _load()
    specs = load_sensitivity_specs(config)
    members_before = members.copy(deep=True)
    resources_before = resources.copy(deep=True)
    first = run_sensitivity_grid(members, resources, specs)
    second = run_sensitivity_grid(members, resources, specs)
    pd.testing.assert_frame_equal(first, second)
    pd.testing.assert_frame_equal(members, members_before)
    pd.testing.assert_frame_equal(resources, resources_before)


def test_missing_dimension_is_rejected() -> None:
    config, _, _ = _load()
    dimensions = config["analysis"]["dimensions"]
    dimensions.pop("yield_shocks")
    with pytest.raises(ValueError, match="Missing"):
        load_sensitivity_specs(config)


def test_runner_writes_pass_evidence() -> None:
    evidence = run_analysis(CONFIG_PATH)
    assert evidence["overall_status"] == "PASS"
    assert evidence["failed_directional_groups"] == 0
    assert evidence["sensitivities_executed"] == sorted(REQUIRED_SENSITIVITIES)
