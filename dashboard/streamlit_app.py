"""Phase IX, Section 33 controlled Streamlit dashboard."""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd
import streamlit as st

from ficc_liquidity.dashboard.core import COMPONENT_COLUMNS, DatasetBundle, load_dataset

ROOT = Path(__file__).resolve().parents[1]
ALLOW_DEMO = os.environ.get("FICC_DASHBOARD_ALLOW_DEMO", "1") == "1"

st.set_page_config(
    page_title="FICC Treasury Clearing Liquidity Stress Testing",
    layout="wide",
    initial_sidebar_state="expanded",
)

st.markdown(
    """
    <style>
    .block-container {padding-top: 1.4rem; padding-bottom: 3rem;}
    [data-testid="stMetric"] {
        background: #ffffff;
        border: 1px solid #d8e0ea;
        border-radius: 0.55rem;
        padding: 0.75rem;
    }
    .section-note {
        border-left: 4px solid #17365d;
        background: #eef3f8;
        padding: 0.75rem 1rem;
        margin: 0.6rem 0 1rem 0;
    }
    .demo-warning {
        border-left: 4px solid #8a5a00;
        background: #fff8e6;
        padding: 0.75rem 1rem;
        margin: 0.6rem 0 1rem 0;
    }
    .source-note {
        color: #526170;
        font-size: 0.88rem;
    }
    </style>
    """,
    unsafe_allow_html=True,
)


@st.cache_data(ttl=300, show_spinner=False)
def cached_dataset(key: str, allow_demo: bool) -> DatasetBundle:
    return load_dataset(ROOT, key, allow_demo=allow_demo)


def dataset(key: str) -> DatasetBundle:
    bundle = cached_dataset(key, ALLOW_DEMO)
    if bundle.is_demo:
        st.markdown(
            f'<div class="demo-warning"><strong>Demonstration data.</strong> {bundle.note}</div>',
            unsafe_allow_html=True,
        )
    st.markdown(
        f'<div class="source-note">Source: {bundle.source}</div>',
        unsafe_allow_html=True,
    )
    return bundle


def title(text: str, purpose: str) -> None:
    st.title(text)
    st.markdown(
        f'<div class="section-note">{purpose}</div>',
        unsafe_allow_html=True,
    )


def find_column(frame: pd.DataFrame, names: tuple[str, ...]) -> str | None:
    for name in names:
        if name in frame.columns:
            return name
    return None


def numeric(frame: pd.DataFrame, names: tuple[str, ...]) -> pd.Series:
    column = find_column(frame, names)
    if column is None:
        return pd.Series(dtype=float)
    return pd.to_numeric(frame[column], errors="coerce").dropna()


def money(value: float) -> str:
    return f"${value:,.1f} million"


def show_table(frame: pd.DataFrame, *, key: str, max_rows: int = 500) -> None:
    st.dataframe(frame.head(max_rows), use_container_width=True, hide_index=True)
    st.download_button(
        "Download displayed data",
        data=frame.to_csv(index=False).encode("utf-8"),
        file_name=f"{key}.csv",
        mime="text/csv",
        key=f"download_{key}",
    )


def date_filter(frame: pd.DataFrame, key: str) -> pd.DataFrame:
    date_column = find_column(frame, ("date", "as_of_date", "observation_date"))
    if date_column is None:
        return frame

    values = pd.to_datetime(frame[date_column], errors="coerce")
    valid = values.dropna()
    if valid.empty:
        return frame

    start, end = st.date_input(
        "Date range",
        value=(valid.min().date(), valid.max().date()),
        min_value=valid.min().date(),
        max_value=valid.max().date(),
        key=f"dates_{key}",
    )
    mask = values.between(pd.Timestamp(start), pd.Timestamp(end), inclusive="both")
    return frame.loc[mask].copy()


def status_counts(frame: pd.DataFrame) -> pd.DataFrame:
    column = find_column(frame, ("status", "classification", "severity"))
    if column is None:
        return pd.DataFrame()
    return (
        frame[column]
        .astype(str)
        .value_counts(dropna=False)
        .rename_axis(column)
        .reset_index(name="count")
    )


