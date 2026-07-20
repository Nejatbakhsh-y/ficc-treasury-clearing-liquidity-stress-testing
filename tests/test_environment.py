"""Section 3 environment, storage, reproducibility, and CLI smoke tests."""

import json
import logging
import os
import random
import sys
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd
import pytest

from ficc_liquidity.cli import main
from ficc_liquidity.config import load_config
from ficc_liquidity.database import connect_database, initialize_database, write_parquet
from ficc_liquidity.logging_config import configure_logging
from ficc_liquidity.reproducibility import set_deterministic_seed

PROJECT_CONFIG = Path("configs/project.yaml")


def _temporary_config(tmp_path: Path) -> Path:
    root = tmp_path / "project"
    config_directory = root / "configs"
    config_directory.mkdir(parents=True)
    config_path = config_directory / "project.yaml"
    config_path.write_text(PROJECT_CONFIG.read_text(encoding="utf-8"), encoding="utf-8")
    return config_path


def test_python_311_and_package_import() -> None:
    assert sys.version_info[:2] == (3, 11)


def test_yaml_configuration_is_typed_and_resolved() -> None:
    config = load_config(PROJECT_CONFIG)
    assert config.python_version == "3.11"
    assert config.random_seed == 2026
    assert config.currency == "USD"
    assert config.database_path.is_absolute()
    assert config.parquet_directory.is_absolute()


def test_configuration_creates_runtime_directories(tmp_path: Path) -> None:
    config = load_config(_temporary_config(tmp_path))
    config.create_runtime_directories()
    assert config.database_path.parent.is_dir()
    assert config.parquet_directory.is_dir()
    assert config.log_file.parent.is_dir()


def test_missing_and_invalid_configuration_are_rejected(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_config(tmp_path / "missing.yaml")

    invalid = tmp_path / "invalid.yaml"
    invalid.write_text("runtime: []\n", encoding="utf-8")
    with pytest.raises(ValueError, match="project"):
        load_config(invalid)


def test_random_seed_is_deterministic() -> None:
    first_generator = set_deterministic_seed(2026)
    first = (random.random(), float(np.random.random()), int(first_generator.integers(1000)))
    second_generator = set_deterministic_seed(2026)
    second = (random.random(), float(np.random.random()), int(second_generator.integers(1000)))
    assert first == second
    assert os.environ["PYTHONHASHSEED"] == "2026"

    with pytest.raises(ValueError, match="nonnegative"):
        set_deterministic_seed(-1)


def test_duckdb_and_parquet_storage(tmp_path: Path) -> None:
    database_path = tmp_path / "processed" / "smoke.duckdb"
    connection = connect_database(database_path)
    try:
        initialize_database(connection)
        tables = {row[0] for row in connection.execute("SHOW TABLES").fetchall()}
    finally:
        connection.close()
    assert "run_metadata" in tables

    parquet_path = write_parquet(
        pd.DataFrame({"business_date": ["2026-07-19"], "liquidity_need": [100.0]}),
        tmp_path / "processed" / "smoke.parquet",
    )
    verification = duckdb.connect(database=":memory:")
    try:
        row = verification.execute(
            "SELECT COUNT(*) FROM read_parquet(?)", [str(parquet_path)]
        ).fetchone()
    finally:
        verification.close()
    assert row is not None
    count = row[0]
    assert count == 1


def test_central_logging_writes_file(tmp_path: Path) -> None:
    log_path = tmp_path / "logs" / "smoke.log"
    logger = configure_logging("INFO", log_path)
    logger.info("section-three-smoke")
    for handler in logger.handlers:
        handler.flush()
    assert "section-three-smoke" in log_path.read_text(encoding="utf-8")

    with pytest.raises(ValueError, match="Invalid logging level"):
        configure_logging("NOT-A-LEVEL")


def test_doctor_cli_is_reproducible(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["--config", str(PROJECT_CONFIG), "doctor"]) == 0
    first = json.loads(capsys.readouterr().out)
    assert main(["--config", str(PROJECT_CONFIG), "doctor"]) == 0
    second = json.loads(capsys.readouterr().out)
    assert first["config_loaded"] is True
    assert first["database_smoke"] is True
    assert first["seed_probe"] == second["seed_probe"]


def test_init_db_cli_creates_database_and_log(tmp_path: Path) -> None:
    config_path = _temporary_config(tmp_path)
    assert main(["--config", str(config_path), "init-db"]) == 0
    config = load_config(config_path)
    assert config.database_path.is_file()
    assert config.log_file.is_file()


def test_read_only_database_connection(tmp_path: Path) -> None:
    database_path = tmp_path / "readonly.duckdb"
    writable = connect_database(database_path)
    writable.execute("CREATE TABLE smoke(value INTEGER)")
    writable.close()
    readonly = connect_database(database_path, read_only=True)
    try:
        row = readonly.execute("SELECT COUNT(*) FROM smoke").fetchone()
        assert row is not None
        assert row[0] == 0
    finally:
        readonly.close()


def test_logger_has_expected_name_and_no_propagation() -> None:
    logger = configure_logging("WARNING")
    assert logger.name == "ficc_liquidity"
    assert logger.level == logging.WARNING
    assert logger.propagate is False
