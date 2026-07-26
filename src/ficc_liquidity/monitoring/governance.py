"""Monitoring thresholds, escalation, and validation-governance controls."""

from __future__ import annotations

import argparse
import json
from collections.abc import Mapping, Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, ClassVar, cast

import pandas as pd
import yaml

TRAFFIC_ORDER = {"GREEN": 0, "AMBER": 1, "RED": 2}


@dataclass(frozen=True)
class GovernanceSummary:
    """Run-level governance decision."""

    as_of_date: str
    overall_traffic_light: str
    green_count: int
    amber_count: int
    red_count: int
    model_change_trigger_count: int
    revalidation_required: bool
    revalidation_reasons: tuple[str, ...]
    monthly_sign_off_status: str
    annual_validation_status: str
    annual_validation_due_date: str | None


class MonitoringGovernanceEngine:
    """Translate Section 29 monitoring results into controlled governance actions."""

    required_scorecard_columns: ClassVar[set[str]] = {
        "control",
        "metric",
        "value",
        "warning_threshold",
        "failure_threshold",
        "status",
        "severity",
        "message",
        "details",
    }

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.config = dict(config["governance"])
        self.status_mapping = {
            str(key).upper(): str(value).upper()
            for key, value in dict(self.config["status_mapping"]).items()
        }
        self.levels = {
            str(key).upper(): dict(value)
            for key, value in dict(self.config["escalation_levels"]).items()
        }
        self.ownership = {
            str(key): dict(value) for key, value in dict(self.config["control_ownership"]).items()
        }
        self.trigger_config = dict(self.config["triggers"])
        self.sign_off_config = dict(self.config["monthly_sign_off"])
        self.validation_config = dict(self.config["annual_independent_validation"])

    @classmethod
    def from_yaml(cls, path: str | Path) -> MonitoringGovernanceEngine:
        """Create the engine from the controlled YAML file."""
        with Path(path).open("r", encoding="utf-8-sig") as stream:
            config = yaml.safe_load(stream)
        return cls(config)

    def evaluate(
        self,
        scorecard: pd.DataFrame,
        *,
        as_of_date: str,
        history: pd.DataFrame | None = None,
        last_validation_date: str | None = None,
        change_log: pd.DataFrame | None = None,
    ) -> tuple[pd.DataFrame, GovernanceSummary]:
        """Create a breach-action register and governance summary."""
        missing = sorted(self.required_scorecard_columns - set(scorecard.columns))
        if missing:
            raise ValueError(f"Scorecard is missing required columns: {', '.join(missing)}")

        as_of = pd.Timestamp(as_of_date).normalize()
        normalized_history = self._normalize_history(history)
        material_change = self._has_material_change(change_log)

        actions: list[dict[str, Any]] = []
        revalidation_reasons: set[str] = set()
        for raw_row in scorecard.to_dict(orient="records"):
            row = cast(dict[str, Any], raw_row)
            action = self._build_action(
                row,
                as_of=as_of,
                history=normalized_history,
            )
            actions.append(action)
            if bool(action["revalidation_trigger"]):
                revalidation_reasons.add(str(action["revalidation_reason"]))

        annual_status, annual_due = self._annual_validation_status(
            as_of=as_of,
            last_validation_date=last_validation_date,
        )
        if annual_status in {"OVERDUE", "NOT_EVIDENCED"}:
            revalidation_reasons.add(f"annual_independent_validation:{annual_status.lower()}")
        if material_change:
            revalidation_reasons.add("approved_material_model_change")

        action_frame = pd.DataFrame(actions)
        light_counts = action_frame["traffic_light"].value_counts().to_dict()
        red_count = int(light_counts.get("RED", 0))
        amber_count = int(light_counts.get("AMBER", 0))
        green_count = int(light_counts.get("GREEN", 0))
        overall = max(
            (str(value) for value in action_frame["traffic_light"]),
            key=lambda value: TRAFFIC_ORDER[value],
        )
        model_change_count = int(action_frame["model_change_trigger"].astype(bool).sum())
        sign_off_status = self._monthly_sign_off_status(red_count, amber_count)

        summary = GovernanceSummary(
            as_of_date=as_of.date().isoformat(),
            overall_traffic_light=overall,
            green_count=green_count,
            amber_count=amber_count,
            red_count=red_count,
            model_change_trigger_count=model_change_count,
            revalidation_required=bool(revalidation_reasons),
            revalidation_reasons=tuple(sorted(revalidation_reasons)),
            monthly_sign_off_status=sign_off_status,
            annual_validation_status=annual_status,
            annual_validation_due_date=annual_due,
        )
        return action_frame, summary

    def write_outputs(
        self,
        actions: pd.DataFrame,
        summary: GovernanceSummary,
        output_dir: str | Path,
    ) -> dict[str, Path]:
        """Write the controlled governance evidence package."""
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        stamp = summary.as_of_date.replace("-", "")

        register_path = output_path / f"monitoring_breach_register_{stamp}.csv"
        summary_path = output_path / f"monitoring_governance_summary_{stamp}.json"
        report_path = output_path / f"monitoring_escalation_report_{stamp}.md"
        signoff_path = output_path / f"monthly_signoff_template_{stamp}.csv"

        actions.to_csv(register_path, index=False)
        summary_path.write_text(
            json.dumps(asdict(summary), indent=2, sort_keys=True),
            encoding="utf-8",
        )
        report_path.write_text(
            self._render_markdown(actions, summary),
            encoding="utf-8",
        )
        self._build_signoff_template(summary).to_csv(signoff_path, index=False)
        return {
            "breach_register": register_path,
            "summary": summary_path,
            "report": report_path,
            "signoff_template": signoff_path,
        }

    def _build_action(
        self,
        row: Mapping[str, Any],
        *,
        as_of: pd.Timestamp,
        history: pd.DataFrame | None,
    ) -> dict[str, Any]:
        status = str(row["status"]).upper()
        if status not in self.status_mapping:
            raise ValueError(f"Unsupported monitoring status: {status}")
        traffic_light = self.status_mapping[status]
        level = self.levels[traffic_light]
        control = str(row["control"])
        owner = self.ownership.get(control, self.ownership["default"])
        severity = str(row["severity"])

        investigation_required = bool(level["investigation_required"])
        model_change_trigger = self._model_change_trigger(control, traffic_light)
        repeated_trigger, repeated_reason = self._repeated_breach_trigger(
            control=control,
            traffic_light=traffic_light,
            as_of=as_of,
            history=history,
        )
        critical_red = traffic_light == "RED" and severity.lower() == "critical"
        revalidation_trigger = critical_red or repeated_trigger
        revalidation_reason = ""
        if critical_red:
            revalidation_reason = f"{control}:critical_red_breach"
        elif repeated_trigger:
            revalidation_reason = repeated_reason

        return {
            "as_of_date": as_of.date().isoformat(),
            "control": control,
            "metric": str(row["metric"]),
            "value": row["value"],
            "warning_threshold": row["warning_threshold"],
            "failure_threshold": row["failure_threshold"],
            "monitoring_status": status,
            "traffic_light": traffic_light,
            "severity": severity,
            "primary_owner": str(owner["primary_owner"]),
            "secondary_owner": str(owner["secondary_owner"]),
            "escalation_route": " -> ".join(str(item) for item in level["escalation_route"]),
            "acknowledgment_due_date": self._due_date(
                as_of,
                level.get("acknowledgment_business_days"),
                traffic_light,
            ),
            "investigation_due_date": self._due_date(
                as_of,
                level.get("investigation_business_days"),
                traffic_light,
            ),
            "remediation_due_date": self._remediation_due_date(
                as_of=as_of,
                level=level,
                owner=owner,
                traffic_light=traffic_light,
            ),
            "investigation_required": investigation_required,
            "use_restriction_assessment": bool(level["use_restriction_assessment"]),
            "model_change_trigger": model_change_trigger,
            "revalidation_trigger": revalidation_trigger,
            "revalidation_reason": revalidation_reason,
            "required_investigation": " | ".join(
                str(item) for item in owner["investigation_requirements"]
            ),
            "required_evidence": " | ".join(str(item) for item in owner["required_evidence"]),
            "message": str(row["message"]),
            "details": str(row["details"]),
            "disposition_status": "NO_ACTION" if traffic_light == "GREEN" else "OPEN",
            "management_acceptance_required": traffic_light == "RED",
        }

    def _model_change_trigger(self, control: str, traffic_light: str) -> bool:
        if traffic_light == "GREEN":
            return False
        controls = set(str(item) for item in self.trigger_config["model_change_controls"])
        amber_controls = set(
            str(item) for item in self.trigger_config["amber_model_change_controls"]
        )
        return control in controls and (traffic_light == "RED" or control in amber_controls)

    def _repeated_breach_trigger(
        self,
        *,
        control: str,
        traffic_light: str,
        as_of: pd.Timestamp,
        history: pd.DataFrame | None,
    ) -> tuple[bool, str]:
        if history is None or history.empty or traffic_light == "GREEN":
            return False, ""

        same_control = history.loc[history["control"].astype(str) == control].copy()
        if same_control.empty:
            return False, ""

        if traffic_light == "RED":
            lookback = int(self.trigger_config["red_repeat_lookback_months"])
            start = as_of - pd.DateOffset(months=lookback)
            prior_red = same_control.loc[
                (same_control["as_of_date"] >= start)
                & (same_control["as_of_date"] < as_of)
                & (same_control["traffic_light"].astype(str).str.upper() == "RED")
            ]
            threshold = int(self.trigger_config["red_occurrences_for_revalidation"]) - 1
            if len(prior_red) >= threshold:
                return True, f"{control}:repeated_red_breach"

        if traffic_light == "AMBER":
            lookback = int(self.trigger_config["amber_repeat_lookback_months"])
            start = as_of - pd.DateOffset(months=lookback)
            prior_amber = same_control.loc[
                (same_control["as_of_date"] >= start)
                & (same_control["as_of_date"] < as_of)
                & (same_control["traffic_light"].astype(str).str.upper() == "AMBER")
            ]
            threshold = int(self.trigger_config["amber_occurrences_for_revalidation"]) - 1
            if len(prior_amber) >= threshold:
                return True, f"{control}:persistent_amber_breach"

        return False, ""

    def _annual_validation_status(
        self,
        *,
        as_of: pd.Timestamp,
        last_validation_date: str | None,
    ) -> tuple[str, str | None]:
        if not last_validation_date:
            return "NOT_EVIDENCED", None
        last_validation = pd.Timestamp(last_validation_date).normalize()
        interval = int(self.validation_config["maximum_interval_months"])
        due = last_validation + pd.DateOffset(months=interval)
        due_date = due.date().isoformat()
        if as_of > due:
            return "OVERDUE", due_date
        warning_days = int(self.validation_config["due_soon_calendar_days"])
        if (due - as_of).days <= warning_days:
            return "DUE_SOON", due_date
        return "CURRENT", due_date

    def _monthly_sign_off_status(self, red_count: int, amber_count: int) -> str:
        if red_count:
            return str(self.sign_off_config["red_status"])
        if amber_count:
            return str(self.sign_off_config["amber_status"])
        return str(self.sign_off_config["green_status"])

    def _build_signoff_template(self, summary: GovernanceSummary) -> pd.DataFrame:
        roles = [str(item) for item in self.sign_off_config["required_roles"]]
        return pd.DataFrame(
            {
                "as_of_date": [summary.as_of_date] * len(roles),
                "role": roles,
                "signer_name": [""] * len(roles),
                "decision": ["PENDING"] * len(roles),
                "signature_date": [""] * len(roles),
                "comments": [""] * len(roles),
                "governance_status": [summary.monthly_sign_off_status] * len(roles),
            }
        )

    def _render_markdown(
        self,
        actions: pd.DataFrame,
        summary: GovernanceSummary,
    ) -> str:
        lines = [
            "# Monthly Monitoring Threshold and Escalation Report",
            "",
            f"- As-of date: {summary.as_of_date}",
            f"- Overall traffic light: **{summary.overall_traffic_light}**",
            f"- Green controls: {summary.green_count}",
            f"- Amber controls: {summary.amber_count}",
            f"- Red controls: {summary.red_count}",
            f"- Monthly sign-off status: **{summary.monthly_sign_off_status}**",
            f"- Revalidation required: **{summary.revalidation_required}**",
            f"- Annual independent validation: **{summary.annual_validation_status}**",
            "",
            "## Open breaches",
            "",
        ]
        open_actions = actions.loc[actions["traffic_light"] != "GREEN"]
        if open_actions.empty:
            lines.append("No amber or red breaches were identified.")
        else:
            lines.extend(
                [
                    "| Control | Light | Severity | Owner | Investigation due | Remediation due |",
                    "|---|---|---|---|---|---|",
                ]
            )
            for raw_row in open_actions.to_dict(orient="records"):
                row = cast(dict[str, Any], raw_row)
                lines.append(
                    "| {control} | {traffic_light} | {severity} | {primary_owner} | "
                    "{investigation_due_date} | {remediation_due_date} |".format(**row)
                )

        lines.extend(["", "## Revalidation reasons", ""])
        if summary.revalidation_reasons:
            lines.extend(f"- {reason}" for reason in summary.revalidation_reasons)
        else:
            lines.append("- None.")

        lines.extend(
            [
                "",
                "## Required governance disposition",
                "",
                "All amber and red items require documented root-cause analysis, evidence, "
                "owner assignment, target dates, and closure verification. Red items additionally "
                "require a model-use restriction assessment and management acceptance before "
                "monthly sign-off.",
                "",
                "The thresholds in this project are controlled benchmark thresholds for a "
                "public-data, synthetic-member implementation. They are not represented as "
                "confidential FICC production thresholds or participant outcomes.",
                "",
            ]
        )
        return "\n".join(lines)

    @staticmethod
    def _normalize_history(history: pd.DataFrame | None) -> pd.DataFrame | None:
        if history is None:
            return None
        required = {"as_of_date", "control", "traffic_light"}
        missing = sorted(required - set(history.columns))
        if missing:
            raise ValueError(f"History is missing required columns: {', '.join(missing)}")
        normalized = history.copy()
        normalized["as_of_date"] = pd.to_datetime(
            normalized["as_of_date"],
            errors="coerce",
        )
        return normalized.dropna(subset=["as_of_date"])

    @staticmethod
    def _has_material_change(change_log: pd.DataFrame | None) -> bool:
        if change_log is None or change_log.empty:
            return False
        if "material_change" not in change_log.columns:
            raise ValueError("Change log requires a material_change column.")
        values = change_log["material_change"]
        if pd.api.types.is_bool_dtype(values):
            return bool(values.fillna(False).any())
        normalized = values.astype(str).str.strip().str.lower()
        return bool(normalized.isin({"true", "1", "yes", "y"}).any())

    @staticmethod
    def _due_date(
        as_of: pd.Timestamp,
        business_days: Any,
        traffic_light: str,
    ) -> str:
        if traffic_light == "GREEN" or business_days is None:
            return ""
        due = as_of + pd.offsets.BDay(int(business_days))
        return due.date().isoformat()

    @staticmethod
    def _remediation_due_date(
        *,
        as_of: pd.Timestamp,
        level: Mapping[str, Any],
        owner: Mapping[str, Any],
        traffic_light: str,
    ) -> str:
        if traffic_light == "GREEN":
            return ""
        override_key = f"{traffic_light.lower()}_remediation_business_days"
        business_days = owner.get(
            override_key,
            level.get("remediation_business_days"),
        )
        due = as_of + pd.offsets.BDay(int(business_days))
        return due.date().isoformat()


