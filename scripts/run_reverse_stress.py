"""Run Phase VI, Section 23 reverse stress testing."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from copy import deepcopy
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd
import yaml

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.scenarios.reverse_stress import (  # noqa: E402
    ReverseStressError,
    dataframe_digest,
    prepare_control,
    run_reverse_stress,
)
from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    load_config as load_haircut_config,
)
from ficc_liquidity.stress.collateral_haircut_stress import (  # noqa: E402
    run_model as run_haircut_model,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    calculate_repo_funding_stress,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    load_config as load_repo_config,
)
from ficc_liquidity.stress.repo_funding_stress import (  # noqa: E402
    load_settings as load_repo_settings,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    TreasuryYieldShockModel,
    load_stress_config,
)


def parse_args() -> argparse.Namespace:
    """Parse controlled Section 23 arguments."""
    parser = argparse.ArgumentParser(description="Run Phase VI Section 23 reverse stress testing.")
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "reverse_stress_testing.yaml",
    )
    parser.add_argument("--integrated-results", type=Path, default=None)
    parser.add_argument("--baseline-cashflows", type=Path, default=None)
    parser.add_argument("--members", type=Path, default=None)
    parser.add_argument("--treasury-positions", type=Path, default=None)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "reports" / "tables",
    )
    parser.add_argument(
        "--evidence-dir",
        type=Path,
        default=ROOT / "reports" / "evidence",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT / "data" / "manifests" / "reverse_stress_testing_manifest.csv",
    )
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReverseStressError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def load_config(path: Path) -> dict[str, Any]:
    """Load the controlled Section 23 configuration."""
    if not path.exists():
        raise ReverseStressError(f"Configuration does not exist: {path}")
    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    return _mapping(loaded, "Configuration")


def read_table(path: Path) -> pd.DataFrame:
    """Read CSV or Parquet data."""
    if not path.exists():
        raise ReverseStressError(f"Input table does not exist: {path}")
    if path.suffix.lower() == ".csv":
        return pd.read_csv(path)
    if path.suffix.lower() in {".parquet", ".pq"}:
        return pd.read_parquet(path)
    raise ReverseStressError(f"Unsupported input format: {path.suffix}")


def discover_input(root: Path, candidates: list[str]) -> Path | None:
    """Return the first existing candidate."""
    for candidate in candidates:
        path = root / candidate
        if path.exists():
            return path
    return None


def _candidate_list(source: dict[str, Any], key: str) -> list[str]:
    raw = source.get(key)
    if not isinstance(raw, list) or not raw:
        raise ReverseStressError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def required_input(
    supplied: Path | None,
    source: dict[str, Any],
    key: str,
    label: str,
) -> Path:
    """Resolve a required source table."""
    path = supplied or discover_input(ROOT, _candidate_list(source, key))
    if path is None:
        raise ReverseStressError(
            f"{label} was not found. Run the required prior section or supply the path."
        )
    return path


def file_hash(path: Path) -> str:
    """Return a file SHA-256 digest."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_frame(
    frame: pd.DataFrame,
    stem: Path,
    *,
    write_csv: bool,
    write_parquet: bool,
) -> list[Path]:
    """Write a controlled output frame."""
    written: list[Path] = []
    stem.parent.mkdir(parents=True, exist_ok=True)
    if write_csv:
        csv_path = stem.with_suffix(".csv")
        frame.to_csv(csv_path, index=False)
        written.append(csv_path)
    if write_parquet:
        parquet_path = stem.with_suffix(".parquet")
        try:
            frame.to_parquet(parquet_path, index=False)
            written.append(parquet_path)
        except (ImportError, ModuleNotFoundError, ValueError) as exc:
            print(f"Parquet output skipped: {exc}")
    return written


def _series_by_member(
    frame: pd.DataFrame,
    *,
    value_column: str,
    expected_member_ids: set[str],
    label: str,
) -> pd.Series:
    required = {"member_id", value_column}
    missing = sorted(required - set(frame.columns))
    if missing:
        raise ReverseStressError(f"{label} output is missing columns: {missing}")
    selected = frame[["member_id", value_column]].copy()
    selected["member_id"] = selected["member_id"].astype(str)
    if selected["member_id"].duplicated().any():
        raise ReverseStressError(f"{label} output contains duplicate member rows.")
    selected[value_column] = pd.to_numeric(selected[value_column], errors="coerce")
    if selected[value_column].isna().any():
        raise ReverseStressError(f"{label} output contains invalid values.")
    actual_ids = set(selected["member_id"])
    if actual_ids != expected_member_ids:
        missing_ids = sorted(expected_member_ids - actual_ids)
        extra_ids = sorted(actual_ids - expected_member_ids)
        raise ReverseStressError(
            f"{label} member coverage differs from control. "
            f"Missing={missing_ids}; extra={extra_ids}"
        )
    return selected.set_index("member_id")[value_column].astype(float).sort_index()


