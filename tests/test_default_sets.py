"""Tests for synthetic clearing-member default-set construction."""

from __future__ import annotations

from copy import deepcopy

import pandas as pd
import pytest

from ficc_liquidity.synthetic.default_sets import (
    DefaultSetError,
    construct_default_sets,
    cover_1_selection,
    cover_2_selection,
    largest_single_member_default,
    largest_two_member_default,
    prepare_member_frame,
    run_self_test,
    validate_default_sets,
)


@pytest.fixture
def members() -> pd.DataFrame:
    """Controlled synthetic member fixture."""
    return pd.DataFrame(
        {
            "synthetic_member_id": [
                "SYN-MEMBER-0001",
                "SYN-MEMBER-0002",
                "SYN-MEMBER-0003",
                "SYN-MEMBER-0004",
                "SYN-MEMBER-0005",
            ],
            "stressed_liquidity_need_usd": [150.0, 120.0, 80.0, 70.0, 60.0],
            "settlement_obligation_usd": [20.0, 15.0, 15.0, 10.0, 10.0],
            "repo_financing_need_usd": [30.0, 25.0, 20.0, 15.0, 10.0],
            "available_qualified_liquid_resources_usd": [
                20.0,
                15.0,
                10.0,
                15.0,
                15.0,
            ],
            "member_concentration": [0.25, 0.20, 0.12, 0.08, 0.07],
            "correlation_cluster": ["A", "A", "B", "B", "B"],
        }
    )


@pytest.fixture
def config() -> dict[str, object]:
    """Controlled default-set configuration."""
    return {
        "member_id_column": "synthetic_member_id",
        "synthetic_member_id_pattern": r"^SYN-MEMBER-[0-9]{4,}$",
        "scoring": {
            "fields": {
                "stressed_liquidity_need_usd": 1.0,
                "settlement_obligation_usd": 0.25,
                "repo_financing_need_usd": 0.25,
                "available_qualified_liquid_resources_usd": -1.0,
            },
            "missing_field_policy": "error",
            "floor_at_zero": True,
        },
        "definitions": [
            {
                "default_set_id": "largest_single",
                "selection_type": "largest_single",
            },
            {
                "default_set_id": "cover_1",
                "selection_type": "cover_1",
            },
            {
                "default_set_id": "largest_two",
                "selection_type": "largest_two",
            },
            {
                "default_set_id": "cover_2",
                "selection_type": "cover_2",
            },
            {
                "default_set_id": "concentrated",
                "selection_type": "concentrated",
                "concentration_column": "member_concentration",
                "minimum_concentration": 0.10,
                "maximum_members": 3,
                "scenario_per_member": True,
            },
            {
                "default_set_id": "correlated",
                "selection_type": "correlated_multi",
                "group_column": "correlation_cluster",
                "minimum_members": 2,
                "maximum_members_per_group": 3,
                "maximum_groups": 2,
            },
        ],
        "validation": {"require_synthetic_identifiers": True},
    }


def test_largest_single_and_cover_1_match(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    prepared = prepare_member_frame(members, config)
    largest = largest_single_member_default(prepared)
    cover_1 = cover_1_selection(prepared)

    assert largest["synthetic_member_id"].tolist() == ["SYN-MEMBER-0001"]
    assert cover_1["synthetic_member_id"].tolist() == largest[
        "synthetic_member_id"
    ].tolist()


def test_largest_two_and_cover_2_match(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    prepared = prepare_member_frame(members, config)
    largest_two = largest_two_member_default(prepared)
    cover_2 = cover_2_selection(prepared)

    expected = ["SYN-MEMBER-0001", "SYN-MEMBER-0002"]
    assert largest_two["synthetic_member_id"].tolist() == expected
    assert cover_2["synthetic_member_id"].tolist() == expected


def test_concentrated_member_defaults_are_separate_scenarios(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    result = construct_default_sets(members, config)
    concentrated = result.loc[result["selection_type"] == "concentrated"]

    assert len(concentrated) == 3
    assert concentrated["default_set_id"].nunique() == 3
    assert set(concentrated["synthetic_member_id"]) == {
        "SYN-MEMBER-0001",
        "SYN-MEMBER-0002",
        "SYN-MEMBER-0003",
    }


def test_correlated_multi_member_defaults(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    result = construct_default_sets(members, config)
    correlated = result.loc[result["selection_type"] == "correlated_multi"]

    assert correlated["default_set_id"].nunique() == 2
    assert correlated.groupby("default_set_id").size().ge(2).all()
    assert set(correlated["correlation_group"]) == {"A", "B"}


def test_selection_is_deterministic_under_input_reordering(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    first = construct_default_sets(members, config)
    shuffled = members.sample(frac=1.0, random_state=2026).reset_index(drop=True)
    second = construct_default_sets(shuffled, config)

    pd.testing.assert_frame_equal(first, second)


def test_configurable_explicit_default_set(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    configured = deepcopy(config)
    definitions = configured["definitions"]
    assert isinstance(definitions, list)
    definitions.append(
        {
            "default_set_id": "explicit",
            "selection_type": "explicit",
            "member_ids": ["SYN-MEMBER-0003", "SYN-MEMBER-0001"],
        }
    )

    result = construct_default_sets(members, configured)
    explicit = result.loc[result["default_set_id"] == "explicit"]

    assert explicit["synthetic_member_id"].tolist() == [
        "SYN-MEMBER-0003",
        "SYN-MEMBER-0001",
    ]


def test_actual_participant_like_identifier_is_rejected(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    invalid = members.copy()
    invalid.loc[0, "synthetic_member_id"] = "ACTUAL-PARTICIPANT-NAME"

    with pytest.raises(DefaultSetError, match="Non-synthetic"):
        construct_default_sets(invalid, config)


def test_unknown_explicit_member_is_rejected(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    configured = deepcopy(config)
    configured["definitions"] = [
        {
            "default_set_id": "explicit",
            "selection_type": "explicit",
            "member_ids": ["SYN-MEMBER-9999"],
        }
    ]

    with pytest.raises(DefaultSetError, match="unknown synthetic members"):
        construct_default_sets(members, configured)


def test_validation_controls_pass(
    members: pd.DataFrame,
    config: dict[str, object],
) -> None:
    result = construct_default_sets(members, config)
    validation = validate_default_sets(result, members, config)

    assert validation.passed
    assert all(validation.checks.values())


def test_section_13_self_test_passes() -> None:
    result, validation, acceptance = run_self_test()

    assert not result.empty
    assert validation.passed
    assert all(acceptance.values())