from __future__ import annotations

from pathlib import Path

import yaml

from ficc_liquidity.data import h15, h41


def test_catalog_contains_supporting_fed_contracts() -> None:
    catalog_path = Path("configs/data_sources.yaml")
    if not catalog_path.exists():
        import pytest

        pytest.skip("controlled catalog is created by Phase II Section 4")
    document = yaml.safe_load(catalog_path.read_text(encoding="utf-8"))
    series = document["series"]
    by_source: dict[str, set[str]] = {}
    for item in series:
        by_source.setdefault(item["source_id"], set()).add(item["series_identifier"].split()[0])

    assert set(h15.SERIES_IDS).issubset(by_source["frb_h15"])
    assert set(h41.SERIES_IDS).issubset(by_source["frb_h41"])
    sofr_contracts = {item["contract_id"] for item in series if item["source_id"] == "nyfed_sofr"}
    assert sofr_contracts == {
        "SOFR_RATE",
        "SOFR_P01",
        "SOFR_P25",
        "SOFR_P75",
        "SOFR_P99",
        "SOFR_VOLUME",
    }
