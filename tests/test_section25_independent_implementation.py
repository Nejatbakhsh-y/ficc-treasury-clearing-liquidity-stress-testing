"""Tests for Section 25 independent implementation verification."""

from __future__ import annotations

import ast
from pathlib import Path

import pandas as pd
import pytest

from ficc_liquidity.validation.independent_implementation import (
    ComparisonTolerance,
    calculate_cover_results,
    calculate_member_stress,
    calculate_qualified_resources,
    compare_results,
    reconcile_aggregates,
    select_default_sets,
)


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = PROJECT_ROOT / "data" / "validation" / "fixtures"
MODULE_PATH = (
    PROJECT_ROOT
    / "src"
    / "ficc_liquidity"
    / "validation"
    / "independent_implementation.py"
)


def _load_inputs() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    members = pd.read_csv(FIXTURE_DIR / "section25_members.csv")
    resources = pd.read_csv(
        FIXTURE_DIR / "section25_resources.csv", keep_default_na=False
    )
    controls = pd.read_csv(FIXTURE_DIR / "section25_aggregate_controls.csv")
    return members, resources, controls


def _calculate() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    members, resources, _ = _load_inputs()
    member_results = calculate_member_stress(members)
    qualified_resources = calculate_qualified_resources(resources)
    default_sets = select_default_sets(member_results)
    cover_results = calculate_cover_results(
        member_results, qualified_resources, default_sets
    )
    return member_results, qualified_resources, default_sets, cover_results


def test_independent_module_imports_no_production_package_code() -> None:
    tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
    prohibited: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            prohibited.extend(
                alias.name for alias in node.names if alias.name.startswith("ficc_liquidity")
            )
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module.startswith("ficc_liquidity"):
                prohibited.append(module)
    assert prohibited == []


def test_hand_calculated_stress_components() -> None:
    member_results, _, _, _ = _calculate()
    moderate_m001 = member_results.loc[
        member_results["scenario_id"].eq("moderate")
        & member_results["member_id"].eq("M001")
    ].iloc[0]

    assert moderate_m001["settlement_liquidity_need"] == pytest.approx(250.0)
    assert moderate_m001["repo_rollover_need"] == pytest.approx(100.0)
    assert moderate_m001["incremental_funding_cost"] == pytest.approx(1.0 / 12.0)
    assert moderate_m001["additional_haircut_requirement"] == pytest.approx(14.4)
    assert moderate_m001["treasury_liquidation_loss"] == pytest.approx(48.5)
    assert moderate_m001["settlement_fail_requirement"] == pytest.approx(120.0)
    assert moderate_m001["concentration_adjustment"] == pytest.approx(10.0)
    assert moderate_m001["operational_liquidity_buffer"] == pytest.approx(10.0)
    assert moderate_m001["stressed_liquidity_requirement"] == pytest.approx(
        552.983333333333
    )


def test_default_set_selection_uses_independent_member_requirements() -> None:
    _, _, default_sets, _ = _calculate()
    moderate_cover1 = default_sets.loc[
        default_sets["scenario_id"].eq("moderate")
        & default_sets["coverage_basis"].eq("cover1")
    ]
    moderate_cover2 = default_sets.loc[
        default_sets["scenario_id"].eq("moderate")
        & default_sets["coverage_basis"].eq("cover2")
    ].sort_values("default_rank")

    assert moderate_cover1["member_id"].tolist() == ["M001"]
    assert moderate_cover2["member_id"].tolist() == ["M001", "M002"]


def test_cover_results_exclude_defaulting_member_resources() -> None:
    _, _, _, cover_results = _calculate()
    moderate_cover1 = cover_results.loc[
        cover_results["scenario_id"].eq("moderate")
        & cover_results["coverage_basis"].eq("cover1")
    ].iloc[0]
    severe_cover2 = cover_results.loc[
        cover_results["scenario_id"].eq("severe")
        & cover_results["coverage_basis"].eq("cover2")
    ].iloc[0]

    assert moderate_cover1["available_resources"] == pytest.approx(1056.0)
    assert moderate_cover1["lcr"] == pytest.approx(1.909641640797)
    assert moderate_cover1["liquidity_shortfall"] == pytest.approx(0.0)
    assert severe_cover2["available_resources"] == pytest.approx(740.0)
    assert severe_cover2["liquidity_shortfall"] == pytest.approx(
        1698.297222222222
    )


def test_aggregate_reconciliation_passes() -> None:
    members, resources, controls = _load_inputs()
    qualified_resources = calculate_qualified_resources(resources)
    reconciliation = reconcile_aggregates(members, qualified_resources, controls)

    assert not reconciliation.empty
    assert reconciliation["status"].eq("PASS").all()


def test_control_result_comparison_passes() -> None:
    _, _, _, cover_results = _calculate()
    control_results = pd.read_csv(FIXTURE_DIR / "section25_control_results.csv")
    comparison = compare_results(
        cover_results,
        control_results,
        ComparisonTolerance(absolute=1.0e-8, relative=1.0e-8),
    )

    assert len(comparison) == 20
    assert comparison["status"].eq("PASS").all()


def test_invalid_fraction_is_rejected() -> None:
    members, _, _ = _load_inputs()
    members.loc[0, "repo_rollover_failure_rate"] = 1.2
    with pytest.raises(ValueError, match="between 0 and 1"):
        calculate_member_stress(members)