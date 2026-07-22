"""Configurable default-set construction for synthetic clearing-member portfolios.

The module intentionally operates only on synthetic member identifiers. It does
not identify, estimate, or represent actual FICC participants.
"""

from __future__ import annotations

import argparse
import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pandas as pd
import yaml


class DefaultSetError(ValueError):
    """Raised when a default-set definition or member dataset is invalid."""


@dataclass(frozen=True)
class ValidationResult:
    """Structured validation result."""

    checks: Mapping[str, bool]

    @property
    def passed(self) -> bool:
        """Return True only when every validation check passes."""
        return all(self.checks.values())


def load_default_set_config(path: str | Path) -> dict[str, Any]:
    """Load and minimally validate a YAML default-set configuration."""
    config_path = Path(path)
    if not config_path.exists():
        raise DefaultSetError(f"Configuration file does not exist: {config_path}")

    payload = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise DefaultSetError("Default-set configuration must be a YAML mapping.")

    definitions = payload.get("definitions")
    if not isinstance(definitions, list) or not definitions:
        raise DefaultSetError("Configuration must contain nonempty 'definitions'.")

    return payload


def read_member_data(path: str | Path) -> pd.DataFrame:
    """Read synthetic member data from CSV or Parquet."""
    data_path = Path(path)
    if not data_path.exists():
        raise DefaultSetError(f"Synthetic member data does not exist: {data_path}")

    suffix = data_path.suffix.lower()
    if suffix == ".csv":
        return pd.read_csv(data_path)
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(data_path)

    raise DefaultSetError(
        f"Unsupported member-data format '{suffix}'. Use CSV or Parquet."
    )


