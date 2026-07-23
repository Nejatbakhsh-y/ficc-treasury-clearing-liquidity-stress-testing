# Section 19 â€” Integrated Stressed Liquidity Requirement

## Purpose

Section 19 combines the controlled liquidity-stress outputs produced in
Sections 14 through 18 into one auditable stressed liquidity requirement and
one liquidity coverage ratio for each fictional synthetic clearing member and
integrated scenario.

The model does not identify, estimate, rank, or infer any actual FICC
participant.

## Core equation

For each synthetic member and integrated scenario:

```text
Settlement liquidity need
+ Repo rollover need
+ Incremental funding cost
+ Additional haircut requirement
+ Treasury liquidation loss
+ Settlement-fail requirement
+ Concentration adjustment
+ Operational liquidity buffer
= Stressed Liquidity Requirement
```

The liquidity coverage ratio is:

```text
LCR = Available Qualified Liquid Resources
      ------------------------------------
      Stressed Liquidity Requirement
```

The configured minimum passing ratio is `1.00`.

## Atomic component selection

The engine uses atomic source columns rather than composite totals.

| Integrated component | Controlled source |
|---|---|
| Settlement liquidity need | Section 14 `net_settlement_outflow_usd` |
| Repo rollover need | Section 16 `repo_rollover_failure_outflow_usd` |
| Incremental funding cost | Section 16 `incremental_funding_cost_usd` |
| Additional haircut requirement | Section 17 `additional_collateral_requirement_total_usd` |
| Treasury liquidation loss | Section 15 `treasury_loss_usd` |
| Settlement-fail requirement | Section 18 `incremental_settlement_fail_outflow_usd` |
| Concentration adjustment | Section 19 residual overlay |
| Operational liquidity buffer | Section 19 configured percentage |

## No-double-counting controls

### Section 16 funding composite

Section 16 reports:

```text
Repo rollover failure
+ Incremental funding cost
+ Additional collateral demand
= Incremental repo funding stress outflow
```

Section 19 selects only repo rollover failure and incremental funding cost. It
does not add the Section 16 composite outflow. Section 16 additional collateral
demand is excluded because Section 19 obtains the haircut-driven collateral
requirement from Section 17.

### Section 18 combined settlement and funding composite

Section 18 reports:

```text
Incremental settlement-fail outflow
+ Combined funding-shock outflow
= Incremental combined stress outflow
```

Section 19 selects only the settlement-fail outflow. It does not add either the
Section 18 funding overlay or the Section 18 combined total, because Section 16
funding components are already selected directly.

### Section 17 stressed AQLR

Section 17 stressed qualified resources subtract collateral value erosion and
posted collateral. Section 19 does not use that stressed AQLR field in the LCR
numerator while also adding the full Section 17 collateral requirement to the
denominator. Using both would duplicate posted-collateral effects.

The Section 19 numerator therefore remains the controlled Section 14
`modeled_aqlr_usd`. Haircut stress enters through the separately identified
additional haircut requirement.

### Concentration overlay

Repo funding, Treasury liquidation, and collateral haircuts already contain
their own concentration-sensitive mechanisms. The Section 19 concentration
overlay is therefore applied only to configured residual components:

- settlement liquidity need;
- settlement-fail requirement.

This prevents a second concentration charge on components already adjusted by
their source models.

### Operational buffer

The operational liquidity buffer is applied once, after the six atomic
components and the residual concentration adjustment have been combined.

## Integrated scenario mapping

The controlled configuration defines four severity-ordered scenarios:

1. `control`
2. `moderate_integrated_stress`
3. `severe_integrated_stress`
4. `extreme_integrated_crisis`

Each integrated scenario explicitly maps to one Section 16 funding scenario,
one Section 17 haircut scenario, one Section 15 Treasury scenario, and one
Section 18 settlement-fail scenario.

The control scenario assigns no Treasury liquidation shock and applies no
Section 19 concentration or operational buffer.

## Treasury maturity bridge

Section 12 and Section 15 use different Treasury maturity bucket granularity.
When a member-aligned Section 15 summary is unavailable, the Section 19 runner
uses a deterministic weighted bridge from Section 12 synthetic maturity
positions to the Section 15 maturity buckets and then calls the validated
Section 15 Treasury yield-shock model.

The source-bucket weights must sum exactly to one. The bridge is an explicit
modeling assumption and is recorded in
`configs/integrated_stress_engine.yaml`.

## Inputs

Preferred controlled inputs are:

- `reports/tables/baseline_liquidity_summary.parquet`
- `reports/tables/repo_funding_stress_member_summary.parquet`
- `reports/tables/collateral_haircut_stress_member_summary.parquet`
- `reports/tables/settlement_fail_stress_cashflows.parquet`
- a member-aligned Section 15 Treasury stress summary, or
- `data/synthetic/calibrated_member_portfolios.parquet` for the Treasury bridge.

CSV fallbacks are supported where configured.

## Outputs

The runner writes CSV and Parquet versions of:

- `reports/tables/integrated_stress_member_results`
- `reports/tables/integrated_stress_scenario_summary`
- `reports/tables/integrated_stress_double_count_controls`

When the Treasury bridge is required, it also writes:

- `reports/tables/treasury_yield_stress_member_summary_section19_adapter`
- `reports/tables/treasury_yield_stress_positions_section19_adapter`

Evidence and lineage outputs are:

- `reports/evidence/section19_integrated_stress_engine.json`
- `reports/evidence/section19_integrated_stress_engine.md`
- `data/manifests/integrated_stress_engine_manifest.csv`

## Validation gates

Section 19 fails closed unless all applicable gates pass:

- expected member-scenario row count;
- unique member-scenario keys;
- finite and nonnegative required outputs;
- stressed-requirement arithmetic identity;
- LCR arithmetic identity;
- zero-requirement LCR convention;
- LCR status identity;
- Section 16 and Section 18 composite reconciliation;
- complete scenario summary;
- nondecreasing aggregate requirement by severity;
- deterministic reproduction;
- synthetic-member-only controls.

## Model-risk limitations

- The integrated scenarios are controlled assumptions, not forecasts.
- Aggregate public data do not reveal participant-level portfolios, settlement
  timing, lender relationships, collateral substitutions, or operational
  responses.
- The Section 19 requirement is an analytical stress measure and is not an
  official FICC liquidity requirement.
- The Treasury maturity bridge introduces a documented allocation assumption.
- The residual concentration overlay is intentionally narrow to avoid duplicate
  concentration effects.
- Correlations across stress channels are represented through scenario mapping,
  not estimated participant-level joint distributions.
- AQLR remains the Section 14 modeled resource amount to prevent duplication
  with the Section 17 denominator charge.
