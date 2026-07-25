"""Section 28 uncertainty and limitations assessment.

This module provides a transparent uncertainty register, one-at-a-time stress
analysis, and a bounded joint Monte Carlo envelope. It is a research validation
utility, not a production capital or liquidity model.
"""

from __future__ import annotations

import argparse
import json
import math
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, overload

import matplotlib.pyplot as plt
import numpy as np
import numpy.typing as npt
import pandas as pd
import yaml

# Use a non-interactive backend for CI and headless Windows execution.
plt.switch_backend("Agg")

REQUIRED_CATEGORIES: tuple[str, ...] = (
    "aggregate_data_uncertainty",
    "synthetic_allocation_uncertainty",
    "scenario_selection_uncertainty",
    "parameter_uncertainty",
    "missing_intraday_information",
    "participant_level_data_limitations",
    "operational_legal_assumptions",
    "simplified_liquidation_functions",
)


@dataclass(frozen=True)
class TriangularRange:
    """Triangular uncertainty range."""

    minimum: float
    mode: float
    maximum: float

    def validate(self, name: str) -> None:
        if not self.minimum <= self.mode <= self.maximum:
            raise ValueError(
                f"{name} must satisfy minimum <= mode <= maximum; got "
                f"{self.minimum}, {self.mode}, {self.maximum}."
            )
        if self.minimum <= 0:
            raise ValueError(f"{name} multipliers must be strictly positive.")

    def draw(
        self,
        rng: np.random.Generator,
        size: int,
    ) -> npt.NDArray[np.float64]:
        if self.minimum == self.maximum:
            return np.full(size, self.minimum, dtype=float)
        return rng.triangular(self.minimum, self.mode, self.maximum, size=size)


@dataclass(frozen=True)
class UncertaintyDriver:
    """Controlled uncertainty-driver definition."""

    key: str
    title: str
    uncertainty_type: str
    description: str
    evidence_gap: str
    model_effect: str
    probability: int
    impact: int
    mitigation_effectiveness: float
    requirement_weight: float
    resource_weight: float
    requirement_multiplier: TriangularRange
    resource_multiplier: TriangularRange
    limitations: tuple[str, ...]
    mitigations: tuple[str, ...]
    validation_actions: tuple[str, ...]
    owner: str

    @property
    def inherent_score(self) -> int:
        return self.probability * self.impact

    @property
    def residual_score(self) -> int:
        adjusted = math.ceil(self.inherent_score * (1.0 - self.mitigation_effectiveness))
        return max(1, adjusted)


@dataclass(frozen=True)
class AssessmentConfig:
    """Validated Section 28 configuration."""

    metadata: Mapping[str, Any]
    seed: int
    samples: int
    currency: str
    shortfall_threshold: float
    baseline_requirement: float
    baseline_resources: float
    baseline_label: str
    risk_thresholds: Mapping[str, int]
    drivers: tuple[UncertaintyDriver, ...]
    prohibited_uses: tuple[str, ...]
    required_conclusions: tuple[str, ...]

    @property
    def baseline_lcr(self) -> float:
        return self.baseline_resources / self.baseline_requirement


def _as_range(raw: Mapping[str, Any], name: str) -> TriangularRange:
    value = TriangularRange(
        minimum=float(raw["minimum"]),
        mode=float(raw["mode"]),
        maximum=float(raw["maximum"]),
    )
    value.validate(name)
    return value


def _as_tuple(values: Iterable[Any]) -> tuple[str, ...]:
    return tuple(str(value) for value in values)


