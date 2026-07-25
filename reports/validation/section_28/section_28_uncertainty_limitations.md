# Phase VII - Section 28: Uncertainty and Limitations Assessment

> **Evidence classification:** Illustrative synthetic calibration. This report does not use actual FICC participant-level or intraday data and must not be interpreted as an estimate of FICC liquidity needs.

## Executive conclusion

The research framework is suitable for independent methodology testing, control demonstration, sensitivity analysis, benchmark comparison, and directional model validation. It is not suitable for empirical validation of actual FICC participant exposures, legal resource availability, or intraday liquidity peaks.

The illustrative baseline requirement is $1,000,000,000, available resources are $1,150,000,000, and baseline LCR is 1.1500. Under the configured joint uncertainty envelope, the estimated frequency of LCR below 1.0 is 27.48%. This result is a model-risk diagnostic, not a forecast or regulatory measure.

## Scope and methodology

The assessment combines two controlled views:

1. A qualitative uncertainty register using probability, impact, mitigation effectiveness, inherent risk, and residual risk.
2. A quantitative uncertainty envelope using transparent triangular ranges, bounded weighted adjustments, one-at-a-time adverse tests, and a reproducible joint Monte Carlo simulation.

The quantitative envelope intentionally avoids false precision. It does not model a full joint economic distribution, confidential participant dependencies, payment queues, legal enforceability, or market microstructure.

## Quantitative uncertainty results

- Simulations: 10,000
- Deterministic seed: 2026
- Mean simulated requirement: $1,081,060,533
- 99th-percentile requirement: $1,150,460,220
- 1st-percentile available resources: $1,050,834,950
- Median LCR: 1.0217
- 5th-percentile LCR: 0.9634
- 1st-percentile LCR: 0.9413
- Probability of LCR below 1.0: 27.48%
- Maximum simulated shortfall: $130,417,915
- Largest one-at-a-time LCR reduction: Operational and legal assumptions (0.1106)

## Residual-risk prioritization

The following drivers retain High or Critical residual risk and require explicit use restrictions, challenge, or remediation:

- **Missing intraday information:** residual score 20 (Critical); owner: Model Validation.
- **Participant-level data limitations:** residual score 20 (Critical); owner: Model Risk Governance.
- **Synthetic allocation uncertainty:** residual score 18 (Critical); owner: Model Development and Model Validation.
- **Parameter uncertainty:** residual score 15 (High); owner: Model Development and Model Validation.
- **Operational and legal assumptions:** residual score 15 (High); owner: Legal, Operations, and Model Risk Governance.
- **Aggregate-data uncertainty:** residual score 13 (High); owner: Model Validation.
- **Model risk from simplified liquidation functions:** residual score 13 (High); owner: Model Development and Model Validation.
- **Scenario-selection uncertainty:** residual score 13 (High); owner: Model Validation.

## Detailed assessment by uncertainty source

### Missing intraday information

**Type:** Data granularity

**Assessment:** Daily and weekly public datasets do not show intraday settlement peaks, payment queues, timing mismatches, substitutions, or operational bottlenecks.

**Evidence gap:** Intraday cash-flow and collateral-movement data are unavailable publicly.

**Potential model effect:** End-of-day aggregation can understate peak liquidity usage and the duration of temporary shortfalls.

**Risk rating:** inherent 25 (Critical); residual 20 (Critical).

**Material limitations**

- Intraday peak requirements cannot be empirically validated.
- Payment timing and queuing are represented through conservative overlays only.

**Mitigations and compensating controls**

- Apply explicit intraday peak overlays and delayed-payment scenarios.
- Separate end-of-day and peak-liquidity conclusions in reporting.

**Independent validation actions**

- Run overlays for delayed receipts, concentrated payment windows, and multi-day fails.
- Report the range rather than a single intraday estimate.

### Participant-level data limitations

**Type:** Coverage and representativeness

**Assessment:** Public data do not provide actual FICC participant positions, settlement obligations, collateral inventories, liquidity resources, or legal agreements.

