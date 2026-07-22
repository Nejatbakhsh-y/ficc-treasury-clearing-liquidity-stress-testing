"""Controlled schema for fictional clearing-member liquidity profiles."""

from __future__ import annotations

import math
import re
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from datetime import date
from typing import ClassVar, cast


def classify_risk(
    score: float,
    elevated_threshold: float = 40.0,
    high_threshold: float = 65.0,
) -> str:
    """Map a bounded liquidity-risk score to a controlled risk band."""
    if not 0.0 <= elevated_threshold < high_threshold <= 100.0:
        raise ValueError("Risk thresholds must satisfy 0 <= elevated < high <= 100.")
    if not 0.0 <= score <= 100.0:
        raise ValueError("Liquidity-risk score must be between 0 and 100.")
    if score >= high_threshold:
        return "high"
    if score >= elevated_threshold:
        return "elevated"
    return "moderate"


@dataclass(frozen=True, slots=True)
class SyntheticMember:
    """One fictional clearing-member observation at a controlled as-of date."""

    member_id: str
    member_label: str
    as_of_date: date
    value_class: str
    generator_version: str
    actual_ficc_participant: bool

    treasury_position_bills_0_1y_usd: float
    treasury_position_notes_1_3y_usd: float
    treasury_position_notes_3_7y_usd: float
    treasury_position_notes_7_10y_usd: float
    treasury_position_bonds_10_30y_usd: float
    treasury_position_strips_30y_plus_usd: float
    total_treasury_position_usd: float

    treasury_transaction_activity_usd: float
    repo_financing_need_usd: float
    reverse_repo_position_usd: float
    settlement_obligation_usd: float
    settlement_fail_usd: float
    collateral_inventory_usd: float
    available_qualified_liquid_resources_usd: float
    stressed_liquidity_need_usd: float
    liquidity_gap_usd: float

    member_concentration_ratio: float
    funding_dependency_ratio: float
    net_repo_dependency_ratio: float
    settlement_fail_rate: float
    collateral_coverage_ratio: float
    liquidity_coverage_ratio: float
    liquidity_risk_score: float
    risk_elevated_threshold: float
    risk_high_threshold: float
    liquidity_risk_band: str

    _ID_PATTERN: ClassVar[re.Pattern[str]] = re.compile(r"^SYN-MBR-\d{4}$")
    _LABEL_PATTERN: ClassVar[re.Pattern[str]] = re.compile(r"^Fictional Clearing Member \d{3}$")
    _USD_FIELDS: ClassVar[tuple[str, ...]] = (
        "treasury_position_bills_0_1y_usd",
        "treasury_position_notes_1_3y_usd",
        "treasury_position_notes_3_7y_usd",
        "treasury_position_notes_7_10y_usd",
        "treasury_position_bonds_10_30y_usd",
        "treasury_position_strips_30y_plus_usd",
        "total_treasury_position_usd",
        "treasury_transaction_activity_usd",
        "repo_financing_need_usd",
        "reverse_repo_position_usd",
        "settlement_obligation_usd",
        "settlement_fail_usd",
        "collateral_inventory_usd",
        "available_qualified_liquid_resources_usd",
        "stressed_liquidity_need_usd",
        "liquidity_gap_usd",
    )
    _POSITIVE_FIELDS: ClassVar[tuple[str, ...]] = (
        "total_treasury_position_usd",
        "treasury_transaction_activity_usd",
        "repo_financing_need_usd",
        "settlement_obligation_usd",
        "stressed_liquidity_need_usd",
    )
    _BOUNDED_RATIO_FIELDS: ClassVar[tuple[str, ...]] = (
        "member_concentration_ratio",
        "funding_dependency_ratio",
        "net_repo_dependency_ratio",
        "settlement_fail_rate",
    )

    @property
    def maturity_positions(self) -> tuple[float, ...]:
        """Return the six controlled Treasury maturity-bucket positions."""
        return (
            self.treasury_position_bills_0_1y_usd,
            self.treasury_position_notes_1_3y_usd,
            self.treasury_position_notes_3_7y_usd,
            self.treasury_position_notes_7_10y_usd,
            self.treasury_position_bonds_10_30y_usd,
            self.treasury_position_strips_30y_plus_usd,
        )

    def validate(self) -> None:
        """Validate identity separation, accounting consistency, and risk fields."""
        if self._ID_PATTERN.fullmatch(self.member_id) is None:
            raise ValueError(f"Invalid synthetic member identifier: {self.member_id}")
        if self._LABEL_PATTERN.fullmatch(self.member_label) is None:
            raise ValueError("Member labels must use the controlled fictional naming convention.")
        if self.actual_ficc_participant:
            raise ValueError("A synthetic record cannot be marked as an actual FICC participant.")
        if self.value_class != "synthetic":
            raise ValueError("Synthetic member records must use value_class='synthetic'.")
        if not self.generator_version.strip():
            raise ValueError("generator_version must be populated.")

        for field_name in self._USD_FIELDS:
            value = float(getattr(self, field_name))
            if not math.isfinite(value) or value < 0.0:
                raise ValueError(f"{field_name} must be finite and nonnegative.")

        for field_name in self._POSITIVE_FIELDS:
            if float(getattr(self, field_name)) <= 0.0:
                raise ValueError(f"{field_name} must be positive.")

        for field_name in self._BOUNDED_RATIO_FIELDS:
            value = float(getattr(self, field_name))
            if not math.isfinite(value) or not 0.0 <= value <= 1.0:
                raise ValueError(f"{field_name} must be finite and between zero and one.")

        for field_name in ("collateral_coverage_ratio", "liquidity_coverage_ratio"):
            value = float(getattr(self, field_name))
            if not math.isfinite(value) or value < 0.0:
                raise ValueError(f"{field_name} must be finite and nonnegative.")

        if not math.isfinite(self.liquidity_risk_score):
            raise ValueError("liquidity_risk_score must be finite.")
        if self.reverse_repo_position_usd > self.repo_financing_need_usd:
            raise ValueError("Reverse-repo positions cannot exceed repo financing needs.")
        if self.settlement_fail_usd > self.settlement_obligation_usd:
            raise ValueError("Settlement fails cannot exceed settlement obligations.")
        if self.available_qualified_liquid_resources_usd > self.collateral_inventory_usd:
            raise ValueError("Qualified liquid resources cannot exceed collateral inventory.")

        maturity_total = sum(self.maturity_positions)
        if not math.isclose(
            maturity_total,
            self.total_treasury_position_usd,
            rel_tol=1e-10,
            abs_tol=5.0,
        ):
            raise ValueError("Treasury maturity positions do not reconcile to the total.")

        expected_concentration = max(self.maturity_positions) / self.total_treasury_position_usd
        expected_funding_dependency = (
            self.repo_financing_need_usd / self.treasury_transaction_activity_usd
        )
        expected_net_repo_dependency = (
            max(self.repo_financing_need_usd - self.reverse_repo_position_usd, 0.0)
            / self.repo_financing_need_usd
        )
        expected_fail_rate = self.settlement_fail_usd / self.settlement_obligation_usd
        expected_collateral_coverage = (
            self.collateral_inventory_usd / self.stressed_liquidity_need_usd
        )
        expected_liquidity_coverage = (
            self.available_qualified_liquid_resources_usd / self.stressed_liquidity_need_usd
        )
        expected_gap = max(
            self.stressed_liquidity_need_usd - self.available_qualified_liquid_resources_usd,
            0.0,
        )

        consistency_checks = (
            (
                expected_concentration,
                self.member_concentration_ratio,
                "Member concentration ratio is inconsistent.",
            ),
            (
                expected_funding_dependency,
                self.funding_dependency_ratio,
                "Funding-dependency ratio is inconsistent.",
            ),
            (
                expected_net_repo_dependency,
                self.net_repo_dependency_ratio,
                "Net repo-dependency ratio is inconsistent.",
            ),
            (
                expected_fail_rate,
                self.settlement_fail_rate,
                "Settlement-fail rate is inconsistent.",
            ),
            (
                expected_collateral_coverage,
                self.collateral_coverage_ratio,
                "Collateral-coverage ratio is inconsistent.",
            ),
            (
                expected_liquidity_coverage,
                self.liquidity_coverage_ratio,
                "Liquidity-coverage ratio is inconsistent.",
            ),
        )
        for expected, observed, message in consistency_checks:
            if not math.isclose(expected, observed, rel_tol=1e-10, abs_tol=1e-10):
                raise ValueError(message)

        if not math.isclose(expected_gap, self.liquidity_gap_usd, rel_tol=1e-10, abs_tol=5.0):
            raise ValueError("Liquidity gap is inconsistent.")

        expected_band = classify_risk(
            self.liquidity_risk_score,
            elevated_threshold=self.risk_elevated_threshold,
            high_threshold=self.risk_high_threshold,
        )
        if expected_band != self.liquidity_risk_band:
            raise ValueError("Liquidity-risk band is inconsistent with the score.")

    def to_record(self) -> dict[str, object]:
        """Convert the validated dataclass to a tabular record."""
        self.validate()
        return cast(dict[str, object], asdict(self))


def validate_members(members: Sequence[SyntheticMember]) -> None:
    """Validate a collection and enforce unique synthetic identifiers."""
    if not members:
        raise ValueError("At least one synthetic member is required.")

    seen: set[str] = set()
    for member in members:
        member.validate()
        if member.member_id in seen:
            raise ValueError(f"Duplicate synthetic member identifier: {member.member_id}")
        seen.add(member.member_id)
