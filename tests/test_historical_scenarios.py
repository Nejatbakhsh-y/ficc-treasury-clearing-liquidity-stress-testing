from __future__ import annotations

from pathlib import Path
from typing import cast

import pandas as pd
import pytest

from ficc_liquidity.scenarios.historical_scenarios import (
    HistoricalScenarioError,
    build_historical_treasury_scenarios,
    build_single_historical_integrated_config,
    calibrate_historical_scenarios,
    choose_component_scenario,
    load_historical_windows,
    load_replay_settings,
    prepare_long_form,
)


def _catalog() -> dict[str, object]:
    return {
        "series_rules": {
            "sofr": {
                "source_names": ["SOFR"],
                "alignment_frequency": "daily",
                "standardized_units": ["PERCENT"],
                "metric_kinds": ["rate"],
                "include_patterns": ["sofr"],
                "exclude_patterns": ["volume"],
            },
            "treasury_yields": {
                "source_names": ["H15"],
                "alignment_frequency": "daily",
                "standardized_units": ["PERCENT"],
                "require_maturity": True,
                "include_patterns": [],
                "exclude_patterns": ["change"],
            },
            "financing_volume": {
                "source_names": ["FR2004"],
                "alignment_frequency": "weekly",
                "standardized_units": ["USD"],
                "include_patterns": ["repo"],
                "exclude_patterns": ["fail"],
            },
            "settlement_fails": {
                "source_names": ["FR2004"],
                "alignment_frequency": "weekly",
                "standardized_units": ["USD"],
                "include_patterns": ["fail"],
                "exclude_patterns": [],
            },
            "reserve_balances": {
                "source_names": ["H41"],
                "alignment_frequency": "daily",
                "standardized_units": ["USD"],
                "include_patterns": ["reserve"],
                "exclude_patterns": [],
                "exact_series_ids": ["WRESBAL"],
            },
        },
        "selected_scenarios": [
            {
                "id": "HIST_A",
                "name": "Observed window A",
                "start_date": "2020-03-01",
                "peak_date": "2020-03-03",
                "end_date": "2020-03-05",
                "anchor_match": "march_2020",
                "selection": {"trigger_components": ["sofr_spike_score"]},
            },
            {
                "id": "HIST_B",
                "name": "Observed window B",
                "start_date": "2020-04-01",
                "peak_date": "2020-04-03",
                "end_date": "2020-04-05",
                "anchor_match": None,
                "selection": {"trigger_components": ["reserve_contraction_score"]},
            },
        ],
    }


def _replay_config() -> dict[str, object]:
    return {
        "model_version": "section-20-test",
        "source": {
            "scenario_catalog": "configs/historical_scenarios.yaml",
            "analytical_inputs": ["a.parquet", "b.parquet"],
        },
        "severity_weights": {
            "sofr_spike_bp": 1.0,
            "maximum_absolute_treasury_shock_bp": 1.0,
            "financing_contraction_rate": 1.0,
            "settlement_fail_increase_rate": 1.0,
            "reserve_contraction_rate": 1.0,
        },
        "factor_caps": {
            "sofr_spike_bp": 500.0,
            "maximum_absolute_treasury_shock_bp": 300.0,
            "financing_contraction_rate": 0.5,
            "settlement_fail_increase_rate": 5.0,
            "reserve_contraction_rate": 0.25,
        },
        "validation": {"maximum_asof_lookback_days": 10, "observed_only": True},
        "output": {
            "directory": "reports/tables",
            "evidence_directory": "reports/evidence",
            "manifest": "data/manifests/historical.csv",
            "write_csv": True,
            "write_parquet": False,
        },
    }


