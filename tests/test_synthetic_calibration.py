"""Unit tests for FR 2004 aggregate synthetic-member calibration."""

from __future__ import annotations

from datetime import date

import numpy as np

from ficc_liquidity.synthetic.calibrate_members import (
    MATURITY_COLUMNS,
    AggregateTargets,
    CalibrationSettings,
    build_reconciliation,
    deterministic_digest,
    exact_allocate,
    generate_calibrated_frame,
    heavy_tail_weights,
    validate_calibration,
)


def _settings(
    *,
    concentration_power: float = 1.4,
    random_seed: int = 2026,
) -> CalibrationSettings:
    return CalibrationSettings(
        member_count=24,
        random_seed=random_seed,
        pareto_shape=1.55,
        concentration_power=concentration_power,
        idiosyncratic_sigma=0.20,
        generator_version="test",
        collateral_coverage_low=1.05,
        collateral_coverage_high=1.45,
        qualified_resource_share_low=0.35,
        qualified_resource_share_high=0.70,
        stress_multiplier_low=1.10,
        stress_multiplier_high=1.55,
        risk_weights={
            "concentration": 0.25,
            "funding_dependency": 0.25,
            "settlement_fail": 0.20,
            "collateral_shortfall": 0.15,
            "liquidity_shortfall": 0.15,
        },
        elevated_threshold=40.0,
        high_threshold=65.0,
        aggregate_tolerance_usd=0.01,
    )


def _targets() -> AggregateTargets:
    maturity = {
        MATURITY_COLUMNS[0]: 7_000_000_000_00,
        MATURITY_COLUMNS[1]: 12_000_000_000_00,
        MATURITY_COLUMNS[2]: 15_000_000_000_00,
        MATURITY_COLUMNS[3]: 9_000_000_000_00,
        MATURITY_COLUMNS[4]: 14_000_000_000_00,
        MATURITY_COLUMNS[5]: 1_000_000_000_00,
    }
    source_series = {
        column: (f"TEST-{index}",)
        for index, column in enumerate(
            (
                *MATURITY_COLUMNS,
                "treasury_transaction_activity_usd",
                "fr2004_repo_financing_out_usd",
                "fr2004_reverse_repo_in_usd",
                "fr2004_fails_to_receive_usd",
                "fr2004_fails_to_deliver_usd",
            ),
            start=1,
        )
    }
    return AggregateTargets(
        as_of_date=date(2026, 1, 2),
        maturity_targets=maturity,
        treasury_transaction_activity_cents=40_000_000_000_00,
        repo_financing_out_cents=22_000_000_000_00,
        reverse_repo_in_cents=13_000_000_000_00,
        fails_to_receive_cents=2_000_000_000_00,
        fails_to_deliver_cents=3_000_000_000_00,
        source_file="test.csv",
        source_sha256="a" * 64,
        source_series=source_series,
    )


def test_exact_allocate_reconciles_integer_cents() -> None:
    allocated = exact_allocate(10_003, [0.5, 0.3, 0.2])
    assert allocated.sum() == 10_003
    assert (allocated >= 0).all()


def test_generation_is_deterministic_and_reconciles() -> None:
    settings = _settings()
    targets = _targets()
    first = generate_calibrated_frame(targets, settings)
    second = generate_calibrated_frame(targets, settings)

    assert deterministic_digest(first) == deterministic_digest(second)
    reconciliation = build_reconciliation(
        first,
        targets,
        settings.aggregate_tolerance_usd,
    )
    assert reconciliation["status"].eq("PASS").all()
    validate_calibration(first, reconciliation, settings)


def test_identifiers_and_labels_are_synthetic_only() -> None:
    frame = generate_calibrated_frame(_targets(), _settings())
    assert frame["member_id"].str.fullmatch(r"SYN-MBR-\d{4}").all()
    assert frame["member_label"].str.fullmatch(r"Fictional Clearing Member \d{3}").all()
    assert frame["value_class"].eq("synthetic").all()
    assert not frame["actual_ficc_participant"].any()
    assert not frame["participant_level_inference"].any()


def test_all_monetary_exposures_are_nonnegative() -> None:
    frame = generate_calibrated_frame(_targets(), _settings())
    monetary = [
        column
        for column in frame.columns
        if column.endswith("_usd") and np.issubdtype(frame[column].dtype, np.number)
    ]
    assert monetary
    assert (frame[monetary] >= 0.0).all().all()


def test_configurable_concentration_changes_largest_weight() -> None:
    low = heavy_tail_weights(_settings(concentration_power=0.8))
    high = heavy_tail_weights(_settings(concentration_power=2.2))
    assert high.max() > low.max()


def test_different_seed_changes_portfolio() -> None:
    targets = _targets()
    first = generate_calibrated_frame(targets, _settings(random_seed=2026))
    second = generate_calibrated_frame(targets, _settings(random_seed=2027))
    assert deterministic_digest(first) != deterministic_digest(second)
