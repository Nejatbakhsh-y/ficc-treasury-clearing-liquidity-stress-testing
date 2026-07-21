"""Tests for long-form historical stress-window calibration."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import pytest
import yaml
from scripts.run_historical_stress_calibration import (
    augment_with_fr2004_raw,
)

from ficc_liquidity.analysis.historical_stress import (
    COMPONENT_COLUMNS,
    build_component_scores,
    calibrate_historical_windows,
    combine_components,
    identify_windows,
    load_analytical_inputs,
    load_config,
    resolve_series_map,
    update_selected_scenarios,
)


def _row(
    date: pd.Timestamp,
    source: str,
    series: str,
    metric: str,
    value: float,
    frequency: str,
    unit: str,
    kind: str,
    maturity_months: float | None = None,
) -> dict[str, object]:
    return {
        "observation_date": date,
        "alignment_frequency": frequency,
        "source_name": source,
        "source_series_id": series,
        "source_metric": metric,
        "value": value,
        "standardized_unit": unit,
        "metric_kind": kind,
        "maturity_months": maturity_months,
        "is_observed": True,
        "series_key": f"{source}::{series}::{frequency}",
    }


def _synthetic_long_frame() -> pd.DataFrame:
    rng = np.random.default_rng(2026)
    dates = pd.bdate_range("2019-01-01", periods=500)
    shock_start = pd.Timestamp("2020-03-09")
    shock_end = pd.Timestamp("2020-03-20")

    sofr = 2.0 + rng.normal(0.0, 0.01, len(dates)).cumsum() / 20.0
    y2 = 2.2 + rng.normal(0.0, 0.01, len(dates)).cumsum()
    y10 = 2.6 + rng.normal(0.0, 0.01, len(dates)).cumsum()
    reserves = 1500.0 + rng.normal(0.0, 3.0, len(dates)).cumsum()
    daily_shock = (dates >= shock_start) & (dates <= shock_end)
    sofr[daily_shock] += np.linspace(0.0, 1.2, daily_shock.sum())
    y2[daily_shock] += np.linspace(0.0, 1.5, daily_shock.sum())
    y10[daily_shock] -= np.linspace(0.0, 1.2, daily_shock.sum())
    reserves[daily_shock] -= np.linspace(0.0, 300.0, daily_shock.sum())

    records: list[dict[str, object]] = []
    for index, date in enumerate(dates):
        records.extend(
            [
                _row(
                    date,
                    "SOFR",
                    "SOFR",
                    "Secured Overnight Financing Rate",
                    sofr[index],
                    "daily",
                    "PERCENT",
                    "rate",
                ),
                _row(
                    date,
                    "H15",
                    "DGS2",
                    "2-Year Treasury Constant Maturity Rate",
                    y2[index],
                    "daily",
                    "PERCENT",
                    "rate",
                    24.0,
                ),
                _row(
                    date,
                    "H15",
                    "DGS10",
                    "10-Year Treasury Constant Maturity Rate",
                    y10[index],
                    "daily",
                    "PERCENT",
                    "rate",
                    120.0,
                ),
                _row(
                    date,
                    "H41",
                    "WRESBAL",
                    "wresbal",
                    reserves[index] * 1_000_000.0,
                    "daily",
                    "USD",
                    "stock",
                ),
            ]
        )

    fridays = dates[dates.weekday == 4]
    fails = 100.0 + rng.normal(0.0, 2.0, len(fridays))
    financing = 1000.0 + rng.normal(0.0, 8.0, len(fridays))
    weekly_shock = (fridays >= shock_start) & (fridays <= shock_end)
    fails[weekly_shock] += np.linspace(0.0, 500.0, weekly_shock.sum())
    financing[weekly_shock] -= np.linspace(0.0, 350.0, weekly_shock.sum())
    for index, date in enumerate(fridays):
        records.extend(
            [
                _row(
                    date,
                    "FR2004",
                    "PDFTD-USET",
                    "pdftd_uset",
                    fails[index] * 1_000_000.0,
                    "weekly",
                    "USD",
                    "flow",
                ),
                _row(
                    date,
                    "FR2004",
                    "PDSORA-UTSETTOT",
                    "pdsora_utsettot",
                    financing[index] * 1_000_000.0,
                    "weekly",
                    "USD",
                    "flow",
                ),
            ]
        )

    return pd.DataFrame.from_records(records)


def _config() -> dict[str, object]:
    return {
        "methodology": {
            "tail_quantile": 0.95,
            "rolling_window_observations": 40,
            "minimum_available_components": 2,
            "require_all_series_groups": True,
            "merge_gap_days": 7,
            "pre_window_days": 2,
            "post_window_days": 2,
            "minimum_exceedance_days": 1,
            "maximum_windows": 10,
            "component_weights": {column: 1.0 for column in COMPONENT_COLUMNS},
        },
        "series_rules": {
            "sofr": {
                "source_names": ["SOFR"],
                "alignment_frequency": "daily",
                "standardized_units": ["PERCENT"],
                "metric_kinds": ["rate"],
                "include_patterns": ["sofr"],
                "exclude_patterns": ["volume", "percentile"],
            },
            "treasury_yields": {
                "source_names": ["H15"],
                "alignment_frequency": "daily",
                "standardized_units": ["PERCENT"],
                "metric_kinds": ["rate"],
                "require_maturity": True,
            },
            "settlement_fails": {
                "source_names": ["FR2004"],
                "alignment_frequency": "weekly",
                "standardized_units": ["USD"],
                "include_patterns": ["fail", r"pdft[rd][_-]"],
                "exclude_patterns": [r"pdft[rd][_-][a-z0-9_-]*c(?:\s|$)"],
            },
            "financing_volume": {
                "source_names": ["FR2004"],
                "alignment_frequency": "weekly",
                "standardized_units": ["USD"],
                "include_patterns": [
                    "repo",
                    "financ",
                    "volume",
                    r"pds(?:ora|irra|iosb|oos)[_-]",
                ],
                "exclude_patterns": [
                    "fail",
                    r"pds(?:ora|irra|iosb|oos)[_-][a-z0-9_-]*c(?:\s|$)",
                ],
            },
            "reserve_balances": {
                "source_names": ["H41"],
                "alignment_frequency": "daily",
                "standardized_units": ["USD"],
                "metric_kinds": ["stock"],
                "include_patterns": ["reserve.*balance", "wresbal"],
                "exact_series_ids": ["WRESBAL"],
            },
        },
        "candidate_anchors": [
            {
                "id": "march_2020_treasury_stress",
                "name": "March 2020 Treasury-market stress",
                "start_date": "2020-03-01",
                "end_date": "2020-04-30",
            }
        ],
    }


def test_series_rules_resolve_all_five_groups() -> None:
    mappings = resolve_series_map(_synthetic_long_frame(), _config())
    assert all(mappings.values())
    assert any("DGS10" in item for item in mappings["treasury_yields"])
    assert any("PDFTD-USET" in item for item in mappings["settlement_fails"])
    assert any("PDSORA-UTSETTOT" in item for item in mappings["financing_volume"])
    assert any("WRESBAL" in item for item in mappings["reserve_balances"])


def test_all_component_scores_are_bounded() -> None:
    frame = _synthetic_long_frame()
    mappings = resolve_series_map(frame, _config())
    scores = build_component_scores(frame, mappings, rolling_window=40)
    for column in COMPONENT_COLUMNS:
        non_missing = scores[column].dropna()
        assert not non_missing.empty
        assert non_missing.between(0.0, 1.0).all()


def test_combined_score_requires_minimum_available_components() -> None:
    dates = pd.date_range("2020-01-01", periods=4, freq="D")
    scores = pd.DataFrame({"observation_date": dates})
    for column in COMPONENT_COLUMNS:
        scores[column] = np.nan
    scores.loc[:, "sofr_spike_score"] = [0.1, 0.2, 0.3, 0.4]
    combined = combine_components(
        scores,
        weights={column: 1.0 for column in COMPONENT_COLUMNS},
        minimum_components=2,
    )
    assert combined["combined_stress_score"].isna().all()


def test_empirical_calibration_finds_march_2020_shock() -> None:
    result = calibrate_historical_windows(_synthetic_long_frame(), _config())
    march_overlap = result.windows.apply(
        lambda row: (
            pd.Timestamp(row["start_date"]) <= pd.Timestamp("2020-03-20")
            and pd.Timestamp(row["end_date"]) >= pd.Timestamp("2020-03-09")
        ),
        axis=1,
    )
    assert march_overlap.any()
    assert (
        result.windows.loc[march_overlap, "anchor_match"]
        .str.contains("march_2020_treasury_stress")
        .any()
    )


def test_window_selection_does_not_force_anchor() -> None:
    dates = pd.date_range("2022-01-01", periods=100, freq="D")
    daily = pd.DataFrame({"observation_date": dates})
    for column in COMPONENT_COLUMNS:
        daily[column] = 0.2
    daily["available_component_count"] = len(COMPONENT_COLUMNS)
    daily["combined_stress_score"] = np.linspace(0.0, 1.0, len(dates))

    windows, threshold = identify_windows(
        daily_scores=daily,
        quantile=0.95,
        merge_gap_days=7,
        pre_window_days=1,
        post_window_days=1,
        minimum_exceedance_days=1,
        maximum_windows=5,
        anchors=[
            {
                "id": "uncovered_anchor",
                "name": "Uncovered anchor",
                "start_date": "2008-01-01",
                "end_date": "2008-12-31",
            }
        ],
    )
    assert threshold > 0.9
    assert (windows["anchor_match"] == "").all()
    assert (windows["scenario_name"] == "Empirical tail window").all()


def test_load_inputs_builds_lineage_and_deduplicates(tmp_path: Path) -> None:
    frame = _synthetic_long_frame().head(30).drop(columns=["series_key"])
    duplicate = frame.iloc[[0]].copy()
    duplicate["value"] = duplicate["value"] + 1.0
    first = pd.concat([frame, duplicate], ignore_index=True)
    second = _synthetic_long_frame().tail(20).drop(columns=["series_key"])
    first_path = tmp_path / "first.parquet"
    second_path = tmp_path / "second.parquet"
    first.to_parquet(first_path, index=False)
    second.to_parquet(second_path, index=False)

    loaded, lineage = load_analytical_inputs([first_path, second_path])

    assert len(lineage) == 2
    assert "series_key" in loaded.columns
    assert not loaded.duplicated(
        ["observation_date", "alignment_frequency", "source_name", "source_series_id"]
    ).any()
    assert all(item["sha256"] for item in lineage)


def test_load_inputs_rejects_invalid_schema_and_format(tmp_path: Path) -> None:
    invalid_csv = tmp_path / "invalid.csv"
    pd.DataFrame({"observation_date": ["2020-01-01"], "value": [1.0]}).to_csv(
        invalid_csv, index=False
    )
    with pytest.raises(ValueError, match="missing canonical columns"):
        load_analytical_inputs([invalid_csv])

    unsupported = tmp_path / "input.txt"
    unsupported.write_text("not a table", encoding="utf-8")
    with pytest.raises(ValueError, match="Unsupported analytical input format"):
        load_analytical_inputs([unsupported])


def test_load_inputs_requires_at_least_one_existing_file(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="No Section 8 processed inputs"):
        load_analytical_inputs([tmp_path / "missing.parquet"])


def test_config_and_selected_scenario_round_trip(tmp_path: Path) -> None:
    config_path = tmp_path / "historical_scenarios.yaml"
    with config_path.open("w", encoding="utf-8") as handle:
        yaml.safe_dump(_config(), handle, sort_keys=False)

    config = load_config(config_path)
    result = calibrate_historical_windows(_synthetic_long_frame(), config)
    update_selected_scenarios(config_path, config, result.windows)

    with config_path.open(encoding="utf-8") as handle:
        updated = yaml.safe_load(handle)
    assert updated["selected_scenarios"]
    assert updated["selected_scenarios"][0]["id"].startswith("HIST_")
    assert "selection" in updated["selected_scenarios"][0]


def test_invalid_config_and_missing_required_group_raise(tmp_path: Path) -> None:
    config_path = tmp_path / "invalid.yaml"
    config_path.write_text("schema_version: '1.0'\n", encoding="utf-8")
    with pytest.raises(ValueError, match="methodology and series_rules"):
        load_config(config_path)

    frame = _synthetic_long_frame()
    frame = frame.loc[~frame["source_name"].eq("H41")].copy()
    with pytest.raises(ValueError, match="reserve_balances"):
        calibrate_historical_windows(frame, _config())


def test_raw_fr2004_fallback_resolves_official_fail_series(tmp_path: Path) -> None:
    raw_directory = tmp_path / "data" / "raw" / "fr2004"
    raw_directory.mkdir(parents=True)
    raw_path = raw_directory / "fr2004_20260720T012731Z_example.csv"
    raw_path.write_text(
        "As Of Date,Time Series,Value (millions)\n"
        "2020-03-04,PDFTR-USTET,1250\n"
        "2020-03-04,PDFTD-USTET,1350\n"
        "2020-03-04,PDSORA-UTSETTOT,850000\n",
        encoding="utf-8",
    )

    base = _synthetic_long_frame().loc[lambda frame: frame["source_name"] != "FR2004"].copy()
    enriched, lineage = augment_with_fr2004_raw(base, tmp_path)

    assert lineage is not None
    assert lineage["source_row_counts"] == {"FR2004_RAW_FALLBACK": 3}
    assert {"PDFTR-USTET", "PDFTD-USTET"}.issubset(set(enriched["source_series_id"].astype(str)))
    mappings = resolve_series_map(enriched, _config())
    assert mappings["settlement_fails"]
    assert mappings["financing_volume"]