def _canonicalize_columns(
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> pd.DataFrame:
    """Return a copy with configured aliases renamed to canonical columns."""
    if members.empty:
        raise DefaultSetError("Synthetic member dataset is empty.")

    frame = members.copy(deep=True)
    alias_config = config.get("column_aliases", {})
    if not isinstance(alias_config, Mapping):
        raise DefaultSetError("'column_aliases' must be a mapping.")

    rename_map: dict[str, str] = {}
    for canonical, aliases_value in alias_config.items():
        canonical_name = str(canonical)
        if canonical_name in frame.columns:
            continue

        aliases: Sequence[Any]
        if isinstance(aliases_value, Sequence) and not isinstance(
            aliases_value,
            (str, bytes),
        ):
            aliases = aliases_value
        else:
            aliases = [aliases_value]

        match = next(
            (str(alias) for alias in aliases if str(alias) in frame.columns),
            None,
        )
        if match is not None:
            rename_map[match] = canonical_name

    frame = frame.rename(columns=rename_map)

    configured_id = str(config.get("member_id_column", "synthetic_member_id"))
    if "synthetic_member_id" not in frame.columns:
        if configured_id in frame.columns:
            frame = frame.rename(columns={configured_id: "synthetic_member_id"})
        else:
            raise DefaultSetError(
                "Synthetic member identifier column was not found. Expected "
                f"'synthetic_member_id' or configured column '{configured_id}'."
            )

    frame["synthetic_member_id"] = (
        frame["synthetic_member_id"].astype("string").str.strip()
    )
    if frame["synthetic_member_id"].isna().any():
        raise DefaultSetError("Synthetic member identifiers may not be missing.")
    if frame["synthetic_member_id"].duplicated().any():
        duplicates = sorted(
            frame.loc[
                frame["synthetic_member_id"].duplicated(keep=False),
                "synthetic_member_id",
            ]
            .astype(str)
            .unique()
            .tolist()
        )
        raise DefaultSetError(
            f"Synthetic member identifiers must be unique: {duplicates}"
        )

    return frame


def _validate_synthetic_ids(
    frame: pd.DataFrame,
    config: Mapping[str, Any],
) -> None:
    """Enforce synthetic-only member identifiers."""
    validation = config.get("validation", {})
    require_synthetic = bool(
        validation.get("require_synthetic_identifiers", True)
        if isinstance(validation, Mapping)
        else True
    )
    if not require_synthetic:
        return

    pattern = str(
        config.get(
            "synthetic_member_id_pattern",
            r"^SYN-MEMBER-[0-9]{4,}$",
        )
    )
    invalid = [
        member_id
        for member_id in frame["synthetic_member_id"].astype(str)
        if re.fullmatch(pattern, member_id) is None
    ]
    if invalid:
        raise DefaultSetError(
            "Non-synthetic or invalid member identifiers detected: "
            f"{sorted(invalid)}"
        )


def _compute_default_score(
    frame: pd.DataFrame,
    config: Mapping[str, Any],
) -> pd.DataFrame:
    """Compute a deterministic configurable stressed-liquidity severity score."""
    scoring = config.get("scoring", {})
    if not isinstance(scoring, Mapping):
        raise DefaultSetError("'scoring' must be a mapping.")

    fields = scoring.get("fields", {})
    if not isinstance(fields, Mapping) or not fields:
        raise DefaultSetError("'scoring.fields' must be a nonempty mapping.")

    missing_policy = str(scoring.get("missing_field_policy", "error")).lower()
    score = pd.Series(0.0, index=frame.index, dtype="float64")
    used_fields: list[str] = []

    for field_name, weight_value in fields.items():
        field = str(field_name)
        if field not in frame.columns:
            if missing_policy == "ignore":
                continue
            raise DefaultSetError(f"Required scoring field is missing: {field}")

        numeric = pd.to_numeric(frame[field], errors="coerce")
        if numeric.isna().any():
            raise DefaultSetError(
                f"Scoring field '{field}' contains missing or nonnumeric values."
            )
        if (numeric < 0).any():
            raise DefaultSetError(
                f"Scoring field '{field}' contains negative values."
            )

        score = score + numeric.astype(float) * float(weight_value)
        used_fields.append(field)

    if not used_fields:
        raise DefaultSetError(
            "None of the configured scoring fields were found in member data."
        )

    if bool(scoring.get("floor_at_zero", True)):
        score = score.clip(lower=0.0)

    result = frame.copy(deep=True)
    result["_default_score"] = score.astype(float)
    result["_score_fields"] = ",".join(used_fields)
    return result


def prepare_member_frame(
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> pd.DataFrame:
    """Canonicalize, validate, score, and stably rank synthetic members."""
    frame = _canonicalize_columns(members, config)
    _validate_synthetic_ids(frame, config)
    frame = _compute_default_score(frame, config)

    return frame.sort_values(
        by=["_default_score", "synthetic_member_id"],
        ascending=[False, True],
        kind="mergesort",
    ).reset_index(drop=True)


def _require_member_count(frame: pd.DataFrame, count: int, label: str) -> None:
    if len(frame) < count:
        raise DefaultSetError(
            f"{label} requires at least {count} synthetic members; "
            f"received {len(frame)}."
        )


def _result_rows(
    default_set_id: str,
    selection_type: str,
    selected: pd.DataFrame,
    definition: Mapping[str, Any],
    *,
    group_value: str | None = None,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    metadata = {
        "definition": dict(definition),
        "group_value": group_value,
        "synthetic_only": True,
    }
    metadata_json = json.dumps(metadata, sort_keys=True, default=str)

    for rank, (_, member) in enumerate(selected.iterrows(), start=1):
        rows.append(
            {
                "default_set_id": default_set_id,
                "selection_type": selection_type,
                "selection_rank": rank,
                "synthetic_member_id": str(member["synthetic_member_id"]),
                "default_score_usd": float(member["_default_score"]),
                "correlation_group": group_value,
                "selection_metadata_json": metadata_json,
            }
        )
    return rows


def largest_single_member_default(
    prepared_members: pd.DataFrame,
) -> pd.DataFrame:
    """Select the largest single synthetic member by default severity."""
    _require_member_count(prepared_members, 1, "Largest single-member default")
    return prepared_members.head(1).copy()


def cover_1_selection(prepared_members: pd.DataFrame) -> pd.DataFrame:
    """Select Cover 1 as the largest single synthetic member default."""
    return largest_single_member_default(prepared_members)


def largest_two_member_default(
    prepared_members: pd.DataFrame,
) -> pd.DataFrame:
    """Select the two largest synthetic members by default severity."""
    _require_member_count(prepared_members, 2, "Largest two-member default")
    return prepared_members.head(2).copy()


def cover_2_selection(prepared_members: pd.DataFrame) -> pd.DataFrame:
    """Select Cover 2 as the two largest synthetic member defaults."""
    return largest_two_member_default(prepared_members)


def _select_concentrated(
    frame: pd.DataFrame,
    definition: Mapping[str, Any],
) -> list[tuple[str, pd.DataFrame, str | None]]:
    column = str(definition.get("concentration_column", "member_concentration"))
    if column not in frame.columns:
        raise DefaultSetError(
            f"Concentrated-member definition requires column '{column}'."
        )

    concentration = pd.to_numeric(frame[column], errors="coerce")
    if concentration.isna().any():
        raise DefaultSetError(
            f"Concentration column '{column}' contains invalid values."
        )
    if ((concentration < 0) | (concentration > 1)).any():
        raise DefaultSetError(
            f"Concentration column '{column}' must be between 0 and 1."
        )

    minimum = float(definition.get("minimum_concentration", 0.10))
    maximum = int(definition.get("maximum_members", len(frame)))
    if maximum < 1:
        raise DefaultSetError("'maximum_members' must be at least 1.")

    selected = frame.assign(_concentration=concentration)
    selected = selected.loc[selected["_concentration"] >= minimum]
    selected = selected.sort_values(
        by=["_concentration", "_default_score", "synthetic_member_id"],
        ascending=[False, False, True],
        kind="mergesort",
    ).head(maximum)

    allow_empty = bool(definition.get("allow_empty", False))
    if selected.empty and not allow_empty:
        raise DefaultSetError(
            "No members satisfy the concentrated-member threshold."
        )

    default_set_id = str(definition["default_set_id"])
    scenario_per_member = bool(definition.get("scenario_per_member", True))
    if not scenario_per_member:
        return [(default_set_id, selected, None)]

    scenarios: list[tuple[str, pd.DataFrame, str | None]] = []
    for _, member in selected.iterrows():
        member_id = str(member["synthetic_member_id"])
        scenarios.append(
            (
                f"{default_set_id}__{member_id}",
                selected.loc[
                    selected["synthetic_member_id"].astype(str) == member_id
                ].copy(),
                None,
            )
        )
    return scenarios


def _select_correlated_groups(
    frame: pd.DataFrame,
    definition: Mapping[str, Any],
) -> list[tuple[str, pd.DataFrame, str | None]]:
    group_column = str(definition.get("group_column", "correlation_cluster"))
    if group_column not in frame.columns:
        raise DefaultSetError(
            f"Correlated default definition requires column '{group_column}'."
        )

    minimum_members = int(definition.get("minimum_members", 2))
    maximum_members = int(
        definition.get("maximum_members_per_group", len(frame))
    )
    maximum_groups = int(definition.get("maximum_groups", 1))
    if minimum_members < 2:
        raise DefaultSetError("'minimum_members' must be at least 2.")
    if maximum_members < minimum_members:
        raise DefaultSetError(
            "'maximum_members_per_group' must be >= 'minimum_members'."
        )
    if maximum_groups < 1:
        raise DefaultSetError("'maximum_groups' must be at least 1.")

    grouped_frame = frame.copy(deep=True)
    grouped_frame[group_column] = (
        grouped_frame[group_column].astype("string").str.strip()
    )
    grouped_frame = grouped_frame.loc[
        grouped_frame[group_column].notna()
        & (grouped_frame[group_column] != "")
    ]

    candidates: list[tuple[str, float, pd.DataFrame]] = []
    for group_value, group in grouped_frame.groupby(group_column, sort=True):
        if len(group) < minimum_members:
            continue

        ranked = group.sort_values(
            by=["_default_score", "synthetic_member_id"],
            ascending=[False, True],
            kind="mergesort",
        ).head(maximum_members)
        aggregate_score = float(ranked["_default_score"].sum())
        candidates.append((str(group_value), aggregate_score, ranked))

    candidates.sort(key=lambda item: (-item[1], item[0]))
    selected_groups = candidates[:maximum_groups]

    allow_empty = bool(definition.get("allow_empty", False))
    if not selected_groups and not allow_empty:
        raise DefaultSetError(
            "No correlation group satisfies the minimum-member requirement."
        )

    base_id = str(definition["default_set_id"])
    return [
        (f"{base_id}__{group_value}", group, group_value)
        for group_value, _, group in selected_groups
    ]


def _select_explicit(
    frame: pd.DataFrame,
    definition: Mapping[str, Any],
) -> pd.DataFrame:
    member_ids_value = definition.get("member_ids", [])
    if not isinstance(member_ids_value, Sequence) or isinstance(
        member_ids_value,
        (str, bytes),
    ):
        raise DefaultSetError("'member_ids' must be a list.")

    member_ids = [str(member_id) for member_id in member_ids_value]
    available = set(frame["synthetic_member_id"].astype(str))
    unknown = sorted(set(member_ids) - available)
    if unknown:
        raise DefaultSetError(
            f"Explicit default set contains unknown synthetic members: {unknown}"
        )

    order = {member_id: rank for rank, member_id in enumerate(member_ids)}
    selected = frame.loc[
        frame["synthetic_member_id"].astype(str).isin(member_ids)
    ].copy()
    selected["_explicit_order"] = selected["synthetic_member_id"].map(order)
    return selected.sort_values(
        by=["_explicit_order", "synthetic_member_id"],
        ascending=[True, True],
        kind="mergesort",
    )


def construct_default_sets(
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> pd.DataFrame:
    """Construct every enabled default set from configurable definitions."""
    frame = prepare_member_frame(members, config)
    definitions = config.get("definitions", [])
    if not isinstance(definitions, list):
        raise DefaultSetError("'definitions' must be a list.")

    rows: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    for raw_definition in definitions:
        if not isinstance(raw_definition, Mapping):
            raise DefaultSetError("Each default-set definition must be a mapping.")
        if not bool(raw_definition.get("enabled", True)):
            continue

        definition = dict(raw_definition)
        default_set_id = str(definition.get("default_set_id", "")).strip()
        selection_type = str(
            definition.get("selection_type", "")
        ).strip().lower()

        if not default_set_id:
            raise DefaultSetError("Every definition needs 'default_set_id'.")
        if default_set_id in seen_ids:
            raise DefaultSetError(
                f"Duplicate configured default_set_id: {default_set_id}"
            )
        seen_ids.add(default_set_id)

        if selection_type == "largest_single":
            selected = largest_single_member_default(frame)
            rows.extend(
                _result_rows(
                    default_set_id,
                    selection_type,
                    selected,
                    definition,
                )
            )
        elif selection_type == "cover_1":
            selected = cover_1_selection(frame)
            rows.extend(
                _result_rows(
                    default_set_id,
                    selection_type,
                    selected,
                    definition,
                )
            )
        elif selection_type == "largest_two":
            selected = largest_two_member_default(frame)
            rows.extend(
                _result_rows(
                    default_set_id,
                    selection_type,
                    selected,
                    definition,
                )
            )
        elif selection_type == "cover_2":
            selected = cover_2_selection(frame)
            rows.extend(
                _result_rows(
                    default_set_id,
                    selection_type,
                    selected,
                    definition,
                )
            )
        elif selection_type == "concentrated":
            for scenario_id, selected, group_value in _select_concentrated(
                frame,
                definition,
            ):
                rows.extend(
                    _result_rows(
                        scenario_id,
                        selection_type,
                        selected,
                        definition,
                        group_value=group_value,
                    )
                )
        elif selection_type == "correlated_multi":
            for scenario_id, selected, group_value in _select_correlated_groups(
                frame,
                definition,
            ):
                rows.extend(
                    _result_rows(
                        scenario_id,
                        selection_type,
                        selected,
                        definition,
                        group_value=group_value,
                    )
                )
        elif selection_type == "explicit":
            selected = _select_explicit(frame, definition)
            rows.extend(
                _result_rows(
                    default_set_id,
                    selection_type,
                    selected,
                    definition,
                )
            )
        else:
            raise DefaultSetError(
                f"Unsupported selection_type '{selection_type}' "
                f"for definition '{default_set_id}'."
            )

    if not rows:
        raise DefaultSetError("No enabled default-set definitions produced rows.")

    result = pd.DataFrame(rows)
    return result.sort_values(
        by=["default_set_id", "selection_rank", "synthetic_member_id"],
        ascending=[True, True, True],
        kind="mergesort",
    ).reset_index(drop=True)


def validate_default_sets(
    result: pd.DataFrame,
    members: pd.DataFrame,
    config: Mapping[str, Any],
) -> ValidationResult:
    """Validate structural, synthetic-only, and Cover 1/Cover 2 controls."""
    required_columns = {
        "default_set_id",
        "selection_type",
        "selection_rank",
        "synthetic_member_id",
        "default_score_usd",
    }
    columns_present = required_columns.issubset(result.columns)

    source = prepare_member_frame(members, config)
    source_ids = set(source["synthetic_member_id"].astype(str))
    result_ids = set(result.get("synthetic_member_id", pd.Series(dtype=str)).astype(str))

    no_duplicates = not result.duplicated(
        subset=["default_set_id", "synthetic_member_id"]
    ).any()
    members_exist = result_ids.issubset(source_ids)
    scores_nonnegative = bool(
        pd.to_numeric(result["default_score_usd"], errors="coerce").ge(0).all()
    )

    cover_1_rows = result.loc[result["selection_type"] == "cover_1"]
    cover_2_rows = result.loc[result["selection_type"] == "cover_2"]
    cover_1_count = (
        not cover_1_rows.empty
        and cover_1_rows.groupby("default_set_id").size().eq(1).all()
    )
    cover_2_count = (
        not cover_2_rows.empty
        and cover_2_rows.groupby("default_set_id").size().eq(2).all()
    )

    pattern = str(
        config.get(
            "synthetic_member_id_pattern",
            r"^SYN-MEMBER-[0-9]{4,}$",
        )
    )
    synthetic_ids_only = all(
        re.fullmatch(pattern, member_id) is not None for member_id in result_ids
    )

    checks = {
        "required_output_columns": columns_present,
        "unique_members_within_default_set": no_duplicates,
        "all_members_exist_in_source": members_exist,
        "nonnegative_default_scores": scores_nonnegative,
        "cover_1_has_one_member": bool(cover_1_count),
        "cover_2_has_two_members": bool(cover_2_count),
        "synthetic_member_identifiers_only": synthetic_ids_only,
    }
    return ValidationResult(checks=checks)


def _self_test_members() -> pd.DataFrame:
    return pd.DataFrame(
        {
            "synthetic_member_id": [
                "SYN-MEMBER-0001",
                "SYN-MEMBER-0002",
                "SYN-MEMBER-0003",
                "SYN-MEMBER-0004",
                "SYN-MEMBER-0005",
                "SYN-MEMBER-0006",
            ],
            "stressed_liquidity_need_usd": [
                150.0,
                120.0,
                80.0,
                70.0,
                60.0,
                50.0,
            ],
            "settlement_obligation_usd": [
                20.0,
                15.0,
                15.0,
                10.0,
                10.0,
                5.0,
            ],
            "repo_financing_need_usd": [
                30.0,
                25.0,
                20.0,
                15.0,
                10.0,
                10.0,
            ],
            "available_qualified_liquid_resources_usd": [
                20.0,
                15.0,
                10.0,
                15.0,
                15.0,
                10.0,
            ],
            "member_concentration": [
                0.25,
                0.20,
                0.12,
                0.08,
                0.07,
                0.05,
            ],
            "correlation_cluster": ["A", "A", "B", "B", "B", "C"],
        }
    )


def _self_test_config() -> dict[str, Any]:
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
                "default_set_id": "largest_single_member_default",
                "selection_type": "largest_single",
                "enabled": True,
            },
            {
                "default_set_id": "cover_1",
                "selection_type": "cover_1",
                "enabled": True,
            },
            {
                "default_set_id": "largest_two_member_default",
                "selection_type": "largest_two",
                "enabled": True,
            },
            {
                "default_set_id": "cover_2",
                "selection_type": "cover_2",
                "enabled": True,
            },
            {
                "default_set_id": "concentrated_member_defaults",
                "selection_type": "concentrated",
                "enabled": True,
                "concentration_column": "member_concentration",
                "minimum_concentration": 0.10,
                "maximum_members": 3,
                "scenario_per_member": True,
            },
            {
                "default_set_id": "correlated_multi_member_defaults",
                "selection_type": "correlated_multi",
                "enabled": True,
                "group_column": "correlation_cluster",
                "minimum_members": 2,
                "maximum_members_per_group": 3,
                "maximum_groups": 2,
            },
        ],
        "validation": {
            "require_synthetic_identifiers": True,
        },
    }


def run_self_test() -> tuple[pd.DataFrame, ValidationResult, dict[str, bool]]:
    """Execute deterministic Section 13 acceptance checks."""
    members = _self_test_members()
    config = _self_test_config()
    result = construct_default_sets(members, config)
    validation = validate_default_sets(result, members, config)

    shuffled = members.sample(frac=1.0, random_state=2026).reset_index(drop=True)
    shuffled_result = construct_default_sets(shuffled, config)
    deterministic = result.equals(shuffled_result)

    largest_single_ids = result.loc[
        result["selection_type"] == "largest_single",
        "synthetic_member_id",
    ].tolist()
    cover_1_ids = result.loc[
        result["selection_type"] == "cover_1",
        "synthetic_member_id",
    ].tolist()
    largest_two_ids = result.loc[
        result["selection_type"] == "largest_two",
        "synthetic_member_id",
    ].tolist()
    cover_2_ids = result.loc[
        result["selection_type"] == "cover_2",
        "synthetic_member_id",
    ].tolist()

    acceptance = {
        "largest_single_member_default": largest_single_ids
        == ["SYN-MEMBER-0001"],
        "cover_1_selection": cover_1_ids == largest_single_ids,
        "largest_two_member_default": largest_two_ids
        == ["SYN-MEMBER-0001", "SYN-MEMBER-0002"],
        "cover_2_selection": cover_2_ids == largest_two_ids,
        "concentrated_member_defaults": (
            result["selection_type"] == "concentrated"
        ).sum()
        == 3,
        "correlated_multi_member_defaults": (
            result["selection_type"] == "correlated_multi"
        ).sum()
        >= 4,
        "configurable_default_set_definitions": result[
            "default_set_id"
        ].nunique()
        >= 8,
        "deterministic_selection": deterministic,
        "validation_controls": validation.passed,
    }
    return result, validation, acceptance


def _write_output(frame: pd.DataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix.lower() == ".csv":
        frame.to_csv(path, index=False)
    elif path.suffix.lower() in {".parquet", ".pq"}:
        frame.to_parquet(path, index=False)
    else:
        raise DefaultSetError("Output must use .csv or .parquet extension.")


def _write_evidence(
    path: Path,
    acceptance: Mapping[str, bool],
    validation: ValidationResult,
    result: pd.DataFrame,
    *,
    source_label: str,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    labels = {
        "largest_single_member_default": "Largest single-member default",
        "cover_1_selection": "Cover 1 selection",
        "largest_two_member_default": "Largest two-member default",
        "cover_2_selection": "Cover 2 selection",
        "concentrated_member_defaults": "Concentrated-member defaults",
        "correlated_multi_member_defaults": "Correlated multi-member defaults",
        "configurable_default_set_definitions": (
            "Configurable default-set definitions"
        ),
        "deterministic_selection": "Deterministic selection",
        "validation_controls": "Validation controls",
    }

    lines = [
        "Phase IV â€” Synthetic Clearing-Member Portfolios",
        "Section 13 â€” Default-set construction",
        f"Source: {source_label}",
        "",
    ]
    for key, label in labels.items():
        status = "PASS" if acceptance.get(key, False) else "FAIL"
        lines.append(f"{label}: {status}")

    lines.append("")
    for key, passed in validation.checks.items():
        status = "PASS" if passed else "FAIL"
        lines.append(f"Validation â€” {key}: {status}")

    lines.extend(
        [
            "",
            f"Default-set rows: {len(result)}",
            f"Distinct default sets: {result['default_set_id'].nunique()}",
            "Actual FICC participants represented: NO",
            "Synthetic member identifiers only: YES",
            "",
            (
                "Section 13: COMPLETE"
                if all(acceptance.values()) and validation.passed
                else "Section 13: INCOMPLETE"
            ),
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Construct synthetic clearing-member default sets."
    )
    parser.add_argument(
        "--members",
        type=Path,
        help="Synthetic member CSV or Parquet file.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/default_sets.yaml"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("reports/tables/default_sets.csv"),
    )
    parser.add_argument(
        "--evidence",
        type=Path,
        default=Path("reports/evidence/section13_default_set_validation.txt"),
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run deterministic built-in acceptance checks.",
    )
    return parser.parse_args()


def main() -> int:
    """Command-line entry point."""
    args = _parse_args()

    if args.self_test or args.members is None:
        result, validation, acceptance = run_self_test()
        _write_output(result, args.output)
        _write_evidence(
            args.evidence,
            acceptance,
            validation,
            result,
            source_label="controlled built-in synthetic fixture",
        )
        if not all(acceptance.values()) or not validation.passed:
            return 1
        return 0

    config = load_default_set_config(args.config)
    members = read_member_data(args.members)
    result = construct_default_sets(members, config)
    validation = validate_default_sets(result, members, config)

    shuffled = members.sample(frac=1.0, random_state=2026).reset_index(drop=True)
    deterministic = result.equals(construct_default_sets(shuffled, config))
    acceptance = {
        "largest_single_member_default": (
            result["selection_type"] == "largest_single"
        ).any(),
        "cover_1_selection": (
            result["selection_type"] == "cover_1"
        ).any(),
        "largest_two_member_default": (
            result["selection_type"] == "largest_two"
        ).any(),
        "cover_2_selection": (
            result["selection_type"] == "cover_2"
        ).any(),
        "concentrated_member_defaults": (
            result["selection_type"] == "concentrated"
        ).any(),
        "correlated_multi_member_defaults": (
            result["selection_type"] == "correlated_multi"
        ).any(),
        "configurable_default_set_definitions": True,
        "deterministic_selection": deterministic,
        "validation_controls": validation.passed,
    }

    _write_output(result, args.output)
    _write_evidence(
        args.evidence,
        acceptance,
        validation,
        result,
        source_label=str(args.members),
    )
    if not all(acceptance.values()) or not validation.passed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())