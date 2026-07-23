from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any, cast

import pandas as pd
import pytest
import yaml

from ficc_liquidity.scenarios.cover_analysis import (
    CoverAnalysisError,
    analyze_cover_sets,
    canonicalize_member_results,
    deterministic_reproduction_check,
    load_cover_analysis_config,
    settings_from_config,
)


def config() -> dict[str, Any]:
    return {
        "model_version": "test-v1",
        "source": {"synthetic_id_pattern": r"^SYN-MBR-[0-9]{4}$"},
        "selection": {"cover_levels": [1, 2]},
        "metrics": {"lcr_minimum_ratio": 1.0},
        "validation": {"reconciliation_tolerance_usd": 0.01},
    }


def member_frame() -> pd.DataFrame:
    rows: list[dict[str, object]] = []
    specifications = {
        "moderate": [
            ("SYN-MBR-0001", 100.0, 80.0, 60.0, 20.0, 10.0, 5.0, 2.0, 1.0, 1.0, 1.0),
            ("SYN-MBR-0002", 80.0, 90.0, 20.0, 30.0, 10.0, 5.0, 5.0, 5.0, 3.0, 2.0),
            ("SYN-MBR-0003", 60.0, 40.0, 10.0, 5.0, 10.0, 10.0, 10.0, 10.0, 3.0, 2.0),
        ],
        "severe": [
            ("SYN-MBR-0001", 150.0, 100.0, 20.0, 70.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0),
            ("SYN-MBR-0002", 140.0, 110.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0, 10.0, 10.0),
            ("SYN-MBR-0003", 50.0, 70.0, 10.0, 5.0, 5.0, 5.0, 5.0, 5.0, 10.0, 5.0),
        ],
    }
    for severity_rank, (scenario_name, members) in enumerate(specifications.items(), start=1):
        for member in members:
            (
                member_id,
                requirement,
                resources,
                settlement,
                repo,
                funding,
                haircut,
                treasury,
                fails,
                concentration,
                buffer,
            ) = member
            rows.append(
                {
                    "member_id": member_id,
                    "scenario_name": scenario_name,
                    "severity_rank": severity_rank,
                    "stressed_liquidity_requirement_usd": requirement,
                    "available_qualified_liquid_resources_usd": resources,
                    "settlement_liquidity_need_usd": settlement,
                    "repo_rollover_need_usd": repo,
                    "incremental_funding_cost_usd": funding,
                    "additional_haircut_requirement_usd": haircut,
                    "treasury_liquidation_loss_usd": treasury,
                    "settlement_fail_requirement_usd": fails,
                    "concentration_adjustment_usd": concentration,
                    "operational_liquidity_buffer_usd": buffer,
                }
            )
    return pd.DataFrame(rows)


def test_cover_metrics_and_selection() -> None:
    settings = settings_from_config(config())
    result = analyze_cover_sets(member_frame(), settings)
    moderate = result.cover_results.loc[
        result.cover_results["scenario_name"].eq("moderate")
    ].set_index("cover_level")

    assert result.passed
    assert moderate.loc[1, "selected_member_ids_json"] == '["SYN-MBR-0001"]'
    assert moderate.loc[2, "selected_member_ids_json"] == ('["SYN-MBR-0001", "SYN-MBR-0002"]')
    assert moderate.loc[1, "cover_stressed_requirement_usd"] == pytest.approx(100.0)
    assert moderate.loc[2, "cover_stressed_requirement_usd"] == pytest.approx(180.0)
    assert moderate.loc[1, "available_resources_usd"] == pytest.approx(80.0)
    assert moderate.loc[1, "liquidity_coverage_ratio"] == pytest.approx(0.8)
    assert moderate.loc[1, "liquidity_shortfall_usd"] == pytest.approx(20.0)
    assert moderate.loc[1, "resource_utilization_ratio"] == pytest.approx(1.25)
    assert moderate.loc[1, "dominant_stress_component"] == "settlement_liquidity_need"
    assert moderate.loc[2, "dominant_stress_component"] == "settlement_liquidity_need"
    assert result.scenario_summary.shape[0] == 2
    assert result.selected_members.shape[0] == 6
    assert result.component_summary.shape[0] == 32


def test_tie_breaking_is_deterministic() -> None:
    frame = member_frame()
    frame.loc[
        frame["scenario_name"].eq("moderate") & frame["member_id"].eq("SYN-MBR-0002"),
        "stressed_liquidity_requirement_usd",
    ] = 100.0
    frame.loc[
        frame["scenario_name"].eq("moderate") & frame["member_id"].eq("SYN-MBR-0002"),
        "operational_liquidity_buffer_usd",
    ] = 22.0
    settings = settings_from_config(config())
    result = analyze_cover_sets(frame, settings)
    cover1 = result.cover_results.loc[
        result.cover_results["scenario_name"].eq("moderate")
        & result.cover_results["cover_level"].eq(1)
    ].iloc[0]
    assert cover1["selected_member_ids_json"] == '["SYN-MBR-0001"]'
    assert deterministic_reproduction_check(frame, settings)


