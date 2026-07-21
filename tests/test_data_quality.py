from __future__ import annotations

from pathlib import Path

import pandas as pd

from ficc_liquidity.validation.data_quality import (
    MIN_COMPLETENESS,
    discover_dataset_files,
    results_frame,
    run_validation,
    validate_dataset,
    write_evidence,
)


def _daily_dates(periods: int = 260) -> pd.DatetimeIndex:
    return pd.bdate_range("2025-01-02", periods=periods)


def _weekly_dates(periods: int = 80) -> pd.DatetimeIndex:
    return pd.date_range("2024-01-03", periods=periods, freq="W-WED")


def test_valid_sofr_long_format_passes_core_checks(tmp_path: Path) -> None:
    dates = _daily_dates()
    frame = pd.concat(
        [
            pd.DataFrame(
                {
                    "observation_date": dates,
                    "series_id": "SOFR rate",
                    "value": 5.0,
                    "unit": "percent",
                }
            ),
            pd.DataFrame(
                {
                    "observation_date": dates,
                    "series_id": "transaction volume",
                    "value": 1_500.0,
                    "unit": "USD billions",
                }
            ),
        ],
        ignore_index=True,
    ).sort_values(["series_id", "observation_date"], kind="stable")
    path = tmp_path / "sofr_processed.csv"
    frame.to_csv(path, index=False)

    results, context = validate_dataset("sofr", path, minimum_completeness=0.98)
    table = results_frame(results)

    assert context is not None
    assert not (
        (table["check_id"].isin(["DQ01", "DQ02", "DQ03.1", "DQ04"])) & (table["status"] == "FAIL")
    ).any()


def test_duplicate_series_date_is_rejected(tmp_path: Path) -> None:
    dates = _weekly_dates()
    frame = pd.DataFrame(
        {
            "date": dates,
            "series_id": "Treasury transaction volume",
            "value": 100.0,
            "unit": "USD millions",
        }
    )
    frame = pd.concat([frame, frame.iloc[[0]]], ignore_index=True)
    path = tmp_path / "fr2004.csv"
    frame.to_csv(path, index=False)

    results, _ = validate_dataset("fr2004", path)
    table = results_frame(results)
    row = table.loc[table["check_id"] == "DQ03.2"].iloc[0]
    assert row["status"] == "FAIL"


def test_missing_week_below_threshold_fails_completeness(tmp_path: Path) -> None:
    dates = _weekly_dates(periods=20).delete(10)
    frame = pd.DataFrame(
        {
            "date": dates,
            "series_id": "reserve balances",
            "value": 3_000_000.0,
            "unit": "USD millions",
        }
    )
    path = tmp_path / "h41.csv"
    frame.to_csv(path, index=False)

    results, _ = validate_dataset("h41", path, minimum_completeness=MIN_COMPLETENESS)
    table = results_frame(results)
    row = table.loc[table["check_id"] == "DQ06"].iloc[0]
    assert row["status"] == "FAIL"


def test_negative_volume_is_impossible(tmp_path: Path) -> None:
    dates = _daily_dates(periods=30)
    values = [1_000.0] * len(dates)
    values[5] = -1.0
    frame = pd.DataFrame({"date": dates, "sofr_rate": 5.0, "transaction_volume": values})
    path = tmp_path / "sofr.csv"
    frame.to_csv(path, index=False)

    results, _ = validate_dataset("sofr", path, minimum_completeness=0.95)
    table = results_frame(results)
    row = table.loc[table["check_id"] == "DQ08.2"].iloc[0]
    assert row["status"] == "FAIL"


def test_unit_inconsistency_is_detected(tmp_path: Path) -> None:
    dates = _daily_dates(periods=20)
    frame = pd.DataFrame(
        {
            "date": dates,
            "series_id": "SOFR rate",
            "value": 5.0,
            "unit": ["percent"] * 10 + ["decimal"] * 10,
        }
    )
    path = tmp_path / "sofr.csv"
    frame.to_csv(path, index=False)

    results, _ = validate_dataset("sofr", path, minimum_completeness=0.90)
    table = results_frame(results)
    row = table.loc[table["check_id"] == "DQ07"].iloc[0]
    assert row["status"] == "FAIL"


def test_discovery_prefers_processed_parquet(tmp_path: Path) -> None:
    raw = tmp_path / "raw"
    processed = tmp_path / "processed"
    raw.mkdir()
    processed.mkdir()
    (raw / "sofr.csv").write_text("date,value\n2025-01-02,5\n", encoding="utf-8")
    (processed / "sofr.parquet").write_bytes(b"PAR1")

    selected, candidates = discover_dataset_files(tmp_path)
    assert selected["sofr"].suffix == ".parquet"
    assert len(candidates["sofr"]) == 2


def test_full_run_writes_controlled_evidence(tmp_path: Path) -> None:
    data_root = tmp_path / "data" / "processed"
    data_root.mkdir(parents=True)
    daily = _daily_dates(periods=260)
    weekly = _weekly_dates(periods=52)

    pd.DataFrame({"date": daily, "sofr_rate": 5.0, "transaction_volume": 1_500.0}).to_csv(
        data_root / "sofr.csv", index=False
    )
    pd.DataFrame({"date": daily, "treasury_10_year_yield": 4.0}).to_csv(
        data_root / "h15.csv", index=False
    )
    pd.DataFrame(
        {
            "date": weekly,
            "series_id": "positions transactions financing settlement fails",
            "value": 1_000.0,
            "unit": "USD millions",
        }
    ).to_csv(data_root / "fr2004.csv", index=False)
    pd.DataFrame(
        {
            "date": weekly,
            "series_id": "reserve balances",
            "value": 3_000_000.0,
            "unit": "USD millions",
        }
    ).to_csv(data_root / "h41.csv", index=False)

    selected, _ = discover_dataset_files(tmp_path / "data")
    results = run_validation(selected, minimum_completeness=0.95)
    csv_path = tmp_path / "reports" / "tables" / "data_quality_results.csv"
    text_path = tmp_path / "reports" / "evidence" / "data_quality_report.txt"
    write_evidence(results, selected, csv_path, text_path, minimum_completeness=0.95)

    assert csv_path.exists()
    assert text_path.exists()
    assert "Section 7 final decision" in text_path.read_text(encoding="utf-8")
