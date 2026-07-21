"""Validation tests for Section 8 processed analytical outputs."""

from __future__ import annotations

from pathlib import Path

import duckdb
import pandas as pd
import yaml

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "configs/processed_data.yaml"


def _config() -> dict:
    return yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))


def _frame(label: str) -> pd.DataFrame:
    config = _config()
    path = ROOT / config["output"][label]
    assert path.exists(), f"Missing required output: {path}"
    return pd.read_parquet(path)


def test_processed_outputs_have_controlled_schema() -> None:
    required = {
        "observation_date",
        "alignment_frequency",
        "source_name",
        "source_series_id",
        "value",
        "standardized_unit",
        "source_file",
        "source_sha256",
        "lineage_id",
        "missing_value_policy",
        "value_lag_1",
    }
    for label in ("fed_liquidity_factors", "treasury_market_factors"):
        frame = _frame(label)
        assert not frame.empty
        assert required.issubset(frame.columns)
        assert set(frame["alignment_frequency"].dropna().unique()) == {"daily", "weekly"}
        assert frame["source_file"].notna().all()
        assert frame["source_sha256"].str.fullmatch(r"[0-9a-f]{64}").all()


def test_processed_outputs_have_unique_analytical_keys() -> None:
    key = ["observation_date", "alignment_frequency", "source_name", "source_series_id"]
    for label in ("fed_liquidity_factors", "treasury_market_factors"):
        frame = _frame(label)
        assert not frame.duplicated(key).any()


def test_standardized_units_and_maturity_mapping() -> None:
    allowed = {"USD", "PERCENT", "BASIS_POINTS", "COUNT", "INDEX", "UNKNOWN"}
    fed = _frame("fed_liquidity_factors")
    treasury = _frame("treasury_market_factors")
    assert set(fed["standardized_unit"].dropna().unique()).issubset(allowed)
    assert set(treasury["standardized_unit"].dropna().unique()).issubset(allowed)
    h15 = treasury.loc[treasury["source_name"] == "H15"]
    if not h15.empty:
        identifiable = (
            h15["source_series_id"]
            .astype(str)
            .str.contains(r"DGS|DTB|month|year|yield", case=False, regex=True, na=False)
        )
        if identifiable.any():
            assert h15.loc[identifiable, "maturity_months"].notna().any()


def test_duckdb_analytical_tables_exist() -> None:
    config = _config()
    database = ROOT / config["output"]["duckdb"]
    assert database.exists()
    connection = duckdb.connect(str(database), read_only=True)
    try:
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'"
            ).fetchall()
        }
        assert {
            "fed_liquidity_factors",
            "treasury_market_factors",
            "analytical_dataset_build_metadata",
        }.issubset(tables)
        assert connection.execute("SELECT count(*) FROM fed_liquidity_factors").fetchone()[0] > 0
        assert connection.execute("SELECT count(*) FROM treasury_market_factors").fetchone()[0] > 0
    finally:
        connection.close()
