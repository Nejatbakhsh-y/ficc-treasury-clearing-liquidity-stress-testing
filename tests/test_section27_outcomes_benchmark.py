from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

from ficc_liquidity.validation.outcomes_benchmark import (
    COMPONENT_NAMES,
    analyze_component_reconciliation,
    analyze_monotonicity,
    analyze_scenario_rank_ordering,
    execute_section27,
    generate_controlled_records,
    load_config,
    normalize_records,
    run_validation_suite,
)


def test_controlled_suite_has_complete_section27_coverage() -> None:
    config = load_config()
    records = generate_controlled_records(config)
    results = run_validation_suite(records, config)
    result_map = {result.name: result for result in results}

    assert len(records) == 270
    assert set(result_map) == {
        "historical_plausibility",
        "scenario_rank_ordering",
        "monotonicity",
        "independent_benchmarks",
        "component_reconciliation",
        "seed_stability",
        "tail_behavior",
        "economic_interpretation",
    }
    assert all(result.status == "PASS" for result in results)


def test_scenario_rank_ordering_detects_reversal() -> None:
    config = load_config()
    records = generate_controlled_records(config)
    target = next(
        record
        for record in records
        if record.analysis_family == "scenario_ladder"
        and record.severity == "extreme"
        and record.seed == 2026
    )
    corrupted = target.__class__(
        **{
            **target.__dict__,
            "stressed_requirement": 1.0,
            "lcr": target.available_resources,
            "resource_utilization": 1.0 / target.available_resources,
            "shortfall": 0.0,
        }
    )
    modified = [corrupted if record is target else record for record in records]
    result = analyze_scenario_rank_ordering(modified, config, "resources_over_requirement")
    assert result.status == "FAIL"


def test_monotonicity_detects_yield_sweep_reversal() -> None:
    config = load_config()
    records = generate_controlled_records(config)
    group = [
        record
        for record in records
        if record.analysis_family == "sensitivity_yield_shock_bps" and record.seed == 2026
    ]
    highest = max(group, key=lambda item: item.drivers["yield_shock_bps"])
    corrupted = highest.__class__(
        **{
            **highest.__dict__,
            "stressed_requirement": 0.5,
            "lcr": highest.available_resources / 0.5,
            "resource_utilization": 0.5 / highest.available_resources,
            "shortfall": 0.0,
        }
    )
    modified = [corrupted if record is highest else record for record in records]
    result = analyze_monotonicity(modified, config, "resources_over_requirement")
    assert result.status == "FAIL"


def test_component_reconciliation_detects_difference() -> None:
    config = load_config()
    record = generate_controlled_records(config)[0]
    corrupted = record.__class__(
        **{
            **record.__dict__,
            "stressed_requirement": record.stressed_requirement * 2.0,
        }
    )
    result = analyze_component_reconciliation([corrupted], config)
    assert result.status == "FAIL"


def test_external_csv_aliases_and_outputs(tmp_path: Path) -> None:
    input_path = tmp_path / "external.csv"
    fieldnames = [
        "scenario_name",
        "scenario_severity",
        "random_seed",
        "stressed_liquidity_requirement",
        "available_qualified_liquid_resources",
        "liquidity_coverage_ratio",
        *COMPONENT_NAMES,
    ]
    components = {name: 10.0 for name in COMPONENT_NAMES}
    with input_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerow(
            {
                "scenario_name": "baseline_combined_stress",
                "scenario_severity": "baseline",
                "random_seed": 1,
                "stressed_liquidity_requirement": 80.0,
                "available_qualified_liquid_resources": 160.0,
                "liquidity_coverage_ratio": 2.0,
                **components,
            }
        )
    with input_path.open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    records, metadata = normalize_records(rows)
    assert records[0].stressed_requirement == pytest.approx(80.0)
    assert metadata["lcr_orientation"] == "resources_over_requirement"

    output_dir = tmp_path / "out"
    summary = execute_section27(config_path=None, output_dir=output_dir, input_path=input_path)
    assert summary["evidence_mode"] == "external_model_output"
    assert (output_dir / "section27_summary.json").exists()
    assert json.loads((output_dir / "section27_summary.json").read_text())["section"] == 27


def test_controlled_mode_is_explicitly_labeled(tmp_path: Path) -> None:
    summary = execute_section27(config_path=None, output_dir=tmp_path)
    assert summary["overall_status"] == "PASS_CONTROLLED_ONLY"
    report = (tmp_path / "section27_validation_report.md").read_text(encoding="utf-8")
    assert "not empirical validation" in report.lower()
    assert "controlled_benchmark" in report
