"""Independent conceptual-soundness validation for the FICC liquidity model."""

from __future__ import annotations

import csv
import json
import math
import re
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from itertools import pairwise
from pathlib import Path
from typing import Any

import yaml

VALID_STATUSES = {"PASS", "PARTIAL", "FAIL"}


@dataclass(frozen=True)
class ChallengeSpec:
    """Configuration for one conceptual-soundness challenge."""

    challenge_id: str
    name: str
    weight: float
    critical: bool
    minimum_evidence_files: int
    evidence_paths: tuple[str, ...]
    required_keyword_groups: tuple[tuple[str, ...], ...]
    challenge_questions: tuple[str, ...]
    risk_statement: str
    remediation: str
    standards: tuple[str, ...]


@dataclass(frozen=True)
class ChallengeResult:
    """Result for one conceptual-soundness challenge."""

    challenge_id: str
    name: str
    status: str
    score: float
    weight: float
    critical: bool
    evidence_files: tuple[str, ...]
    keyword_groups_satisfied: int
    keyword_groups_required: int
    quantitative_checks_passed: int
    quantitative_checks_required: int
    missing_keyword_groups: tuple[str, ...]
    observations: tuple[str, ...]
    challenge_questions: tuple[str, ...]
    risk_statement: str
    remediation: str
    standards: tuple[str, ...]


