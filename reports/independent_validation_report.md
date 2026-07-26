# FICC Treasury Clearing Liquidity Stress Testing and Model Validation

## Independent Validation Report

| Report field | Value |
|---|---|
| Report ID | IVR-P9-S34 |
| Report date | July 26, 2026 |
| Generated UTC | 2026-07-26T23:46:05Z |
| Repository branch | docs/22-final-validation-report |
| Starting commit | 6bde9c50740b45dbbe5bc7efe1f1a5fabdb0488f |
| Evidence files inventoried | 673 |
| Evidence readiness | 13 of 13 domains passed |
| Validation conclusion | **CONDITIONALLY SATISFACTORY** |

## 1. Executive summary

This independent validation assesses the conceptual soundness, data controls,
implementation, outcomes, sensitivity, reverse-stress behavior, limitations,
findings, and governance of the FICC Treasury Clearing Liquidity Stress Testing
and Model Validation project.

The model is a public-data analytical framework. It uses aggregate Federal
Reserve data and synthetic clearing-member portfolios. It does not reproduce
FICC's proprietary liquidity stress-testing model, does not use confidential
participant positions, and must not identify a synthetic member as an actual
FICC participant.

The automated report-readiness result is **CONDITIONALLY SATISFACTORY**.
Required evidence domains are present and no open Critical or High finding was identified by the automated register review. The evidence inventory identified 673
controlled artifacts. Mandatory evidence domains passed:
13 of 13. Missing domains:
None.

| Validation domain | Status | Evidence count |
|---|---:|---:|
| Governance and scope | PASS | 39 |
| Data sources and quality | PASS | 141 |
| Synthetic portfolios | PASS | 29 |
| Model methodology | PASS | 39 |
| Scenario framework | PASS | 60 |
| Implementation verification | PASS | 5 |
| Sensitivity analysis | PASS | 12 |
| Outcomes analysis | PASS | 10 |
| Reverse stress | PASS | 17 |
| Monitoring | PASS | 18 |
| Findings | PASS | 9 |
| Limitations | PASS | 13 |
| Reproducibility | PASS | 47 |

## 2. Model purpose and intended use

The model's purpose is to estimate stressed liquidity requirements associated
with Treasury clearing, repo financing, settlement obligations, member default,
market liquidation, collateral haircut, concentration, operational, and
settlement-fail stresses. The framework evaluates resource adequacy through
Cover 1, Cover 2, Liquidity Coverage Ratio, liquidity shortfall, resource
utilization, and component-contribution measures.

Permitted uses include independent model-risk analysis, scenario comparison,
methodology challenge, sensitivity analysis, reverse stress, monitoring, and
governance reporting. Prohibited uses include representing the framework as
FICC's production model, treating synthetic members as real participants, or
using the results as a substitute for proprietary clearing-house, supervisory,
legal, or intraday liquidity information.

Automated evidence inventory: EV-0023 (configs/monitoring_governance.yaml); EV-0025 (configs/project.yaml); EV-0026 (configs/README.md); EV-0036 (CONTRIBUTING.md); EV-0110 (data/README.md); EV-0166 (notebooks/README.md).

## 3. Scope

The validation scope includes:

- Federal Reserve source contracts, ingestion, processing, lineage, and quality.
- Synthetic clearing-member schema, portfolio allocation, concentration, and
  default-set construction.
- Settlement, repo rollover, funding-cost, haircut, Treasury liquidation,
  settlement-fail, concentration, operational-buffer, and available-resource
  calculations.
- Historical, hypothetical, Cover 1, Cover 2, sensitivity, and reverse-stress
  analyses.
- Independent implementation verification, component reconciliation,
  deterministic benchmarks, scenario ordering, stability, and tail behavior.
- Monitoring thresholds, escalation, validation findings, remediation, and
  reproducibility controls.

The validation does not cover proprietary FICC participant data, contractual
liquidity facilities, confidential operational procedures, actual default
management results, or legal enforceability opinions.

Automated evidence inventory: EV-0023 (configs/monitoring_governance.yaml); EV-0025 (configs/project.yaml); EV-0026 (configs/README.md); EV-0036 (CONTRIBUTING.md); EV-0110 (data/README.md); EV-0166 (notebooks/README.md).

