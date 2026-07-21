from __future__ import annotations

import csv
from datetime import UTC, datetime
from pathlib import Path
from urllib.error import URLError

import pandas as pd
import pytest

from ficc_liquidity.data import _fed_common as common


class _Response:
    def __init__(self, payload: bytes) -> None:
        self.payload = payload

    def __enter__(self) -> _Response:
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return self.payload


def test_time_and_hash_controls() -> None:
    value = datetime(2026, 7, 19, 20, 1, 2, tzinfo=UTC)
    assert common.utc_now().tzinfo is not None
    assert common.utc_timestamp(value) == "2026-07-19T20:01:02Z"
    assert common.filename_timestamp(value) == "20260719T200102Z"
    assert len(common.sha256_bytes(b"abc")) == 64
    with pytest.raises(common.IngestionError, match="timezone-aware"):
        common.utc_timestamp(datetime(2026, 7, 19))
    with pytest.raises(common.IngestionError, match="timezone-aware"):
        common.filename_timestamp(datetime(2026, 7, 19))


def test_download_controls_and_retry(monkeypatch: pytest.MonkeyPatch) -> None:
    with pytest.raises(common.IngestionError, match="HTTPS"):
        common.download_bytes("http://example.test")
    with pytest.raises(common.IngestionError, match="at least one"):
        common.download_bytes("https://example.test", attempts=0)

    calls = 0

    def fake_urlopen(_request: object, timeout: int) -> _Response:
        nonlocal calls
        assert timeout == 5
        calls += 1
        if calls == 1:
            raise URLError("temporary")
        return _Response(b"ok")

    monkeypatch.setattr(common, "urlopen", fake_urlopen)
    monkeypatch.setattr("ficc_liquidity.data._fed_common.time.sleep", lambda _seconds: None)
    assert common.download_bytes("https://example.test", attempts=2, timeout_seconds=5) == b"ok"
    assert calls == 2

    monkeypatch.setattr(common, "urlopen", lambda *_args, **_kwargs: _Response(b""))
    with pytest.raises(common.IngestionError, match="download failed"):
        common.download_bytes("https://example.test", attempts=1)


def test_raw_parquet_and_path_controls(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    timestamp = datetime(2026, 7, 19, 20, 0, tzinfo=UTC)
    path, digest = common.save_immutable_raw(
        payload=b"source",
        raw_directory=tmp_path / "raw",
        source_id="source",
        series_id="A/B",
        suffix=".csv",
        retrieved_at=timestamp,
    )
    assert path.exists()
    assert path.read_bytes() == b"source"
    same_path, same_digest = common.save_immutable_raw(
        payload=b"source",
        raw_directory=tmp_path / "raw",
        source_id="source",
        series_id="A/B",
        suffix=".csv",
        retrieved_at=timestamp,
    )
    assert (same_path, same_digest) == (path, digest)

    monkeypatch.setattr(common, "sha256_bytes", lambda _payload: "0" * 64)
    collision_path, _ = common.save_immutable_raw(
        payload=b"first",
        raw_directory=tmp_path / "collision",
        source_id="source",
        series_id="x",
        suffix=".csv",
        retrieved_at=timestamp,
    )
    assert collision_path.exists()
    with pytest.raises(common.IngestionError, match="collision"):
        common.save_immutable_raw(
            payload=b"second",
            raw_directory=tmp_path / "collision",
            source_id="source",
            series_id="x",
            suffix=".csv",
            retrieved_at=timestamp,
        )

    frame = pd.DataFrame({"a": [1]})

    def fake_to_parquet(self: pd.DataFrame, destination: Path, index: bool) -> None:
        assert self.equals(frame)
        assert index is False
        Path(destination).write_bytes(b"parquet")

    monkeypatch.setattr(pd.DataFrame, "to_parquet", fake_to_parquet)
    output = tmp_path / "processed" / "data.parquet"
    common.write_parquet_atomic(frame, output)
    assert output.read_bytes() == b"parquet"
    assert common.relative_posix(output, tmp_path) == "processed/data.parquet"


def test_dataframe_validators() -> None:
    frame = pd.DataFrame(
        {"observation_date": ["2026-07-01", "2026-07-02"], "series_id": ["A", "A"]}
    )
    assert common.observation_bounds(frame) == ("2026-07-01", "2026-07-02")
    common.validate_unique(frame, ["observation_date", "series_id"])
    common.validate_required_columns(frame, ["observation_date", "series_id"])
    normalized = common.normalize_numeric(pd.Series(["1,234", ".", "N/A"]))
    assert normalized.iloc[0] == pytest.approx(1234.0)
    assert normalized.iloc[1:].isna().all()

    with pytest.raises(common.IngestionError, match="empty"):
        common.observation_bounds(pd.DataFrame(columns=["observation_date"]))
    with pytest.raises(common.IngestionError, match="duplicate"):
        common.validate_unique(pd.concat([frame.iloc[[0]], frame.iloc[[0]]]), ["observation_date"])
    with pytest.raises(common.IngestionError, match="missing"):
        common.validate_required_columns(frame, ["value"])


def test_manifest_controls(tmp_path: Path) -> None:
    path = tmp_path / "manifest.csv"
    common.ensure_manifest_header(path)
    common.ensure_manifest_header(path)
    row = {
        "source_id": "source",
        "series_id": "series",
        "retrieved_at_utc": "2026-07-19T20:00:00Z",
        "source_url": "https://example.test",
        "raw_path": "data/raw/source.csv",
        "processed_path": "data/processed/source.parquet",
        "sha256": "a" * 64,
        "file_size_bytes": 10,
        "row_count": 2,
        "observation_start": "2026-07-01",
        "observation_end": "2026-07-02",
        "status": "PASS",
        "notes": "test",
    }
    common.append_manifest(path, row)
    common.append_manifest(path, row)
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert len(rows) == 1

    bad = tmp_path / "bad.csv"
    bad.write_text("wrong\nvalue\n", encoding="utf-8")
    with pytest.raises(common.IngestionError, match="schema mismatch"):
        common.append_manifest(bad, row)
