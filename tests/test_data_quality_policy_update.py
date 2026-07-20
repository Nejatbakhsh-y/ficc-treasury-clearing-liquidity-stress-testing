# ruff: noqa: F821
from __future__ import annotations

import pandas as pd
import pytest
from pandas.api.types import is_bool_dtype, is_numeric_dtype

from ficc_liquidity.validation.data_quality import (
    _apply_control_policy,
    _fr2004_nonfinite_count,
    _nearest_calendar_alignment,
    _policy_date_column,
    _policy_read_table,
    _policy_update_row,
    _weekly_reporting_completeness,
)


def _apply(
    frame: pd.DataFrame,
    *,
    dataset: str = "fr2004",
    check_id: str = "DQ06",
    observed: float | int = 1,
    threshold: float | int = 0,
    passed: bool = True,
) -> None:
    _policy_update_row(
        frame,
        dataset=dataset,
        check_id=check_id,
        observed=observed,
        threshold=threshold,
        details="policy-adjusted result",
        passed=passed,
    )


def test_policy_update_preserves_numeric_columns() -> None:
    frame = pd.DataFrame(
        {
            "dataset": pd.Series(["fr2004"], dtype="string"),
            "check_id": pd.Series(["DQ06"], dtype="string"),
            "observed": pd.Series([0.0], dtype="float64"),
            "threshold": pd.Series([0.0], dtype="float64"),
            "details": pd.Series(["original"], dtype="string"),
        }
    )

    _apply(
        frame,
        observed=1.25,
        threshold=0.995,
    )

    assert is_numeric_dtype(frame["observed"].dtype)
    assert is_numeric_dtype(frame["threshold"].dtype)
    assert frame.at[0, "observed"] == pytest.approx(1.25)
    assert frame.at[0, "threshold"] == pytest.approx(0.995)
    assert frame.at[0, "details"] == "policy-adjusted result"


def test_policy_update_coerces_string_and_object_columns() -> None:
    frame = pd.DataFrame(
        {
            "dataset": pd.Series(["fr2004"], dtype="string"),
            "check_id": pd.Series(["DQ06"], dtype="string"),
            "observed": pd.Series(["old"], dtype="string"),
            "threshold": pd.Series([None], dtype="object"),
            "details": pd.Series([None], dtype="object"),
        }
    )

    _apply(
        frame,
        observed=52,
        threshold=0.995,
    )

    assert frame.at[0, "observed"] == "52"
    assert frame.at[0, "threshold"] == "0.995"
    assert frame.at[0, "details"] == "policy-adjusted result"
    assert isinstance(frame.at[0, "observed"], str)
    assert isinstance(frame.at[0, "threshold"], str)


@pytest.mark.parametrize(
    ("passed", "expected"),
    [
        (True, True),
        (False, False),
    ],
)
def test_policy_update_preserves_boolean_flags(
    passed: bool,
    expected: bool,
) -> None:
    frame = pd.DataFrame(
        {
            "dataset": ["fr2004"],
            "check_id": ["DQ06"],
            "observed": [0.0],
            "threshold": [0.0],
            "details": ["original"],
            "passed": pd.Series([not passed], dtype="bool"),
            "is_pass": pd.Series([not passed], dtype="boolean"),
        }
    )

    _apply(frame, passed=passed)

    assert is_bool_dtype(frame["passed"].dtype)
    assert is_bool_dtype(frame["is_pass"].dtype)
    assert bool(frame.at[0, "passed"]) is expected
    assert bool(frame.at[0, "is_pass"]) is expected


@pytest.mark.parametrize(
    ("passed", "expected_status"),
    [
        (True, "PASS"),
        (False, "FAIL"),
    ],
)
def test_policy_update_sets_pass_and_fail_statuses(
    passed: bool,
    expected_status: str,
) -> None:
    frame = pd.DataFrame(
        {
            "dataset": pd.Series(["fr2004"], dtype="string"),
            "check_id": pd.Series(["DQ06"], dtype="string"),
            "observed": pd.Series(["0"], dtype="string"),
            "threshold": pd.Series(["0"], dtype="string"),
            "details": pd.Series(["original"], dtype="string"),
            "status": pd.Series(["UNKNOWN"], dtype="string"),
            "result": pd.Series(["UNKNOWN"], dtype="object"),
        }
    )

    _apply(frame, passed=passed)

    assert frame.at[0, "status"] == expected_status
    assert frame.at[0, "result"] == expected_status