def load_config(path: Path) -> AssessmentConfig:
    """Load and validate the controlled YAML configuration."""

    with path.open(encoding="utf-8-sig") as stream:
        raw = yaml.safe_load(stream)

    if not isinstance(raw, dict):
        raise ValueError("The Section 28 configuration must be a YAML mapping.")

    simulation = raw["simulation"]
    baseline = simulation["baseline"]
    scoring = raw["risk_scoring"]["thresholds"]

    drivers: list[UncertaintyDriver] = []
    for item in raw["uncertainty_drivers"]:
        driver = UncertaintyDriver(
            key=str(item["key"]),
            title=str(item["title"]),
            uncertainty_type=str(item["uncertainty_type"]),
            description=str(item["description"]),
            evidence_gap=str(item["evidence_gap"]),
            model_effect=str(item["model_effect"]),
            probability=int(item["probability"]),
            impact=int(item["impact"]),
            mitigation_effectiveness=float(item["mitigation_effectiveness"]),
            requirement_weight=float(item["requirement_weight"]),
            resource_weight=float(item["resource_weight"]),
            requirement_multiplier=_as_range(
                item["requirement_multiplier"], f"{item['key']}.requirement_multiplier"
            ),
            resource_multiplier=_as_range(
                item["resource_multiplier"], f"{item['key']}.resource_multiplier"
            ),
            limitations=_as_tuple(item["limitations"]),
            mitigations=_as_tuple(item["mitigations"]),
            validation_actions=_as_tuple(item["validation_actions"]),
            owner=str(item["owner"]),
        )
        if not 1 <= driver.probability <= 5:
            raise ValueError(f"{driver.key}.probability must be in [1, 5].")
        if not 1 <= driver.impact <= 5:
            raise ValueError(f"{driver.key}.impact must be in [1, 5].")
        if not 0.0 <= driver.mitigation_effectiveness <= 1.0:
            raise ValueError(f"{driver.key}.mitigation_effectiveness must be in [0, 1].")
        if driver.requirement_weight < 0 or driver.resource_weight < 0:
            raise ValueError(f"{driver.key} weights cannot be negative.")
        drivers.append(driver)

    keys = tuple(driver.key for driver in drivers)
    missing = sorted(set(REQUIRED_CATEGORIES) - set(keys))
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if missing:
        raise ValueError(f"Missing required uncertainty categories: {missing}")
    if duplicates:
        raise ValueError(f"Duplicate uncertainty categories: {duplicates}")

    baseline_requirement = float(baseline["stressed_liquidity_requirement"])
    baseline_resources = float(baseline["available_resources"])
    if baseline_requirement <= 0 or baseline_resources <= 0:
        raise ValueError("Baseline requirement and resources must be positive.")

    config = AssessmentConfig(
        metadata=raw["metadata"],
        seed=int(simulation["seed"]),
        samples=int(simulation["samples"]),
        currency=str(simulation["currency"]),
        shortfall_threshold=float(simulation["shortfall_threshold"]),
        baseline_requirement=baseline_requirement,
        baseline_resources=baseline_resources,
        baseline_label=str(baseline["label"]),
        risk_thresholds={key: int(value) for key, value in scoring.items()},
        drivers=tuple(drivers),
        prohibited_uses=_as_tuple(raw["reporting"]["prohibited_uses"]),
        required_conclusions=_as_tuple(raw["reporting"]["required_conclusions"]),
    )
    if config.samples < 100:
        raise ValueError("simulation.samples must be at least 100.")
    if config.shortfall_threshold <= 0:
        raise ValueError("shortfall_threshold must be positive.")
    return config


def risk_rating(score: int, thresholds: Mapping[str, int]) -> str:
    """Convert a numeric score into a controlled qualitative rating."""

    if score <= thresholds["low_max"]:
        return "Low"
    if score <= thresholds["moderate_max"]:
        return "Moderate"
    if score <= thresholds["high_max"]:
        return "High"
    return "Critical"


