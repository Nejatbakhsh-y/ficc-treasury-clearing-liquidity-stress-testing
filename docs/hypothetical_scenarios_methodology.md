# Section 21 â€” Hypothetical Scenarios

## Objective

Section 21 establishes a controlled hypothetical-scenario library for FICC Treasury clearing liquidity stress testing. It converts explicit, reviewable assumptions into inputs for the validated Phase V Treasury, repo-funding, collateral-haircut, settlement-fail, and integrated liquidity models.

The framework applies hypothetical market and operational shocks only to fictional synthetic clearing-member portfolios. It does not identify, estimate, rank, or infer any actual FICC participant.

## Required scenario library

The controlled library contains eleven scenarios:

1. Moderate stress.
2. Severe stress.
3. Extreme but plausible stress.
4. Parallel Treasury shock.
5. Treasury curve steepening.
6. Treasury curve flattening.
7. SOFR spike.
8. Repo rollover failure.
9. Collateral haircut increase.
10. Settlement-fail increase.
11. Combined systemic stress.

The first three scenarios provide broad severity tiers. The next seven isolate individual or closely related transmission channels. The combined systemic scenario applies simultaneous shocks across Treasury valuation, secured funding, collateral, settlement, concentration, and the operational liquidity buffer.

## Scenario architecture

Scenario assumptions are stored in `configs/hypothetical_scenarios.yaml`. Each scenario contains five controlled blocks:

- `treasury`: yield-curve shape and basis-point shocks;
- `funding`: SOFR, spread, rollover, lender-withdrawal, refinancing-horizon, and funding-concentration assumptions;
- `haircut`: maturity-dependent haircut, collateral-call, concentration, and inventory-availability assumptions;
- `settlement`: fails-to-receive, fails-to-deliver, payment-delay, replacement-liquidity, persistence, and funding-interaction assumptions;
- `integrated`: residual concentration and operational-liquidity-buffer assumptions used by Section 19.

All assumptions are subject to explicit numerical guardrails. A scenario outside those guardrails fails configuration validation before any model is executed.

## Treasury shocks

Parallel Treasury scenarios apply the same basis-point movement to every Section 15 maturity bucket. Curve steepening and flattening are represented as linear shock vectors between the shortest and longest configured maturity midpoints. The resulting bucket vector is passed to the existing Section 15 duration-plus-convexity model, including its liquidation-horizon, concentration, and market-impact controls.

A zero Treasury block is represented by `shape: none`. Such a scenario is passed to Section 19 with `treasury_scenario_name: NONE`, preventing the creation of a fictitious Treasury loss.

## Component-model execution

Each hypothetical scenario is executed independently as a control-plus-target pair:

- Section 16 receives the scenario-specific repo-funding assumptions.
- Section 17 receives the scenario-specific collateral-haircut assumptions.
- Section 18 receives the scenario-specific settlement assumptions and the corresponding Section 16 cash flows.
- Section 15 receives the scenario-specific Treasury bucket vector where applicable.
- Section 19 combines the atomic outputs and calculates stressed liquidity requirement, available qualified liquid resources, liquidity headroom, shortfall, and liquidity coverage ratio.

Independent control-plus-target execution prevents unrelated targeted scenarios from being forced into a false global severity ordering. Accounting, identity, bound, and synthetic-data controls remain mandatory for every scenario. Component feature-coverage checks that are meaningful only for the full Section 16 or Section 18 libraries are recorded but are not incorrectly required for isolated single-channel scenarios.

## No-double-counting control

Section 21 uses the Section 19 atomic integration design. It includes:

- settlement liquidity need;
- repo rollover need;
- incremental funding cost;
- additional haircut requirement;
- Treasury liquidation loss;
- settlement-fail requirement;
- concentration adjustment;
- operational liquidity buffer.

Composite Section 16 and Section 18 totals and Section 17 stressed-resource reductions remain excluded from additive integration. The Section 19 double-counting control must pass for every Section 21 scenario.

## Validation requirements

The automation requires:

- all eleven required scenarios and all required scenario families;
- unique scenario names and display orders;
- guardrail compliance;
- complete Treasury maturity vectors for active Treasury scenarios;
- component accounting and model-identity checks;
- integrated stressed-liquidity identity checks;
- passing double-counting controls;
- deterministic scenario construction;
- unique scenario-member keys;
- synthetic-member-only results;
- no actual-participant or participant-level inference.

## Controlled outputs

The framework produces CSV and, where supported, Parquet versions of:

- `reports/tables/hypothetical_scenario_catalog`;
- `reports/tables/hypothetical_treasury_shocks`;
- `reports/tables/hypothetical_component_summary`;
- `reports/tables/hypothetical_component_checks`;
- `reports/tables/hypothetical_scenario_member_results`;
- `reports/tables/hypothetical_scenario_summary`;
- `reports/tables/hypothetical_scenario_double_count_controls`.

Validation evidence is written to:

- `reports/evidence/section21_hypothetical_scenarios.json`;
- `reports/evidence/section21_hypothetical_scenarios.md`;
- `reports/evidence/section21_automation_gate.txt`;
- `data/manifests/hypothetical_scenario_manifest.csv`.

Smoke-mode evidence uses the `_smoke` suffix and executes moderate stress, curve steepening, and combined systemic stress.

## Interpretation

Hypothetical scenarios are model-risk tools, not forecasts. Their values represent controlled assumptions selected to test liquidity resilience and model behavior. â€œExtreme but plausibleâ€ indicates a scenario within the documented Section 21 guardrails; it is not a probability statement and does not imply that the scenario is expected to occur.
