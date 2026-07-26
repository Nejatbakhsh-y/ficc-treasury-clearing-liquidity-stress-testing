from __future__ import annotations

import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports" / "independent_validation_report.md"
EVIDENCE_CSV = ROOT / "reports" / "validation" / "section34_evidence_index.csv"
EVIDENCE_MD = ROOT / "reports" / "validation" / "section34_evidence_index.md"
READINESS_CSV = ROOT / "reports" / "validation" / "section34_report_readiness.csv"
CHECKLIST = ROOT / "reports" / "validation" / "section34_completion_checklist.md"
MANIFEST = ROOT / "reports" / "validation" / "section34_report_manifest.json"

REQUIRED_HEADINGS = [
    "## 1. Executive summary",
    "## 2. Model purpose and intended use",
    "## 3. Scope",
    "## 4. Data sources",
    "## 5. Synthetic portfolio methodology",
    "## 6. Model methodology",
    "## 7. Scenario framework",
    "## 8. Conceptual soundness",
    "## 9. Data validation",
    "## 10. Implementation verification",
    "## 11. Sensitivity analysis",
    "## 12. Outcomes analysis",
    "## 13. Reverse stress",
    "## 14. Limitations",
    "## 15. Findings",
    "## 16. Validation conclusion",
    "## 17. Recommendations",
    "## 18. Appendices and evidence index",
]


def test_section34_required_files_exist() -> None:
    for path in [
        REPORT,
        EVIDENCE_CSV,
        EVIDENCE_MD,
        READINESS_CSV,
        CHECKLIST,
        MANIFEST,
    ]:
        assert path.is_file(), f"Missing Section 34 artifact: {path}"


def test_independent_validation_report_has_all_required_sections() -> None:
    text = REPORT.read_text(encoding="utf-8")
    missing = [heading for heading in REQUIRED_HEADINGS if heading not in text]
    assert not missing, f"Missing required report headings: {missing}"
    assert not re.search(r"\b(?:TODO|TBD|FILL[_ -]?ME)\b", text, re.IGNORECASE)


def test_evidence_index_is_controlled_and_hashed() -> None:
    with EVIDENCE_CSV.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    assert rows, "Evidence index must contain at least one evidence record."
    required_columns = {
        "EvidenceId",
        "Category",
        "Path",
        "Extension",
        "SizeBytes",
        "ModifiedUtc",
        "Sha256",
        "Description",
    }
    assert required_columns.issubset(rows[0])
    assert len({row["EvidenceId"] for row in rows}) == len(rows)
    assert all(re.fullmatch(r"EV-\d{4}", row["EvidenceId"]) for row in rows)
    assert all(re.fullmatch(r"[0-9a-f]{64}", row["Sha256"]) for row in rows)
    assert all(not Path(row["Path"]).is_absolute() for row in rows)


def test_readiness_control_is_complete() -> None:
    with READINESS_CSV.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    assert len(rows) == 13
    assert {row["Status"] for row in rows}.issubset({"PASS", "FAIL"})
    assert all(row["ControlObjective"].strip() for row in rows)


def test_report_manifest_is_valid() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert manifest["section"] == 34
    assert manifest["phase"] == 9
    assert manifest["branch"] == "docs/22-final-validation-report"
    assert manifest["evidence_count"] > 0
    assert manifest["validation_conclusion"]
    assert manifest["outputs"]