def build_uncertainty_register(config: AssessmentConfig) -> pd.DataFrame:
    """Create the qualitative uncertainty and limitations register."""

    records: list[dict[str, Any]] = []
    for driver in config.drivers:
        records.append(
            {
                "key": driver.key,
                "title": driver.title,
                "uncertainty_type": driver.uncertainty_type,
                "description": driver.description,
                "evidence_gap": driver.evidence_gap,
                "model_effect": driver.model_effect,
                "probability": driver.probability,
                "impact": driver.impact,
                "inherent_score": driver.inherent_score,
                "inherent_rating": risk_rating(driver.inherent_score, config.risk_thresholds),
                "mitigation_effectiveness": driver.mitigation_effectiveness,
                "residual_score": driver.residual_score,
                "residual_rating": risk_rating(driver.residual_score, config.risk_thresholds),
                "requirement_weight": driver.requirement_weight,
                "resource_weight": driver.resource_weight,
                "requirement_min": driver.requirement_multiplier.minimum,
                "requirement_mode": driver.requirement_multiplier.mode,
                "requirement_max": driver.requirement_multiplier.maximum,
                "resource_min": driver.resource_multiplier.minimum,
                "resource_mode": driver.resource_multiplier.mode,
                "resource_max": driver.resource_multiplier.maximum,
                "limitations": " | ".join(driver.limitations),
                "mitigations": " | ".join(driver.mitigations),
                "validation_actions": " | ".join(driver.validation_actions),
                "owner": driver.owner,
            }
        )
    return pd.DataFrame.from_records(records).sort_values(
        ["residual_score", "inherent_score", "title"], ascending=[False, False, True]
    )


@overload
def _bounded_adjustment(weight: float, multiplier: float) -> float: ...


@overload
def _bounded_adjustment(
    weight: float,
    multiplier: npt.NDArray[np.float64],
) -> npt.NDArray[np.float64]: ...


def _bounded_adjustment(
    weight: float,
    multiplier: npt.NDArray[np.float64] | float,
) -> npt.NDArray[np.float64] | float:
    return weight * (multiplier - 1.0)


def one_at_a_time_analysis(config: AssessmentConfig) -> pd.DataFrame:
    """Calculate favorable and adverse one-at-a-time LCR effects."""

    rows: list[dict[str, Any]] = []
    base_req = config.baseline_requirement
    base_res = config.baseline_resources
    base_lcr = config.baseline_lcr

    for driver in config.drivers:
        favorable_req = base_req * (
            1.0
            + _bounded_adjustment(driver.requirement_weight, driver.requirement_multiplier.minimum)
        )
        favorable_res = base_res * (
            1.0 + _bounded_adjustment(driver.resource_weight, driver.resource_multiplier.maximum)
        )
        adverse_req = base_req * (
            1.0
            + _bounded_adjustment(driver.requirement_weight, driver.requirement_multiplier.maximum)
        )
        adverse_res = base_res * (
            1.0 + _bounded_adjustment(driver.resource_weight, driver.resource_multiplier.minimum)
        )
        favorable_lcr = favorable_res / favorable_req
        adverse_lcr = adverse_res / adverse_req
        rows.append(
            {
                "key": driver.key,
                "title": driver.title,
                "baseline_lcr": base_lcr,
                "favorable_requirement": favorable_req,
                "favorable_resources": favorable_res,
                "favorable_lcr": favorable_lcr,
                "adverse_requirement": adverse_req,
                "adverse_resources": adverse_res,
                "adverse_lcr": adverse_lcr,
                "adverse_lcr_change": adverse_lcr - base_lcr,
                "adverse_lcr_reduction": base_lcr - adverse_lcr,
                "adverse_shortfall": max(adverse_req - adverse_res, 0.0),
                "adverse_breach": adverse_lcr < config.shortfall_threshold,
            }
        )

    return pd.DataFrame.from_records(rows).sort_values("adverse_lcr_reduction", ascending=False)