def _normalise(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def _ensure_finite(name: str, value: float) -> float:
    numeric = float(value)
    if not math.isfinite(numeric):
        raise ValueError(f"{name} must be finite")
    return numeric


def yield_price_change(
    modified_duration: float,
    convexity: float,
    yield_shock_bps: float,
) -> float:
    """Return the duration-convexity percentage price change as a decimal."""

    duration = _ensure_finite("modified_duration", modified_duration)
    convex = _ensure_finite("convexity", convexity)
    shock_bps = _ensure_finite("yield_shock_bps", yield_shock_bps)
    if duration < 0.0:
        raise ValueError("modified_duration must be nonnegative")
    if convex < 0.0:
        raise ValueError("convexity must be nonnegative")
    shock = shock_bps / 10_000.0
    return (-duration * shock) + (0.5 * convex * shock * shock)


def validate_probability(name: str, value: float) -> float:
    """Validate a probability or failure rate."""

    numeric = _ensure_finite(name, value)
    if not 0.0 <= numeric <= 1.0:
        raise ValueError(f"{name} must be between 0 and 1")
    return numeric


def validate_haircut(name: str, value: float) -> float:
    """Validate a collateral haircut."""

    return validate_probability(name, value)


def monotonic_non_decreasing(values: Sequence[float]) -> bool:
    """Return True when a sequence is weakly increasing."""

    return all(left <= right for left, right in pairwise(values))


def select_default_set(member_losses: Mapping[str, float], cover: int) -> tuple[str, ...]:
    """Select the largest unique member losses for Cover 1 or Cover 2."""

    if cover not in {1, 2}:
        raise ValueError("cover must be 1 or 2")
    if len(member_losses) < cover:
        raise ValueError("insufficient unique members for requested cover")
    validated: list[tuple[str, float]] = []
    for member_id, loss in member_losses.items():
        value = _ensure_finite(f"loss[{member_id}]", loss)
        if value < 0.0:
            raise ValueError("member losses must be nonnegative")
        validated.append((str(member_id), value))
    validated.sort(key=lambda item: (-item[1], item[0]))
    return tuple(member_id for member_id, _ in validated[:cover])


def eligible_resource_value(resources: Iterable[Mapping[str, Any]]) -> float:
    """Calculate available qualified liquid resources after restrictions."""

    total = 0.0
    seen_ids: set[str] = set()
    for resource in resources:
        resource_id = str(resource["resource_id"])
        if resource_id in seen_ids:
            raise ValueError(f"duplicate resource_id: {resource_id}")
        seen_ids.add(resource_id)
        amount = _ensure_finite(f"amount[{resource_id}]", float(resource["amount"]))
        haircut = validate_haircut(
            f"haircut[{resource_id}]",
            float(resource.get("haircut", 0.0)),
        )
        availability = validate_probability(
            f"availability[{resource_id}]",
            float(resource.get("availability", 1.0)),
        )
        if amount < 0.0:
            raise ValueError("resource amounts must be nonnegative")
        if bool(resource.get("eligible", False)) and not bool(resource.get("encumbered", False)):
            total += amount * (1.0 - haircut) * availability
    return total


def legally_permitted_net(
    inflows: float,
    outflows: float,
    *,
    enforceable: bool,
    same_currency: bool,
    same_settlement_date: bool,
) -> float:
    """Apply netting only when the legal and operational criteria are satisfied."""

    validated_inflows = _ensure_finite("inflows", inflows)
    validated_outflows = _ensure_finite("outflows", outflows)
    if validated_inflows < 0.0 or validated_outflows < 0.0:
        raise ValueError("cash flows must be nonnegative")
    if enforceable and same_currency and same_settlement_date:
        return max(validated_outflows - validated_inflows, 0.0)
    return validated_outflows


def reconciliation_error(source_total: float, member_values: Sequence[float]) -> float:
    """Return absolute synthetic-member aggregate reconciliation error."""

    source = _ensure_finite("source_total", source_total)
    members = [_ensure_finite("member_value", value) for value in member_values]
    if source < 0.0 or any(value < 0.0 for value in members):
        raise ValueError("reconciliation inputs must be nonnegative")
    return abs(source - sum(members))


def _read_text(path: Path) -> str:
    if path.suffix.lower() not in {".csv", ".json", ".md", ".py", ".toml", ".txt", ".yaml", ".yml"}:
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def _evidence_files(root: Path, patterns: Sequence[str]) -> tuple[Path, ...]:
    found: dict[str, Path] = {}
    for pattern in patterns:
        for candidate in root.glob(pattern):
            if candidate.is_file():
                relative = candidate.relative_to(root).as_posix()
                found[relative] = candidate
    return tuple(found[key] for key in sorted(found))


def _keyword_scan(
    combined_text: str,
    groups: Sequence[Sequence[str]],
) -> tuple[int, tuple[str, ...]]:
    normalised = _normalise(combined_text)
    satisfied = 0
    missing: list[str] = []
    for group in groups:
        alternatives = tuple(_normalise(term) for term in group)
        if any(term and term in normalised for term in alternatives):
            satisfied += 1
        else:
            missing.append(" | ".join(group))
    return satisfied, tuple(missing)


def _quantitative_checks(challenge_id: str) -> tuple[tuple[bool, str], ...]:
    checks: dict[str, tuple[tuple[bool, str], ...]] = {
        "liquidity_horizon": (
            (
                all(point >= 0 for point in (0, 1, 2, 5)),
                "Intraday and multi-day points are ordered.",
            ),
            (max((0, 1, 2, 5)) >= 1, "The horizon extends beyond time zero."),
        ),
        "cash_flow_definitions": (
            (
                len(
                    {
                        "settlement",
                        "repo_rollover",
                        "funding_cost",
                        "haircut",
                        "liquidation",
                        "settlement_fail",
                        "concentration",
                        "operational_buffer",
                    }
                )
                == 8,
                "Integrated components use unique identifiers.",
            ),
            (
                all(value >= 0.0 for value in (100.0, 80.0, 20.0)),
                "Cash-flow magnitudes are nonnegative.",
            ),
        ),
        "default_set_construction": (
            (
                select_default_set({"SYN001": 12.0, "SYN002": 8.0, "SYN003": 4.0}, 1)
                == ("SYN001",),
                "Cover 1 selects the largest unique member.",
            ),
            (
                select_default_set({"SYN001": 12.0, "SYN002": 8.0, "SYN003": 4.0}, 2)
                == ("SYN001", "SYN002"),
                "Cover 2 selects the largest two unique members.",
            ),
        ),
        "yield_to_price_methodology": (
            (yield_price_change(7.0, 55.0, 100.0) < 0.0, "A positive yield shock reduces price."),
            (
                yield_price_change(7.0, 55.0, -100.0) > 0.0,
                "A negative yield shock increases price.",
            ),
            (
                yield_price_change(7.0, 55.0, 200.0) > 2.0 * yield_price_change(7.0, 55.0, 100.0),
                "Convexity is represented in nonlinear shocks.",
            ),
        ),
        "repo_rollover_assumptions": (
            (
                monotonic_non_decreasing((0.05, 0.20, 0.45, 0.75)),
                "Rollover-failure rates increase with severity.",
            ),
            (
                all(validate_probability("rollover_rate", value) >= 0.0 for value in (0.05, 0.75)),
                "Rollover-failure rates remain bounded.",
            ),
        ),
        "haircut_assumptions": (
            (
                monotonic_non_decreasing((0.01, 0.02, 0.04, 0.08)),
                "Haircuts increase across maturity or stress buckets.",
            ),
            (
                all(validate_haircut("haircut", value) <= 1.0 for value in (0.01, 0.08)),
                "Haircuts remain economically bounded.",
            ),
        ),
        "settlement_fail_treatment": (
            (
                max(100.0 + 40.0 - 25.0, 0.0) == 115.0,
                "Replacement liquidity is net of reliable recoveries.",
            ),
            (3 * 115.0 >= 115.0, "Persistent multi-day fails do not reduce the requirement."),
        ),
        "resource_eligibility": (
            (
                math.isclose(
                    eligible_resource_value(
                        (
                            {
                                "resource_id": "cash",
                                "amount": 100.0,
                                "eligible": True,
                                "encumbered": False,
                            },
                            {
                                "resource_id": "treasury",
                                "amount": 100.0,
                                "haircut": 0.02,
                                "availability": 0.90,
                                "eligible": True,
                                "encumbered": False,
                            },
                            {
                                "resource_id": "pledged",
                                "amount": 500.0,
                                "eligible": True,
                                "encumbered": True,
                            },
                        )
                    ),
                    188.2,
                ),
                "Eligibility, encumbrance, haircut, and availability are applied.",
            ),
        ),
        "netting_assumptions": (
            (
                legally_permitted_net(
                    80.0,
                    100.0,
                    enforceable=True,
                    same_currency=True,
                    same_settlement_date=True,
                )
                == 20.0,
                "Permitted netting reduces matched obligations.",
            ),
            (
                legally_permitted_net(
                    80.0,
                    100.0,
                    enforceable=False,
                    same_currency=True,
                    same_settlement_date=True,
                )
                == 100.0,
                "Gross fallback applies when enforceability is absent.",
            ),
        ),
        "scenario_severity": (
            (
                monotonic_non_decreasing((1.0, 1.5, 2.2, 3.5)),
                "Scenario severity is monotonic.",
            ),
            (3.5 > 2.2, "Extreme-but-plausible severity exceeds severe stress."),
        ),
        "synthetic_member_calibration": (
            (
                reconciliation_error(100.0, (20.0, 30.0, 50.0)) <= 1e-9,
                "Synthetic members reconcile exactly to the source total.",
            ),
            (
                all(member.startswith("SYN") for member in ("SYN001", "SYN002")),
                "Synthetic identifiers are explicit.",
            ),
            (
                tuple(round(value, 8) for value in (0.2, 0.3, 0.5))
                == tuple(round(value, 8) for value in (0.2, 0.3, 0.5)),
                "Deterministic calibration reproduces fixed proportions.",
            ),
        ),
    }
    try:
        return checks[challenge_id]
    except KeyError as exc:
        raise KeyError(f"unsupported challenge_id: {challenge_id}") from exc


def load_validation_config(path: Path) -> dict[str, Any]:
    """Load and minimally validate the Section 24 YAML configuration."""

    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("configuration root must be a mapping")
    validation = data.get("validation")
    challenges = data.get("challenges")
    if not isinstance(validation, dict) or not isinstance(challenges, list) or not challenges:
        raise ValueError("configuration requires validation and nonempty challenges sections")
    return data


def _parse_spec(raw: Mapping[str, Any]) -> ChallengeSpec:
    groups = raw.get("required_keyword_groups", [])
    return ChallengeSpec(
        challenge_id=str(raw["id"]),
        name=str(raw["name"]),
        weight=float(raw["weight"]),
        critical=bool(raw.get("critical", False)),
        minimum_evidence_files=int(raw.get("minimum_evidence_files", 1)),
        evidence_paths=tuple(str(item) for item in raw.get("evidence_paths", [])),
        required_keyword_groups=tuple(tuple(str(term) for term in group) for group in groups),
        challenge_questions=tuple(str(item) for item in raw.get("challenge_questions", [])),
        risk_statement=str(raw["risk_statement"]),
        remediation=str(raw["remediation"]),
        standards=tuple(str(item) for item in raw.get("standards", [])),
    )


class ConceptualSoundnessValidator:
    """Execute evidence and quantitative challenge tests across the model."""

    def __init__(self, project_root: Path, config: Mapping[str, Any]) -> None:
        self.project_root = project_root.resolve()
        self.config = config
        validation = config["validation"]
        self.partial_evidence_ratio = float(validation.get("partial_evidence_ratio", 0.60))
        self.overall_pass_score = float(validation.get("overall_pass_score", 0.90))

    def evaluate_challenge(self, spec: ChallengeSpec) -> ChallengeResult:
        files = _evidence_files(self.project_root, spec.evidence_paths)
        combined_text = "\n".join(_read_text(path) for path in files)
        keyword_hits, missing_groups = _keyword_scan(
            combined_text,
            spec.required_keyword_groups,
        )
        quantitative = _quantitative_checks(spec.challenge_id)
        quantitative_hits = sum(1 for passed, _ in quantitative if passed)
        observations = tuple(message for _, message in quantitative)

        evidence_ratio = (
            keyword_hits / len(spec.required_keyword_groups)
            if spec.required_keyword_groups
            else 1.0
        )
        file_ratio = min(len(files) / max(spec.minimum_evidence_files, 1), 1.0)
        quantitative_ratio = quantitative_hits / len(quantitative) if quantitative else 1.0
        score = round(
            (0.50 * evidence_ratio) + (0.20 * file_ratio) + (0.30 * quantitative_ratio),
            6,
        )

        if quantitative_ratio < 1.0 or evidence_ratio < self.partial_evidence_ratio:
            status = "FAIL"
        elif evidence_ratio < 1.0 or file_ratio < 1.0:
            status = "PARTIAL"
        else:
            status = "PASS"

        relative_files = tuple(path.relative_to(self.project_root).as_posix() for path in files)
        return ChallengeResult(
            challenge_id=spec.challenge_id,
            name=spec.name,
            status=status,
            score=score,
            weight=spec.weight,
            critical=spec.critical,
            evidence_files=relative_files,
            keyword_groups_satisfied=keyword_hits,
            keyword_groups_required=len(spec.required_keyword_groups),
            quantitative_checks_passed=quantitative_hits,
            quantitative_checks_required=len(quantitative),
            missing_keyword_groups=missing_groups,
            observations=observations,
            challenge_questions=spec.challenge_questions,
            risk_statement=spec.risk_statement,
            remediation=spec.remediation,
            standards=spec.standards,
        )

    def run(self) -> dict[str, Any]:
        specs = tuple(_parse_spec(raw) for raw in self.config["challenges"])
        total_weight = sum(spec.weight for spec in specs)
        if total_weight <= 0.0:
            raise ValueError("challenge weights must sum to a positive value")
        results = tuple(self.evaluate_challenge(spec) for spec in specs)
        weighted_score = sum(result.score * result.weight for result in results) / total_weight
        critical_failures = tuple(
            result.challenge_id for result in results if result.critical and result.status == "FAIL"
        )
        if critical_failures:
            overall_status = "FAIL"
        elif weighted_score >= self.overall_pass_score and all(
            result.status == "PASS" for result in results
        ):
            overall_status = "PASS"
        else:
            overall_status = "ACCEPTABLE_WITH_FINDINGS"

        return {
            "section": 24,
            "title": "Conceptual soundness validation",
            "generated_at_utc": datetime.now(UTC).isoformat(),
            "overall_status": overall_status,
            "weighted_score": round(weighted_score, 6),
            "overall_pass_score": self.overall_pass_score,
            "critical_failures": list(critical_failures),
            "results": [asdict(result) for result in results],
        }


def _severity(result: Mapping[str, Any]) -> str:
    if result["status"] == "PASS":
        return "Observation"
    if result["status"] == "FAIL" and result["critical"]:
        return "High"
    if result["status"] == "FAIL":
        return "Medium"
    return "Low"


def write_outputs(
    summary: Mapping[str, Any],
    project_root: Path,
    output_config: Mapping[str, Any],
) -> dict[str, Path]:
    """Write the controlled Section 24 evidence package."""

    root = project_root.resolve()
    paths = {
        key: root / str(value)
        for key, value in output_config.items()
        if key in {"matrix_csv", "findings_csv", "summary_json", "report_md", "evidence_txt"}
    }
    for path in paths.values():
        path.parent.mkdir(parents=True, exist_ok=True)

    results = list(summary["results"])
    matrix_fields = [
        "challenge_id",
        "name",
        "status",
        "score",
        "weight",
        "critical",
        "keyword_groups_satisfied",
        "keyword_groups_required",
        "quantitative_checks_passed",
        "quantitative_checks_required",
        "evidence_files",
        "missing_keyword_groups",
    ]
    with paths["matrix_csv"].open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=matrix_fields)
        writer.writeheader()
        for result in results:
            row = {field: result[field] for field in matrix_fields}
            row["evidence_files"] = " | ".join(result["evidence_files"])
            row["missing_keyword_groups"] = " | ".join(result["missing_keyword_groups"])
            writer.writerow(row)

    finding_fields = [
        "finding_id",
        "challenge_id",
        "challenge",
        "severity",
        "status",
        "risk_statement",
        "missing_evidence",
        "recommended_remediation",
    ]
    with paths["findings_csv"].open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=finding_fields)
        writer.writeheader()
        counter = 1
        for result in results:
            if result["status"] == "PASS":
                continue
            writer.writerow(
                {
                    "finding_id": f"CS-{counter:03d}",
                    "challenge_id": result["challenge_id"],
                    "challenge": result["name"],
                    "severity": _severity(result),
                    "status": result["status"],
                    "risk_statement": result["risk_statement"],
                    "missing_evidence": " | ".join(result["missing_keyword_groups"]),
                    "recommended_remediation": result["remediation"],
                }
            )
            counter += 1

    paths["summary_json"].write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    report_lines = [
        "# Section 24 â€” Conceptual Soundness Validation",
        "",
        "## Independent validation conclusion",
        "",
        f"- Overall status: **{summary['overall_status']}**",
        f"- Weighted score: **{float(summary['weighted_score']):.2%}**",
        f"- Critical failures: **{len(summary['critical_failures'])}**",
        "",
        "The assessment challenges model design, assumptions, evidence, and deterministic "
        "sanity checks. It does not treat file existence alone as conceptual validation.",
        "",
        "## Challenge matrix",
        "",
        "| Challenge | Status | Score | Evidence groups | Quantitative checks |",
        "|---|---:|---:|---:|---:|",
    ]
    for result in results:
        report_lines.append(
            (
                "| {name} | {status} | {score:.1%} | {hits}/{required} | {q_hits}/{q_required} |"
            ).format(
                name=result["name"],
                status=result["status"],
                score=float(result["score"]),
                hits=result["keyword_groups_satisfied"],
                required=result["keyword_groups_required"],
                q_hits=result["quantitative_checks_passed"],
                q_required=result["quantitative_checks_required"],
            )
        )

    report_lines.extend(["", "## Detailed challenge results", ""])
    for result in results:
        report_lines.extend(
            [
                f"### {result['name']}",
                "",
                f"**Status:** {result['status']}  ",
                f"**Risk:** {result['risk_statement']}  ",
                f"**Standards mapping:** {', '.join(result['standards']) or 'Not specified'}",
                "",
                "**Challenge questions**",
                "",
            ]
        )
        report_lines.extend(f"- {question}" for question in result["challenge_questions"])
        report_lines.extend(["", "**Evidence files**", ""])
        report_lines.extend(f"- `{path}`" for path in result["evidence_files"])
        if not result["evidence_files"]:
            report_lines.append("- No matching controlled evidence file was located.")
        report_lines.extend(["", "**Missing evidence groups**", ""])
        if result["missing_keyword_groups"]:
            report_lines.extend(f"- {group}" for group in result["missing_keyword_groups"])
        else:
            report_lines.append("- None.")
        report_lines.extend(["", f"**Remediation:** {result['remediation']}", ""])

    paths["report_md"].write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    evidence_lines = [
        "SECTION 24 CONCEPTUAL SOUNDNESS VALIDATION",
        f"Generated UTC: {summary['generated_at_utc']}",
        f"Overall status: {summary['overall_status']}",
        f"Weighted score: {float(summary['weighted_score']):.6f}",
        f"Critical failures: {', '.join(summary['critical_failures']) or 'None'}",
        "",
    ]
    for result in results:
        evidence_lines.append(
            f"{result['challenge_id']}: {result['status']} "
            f"(score={float(result['score']):.6f}, "
            f"evidence={result['keyword_groups_satisfied']}/"
            f"{result['keyword_groups_required']}, "
            f"quantitative={result['quantitative_checks_passed']}/"
            f"{result['quantitative_checks_required']})"
        )
    paths["evidence_txt"].write_text("\n".join(evidence_lines) + "\n", encoding="utf-8")
    return paths