def executive_summary() -> None:
    title(
        "Executive Summary",
        "Consolidated liquidity adequacy, scenario severity, monitoring, and validation status.",
    )
    lcr = dataset("lcr_results").data
    monitoring = dataset("monitoring_results").data
    findings = dataset("findings").data

    lcr_values = numeric(lcr, ("lcr", "liquidity_coverage_ratio"))
    shortfalls = numeric(
        lcr,
        (
            "liquidity_shortfall_usd_mm",
            "liquidity_shortfall",
            "shortfall_usd_mm",
            "shortfall",
        ),
    )
    status_col = find_column(findings, ("status",))
    class_col = find_column(findings, ("classification", "severity"))
    open_material = 0
    if status_col and class_col:
        open_mask = ~findings[status_col].astype(str).str.lower().isin(
            {"closed", "resolved", "validated"}
        )
        material_mask = findings[class_col].astype(str).str.lower().isin({"critical", "high"})
        open_material = int((open_mask & material_mask).sum())

    monitor_status = find_column(monitoring, ("status",))
    failed_controls = (
        int(monitoring[monitor_status].astype(str).str.upper().eq("FAIL").sum())
        if monitor_status
        else 0
    )

    columns = st.columns(4)
    columns[0].metric("Minimum LCR", f"{lcr_values.min():.2f}" if not lcr_values.empty else "N/A")
    columns[1].metric(
        "Maximum shortfall",
        money(float(shortfalls.max())) if not shortfalls.empty else "N/A",
    )
    columns[2].metric("Failed monitoring controls", failed_controls)
    columns[3].metric("Open Critical or High findings", open_material)

    scenario_col = find_column(lcr, ("scenario", "scenario_name"))
    if scenario_col and not lcr_values.empty:
        chart = lcr[[scenario_col]].copy()
        chart["LCR"] = pd.to_numeric(
            lcr[find_column(lcr, ("lcr", "liquidity_coverage_ratio"))],
            errors="coerce",
        )
        st.subheader("Scenario LCR")
        st.bar_chart(chart.set_index(scenario_col), use_container_width=True)

    st.subheader("Scenario results")
    show_table(lcr, key="executive_scenario_results")


def federal_reserve_conditions() -> None:
    title(
        "Federal Reserve Market Conditions",
        "Public-source funding, Treasury-yield, reserves, and settlement-fail indicators.",
    )
    frame = date_filter(dataset("market_conditions").data, "market")
    date_col = find_column(frame, ("date", "observation_date", "as_of_date"))

    rate_columns = [
        column
        for column in (
            "sofr_rate_pct",
            "sofr",
            "treasury_2y_yield_pct",
            "treasury_10y_yield_pct",
            "yield_2y",
            "yield_10y",
        )
        if column in frame.columns
    ]
    if date_col and rate_columns:
        st.subheader("Rates and Treasury yields")
        chart = frame[[date_col, *rate_columns]].copy().set_index(date_col)
        st.line_chart(chart, use_container_width=True)

    liquidity_columns = [
        column
        for column in (
            "sofr_volume_usd_bn",
            "reserve_balances_usd_bn",
            "settlement_fails_usd_bn",
            "transaction_volume",
            "reserve_balances",
            "settlement_fails",
        )
        if column in frame.columns
    ]
    if date_col and liquidity_columns:
        st.subheader("Funding and system liquidity indicators")
        chart = frame[[date_col, *liquidity_columns]].copy().set_index(date_col)
        st.line_chart(chart, use_container_width=True)

    show_table(frame, key="federal_reserve_market_conditions")


def synthetic_member_exposures() -> None:
    title(
        "Synthetic Member Exposures",
        "Fictional clearing-member portfolios used for model development and validation.",
    )
    frame = dataset("member_exposures").data
    member_col = find_column(frame, ("member_id", "synthetic_member_id", "member"))
    bucket_col = find_column(frame, ("maturity_bucket", "treasury_maturity", "bucket"))

    filtered = frame.copy()
    if member_col:
        options = sorted(filtered[member_col].dropna().astype(str).unique())
        selected = st.multiselect("Synthetic members", options, default=options[:5])
        if selected:
            filtered = filtered[filtered[member_col].astype(str).isin(selected)]
    if bucket_col:
        options = sorted(filtered[bucket_col].dropna().astype(str).unique())
        selected = st.multiselect("Maturity buckets", options, default=options)
        if selected:
            filtered = filtered[filtered[bucket_col].astype(str).isin(selected)]

    exposure_col = find_column(
        filtered,
        ("treasury_position_usd_mm", "exposure", "market_value_usd_mm"),
    )
    if member_col and exposure_col:
        grouped = (
            filtered.groupby(member_col, as_index=False)[exposure_col]
            .sum()
            .sort_values(exposure_col, ascending=False)
        )
        st.subheader("Treasury exposure by synthetic member")
        st.bar_chart(grouped.set_index(member_col), use_container_width=True)

    show_table(filtered, key="synthetic_member_exposures")