**Evidence gap:** Confidential participant and clearing-agency data are outside the research model's evidence base.

**Potential model effect:** Member ranking, wrong-way risk, concentration, default-set selection, and resource eligibility cannot be validated against actual outcomes.

**Risk rating:** inherent 25 (Critical); residual 20 (Critical).

**Material limitations**

- The model is unsuitable for participant-level decisions.
- Cover 1 and Cover 2 results are methodological demonstrations only.

**Mitigations and compensating controls**

- Use generic member identifiers and explicit synthetic-data labels.
- Restrict conclusions to methodology, controls, and directional behavior.

**Independent validation actions**

- Verify that no synthetic member is represented as an actual participant.
- Document prohibited uses in every material report.

### Synthetic allocation uncertainty

**Type:** Synthetic data construction

**Assessment:** Aggregate positions, financing, settlement obligations, and collateral are allocated to non-real synthetic clearing members.

**Evidence gap:** No public dataset provides the true participant-level allocation or dependence structure required to validate the synthetic population directly.

**Potential model effect:** Allocation rules can change default-set rankings, concentration, netting benefits, and stressed liquidity requirements.

**Risk rating:** inherent 25 (Critical); residual 18 (Critical).

**Material limitations**

- Synthetic members must never be interpreted as actual FICC participants.
- Tail dependence and concentration are assumption-driven.

**Mitigations and compensating controls**

- Use multiple seeds, alternative allocation algorithms, and concentration regimes.
- Publish allocation controls and preserve deterministic seeds.

**Independent validation actions**

- Compare scenario rankings and Cover 1/Cover 2 results across seeds.
- Challenge allocation distributions and dependence assumptions independently.

### Parameter uncertainty

**Type:** Calibration and estimation

**Assessment:** Duration, convexity, rollover failure, haircut, fail persistence, concentration, liquidation horizon, and available-resource assumptions are estimated or judgmental.

**Evidence gap:** Parameter estimates are not calibrated to confidential member-level or FICC operational data.

**Potential model effect:** Parameter uncertainty changes stressed requirements, shortfall thresholds, and the identity of dominant stress components.

**Risk rating:** inherent 25 (Critical); residual 15 (High).

**Material limitations**

- Point estimates can create false precision.
- Parameter dependence is simplified in the quantitative envelope.

**Mitigations and compensating controls**

- Use parameter ranges, sensitivity analysis, and version-controlled assumptions.
- Escalate parameters with high residual risk for targeted validation.

**Independent validation actions**

- Reconcile Section 26 sensitivity results with uncertainty rankings.
- Confirm directional behavior and boundary handling.

### Operational and legal assumptions

**Type:** Operational, legal, and governance

**Assessment:** Resource mobilization, settlement sequencing, access to credit, collateral eligibility, default-management timing, and enforceability are represented through simplified rules.

**Evidence gap:** Public documents do not provide all contractual terms, operational cutoffs, committed facility conditions, or crisis-time execution constraints.

**Potential model effect:** Resources that appear available in a static model may be delayed, encumbered, ineligible, or legally unavailable during stress.

**Risk rating:** inherent 20 (Critical); residual 15 (High).

**Material limitations**

- Legal enforceability is not independently opined upon.
- Operational execution risk is not modeled as a full process simulation.

**Mitigations and compensating controls**

- Apply resource-availability haircuts and timing restrictions.
- Require legal and operational subject-matter review before production use.

**Independent validation actions**

- Test delayed or unavailable resources and document eligibility assumptions.
- Reconcile modeled resources with Section 24 conceptual-soundness challenges.

### Aggregate-data uncertainty

**Type:** Data and measurement

**Assessment:** Public Federal Reserve series are aggregate, revised, and not aligned perfectly with FICC member portfolios or settlement timelines.

**Evidence gap:** Aggregate market statistics cannot identify member-specific cash-flow timing, netting sets, collateral eligibility, or default liquidity contributions.

**Potential model effect:** Aggregate calibration may smooth tail concentrations and obscure cross-member heterogeneity.

