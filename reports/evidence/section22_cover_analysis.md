# Section 22 â€” Cover 1 and Cover 2 Analysis

- Generated at: `2026-07-23T23:32:24.555482+00:00`
- Source table: `C:/Users/nejat/OneDrive/Desktop/UN/Skills/GitHub 2026/ficc-treasury-clearing-liquidity-stress-testing/reports/tables/hypothetical_scenario_member_results.parquet`
- Scenario count: `11`
- Cover-result rows: `22`
- Actual FICC participants represented: `NO`
- Participant-level inference performed: `NO`

## Validation checks

- Actual Ficc Participants Excluded: `PASS`
- Available Resources Nonnegative: `PASS`
- Component Reconciliation: `PASS`
- Cover 1 Member Count: `PASS`
- Cover 2 Member Count: `PASS`
- Cover 2 Not Less Than Cover 1: `PASS`
- Deterministic Reproduction: `PASS`
- Liquidity Shortfall Identity: `PASS`
- One Dominant Component Per Cover: `PASS`
- Scenario Coverage Complete: `PASS`
- Selected Members Unique Within Cover: `PASS`
- Synthetic Identifiers Only: `PASS`

## Metric definitions

- Cover 1: the synthetic member with the largest gross stressed liquidity requirement within each scenario.
- Cover 2: the two synthetic members with the largest gross stressed liquidity requirements within each scenario.
- Available resources: sum of selected members' available qualified liquid resources.
- LCR: available resources divided by the Cover stressed requirement.
- Liquidity shortfall: maximum of requirement minus resources and zero.
- Resource utilization: Cover stressed requirement divided by available resources.
- Dominant stress component: largest aggregated atomic stress component for the selected Cover set.

## Final decision: PASS