def cover_analysis() -> None:
    title(
        "Cover 1 and Cover 2",
        "Stressed requirements, available resources, LCR, shortfall, and dominant stress driver.",
    )
    frame = dataset("cover_results").data
    cover_col = find_column(frame, ("cover_standard", "cover_type", "default_set"))
    if cover_col:
        options = sorted(frame[cover_col].dropna().astype(str).unique())
        selected = st.multiselect("Cover standard", options, default=options)
        if selected:
            frame = frame[frame[cover_col].astype(str).isin(selected)]

    lcr_values = numeric(frame, ("lcr", "liquidity_coverage_ratio"))
    shortfalls = numeric(
        frame,
        ("liquidity_shortfall_usd_mm", "liquidity_shortfall", "shortfall"),
    )
    columns = st.columns(3)
    columns[0].metric("Minimum LCR", f"{lcr_values.min():.2f}" if not lcr_values.empty else "N/A")
    columns[1].metric(
        "Maximum shortfall",
        money(float(shortfalls.max())) if not shortfalls.empty else "N/A",
    )
    columns[2].metric("Scenarios", len(frame))

    show_table(frame, key="cover_1_cover_2")


def scenario_page(key: str, heading: str, purpose: str) -> None:
    title(heading, purpose)
    frame = dataset(key).data
    scenario_col = find_column(frame, ("scenario", "scenario_name"))
    lcr_col = find_column(frame, ("lcr", "liquidity_coverage_ratio"))
    if scenario_col and lcr_col:
        chart = frame[[scenario_col, lcr_col]].copy()
        chart[lcr_col] = pd.to_numeric(chart[lcr_col], errors="coerce")
        st.bar_chart(chart.set_index(scenario_col), use_container_width=True)
    show_table(frame, key=key)


def lcr_page() -> None:
    title(
        "Liquidity Coverage Ratio",
        "Scenario-level and default-set liquidity adequacy relative to "
        "available qualified resources.",
    )
    frame = dataset("lcr_results").data
    lcr_col = find_column(frame, ("lcr", "liquidity_coverage_ratio"))
    scenario_col = find_column(frame, ("scenario", "scenario_name"))

    if lcr_col:
        threshold = st.number_input("LCR threshold", min_value=0.0, value=1.0, step=0.05)
        frame = frame.copy()
        frame["dashboard_lcr_status"] = (
            pd.to_numeric(frame[lcr_col], errors="coerce")
            .ge(threshold)
            .map({True: "Adequate", False: "Breach"})
        )

    if scenario_col and lcr_col:
        st.bar_chart(frame.set_index(scenario_col)[[lcr_col]], use_container_width=True)
    show_table(frame, key="liquidity_coverage_ratio")


def shortfall_page() -> None:
    title(
        "Liquidity Shortfalls",
        "Positive funding gaps by scenario and default-set assumption.",
    )
    frame = dataset("lcr_results").data
    shortfall_col = find_column(
        frame,
        (
            "liquidity_shortfall_usd_mm",
            "liquidity_shortfall",
            "shortfall_usd_mm",
            "shortfall",
        ),
    )
    scenario_col = find_column(frame, ("scenario", "scenario_name"))
    if shortfall_col:
        values = pd.to_numeric(frame[shortfall_col], errors="coerce").fillna(0.0)
        breaches_only = st.checkbox("Show positive shortfalls only", value=True)
        if breaches_only:
            frame = frame.loc[values.gt(0.0)].copy()
        if scenario_col and not frame.empty:
            st.bar_chart(frame.set_index(scenario_col)[[shortfall_col]], use_container_width=True)
    show_table(frame, key="liquidity_shortfalls")


def component_page() -> None:
    title(
        "Component Contributions",
        "Contribution of each Section 19 stress component without double counting.",
    )
    frame = dataset("component_contributions").data
    scenario_col = find_column(frame, ("scenario", "scenario_name"))
    available = [column for column in COMPONENT_COLUMNS if column in frame.columns]

    if scenario_col and available:
        scenario_options = frame[scenario_col].dropna().astype(str).unique().tolist()
        selected = st.selectbox("Scenario", scenario_options)
        row = frame.loc[frame[scenario_col].astype(str).eq(selected), available]
        if not row.empty:
            contribution = row.iloc[0].astype(float).sort_values(ascending=False)
            st.bar_chart(contribution, use_container_width=True)

    show_table(frame, key="component_contributions")


def sensitivity_page() -> None:
    title(
        "Sensitivity Analysis",
        "Parameter directionality, monotonicity, elasticity, and LCR response.",
    )
    frame = dataset("sensitivity_results").data
    driver_col = find_column(frame, ("risk_driver", "parameter", "sensitivity"))
    elasticity_col = find_column(frame, ("elasticity", "lcr_elasticity"))
    if driver_col and elasticity_col:
        chart = frame[[driver_col, elasticity_col]].copy()
        chart[elasticity_col] = pd.to_numeric(chart[elasticity_col], errors="coerce")
        st.bar_chart(chart.set_index(driver_col), use_container_width=True)
    show_table(frame, key="sensitivity_analysis")