## 4. Data sources

The controlled public-data design uses the following official source families:

- FR 2004 Primary Dealer Statistics for Treasury positions, transactions,
  financing activity, and settlement-fail information.
- New York Fed SOFR data for secured overnight funding rates, distributional
  statistics, and transaction volume.
- Federal Reserve H.15 data for Treasury yields by maturity.
- Federal Reserve H.4.1 data for reserve balances and systemwide liquidity
  conditions.

Validation expectations include documented identifiers, definitions, units,
frequency, publication calendar, history, revision policy, intended model use,
known limitations, standardized dates and units, maturity mappings, missing-data
controls, and source lineage.

Automated evidence inventory: EV-0003 (.github/ISSUE_TEMPLATE/data-quality.yml); EV-0015 (configs/data_sources.yaml); EV-0024 (configs/processed_data.yaml); EV-0038 (data/interim/fr2004/fr2004_series_definitions.csv); EV-0039 (data/manifests/baseline_liquidity_manifest.csv); EV-0041 (data/manifests/cover_analysis_manifest.csv).

## 5. Synthetic portfolio methodology

Synthetic members must be generated from controlled rules rather than copied
from, named after, or represented as actual FICC participants. The synthetic
schema should cover Treasury positions by maturity, transaction activity, repo
and reverse-repo positions, settlement obligations and fails, collateral
inventory, available qualified liquid resources, concentration, funding
dependency, and liquidity-risk characteristics.

Validation criteria include deterministic random seeds, reproducible allocation,
aggregate reconciliation, bounded values, internally consistent balance and
resource relationships, configurable concentration, and explicit construction
of largest-member, Cover 1, largest-two-member, Cover 2, concentrated, and
correlated default sets.

Automated evidence inventory: EV-0016 (configs/default_sets.yaml); EV-0032 (configs/synthetic_calibration.yaml); EV-0033 (configs/synthetic_members.yaml); EV-0054 (data/manifests/synthetic_calibration_manifest.csv); EV-0055 (data/manifests/synthetic_member_manifest.csv); EV-0056 (data/manifests/synthetic_member_schema.json).

## 6. Model methodology

The integrated stressed liquidity requirement is defined as the controlled
aggregation of:

1. Settlement liquidity need.
2. Repo rollover need.
3. Incremental funding cost.
4. Additional haircut requirement.
5. Treasury liquidation loss.
6. Settlement-fail requirement.
7. Concentration adjustment.
8. Operational liquidity buffer.

The aggregation must prevent double counting. Available qualified liquid
resources are compared with the stressed liquidity requirement. The Liquidity
Coverage Ratio is available qualified liquid resources divided by stressed
liquidity requirement. Liquidity shortfall is the positive excess of stressed
requirement over available resources.

Validation requires unit consistency, sign controls, boundary behavior,
component reconciliation, transparent assumptions, deterministic execution,
and traceability from scenario parameters through component outputs to the final
LCR and shortfall.

Automated evidence inventory: EV-0011 (configs/collateral_haircut_stress.yaml); EV-0021 (configs/integrated_stress_engine.yaml); EV-0031 (configs/settlement_fail_stress.yaml); EV-0040 (data/manifests/collateral_haircut_stress_manifest.csv); EV-0048 (data/manifests/integrated_stress_engine_manifest.csv); EV-0052 (data/manifests/settlement_fail_stress_manifest.csv).

## 7. Scenario framework

The scenario framework should include historical and hypothetical stresses,
moderate, severe, and extreme-but-plausible calibration, parallel Treasury
shocks, curve steepening and flattening, SOFR spikes, repo rollover failure,
haircut increases, settlement-fail increases, concentration shocks, and combined
systemic stress.

For every scenario, the framework should calculate Cover 1 and Cover 2 stressed
requirements, available resources, LCR, shortfall, resource utilization, and the
dominant stress component. Scenario identifiers, parameters, provenance, and
severity ordering must be controlled and reproducible.

Automated evidence inventory: EV-0017 (configs/historical_scenario_replay.yaml); EV-0018 (configs/historical_scenarios.yaml); EV-0019 (configs/hypothetical_scenarios.yaml); EV-0046 (data/manifests/historical_scenario_manifest.csv); EV-0047 (data/manifests/hypothetical_scenario_manifest.csv); EV-0123 (docs/historical_scenarios_methodology.md).

