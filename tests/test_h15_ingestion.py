from __future__ import annotations

from datetime import UTC, date, datetime
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pandas as pd
import pytest

from ficc_liquidity.data import _fed_common as common
from ficc_liquidity.data import h15


def _csv(series_id: str) -> bytes:
    return (
        f"observation_date,{series_id}\n2026-07-01,4.25\n2026-07-02,.\n2026-07-06,4.31\n"
    ).encode()


def test_h15_contract_and_parser() -> None:
    assert len(h15.SERIES_IDS) == 11
    url = h15.build_url("DGS10", date(2026, 7, 1), date(2026, 7, 6))
    assert parse_qs(urlparse(url).query)["id"] == ["DGS10"]
    frame = h15.parse_series_payload(_csv("DGS10"), "DGS10")
    assert len(frame) == 2
    assert frame["value"].tolist() == pytest.approx([4.25, 4.31])
    with pytest.raises(common.IngestionError, match="uncontrolled"):
        h15.build_url("BAD")


def test_h15_rejects_duplicate_observations() -> None:
    payload = b"DATE,DGS10\n2026-07-01,4.25\n2026-07-01,4.26\n"
    with pytest.raises(common.IngestionError, match="duplicate"):
        h15.parse_series_payload(payload, "DGS10")


def test_h15_ingest_all_controlled_series(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def downloader(url: str) -> bytes:
        series_id = parse_qs(urlparse(url).query)["id"][0]
        return _csv(series_id)

    def fake_parquet(frame: pd.DataFrame, destination: Path) -> None:
        assert frame["series_id"].nunique() == 11
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"PARQUET")

    monkeypatch.setattr(common, "write_parquet_atomic", fake_parquet)
    result = h15.ingest(
        tmp_path,
        downloader=downloader,
        retrieved_at=datetime(2026, 7, 19, 20, 0, tzinfo=UTC),
    )
    assert result["series_count"] == 11
    assert result["rows"] == 22
    manifest = pd.read_csv(tmp_path / "data/manifests/h15_manifest.csv")
    assert set(manifest["series_id"]) == set(h15.SERIES_IDS)
    assert manifest["status"].eq("PASS").all()


def test_h15_main_and_input_controls(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(common.IngestionError, match="after"):
        h15.build_url("DGS10", date(2026, 7, 2), date(2026, 7, 1))
    with pytest.raises(common.IngestionError, match="nonempty"):
        h15.ingest(Path.cwd(), series_ids=())
    with pytest.raises(common.IngestionError, match="uncontrolled"):
        h15.ingest(Path.cwd(), series_ids=("BAD",))

    def fake_ingest(
        project_root: Path,
        *,
        start_date: date | None = None,
        end_date: date | None = None,
    ) -> dict[str, object]:
        assert project_root.is_absolute()
        assert start_date == date(2026, 7, 1)
        assert end_date is None
        return {"rows": 22}

    monkeypatch.setattr(h15, "ingest", fake_ingest)
    assert h15.main(["--start-date", "2026-07-01"]) == 0
    assert '"rows": "22"' in capsys.readouterr().out
