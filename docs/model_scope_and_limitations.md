# Model Scope and Limitations

## Scope statement

This project models a public-data proxy for FICC GSD Treasury-clearing liquidity stress. The unit of analysis is a synthetic member family; the output is a research estimate of stressed net liquidity requirements, proxy available qualifying liquid resources, coverage ratios, and shortfalls. Actual FICC members, obligations, resources, intraday payment queues, and default-management actions are outside the observable dataset.

## In-scope components

| Component | In scope | Treatment |
| --- | --- | --- |
| Treasury cash and repo market conditions | Yes | Observed aggregate Federal Reserve or other authoritative public data |
| Dealer positions, transactions, financing, and fails | Yes | Observed aggregates; derived features are separately labeled |
| Synthetic member-family exposures | Yes | Generated from documented allocation and concentration assumptions |
| Cover One | Yes | Baseline: largest synthetic member-family requirement |
| Cover Two | Yes | Conservative challenger: two largest synthetic member-family requirements |
| Historical replay | Yes | Public observed or derived shocks applied through the proxy model |
| Hypothetical stress | Yes | Configuration-controlled assumed shocks |
| Resource sufficiency | Yes, as a proxy | Uses public observed aggregates where suitable and explicitly assumed or synthetic amounts otherwise |
| Actual FICC compliance determination | No | Prohibited interpretation |

## Data-classification standard

Every numeric analytical value must have exactly one primary classification:

| Classification | Definition | Example | Permitted claim |
| --- | --- | --- | --- |
| Observed | Value published by an authoritative source and retained without analytical alteration other than type or unit normalization | Published aggregate dealer financing or SOFR volume | The source reported this aggregate value |
| Derived | Deterministic transformation of observed values | Weekly change, rolling volatility, normalized stress percentile | The value was calculated from named observed inputs |
| Synthetic | Artificial micro-level value created to make analysis possible without confidential data | Synthetic member-family exposure | The value is simulated and does not identify a real member |
| Assumed | Expert, policy, or scenario choice not directly established by the public data | Resource-availability haircut or Cover Two dependence parameter | The value is a documented scenario assumption |
| Modeled | Output produced by a statistical, econometric, allocation, or stress model | Stressed requirement, LCR, or shortfall | The value is a model estimate subject to validation |

Required lineage fields are `value_type`, `source_id`, `source_url`, `as_of_date`, `retrieval_timestamp_utc`, `transformation_id`, `assumption_id`, `scenario_id`, and `model_version`. Nonapplicable fields must be null, not fabricated. A modeled value must retain links to all material observed, derived, synthetic, and assumed inputs.

## Explicit public aggregate-data limitations

Public aggregate data do not reveal:

- actual FICC member or affiliate-family positions, novated trades, obligations, concentration, or defaults;
- actual intraday settlement timing, payment queues, operational delays, liquidity calls, or end-of-day closeout activity;
- member-specific clearing-fund deposits, CCLF obligations, committed facility terms, draw capacity, collateral eligibility, haircuts, or operational availability;
- FICC's confidential scenario design, dependence structure, stress parameters, liquidity forecast, backtesting exceptions, management overlays, or intraday monitoring;
- the mapping between primary dealers and FICC member families or the activity of non-primary-dealer clearing participants;
- transaction-level distributions hidden by aggregation, including tail exposures and offsetting positions.

Consequences of these limitations:

1. Aggregate dealer activity cannot be disaggregated into true member exposures. Any allocation is synthetic.
2. Aggregate market volumes cannot be interpreted as FICC settlement obligations or liquidity needs.
3. Quarterly public resource disclosures and weekly or daily market series create frequency mismatch.
4. Reporting-definition changes can cause structural breaks that resemble economic shocks.
5. Revised observations, publication lags, missing values, and event-window coverage can affect backtests.
6. A proxy LCR above one does not prove actual FICC liquidity sufficiency; a proxy LCR below one does not prove an actual FICC shortfall.
7. Cover Two results are an analytical challenger, not a statement that FICC is required to or does maintain Cover Two for GSD.

## Model boundary

The project begins with ingestion of named public datasets and ends with research reports and validation findings. It excludes production deployment, real-time clearing integration, confidential or personal data, legal advice, regulatory reporting, recovery and wind-down execution, and actual liquidity facility activation.

## Controls required by later phases

- source-file checksums and immutable raw-data storage;
- schema, unit, frequency, revision, and missingness tests;
- explicit definition-break handling;
- deterministic random seeds for synthetic allocations;
- configuration-controlled scenarios and assumptions;
- no real-firm labels in synthetic member data;
- independent code reconciliation for coverage and shortfall formulas;
- separate reporting of observed evidence and model inference;
- limitation banner on every decision-facing report or dashboard.

## Interpretation policy

Language such as "FICC will require," "FICC member exposure," or "FICC is insufficient" is prohibited unless supported by actual authoritative evidence for that exact claim. Preferred language is "public-data proxy," "synthetic member family," "modeled requirement," and "research scenario." Material conclusions must state the dominant data and assumption limitations.

## Acceptance

This scope is accepted for public-data research and independent model-validation development by Yousef Nejatbakhsh on 2026-07-19. Approval status: **APPROVED**.
