"""Tests for Phase IX, Section 33 dashboard support."""

from __future__ import annotations

from pathlib import Path

import pandas as pd
import pytest
from streamlit.testing.v1 import AppTest

from ficc_liquidity.dashboard.core import (
    DATASET_SPECS,
    build_demo_data,
    discover_candidates,
    load_dataset,
)


@pytest.mark.parametrize("key", sorted(DATASET_SPECS))
def test_every_dashboard_subject_has_deterministic_fallback(key: str) -> None:
    first = build_demo_data(key)
    second = build_demo_data(key)

    assert not first.empty
    pd.testing.assert_frame_equal(first, second)


def test_candidate_discovery_prefers_repository_evidence(tmp_path: Path) -> None:
    evidence = tmp_path / "reports" / "evidence_package"
    evidence.mkdir(parents=True)
    preferred = evidence / "lcr_results.csv"
    preferred.write_text("scenario,lcr\nSevere,0.91\n", encoding="utf-8")

    other = tmp_path / "data"
    other.mkdir()
    (other / "scenario_results.csv").write_text(
        "scenario,lcr\nModerate,1.20\n",
        encoding="utf-8",
    )

    candidates = discover_candidates(tmp_path, "lcr_results")
    assert candidates
    assert candidates[0] == preferred


def test_load_dataset_reads_repository_artifact(tmp_path: Path) -> None:
    report = tmp_path / "reports"
    report.mkdir()
    path = report / "finding_register.csv"
    path.write_text(
        "Finding ID,Classification,Status\nF-001,High,Open\n",
        encoding="utf-8",
    )

    bundle = load_dataset(tmp_path, "findings")

    assert bundle.is_demo is False
    assert bundle.source == "reports/finding_register.csv"
    assert list(bundle.data.columns) == ["finding_id", "classification", "status"]


def test_load_dataset_uses_labelled_demo_when_absent(tmp_path: Path) -> None:
    bundle = load_dataset(tmp_path, "monitoring_results")

    assert bundle.is_demo is True
    assert bundle.source == "deterministic synthetic fallback"
    assert "fictional" in bundle.note
    assert not bundle.data.empty


def test_load_dataset_can_prohibit_demo(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_dataset(tmp_path, "reverse_stress", allow_demo=False)


def test_streamlit_default_page_smoke(monkeypatch: pytest.MonkeyPatch) -> None:
    root = Path(__file__).resolve().parents[1]
    monkeypatch.setenv("FICC_DASHBOARD_ALLOW_DEMO", "1")
    app = AppTest.from_file(root / "dashboard" / "streamlit_app.py")
    app.run(timeout=30)

    assert not app.exception
    assert app.title
    assert app.title[0].value == "Executive Summary"