**Risk rating:** inherent 20 (Critical); residual 13 (High).

**Material limitations**

- Aggregate series cannot be mapped uniquely to clearing-member portfolios.
- Publication frequency may mask daily and intraday liquidity peaks.

**Mitigations and compensating controls**

- Maintain source contracts, revision logs, and conservative calibration ranges.
- Reperform calibration when source definitions or publication practices change.

**Independent validation actions**

- Compare weekly and daily transformations where both are available.
- Run conservative scaling and data-vintage sensitivity tests.

### Model risk from simplified liquidation functions

**Type:** Methodology and implementation

**Assessment:** Treasury liquidation losses are approximated with duration, convexity, concentration, liquidation-horizon, and market-impact functions rather than an order-book model.

**Evidence gap:** Public data do not provide stressed liquidation execution, bid depth, dealer capacity, or member-specific hedge behavior.

**Potential model effect:** Simplified functions may miss nonlinear price impact, liquidity spirals, basis risk, and feedback between funding and liquidation.

**Risk rating:** inherent 20 (Critical); residual 13 (High).

**Material limitations**

- Linear or piecewise approximations may understate discontinuous market impact.
- Hedging, basis, and feedback effects are simplified.

**Mitigations and compensating controls**

- Benchmark against deterministic haircuts and alternative nonlinear impact functions.
- Apply conservative liquidation horizons and concentration multipliers.

**Independent validation actions**

- Compare duration-convexity results with simpler deterministic valuation shocks.
- Test nonlinear impact and longer liquidation-horizon challengers.

### Scenario-selection uncertainty

**Type:** Stress design

**Assessment:** Historical and hypothetical scenarios may omit relevant combinations, sequencing, persistence, or nonlinear interactions.

**Evidence gap:** Public evidence does not identify the exact FICC scenario library, internal risk appetite, or participant-specific stress calibration.

**Potential model effect:** Incomplete scenario coverage can understate the dominant liquidity driver or fail to identify a reverse-stress threshold.

**Risk rating:** inherent 20 (Critical); residual 13 (High).

**Material limitations**

- Extreme-but-plausible severity is judgmental.
- Joint shocks may not preserve real-world dependence or temporal ordering.

**Mitigations and compensating controls**

- Use historical, hypothetical, combined, and reverse-stress scenarios.
- Document scenario rationale, exclusions, and rank-order expectations.

**Independent validation actions**

- Test monotonicity and rank ordering under single-factor and combined stresses.
- Compare outcomes with simpler deterministic benchmarks.

## Cross-cutting limitations

- Public aggregate data cannot validate actual participant-level liquidity needs.
- Missing intraday information prevents empirical estimation of peak payment and collateral usage.
- Synthetic allocation and dependence assumptions materially affect default-set rankings.
- Operational and legal availability of resources requires specialist review outside this model.
- Simplified liquidation functions do not reproduce full market microstructure or feedback loops.
- The joint uncertainty envelope uses transparent but judgmental ranges and simplified dependence.
- Historical plausibility and benchmark agreement do not establish production fitness.

## Required model-use restrictions

- Do not use outputs to infer actual FICC participant exposures or liquidity resources.
- Do not interpret illustrative uncertainty ranges as regulatory thresholds.
- Do not use the assessment for legal conclusions, production limits, or participant decisions.

## Required conclusions

- The framework supports methodological validation, not empirical validation of actual FICC outcomes.
- Participant-level and intraday data gaps remain material residual limitations.
- Operational, legal, and liquidation-function assumptions require expert review before production use.

## Validation disposition

**Conditionally acceptable for research and portfolio demonstration only.** The framework must retain synthetic-data labeling, deterministic reproducibility, conservative uncertainty ranges, benchmark comparison, and explicit reporting of participant-level, intraday, legal, operational, and liquidation-function limitations.

Production or regulatory use would require confidential participant-level and intraday data, validated legal and operational resource assumptions, empirical calibration, independent implementation testing, and formal model-risk approval.
