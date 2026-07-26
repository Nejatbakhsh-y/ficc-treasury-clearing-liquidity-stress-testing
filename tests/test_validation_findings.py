"""Tests for the Section 31 validation finding register."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ficc_liquidity.governance.validation_findings import (
    FindingRegisterValidationError,
    ValidationFindingRegister,
    build_demo_rows,
)

CONFIG = Path("configs/validation_findings.yaml")
AS_OF_DATE = "2026-07-25"


def controller() -> ValidationFindingRegister:
    return ValidationFindingRegister.from_yaml(CONFIG)


def test_demo_register_passes_controlled_validation() -> None:
    register = controller()
    rows = build_demo_rows()

    issues = register.validate(
        rows,
        as_of_date=AS_OF_DATE,
        raise_on_error=True,
    )
    summary = register.summarize(
        rows,
        as_of_date=AS_OF_DATE,
        issues=issues,
    )

    assert summary.total_findings == 5
    assert summary.active_findings == 3
    assert summary.closed_findings == 1
    assert summary.risk_accepted_findings == 1
    assert summary.overdue_findings == 0
    assert summary.highest_open_classification == "Critical"
    assert summary.error_count == 0


def test_duplicate_finding_id_is_rejected() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[1]["finding_id"] = rows[0]["finding_id"]

    with pytest.raises(FindingRegisterValidationError, match="DUPLICATE_FINDING_ID"):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_unknown_classification_is_rejected() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[0]["category"] = "Severe"

    with pytest.raises(FindingRegisterValidationError, match="INVALID_CATEGORY"):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_closed_finding_requires_substantive_closure_evidence() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[3]["closure_evidence"] = "Pending"

    with pytest.raises(
        FindingRegisterValidationError,
        match="INSUFFICIENT_CLOSURE_EVIDENCE",
    ):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_critical_finding_cannot_be_risk_accepted() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[0]["status"] = "Risk Accepted"
    rows[0]["closure_evidence"] = (
        "Management documented risk acceptance, but the classification prohibits it."
    )

    with pytest.raises(
        FindingRegisterValidationError,
        match="RISK_ACCEPTANCE_PROHIBITED",
    ):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_expired_active_target_requires_overdue_status() -> None:
    register = controller()
    rows = build_demo_rows()
    rows[2]["target_date"] = "2026-07-01"

    with pytest.raises(
        FindingRegisterValidationError,
        match="OVERDUE_STATUS_REQUIRED",
    ):
        register.validate(rows, as_of_date=AS_OF_DATE, raise_on_error=True)


def test_next_finding_id_increments_existing_year_sequence() -> None:
    register = controller()
    rows = build_demo_rows()

    assert register.next_finding_id(rows, year=2026) == "FICC-LST-2026-006"
    assert register.next_finding_id(rows, year=2027) == "FICC-LST-2027-001"


def test_outputs_include_register_summary_issues_and_report(tmp_path: Path) -> None:
    register = controller()
    rows = build_demo_rows()
    issues = register.validate(rows, as_of_date=AS_OF_DATE)

    outputs = register.write_outputs(
        rows,
        output_dir=tmp_path,
        as_of_date=AS_OF_DATE,
        issues=issues,
    )

    assert set(outputs) == {"register", "summary", "issues", "report"}
    assert all(path.exists() for path in outputs.values())

    summary = json.loads(outputs["summary"].read_text(encoding="utf-8"))
    assert summary["total_findings"] == 5
    assert summary["highest_open_classification"] == "Critical"

    report = outputs["report"].read_text(encoding="utf-8")
    assert "Validation Finding Register" in report
    assert "FICC-LST-2026-001" in report
    assert "synthetic project-governance examples" in report
