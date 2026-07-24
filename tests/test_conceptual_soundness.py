"""Tests for Section 24 conceptual-soundness validation."""

from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any

import pytest
import yaml

from ficc_liquidity.validation.conceptual_soundness import (
    ConceptualSoundnessValidator,
    eligible_resource_value,
    legally_permitted_net,
    load_validation_config,
    monotonic_non_decreasing,
    reconciliation_error,
    select_default_set,
    validate_haircut,
    validate_probability,
    write_outputs,
    yield_price_change,
)


def _challenge(challenge_id: str, pattern: str, terms: list[list[str]]) -> dict[str, Any]:
    return {
        "id": challenge_id,
        "name": challenge_id.replace("_", " ").title(),
        "weight": 1.0,
        "critical": challenge_id in {"liquidity_horizon", "resource_eligibility"},
        "minimum_evidence_files": 1,
        "evidence_paths": [pattern],
        "required_keyword_groups": terms,
        "challenge_questions": ["Is the assumption controlled?"],
        "risk_statement": "The assumption could be misstated.",
        "remediation": "Document and test the assumption.",
        "standards": ["PFMI Principle 7"],
    }


def _config(challenges: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "validation": {
            "overall_pass_score": 0.90,
            "partial_evidence_ratio": 0.60,
        },
        "outputs": {
            "matrix_csv": "reports/matrix.csv",
            "findings_csv": "reports/findings.csv",
            "summary_json": "reports/summary.json",
            "report_md": "reports/report.md",
            "evidence_txt": "reports/evidence.txt",
        },
        "challenges": challenges,
    }


def test_yield_price_change_sign_and_convexity() -> None:
    up = yield_price_change(7.0, 55.0, 100.0)
    down = yield_price_change(7.0, 55.0, -100.0)
    large_up = yield_price_change(7.0, 55.0, 200.0)

    assert up < 0.0
    assert down > 0.0
    assert large_up > 2.0 * up


@pytest.mark.parametrize(
    ("duration", "convexity", "shock"),
    [(-1.0, 1.0, 100.0), (1.0, -1.0, 100.0), (float("nan"), 1.0, 100.0)],
)
def test_yield_price_change_rejects_invalid_values(
    duration: float,
    convexity: float,
    shock: float,
) -> None:
    with pytest.raises(ValueError):
        yield_price_change(duration, convexity, shock)


@pytest.mark.parametrize("value", [0.0, 0.5, 1.0])
def test_probability_and_haircut_accept_boundaries(value: float) -> None:
    assert validate_probability("p", value) == value
    assert validate_haircut("h", value) == value


@pytest.mark.parametrize("value", [-0.01, 1.01, float("inf")])
def test_probability_rejects_out_of_range(value: float) -> None:
    with pytest.raises(ValueError):
        validate_probability("p", value)


def test_monotonic_non_decreasing() -> None:
    assert monotonic_non_decreasing((0.0, 0.0, 1.0))
    assert not monotonic_non_decreasing((0.0, 2.0, 1.0))


def test_select_default_set() -> None:
    losses = {"SYN003": 4.0, "SYN002": 8.0, "SYN001": 12.0}
    assert select_default_set(losses, 1) == ("SYN001",)
    assert select_default_set(losses, 2) == ("SYN001", "SYN002")


@pytest.mark.parametrize("cover", [0, 3])
def test_select_default_set_rejects_invalid_cover(cover: int) -> None:
    with pytest.raises(ValueError):
        select_default_set({"SYN001": 1.0, "SYN002": 2.0}, cover)


def test_select_default_set_rejects_negative_or_insufficient() -> None:
    with pytest.raises(ValueError):
        select_default_set({"SYN001": -1.0, "SYN002": 2.0}, 1)
    with pytest.raises(ValueError):
        select_default_set({"SYN001": 1.0}, 2)


def test_eligible_resource_value_applies_all_controls() -> None:
    resources = (
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
            "resource_id": "encumbered",
            "amount": 1_000.0,
            "eligible": True,
            "encumbered": True,
        },
        {
            "resource_id": "ineligible",
            "amount": 1_000.0,
            "eligible": False,
            "encumbered": False,
        },
    )
    assert eligible_resource_value(resources) == pytest.approx(188.2)


def test_eligible_resource_value_rejects_duplicates_and_negative_amount() -> None:
    duplicate = (
        {"resource_id": "cash", "amount": 1.0, "eligible": True},
        {"resource_id": "cash", "amount": 1.0, "eligible": True},
    )
    with pytest.raises(ValueError):
        eligible_resource_value(duplicate)
    with pytest.raises(ValueError):
        eligible_resource_value(({"resource_id": "cash", "amount": -1.0, "eligible": True},))