class ExactComponentModels:
    """Reuse Sections 15-17 to generate exact member component vectors."""

    def __init__(
        self,
        *,
        control: pd.DataFrame,
        treasury_positions: pd.DataFrame,
        baseline_cashflows: pd.DataFrame,
        members: pd.DataFrame,
        section23_config: dict[str, Any],
    ) -> None:
        self.control = control
        self.member_ids = set(control["member_id"].astype(str))
        self.treasury_positions = treasury_positions
        self.baseline_cashflows = baseline_cashflows
        self.members = members
        self.section23_config = section23_config
        source = _mapping(section23_config.get("source"), "source")
        self.synthetic_id_pattern = str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$"))

        self.treasury_config = load_stress_config(ROOT / str(source["treasury_config"]))
        self.repo_config = load_repo_config(ROOT / str(source["repo_funding_config"]))
        self.haircut_config = load_haircut_config(ROOT / str(source["haircut_config"]))

        search = _mapping(section23_config.get("search"), "search")
        yield_search = _mapping(search.get("yield_shock"), "search.yield_shock")
        self.include_market_impact = bool(yield_search.get("include_market_impact", False))
        haircut_search = _mapping(
            search.get("haircut_increase"),
            "search.haircut_increase",
        )
        maximum_haircut = haircut_search.get("maximum_haircut_rate", 0.95)
        if isinstance(maximum_haircut, bool) or not isinstance(maximum_haircut, (int, float)):
            raise ReverseStressError("maximum_haircut_rate must be numeric.")
        self.maximum_haircut_rate = float(maximum_haircut)

        self._yield_cache: dict[float, pd.Series] = {}
        self._rollover_cache: dict[float, pd.Series] = {}
        self._haircut_cache: dict[float, pd.Series] = {}

    @staticmethod
    def _key(value: float) -> float:
        return round(float(value), 12)

    def yield_losses(self, shock_bp: float) -> pd.Series:
        """Run an exact parallel Treasury shock."""
        if shock_bp < 0.0:
            raise ReverseStressError("Yield shock cannot be negative.")
        key = self._key(shock_bp)
        cached = self._yield_cache.get(key)
        if cached is not None:
            return cached.copy()

        config = deepcopy(self.treasury_config)
        config["input"]["required_member_id_pattern"] = self.synthetic_id_pattern
        if not self.include_market_impact:
            config["market_impact"]["enabled"] = False
        scenario = {
            "name": "section23_reverse_parallel_yield",
            "family": "parallel_reverse_stress",
            "type": "parallel",
            "shock_bp": float(shock_bp),
            "enabled": True,
        }
        summary = (
            TreasuryYieldShockModel(config)
            .run(
                self.treasury_positions,
                scenarios=[scenario],
            )
            .member_summary
        )
        series = _series_by_member(
            summary,
            value_column="treasury_loss_usd",
            expected_member_ids=self.member_ids,
            label="Treasury reverse stress",
        )
        self._yield_cache[key] = series
        return series.copy()

    def rollover_needs(self, failure_rate: float) -> pd.Series:
        """Run an isolated exact repo rollover-failure scenario."""
        if not 0.0 <= failure_rate <= 1.0:
            raise ReverseStressError("Rollover-failure rate must be between zero and one.")
        key = self._key(failure_rate)
        cached = self._rollover_cache.get(key)
        if cached is not None:
            return cached.copy()

        config = deepcopy(self.repo_config)
        horizon = int(config["assumptions"]["baseline_liquidity_horizon_hours"])
        config["scenarios"] = [
            {
                "name": "section23_reverse_rollover",
                "enabled": True,
                "severity_rank": 1,
                "sofr_spike_bp": 0.0,
                "funding_spread_increase_bp": 0.0,
                "repo_rollover_failure_rate": float(failure_rate),
                "lender_withdrawal_rate": 0.0,
                "refinancing_horizon_hours": horizon,
                "collateral_haircut_increase": 0.0,
                "collateral_call_rate": 0.0,
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "funding_dependency_multiplier": 0.0,
                "max_effective_unavailability_rate": 1.0,
            }
        ]
        settings = load_repo_settings(config)
        _, member_summary, _ = calculate_repo_funding_stress(
            self.baseline_cashflows,
            self.members,
            settings,
        )
        series = _series_by_member(
            member_summary,
            value_column="repo_rollover_failure_outflow_usd",
            expected_member_ids=self.member_ids,
            label="Repo rollover reverse stress",
        )
        self._rollover_cache[key] = series
        return series.copy()

    def haircut_requirements(self, increase_rate: float) -> pd.Series:
        """Run an isolated exact additive haircut-increase scenario."""
        if not 0.0 <= increase_rate < 1.0:
            raise ReverseStressError("Haircut increase must be in [0, 1).")
        key = self._key(increase_rate)
        cached = self._haircut_cache.get(key)
        if cached is not None:
            return cached.copy()

        config = deepcopy(self.haircut_config)
        bucket_names = list(config["maturity_buckets"])
        config["scenarios"] = [
            {
                "name": "section23_reverse_haircut",
                "enabled": True,
                "severity_rank": 1,
                "stress_multiplier": 1.0,
                "additive_haircut_rate": float(increase_rate),
                "bucket_addons": {name: 0.0 for name in bucket_names},
                "concentration_threshold": 1.0,
                "concentration_multiplier": 0.0,
                "additional_collateral_call_rate": 0.0,
                "inventory_availability_rate": 1.0,
                "maximum_haircut_rate": self.maximum_haircut_rate,
            }
        ]
        result = run_haircut_model(
            self.members,
            self.baseline_cashflows,
            config,
        )
        series = _series_by_member(
            result.member_summary,
            value_column="additional_collateral_requirement_total_usd",
            expected_member_ids=self.member_ids,
            label="Haircut reverse stress",
        )
        self._haircut_cache[key] = series
        return series.copy()