def simulate_joint_uncertainty(
    config: AssessmentConfig,
    *,
    samples: int | None = None,
    seed: int | None = None,
) -> pd.DataFrame:
    """Run the bounded joint Monte Carlo uncertainty envelope.

    The framework uses weighted additive adjustments around the controlled baseline.
    This avoids treating every uncertainty multiplier as a full-portfolio multiplicative
    shock while preserving transparent directional effects.
    """

    simulation_count = config.samples if samples is None else int(samples)
    simulation_seed = config.seed if seed is None else int(seed)
    if simulation_count < 1:
        raise ValueError("samples must be positive.")

    rng = np.random.default_rng(simulation_seed)
    requirement_adjustment = np.zeros(simulation_count, dtype=float)
    resource_adjustment = np.zeros(simulation_count, dtype=float)

    for driver in config.drivers:
        requirement_draw = driver.requirement_multiplier.draw(rng, simulation_count)
        resource_draw = driver.resource_multiplier.draw(rng, simulation_count)
        requirement_adjustment += _bounded_adjustment(driver.requirement_weight, requirement_draw)
        resource_adjustment += _bounded_adjustment(driver.resource_weight, resource_draw)

    requirement = config.baseline_requirement * np.clip(1.0 + requirement_adjustment, 0.01, None)
    resources = config.baseline_resources * np.clip(1.0 + resource_adjustment, 0.01, None)
    lcr = resources / requirement
    shortfall = np.maximum(requirement - resources, 0.0)

    return pd.DataFrame(
        {
            "simulation_id": np.arange(1, simulation_count + 1),
            "stressed_liquidity_requirement": requirement,
            "available_resources": resources,
            "lcr": lcr,
            "liquidity_shortfall": shortfall,
            "shortfall_flag": lcr < config.shortfall_threshold,
        }
    )


def summarize_joint_results(config: AssessmentConfig, simulation: pd.DataFrame) -> pd.DataFrame:
    """Summarize the joint uncertainty envelope."""

    lcr = simulation["lcr"]
    requirement = simulation["stressed_liquidity_requirement"]
    resources = simulation["available_resources"]
    shortfall = simulation["liquidity_shortfall"]
    positive_shortfalls = shortfall[shortfall > 0]

    metrics: list[tuple[str, float | int | str]] = [
        ("baseline_requirement", config.baseline_requirement),
        ("baseline_resources", config.baseline_resources),
        ("baseline_lcr", config.baseline_lcr),
        ("simulation_samples", len(simulation)),
        ("seed", config.seed),
        ("requirement_mean", float(requirement.mean())),
        ("requirement_p95", float(requirement.quantile(0.95))),
        ("requirement_p99", float(requirement.quantile(0.99))),
        ("resources_mean", float(resources.mean())),
        ("resources_p05", float(resources.quantile(0.05))),
        ("resources_p01", float(resources.quantile(0.01))),
        ("lcr_mean", float(lcr.mean())),
        ("lcr_p01", float(lcr.quantile(0.01))),
        ("lcr_p05", float(lcr.quantile(0.05))),
        ("lcr_p50", float(lcr.quantile(0.50))),
        ("lcr_p95", float(lcr.quantile(0.95))),
        ("probability_lcr_below_1", float((lcr < 1.0).mean())),
        (
            "expected_shortfall_given_shortfall",
            float(positive_shortfalls.mean()) if not positive_shortfalls.empty else 0.0,
        ),
        ("maximum_simulated_shortfall", float(shortfall.max())),
        ("evidence_classification", str(config.metadata["evidence_classification"])),
    ]
    return pd.DataFrame(metrics, columns=["metric", "value"])


def _format_money(value: float, currency: str) -> str:
    if currency == "USD":
        return f"${value:,.0f}"
    return f"{value:,.0f} {currency}"


def _format_percent(value: float) -> str:
    return f"{100.0 * value:.2f}%"