## 8. Conceptual soundness

The conceptual design is sound when the model:

- Links market, funding, collateral, settlement, concentration, and operational
  stresses to liquidity requirements through economically interpretable
  mechanisms.
- Separates stressed requirements from available resources.
- Preserves component additivity without double counting.
- Applies Cover 1 and Cover 2 default-set logic consistently.
- Produces monotonic responses to more severe adverse assumptions, except where
  a documented nonlinear resource or portfolio interaction explains otherwise.
- Uses assumptions proportionate to public aggregate data and synthetic
  portfolios.
- Exposes limitations rather than implying participant-level or intraday
  precision.

Conceptual soundness remains conditional on empirical calibration, independent
implementation results, sensitivity behavior, reverse-stress thresholds, and
closure of material validation findings.

Automated evidence inventory: EV-0011 (configs/collateral_haircut_stress.yaml); EV-0021 (configs/integrated_stress_engine.yaml); EV-0031 (configs/settlement_fail_stress.yaml); EV-0040 (data/manifests/collateral_haircut_stress_manifest.csv); EV-0048 (data/manifests/integrated_stress_engine_manifest.csv); EV-0052 (data/manifests/settlement_fail_stress_manifest.csv).

## 9. Data validation

Data validation should demonstrate schema conformance, type controls,
standardized dates and units, frequency alignment, maturity mapping, missing
observation treatment, duplicate detection, range and sign checks, revision
awareness, lineage, reproducible processed datasets, and reconciliation to
source-level aggregates where feasible.

Aggregate public data support market-condition and plausibility analysis but do
not identify participant-specific exposures. Synthetic allocation therefore
introduces an additional modeled layer that must be validated separately from
source-data quality.

Automated evidence inventory: EV-0003 (.github/ISSUE_TEMPLATE/data-quality.yml); EV-0015 (configs/data_sources.yaml); EV-0024 (configs/processed_data.yaml); EV-0038 (data/interim/fr2004/fr2004_series_definitions.csv); EV-0039 (data/manifests/baseline_liquidity_manifest.csv); EV-0041 (data/manifests/cover_analysis_manifest.csv).

## 10. Implementation verification

Independent implementation verification must use a calculation path that does
not call production calculation functions. It should independently calculate
stress components, default-set selection, aggregate reconciliation, stressed
liquidity requirement, available resources, LCR, and shortfalls.

Required comparisons include exact or tolerance-based reconciliation, component
differences, exception reporting, deterministic benchmark comparisons, boundary
tests, and investigation of unexplained discrepancies. A passing result requires
all material differences to be explained, accepted, or remediated.

Automated evidence inventory: EV-0135 (docs/section25_independent_implementation_verification.md); EV-0249 (P7S25_Independent_Implementation_Verification.ps1); EV-0530 (reports/validation/section27/component_reconciliation.csv); EV-0628 (src/ficc_liquidity/validation/independent_implementation.py); EV-0664 (tests/test_section25_independent_implementation.py).

## 11. Sensitivity analysis

Sensitivity testing should cover Treasury yield shocks, duration assumptions,
SOFR spikes, rollover-failure percentages, haircut increases, settlement-fail
percentages, member concentration, liquidation horizon, default-set size, and
available-resource assumptions.

The expected outcome is economically coherent directionality, identifiable
nonlinearities, stable rank ordering where appropriate, and clear attribution
of changes to affected stress components. Discontinuities, non-monotonic
responses, or excessive parameter dependence require documented investigation.

Automated evidence inventory: EV-0030 (configs/sensitivity_analysis.yaml); EV-0136 (docs/section26_sensitivity_analysis.md); EV-0250 (P7S26_Sensitivity_Analysis.ps1); EV-0419 (reports/evidence/section26_sensitivity_analysis.txt); EV-0420 (reports/evidence/section26_sensitivity_summary.json); EV-0501 (reports/tables/section26_sensitivity_baselines.csv).

## 12. Outcomes analysis

Because actual FICC outcomes are unavailable, outcomes validation should rely on
historical plausibility, scenario rank ordering, monotonicity, independent
benchmarks, component reconciliation, stability across seeds, comparison with
simpler deterministic benchmarks, tail behavior, and economic interpretation.