def _long_frame() -> pd.DataFrame:
    rows: list[dict[str, object]] = []

    def add(
        dates: list[str],
        values: list[float],
        source: str,
        series: str,
        metric: str,
        frequency: str,
        unit: str,
        kind: str,
        maturity: float | None = None,
    ) -> None:
        for date, value in zip(dates, values, strict=True):
            rows.append(
                {
                    "observation_date": date,
                    "alignment_frequency": frequency,
                    "source_name": source,
                    "source_series_id": series,
                    "source_metric": metric,
                    "value": value,
                    "standardized_unit": unit,
                    "metric_kind": kind,
                    "maturity_months": maturity,
                    "is_observed": True,
                }
            )

    dates_a = ["2020-03-01", "2020-03-03", "2020-03-05"]
    dates_b = ["2020-04-01", "2020-04-03", "2020-04-05"]
    add(dates_a, [1.0, 2.0, 1.5], "SOFR", "SOFR", "SOFR rate", "daily", "PERCENT", "rate")
    add(dates_b, [1.0, 1.2, 1.1], "SOFR", "SOFR", "SOFR rate", "daily", "PERCENT", "rate")
    add(dates_a, [0.8, 1.0, 1.1], "H15", "DGS2", "2-year yield", "daily", "PERCENT", "rate", 24)
    add(dates_a, [1.2, 1.4, 1.5], "H15", "DGS10", "10-year yield", "daily", "PERCENT", "rate", 120)
    add(dates_b, [1.1, 1.0, 0.9], "H15", "DGS2", "2-year yield", "daily", "PERCENT", "rate", 24)
    add(dates_b, [1.5, 1.4, 1.3], "H15", "DGS10", "10-year yield", "daily", "PERCENT", "rate", 120)
    add(dates_a, [100.0, 80.0, 70.0], "FR2004", "REPO", "repo financing", "weekly", "USD", "volume")
    add(dates_b, [100.0, 98.0, 95.0], "FR2004", "REPO", "repo financing", "weekly", "USD", "volume")
    add(dates_a, [10.0, 25.0, 20.0], "FR2004", "FAIL", "fails to deliver", "weekly", "USD", "level")
    add(dates_b, [10.0, 11.0, 10.0], "FR2004", "FAIL", "fails to deliver", "weekly", "USD", "level")
    add(
        dates_a,
        [1000.0, 800.0, 900.0],
        "H41",
        "WRESBAL",
        "reserve balances",
        "daily",
        "USD",
        "level",
    )
    add(
        dates_b,
        [1000.0, 990.0, 985.0],
        "H41",
        "WRESBAL",
        "reserve balances",
        "daily",
        "USD",
        "level",
    )
    return pd.DataFrame(rows)


def test_load_settings_resolves_paths(tmp_path: Path) -> None:
    settings = load_replay_settings(_replay_config(), tmp_path)
    assert settings.model_version == "section-20-test"
    assert settings.scenario_catalog == tmp_path / "configs/historical_scenarios.yaml"
    assert settings.maximum_asof_lookback_days == 10
    assert settings.observed_only is True


def test_load_windows_preserves_empirical_selection() -> None:
    windows = load_historical_windows(_catalog())
    assert [window.scenario_id for window in windows] == ["HIST_A", "HIST_B"]
    assert windows[0].anchor_match == "march_2020"
    assert windows[1].anchor_match is None


def test_invalid_window_order_fails() -> None:
    catalog = _catalog()
    scenarios = catalog["selected_scenarios"]
    assert isinstance(scenarios, list)
    scenarios[0]["end_date"] = "2020-02-01"
    with pytest.raises(HistoricalScenarioError, match="start <= peak <= end"):
        load_historical_windows(catalog)


def test_prepare_long_form_excludes_nonobserved_rows() -> None:
    frame = _long_frame()
    frame.loc[0, "is_observed"] = False
    prepared = prepare_long_form(frame, observed_only=True)
    assert len(prepared) == len(frame) - 1
    assert prepared["source_name"].str.isupper().all()


def test_calibration_derives_observed_conditions() -> None:
    settings = load_replay_settings(_replay_config(), Path("."))
    treasury_config = {
        "maturity_buckets": {
            "short": {"midpoint_years": 2.0},
            "long": {"midpoint_years": 10.0},
        }
    }
    output = calibrate_historical_scenarios(
        _long_frame(),
        load_historical_windows(_catalog()),
        _catalog(),
        treasury_config,
        settings,
    )
    metrics = output.scenario_metrics.set_index("scenario_id")
    assert metrics.loc["HIST_A", "sofr_spike_bp"] == pytest.approx(100.0)
    assert metrics.loc["HIST_A", "financing_contraction_rate"] == pytest.approx(0.30)
    assert metrics.loc["HIST_A", "settlement_fail_increase_rate"] == pytest.approx(1.50)
    assert metrics.loc["HIST_A", "reserve_contraction_rate"] == pytest.approx(0.20)
    assert metrics.loc["HIST_A", "maximum_absolute_treasury_shock_bp"] == pytest.approx(30.0)
    hist_a_score = cast(float, metrics.loc["HIST_A", "empirical_severity_score"])
    hist_b_score = cast(float, metrics.loc["HIST_B", "empirical_severity_score"])
    assert hist_a_score > hist_b_score
    assert output.treasury_bucket_shocks["scenario_id"].nunique() == 2


