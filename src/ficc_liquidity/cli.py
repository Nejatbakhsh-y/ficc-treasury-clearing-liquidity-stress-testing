"""Reproducible command-line entry points."""

import argparse
import json
import platform
from collections.abc import Sequence
from pathlib import Path

import duckdb

from ficc_liquidity.config import load_config
from ficc_liquidity.database import connect_database, initialize_database
from ficc_liquidity.logging_config import configure_logging
from ficc_liquidity.reproducibility import set_deterministic_seed


def build_parser() -> argparse.ArgumentParser:
    """Build the project command-line parser."""
    parser = argparse.ArgumentParser(prog="ficc-liquidity")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/project.yaml"),
        help="Path to the YAML project configuration.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor", help="Run a deterministic architecture smoke check.")
    subparsers.add_parser("init-db", help="Initialize the configured DuckDB database.")
    return parser


def _doctor(config_path: Path) -> dict[str, str | int | bool]:
    config = load_config(config_path)
    logger = configure_logging(config.log_level)
    generator = set_deterministic_seed(config.random_seed)
    connection = duckdb.connect(database=":memory:")
    try:
        row = connection.execute("SELECT 1").fetchone()
        if row is None:
            raise RuntimeError("DuckDB architecture query returned no row.")
        scalar = int(row[0])
    finally:
        connection.close()

    logger.info("Architecture doctor completed")
    return {
        "config_loaded": True,
        "database_smoke": scalar == 1,
        "duckdb_version": duckdb.__version__,
        "project": config.name,
        "python": platform.python_version(),
        "random_seed": config.random_seed,
        "seed_probe": int(generator.integers(0, 1_000_000)),
    }


def main(argv: Sequence[str] | None = None) -> int:
    """Execute a supported project command."""
    arguments = build_parser().parse_args(list(argv) if argv is not None else None)
    config_path = Path(arguments.config)

    if arguments.command == "doctor":
        print(json.dumps(_doctor(config_path), indent=2, sort_keys=True))
        return 0

    if arguments.command == "init-db":
        config = load_config(config_path)
        config.create_runtime_directories()
        logger = configure_logging(config.log_level, config.log_file)
        connection = connect_database(config.database_path)
        try:
            initialize_database(connection)
        finally:
            connection.close()
        logger.info("Initialized DuckDB database at %s", config.database_path)
        return 0

    raise RuntimeError(f"Unsupported command: {arguments.command}")