def test_policy_update_is_no_op_when_row_is_missing() -> None:
    frame = pd.DataFrame(
        {
            "dataset": pd.Series(["sofr"], dtype="string"),
            "check_id": pd.Series(["DQ01"], dtype="string"),
            "observed": pd.Series([1.0], dtype="float64"),
            "threshold": pd.Series([0.995], dtype="float64"),
            "details": pd.Series(["unchanged"], dtype="string"),
            "status": pd.Series(["PASS"], dtype="string"),
        }
    )
    expected = frame.copy(deep=True)

    _apply(
        frame,
        dataset="fr2004",
        check_id="DQ06",
        observed=999,
        threshold=0,
        passed=False,
    )

    pd.testing.assert_frame_equal(frame, expected)


def test_policy_update_changes_all_matches_and_preserves_other_rows() -> None:
    frame = pd.DataFrame(
        {
            "dataset": pd.Series(
                ["fr2004", "fr2004", "sofr"],
                dtype="string",
            ),
            "check_id": pd.Series(
                ["DQ06", "DQ06", "DQ06"],
                dtype="string",
            ),
            "observed": pd.Series([0.0, 0.0, 7.0], dtype="float64"),
            "threshold": pd.Series([0.0, 0.0, 8.0], dtype="float64"),
            "details": pd.Series(
                ["first", "second", "unrelated"],
                dtype="string",
            ),
            "status": pd.Series(
                ["FAIL", "FAIL", "PASS"],
                dtype="string",
            ),
        }
    )

    _apply(
        frame,
        observed=52,
        threshold=0.995,
        passed=True,
    )

    assert frame.loc[:1, "observed"].tolist() == [52.0, 52.0]
    assert frame.loc[:1, "threshold"].tolist() == [0.995, 0.995]
    assert frame.loc[:1, "status"].tolist() == ["PASS", "PASS"]
    assert frame.at[2, "observed"] == pytest.approx(7.0)
    assert frame.at[2, "threshold"] == pytest.approx(8.0)
    assert frame.at[2, "details"] == "unrelated"
    assert frame.at[2, "status"] == "PASS"


def test_policy_helpers_cover_read_date_and_alignment_paths(tmp_path: Path) -> None:
    frame = pd.DataFrame(
        {
            "observation_date": pd.to_datetime(["2024-01-03", "2024-01-10", "2024-01-17"]),
            "value": [1.0, 2.0, 3.0],
        }
    )
    assert _policy_date_column(frame) == "observation_date"

    csv_path = tmp_path / "policy.csv"
    frame.to_csv(csv_path, index=False)
    loaded = _policy_read_table(csv_path)
    assert loaded.shape == frame.shape

    completeness, matched, total, weekday = _weekly_reporting_completeness(frame)
    assert completeness == pytest.approx(1.0)
    assert matched == total == 3
    assert weekday == 2

    nonfinite = _fr2004_nonfinite_count(pd.DataFrame({"value": [1.0, float("nan"), float("inf")]}))
    assert nonfinite == 1

    left = pd.DataFrame({"date": pd.to_datetime(["2024-01-01", "2024-01-08"])})
    right = pd.DataFrame({"date": pd.to_datetime(["2024-01-02", "2024-01-09"])})
    alignment, aligned, total = _nearest_calendar_alignment(left, right, tolerance_days=1)
    assert alignment == pytest.approx(1.0)
    assert aligned == 1
    assert total == 1


def test_apply_control_policy_updates_rows_with_policy_data(tmp_path: Path) -> None:
    weekly = pd.date_range("2024-01-03", periods=4, freq="W-WED")
    fr2004 = pd.DataFrame(
        {
            "observation_date": weekly,
            "series_id": ["net_position"] * len(weekly),
            "value": [-125.0] * len(weekly),
            "unit": ["USD millions"] * len(weekly),
        }
    )
    sofr = pd.DataFrame(
        {
            "observation_date": pd.bdate_range("2024-01-02", periods=3),
            "sofr_rate": 5.3,
            "percentile_01": 5.2,
            "percentile_25": 5.25,
            "percentile_75": 5.35,
            "percentile_99": 5.4,
            "volume_billions": 1800.0,
        }
    )
    h15 = pd.DataFrame({"observation_date": pd.bdate_range("2024-01-03", periods=3), "DGS10": 4.2})

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
        files={"fr2004": fr_path, "sofr": sofr_path, "h15": h15_path},
        minimum_completeness=0.995,
    )

    assert adjusted.loc[0, "status"] == "PASS"
    assert adjusted.loc[1, "status"] == "PASS"
    assert adjusted.loc[2, "status"] == "PASS"
