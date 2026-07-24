"""Run Phase VI, Section 20 historical scenario replay."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from ficc_liquidity.scenarios.historical_scenarios import (  # noqa: E402
    HistoricalScenarioError,
    build_historical_treasury_scenarios,
    build_single_historical_integrated_config,
    calibrate_historical_scenarios,
    choose_component_scenario,
    load_historical_windows,
    load_replay_settings,
    load_yaml,
)
from ficc_liquidity.stress.integrated_stress import (  # noqa: E402
    dataframe_digest,
    read_table,
    run_integrated_stress,
)
from ficc_liquidity.stress.treasury_yield_shock import (  # noqa: E402
    TreasuryYieldShockModel,
    load_stress_config,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Replay empirically calibrated historical liquidity scenarios."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "configs" / "historical_scenario_replay.yaml",
    )
    parser.add_argument("--smoke", action="store_true")
    return parser.parse_args()


def _mapping(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HistoricalScenarioError(f"{label} must be a YAML mapping.")
    return cast(dict[str, Any], value)


def _candidate_list(mapping: dict[str, Any], key: str) -> list[str]:
    raw = mapping.get(key)
    if not isinstance(raw, list) or not raw:
        raise HistoricalScenarioError(f"source.{key} must be a nonempty list.")
    return [str(value) for value in raw]


def discover_input(candidates: list[str]) -> Path:
    for candidate in candidates:
        path = ROOT / candidate
        if path.exists():
            return path
    raise HistoricalScenarioError(f"No controlled input exists among: {candidates}")


def read_analytical_inputs(paths: tuple[Path, ...]) -> pd.DataFrame:
    frames: list[pd.DataFrame] = []
    for path in paths:
        if not path.exists():
            continue
        if path.suffix.lower() in {".parquet", ".pq"}:
            frames.append(pd.read_parquet(path))
        elif path.suffix.lower() == ".csv":
            frames.append(pd.read_csv(path, low_memory=False))
        else:
            raise HistoricalScenarioError(f"Unsupported analytical input: {path}")
    if not frames:
        raise HistoricalScenarioError("No Section 8 analytical input files were found.")
    return pd.concat(frames, ignore_index=True, sort=False)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_frame(frame: pd.DataFrame, stem: Path, csv: bool, parquet: bool) -> list[Path]:
    written: list[Path] = []
    if csv:
        csv_path = stem.with_suffix(".csv")
        frame.to_csv(csv_path, index=False)
        written.append(csv_path)
    if parquet:
        parquet_path = stem.with_suffix(".parquet")
        try:
            frame.to_parquet(parquet_path, index=False)
            written.append(parquet_path)
        except (ImportError, ModuleNotFoundError, ValueError) as exc:
            print(f"Parquet output skipped: {exc}")
    return written


def _annotate(
    frame: pd.DataFrame,
    metric_row: pd.Series,
    funding_name: str,
    haircut_name: str,
    settlement_name: str,
) -> pd.DataFrame:
    result = frame.copy(deep=True)
    result["historical_window_name"] = str(metric_row["scenario_name"])
    result["historical_start_date"] = metric_row["start_date"]
    result["historical_peak_date"] = metric_row["peak_date"]
    result["historical_end_date"] = metric_row["end_date"]
    result["empirical_severity_score"] = float(metric_row["empirical_severity_score"])
    result["empirical_severity_rank"] = int(metric_row["empirical_severity_rank"])
    result["selected_funding_scenario"] = funding_name
    result["selected_haircut_scenario"] = haircut_name
    result["selected_settlement_scenario"] = settlement_name
    result["historical_value_class"] = "observed_market_conditions_on_synthetic_members"
    return result


def run() -> int:
    args = parse_args()
    config = load_yaml(args.config)
    settings = load_replay_settings(config, ROOT)
    source = _mapping(config.get("source"), "source")
    validation = _mapping(config.get("validation"), "validation")

    catalog = load_yaml(settings.scenario_catalog)
    windows = load_historical_windows(catalog)
    if args.smoke:
        windows = windows[-2:]

    treasury_config_path = ROOT / str(source["treasury_yield_config"])
    integrated_config_path = ROOT / str(source["integrated_stress_config"])
    treasury_config = load_stress_config(treasury_config_path)
    treasury_input = treasury_config.get("input")
    if isinstance(treasury_input, dict):
        treasury_input["required_member_id_pattern"] = r"^SYN-MBR-[0-9]{4}$"
    integrated_config = load_yaml(integrated_config_path)

    analytical = read_analytical_inputs(settings.analytical_inputs)
    calibration = calibrate_historical_scenarios(
        analytical,
        windows,
        catalog,
        treasury_config,
        settings,
    )

    baseline_path = discover_input(_candidate_list(source, "baseline_summary_candidates"))
    funding_path = discover_input(_candidate_list(source, "funding_summary_candidates"))
    haircut_path = discover_input(_candidate_list(source, "haircut_summary_candidates"))
    settlement_path = discover_input(_candidate_list(source, "settlement_fail_cashflow_candidates"))
    treasury_positions_path = discover_input(
        _candidate_list(source, "treasury_position_candidates")
    )

    baseline = read_table(baseline_path)
    funding = read_table(funding_path)
    haircut = read_table(haircut_path)
    settlement = read_table(settlement_path)
    treasury_positions = read_table(treasury_positions_path)

    treasury_scenarios = build_historical_treasury_scenarios(calibration.treasury_bucket_shocks)
    if not treasury_scenarios:
        raise HistoricalScenarioError("No historical Treasury scenarios could be derived.")
    treasury_result = TreasuryYieldShockModel(treasury_config).run(
        treasury_positions,
        treasury_scenarios,
    )

    member_outputs: list[pd.DataFrame] = []
    summary_outputs: list[pd.DataFrame] = []
    control_outputs: list[pd.DataFrame] = []
    selection_rows: list[dict[str, object]] = []
    integrated_checks: dict[str, dict[str, bool]] = {}

    available_treasury = set(treasury_result.member_summary["scenario_name"].astype(str))
    for _, metric_row in calibration.scenario_metrics.iterrows():
        scenario_id = str(metric_row["scenario_id"])
        if scenario_id not in available_treasury:
            continue
        score = float(metric_row["empirical_severity_score"])
        funding_name, funding_rank = choose_component_scenario(funding, score)
        haircut_name, haircut_rank = choose_component_scenario(haircut, score)
        settlement_name, settlement_rank = choose_component_scenario(settlement, score)
        scenario_config = build_single_historical_integrated_config(
            integrated_config,
            scenario_id,
            funding_name,
            haircut_name,
            settlement_name,
            score,
            settings.model_version,
        )
        result = run_integrated_stress(
            baseline,
            funding,
            haircut,
            treasury_result.member_summary,
            settlement,
            scenario_config,
        )
        integrated_checks[scenario_id] = dict(result.checks)
        member_outputs.append(
            _annotate(
                result.member_results,
                metric_row,
                funding_name,
                haircut_name,
                settlement_name,
            )
        )
        summary_outputs.append(
            _annotate(
                result.scenario_summary,
                metric_row,
                funding_name,
                haircut_name,
                settlement_name,
            )
        )
        control_outputs.append(
            _annotate(
                result.double_count_controls,
                metric_row,
                funding_name,
                haircut_name,
                settlement_name,
            )
        )
        selection_rows.append(
            {
                "scenario_id": scenario_id,
                "empirical_severity_score": score,
                "empirical_severity_rank": int(metric_row["empirical_severity_rank"]),
                "funding_scenario_name": funding_name,
                "funding_severity_rank": funding_rank,
                "haircut_scenario_name": haircut_name,
                "haircut_severity_rank": haircut_rank,
                "settlement_scenario_name": settlement_name,
                "settlement_severity_rank": settlement_rank,
                "treasury_scenario_name": scenario_id,
                "mapping_method": "nearest_validated_component_severity",
            }
        )

    if not member_outputs:
        raise HistoricalScenarioError("No historical scenario completed integrated replay.")

    member_results = pd.concat(member_outputs, ignore_index=True).sort_values(
        ["empirical_severity_rank", "member_id"], kind="stable"
    )
    summaries = pd.concat(summary_outputs, ignore_index=True).sort_values(
        "empirical_severity_rank", kind="stable"
    )
    controls = pd.concat(control_outputs, ignore_index=True).sort_values(
        ["empirical_severity_rank", "member_id"], kind="stable"
    )
    selections = pd.DataFrame.from_records(selection_rows).sort_values(
        "empirical_severity_rank", kind="stable"
    )

    identity_expected = member_results[
        [
            "settlement_liquidity_need_usd",
            "repo_rollover_need_usd",
            "incremental_funding_cost_usd",
            "additional_haircut_requirement_usd",
            "treasury_liquidation_loss_usd",
            "settlement_fail_requirement_usd",
            "concentration_adjustment_usd",
            "operational_liquidity_buffer_usd",
        ]
    ].sum(axis=1)
    tolerance = float(validation.get("reconciliation_tolerance_usd", 0.01))
    no_lookahead = True
    if not calibration.factor_observations.empty:
        end_dates = calibration.scenario_metrics.set_index("scenario_id")["end_date"]
        observation_end = calibration.factor_observations["scenario_id"].map(end_dates)
        no_lookahead = bool(
            (
                pd.to_datetime(calibration.factor_observations["observation_date"])
                <= pd.to_datetime(observation_end)
            ).all()
        )
    checks = {
        "selected_windows_loaded": len(calibration.scenario_metrics) == len(windows),
        "observed_factor_replay_available": bool(
            (calibration.scenario_metrics["available_factor_count"] > 0).all()
        ),
        "treasury_bucket_shocks_available": bool(
            calibration.treasury_bucket_shocks["scenario_id"].nunique() > 0
        ),
        "integrated_replay_completed": len(summaries) > 0,
        "all_integrated_checks_pass": all(
            all(scenario_checks.values()) for scenario_checks in integrated_checks.values()
        ),
        "stressed_requirement_identity": bool(
            (identity_expected - member_results["stressed_liquidity_requirement_usd"])
            .abs()
            .le(tolerance)
            .all()
        ),
        "double_count_controls_pass": bool(
            controls["double_count_control_pass"].astype(bool).all()
        ),
        "no_lookahead": no_lookahead,
        "synthetic_members_only": bool(
            not member_results["actual_ficc_participant"].astype(bool).any()
            and not member_results["participant_level_inference"].astype(bool).any()
        ),
        "unique_scenario_member_keys": not bool(
            member_results.duplicated(["scenario_name", "member_id"]).any()
        ),
    }

    settings.output_directory.mkdir(parents=True, exist_ok=True)
    settings.evidence_directory.mkdir(parents=True, exist_ok=True)
    settings.manifest_path.parent.mkdir(parents=True, exist_ok=True)

    outputs: list[Path] = []
    frames = {
        "historical_scenario_metrics": calibration.scenario_metrics,
        "historical_treasury_bucket_shocks": calibration.treasury_bucket_shocks,
        "historical_factor_observations": calibration.factor_observations,
        "historical_component_selections": selections,
        "historical_scenario_member_results": member_results,
        "historical_scenario_summary": summaries,
        "historical_scenario_double_count_controls": controls,
    }
    for name, frame in frames.items():
        outputs.extend(
            write_frame(
                frame,
                settings.output_directory / name,
                settings.write_csv,
                settings.write_parquet,
            )
        )

    generated_at = datetime.now(UTC).isoformat()
    evidence = {
        "section": 20,
        "model_version": settings.model_version,
        "generated_at_utc": generated_at,
        "smoke_mode": bool(args.smoke),
        "historical_window_count": len(windows),
        "completed_replay_count": len(summaries),
        "member_result_rows": len(member_results),
        "checks": checks,
        "integrated_checks": integrated_checks,
        "digests": {name: dataframe_digest(frame) for name, frame in frames.items()},
        "sources": {
            "scenario_catalog": str(settings.scenario_catalog),
            "analytical_inputs": [str(path) for path in settings.analytical_inputs],
            "baseline": str(baseline_path),
            "funding": str(funding_path),
            "haircut": str(haircut_path),
            "settlement": str(settlement_path),
            "treasury_positions": str(treasury_positions_path),
        },
    }
    evidence_json = settings.evidence_directory / "section20_historical_scenarios.json"
    evidence_json.write_text(json.dumps(evidence, indent=2, default=str), encoding="utf-8")
    outputs.append(evidence_json)
    evidence_md = settings.evidence_directory / "section20_historical_scenarios.md"
    evidence_md.write_text(
        "\n".join(
            [
                "# Section 20 Historical Scenarios Evidence",
                "",
                f"Generated: `{generated_at}`",
                f"Historical windows replayed: `{len(summaries)}`",
                f"Synthetic member rows: `{len(member_results)}`",
                "",
                "## Validation checks",
                "",
                *[f"- {name}: {'PASS' if passed else 'FAIL'}" for name, passed in checks.items()],
                "",
                "No actual FICC participant data or participant-level inference is used.",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    outputs.append(evidence_md)

    manifest_rows: list[dict[str, object]] = []
    for path in outputs:
        manifest_rows.append(
            {
                "section": 20,
                "artifact_path": str(path.resolve()),
                "artifact_name": path.name,
                "sha256": file_sha256(path),
                "generated_at_utc": generated_at,
                "actual_ficc_participant": False,
                "participant_level_inference": False,
            }
        )
    pd.DataFrame.from_records(manifest_rows).to_csv(settings.manifest_path, index=False)

    print("Section 20 historical scenario replay")
    print(f"Windows requested: {len(windows)}")
    print(f"Windows completed: {len(summaries)}")
    for name, passed in checks.items():
        print(f"{name}: {'PASS' if passed else 'FAIL'}")
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    raise SystemExit(run())
