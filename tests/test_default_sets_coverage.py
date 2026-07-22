"""Supplemental coverage tests for Section 13 default-set construction."""

from __future__ import annotations

import sys
from copy import deepcopy
from pathlib import Path

import pandas as pd
import pytest

from ficc_liquidity.synthetic import default_sets as ds


def _members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "synthetic_member_id": [
                "SYN-MEMBER-0001",
                "SYN-MEMBER-0002",
                "SYN-MEMBER-0003",
                "SYN-MEMBER-0004",
            ],
            "stressed_liquidity_need_usd": [100.0, 90.0, 80.0, 70.0],
            "settlement_obligation_usd": [20.0, 10.0, 10.0, 5.0],
            "repo_financing_need_usd": [20.0, 20.0, 10.0, 10.0],
            "available_qualified_liquid_resources_usd": [
                10.0,
                10.0,
                10.0,
                10.0,
            ],
            "member_concentration": [0.30, 0.20, 0.08, 0.05],
            "correlation_cluster": ["A", "A", "B", "B"],
        }
    )


def _config() -> dict[str, object]:
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
                "maximum_members": 2,
                "scenario_per_member": True,
            },
            {
                "default_set_id": "correlated",
                "selection_type": "correlated_multi",
                "group_column": "correlation_cluster",
                "minimum_members": 2,
                "maximum_members_per_group": 2,
                "maximum_groups": 2,
            },
        ],
        "validation": {"require_synthetic_identifiers": True},
    }


def test_load_valid_configuration(tmp_path: Path) -> None:
    config_path = tmp_path / "default_sets.yaml"
    config_path.write_text(
        "definitions:\n  - default_set_id: cover_1\n    selection_type: cover_1\n",
        encoding="utf-8",
    )

    loaded = ds.load_default_set_config(config_path)

    assert loaded["definitions"][0]["default_set_id"] == "cover_1"


@pytest.mark.parametrize(
    "content,match",
    [
        ("- item\n", "YAML mapping"),
        ("definitions: []\n", "nonempty"),
    ],
)
def test_load_invalid_configuration(
    tmp_path: Path,
    content: str,
    match: str,
) -> None:
    config_path = tmp_path / "invalid.yaml"
    config_path.write_text(content, encoding="utf-8")

    with pytest.raises(ds.DefaultSetError, match=match):
        ds.load_default_set_config(config_path)


def test_missing_configuration_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(ds.DefaultSetError, match="does not exist"):
        ds.load_default_set_config(tmp_path / "missing.yaml")


def test_read_csv_and_reject_unsupported_input(tmp_path: Path) -> None:
    csv_path = tmp_path / "members.csv"
    _members().to_csv(csv_path, index=False)

    loaded = ds.read_member_data(csv_path)

    assert len(loaded) == 4

    text_path = tmp_path / "members.txt"
    text_path.write_text("not supported", encoding="utf-8")
    with pytest.raises(ds.DefaultSetError, match="Unsupported"):
        ds.read_member_data(text_path)


def test_alias_mapping_and_deterministic_tie_break() -> None:
    members = _members().rename(
        columns={
            "synthetic_member_id": "member_id",
            "stressed_liquidity_need_usd": "liquidity_need_usd",
        }
    )
    members.loc[:, "liquidity_need_usd"] = 100.0

    config = _config()
    config["column_aliases"] = {
        "synthetic_member_id": ["member_id"],
        "stressed_liquidity_need_usd": ["liquidity_need_usd"],
    }

    prepared = ds.prepare_member_frame(members, config)

    assert prepared.iloc[0]["synthetic_member_id"] == "SYN-MEMBER-0001"


def test_duplicate_and_invalid_member_identifiers_are_rejected() -> None:
    duplicate = _members()
    duplicate.loc[1, "synthetic_member_id"] = "SYN-MEMBER-0001"

    with pytest.raises(ds.DefaultSetError, match="must be unique"):
        ds.construct_default_sets(duplicate, _config())

    invalid = _members()
    invalid.loc[0, "synthetic_member_id"] = "REAL-MEMBER"

    with pytest.raises(ds.DefaultSetError, match="Non-synthetic"):
        ds.construct_default_sets(invalid, _config())


def test_missing_and_negative_scoring_fields_are_rejected() -> None:
    missing = _members().drop(columns=["stressed_liquidity_need_usd"])
    with pytest.raises(ds.DefaultSetError, match="Required scoring field"):
        ds.construct_default_sets(missing, _config())

    negative = _members()
    negative.loc[0, "stressed_liquidity_need_usd"] = -1.0
    with pytest.raises(ds.DefaultSetError, match="negative values"):
        ds.construct_default_sets(negative, _config())


def test_ignore_policy_still_requires_one_available_score_field() -> None:
    config = _config()
    config["scoring"] = {
        "fields": {"unavailable_score_field": 1.0},
        "missing_field_policy": "ignore",
        "floor_at_zero": True,
    }

    with pytest.raises(ds.DefaultSetError, match="None of the configured"):
        ds.construct_default_sets(_members(), config)