def _write_evidence_markdown(
    path: Path,
    evidence: dict[str, object],
    thresholds: pd.DataFrame,
    combinations: pd.DataFrame,
) -> None:
    checks = cast(dict[str, bool], evidence["checks"])
    lines = [
        "# Section 23 — Reverse Stress Testing",
        "",
        f"- Generated at: `{evidence['generated_at_utc']}`",
        f"- Run type: `{evidence['run_type']}`",
        f"- Model version: `{evidence['model_version']}`",
        f"- Deterministic reproduction: `{evidence['deterministic_reproduction']}`",
        f"- Final decision: `{evidence['final_decision']}`",
        "",
        "## Validation gates",
        "",
        "| Gate | Result |",
        "|---|---|",
    ]
    lines.extend(
        f"| {name.replace('_', ' ')} | {'PASS' if passed else 'FAIL'} |"
        for name, passed in checks.items()
    )
    lines.extend(
        [
            "",
            "## Reverse-stress thresholds",
            "",
            "| Test | Status | Minimum threshold | Unit | Binding entity | LCR | Shortfall (USD) |",
            "|---|---|---:|---|---|---:|---:|",
        ]
    )
    for _, row in thresholds.iterrows():
        threshold = row["minimum_threshold"]
        threshold_text = f"{float(threshold):.8f}" if pd.notna(threshold) else "not reached"
        lines.append(
            "| {test} | {status} | {threshold} | {unit} | {entity} | "
            "{lcr:.6f} | {shortfall:,.2f} |".format(
                test=row["test_name"],
                status=row["search_status"],
                threshold=threshold_text,
                unit=row["parameter_unit"],
                entity=row["breached_entity_id"],
                lcr=float(row["liquidity_coverage_ratio"]),
                shortfall=float(row["liquidity_shortfall_usd"]),
            )
        )
    lines.extend(
        [
            "",
            "## Most vulnerable member combination",
            "",
        ]
    )
    if combinations.empty:
        lines.append("No member-combination result was produced.")
    else:
        row = combinations.iloc[0]
        lines.extend(
            [
                f"- Combination: `{row['combination_id']}`",
                f"- Combined severity: `{float(row['combined_severity']):.8f}`",
                f"- Requirement: `${float(row['stressed_liquidity_requirement_usd']):,.2f}`",
                f"- Available resources: `${float(row['available_resources_usd']):,.2f}`",
                f"- LCR: `{float(row['liquidity_coverage_ratio']):.6f}`",
                f"- Shortfall: `${float(row['liquidity_shortfall_usd']):,.2f}`",
            ]
        )
    lines.extend(
        [
            "",
            "## Interpretation controls",
            "",
            "- All members are fictional synthetic records.",
            "- No actual FICC participant is represented or inferred.",
            "- The combined path scales parallel yield shock, rollover failure, and "
            "additive haircut increase with one normalized severity parameter.",
            "- Member-combination requirements and resources are additive; cross-member "
            "netting is not assumed.",
            "- Isolated yield testing disables market impact by default so the solved "
            "threshold is attributable to the yield shock itself.",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def write_manifest(
    manifest_path: Path,
    artifacts: list[tuple[Path, str, int | None]],
) -> None:
    """Write Section 23 source-lineage and output-integrity metadata."""
    generated_at = datetime.now(UTC).isoformat()
    rows = [
        {
            "section": 23,
            "artifact_path": str(path.resolve()),
            "artifact_name": path.name,
            "value_class": value_class,
            "row_count": "" if row_count is None else row_count,
            "sha256": file_hash(path),
            "generated_at_utc": generated_at,
            "actual_ficc_participant": False,
            "participant_level_inference": False,
        }
        for path, value_class, row_count in artifacts
    ]
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame.from_records(rows).to_csv(manifest_path, index=False)


def main() -> int:
    """Execute Section 23 and write controlled artifacts."""
    args = parse_args()
    config = load_config(args.config)
    source = _mapping(config.get("source"), "source")
    validation = _mapping(config.get("validation"), "validation")
    output = _mapping(config.get("output"), "output")

    integrated_path = required_input(
        args.integrated_results,
        source,
        "integrated_member_result_candidates",
        "Section 19 integrated member results",
    )
    baseline_path = required_input(
        args.baseline_cashflows,
        source,
        "baseline_cashflow_candidates",
        "Section 14 baseline cash flows",
    )
    members_path = required_input(
        args.members,
        source,
        "member_profile_candidates",
        "Synthetic member profiles",
    )
    treasury_positions_path = required_input(
        args.treasury_positions,
        source,
        "treasury_position_candidates",
        "Section 19 Treasury adapter positions",
    )

    integrated_results = read_table(integrated_path)
    baseline_cashflows = read_table(baseline_path)
    members = read_table(members_path)
    treasury_positions = read_table(treasury_positions_path)

    control = prepare_control(
        integrated_results,
        control_scenario_name=str(source.get("control_scenario_name", "control")),
        synthetic_id_pattern=str(source.get("synthetic_id_pattern", r"^SYN-MBR-[0-9]{4}$")),
        lcr_minimum_ratio=float(validation["lcr_minimum_ratio"]),
        tolerance_usd=float(validation["liquidity_tolerance_usd"]),
    )
    if args.smoke:
        smoke_count = min(8, len(control))
        selected_ids = set(control.head(smoke_count)["member_id"].astype(str))
        control = control.loc[control["member_id"].astype(str).isin(selected_ids)].copy()
        baseline_cashflows = baseline_cashflows.loc[
            baseline_cashflows["member_id"].astype(str).isin(selected_ids)
        ].copy()
        members = members.loc[members["member_id"].astype(str).isin(selected_ids)].copy()
        treasury_positions = treasury_positions.loc[
            treasury_positions["member_id"].astype(str).isin(selected_ids)
        ].copy()

    models = ExactComponentModels(
        control=control,
        treasury_positions=treasury_positions,
        baseline_cashflows=baseline_cashflows,
        members=members,
        section23_config=config,
    )
    result = run_reverse_stress(
        control=control,
        yield_evaluator=models.yield_losses,
        rollover_evaluator=models.rollover_needs,
        haircut_evaluator=models.haircut_requirements,
        config=config,
    )

    second_models = ExactComponentModels(
        control=control,
        treasury_positions=treasury_positions,
        baseline_cashflows=baseline_cashflows,
        members=members,
        section23_config=config,
    )
    reproduced = run_reverse_stress(
        control=control,
        yield_evaluator=second_models.yield_losses,
        rollover_evaluator=second_models.rollover_needs,
        haircut_evaluator=second_models.haircut_requirements,
        config=config,
    )
    deterministic = (
        dataframe_digest(result.thresholds) == dataframe_digest(reproduced.thresholds)
        and dataframe_digest(result.member_details) == dataframe_digest(reproduced.member_details)
        and dataframe_digest(result.combination_ranking)
        == dataframe_digest(reproduced.combination_ranking)
    )
    checks = dict(result.checks)
    checks["deterministic_reproduction"] = deterministic
    checks["exact_section15_17_model_reuse"] = True
    checks["all_input_members_covered"] = set(control["member_id"].astype(str)) == set(
        result.member_details["member_id"].astype(str)
    )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    write_csv = bool(output.get("write_csv", True))
    write_parquet = bool(output.get("write_parquet", True))
    written: list[tuple[Path, str, int | None]] = []

    outputs = [
        (
            result.thresholds,
            args.output_dir / "reverse_stress_thresholds",
            "modeled",
        ),
        (
            result.member_details,
            args.output_dir / "reverse_stress_member_details",
            "modeled",
        ),
        (
            result.combination_ranking,
            args.output_dir / "reverse_stress_member_combination_ranking",
            "synthetic",
        ),
        (
            result.search_trace,
            args.output_dir / "reverse_stress_search_trace",
            "modeled",
        ),
    ]
    for frame, stem, value_class in outputs:
        paths = write_frame(
            frame,
            stem,
            write_csv=write_csv,
            write_parquet=write_parquet,
        )
        written.extend((path, value_class, len(frame)) for path in paths)

    generated_at = datetime.now(UTC).isoformat()
    final_decision = "PASS" if all(checks.values()) else "FAIL"
    evidence: dict[str, object] = {
        "section": 23,
        "model_version": str(config.get("model_version", "section-23-v1")),
        "generated_at_utc": generated_at,
        "run_type": "smoke" if args.smoke else "full",
        "final_decision": final_decision,
        "deterministic_reproduction": deterministic,
        "checks": checks,
        "input_paths": {
            "integrated_results": str(integrated_path.resolve()),
            "baseline_cashflows": str(baseline_path.resolve()),
            "members": str(members_path.resolve()),
            "treasury_positions": str(treasury_positions_path.resolve()),
        },
        "thresholds": result.thresholds.replace([math.inf, -math.inf], None).to_dict(
            orient="records"
        ),
        "most_vulnerable_member_combination": (
            {}
            if result.combination_ranking.empty
            else result.combination_ranking.iloc[0].replace([math.inf, -math.inf], None).to_dict()
        ),
        "actual_ficc_participant": False,
        "participant_level_inference": False,
    }
    evidence_json = args.evidence_dir / "section23_reverse_stress_testing.json"
    evidence_markdown = args.evidence_dir / "section23_reverse_stress_testing.md"
    evidence_json.write_text(
        json.dumps(evidence, indent=2, sort_keys=True, default=str),
        encoding="utf-8",
    )
    _write_evidence_markdown(
        evidence_markdown,
        evidence,
        result.thresholds,
        result.combination_ranking,
    )
    written.extend(
        [
            (evidence_json, "modeled", None),
            (evidence_markdown, "modeled", None),
            (args.config, "assumed", None),
            (integrated_path, "modeled", len(integrated_results)),
            (baseline_path, "modeled", len(baseline_cashflows)),
            (members_path, "synthetic", len(members)),
            (treasury_positions_path, "synthetic", len(treasury_positions)),
        ]
    )
    write_manifest(args.manifest, written)

    print("")
    print("SECTION 23 REVERSE STRESS TESTING")
    print(result.thresholds.to_string(index=False))
    print("")
    if result.combination_ranking.empty:
        print("Most vulnerable member combination: not available")
    else:
        top = result.combination_ranking.iloc[0]
        print(f"Most vulnerable member combination: {top['combination_id']}")
        print(f"Combined severity: {float(top['combined_severity']):.8f}")
        print(f"LCR: {float(top['liquidity_coverage_ratio']):.6f}")
        print(f"Shortfall USD: {float(top['liquidity_shortfall_usd']):,.2f}")
    print("")
    for name, passed in checks.items():
        print(f"{name}: {'PASS' if passed else 'FAIL'}")
    print(f"FINAL DECISION: {final_decision}")
    return 0 if final_decision == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
