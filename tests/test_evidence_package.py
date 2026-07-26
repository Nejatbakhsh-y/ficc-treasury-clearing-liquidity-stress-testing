from __future__ import annotations

import csv
import json
import zipfile
from pathlib import Path

from ficc_liquidity.reporting.evidence_package import EvidencePackageBuilder


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def test_build_creates_manifest_archive_and_runtime_evidence(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _write(repo / "reports" / "data_quality_results.csv", "metric,status\nrows,PASS\n")
    _write(repo / "reports" / "scenario_results.csv", "scenario,lcr\nbase,1.25\n")
    _write(repo / "reports" / "cover_1_results.csv", "member,need\nM001,100\n")
    _write(repo / "reports" / "cover_2_results.csv", "members,need\nM001+M002,180\n")
    _write(repo / "reports" / "lcr_results.csv", "scenario,lcr\nbase,1.25\n")
    _write(repo / "reports" / "liquidity_shortfalls.csv", "scenario,shortfall\nbase,0\n")
    _write(
        repo / "reports" / "component_contributions.csv",
        "component,value\nsettlement,75\n",
    )
    _write(repo / "reports" / "sensitivity_results.csv", "parameter,lcr\nyield,1.1\n")
    _write(
        repo / "reports" / "reverse_stress_results.csv",
        "driver,threshold\nyield,0.02\n",
    )
    _write(repo / "reports" / "monitoring_results.csv", "metric,status\nlcr,GREEN\n")
    _write(
        repo / "reports" / "validation_finding_register.csv",
        "finding_id,status\nF-001,OPEN\n",
    )
    _write(repo / "configs" / "project.yaml", "random_seed: 2026\n")

    builder = EvidencePackageBuilder(
        repo_root=repo,
        output_root=repo / "reports" / "evidence_packages",
    )
    result = builder.build()

    package_dir = Path(result.package_directory)
    manifest_path = Path(result.manifest_path)
    archive_path = Path(result.archive_path)

    assert package_dir.exists()
    assert manifest_path.exists()
    assert archive_path.exists()
    assert (package_dir / "runtime_environment" / "runtime_environment.json").exists()
    assert result.missing_categories == ()

    with manifest_path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert rows
    assert all(len(row["sha256"]) == 64 for row in rows)

    with zipfile.ZipFile(archive_path) as archive:
        names = set(archive.namelist())
    assert "evidence_manifest.csv" in names
    assert "category_status.json" in names


def test_missing_category_is_reported_without_strict_failure(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _write(repo / "configs" / "project.yaml", "random_seed: 2026\n")

    builder = EvidencePackageBuilder(
        repo_root=repo,
        output_root=repo / "reports" / "evidence_packages",
    )
    result = builder.build()

    assert "scenario_results" in result.missing_categories
    status_path = Path(result.package_directory) / "category_status.json"
    statuses = json.loads(status_path.read_text(encoding="utf-8"))
    scenario_status = next(
        item for item in statuses if item["category"] == "scenario_results"
    )
    assert scenario_status["status"] == "MISSING"
    marker = (
        Path(result.package_directory)
        / "scenario_results"
        / "MISSING_EVIDENCE.md"
    )
    assert marker.exists()
