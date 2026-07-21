from __future__ import annotations

import argparse
import inspect
import runpy
from collections.abc import Sequence
from pathlib import Path
from types import SimpleNamespace
from typing import Any, cast

import pandas as pd
import pytest

import ficc_liquidity.validation.data_quality as data_quality


def _value_for_parameter(
    name: str,
    *,
    passed: bool,
    tmp_path: Path,
) -> object:
    normalized = name.lower()

    if normalized in {"dataset", "dataset_name", "source"}:
        return "fr2004"
    if normalized in {"check_id", "control_id"}:
        return "DQ99"
    if normalized in {"check_name", "control_name", "name"}:
        return "Synthetic controlled check"
    if normalized in {"passed", "is_pass", "success"}:
        return passed
    if normalized in {"status", "result"}:
        return "PASS" if passed else "FAIL"
    if normalized in {"observed", "value", "actual"}:
        return 1.0
    if normalized in {"threshold", "expected", "minimum"}:
        return 0.995
    if normalized in {"details", "message", "description"}:
        return "Synthetic evidence detail"
    if "path" in normalized or "file" in normalized:
        return tmp_path / f"{normalized}.csv"
    if "date" in normalized:
        return pd.Timestamp("2026-01-07")
    if "column" in normalized:
        return "value"
    if "frequency" in normalized:
        return "weekly"
    if "unit" in normalized:
        return "percent"
    return None


def _make_result(
    tmp_path: Path,
    *,
    passed: bool,
) -> object:
    result_type = getattr(data_quality, "CheckResult", None)

    if result_type is None:
        return {
            "dataset": "fr2004",
            "check_id": "DQ99",
            "check_name": "Synthetic controlled check",
            "passed": passed,
            "status": "PASS" if passed else "FAIL",
            "observed": 1.0,
            "threshold": 0.995,
            "details": "Synthetic evidence detail",
        }

    signature = inspect.signature(result_type)
    arguments: dict[str, object] = {}

    for name, parameter in signature.parameters.items():
        if parameter.default is not inspect.Parameter.empty:
            continue

        value = _value_for_parameter(
            name,
            passed=passed,
            tmp_path=tmp_path,
        )

        if value is None:
            annotation = parameter.annotation
            if annotation is bool:
                value = passed
            elif annotation is int:
                value = 1
            elif annotation is float:
                value = 1.0
            elif annotation is str:
                value = "synthetic"
            elif annotation is Path:
                value = tmp_path / f"{name}.csv"
            else:
                value = "synthetic"

        arguments[name] = value

    return result_type(**arguments)


def _result_mapping(result: object) -> dict[str, object]:
    if isinstance(result, dict):
        return dict(result)

    as_dict = getattr(result, "as_dict", None)
    if callable(as_dict):
        value = as_dict()
        assert isinstance(value, dict)
        return dict(value)

    return dict(vars(result))


def test_results_frame_accepts_objects_and_dictionaries(
    tmp_path: Path,
) -> None:
    pass_result = _make_result(tmp_path, passed=True)
    mapping = _result_mapping(pass_result)

    object_frame = data_quality.results_frame(
        cast(Sequence[data_quality.CheckResult], [pass_result])
    )
    mapping_frame = data_quality.results_frame(cast(Sequence[data_quality.CheckResult], [mapping]))

    assert not object_frame.empty
    assert not mapping_frame.empty
    assert list(object_frame.columns) == list(mapping_frame.columns)


def test_write_evidence_covers_pass_and_fail_paths(
    tmp_path: Path,
) -> None:
    selected = {
        "fr2004": tmp_path / "fr2004.parquet",
        "sofr": tmp_path / "sofr.parquet",
        "h15": tmp_path / "h15.parquet",
        "h41": tmp_path / "h41.parquet",
    }

    for path in selected.values():
        path.write_bytes(b"controlled")

    pass_csv = tmp_path / "pass_results.csv"
    pass_report = tmp_path / "pass_report.txt"

    data_quality.write_evidence(
        cast(Sequence[data_quality.CheckResult], [_make_result(tmp_path, passed=True)]),
        selected,
        pass_csv,
        pass_report,
        minimum_completeness=0.995,
    )

    assert pass_csv.is_file()
    assert pass_report.is_file()
    assert "PASS" in pass_report.read_text(encoding="utf-8")

    fail_csv = tmp_path / "fail_results.csv"
    fail_report = tmp_path / "fail_report.txt"

    data_quality.write_evidence(
        cast(Sequence[data_quality.CheckResult], [_make_result(tmp_path, passed=False)]),
        selected,
        fail_csv,
        fail_report,
        minimum_completeness=0.995,
    )

    assert fail_csv.is_file()
    assert fail_report.is_file()
    assert "FAIL" in fail_report.read_text(encoding="utf-8")