def reverse_stress_page() -> None:
    title(
        "Reverse Stress",
        "Minimum individual and combined stresses that produce LCR failure "
        "or a liquidity shortfall.",
    )
    frame = dataset("reverse_stress").data
    show_table(frame, key="reverse_stress")


def monitoring_page() -> None:
    title(
        "Model Monitoring",
        "Monthly control status, threshold breaches, ownership, and escalation indicators.",
    )
    frame = dataset("monitoring_results").data
    counts = status_counts(frame)
    if not counts.empty:
        status_col = counts.columns[0]
        st.bar_chart(counts.set_index(status_col), use_container_width=True)
    show_table(frame, key="model_monitoring")


def findings_page() -> None:
    title(
        "Findings and Remediation",
        "Controlled validation findings, classifications, ownership, target dates, and status.",
    )
    frame = dataset("findings").data
    classification = find_column(frame, ("classification", "severity"))
    status = find_column(frame, ("status",))
    filtered = frame.copy()

    if classification:
        options = sorted(filtered[classification].dropna().astype(str).unique())
        selected = st.multiselect("Classification", options, default=options)
        if selected:
            filtered = filtered[filtered[classification].astype(str).isin(selected)]
    if status:
        options = sorted(filtered[status].dropna().astype(str).unique())
        selected = st.multiselect("Status", options, default=options)
        if selected:
            filtered = filtered[filtered[status].astype(str).isin(selected)]

    counts = status_counts(filtered)
    if not counts.empty:
        category = counts.columns[0]
        st.bar_chart(counts.set_index(category), use_container_width=True)
    show_table(filtered, key="findings_and_remediation")


def limitations_page() -> None:
    title(
        "Limitations and Governance",
        "Model-use restrictions, residual uncertainty, public-data limitations, "
        "and governance controls.",
    )
    frame = dataset("limitations").data
    st.warning(
        "This research dashboard uses public Federal Reserve aggregate data and fictional "
        "synthetic members. It must not be represented as an actual FICC production model, "
        "an actual participant exposure report, or a substitute for controlled intraday data."
    )
    st.subheader("Required governance controls")
    st.markdown(
        """
        1. Monthly model-performance monitoring and documented sign-off.
        2. Annual independent validation and issue closure verification.
        3. Controlled configuration, source lineage, and reproducible evidence.
        4. Independent review of model changes, threshold changes, and scenario changes.
        5. Explicit restriction against identifying or inferring actual FICC participants.
        """
    )
    show_table(frame, key="limitations_and_governance")


def historical_stress_scenarios_page() -> None:
    scenario_page(
        "historical_scenarios",
        "Historical Stress Scenarios",
        "Historical market episodes used for plausibility and severity assessment.",
    )


def hypothetical_scenarios_page() -> None:
    scenario_page(
        "hypothetical_scenarios",
        "Hypothetical Scenarios",
        ("Moderate, severe, extreme, curve, funding, haircut, fail, and combined stresses."),
    )


PAGES: dict[str, list[st.Page]] = {
    "Overview": [
        st.Page(executive_summary, title="Executive summary", default=True),
        st.Page(federal_reserve_conditions, title="Federal Reserve market conditions"),
        st.Page(synthetic_member_exposures, title="Synthetic member exposures"),
    ],
    "Stress Results": [
        st.Page(cover_analysis, title="Cover 1 and Cover 2"),
        st.Page(
            historical_stress_scenarios_page,
            title="Historical stress scenarios",
            url_path="historical-stress-scenarios",
        ),
        st.Page(
            hypothetical_scenarios_page,
            title="Hypothetical scenarios",
            url_path="hypothetical-scenarios",
        ),
        st.Page(lcr_page, title="Liquidity Coverage Ratio"),
        st.Page(shortfall_page, title="Liquidity shortfalls"),
        st.Page(component_page, title="Component contributions"),
    ],
    "Validation and Governance": [
        st.Page(sensitivity_page, title="Sensitivity analysis"),
        st.Page(reverse_stress_page, title="Reverse stress"),
        st.Page(monitoring_page, title="Model monitoring"),
        st.Page(findings_page, title="Findings and remediation"),
        st.Page(limitations_page, title="Limitations and governance"),
    ],
}

with st.sidebar:
    st.markdown("## Section 33")
    st.caption("Phase IX - Reporting and Dashboard")
    st.caption("Repository evidence is preferred. Synthetic fallback data are clearly labelled.")
    if st.button("Refresh repository evidence"):
        cached_dataset.clear()
        st.rerun()

navigation = st.navigation(PAGES, position="sidebar", expanded=True)
navigation.run()