def _read_table(path: str | Path) -> pd.DataFrame:
    source = Path(path)
    suffix = source.suffix.lower()
    if suffix == ".csv":
        return pd.read_csv(source)
    if suffix in {".parquet", ".pq"}:
        return pd.read_parquet(source)
    raise ValueError(f"Unsupported table format: {source}")


def build_demo_scorecard() -> pd.DataFrame:
    """Build deterministic monitoring results for the governance smoke test."""
    return pd.DataFrame(
        [
            {
                "control": "data_completeness",
                "metric": "minimum_required_field_completeness",
                "value": 0.997,
                "warning_threshold": 0.995,
                "failure_threshold": 0.980,
                "status": "PASS",
                "severity": "High",
                "message": "Minimum non-null ratio across required fields.",
                "details": "",
            },
            {
                "control": "exposure_concentration",
                "metric": "largest_member_share",
                "value": 0.225,
                "warning_threshold": 0.200,
                "failure_threshold": 0.300,
                "status": "WARN",
                "severity": "High",
                "message": "Largest member share of absolute exposure.",
                "details": "hhi=0.185000",
            },
            {
                "control": "lcr_distribution",
                "metric": "lcr_5th_percentile",
                "value": 0.98,
                "warning_threshold": 1.05,
                "failure_threshold": 1.00,
                "status": "FAIL",
                "severity": "Critical",
                "message": "Lower-tail LCR control.",
                "details": "breach_rate=0.012",
            },
        ]
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Apply Section 30 monitoring thresholds and escalation governance."
    )
    parser.add_argument("--scorecard", help="Section 29 scorecard CSV or Parquet.")
    parser.add_argument(
        "--config",
        default="configs/monitoring_governance.yaml",
        help="Controlled governance YAML.",
    )
    parser.add_argument("--history", help="Prior governance history CSV or Parquet.")
    parser.add_argument("--change-log", help="Approved change log CSV or Parquet.")
    parser.add_argument("--as-of-date", required=False)
    parser.add_argument("--last-validation-date")
    parser.add_argument(
        "--output-dir",
        default="reports/monitoring/governance",
    )
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--fail-on-red", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.demo:
        scorecard = build_demo_scorecard()
        as_of_date = args.as_of_date or "2026-06-30"
        last_validation_date = args.last_validation_date or "2026-01-15"
    else:
        if not args.scorecard:
            raise ValueError("--scorecard is required unless --demo is used.")
        if not args.as_of_date:
            raise ValueError("--as-of-date is required unless --demo is used.")
        scorecard = _read_table(args.scorecard)
        as_of_date = args.as_of_date
        last_validation_date = args.last_validation_date

    history = _read_table(args.history) if args.history else None
    change_log = _read_table(args.change_log) if args.change_log else None
    engine = MonitoringGovernanceEngine.from_yaml(args.config)
    actions, summary = engine.evaluate(
        scorecard,
        as_of_date=as_of_date,
        history=history,
        last_validation_date=last_validation_date,
        change_log=change_log,
    )
    paths = engine.write_outputs(actions, summary, args.output_dir)
    print(json.dumps({key: str(value) for key, value in paths.items()}, indent=2))
    print(json.dumps(asdict(summary), indent=2))
    return 2 if args.fail_on_red and summary.red_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