def test_legally_permitted_net_and_gross_fallback() -> None:
    assert (
        legally_permitted_net(
            80.0,
            100.0,
            enforceable=True,
            same_currency=True,
            same_settlement_date=True,
        )
        == 20.0
    )
    assert (
        legally_permitted_net(
            80.0,
            100.0,
            enforceable=False,
            same_currency=True,
            same_settlement_date=True,
        )
        == 100.0
    )
    assert (
        legally_permitted_net(
            120.0,
            100.0,
            enforceable=True,
            same_currency=True,
            same_settlement_date=True,
        )
        == 0.0
    )


def test_legally_permitted_net_rejects_negative_cash_flow() -> None:
    with pytest.raises(ValueError):
        legally_permitted_net(
            -1.0,
            100.0,
            enforceable=True,
            same_currency=True,
            same_settlement_date=True,
        )


def test_reconciliation_error() -> None:
    assert reconciliation_error(100.0, (20.0, 30.0, 50.0)) == 0.0
    assert reconciliation_error(100.0, (20.0, 30.0, 49.0)) == 1.0
    with pytest.raises(ValueError):
        reconciliation_error(-1.0, (1.0,))


def test_load_validation_config(tmp_path: Path) -> None:
    path = tmp_path / "config.yaml"
    path.write_text(
        yaml.safe_dump(_config([_challenge("liquidity_horizon", "docs/*.md", [["intraday"]])])),
        encoding="utf-8",
    )
    loaded = load_validation_config(path)
    assert loaded["validation"]["overall_pass_score"] == 0.90


@pytest.mark.parametrize("payload", [[], {"validation": {}}, {"challenges": []}])
def test_load_validation_config_rejects_invalid_root(
    tmp_path: Path,
    payload: object,
) -> None:
    path = tmp_path / "invalid.yaml"
    path.write_text(yaml.safe_dump(payload), encoding="utf-8")
    with pytest.raises(ValueError):
        load_validation_config(path)


def test_validator_passes_complete_evidence(tmp_path: Path) -> None:
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "liquidity.md").write_text(
        "Intraday liquidity horizon and multi-day payment timing.",
        encoding="utf-8",
    )
    config = _config(
        [
            _challenge(
                "liquidity_horizon",
                "docs/*.md",
                [["intraday"], ["multi-day"], ["payment timing"]],
            )
        ]
    )

    summary = ConceptualSoundnessValidator(tmp_path, config).run()

    assert summary["overall_status"] == "PASS"
    assert summary["critical_failures"] == []
    result = summary["results"][0]
    assert result["status"] == "PASS"
    assert result["evidence_files"] == ("docs/liquidity.md",)


def test_validator_returns_partial_and_findings(tmp_path: Path) -> None:
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "resources.md").write_text(
        "Qualified liquid resource eligibility and unencumbered availability.",
        encoding="utf-8",
    )
    config = _config(
        [
            _challenge(
                "resource_eligibility",
                "docs/*.md",
                [
                    ["qualified liquid resource"],
                    ["unencumbered"],
                    ["same-day"],
                ],
            )
        ]
    )

    validator = ConceptualSoundnessValidator(tmp_path, config)
    summary = validator.run()
    outputs = write_outputs(summary, tmp_path, config["outputs"])

    assert summary["overall_status"] == "ACCEPTABLE_WITH_FINDINGS"
    assert summary["results"][0]["status"] == "PARTIAL"
    assert all(path.exists() for path in outputs.values())

    rows = list(csv.DictReader(outputs["findings_csv"].open(encoding="utf-8")))
    assert rows[0]["severity"] == "Low"
    assert "same-day" in rows[0]["missing_evidence"]

    saved = json.loads(outputs["summary_json"].read_text(encoding="utf-8"))
    assert saved["section"] == 24
    assert "Challenge matrix" in outputs["report_md"].read_text(encoding="utf-8")
    assert "Overall status" in outputs["evidence_txt"].read_text(encoding="utf-8")


def test_validator_fails_critical_missing_evidence(tmp_path: Path) -> None:
    config = _config(
        [
            _challenge(
                "liquidity_horizon",
                "missing/*.md",
                [["intraday"], ["multi-day"]],
            )
        ]
    )
    summary = ConceptualSoundnessValidator(tmp_path, config).run()
    assert summary["overall_status"] == "FAIL"
    assert summary["critical_failures"] == ["liquidity_horizon"]
    assert summary["results"][0]["status"] == "FAIL"


def test_validator_requires_positive_total_weight(tmp_path: Path) -> None:
    challenge = _challenge("liquidity_horizon", "docs/*.md", [["intraday"]])
    challenge["weight"] = 0.0
    with pytest.raises(ValueError):
        ConceptualSoundnessValidator(tmp_path, _config([challenge])).run()


def test_validator_rejects_unknown_challenge(tmp_path: Path) -> None:
    challenge = _challenge("unknown_challenge", "docs/*.md", [["term"]])
    with pytest.raises(KeyError):
        ConceptualSoundnessValidator(tmp_path, _config([challenge])).run()
