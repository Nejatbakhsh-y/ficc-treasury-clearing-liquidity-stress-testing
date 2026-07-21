from __future__ import annotations

import json
from datetime import UTC, date, datetime
from pathlib import Path

import pandas as pd
import pytest

from ficc_liquidity.data import _fed_common as common
from ficc_liquidity.data import sofr


def _payload() -> bytes:
    return json.dumps(
        {
            "refRates": [
                {
                    "effectiveDate": "2026-07-01",
                    "percentRate": "3.62",
                    "percentile1": "3.55",
                    "percentile25": "3.59",
                    "percentile75": "3.66",
                    "percentile99": "3.71",
                    "volumeInBillions": "3,050",
                    "revisionIndicator": "",
                },
                {
                    "effectiveDate": "2026-07-02",
                    "percentRate": "3.60",
                    "percentile1": "3.54",
                    "percentile25": "3.58",
                    "percentile75": "3.64",
                    "percentile99": "3.69",
                    "volumeInBillions": "3,010",
                    "revisionIndicator": "R",
                },
            ]
        }
    ).encode()


def test_build_url_and_parse_payload() -> None:
    url = sofr.build_url(date(2026, 7, 1), date(2026, 7, 2))
    assert url.startswith("https://markets.newyorkfed.org/")
    assert "startDate=2026-07-01" in url
    assert "endDate=2026-07-02" in url
    frame = sofr.parse_payload(_payload())
    assert list(frame.columns) == list(sofr.OUTPUT_COLUMNS)
    assert len(frame) == 2
    assert frame.loc[0, "sofr_rate"] == pytest.approx(3.62)
    assert frame.loc[0, "volume_billions"] == pytest.approx(3050.0)


def test_sofr_rejects_duplicate_dates_and_bad_percentiles() -> None:
    document = json.loads(_payload())
    document["refRates"].append(document["refRates"][0])
    with pytest.raises(common.IngestionError, match="duplicate"):
        sofr.parse_payload(json.dumps(document).encode())

    bad = json.loads(_payload())
    bad["refRates"][0]["percentile25"] = "4.50"
    with pytest.raises(common.IngestionError, match="ordering"):
        sofr.parse_payload(json.dumps(bad).encode())


def test_sofr_ingest_writes_raw_processed_and_manifest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    written: list[Path] = []

    def fake_parquet(frame: pd.DataFrame, destination: Path) -> None:
        assert len(frame) == 2
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"PARQUET")
        written.append(destination)

    monkeypatch.setattr(common, "write_parquet_atomic", fake_parquet)
    result = sofr.ingest(
        tmp_path,
        downloader=lambda _url: _payload(),
        retrieved_at=datetime(2026, 7, 19, 20, 0, tzinfo=UTC),
    )
    assert result["rows"] == 2
    assert written and written[0].exists()
    manifest = pd.read_csv(tmp_path / "data/manifests/sofr_manifest.csv")
    assert len(manifest) == 1
    assert manifest.loc[0, "status"] == "PASS"
    assert len(str(manifest.loc[0, "sha256"])) == 64


def test_sofr_main(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    def fake_ingest(
        project_root: Path,
        *,
        start_date: date | None = None,
        end_date: date | None = None,
    ) -> dict[str, object]:
        assert project_root.is_absolute()
        assert start_date == date(2026, 7, 1)
        assert end_date == date(2026, 7, 2)
        return {"rows": 2, "processed_path": Path("data.parquet")}

    monkeypatch.setattr(sofr, "ingest", fake_ingest)
    assert sofr.main(["--start-date", "2026-07-01", "--end-date", "2026-07-02"]) == 0
    assert '"rows": "2"' in capsys.readouterr().out
