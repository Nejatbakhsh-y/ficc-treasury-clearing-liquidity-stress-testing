from __future__ import annotations

import argparse
import json
from datetime import date
from pathlib import Path

import pytest
import yaml

from ficc_liquidity import cli, config
from ficc_liquidity.data import _fed_common as common
from ficc_liquidity.data import sofr


def _sofr_record(**overrides: object) -> dict[str, object]:
    record: dict[str, object] = {
        "effectiveDate": "2026-07-01",
        "percentRate": "3.62",
        "percentile1": "3.55",
        "percentile25": "3.59",
        "percentile75": "3.66",
        "percentile99": "3.71",
        "volumeInBillions": "3050",
        "revisionIndicator": "",
    }
    record.update(overrides)
    return record


def _payload(**overrides: object) -> bytes:
    return json.dumps({"refRates": [_sofr_record(**overrides)]}).encode("utf-8")


def test_sofr_build_url_default_and_reversed_dates() -> None:
    default_url = sofr.build_url()

    assert "startDate=2018-04-02" in default_url
    assert "endDate=" not in default_url

    with pytest.raises(
        common.IngestionError,
        match="start date cannot be after end date",
    ):
        sofr.build_url(
            date(2026, 7, 2),
            date(2026, 7, 1),
        )


def test_sofr_document_variants_and_missing_record_values() -> None:
    direct = sofr._records_from_document([_sofr_record(), "ignored"])
    nested = sofr._records_from_document({"data": {"results": [_sofr_record()]}})

    assert len(direct) == 1
    assert len(nested) == 1
    assert (
        sofr._first_value(
            direct[0],
            ("does_not_exist",),
        )
        is None
    )

    with pytest.raises(
        common.IngestionError,
        match="no observation records",
    ):
        sofr._records_from_document({"unknown": []})

    with pytest.raises(
        common.IngestionError,
        match="no observation records",
    ):
        sofr._records_from_document("not-a-document")


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        (b"{not-json", "valid UTF-8 JSON"),
        (_payload(effectiveDate="not-a-date"), "invalid observation date"),
        (_payload(percentRate=None), "missing or nonnumeric"),
        (_payload(percentRate="101"), "controlled range"),
        (_payload(volumeInBillions="-1"), "cannot be negative"),
    ],
)
def test_sofr_payload_validation_errors(
    payload: bytes,
    message: str,
) -> None:
    with pytest.raises(common.IngestionError, match=message):
        sofr.parse_payload(payload)


def test_sofr_iso_date_helper_covers_value_and_none() -> None:
    assert sofr._parse_iso_date(None) is None
    assert sofr._parse_iso_date("2026-07-01") == date(2026, 7, 1)


def test_config_helper_validation_and_absolute_path(
    tmp_path: Path,
) -> None:
    with pytest.raises(ValueError, match="must be a mapping"):
        config._as_mapping([], "controlled")

    with pytest.raises(ValueError, match="non-empty text"):
        config._as_text("", "controlled")

    with pytest.raises(ValueError, match="non-empty text"):
        config._as_text(1, "controlled")

    with pytest.raises(ValueError, match="nonnegative integer"):
        config._as_nonnegative_integer(-1, "controlled")

    with pytest.raises(ValueError, match="nonnegative integer"):
        config._as_nonnegative_integer(True, "controlled")

    assert config._as_text("  value  ", "controlled") == "value"
    assert config._as_nonnegative_integer(0, "controlled") == 0

    absolute = (tmp_path / "absolute.duckdb").resolve()
    relative = Path("data") / "relative.duckdb"

    assert (
        config._resolve_project_path(
            tmp_path,
            str(absolute),
            "controlled",
        )
        == absolute
    )
    assert (
        config._resolve_project_path(
            tmp_path,
            str(relative),
            "controlled",
        )
        == (tmp_path / relative).resolve()
    )


def test_config_rejects_invalid_logging_level(
    tmp_path: Path,
) -> None:
    source = Path("configs/project.yaml")
    payload = yaml.safe_load(source.read_text(encoding="utf-8"))
    payload["logging"]["level"] = "TRACE"

    config_directory = tmp_path / "project" / "configs"
    config_directory.mkdir(parents=True)
    config_path = config_directory / "project.yaml"
    config_path.write_text(
        yaml.safe_dump(payload, sort_keys=False),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match=r"logging\.level"):
        config.load_config(config_path)


class _NoRowConnection:
    def __init__(self) -> None:
        self.closed = False

    def execute(self, _query: str) -> _NoRowConnection:
        return self

    def fetchone(self) -> None:
        return None

    def close(self) -> None:
        self.closed = True


def test_cli_doctor_rejects_missing_database_row(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection = _NoRowConnection()

    monkeypatch.setattr(
        cli.duckdb,
        "connect",
        lambda database: connection,
    )

    with pytest.raises(
        RuntimeError,
        match="returned no row",
    ):
        cli._doctor(Path("configs/project.yaml"))

    assert connection.closed is True


class _UnsupportedParser:
    def parse_args(
        self,
        _args: object = None,
    ) -> argparse.Namespace:
        return argparse.Namespace(
            command="unsupported",
            config=Path("configs/project.yaml"),
        )


def test_cli_rejects_unsupported_command(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    parser = _UnsupportedParser()

    monkeypatch.setattr(
        cli,
        "build_parser",
        lambda: parser,
    )

    with pytest.raises(
        RuntimeError,
        match="Unsupported command",
    ):
        cli.main([])