Validation should distinguish evidence of computational correctness from
evidence of real-world predictive accuracy. Aggregate-data plausibility cannot
establish participant-level forecast accuracy, and synthetic-member results
must be interpreted as controlled analytical experiments.

Automated evidence inventory: EV-0029 (configs/section27_outcomes_benchmark.yaml); EV-0142 (docs/validation/section_27_outcomes_benchmark_analysis.md); EV-0532 (reports/validation/section27/historical_plausibility.csv); EV-0534 (reports/validation/section27/monotonicity_results.csv); EV-0535 (reports/validation/section27/normalized_outcomes.csv); EV-0536 (reports/validation/section27/scenario_rank_ordering.csv).

## 13. Reverse stress

Reverse-stress analysis should identify combinations of market, funding,
haircut, settlement-fail, concentration, liquidation-horizon, default-set, and
resource assumptions that cause LCR to fall below the controlled threshold or
produce a positive liquidity shortfall.

Results should identify the first breach, dominant component, parameter
combination, available-resource dependency, and distance from baseline. Reverse
stress should support risk appetite, monitoring thresholds, escalation, and
scenario design rather than claim a probability for the breach unless a
separate probability model is validated.

Automated evidence inventory: EV-0028 (configs/reverse_stress_testing.yaml); EV-0051 (data/manifests/reverse_stress_testing_manifest.csv); EV-0133 (docs/reverse_stress_testing_methodology.md); EV-0413 (reports/evidence/section23_reverse_stress_testing.json); EV-0414 (reports/evidence/section23_reverse_stress_testing.md); EV-0485 (reports/tables/reverse_stress_member_combination_ranking.csv).

## 14. Limitations

The principal limitations are:

1. Aggregate-data uncertainty: public series may not align exactly with cleared
   portfolios, obligations, settlement timing, or eligible resources.
2. Synthetic allocation uncertainty: participant exposures and dependencies are
   modeled rather than observed.
3. Scenario-selection uncertainty: historical and hypothetical scenarios may
   omit relevant combinations or structural breaks.
4. Parameter uncertainty: duration, funding, haircut, fail, liquidation, and
   concentration assumptions are estimated or judgmental.
5. Missing intraday information: daily or weekly aggregates cannot represent
   peak intraday payment and settlement needs.
6. Participant-level data limitations: the framework cannot validate member
   heterogeneity against confidential FICC records.
7. Operational and legal assumptions: resource availability, timing,
   enforceability, and operational execution are simplified.
8. Simplified liquidation functions: market depth, price impact, wrong-way
   effects, execution delays, and feedback loops may be understated.
9. Model-form uncertainty: additive components and deterministic rules may not
   capture nonlinear dependencies.
10. Outcome limitations: public data and synthetic portfolios cannot establish
    actual FICC performance or default-management outcomes.

These limitations require conservative interpretation, explicit disclosure,
sensitivity analysis, reverse stress, monitoring, and periodic revalidation.

Automated evidence inventory: EV-0004 (.github/ISSUE_TEMPLATE/model-risk.yml); EV-0035 (configs/validation/section_28_uncertainty.yaml); EV-0127 (docs/model_scope_and_limitations.md); EV-0143 (docs/validation/section_28_uncertainty_methodology.md); EV-0523 (reports/validation/section_28/joint_uncertainty_simulations.csv); EV-0524 (reports/validation/section_28/joint_uncertainty_summary.csv).

## 15. Findings

Controlled finding register: reports/evidence/backups/section31_20260725_211940/data/manifests/validation_finding_register.csv

| Classification | Count |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Observation | 0 |
| Unknown | 5 |

Open Critical findings identified by the automated register review:
0

Open High findings identified by the automated register review:
0

Finding severity alone is not sufficient for closure. Each finding should
include condition, evidence, risk, recommendation, management response, owner,
target date, status, and closure evidence. Critical and High findings require
formal remediation or documented risk acceptance before unconditional reliance.