def create_figures(
    config: AssessmentConfig,
    one_at_a_time: pd.DataFrame,
    simulation: pd.DataFrame,
    output_dir: Path,
) -> tuple[Path, Path]:
    """Create controlled diagnostic figures."""

    output_dir.mkdir(parents=True, exist_ok=True)

    tornado_path = output_dir / "uncertainty_tornado.png"
    tornado = one_at_a_time.sort_values("adverse_lcr_reduction", ascending=True)
    plt.figure(figsize=(10, 6))
    plt.barh(tornado["title"], tornado["adverse_lcr_reduction"])
    plt.xlabel("Reduction from baseline LCR under adverse one-at-a-time setting")
    plt.ylabel("Uncertainty driver")
    plt.title("Section 28 uncertainty-driver ranking")
    plt.tight_layout()
    plt.savefig(tornado_path, dpi=180, bbox_inches="tight")
    plt.close()

    distribution_path = output_dir / "joint_lcr_distribution.png"
    plt.figure(figsize=(9, 5))
    plt.hist(simulation["lcr"], bins=50)
    plt.axvline(config.shortfall_threshold, linestyle="--", linewidth=1.5)
    plt.xlabel("Liquidity Coverage Ratio (available resources / requirement)")
    plt.ylabel("Simulation count")
    plt.title("Joint uncertainty envelope for illustrative synthetic baseline")
    plt.tight_layout()
    plt.savefig(distribution_path, dpi=180, bbox_inches="tight")
    plt.close()

    return tornado_path, distribution_path


def _markdown_bullets(values: Iterable[str]) -> str:
    return "\n".join(f"- {value}" for value in values)