def test_aliases_are_resolved() -> None:
    frame = member_frame().rename(
        columns={
            "member_id": "synthetic_member_id",
            "scenario_name": "hypothetical_scenario_name",
            "stressed_liquidity_requirement_usd": "total_stressed_liquidity_requirement_usd",
            "available_qualified_liquid_resources_usd": "aqlr_usd",
        }
    )
    settings = settings_from_config(config())
    canonical = canonicalize_member_results(frame, settings)
    assert "member_id" in canonical
    assert "scenario_name" in canonical
    assert "liquidity_shortfall_usd" in canonical


def test_missing_severity_rank_is_created() -> None:
    frame = member_frame().drop(columns=["severity_rank"])
    settings = settings_from_config(config())
    canonical = canonicalize_member_results(frame, settings)
    assert canonical["severity_rank"].nunique() == 2


@pytest.mark.parametrize(
    ("mutation", "match"),
    [
        ("empty", "empty"),
        ("bad_id", "synthetic"),
        ("duplicate", "unique"),
        ("negative", "negative"),
        ("missing", "missing required"),
        ("reconciliation", "do not reconcile"),
        ("infinite", "finite"),
    ],
)
def test_invalid_member_results_are_rejected(mutation: str, match: str) -> None:
    frame = member_frame()
    if mutation == "empty":
        frame = frame.iloc[0:0]
    elif mutation == "bad_id":
        frame.loc[0, "member_id"] = "ACTUAL-MEMBER"
    elif mutation == "duplicate":
        frame = pd.concat([frame, frame.iloc[[0]]], ignore_index=True)
    elif mutation == "negative":
        frame.loc[0, "available_qualified_liquid_resources_usd"] = -1.0
    elif mutation == "missing":
        frame = frame.drop(columns=["repo_rollover_need_usd"])
    elif mutation == "reconciliation":
        current_rollover = float(cast(Any, frame.loc[0, "repo_rollover_need_usd"]))
        frame.loc[0, "repo_rollover_need_usd"] = current_rollover + 1.0
    elif mutation == "infinite":
        frame.loc[0, "repo_rollover_need_usd"] = float("inf")
    with pytest.raises(CoverAnalysisError, match=match):
        analyze_cover_sets(frame, settings_from_config(config()))


def test_scenario_with_too_few_members_is_rejected() -> None:
    frame = member_frame()
    remove_mask = frame["scenario_name"].eq("moderate") & ~frame["member_id"].eq("SYN-MBR-0001")
    frame = frame.loc[~remove_mask].copy()
    with pytest.raises(CoverAnalysisError, match="fewer than 2"):
        analyze_cover_sets(frame, settings_from_config(config()))


def test_configuration_validation(tmp_path: Path) -> None:
    path = tmp_path / "cover.yaml"
    path.write_text(yaml.safe_dump(config()), encoding="utf-8")
    loaded = load_cover_analysis_config(path)
    assert settings_from_config(loaded).cover_levels == (1, 2)

    with pytest.raises(CoverAnalysisError, match="not found"):
        load_cover_analysis_config(tmp_path / "missing.yaml")

    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("- not\n- a\n- mapping\n", encoding="utf-8")
    with pytest.raises(CoverAnalysisError, match="mapping"):
        load_cover_analysis_config(invalid)

    bad = deepcopy(config())
    bad["selection"] = {"cover_levels": [1, 3]}
    with pytest.raises(CoverAnalysisError, match="exactly"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["source"] = {"synthetic_id_pattern": "["}
    with pytest.raises(CoverAnalysisError, match="regex"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["metrics"] = {"lcr_minimum_ratio": 0.0}
    with pytest.raises(CoverAnalysisError, match="positive"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["validation"] = {"reconciliation_tolerance_usd": -1.0}
    with pytest.raises(CoverAnalysisError, match="negative"):
        settings_from_config(bad)


def test_component_configuration_validation() -> None:
    bad = deepcopy(config())
    bad["metrics"] = {"component_columns": "invalid"}
    with pytest.raises(CoverAnalysisError, match="sequence"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["metrics"] = {"component_columns": [{}]}
    with pytest.raises(CoverAnalysisError, match="nonempty"):
        settings_from_config(bad)

    bad = deepcopy(config())
    bad["metrics"] = {
        "component_columns": [
            {"column": "x", "label": "x"},
            {"column": "x", "label": "y"},
        ]
    }
    with pytest.raises(CoverAnalysisError, match="unique"):
        settings_from_config(bad)