def test_largest_two_requires_two_members() -> None:
    config = _config()
    config["definitions"] = [
        {
            "default_set_id": "largest_two",
            "selection_type": "largest_two",
        }
    ]

    with pytest.raises(ds.DefaultSetError, match="at least 2"):
        ds.construct_default_sets(_members().head(1), config)


def test_concentrated_selection_controls() -> None:
    config = _config()
    config["definitions"] = [
        {
            "default_set_id": "concentrated",
            "selection_type": "concentrated",
            "concentration_column": "member_concentration",
            "minimum_concentration": 0.99,
            "maximum_members": 2,
            "allow_empty": False,
        }
    ]

    with pytest.raises(ds.DefaultSetError, match="No members satisfy"):
        ds.construct_default_sets(_members(), config)

    invalid = _members()
    invalid.loc[0, "member_concentration"] = 1.10
    with pytest.raises(ds.DefaultSetError, match="between 0 and 1"):
        ds.construct_default_sets(invalid, _config())


@pytest.mark.parametrize(
    "overrides,match",
    [
        ({"minimum_members": 1}, "at least 2"),
        (
            {"minimum_members": 3, "maximum_members_per_group": 2},
            "must be >=",
        ),
        ({"maximum_groups": 0}, "at least 1"),
    ],
)
def test_correlated_parameter_validation(
    overrides: dict[str, int],
    match: str,
) -> None:
    definition: dict[str, object] = {
        "default_set_id": "correlated",
        "selection_type": "correlated_multi",
        "group_column": "correlation_cluster",
        "minimum_members": 2,
        "maximum_members_per_group": 2,
        "maximum_groups": 1,
    }
    definition.update(overrides)

    config = _config()
    config["definitions"] = [definition]

    with pytest.raises(ds.DefaultSetError, match=match):
        ds.construct_default_sets(_members(), config)


def test_correlated_selection_requires_qualifying_group() -> None:
    members = _members()
    members["correlation_cluster"] = ["A", "B", "C", "D"]

    config = _config()
    config["definitions"] = [
        {
            "default_set_id": "correlated",
            "selection_type": "correlated_multi",
            "group_column": "correlation_cluster",
            "minimum_members": 2,
            "maximum_members_per_group": 2,
            "maximum_groups": 1,
            "allow_empty": False,
        }
    ]

    with pytest.raises(ds.DefaultSetError, match="No correlation group"):
        ds.construct_default_sets(members, config)


def test_explicit_default_set_validation() -> None:
    invalid_type = _config()
    invalid_type["definitions"] = [
        {
            "default_set_id": "explicit",
            "selection_type": "explicit",
            "member_ids": "SYN-MEMBER-0001",
        }
    ]

    with pytest.raises(ds.DefaultSetError, match="must be a list"):
        ds.construct_default_sets(_members(), invalid_type)

    unknown = deepcopy(invalid_type)
    unknown["definitions"][0]["member_ids"] = ["SYN-MEMBER-9999"]

    with pytest.raises(ds.DefaultSetError, match="unknown synthetic members"):
        ds.construct_default_sets(_members(), unknown)


@pytest.mark.parametrize(
    "definitions,match",
    [
        (
            [
                {
                    "default_set_id": "duplicate",
                    "selection_type": "cover_1",
                },
                {
                    "default_set_id": "duplicate",
                    "selection_type": "cover_2",
                },
            ],
            "Duplicate configured",
        ),
        (
            [
                {
                    "default_set_id": "unsupported",
                    "selection_type": "not_supported",
                }
            ],
            "Unsupported selection_type",
        ),
        ([42], "must be a mapping"),
    ],
)
def test_invalid_default_set_definitions(
    definitions: list[object],
    match: str,
) -> None:
    config = _config()
    config["definitions"] = definitions

    with pytest.raises(ds.DefaultSetError, match=match):
        ds.construct_default_sets(_members(), config)


def test_validation_detects_duplicate_members() -> None:
    members = _members()
    config = _config()
    result = ds.construct_default_sets(members, config)
    duplicate_row = result.iloc[[0]].copy()
    tampered = pd.concat([result, duplicate_row], ignore_index=True)

    validation = ds.validate_default_sets(tampered, members, config)

    assert not validation.passed
    assert not validation.checks["unique_members_within_default_set"]


def test_cli_self_test_writes_outputs(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    output_path = tmp_path / "default_sets.csv"
    evidence_path = tmp_path / "evidence.txt"

    monkeypatch.setattr(
        sys,
        "argv",
        [
            "default_sets",
            "--self-test",
            "--output",
            str(output_path),
            "--evidence",
            str(evidence_path),
        ],
    )

    exit_code = ds.main()

    assert exit_code == 0
    assert output_path.exists()
    assert evidence_path.exists()
    assert "Section 13: COMPLETE" in evidence_path.read_text(encoding="utf-8")