Automated evidence inventory: EV-0336 (reports/evidence/backups/section31_20260725_211940/.github/ISSUE_TEMPLATE/validation-finding.yml); EV-0337 (reports/evidence/backups/section31_20260725_211940/configs/validation_findings.yaml); EV-0338 (reports/evidence/backups/section31_20260725_211940/data/manifests/validation_finding_register.csv); EV-0339 (reports/evidence/backups/section31_20260725_211940/docs/validation_finding_register.md); EV-0340 (reports/evidence/backups/section31_20260725_211940/scripts/automation/P8S31_Setup_Validation_Finding_Register.ps1); EV-0341 (reports/evidence/backups/section31_20260725_211940/scripts/run_validation_findings.py).

## 16. Validation conclusion

**Conclusion: CONDITIONALLY SATISFACTORY**

Required evidence domains are present and no open Critical or High finding was identified by the automated register review.

The conclusion is inherently conditional because the model is based on public
aggregate data and synthetic portfolios. Even when all automated evidence gates
pass, the framework should be used as an independent analytical and validation
tool rather than represented as FICC's proprietary production liquidity model.

Final approval requires review of the underlying evidence, confirmation that
quantitative results are current, closure or formal acceptance of material
findings, and approval by the designated model owner and independent validator.

Automated evidence inventory: EV-0006 (.github/workflows/ci.yml); EV-0007 (.github/workflows/dependency-review.yml); EV-0167 (P1S1_Project_Charter_Automation.ps1); EV-0187 (P2S6_Setup_Supporting_Fed_Data.ps1); EV-0188 (P2S6_Setup_Supporting_Fed_Data_v2.ps1); EV-0189 (P2S6_Setup_Supporting_Fed_Data_v3.ps1).

## 17. Recommendations

1. Close all Critical and High findings before unconditional sign-off.
2. Preserve strict independence between production and verification calculation
   paths.
3. Retain deterministic seeds, configuration snapshots, source lineage, runtime
   evidence, and SHA-256 hashes for every released evidence package.
4. Expand participant-level and intraday validation when authorized data become
   available.
5. Challenge liquidation, market-depth, funding, haircut, settlement, legal,
   and operational assumptions through sensitivity and reverse stress.
6. Reconcile all scenario outputs to component calculations and simpler
   deterministic benchmarks.
7. Calibrate monitoring thresholds to observed drift, historical ranges,
   scenario-order stability, LCR distributions, and contribution changes.
8. Require monthly monitoring sign-off and annual independent revalidation, with
   earlier revalidation after material model, data, or market-structure change.
9. Freeze the final report version and evidence manifest at approval.
10. Maintain explicit disclosure that synthetic members are not actual FICC
    participants.

Automated evidence inventory: EV-0049 (data/manifests/monitoring_threshold_register.csv); EV-0128 (docs/monitoring_thresholds_and_escalation.md); EV-0129 (docs/monthly_monitoring_framework.md); EV-0251 (P8S29_Setup_Monthly_Monitoring_Framework.ps1); EV-0252 (P8S30_FINAL_V3_Setup_Monitoring_Thresholds_Escalation.ps1); EV-0300 (reports/evidence/backups/section30_20260725_132610/data/manifests/monitoring_threshold_register.csv).

## 18. Appendices and evidence index

The controlled Section 34 package consists of:

- Final report: reports/independent_validation_report.md
- Markdown evidence index:
  reports/validation/section34_evidence_index.md
- Machine-readable evidence index:
  reports/validation/section34_evidence_index.csv
- Readiness assessment:
  reports/validation/section34_report_readiness.csv
- Completion checklist:
  reports/validation/section34_completion_checklist.md
- Report manifest:
  reports/validation/section34_report_manifest.json
- Automated report test:
  tests/test_section34_independent_validation_report.py

Evidence records use repository-relative paths and SHA-256 hashes. The evidence
index is the authoritative map from validation domains to controlled artifacts.

Automated evidence inventory: EV-0006 (.github/workflows/ci.yml); EV-0007 (.github/workflows/dependency-review.yml); EV-0167 (P1S1_Project_Charter_Automation.ps1); EV-0187 (P2S6_Setup_Supporting_Fed_Data.ps1); EV-0188 (P2S6_Setup_Supporting_Fed_Data_v2.ps1); EV-0189 (P2S6_Setup_Supporting_Fed_Data_v3.ps1).
