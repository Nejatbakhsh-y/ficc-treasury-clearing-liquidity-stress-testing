"""DuckDB and Parquet storage helpers."""

from pathlib import Path

import duckdb
import pandas as pd


def connect_database(database_path: Path, *, read_only: bool = False) -> duckdb.DuckDBPyConnection:
    """Open the analytical DuckDB database."""
    if not read_only:
        database_path.parent.mkdir(parents=True, exist_ok=True)
    return duckdb.connect(database=str(database_path), read_only=read_only)


def initialize_database(connection: duckdb.DuckDBPyConnection) -> None:
    """Create architecture-level metadata tables idempotently."""
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS run_metadata (
            run_id VARCHAR PRIMARY KEY,
            started_at TIMESTAMPTZ NOT NULL,
            seed INTEGER NOT NULL,
            command VARCHAR NOT NULL,
            status VARCHAR NOT NULL
        )
        """
    )


def write_parquet(frame: pd.DataFrame, destination: Path) -> Path:
    """Write a processed dataset in compressed Parquet format."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    frame.to_parquet(destination, engine="pyarrow", compression="snappy", index=False)
    return destination
