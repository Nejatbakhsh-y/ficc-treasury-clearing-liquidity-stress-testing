from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pandas as pd
import pytest

from ficc_liquidity.data import _fed_common as common
from ficc_liquidity.data import h41


def _csv(series_id: str) -> bytes:
    return (f"DATE,{series_id}\n2026-07-01,3000000\n2026-07-08,3100000\n").encode()


def test_h41_contract_and_parser() -> None:
    assert h41.SERIES_IDS == (
        "WRBWFRBL",
        "WRESBAL",
        "WALCL",
        "TREAST",
        "WLRRAL",
        "WDTGAL",
        "WORAL",
    )
    frame = h41.parse_series_payload(_csv("WALCL"), "WALCL")
    assert len(frame) == 2
    assert frame["value"].iloc[0] == pytest.approx(3_000_000.0)


def test_h41_rejects_non_wednesday_and_negative_values() -> None:
    with pytest.raises(common.IngestionError, match="Wednesday"):
        h41.parse_series_payload(b"DATE,WALCL\n2026-07-02,3000000\n", "WALCL")
    with pytest.raises(common.IngestionError, match="controlled range"):
        h41.parse_series_payload(b"DATE,WALCL\n2026-07-01,-1\n", "WALCL")


def test_h41_ingest_all_controlled_series(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    def downloader(url: str) -> bytes:
        series_id = parse_qs(urlparse(url).query)["id"][0]
        return _csv(series_id)

    def fake_parquet(frame: pd.DataFrame, destination: Path) -> None:
        assert frame["series_id"].nunique() == 7
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"PARQUET")

    monkeypatch.setattr(common, "write_parquet_atomic", fake_parquet)
    result = h41.ingest(
        tmp_path,
        downloader=downloader,
        retrieved_at=datetime(2026, 7, 19, 20, 0, tzinfo=UTC),
    )
    assert result["series_count"] == 7
    assert result["rows"] == 14
    manifest = pd.read_csv(tmp_path / "data/manifests/h41_manifest.csv")
    assert set(manifest["series_id"]) == set(h41.SERIES_IDS)
    assert manifest["status"].eq("PASS").all()


def test_h41_main_and_input_controls(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(common.IngestionError, match="after"):
        h41.build_url("WALCL", datetime(2026, 7, 2).date(), datetime(2026, 7, 1).date())
    with pytest.raises(common.IngestionError, match="nonempty"):
        h41.ingest(Path.cwd(), series_ids=())
    with pytest.raises(common.IngestionError, match="uncontrolled"):
        h41.ingest(Path.cwd(), series_ids=("BAD",))

    def fake_ingest(
        project_root: Path,
        *,
        start_date: object = None,
        end_date: object = None,
    ) -> dict[str, object]:
        assert project_root.is_absolute()
        assert start_date is None
        assert end_date is None
        return {"rows": 14}

    monkeypatch.setattr(h41, "ingest", fake_ingest)
    assert h41.main([]) == 0
    assert '"rows": "14"' in capsys.readouterr().out
