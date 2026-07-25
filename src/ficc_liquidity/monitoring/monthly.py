"""Monthly model monitoring for FICC liquidity stress testing."""

from __future__ import annotations

import argparse
import json
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import yaml


@dataclass(frozen=True)
class MonitoringResult:
    """One monitoring control result."""

    control: str
    metric: str
    value: float | int | str | None
    warning_threshold: float | int | str | None
    failure_threshold: float | int | str | None
    status: str
    severity: str
    message: str
    details: str = ""


@dataclass(frozen=True)
class MonitoringSummary:
    """Run-level monitoring summary."""

    as_of_date: str
    overall_status: str
    pass_count: int
    warning_count: int
    failure_count: int
    control_count: int


class MonthlyMonitoringEngine:
    """Execute the Section 29 monthly monitoring control suite."""

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.config = dict(config["monitoring"])
        self.thresholds = dict(self.config["thresholds"])
        self.required_columns = list(self.config["required_columns"])
        self.numeric_columns = list(self.config["numeric_columns"])
        self.component_columns = list(self.config["component_columns"])

    @classmethod
    def from_yaml(cls, path: str | Path) -> MonthlyMonitoringEngine:
        with Path(path).open("r", encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
        return cls(config)

    def run(
        self,
        current: pd.DataFrame,
        *,
        baseline: pd.DataFrame | None = None,
        previous: pd.DataFrame | None = None,
        current_parameters: Mapping[str, Any] | None = None,
        previous_parameters: Mapping[str, Any] | None = None,
        current_sensitivity: pd.DataFrame | None = None,
        previous_sensitivity: pd.DataFrame | None = None,
        reconciliation: pd.DataFrame | None = None,
        as_of_date: str | None = None,
    ) -> tuple[pd.DataFrame, MonitoringSummary]:
        current = self._normalize_frame(current)
        baseline = self._normalize_optional_frame(baseline)
        previous = self._normalize_optional_frame(previous)

        results = [
            self._check_data_completeness(current),
            self._check_schema_changes(current),
            self._check_missing_observations(current),
            self._check_historical_range(current, baseline),
            self._check_parameter_changes(current_parameters, previous_parameters),
            self._check_exposure_concentration(current),
            self._check_lcr_distribution(current, previous),
            self._check_scenario_rank_stability(current, previous),
            self._check_component_contribution_drift(current, previous),
            self._check_sensitivity_changes(current_sensitivity, previous_sensitivity),
            self._check_reconciliation_failures(reconciliation),
        ]
        scorecard = pd.DataFrame(asdict(result) for result in results)
        status_counts = scorecard["status"].value_counts().to_dict()
        failure_count = int(status_counts.get("FAIL", 0))
        warning_count = int(status_counts.get("WARN", 0))
        pass_count = int(status_counts.get("PASS", 0))
        overall_status = "FAIL" if failure_count else "WARN" if warning_count else "PASS"
        resolved_date = as_of_date or self._resolve_as_of_date(current)
        summary = MonitoringSummary(
            as_of_date=resolved_date,
            overall_status=overall_status,
            pass_count=pass_count,
            warning_count=warning_count,
            failure_count=failure_count,
            control_count=len(results),
        )
        return scorecard, summary

    def write_outputs(
        self,
        scorecard: pd.DataFrame,
        summary: MonitoringSummary,
        output_dir: str | Path,
    ) -> dict[str, Path]:
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        stamp = summary.as_of_date.replace("-", "")
        scorecard_path = output_path / f"monthly_monitoring_scorecard_{stamp}.csv"
        summary_path = output_path / f"monthly_monitoring_summary_{stamp}.json"
        report_path = output_path / f"monthly_monitoring_report_{stamp}.md"

        scorecard.to_csv(scorecard_path, index=False)
        summary_path.write_text(
            json.dumps(asdict(summary), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        report_path.write_text(
            self._render_markdown(scorecard, summary),
            encoding="utf-8",
        )
        return {
            "scorecard": scorecard_path,
            "summary": summary_path,
            "report": report_path,
        }

    def _check_data_completeness(self, current: pd.DataFrame) -> MonitoringResult:
        missing_columns = sorted(set(self.required_columns) - set(current.columns))
        if missing_columns:
            return self._result(
                "data_completeness",
                "required_column_presence",
                len(missing_columns),
                0,
                0,
                "FAIL",
                "Critical",
                "Required monitoring fields are absent.",
                ", ".join(missing_columns),
            )
        completeness = float(current[self.required_columns].notna().mean().min())
        status = self._lower_is_worse_status(
            completeness,
            self.thresholds["data_completeness_warn"],
            self.thresholds["data_completeness_fail"],
        )
        return self._result(
            "data_completeness",
            "minimum_required_field_completeness",
            completeness,
            self.thresholds["data_completeness_warn"],
            self.thresholds["data_completeness_fail"],
            status,
            "High",
            "Minimum non-null ratio across required fields.",
        )

    def _check_schema_changes(self, current: pd.DataFrame) -> MonitoringResult:
        missing = sorted(set(self.required_columns) - set(current.columns))
        non_numeric = [
            name
            for name in self.numeric_columns
            if name in current.columns and not pd.api.types.is_numeric_dtype(current[name])
        ]
        date_problem = "date" in current.columns and not pd.api.types.is_datetime64_any_dtype(
            current["date"]
        )
        issues = missing + non_numeric + (["date:not_datetime"] if date_problem else [])
        status = "FAIL" if issues else "PASS"
        return self._result(
            "schema_changes",
            "schema_issue_count",
            len(issues),
            1,
            1,
            status,
            "Critical",
            "Required fields and data types are compared with the monitoring contract.",
            ", ".join(issues),
        )

    def _check_missing_observations(self, current: pd.DataFrame) -> MonitoringResult:
        if "date" not in current.columns or current["date"].dropna().empty:
            return self._unavailable(
                "missing_observations",
                "missing_business_days",
                "No valid date observations are available.",
            )
        dates = pd.DatetimeIndex(current["date"].dropna().dt.normalize().unique()).sort_values()
        expected = pd.bdate_range(dates.min(), dates.max())
        missing_count = len(expected.difference(dates))
        status = self._higher_is_worse_status(
            missing_count,
            self.thresholds["missing_business_days_warn"],
            self.thresholds["missing_business_days_fail"],
        )
        return self._result(
            "missing_observations",
            "missing_business_days",
            missing_count,
            self.thresholds["missing_business_days_warn"],
            self.thresholds["missing_business_days_fail"],
            status,
            "High",
            "Missing business dates between the first and last observed dates.",
        )

    def _check_historical_range(
        self,
        current: pd.DataFrame,
        baseline: pd.DataFrame | None,
    ) -> MonitoringResult:
        if baseline is None or baseline.empty:
            return self._unavailable(
                "historical_range_breaches",
                "breach_rate",
                "Historical baseline data were not supplied.",
            )
        available = [
            name
            for name in self.numeric_columns
            if name in current.columns and name in baseline.columns
        ]
        if not available:
            return self._unavailable(
                "historical_range_breaches",
                "breach_rate",
                "No common numeric monitoring fields were found.",
            )
        low_q = float(self.thresholds["historical_quantile_low"])
        high_q = float(self.thresholds["historical_quantile_high"])
        breach_total = 0
        observation_total = 0
        detail_rows: list[str] = []
        for name in available:
            lower = float(baseline[name].quantile(low_q))
            upper = float(baseline[name].quantile(high_q))
            values = current[name].dropna()
            breaches = int(((values < lower) | (values > upper)).sum())
            breach_total += breaches
            observation_total += int(values.size)
            detail_rows.append(f"{name}={breaches}/{values.size}")
        breach_rate = breach_total / observation_total if observation_total else 0.0
        status = self._higher_is_worse_status(
            breach_rate,
            self.thresholds["historical_range_breach_rate_warn"],
            self.thresholds["historical_range_breach_rate_fail"],
        )
        return self._result(
            "historical_range_breaches",
            "breach_rate",
            breach_rate,
            self.thresholds["historical_range_breach_rate_warn"],
            self.thresholds["historical_range_breach_rate_fail"],
            status,
            "Medium",
            "Current values outside historical baseline quantile bounds.",
            "; ".join(detail_rows),
        )

    def _check_parameter_changes(
        self,
        current_parameters: Mapping[str, Any] | None,
        previous_parameters: Mapping[str, Any] | None,
    ) -> MonitoringResult:
        if not current_parameters or not previous_parameters:
            return self._unavailable(
                "parameter_changes",
                "maximum_relative_change",
                "Current and previous parameter snapshots were not both supplied.",
            )
        current_flat = self._flatten_mapping(current_parameters)
        previous_flat = self._flatten_mapping(previous_parameters)
        shared = sorted(set(current_flat) & set(previous_flat))
        numeric_changes: list[tuple[str, float]] = []
        categorical_changes: list[str] = []
        for name in shared:
            current_value = current_flat[name]
            previous_value = previous_flat[name]
            if self._is_number(current_value) and self._is_number(previous_value):
                denominator = max(abs(float(previous_value)), 1e-12)
                change = abs(float(current_value) - float(previous_value)) / denominator
                numeric_changes.append((name, change))
            elif current_value != previous_value:
                categorical_changes.append(name)
        added_or_removed = sorted(set(current_flat) ^ set(previous_flat))
        max_change = max((change for _, change in numeric_changes), default=0.0)
        status = self._higher_is_worse_status(
            max_change,
            self.thresholds["parameter_relative_change_warn"],
            self.thresholds["parameter_relative_change_fail"],
        )
        if categorical_changes or added_or_removed:
            status = "FAIL"
        details = [f"{name}={change:.4f}" for name, change in numeric_changes if change > 0]
        details.extend(f"categorical_change:{name}" for name in categorical_changes)
        details.extend(f"added_or_removed:{name}" for name in added_or_removed)
        return self._result(
            "parameter_changes",
            "maximum_relative_change",
            max_change,
            self.thresholds["parameter_relative_change_warn"],
            self.thresholds["parameter_relative_change_fail"],
            status,
            "High",
            "Maximum relative parameter change plus structural parameter changes.",
            "; ".join(details),
        )

    def _check_exposure_concentration(self, current: pd.DataFrame) -> MonitoringResult:
        if not {"member_id", "exposure"}.issubset(current.columns):
            return self._unavailable(
                "exposure_concentration",
                "largest_member_share",
                "Member and exposure fields are required.",
            )
        exposure = current.groupby("member_id", dropna=False)["exposure"].sum().abs()
        total = float(exposure.sum())
        if total <= 0:
            return self._unavailable(
                "exposure_concentration",
                "largest_member_share",
                "Total absolute exposure is zero.",
            )
        shares = exposure / total
        largest_share = float(shares.max())
        hhi = float(np.square(shares).sum())
        share_status = self._higher_is_worse_status(
            largest_share,
            self.thresholds["largest_member_share_warn"],
            self.thresholds["largest_member_share_fail"],
        )
        hhi_status = self._higher_is_worse_status(
            hhi,
            self.thresholds["exposure_hhi_warn"],
            self.thresholds["exposure_hhi_fail"],
        )
        status = self._worst_status(share_status, hhi_status)
        return self._result(
            "exposure_concentration",
            "largest_member_share",
            largest_share,
            self.thresholds["largest_member_share_warn"],
            self.thresholds["largest_member_share_fail"],
            status,
            "High",
            "Largest member share of absolute exposure; HHI is an auxiliary indicator.",
            f"hhi={hhi:.6f}",
        )

    def _check_lcr_distribution(
        self,
        current: pd.DataFrame,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        if "lcr" not in current.columns or current["lcr"].dropna().empty:
            return self._unavailable(
                "lcr_distribution",
                "lcr_5th_percentile",
                "No LCR observations are available.",
            )
        lcr = current["lcr"].dropna().astype(float)
        p05 = float(lcr.quantile(0.05))
        breach_rate = float((lcr < 1.0).mean())
        p05_status = self._lower_is_worse_status(
            p05,
            self.thresholds["lcr_p05_warn"],
            self.thresholds["lcr_p05_fail"],
        )
        breach_status = self._higher_is_worse_status(
            breach_rate,
            self.thresholds["lcr_breach_rate_warn"],
            self.thresholds["lcr_breach_rate_fail"],
        )
        mean_change = 0.0
        mean_change_status = "PASS"
        if previous is not None and "lcr" in previous.columns and previous["lcr"].notna().any():
            previous_mean = float(previous["lcr"].mean())
            denominator = max(abs(previous_mean), 1e-12)
            mean_change = abs(float(lcr.mean()) - previous_mean) / denominator
            mean_change_status = self._higher_is_worse_status(
                mean_change,
                self.thresholds["lcr_mean_relative_change_warn"],
                self.thresholds["lcr_mean_relative_change_fail"],
            )
        status = self._worst_status(p05_status, breach_status, mean_change_status)
        return self._result(
            "lcr_distribution",
            "lcr_5th_percentile",
            p05,
            self.thresholds["lcr_p05_warn"],
            self.thresholds["lcr_p05_fail"],
            status,
            "Critical",
            "Lower-tail LCR, LCR<1 breach rate, and month-over-month mean drift.",
            f"breach_rate={breach_rate:.6f}; mean_relative_change={mean_change:.6f}",
        )

    def _check_scenario_rank_stability(
        self,
        current: pd.DataFrame,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        required = {"scenario", "stressed_liquidity_requirement"}
        if (
            previous is None
            or not required.issubset(current.columns)
            or not required.issubset(previous.columns)
        ):
            return self._unavailable(
                "scenario_rank_stability",
                "rank_correlation",
                "Current and previous scenario results are required.",
            )
        current_rank = current.groupby("scenario")["stressed_liquidity_requirement"].mean().rank()
        previous_rank = previous.groupby("scenario")["stressed_liquidity_requirement"].mean().rank()
        shared = current_rank.index.intersection(previous_rank.index)
        if len(shared) < 2:
            return self._unavailable(
                "scenario_rank_stability",
                "rank_correlation",
                "At least two common scenarios are required.",
            )
        correlation = self._pearson(
            current_rank.loc[shared].to_numpy(dtype=float),
            previous_rank.loc[shared].to_numpy(dtype=float),
        )
        status = self._lower_is_worse_status(
            correlation,
            self.thresholds["scenario_rank_correlation_warn"],
            self.thresholds["scenario_rank_correlation_fail"],
        )
        return self._result(
            "scenario_rank_stability",
            "rank_correlation",
            correlation,
            self.thresholds["scenario_rank_correlation_warn"],
            self.thresholds["scenario_rank_correlation_fail"],
            status,
            "Medium",
            "Pearson correlation of average scenario severity ranks across months.",
            f"common_scenarios={len(shared)}",
        )

    def _check_component_contribution_drift(
        self,
        current: pd.DataFrame,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        if previous is None:
            return self._unavailable(
                "component_contribution_drift",
                "maximum_absolute_share_change",
                "Previous-month results were not supplied.",
            )
        components = [
            name
            for name in self.component_columns
            if name in current.columns and name in previous.columns
        ]
        if not components:
            return self._unavailable(
                "component_contribution_drift",
                "maximum_absolute_share_change",
                "No common stress-component columns are available.",
            )
        current_total = float(current[components].sum(axis=1).abs().sum())
        previous_total = float(previous[components].sum(axis=1).abs().sum())
        if current_total <= 0 or previous_total <= 0:
            return self._unavailable(
                "component_contribution_drift",
                "maximum_absolute_share_change",
                "Component totals must be positive.",
            )
        current_shares = current[components].abs().sum() / current_total
        previous_shares = previous[components].abs().sum() / previous_total
        changes = (current_shares - previous_shares).abs()
        max_change = float(changes.max())
        status = self._higher_is_worse_status(
            max_change,
            self.thresholds["component_share_drift_warn"],
            self.thresholds["component_share_drift_fail"],
        )
        details = "; ".join(f"{name}={changes[name]:.6f}" for name in components)
        return self._result(
            "component_contribution_drift",
            "maximum_absolute_share_change",
            max_change,
            self.thresholds["component_share_drift_warn"],
            self.thresholds["component_share_drift_fail"],
            status,
            "Medium",
            "Maximum absolute change in aggregate stress-component contribution share.",
            details,
        )

    def _check_sensitivity_changes(
        self,
        current: pd.DataFrame | None,
        previous: pd.DataFrame | None,
    ) -> MonitoringResult:
        required = {"parameter", "sensitivity"}
        if current is None or previous is None:
            return self._unavailable(
                "sensitivity_changes",
                "maximum_relative_change",
                "Current and previous sensitivity snapshots were not both supplied.",
            )
        if not required.issubset(current.columns) or not required.issubset(previous.columns):
            return self._unavailable(
                "sensitivity_changes",
                "maximum_relative_change",
                "Sensitivity snapshots require parameter and sensitivity fields.",
            )
        merged = current[list(required)].merge(
            previous[list(required)],
            on="parameter",
            suffixes=("_current", "_previous"),
        )
        if merged.empty:
            return self._unavailable(
                "sensitivity_changes",
                "maximum_relative_change",
                "No common sensitivity parameters were found.",
            )
        denominator = merged["sensitivity_previous"].abs().clip(lower=1e-12)
        changes = (
            merged["sensitivity_current"] - merged["sensitivity_previous"]
        ).abs() / denominator
        max_change = float(changes.max())
        status = self._higher_is_worse_status(
            max_change,
            self.thresholds["sensitivity_relative_change_warn"],
            self.thresholds["sensitivity_relative_change_fail"],
        )
        detail = "; ".join(
            f"{parameter}={change:.6f}"
            for parameter, change in zip(merged["parameter"], changes, strict=True)
        )
        return self._result(
            "sensitivity_changes",
            "maximum_relative_change",
            max_change,
            self.thresholds["sensitivity_relative_change_warn"],
            self.thresholds["sensitivity_relative_change_fail"],
            status,
            "High",
            "Maximum relative change in independently measured model sensitivity.",
            detail,
        )

    def _check_reconciliation_failures(
        self,
        reconciliation: pd.DataFrame | None,
    ) -> MonitoringResult:
        if reconciliation is None or reconciliation.empty:
            return self._unavailable(
                "reconciliation_failures",
                "failure_count",
                "Reconciliation results were not supplied.",
            )
        if "passed" in reconciliation.columns:
            failures = int((~reconciliation["passed"].fillna(False).astype(bool)).sum())
        elif {"difference", "tolerance"}.issubset(reconciliation.columns):
            failures = int(
                (reconciliation["difference"].abs() > reconciliation["tolerance"].abs()).sum()
            )
        else:
            return self._unavailable(
                "reconciliation_failures",
                "failure_count",
                "Reconciliation requires passed or difference/tolerance fields.",
            )
        status = self._higher_is_worse_status(
            failures,
            self.thresholds["reconciliation_failures_warn"],
            self.thresholds["reconciliation_failures_fail"],
        )
        return self._result(
            "reconciliation_failures",
            "failure_count",
            failures,
            self.thresholds["reconciliation_failures_warn"],
            self.thresholds["reconciliation_failures_fail"],
            status,
            "Critical",
            "Number of failed production-to-independent reconciliations.",
        )

    @staticmethod
    def _normalize_frame(frame: pd.DataFrame) -> pd.DataFrame:
        normalized = frame.copy()
        if "date" in normalized.columns:
            normalized["date"] = pd.to_datetime(normalized["date"], errors="coerce")
        return normalized

    def _normalize_optional_frame(self, frame: pd.DataFrame | None) -> pd.DataFrame | None:
        return None if frame is None else self._normalize_frame(frame)

    @staticmethod
    def _resolve_as_of_date(current: pd.DataFrame) -> str:
        if "date" in current.columns and current["date"].notna().any():
            return pd.Timestamp(current["date"].max()).date().isoformat()
        return pd.Timestamp.utcnow().date().isoformat()

    @staticmethod
    def _flatten_mapping(
        values: Mapping[str, Any],
        prefix: str = "",
    ) -> dict[str, Any]:
        flattened: dict[str, Any] = {}
        for key, value in values.items():
            name = f"{prefix}.{key}" if prefix else str(key)
            if isinstance(value, Mapping):
                flattened.update(MonthlyMonitoringEngine._flatten_mapping(value, name))
            else:
                flattened[name] = value
        return flattened

    @staticmethod
    def _is_number(value: Any) -> bool:
        return isinstance(value, (int, float, np.integer, np.floating)) and not isinstance(
            value, bool
        )

    @staticmethod
    def _pearson(x: np.ndarray, y: np.ndarray) -> float:
        if x.size != y.size or x.size < 2:
            return float("nan")
        x_centered = x - x.mean()
        y_centered = y - y.mean()
        denominator = float(np.sqrt(np.square(x_centered).sum() * np.square(y_centered).sum()))
        if denominator == 0:
            return 1.0 if np.allclose(x, y) else 0.0
        return float(np.dot(x_centered, y_centered) / denominator)

    @staticmethod
    def _higher_is_worse_status(value: float, warning: float, failure: float) -> str:
        if value >= failure:
            return "FAIL"
        if value >= warning:
            return "WARN"
        return "PASS"

    @staticmethod
    def _lower_is_worse_status(value: float, warning: float, failure: float) -> str:
        if value < failure:
            return "FAIL"
        if value < warning:
            return "WARN"
        return "PASS"

    @staticmethod
    def _worst_status(*statuses: str) -> str:
        ordering = {"PASS": 0, "WARN": 1, "FAIL": 2}
        return max(statuses, key=lambda status: ordering[status])

    @staticmethod
    def _result(
        control: str,
        metric: str,
        value: float | int | str | None,
        warning_threshold: float | int | str | None,
        failure_threshold: float | int | str | None,
        status: str,
        severity: str,
        message: str,
        details: str = "",
    ) -> MonitoringResult:
        return MonitoringResult(
            control=control,
            metric=metric,
            value=value,
            warning_threshold=warning_threshold,
            failure_threshold=failure_threshold,
            status=status,
            severity=severity,
            message=message,
            details=details,
        )

    def _unavailable(self, control: str, metric: str, message: str) -> MonitoringResult:
        return self._result(
            control,
            metric,
            None,
            None,
            None,
            "WARN",
            "Medium",
            message,
            "Input unavailable; governance review required.",
        )

    @staticmethod
    def _render_markdown(
        scorecard: pd.DataFrame,
        summary: MonitoringSummary,
    ) -> str:
        lines = [
            "# Monthly Model Monitoring Report",
            "",
            f"**As of:** {summary.as_of_date}",
            f"**Overall status:** {summary.overall_status}",
            f"**Controls:** {summary.control_count}",
            f"**PASS / WARN / FAIL:** {summary.pass_count} / "
            f"{summary.warning_count} / {summary.failure_count}",
            "",
            "| Control | Metric | Value | Status | Severity | Message |",
            "|---|---|---:|---|---|---|",
        ]
        for row in scorecard.itertuples(index=False):
            value = "" if pd.isna(row.value) else str(row.value)
            message = str(row.message).replace("|", "/")
            lines.append(
                f"| {row.control} | {row.metric} | {value} | {row.status} | "
                f"{row.severity} | {message} |"
            )
        lines.extend(
            [
                "",
                "## Governance action",
                "",
                "- FAIL: open a model-risk or data-quality issue before the next production run.",
                (
                    "- WARN: assign an owner, document disposition, and close or "
                    "escalate within 10 business days."
                ),
                "- PASS: retain evidence and continue the monthly monitoring cycle.",
                "",
            ]
        )
        return "\n".join(lines)


def _read_table(path: str | Path) -> pd.DataFrame:
    source = Path(path)
    if source.suffix.lower() == ".parquet":
        return pd.read_parquet(source)
    return pd.read_csv(source)


def _read_mapping(path: str | Path) -> dict[str, Any]:
    source = Path(path)
    text = source.read_text(encoding="utf-8")
    if source.suffix.lower() == ".json":
        return dict(json.loads(text))
    return dict(yaml.safe_load(text))


def build_demo_inputs(seed: int = 2026) -> dict[str, Any]:
    """Build deterministic synthetic inputs for a smoke test."""

    rng = np.random.default_rng(seed)
    dates = pd.bdate_range("2026-06-01", "2026-06-30")
    members = [f"SYNTH_MEMBER_{index:02d}" for index in range(1, 13)]
    scenarios = ["moderate", "severe", "extreme"]
    rows: list[dict[str, Any]] = []
    component_names = [
        "settlement_liquidity_need",
        "repo_rollover_need",
        "incremental_funding_cost",
        "additional_haircut_requirement",
        "treasury_liquidation_loss",
        "settlement_fail_requirement",
        "concentration_adjustment",
        "operational_liquidity_buffer",
    ]
    severity = {"moderate": 1.0, "severe": 1.4, "extreme": 1.9}
    for date in dates:
        for member_index, member in enumerate(members, start=1):
            base_exposure = 80_000_000 + member_index * 2_000_000
            for scenario in scenarios:
                components = rng.lognormal(mean=15.0, sigma=0.15, size=len(component_names))
                components = components * severity[scenario]
                requirement = float(components.sum())
                resources = requirement * rng.uniform(1.25, 1.45)
                row: dict[str, Any] = {
                    "date": date,
                    "member_id": member,
                    "scenario": scenario,
                    "exposure": base_exposure * rng.uniform(0.95, 1.05),
                    "stressed_liquidity_requirement": requirement,
                    "available_resources": resources,
                    "lcr": resources / requirement,
                }
                row.update(dict(zip(component_names, components, strict=True)))
                rows.append(row)
    current = pd.DataFrame(rows)
    previous = current.copy()
    previous["date"] = previous["date"] - pd.offsets.MonthBegin(1)
    previous["stressed_liquidity_requirement"] *= 0.98
    previous[component_names] *= 0.98
    previous["lcr"] *= 1.01
    baseline = pd.concat([previous, current], ignore_index=True)
    sensitivity = pd.DataFrame(
        {
            "parameter": ["yield_shock", "sofr_spike", "haircut_increase"],
            "sensitivity": [0.82, 0.67, 0.55],
        }
    )
    previous_sensitivity = sensitivity.copy()
    previous_sensitivity["sensitivity"] *= 0.98
    reconciliation = pd.DataFrame(
        {
            "check_name": ["requirement", "resources", "lcr"],
            "difference": [0.0, 0.0, 0.0],
            "tolerance": [1e-8, 1e-8, 1e-8],
            "passed": [True, True, True],
        }
    )
    return {
        "current": current,
        "previous": previous,
        "baseline": baseline,
        "current_parameters": {
            "liquidation_horizon_days": 5,
            "random_seed": seed,
            "cover_standard": "cover_2",
        },
        "previous_parameters": {
            "liquidation_horizon_days": 5,
            "random_seed": seed,
            "cover_standard": "cover_2",
        },
        "current_sensitivity": sensitivity,
        "previous_sensitivity": previous_sensitivity,
        "reconciliation": reconciliation,
    }


def _optional_table(path: str | None) -> pd.DataFrame | None:
    return None if path is None else _read_table(path)


def _optional_mapping(path: str | None) -> dict[str, Any] | None:
    return None if path is None else _read_mapping(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="configs/monitoring.yaml")
    parser.add_argument("--current")
    parser.add_argument("--baseline")
    parser.add_argument("--previous")
    parser.add_argument("--current-parameters")
    parser.add_argument("--previous-parameters")
    parser.add_argument("--current-sensitivity")
    parser.add_argument("--previous-sensitivity")
    parser.add_argument("--reconciliation")
    parser.add_argument("--output-dir", default="reports/monitoring/monthly")
    parser.add_argument("--as-of-date")
    parser.add_argument("--demo", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    engine = MonthlyMonitoringEngine.from_yaml(args.config)
    if args.demo:
        inputs = build_demo_inputs()
    else:
        if not args.current:
            raise SystemExit("--current is required unless --demo is used")
        inputs = {
            "current": _read_table(args.current),
            "baseline": _optional_table(args.baseline),
            "previous": _optional_table(args.previous),
            "current_parameters": _optional_mapping(args.current_parameters),
            "previous_parameters": _optional_mapping(args.previous_parameters),
            "current_sensitivity": _optional_table(args.current_sensitivity),
            "previous_sensitivity": _optional_table(args.previous_sensitivity),
            "reconciliation": _optional_table(args.reconciliation),
        }
    scorecard, summary = engine.run(**inputs, as_of_date=args.as_of_date)
    paths = engine.write_outputs(scorecard, summary, args.output_dir)
    print(json.dumps({name: str(path) for name, path in paths.items()}, indent=2))
    print(f"overall_status={summary.overall_status}")
    return 1 if summary.failure_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
