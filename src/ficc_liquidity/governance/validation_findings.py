"""Controlled validation finding register for Section 31."""

from __future__ import annotations

import json
import re
from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

import yaml


class FindingRegisterValidationError(ValueError):
    """Raised when a finding register violates a controlled requirement."""


@dataclass(frozen=True)
class FindingIssue:
    """One validation issue identified in the register."""

    level: str
    code: str
    finding_id: str
    message: str


@dataclass(frozen=True)
class FindingRegisterSummary:
    """Run-level summary for the validation finding register."""

    as_of_date: str
    total_findings: int
    active_findings: int
    closed_findings: int
    risk_accepted_findings: int
    overdue_findings: int
    due_soon_findings: int
    highest_open_classification: str | None
    error_count: int
    warning_count: int
    classification_counts: dict[str, int]
    status_counts: dict[str, int]


class ValidationFindingRegister:
    """Validate, summarize, and report controlled model-validation findings."""

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.config = dict(config["validation_findings"])
        self.required_fields = tuple(self.config["required_fields"])
        self.classifications = dict(self.config["classifications"])
        self.statuses = tuple(self.config["statuses"])
        self.active_statuses = tuple(self.config["active_statuses"])
        self.terminal_statuses = tuple(self.config["terminal_statuses"])
        self.id_pattern = re.compile(str(self.config["finding_id"]["pattern"]))
        self.id_prefix = str(self.config["finding_id"]["prefix"])
        self.sequence_width = int(self.config["finding_id"]["sequence_width"])
        self.date_format = str(self.config["date_format"])
        self.due_soon_days = int(self.config["due_soon_calendar_days"])
        closure = dict(self.config["closure"])
        self.closure_required_for = tuple(closure["closure_evidence_required_for"])
        self.prohibited_placeholders = {
            str(value).strip().lower() for value in closure["prohibited_placeholders"]
        }

    @classmethod
    def from_yaml(cls, path: str | Path) -> ValidationFindingRegister:
        """Create a register controller from the controlled YAML configuration."""

        with Path(path).open("r", encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
        return cls(config)

    def load_csv(self, path: str | Path) -> list[dict[str, str]]:
        """Load the controlled CSV register using only standard-library parsing."""

        import csv

        with Path(path).open("r", encoding="utf-8-sig", newline="") as stream:
            reader = csv.DictReader(stream)
            return [
                {str(key): "" if value is None else str(value) for key, value in row.items()}
                for row in reader
            ]

    def write_csv(self, rows: Sequence[Mapping[str, Any]], path: str | Path) -> Path:
        """Write rows in the exact controlled field order."""

        import csv

        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(self.required_fields))
            writer.writeheader()
            for row in rows:
                writer.writerow(
                    {field: self._text(row.get(field, "")) for field in self.required_fields}
                )
        return destination

    def validate(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        as_of_date: str | date,
        raise_on_error: bool = False,
    ) -> list[FindingIssue]:
        """Validate structure, classifications, dates, status, and closure controls."""

        resolved_as_of = self._parse_date(as_of_date, "as_of_date", "")
        issues: list[FindingIssue] = []
        seen_ids: set[str] = set()

        if not rows:
            issues.append(
                FindingIssue(
                    level="WARNING",
                    code="EMPTY_REGISTER",
                    finding_id="",
                    message="The validation finding register contains no findings.",
                )
            )

        for index, source_row in enumerate(rows, start=2):
            row = {str(key): self._text(value) for key, value in source_row.items()}
            finding_id = row.get("finding_id", "").strip() or f"ROW-{index}"

            missing_columns = [field for field in self.required_fields if field not in source_row]
            if missing_columns:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="MISSING_COLUMNS",
                        finding_id=finding_id,
                        message="Missing required columns: " + ", ".join(missing_columns),
                    )
                )
                continue

            blank_fields = [
                field for field in self.required_fields if not row.get(field, "").strip()
            ]
            if blank_fields:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="BLANK_REQUIRED_FIELDS",
                        finding_id=finding_id,
                        message="Blank required fields: " + ", ".join(blank_fields),
                    )
                )

            if not self.id_pattern.fullmatch(row["finding_id"].strip()):
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="INVALID_FINDING_ID",
                        finding_id=finding_id,
                        message=(
                            "Finding ID does not match the controlled pattern "
                            f"{self.id_pattern.pattern}."
                        ),
                    )
                )

            if row["finding_id"] in seen_ids:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="DUPLICATE_FINDING_ID",
                        finding_id=finding_id,
                        message="Finding ID must be unique.",
                    )
                )
            seen_ids.add(row["finding_id"])

            category = row["category"].strip()
            status = row["status"].strip()

            if category not in self.classifications:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="INVALID_CATEGORY",
                        finding_id=finding_id,
                        message=f"Unknown finding classification: {category}.",
                    )
                )

            if status not in self.statuses:
                issues.append(
                    FindingIssue(
                        level="ERROR",
                        code="INVALID_STATUS",
                        finding_id=finding_id,
                        message=f"Unknown finding status: {status}.",
                    )
                )

            target_date = self._try_parse_date(
                row["target_date"].strip(),
                "target_date",
                finding_id,
                issues,
            )

            if target_date is not None and status in self.active_statuses:
                if target_date < resolved_as_of and status != "Overdue":
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="OVERDUE_STATUS_REQUIRED",
                            finding_id=finding_id,
                            message=(
                                f"Target date {target_date.isoformat()} is before "
                                f"{resolved_as_of.isoformat()}; status must be Overdue."
                            ),
                        )
                    )
                if target_date >= resolved_as_of and status == "Overdue":
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="PREMATURE_OVERDUE_STATUS",
                            finding_id=finding_id,
                            message=(
                                f"Target date {target_date.isoformat()} has not passed; "
                                "status cannot be Overdue."
                            ),
                        )
                    )

            if status == "Risk Accepted" and category in self.classifications:
                risk_acceptance_allowed = bool(
                    self.classifications[category]["risk_acceptance_allowed"]
                )
                if not risk_acceptance_allowed:
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="RISK_ACCEPTANCE_PROHIBITED",
                            finding_id=finding_id,
                            message=(
                                f"{category} findings cannot be closed through risk acceptance."
                            ),
                        )
                    )

            closure_evidence = row["closure_evidence"].strip()
            if status in self.closure_required_for:
                normalized_evidence = closure_evidence.lower()
                if normalized_evidence in self.prohibited_placeholders:
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="INSUFFICIENT_CLOSURE_EVIDENCE",
                            finding_id=finding_id,
                            message=(
                                f"Status {status} requires substantive independent "
                                "closure or risk-acceptance evidence."
                            ),
                        )
                    )
                elif len(closure_evidence) < 25:
                    issues.append(
                        FindingIssue(
                            level="ERROR",
                            code="CLOSURE_EVIDENCE_TOO_SHORT",
                            finding_id=finding_id,
                            message=(
                                "Closure evidence must identify the decision, "
                                "review, and supporting evidence."
                            ),
                        )
                    )

            if status == "Closed" and "independent" not in closure_evidence.lower():
                issues.append(
                    FindingIssue(
                        level="WARNING",
                        code="INDEPENDENCE_NOT_EXPLICIT",
                        finding_id=finding_id,
                        message=(
                            "Closed finding evidence should explicitly identify "
                            "independent validation review."
                        ),
                    )
                )

        if raise_on_error:
            errors = [issue for issue in issues if issue.level == "ERROR"]
            if errors:
                detail = "\n".join(
                    f"{issue.finding_id}: {issue.code}: {issue.message}" for issue in errors
                )
                raise FindingRegisterValidationError(
                    "Validation finding register failed controlled validation:\n" + detail
                )

        return issues

    def summarize(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        as_of_date: str | date,
        issues: Sequence[FindingIssue] | None = None,
    ) -> FindingRegisterSummary:
        """Produce classification, status, aging, and validation summaries."""

        resolved_as_of = self._parse_date(as_of_date, "as_of_date", "")
        resolved_issues = list(issues or [])
        classification_counts = Counter(self._text(row.get("category", "")).strip() for row in rows)
        status_counts = Counter(self._text(row.get("status", "")).strip() for row in rows)

        active = [
            row for row in rows if self._text(row.get("status", "")).strip() in self.active_statuses
        ]
        overdue_count = 0
        due_soon_count = 0

        for row in active:
            target_value = self._text(row.get("target_date", "")).strip()
            try:
                target = datetime.strptime(target_value, self.date_format).date()
            except ValueError:
                continue
            if target < resolved_as_of:
                overdue_count += 1
            elif target <= resolved_as_of + timedelta(days=self.due_soon_days):
                due_soon_count += 1

        open_categories = [
            self._text(row.get("category", "")).strip()
            for row in active
            if self._text(row.get("category", "")).strip() in self.classifications
        ]
        highest = None
        if open_categories:
            highest = max(
                open_categories,
                key=lambda value: int(self.classifications[value]["rank"]),
            )

        return FindingRegisterSummary(
            as_of_date=resolved_as_of.isoformat(),
            total_findings=len(rows),
            active_findings=len(active),
            closed_findings=int(status_counts.get("Closed", 0)),
            risk_accepted_findings=int(status_counts.get("Risk Accepted", 0)),
            overdue_findings=overdue_count,
            due_soon_findings=due_soon_count,
            highest_open_classification=highest,
            error_count=sum(issue.level == "ERROR" for issue in resolved_issues),
            warning_count=sum(issue.level == "WARNING" for issue in resolved_issues),
            classification_counts=dict(
                sorted(
                    classification_counts.items(),
                    key=lambda item: int(self.classifications.get(item[0], {"rank": 0})["rank"]),
                    reverse=True,
                )
            ),
            status_counts=dict(sorted(status_counts.items())),
        )

    def next_finding_id(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        year: int | None = None,
    ) -> str:
        """Return the next deterministic finding ID for the requested year."""

        resolved_year = year or date.today().year
        prefix = f"{self.id_prefix}-{resolved_year}-"
        sequences: list[int] = []
        for row in rows:
            finding_id = self._text(row.get("finding_id", "")).strip()
            if finding_id.startswith(prefix) and self.id_pattern.fullmatch(finding_id):
                sequences.append(int(finding_id.rsplit("-", 1)[1]))
        next_sequence = max(sequences, default=0) + 1
        return f"{prefix}{next_sequence:0{self.sequence_width}d}"

    def write_outputs(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        output_dir: str | Path,
        as_of_date: str | date,
        issues: Sequence[FindingIssue],
    ) -> dict[str, Path]:
        """Write the controlled CSV, JSON summary, issue log, and Markdown report."""

        destination = Path(output_dir)
        destination.mkdir(parents=True, exist_ok=True)
        summary = self.summarize(rows, as_of_date=as_of_date, issues=issues)
        stamp = summary.as_of_date.replace("-", "")

        register_path = destination / f"validation_finding_register_{stamp}.csv"
        summary_path = destination / f"validation_finding_summary_{stamp}.json"
        issue_path = destination / f"validation_finding_issues_{stamp}.json"
        report_path = destination / f"validation_finding_report_{stamp}.md"

        self.write_csv(rows, register_path)
        summary_path.write_text(
            json.dumps(asdict(summary), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        issue_path.write_text(
            json.dumps([asdict(issue) for issue in issues], indent=2, sort_keys=True),
            encoding="utf-8",
        )
        report_path.write_text(
            self.render_markdown(rows, summary=summary, issues=issues),
            encoding="utf-8",
        )

        return {
            "register": register_path,
            "summary": summary_path,
            "issues": issue_path,
            "report": report_path,
        }

    def render_markdown(
        self,
        rows: Sequence[Mapping[str, Any]],
        *,
        summary: FindingRegisterSummary,
        issues: Sequence[FindingIssue],
    ) -> str:
        """Render the management and validation review report."""

        lines = [
            "# Section 31 â€” Validation Finding Register",
            "",
            f"**As-of date:** {summary.as_of_date}",
            "",
            "## Executive summary",
            "",
            f"- Total findings: {summary.total_findings}",
            f"- Active findings: {summary.active_findings}",
            f"- Closed findings: {summary.closed_findings}",
            f"- Risk-accepted findings: {summary.risk_accepted_findings}",
            f"- Overdue findings: {summary.overdue_findings}",
            f"- Due within {self.due_soon_days} days: {summary.due_soon_findings}",
            (f"- Highest open classification: {summary.highest_open_classification or 'None'}"),
            f"- Validation errors: {summary.error_count}",
            f"- Validation warnings: {summary.warning_count}",
            "",
            "## Classification summary",
            "",
            "| Classification | Count |",
            "|---|---:|",
        ]
        for classification in self.classifications:
            lines.append(
                f"| {classification} | {summary.classification_counts.get(classification, 0)} |"
            )

        lines.extend(
            [
                "",
                "## Status summary",
                "",
                "| Status | Count |",
                "|---|---:|",
            ]
        )
        for status in self.statuses:
            lines.append(f"| {status} | {summary.status_counts.get(status, 0)} |")

        lines.extend(
            [
                "",
                "## Finding register",
                "",
                "| Finding ID | Classification | Condition | Owner | Target date | Status |",
                "|---|---|---|---|---|---|",
            ]
        )
        for row in rows:
            condition = self._text(row.get("condition", "")).replace("|", "/")
            if len(condition) > 90:
                condition = condition[:87] + "..."
            lines.append(
                "| {finding_id} | {category} | {condition} | {owner} | "
                "{target_date} | {status} |".format(
                    finding_id=self._text(row.get("finding_id", "")),
                    category=self._text(row.get("category", "")),
                    condition=condition,
                    owner=self._text(row.get("owner", "")).replace("|", "/"),
                    target_date=self._text(row.get("target_date", "")),
                    status=self._text(row.get("status", "")),
                )
            )

        lines.extend(["", "## Validation issues", ""])
        if issues:
            lines.extend(
                [
                    "| Level | Code | Finding ID | Message |",
                    "|---|---|---|---|",
                ]
            )
            for issue in issues:
                lines.append(
                    f"| {issue.level} | {issue.code} | {issue.finding_id} | "
                    f"{issue.message.replace('|', '/')} |"
                )
        else:
            lines.append("No controlled validation issues were identified.")

        lines.extend(
            [
                "",
                "## Closure control",
                "",
                (
                    "A finding is not closed solely because management reports that remediation "
                    "is complete. Closed status requires substantive closure evidence and "
                    "independent validation review. Critical and High findings cannot be "
                    "disposed through risk acceptance."
                ),
                "",
                (
                    "All demonstration findings are synthetic project-governance examples. "
                    "They are not actual FICC, DTCC, clearing-member, or participant findings."
                ),
                "",
            ]
        )
        return "\n".join(lines)

    def _try_parse_date(
        self,
        value: str,
        field_name: str,
        finding_id: str,
        issues: list[FindingIssue],
    ) -> date | None:
        try:
            return datetime.strptime(value, self.date_format).date()
        except ValueError:
            issues.append(
                FindingIssue(
                    level="ERROR",
                    code="INVALID_DATE",
                    finding_id=finding_id,
                    message=(
                        f"{field_name} must use the controlled format "
                        f"{self.date_format}: {value!r}."
                    ),
                )
            )
            return None

    def _parse_date(
        self,
        value: str | date,
        field_name: str,
        finding_id: str,
    ) -> date:
        if isinstance(value, date):
            return value
        try:
            return datetime.strptime(str(value), self.date_format).date()
        except ValueError as exc:
            raise FindingRegisterValidationError(
                f"{field_name} must use {self.date_format}: {value!r}."
            ) from exc

    @staticmethod
    def _text(value: Any) -> str:
        return "" if value is None else str(value)


def build_demo_rows() -> list[dict[str, str]]:
    """Return deterministic synthetic Section 31 demonstration findings."""

    return [
        {
            "finding_id": "FICC-LST-2026-001",
            "category": "Critical",
            "condition": (
                "Independent reconciliation differs from the production-equivalent "
                "integrated stressed liquidity requirement."
            ),
            "evidence": "Section 25 reconciliation output and line-item calculation trace.",
            "risk": "Reported LCR and liquidity shortfall may be materially misstated.",
            "recommendation": (
                "Reconcile formulas, units, aggregation, and rounding; correct the "
                "implementation and rerun affected scenarios."
            ),
            "management_response": (
                "Management accepted immediate remediation and restricted reliance "
                "on unreconciled outputs."
            ),
            "owner": "Model Development Owner",
            "target_date": "2026-07-30",
            "status": "Remediation in Progress",
            "closure_evidence": "Not applicable until closure",
        },
        {
            "finding_id": "FICC-LST-2026-002",
            "category": "High",
            "condition": (
                "Available-resource eligibility is not consistently applied across "
                "all scenario paths."
            ),
            "evidence": (
                "Section 24 resource-eligibility challenge and scenario comparison evidence."
            ),
            "risk": "Ineligible resources may overstate liquidity capacity.",
            "recommendation": (
                "Centralize eligibility rules, add negative tests, and independently "
                "verify resource timing and encumbrance."
            ),
            "management_response": (
                "Management implemented the eligibility control and submitted evidence "
                "for independent review."
            ),
            "owner": "Liquidity Risk Owner",
            "target_date": "2026-08-10",
            "status": "Pending Validation Review",
            "closure_evidence": "Not applicable until closure",
        },
        {
            "finding_id": "FICC-LST-2026-003",
            "category": "Medium",
            "condition": (
                "Scenario rank ordering changes under selected parameter combinations "
                "without sufficient economic explanation."
            ),
            "evidence": "Section 27 benchmark and rank-stability analysis.",
            "risk": "Unexpected ordering may impair scenario interpretation and governance.",
            "recommendation": (
                "Document economic drivers, compare deterministic benchmarks, and "
                "define acceptable rank-stability tolerances."
            ),
            "management_response": (
                "Management assigned the scenario governance owner and initiated "
                "the required benchmark analysis."
            ),
            "owner": "Scenario Governance Owner",
            "target_date": "2026-09-01",
            "status": "Open",
            "closure_evidence": "Not applicable until closure",
        },
        {
            "finding_id": "FICC-LST-2026-004",
            "category": "Low",
            "condition": (
                "Monthly monitoring documentation did not initially identify all "
                "retained evidence files."
            ),
            "evidence": "Section 29 documentation review and controlled-output inventory.",
            "risk": "Incomplete evidence references could reduce auditability.",
            "recommendation": (
                "Update the operating procedure and evidence inventory, then verify "
                "all required artifacts are retained."
            ),
            "management_response": (
                "Management updated the operating procedure and evidence index."
            ),
            "owner": "Model Monitoring Owner",
            "target_date": "2026-07-15",
            "status": "Closed",
            "closure_evidence": (
                "Independent validator reviewed the revised documentation, confirmed "
                "the complete evidence inventory, and approved closure on 2026-07-18."
            ),
        },
        {
            "finding_id": "FICC-LST-2026-005",
            "category": "Observation",
            "condition": (
                "The demonstration register uses synthetic examples rather than "
                "actual FICC findings."
            ),
            "evidence": ("Repository data-classification review and synthetic-data labeling."),
            "risk": (
                "A reader could incorrectly interpret demonstration findings as "
                "confidential participant or DTCC outcomes."
            ),
            "recommendation": (
                "Retain explicit synthetic-data disclaimers in the register, reports, "
                "and project documentation."
            ),
            "management_response": (
                "Management formally accepted the residual presentation risk subject "
                "to continued synthetic-data labeling."
            ),
            "owner": "Model Risk Governance Owner",
            "target_date": "2026-07-20",
            "status": "Risk Accepted",
            "closure_evidence": (
                "Documented risk acceptance approved by Model Risk Governance on "
                "2026-07-20; synthetic-data disclaimers remain mandatory."
            ),
        },
    ]
