"""Typed YAML configuration loading and validation."""

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import cast

import yaml


def _as_mapping(value: object, field_name: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"Configuration field '{field_name}' must be a mapping.")
    return cast(Mapping[str, object], value)


def _as_text(value: object, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Configuration field '{field_name}' must be non-empty text.")
    return value.strip()


def _as_nonnegative_integer(value: object, field_name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"Configuration field '{field_name}' must be a nonnegative integer.")
    return value


def _resolve_project_path(project_root: Path, value: object, field_name: str) -> Path:
    configured = Path(_as_text(value, field_name))
    return configured if configured.is_absolute() else (project_root / configured).resolve()


@dataclass(frozen=True, slots=True)
class ProjectConfig:
    """Validated settings required by the technical architecture."""

    name: str
    display_name: str
    currency: str
    python_version: str
    random_seed: int
    timezone: str
    database_path: Path
    parquet_directory: Path
    log_level: str
    log_file: Path
    project_root: Path

    def create_runtime_directories(self) -> None:
        """Create the configured output directories without creating data files."""
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self.parquet_directory.mkdir(parents=True, exist_ok=True)
        self.log_file.parent.mkdir(parents=True, exist_ok=True)


def load_config(path: str | Path = "configs/project.yaml") -> ProjectConfig:
    """Load and validate project configuration from YAML."""
    config_path = Path(path).expanduser().resolve()
    if not config_path.is_file():
        raise FileNotFoundError(f"Configuration file not found: {config_path}")

    loaded = cast(object, yaml.safe_load(config_path.read_text(encoding="utf-8")))
    root = _as_mapping(loaded, "root")
    project = _as_mapping(root.get("project"), "project")
    runtime = _as_mapping(root.get("runtime"), "runtime")
    storage = _as_mapping(root.get("storage"), "storage")
    logging_config = _as_mapping(root.get("logging"), "logging")
    project_root = config_path.parent.parent.resolve()

    log_level = _as_text(logging_config.get("level"), "logging.level").upper()
    allowed_levels = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
    if log_level not in allowed_levels:
        raise ValueError(f"logging.level must be one of {sorted(allowed_levels)}.")

    return ProjectConfig(
        name=_as_text(project.get("name"), "project.name"),
        display_name=_as_text(project.get("display_name"), "project.display_name"),
        currency=_as_text(project.get("currency"), "project.currency"),
        python_version=_as_text(runtime.get("python_version"), "runtime.python_version"),
        random_seed=_as_nonnegative_integer(runtime.get("random_seed"), "runtime.random_seed"),
        timezone=_as_text(runtime.get("timezone"), "runtime.timezone"),
        database_path=_resolve_project_path(
            project_root, storage.get("database_path"), "storage.database_path"
        ),
        parquet_directory=_resolve_project_path(
            project_root, storage.get("parquet_directory"), "storage.parquet_directory"
        ),
        log_level=log_level,
        log_file=_resolve_project_path(
            project_root, logging_config.get("file_path"), "logging.file_path"
        ),
        project_root=project_root,
    )