def test_component_selection_uses_ordered_severity() -> None:
    frame = pd.DataFrame(
        {
            "scenario_name": ["severe", "control", "moderate"],
            "severity_rank": [2, 0, 1],
        }
    )
    assert choose_component_scenario(frame, 0.0) == ("control", 0)
    assert choose_component_scenario(frame, 0.51) == ("moderate", 1)
    assert choose_component_scenario(frame, 1.0) == ("severe", 2)


def test_build_treasury_scenarios_uses_bucket_vectors() -> None:
    shocks = pd.DataFrame(
        {
            "scenario_id": ["HIST_A", "HIST_A"],
            "maturity_bucket": ["short", "long"],
            "observed_yield_shock_bp": [10.0, 20.0],
        }
    )
    scenarios = build_historical_treasury_scenarios(shocks)
    assert scenarios == [
        {
            "name": "HIST_A",
            "enabled": True,
            "type": "bucket_vector",
            "family": "historical_observed",
            "shocks_bp": {"short": 10.0, "long": 20.0},
        }
    ]


def test_single_integrated_config_uses_historical_names() -> None:
    base = {
        "model_version": "section-19-v1",
        "scenarios": [
            {
                "name": "control",
                "severity_rank": 0,
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "operational_liquidity_buffer_rate": 0.0,
            },
            {
                "name": "severe",
                "severity_rank": 1,
                "concentration_threshold": 0.25,
                "concentration_multiplier": 0.25,
                "operational_liquidity_buffer_rate": 0.05,
            },
        ],
    }
    built = build_single_historical_integrated_config(
        base,
        "HIST_A",
        "funding_severe",
        "haircut_severe",
        "settlement_severe",
        1.0,
        "section-20-v1",
    )
    scenario = built["scenarios"][0]
    assert built["model_version"] == "section-20-v1"
    assert scenario["name"] == "HIST_A"
    assert scenario["treasury_scenario_name"] == "HIST_A"
    assert scenario["funding_scenario_name"] == "funding_severe"
    assert scenario["concentration_multiplier"] == pytest.approx(0.25)


def test_settings_reject_zero_total_weight() -> None:
    config = _replay_config()
    weights = config["severity_weights"]
    assert isinstance(weights, dict)
    for key in list(weights):
        weights[key] = 0.0
    with pytest.raises(HistoricalScenarioError, match="At least one severity weight"):
        load_replay_settings(config, Path("."))


def test_prepare_long_form_rejects_missing_schema() -> None:
    with pytest.raises(HistoricalScenarioError, match="missing fields"):
        prepare_long_form(pd.DataFrame({"observation_date": ["2020-01-01"]}), True)


def test_duplicate_historical_ids_fail() -> None:
    catalog = _catalog()
    scenarios = catalog["selected_scenarios"]
    assert isinstance(scenarios, list)
    scenarios[1]["id"] = "HIST_A"
    with pytest.raises(HistoricalScenarioError, match="identifiers must be unique"):
        load_historical_windows(catalog)


def test_empty_component_scenarios_fail() -> None:
    with pytest.raises(HistoricalScenarioError, match="contains no scenarios"):
        choose_component_scenario(
            pd.DataFrame(columns=["scenario_name", "severity_rank"]),
            0.5,
        )


def test_treasury_scenario_schema_is_required() -> None:
    with pytest.raises(HistoricalScenarioError, match="missing fields"):
        build_historical_treasury_scenarios(pd.DataFrame({"scenario_id": ["HIST_A"]}))


def test_unsupported_rate_unit_fails_calibration() -> None:
    frame = _long_frame()
    frame.loc[frame["source_name"].eq("SOFR"), "standardized_unit"] = "UNKNOWN"
    catalog = _catalog()
    rules = catalog["series_rules"]
    assert isinstance(rules, dict)
    sofr_rule = rules["sofr"]
    assert isinstance(sofr_rule, dict)
    sofr_rule["standardized_units"] = ["UNKNOWN"]
    settings = load_replay_settings(_replay_config(), Path("."))
    treasury_config = {
        "maturity_buckets": {
            "short": {"midpoint_years": 2.0},
            "long": {"midpoint_years": 10.0},
        }
    }
    with pytest.raises(HistoricalScenarioError, match="Unsupported rate unit"):
        calibrate_historical_scenarios(
            frame,
            load_historical_windows(catalog),
            catalog,
            treasury_config,
            settings,
        )