def build_report(
    config: AssessmentConfig,
    register: pd.DataFrame,
    one_at_a_time: pd.DataFrame,
    summary: pd.DataFrame,
) -> str:
    """Build the controlled Section 28 Markdown report."""

    summary_map = dict(zip(summary["metric"], summary["value"], strict=True))
    top_quantitative = one_at_a_time.iloc[0]
    high_residual = register[register["residual_rating"].isin(["High", "Critical"])]
    baseline_requirement_text = _format_money(config.baseline_requirement, config.currency)
    baseline_resources_text = _format_money(config.baseline_resources, config.currency)
    shortfall_probability_text = _format_percent(float(summary_map["probability_lcr_below_1"]))
    requirement_mean_text = _format_money(float(summary_map["requirement_mean"]), config.currency)
    requirement_p99_text = _format_money(float(summary_map["requirement_p99"]), config.currency)
    resources_p01_text = _format_money(float(summary_map["resources_p01"]), config.currency)
    maximum_shortfall_text = _format_money(
        float(summary_map["maximum_simulated_shortfall"]), config.currency
    )

    sections: list[str] = [
        "# Phase VII - Section 28: Uncertainty and Limitations Assessment",
        "",
        "> **Evidence classification:** Illustrative synthetic calibration. This report "
        "does not use actual FICC participant-level or intraday data and must not be "
        "interpreted as an estimate of FICC liquidity needs.",
        "",
        "## Executive conclusion",
        "",
        "The research framework is suitable for independent methodology testing, control "
        "demonstration, sensitivity analysis, benchmark comparison, and directional model "
        "validation. It is not suitable for empirical validation of actual FICC participant "
        "exposures, legal resource availability, or intraday liquidity peaks.",
        "",
        f"The illustrative baseline requirement is {baseline_requirement_text}, "
        f"available resources are {baseline_resources_text}, "
        f"and baseline LCR is {config.baseline_lcr:.4f}. Under the configured joint uncertainty "
        f"envelope, the estimated frequency of LCR below 1.0 is "
        f"{shortfall_probability_text}. This result is a "
        "model-risk diagnostic, not a forecast or regulatory measure.",
        "",
        "## Scope and methodology",
        "",
        "The assessment combines two controlled views:",
        "",
        "1. A qualitative uncertainty register using probability, impact, mitigation "
        "effectiveness, inherent risk, and residual risk.",
        "2. A quantitative uncertainty envelope using transparent triangular ranges, "
        "bounded weighted adjustments, one-at-a-time adverse tests, and a reproducible "
        "joint Monte Carlo simulation.",
        "",
        "The quantitative envelope intentionally avoids false precision. It does not model "
        "a full joint economic distribution, confidential participant dependencies, payment "
        "queues, legal enforceability, or market microstructure.",
        "",
        "## Quantitative uncertainty results",
        "",
        f"- Simulations: {int(summary_map['simulation_samples']):,}",
        f"- Deterministic seed: {int(summary_map['seed'])}",
        f"- Mean simulated requirement: {requirement_mean_text}",
        f"- 99th-percentile requirement: {requirement_p99_text}",
        f"- 1st-percentile available resources: {resources_p01_text}",
        f"- Median LCR: {float(summary_map['lcr_p50']):.4f}",
        f"- 5th-percentile LCR: {float(summary_map['lcr_p05']):.4f}",
        f"- 1st-percentile LCR: {float(summary_map['lcr_p01']):.4f}",
        f"- Probability of LCR below 1.0: {shortfall_probability_text}",
        f"- Maximum simulated shortfall: {maximum_shortfall_text}",
        f"- Largest one-at-a-time LCR reduction: {top_quantitative['title']} "
        f"({float(top_quantitative['adverse_lcr_reduction']):.4f})",
        "",
        "## Residual-risk prioritization",
        "",
    ]

    if high_residual.empty:
        sections.append("No driver is rated High or Critical after configured mitigations.")
    else:
        sections.append(
            "The following drivers retain High or Critical residual risk and require explicit "
            "use restrictions, challenge, or remediation:"
        )
        sections.append("")
        for row in high_residual.itertuples(index=False):
            sections.append(
                f"- **{row.title}:** residual score {row.residual_score} "
                f"({row.residual_rating}); owner: {row.owner}."
            )

    sections.extend(["", "## Detailed assessment by uncertainty source", ""])
    driver_lookup = {driver.key: driver for driver in config.drivers}
    for row in register.itertuples(index=False):
        driver = driver_lookup[str(row.key)]
        sections.extend(
            [
                f"### {driver.title}",
                "",
                f"**Type:** {driver.uncertainty_type}",
                "",
                f"**Assessment:** {driver.description}",
                "",
                f"**Evidence gap:** {driver.evidence_gap}",
                "",
                f"**Potential model effect:** {driver.model_effect}",
                "",
                f"**Risk rating:** inherent {row.inherent_score} ({row.inherent_rating}); "
                f"residual {row.residual_score} ({row.residual_rating}).",
                "",
                "**Material limitations**",
                "",
                _markdown_bullets(driver.limitations),
                "",
                "**Mitigations and compensating controls**",
                "",
                _markdown_bullets(driver.mitigations),
                "",
                "**Independent validation actions**",
                "",
                _markdown_bullets(driver.validation_actions),
                "",
            ]
        )

    sections.extend(
        [
            "## Cross-cutting limitations",
            "",
            "- Public aggregate data cannot validate actual participant-level liquidity needs.",
            "- Missing intraday information prevents empirical estimation of peak payment "
            "and collateral usage.",
            "- Synthetic allocation and dependence assumptions materially affect "
            "default-set rankings.",
            "- Operational and legal availability of resources requires specialist review "
            "outside this model.",
            "- Simplified liquidation functions do not reproduce full market microstructure "
            "or feedback loops.",
            "- The joint uncertainty envelope uses transparent but judgmental ranges and "
            "simplified dependence.",
            "- Historical plausibility and benchmark agreement do not establish production "
            "fitness.",
            "",
            "## Required model-use restrictions",
            "",
            _markdown_bullets(config.prohibited_uses),
            "",
            "## Required conclusions",
            "",
            _markdown_bullets(config.required_conclusions),
            "",
            "## Validation disposition",
            "",
            "**Conditionally acceptable for research and portfolio demonstration only.** "
            "The framework must retain synthetic-data labeling, deterministic reproducibility, "
            "conservative uncertainty ranges, benchmark comparison, and explicit reporting "
            "of participant-level, intraday, legal, "
            "operational, and liquidation-function limitations.",
            "",
            "Production or regulatory use would require confidential participant-level and "
            "intraday data, validated legal and operational resource assumptions, empirical "
            "calibration, independent "
            "implementation testing, and formal model-risk approval.",
            "",
        ]
    )
    return "\n".join(sections)


