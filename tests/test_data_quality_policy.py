from __future__ import annotations

from pathlib import Path

import pandas as pd

from ficc_liquidity.validation.data_quality import _apply_control_policy


def test_policy_calibration(tmp_path: Path) -> None:
    weekly = pd.date_range("2024-01-03", periods=20, freq="W-WED")
    fr2004 = pd.DataFrame(
        {
            "observation_date": weekly,
            "series_id": ["net_position"] * len(weekly),
            "value": [-125.0] * len(weekly),
            "unit": ["USD millions"] * len(weekly),
        }
    )
    sofr_dates = pd.bdate_range("2024-01-02", periods=30)
    h15_dates = sofr_dates.where(
        sofr_dates.dayofweek != 0,
        sofr_dates + pd.Timedelta(days=1),
    )
    sofr = pd.DataFrame(
        {
            "observation_date": sofr_dates,
            "sofr_rate": 5.3,
            "percentile_01": 5.2,
            "percentile_25": 5.25,
            "percentile_75": 5.35,
            "percentile_99": 5.4,
            "volume_billions": 1800.0,
        }
    )
    h15 = pd.DataFrame({"observation_date": h15_dates, "DGS10": 4.2})

    fr_path = tmp_path / "fr2004.csv"
    sofr_path = tmp_path / "sofr.csv"
    h15_path = tmp_path / "h15.csv"
    fr2004.to_csv(fr_path, index=False)
    sofr.to_csv(sofr_path, index=False)
    h15.to_csv(h15_path, index=False)

    base = pd.DataFrame(
        [
            {
                "dataset": "fr2004",
                "check_id": "DQ06",
                "check_name": "Expected-frequency completeness",
                "observed": 0.0,
                "threshold": 0.995,
                "status": "FAIL",
                "details": "",
            },
            {
                "dataset": "fr2004",
                "check_id": "DQ08.2",
                "check_name": "Negative or impossible values",
                "observed": 20,
                "threshold": 0,
                "status": "FAIL",
                "details": "",
            },
            {
                "dataset": "cross_dataset",
                "check_id": "DQ12.sofr_h15",
                "check_name": "Cross-dataset calendar alignment",
                "observed": 0.0,
                "threshold": 0.995,
                "status": "FAIL",
                "details": "",
            },
        ]
    )

    adjusted = _apply_control_policy(
        base,
        files={
            "fr2004": fr_path,
            "sofr": sofr_path,
            "h15": h15_path,
        },
        minimum_completeness=0.995,
    )

    assert set(adjusted["status"]) == {"PASS"}
