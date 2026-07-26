"""Build a reproducible Section 32 evidence package.

The builder inventories existing model outputs, copies evidence into a controlled
package, records configuration and runtime provenance, computes SHA-256 checksums,
and creates a ZIP archive. It intentionally does not recalculate production-model
results; it packages already generated evidence from prior roadmap sections.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import zipfile
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - fallback is covered through defaults
    yaml = None


DEFAULT_REQUIRED_CATEGORIES = (
    "data_quality",
    "scenario_results",
    "cover_1_cover_2",
    "lcr_results",
    "liquidity_shortfalls",
    "component_contributions",
    "sensitivity_results",
    "reverse_stress_results",
    "monitoring_results",
    "validation_findings",
    "configuration_provenance",
    "runtime_environment",
)

DEFAULT_CATEGORY_PATTERNS: dict[str, list[str]] = {
    "data_quality": [
        "reports/**/*data*quality*.csv",
        "reports/**/*data*quality*.json",
        "reports/**/*data*quality*.md",
        "data/**/*quality*.csv",
        "data/**/*validation*.csv",
    ],
    "scenario_results": [
        "reports/**/*scenario*.csv",
        "reports/**/*scenario*.json",
        "reports/**/*scenario*.parquet",
    ],
    "cover_1_cover_2": [
        "reports/**/*cover*1*.csv",
        "reports/**/*cover*2*.csv",
        "reports/**/*cover*.json",
        "reports/**/*default*set*.csv",
    ],
    "lcr_results": [
        "reports/**/*lcr*.csv",
        "reports/**/*lcr*.json",
        "reports/**/*liquidity*coverage*.csv",
    ],
    "liquidity_shortfalls": [
        "reports/**/*shortfall*.csv",
        "reports/**/*shortfall*.json",
    ],
    "component_contributions": [
        "reports/**/*component*contribution*.csv",
        "reports/**/*component*contribution*.json",
        "reports/**/*component*reconciliation*.csv",
    ],
    "sensitivity_results": [
        "reports/**/*sensitivity*.csv",
        "reports/**/*sensitivity*.json",
    ],
    "reverse_stress_results": [
        "reports/**/*reverse*stress*.csv",
        "reports/**/*reverse*stress*.json",
    ],
    "monitoring_results": [
        "reports/**/*monitoring*.csv",
        "reports/**/*monitoring*.json",
        "reports/**/*threshold*.csv",
    ],
    "validation_findings": [
        "reports/**/*finding*register*.csv",
        "reports/**/*validation*finding*.csv",
        "reports/**/*finding*.json",
    ],
    "configuration_provenance": [
        "configs/**/*.yaml",
        "configs/**/*.yml",
        "configs/**/*.json",
        "pyproject.toml",
        "requirements*.txt",
        "uv.lock",
        "poetry.lock",
    ],
    "runtime_environment": [
        "reports/**/*runtime*.json",
        "reports/**/*environment*.txt",
        "reports/**/*environment*.json",
    ],
}

DEFAULT_EXCLUDES = (
    "reports/evidence_packages/**",
    ".git/**",
    ".venv/**",
    "**/__pycache__/**",
    ".pytest_cache/**",
    ".mypy_cache/**",
    ".ruff_cache/**",
)

DEFAULT_EXTENSIONS = (
    ".csv",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".md",
    ".txt",
    ".parquet",
    ".html",
    ".png",
    ".svg",
)


@dataclass(frozen=True)
class EvidenceRecord:
    """One copied evidence artifact."""

    category: str
    source_relative_path: str
    package_relative_path: str
    sha256: str
    size_bytes: int
    modified_utc: str


@dataclass(frozen=True)
class CategoryStatus:
    """Coverage status for one required evidence category."""

    category: str
    status: str
    artifact_count: int
    note: str


@dataclass(frozen=True)
class EvidencePackageResult:
    """Summary returned after a package build."""

    package_directory: str
    archive_path: str
    manifest_path: str
    index_path: str
    package_id: str
    artifact_count: int
    missing_categories: tuple[str, ...]
    elapsed_seconds: float


class EvidencePackageBuilder:
    """Create a deterministic evidence inventory and controlled archive."""

    def __init__(
        self,
        repo_root: Path,
        config_path: Path | None = None,
        output_root: Path | None = None,
        strict: bool = False,
    ) -> None:
        self.repo_root = repo_root.resolve()
        self.config_path = (
            config_path.resolve()
            if config_path is not None
            else self.repo_root / "configs" / "evidence_package.yaml"
        )
        self.config = self._load_config(self.config_path)
        configured_output = Path(
            str(self.config.get("output_root", "reports/evidence_packages"))
        )
        self.output_root = (
            output_root.resolve()
            if output_root is not None
            else (self.repo_root / configured_output).resolve()
        )
        self.strict = strict or bool(
            self.config.get("strict_missing_category_failure", False)
        )
        self.required_categories = tuple(
            self.config.get("required_categories", DEFAULT_REQUIRED_CATEGORIES)
        )
        self.category_patterns = dict(
            self.config.get("category_patterns", DEFAULT_CATEGORY_PATTERNS)
        )
        self.exclude_patterns = tuple(
            self.config.get("exclude_patterns", DEFAULT_EXCLUDES)
        )
        self.copy_extensions = {
            str(value).lower()
            for value in self.config.get("copy_extensions", DEFAULT_EXTENSIONS)
        }

    @staticmethod
    def _load_config(config_path: Path) -> dict[str, Any]:
        if not config_path.exists() or yaml is None:
            return {
                "required_categories": list(DEFAULT_REQUIRED_CATEGORIES),
                "category_patterns": DEFAULT_CATEGORY_PATTERNS,
                "exclude_patterns": list(DEFAULT_EXCLUDES),
                "copy_extensions": list(DEFAULT_EXTENSIONS),
                "output_root": "reports/evidence_packages",
            }
        loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
        return loaded if isinstance(loaded, dict) else {}

    @staticmethod
    def _run_command(args: list[str], cwd: Path) -> dict[str, Any]:
        try:
            completed = subprocess.run(
                args,
                cwd=cwd,
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {
                "command": args,
                "return_code": None,
                "stdout": "",
                "stderr": str(exc),
            }
        return {
            "command": args,
            "return_code": completed.returncode,
            "stdout": completed.stdout.strip(),
            "stderr": completed.stderr.strip(),
        }

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def _is_excluded(self, relative_path: str) -> bool:
        normalized = relative_path.replace("\\", "/")
        return any(
            fnmatch.fnmatch(normalized, pattern)
            for pattern in self.exclude_patterns
        )

    def _discover(self, patterns: Iterable[str]) -> list[Path]:
        discovered: dict[str, Path] = {}
        for pattern in patterns:
            for candidate in self.repo_root.glob(pattern):
                if not candidate.is_file():
                    continue
                relative = candidate.relative_to(self.repo_root).as_posix()
                if self._is_excluded(relative):
                    continue
                if candidate.suffix.lower() not in self.copy_extensions:
                    continue
                discovered[relative.lower()] = candidate
        return [discovered[key] for key in sorted(discovered)]

    @staticmethod
    def _safe_destination(category_dir: Path, source: Path, repo_root: Path) -> Path:
        relative = source.relative_to(repo_root)
        destination = category_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        return destination

    @staticmethod
    def _write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

    def _capture_runtime(self, package_dir: Path, started_at: float) -> Path:
        runtime_dir = package_dir / "runtime_environment"
        runtime_dir.mkdir(parents=True, exist_ok=True)
        commands = {
            "python_version": self._run_command([sys.executable, "--version"], self.repo_root),
            "pip_freeze": self._run_command(
                [sys.executable, "-m", "pip", "freeze"], self.repo_root
            ),
            "git_commit": self._run_command(
                ["git", "rev-parse", "HEAD"], self.repo_root
            ),
            "git_branch": self._run_command(
                ["git", "branch", "--show-current"], self.repo_root
            ),
            "git_status": self._run_command(
                ["git", "status", "--short"], self.repo_root
            ),
            "git_remote": self._run_command(
                ["git", "remote", "-v"], self.repo_root
            ),
        }
        payload = {
            "captured_utc": datetime.now(UTC).isoformat(),
            "elapsed_seconds_at_capture": round(time.perf_counter() - started_at, 6),
            "python_executable": sys.executable,
            "python_implementation": platform.python_implementation(),
            "python_version": platform.python_version(),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "system": platform.system(),
            "release": platform.release(),
            "current_working_directory": str(Path.cwd()),
            "repository_root": str(self.repo_root),
            "environment_variables": {
                key: os.environ.get(key)
                for key in (
                    "CI",
                    "GITHUB_ACTIONS",
                    "PYTHONHASHSEED",
                    "VIRTUAL_ENV",
                )
            },
            "commands": commands,
        }
        output = runtime_dir / "runtime_environment.json"
        output.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        return output

    def _write_missing_marker(self, category_dir: Path, category: str) -> Path:
        marker = category_dir / "MISSING_EVIDENCE.md"
        marker.write_text(
            "\n".join(
                [
                    f"# Missing evidence: {category}",
                    "",
                    "No matching source artifact was discovered during this run.",
                    "Generate the corresponding upstream Section output and rebuild",
                    "the evidence package. This marker is not substantive evidence.",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        return marker

    def _copy_category(
        self,
        package_dir: Path,
        category: str,
        patterns: list[str],
    ) -> tuple[list[EvidenceRecord], CategoryStatus]:
        category_dir = package_dir / category
        category_dir.mkdir(parents=True, exist_ok=True)
        sources = self._discover(patterns)
        records: list[EvidenceRecord] = []
        for source in sources:
            destination = self._safe_destination(
                category_dir=category_dir,
                source=source,
                repo_root=self.repo_root,
            )
            shutil.copy2(source, destination)
            stat = destination.stat()
            records.append(
                EvidenceRecord(
                    category=category,
                    source_relative_path=source.relative_to(self.repo_root).as_posix(),
                    package_relative_path=destination.relative_to(package_dir).as_posix(),
                    sha256=self._sha256(destination),
                    size_bytes=stat.st_size,
                    modified_utc=datetime.fromtimestamp(
                        stat.st_mtime, tz=UTC
                    ).isoformat(),
                )
            )
        if records:
            status = CategoryStatus(
                category=category,
                status="AVAILABLE",
                artifact_count=len(records),
                note="Matching source artifacts copied and checksummed.",
            )
        else:
            self._write_missing_marker(category_dir, category)
            status = CategoryStatus(
                category=category,
                status="MISSING",
                artifact_count=0,
                note="No matching upstream artifact discovered.",
            )
        return records, status

    def _package_id(self) -> str:
        timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        git_result = self._run_command(["git", "rev-parse", "--short", "HEAD"], self.repo_root)
        commit = str(git_result.get("stdout") or "nogit").strip()
        return f"{timestamp}_{commit}"

    def _write_manifest(
        self,
        package_dir: Path,
        records: list[EvidenceRecord],
    ) -> Path:
        manifest_path = package_dir / "evidence_manifest.csv"
        self._write_csv(
            manifest_path,
            [asdict(record) for record in records],
            [
                "category",
                "source_relative_path",
                "package_relative_path",
                "sha256",
                "size_bytes",
                "modified_utc",
            ],
        )
        return manifest_path

    def _write_status(
        self,
        package_dir: Path,
        statuses: list[CategoryStatus],
    ) -> tuple[Path, Path]:
        rows = [asdict(status) for status in statuses]
        csv_path = package_dir / "category_status.csv"
        json_path = package_dir / "category_status.json"
        self._write_csv(
            csv_path,
            rows,
            ["category", "status", "artifact_count", "note"],
        )
        json_path.write_text(json.dumps(rows, indent=2), encoding="utf-8")
        return csv_path, json_path

    def _write_index(
        self,
        package_dir: Path,
        package_id: str,
        records: list[EvidenceRecord],
        statuses: list[CategoryStatus],
        elapsed_seconds: float,
    ) -> Path:
        available = sum(status.status == "AVAILABLE" for status in statuses)
        missing = [status.category for status in statuses if status.status == "MISSING"]
        lines = [
            "# FICC Liquidity Reproducible Evidence Package",
            "",
            f"- Package ID: `{package_id}`",
            f"- Generated UTC: `{datetime.now(UTC).isoformat()}`",
            f"- Required categories: `{len(statuses)}`",
            f"- Available categories: `{available}`",
            f"- Missing categories: `{len(missing)}`",
            f"- Copied artifacts: `{len(records)}`",
            f"- Build runtime: `{elapsed_seconds:.3f}` seconds",
            "",
            "## Category coverage",
            "",
            "| Category | Status | Artifacts | Note |",
            "|---|---:|---:|---|",
        ]
        for status in statuses:
            lines.append(
                f"| {status.category} | {status.status} | "
                f"{status.artifact_count} | {status.note} |"
            )
        lines.extend(
            [
                "",
                "## Reproduction controls",
                "",
                "The package contains source-relative paths, SHA-256 checksums,",
                "configuration files, Git state, Python environment information,",
                "and a category-level completeness assessment.",
                "",
                "Missing-category markers are diagnostic only and must not be",
                "treated as substantive model evidence.",
                "",
            ]
        )
        index_path = package_dir / "README.md"
        index_path.write_text("\n".join(lines), encoding="utf-8")
        return index_path

    @staticmethod
    def _zip_directory(package_dir: Path) -> Path:
        archive_path = package_dir.with_suffix(".zip")
        if archive_path.exists():
            archive_path.unlink()
        with zipfile.ZipFile(
            archive_path,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            for path in sorted(package_dir.rglob("*")):
                if path.is_file():
                    archive.write(path, arcname=path.relative_to(package_dir))
        return archive_path

    def _refresh_latest_alias(self, package_dir: Path, archive_path: Path) -> None:
        latest_dir = self.output_root / "latest"
        if latest_dir.exists():
            shutil.rmtree(latest_dir)
        shutil.copytree(package_dir, latest_dir)
        latest_archive = self.output_root / "latest.zip"
        shutil.copy2(archive_path, latest_archive)

    def build(self) -> EvidencePackageResult:
        started_at = time.perf_counter()
        package_id = self._package_id()
        package_dir = self.output_root / package_id
        if package_dir.exists():
            shutil.rmtree(package_dir)
        package_dir.mkdir(parents=True, exist_ok=True)

        runtime_path = self._capture_runtime(package_dir, started_at)
        all_records: list[EvidenceRecord] = []
        statuses: list[CategoryStatus] = []

        for category in self.required_categories:
            patterns = list(self.category_patterns.get(category, []))
            records, status = self._copy_category(
                package_dir=package_dir,
                category=category,
                patterns=patterns,
            )
            all_records.extend(records)
            statuses.append(status)

        runtime_destination = (
            package_dir
            / "runtime_environment"
            / "generated"
            / runtime_path.name
        )
        runtime_destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(runtime_path, runtime_destination)
        stat = runtime_destination.stat()
        all_records.append(
            EvidenceRecord(
                category="runtime_environment",
                source_relative_path="GENERATED_DURING_BUILD",
                package_relative_path=runtime_destination.relative_to(
                    package_dir
                ).as_posix(),
                sha256=self._sha256(runtime_destination),
                size_bytes=stat.st_size,
                modified_utc=datetime.fromtimestamp(stat.st_mtime, tz=UTC).isoformat(),
            )
        )
        runtime_marker = (
            package_dir / "runtime_environment" / "MISSING_EVIDENCE.md"
        )
        if runtime_marker.exists():
            runtime_marker.unlink()
        statuses = [
            CategoryStatus(
                category=status.category,
                status="AVAILABLE",
                artifact_count=status.artifact_count + 1,
                note="Runtime and environment evidence generated during build.",
            )
            if status.category == "runtime_environment"
            else status
            for status in statuses
        ]

        manifest_path = self._write_manifest(package_dir, all_records)
        self._write_status(package_dir, statuses)
        elapsed_seconds = time.perf_counter() - started_at
        index_path = self._write_index(
            package_dir=package_dir,
            package_id=package_id,
            records=all_records,
            statuses=statuses,
            elapsed_seconds=elapsed_seconds,
        )
        archive_path = self._zip_directory(package_dir)
        self._refresh_latest_alias(package_dir, archive_path)

        missing = tuple(
            status.category for status in statuses if status.status == "MISSING"
        )
        if self.strict and missing:
            joined = ", ".join(missing)
            raise RuntimeError(f"Missing required evidence categories: {joined}")

        return EvidencePackageResult(
            package_directory=str(package_dir),
            archive_path=str(archive_path),
            manifest_path=str(manifest_path),
            index_path=str(index_path),
            package_id=package_id,
            artifact_count=len(all_records),
            missing_categories=missing,
            elapsed_seconds=elapsed_seconds,
        )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build the Phase IX Section 32 reproducible evidence package."
    )
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--config", type=Path, default=None)
    parser.add_argument("--output-root", type=Path, default=None)
    parser.add_argument("--strict", action="store_true")
    return parser


def main() -> int:
    args = _build_parser().parse_args()
    builder = EvidencePackageBuilder(
        repo_root=args.repo_root,
        config_path=args.config,
        output_root=args.output_root,
        strict=args.strict,
    )
    result = builder.build()
    print(json.dumps(asdict(result), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