def run_assessment(
    config_path: Path,
    output_dir: Path,
    *,
    samples: int | None = None,
) -> dict[str, Path]:
    """Execute the complete Section 28 assessment and write controlled artifacts."""

    config = load_config(config_path)
    if samples is not None:
        config = AssessmentConfig(
            metadata=config.metadata,
            seed=config.seed,
            samples=int(samples),
            currency=config.currency,
            shortfall_threshold=config.shortfall_threshold,
            baseline_requirement=config.baseline_requirement,
            baseline_resources=config.baseline_resources,
            baseline_label=config.baseline_label,
            risk_thresholds=config.risk_thresholds,
            drivers=config.drivers,
            prohibited_uses=config.prohibited_uses,
            required_conclusions=config.required_conclusions,
        )

    output_dir.mkdir(parents=True, exist_ok=True)
    register = build_uncertainty_register(config)
    one_at_a_time = one_at_a_time_analysis(config)
    simulation = simulate_joint_uncertainty(config)
    summary = summarize_joint_results(config, simulation)

    register_path = output_dir / "uncertainty_register.csv"
    one_at_a_time_path = output_dir / "one_at_a_time_uncertainty.csv"
    simulation_path = output_dir / "joint_uncertainty_simulations.csv"
    summary_path = output_dir / "joint_uncertainty_summary.csv"
    report_path = output_dir / "section_28_uncertainty_limitations.md"
    json_path = output_dir / "section_28_summary.json"

    register.to_csv(register_path, index=False)
    one_at_a_time.to_csv(one_at_a_time_path, index=False)
    simulation.to_csv(simulation_path, index=False)
    summary.to_csv(summary_path, index=False)

    tornado_path, distribution_path = create_figures(config, one_at_a_time, simulation, output_dir)
    report_path.write_text(build_report(config, register, one_at_a_time, summary), encoding="utf-8")

    summary_map = dict(zip(summary["metric"], summary["value"], strict=True))
    json_payload = {
        "section": str(config.metadata["section"]),
        "title": str(config.metadata["title"]),
        "evidence_classification": str(config.metadata["evidence_classification"]),
        "baseline": {
            "stressed_liquidity_requirement": config.baseline_requirement,
            "available_resources": config.baseline_resources,
            "lcr": config.baseline_lcr,
        },
        "joint_uncertainty": {
            "samples": int(summary_map["simulation_samples"]),
            "seed": int(summary_map["seed"]),
            "lcr_p01": float(summary_map["lcr_p01"]),
            "lcr_p05": float(summary_map["lcr_p05"]),
            "lcr_p50": float(summary_map["lcr_p50"]),
            "probability_lcr_below_1": float(summary_map["probability_lcr_below_1"]),
            "maximum_simulated_shortfall": float(summary_map["maximum_simulated_shortfall"]),
        },
        "highest_residual_risks": register.head(5)[
            ["key", "title", "residual_score", "residual_rating", "owner"]
        ].to_dict(orient="records"),
        "prohibited_uses": list(config.prohibited_uses),
    }
    json_path.write_text(json.dumps(json_payload, indent=2), encoding="utf-8")

    return {
        "register": register_path,
        "one_at_a_time": one_at_a_time_path,
        "simulation": simulation_path,
        "summary": summary_path,
        "report": report_path,
        "summary_json": json_path,
        "tornado_figure": tornado_path,
        "distribution_figure": distribution_path,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run Phase VII Section 28 uncertainty and limitations assessment."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/validation/section_28_uncertainty.yaml"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("reports/validation/section_28"),
    )
    parser.add_argument("--samples", type=int, default=None)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    paths = run_assessment(args.config, args.output_dir, samples=args.samples)
    print("Section 28 uncertainty assessment completed.")
    for name, path in paths.items():
        print(f"{name}: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