def test_has_failure_true_and_false_paths(
    tmp_path: Path,
) -> None:
    helper = data_quality._has_failure

    passing = data_quality.results_frame(
        cast(Sequence[data_quality.CheckResult], [_make_result(tmp_path, passed=True)])
    )
    failing = data_quality.results_frame(
        cast(Sequence[data_quality.CheckResult], [_make_result(tmp_path, passed=False)])
    )

    check_id = str(passing.iloc[0]["check_id"])

    assert helper(passing, check_id) is False
    assert helper(failing, check_id) is True
    assert helper(passing, "DQ_NOT_PRESENT") is False


def test_read_table_supports_csv_and_parquet(
    tmp_path: Path,
) -> None:
    source = pd.DataFrame(
        {
            "observation_date": pd.to_datetime(["2026-01-01", "2026-01-02"]),
            "value": [1.0, 2.0],
        }
    )

    csv_path = tmp_path / "controlled.csv"
    parquet_path = tmp_path / "controlled.parquet"

    source.to_csv(csv_path, index=False)
    source.to_parquet(parquet_path, index=False)

    csv_frame = data_quality.read_table(csv_path)
    parquet_frame = data_quality.read_table(parquet_path)

    assert csv_frame.shape == (2, 2)
    assert parquet_frame.shape == (2, 2)


def test_read_table_rejects_unsupported_format(
    tmp_path: Path,
) -> None:
    unsupported = tmp_path / "controlled.txt"
    unsupported.write_text("not,a,controlled,table", encoding="utf-8")

    with pytest.raises((ValueError, RuntimeError)):
        data_quality.read_table(unsupported)


class _Arguments(SimpleNamespace):
    def __getattr__(self, name: str) -> Any:
        normalized = name.lower()

        if "completeness" in normalized:
            return 0.995
        if "root" in normalized:
            return self.project_root
        if "csv" in normalized or "result" in normalized:
            return self.results_csv
        if "report" in normalized or "evidence" in normalized or "text" in normalized:
            return self.report_path
        if "file" in normalized or "path" in normalized:
            return None
        return None


def _invoke_main() -> int | None:
    signature = inspect.signature(data_quality.main)

    if len(signature.parameters) == 0:
        return data_quality.main()

    return data_quality.main([])


@pytest.mark.parametrize(
    ("passed", "accepted_codes"),
    [
        (True, {0, None}),
        (False, {1, 2}),
    ],
)
def test_main_covers_pass_and_fail_paths(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    passed: bool,
    accepted_codes: set[int | None],
) -> None:
    selected = {
        "fr2004": tmp_path / "fr2004.parquet",
        "sofr": tmp_path / "sofr.parquet",
        "h15": tmp_path / "h15.parquet",
        "h41": tmp_path / "h41.parquet",
    }

    for path in selected.values():
        path.write_bytes(b"controlled")

    arguments = _Arguments(
        project_root=tmp_path,
        minimum_completeness=0.995,
        results_csv=tmp_path / f"results_{passed}.csv",
        output_csv=tmp_path / f"results_{passed}.csv",
        csv_path=tmp_path / f"results_{passed}.csv",
        report_path=tmp_path / f"report_{passed}.txt",
        output_report=tmp_path / f"report_{passed}.txt",
        evidence_path=tmp_path / f"report_{passed}.txt",
        files_json=None,
        fr2004=selected["fr2004"],
        sofr=selected["sofr"],
        h15=selected["h15"],
        h41=selected["h41"],
    )

    monkeypatch.setattr(
        argparse.ArgumentParser,
        "parse_args",
        lambda self, args=None: arguments,
    )
    monkeypatch.setattr(
        data_quality,
        "discover_dataset_files",
        lambda *args, **kwargs: selected,
    )
    monkeypatch.setattr(
        data_quality,
        "run_validation",
        lambda *args, **kwargs: [_make_result(tmp_path, passed=passed)],
    )

    try:
        code = _invoke_main()
    except SystemExit as exc:
        raw = exc.code
        if isinstance(raw, int) or raw is None:
            code = raw
        else:
            try:
                code = int(raw)
            except Exception:
                code = None

    assert code in accepted_codes


def test_package_main_delegates_to_cli(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import ficc_liquidity.cli as cli

    monkeypatch.setattr(cli, "main", lambda: 0)

    with pytest.raises(SystemExit) as exc:
        runpy.run_module(
            "ficc_liquidity.__main__",
            run_name="__main__",
        )

    assert exc.value.code == 0
