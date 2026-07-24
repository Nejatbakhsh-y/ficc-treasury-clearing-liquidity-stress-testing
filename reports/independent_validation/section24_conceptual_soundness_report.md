# Section 24 â€” Conceptual Soundness Validation

## Independent validation conclusion

- Overall status: **FAIL**
- Weighted score: **89.93%**
- Critical failures: **2**

The assessment challenges model design, assumptions, evidence, and deterministic sanity checks. It does not treat file existence alone as conceptual validation.

## Challenge matrix

| Challenge | Status | Score | Evidence groups | Quantitative checks |
|---|---:|---:|---:|---:|
| Liquidity horizon | FAIL | 75.0% | 2/4 | 2/2 |
| Cash-flow definitions | PASS | 100.0% | 7/7 | 2/2 |
| Default-set construction | PASS | 100.0% | 6/6 | 2/2 |
| Yield-to-price methodology | PASS | 100.0% | 7/7 | 3/3 |
| Repo rollover assumptions | PASS | 100.0% | 6/6 | 2/2 |
| Haircut assumptions | PASS | 100.0% | 6/6 | 2/2 |
| Settlement-fail treatment | PARTIAL | 92.9% | 6/7 | 2/2 |
| Resource eligibility | FAIL | 78.6% | 4/7 | 1/1 |
| Netting assumptions | FAIL | 50.0% | 0/6 | 2/2 |
| Scenario severity | PARTIAL | 95.5% | 10/11 | 2/2 |
| Synthetic-member calibration | PARTIAL | 94.4% | 8/9 | 3/3 |

## Detailed challenge results

### Liquidity horizon

**Status:** FAIL  
**Risk:** An understated or timing-inconsistent horizon can omit the peak liquidity need.  
**Standards mapping:** PFMI Principle 7, SEC Rule 17Ad-22(e)(7)

**Challenge questions**

- Does the horizon capture intraday peaks and multi-day persistence?
- Are resource monetization times aligned with obligation timing?
- Is the horizon conservative under delayed receipts and rollover failure?

**Evidence files**

- `configs/baseline_liquidity.yaml`
- `docs/baseline_liquidity_methodology.md`
- `src/ficc_liquidity/liquidity/baseline_cashflow.py`

**Missing evidence groups**

- multi-day | overnight | day 2
- same-day | available when needed | timely availability

**Remediation:** Document time buckets, peak-need selection, multi-day persistence, and resource monetization timing.

### Cash-flow definitions

**Status:** PASS  
**Risk:** Ambiguous definitions or duplicated components can materially misstate stressed requirements.  
**Standards mapping:** PFMI Principles 3 and 7, SEC Rule 17Ad-22(e)(7)

**Challenge questions**

- Are contractual, contingent, and stressed cash flows separately defined?
- Are signs, units, timing, and aggregation conventions unambiguous?
- Does the integrated requirement prevent duplicate recognition?

**Evidence files**

- `configs/baseline_liquidity.yaml`
- `configs/collateral_haircut_stress.yaml`
- `configs/integrated_stress_engine.yaml`
- `configs/repo_funding_stress.yaml`
- `configs/reverse_stress_testing.yaml`
- `configs/settlement_fail_stress.yaml`
- `configs/treasury_yield_stress.yaml`
- `docs/baseline_liquidity_methodology.md`
- `docs/collateral_haircut_stress_methodology.md`
- `docs/integrated_stress_engine_methodology.md`
- `docs/repo_funding_stress_methodology.md`
- `docs/reverse_stress_testing_methodology.md`
- `docs/section_10_historical_stress_methodology.md`
- `docs/settlement_fail_stress_methodology.md`
- `src/ficc_liquidity/analysis/historical_stress.py`
- `src/ficc_liquidity/liquidity/baseline_cashflow.py`
- `src/ficc_liquidity/scenarios/reverse_stress.py`
- `src/ficc_liquidity/stress/collateral_haircut_stress.py`
- `src/ficc_liquidity/stress/integrated_stress.py`
- `src/ficc_liquidity/stress/repo_funding_stress.py`
- `src/ficc_liquidity/stress/settlement_fail_stress.py`

**Missing evidence groups**

- None.

**Remediation:** Create a controlled cash-flow dictionary with sign, timing, source, unit, and anti-double-counting rules.

### Default-set construction

**Status:** PASS  
**Risk:** Incorrect default-set logic can select the wrong liquidity-driving member combination.  
**Standards mapping:** PFMI Principles 4 and 7, CCP resilience guidance

**Challenge questions**

- Are Cover 1 and Cover 2 selected from scenario-specific stressed needs?
- Can affiliated or correlated members be represented without duplication?
- Are default sets reproducible and configurable?

**Evidence files**

- `configs/cover_analysis.yaml`
- `configs/default_sets.yaml`
- `docs/default_set_methodology.md`
- `src/ficc_liquidity/scenarios/cover_analysis.py`
- `src/ficc_liquidity/synthetic/default_sets.py`
- `tests/test_default_sets.py`
- `tests/test_default_sets_coverage.py`

**Missing evidence groups**

- None.

**Remediation:** Base selection on scenario-specific member requirements, enforce uniqueness, and retain ranked member evidence.

### Yield-to-price methodology

**Status:** PASS  
**Risk:** Unit, sign, or mapping errors can reverse or materially distort Treasury liquidation losses.  
**Standards mapping:** PFMI Principles 4 and 7, SEC Rule 17Ad-22(e)(6)

**Challenge questions**

- Are yield shocks converted using consistent decimal and basis-point units?
- Are duration and convexity signs correct for long and short positions?
- Are curve and key-rate shocks mapped to maturity buckets without gaps?

**Evidence files**

- `configs/treasury_yield_stress.yaml`
- `docs/treasury_yield_shock_model.md`
- `src/ficc_liquidity/stress/treasury_yield_shock.py`
- `tests/test_treasury_yield_shock.py`

**Missing evidence groups**

- None.

**Remediation:** Retain benchmark calculations, sign tests, key-rate mappings, and independent price-change reconciliation.

### Repo rollover assumptions

**Status:** PASS  
**Risk:** Unsubstantiated rollover assumptions can understate replacement funding and concentration risk.  
**Standards mapping:** PFMI Principle 7, SEC Rule 17Ad-22(e)(7)

**Challenge questions**

- Are failure rates severity-dependent, bounded, and empirically defensible?
- Are lender withdrawal and refinancing-horizon assumptions independent where appropriate?
- Does the model avoid treating failed rollover and haircut demand as the same cash flow?

**Evidence files**

- `configs/repo_funding_stress.yaml`
- `docs/repo_funding_stress_methodology.md`
- `src/ficc_liquidity/stress/repo_funding_stress.py`
- `tests/test_repo_funding_stress.py`
- `tests/test_repository_foundation.py`

**Missing evidence groups**

- None.

**Remediation:** Calibrate bounded monotonic rates, document lender concentration, and separate principal replacement from incremental cost.

### Haircut assumptions

**Status:** PASS  
**Risk:** Haircut misspecification can understate collateral calls or double count concentration effects.  
**Standards mapping:** PFMI Principle 5, SEC Rule 17Ad-22(e)(5)

**Challenge questions**

- Are baseline and stressed haircuts conservative and maturity-sensitive?
- Are concentration effects applied once and in the correct sequence?
- Can additional collateral exceed available unencumbered inventory?

**Evidence files**

- `configs/collateral_haircut_stress.yaml`
- `docs/collateral_haircut_stress_methodology.md`
- `src/ficc_liquidity/stress/collateral_haircut_stress.py`
- `tests/test_collateral_haircut_stress.py`

**Missing evidence groups**

- None.

**Remediation:** Document haircut hierarchy, caps, concentration sequence, and inventory constraints with boundary tests.

### Settlement-fail treatment

**Status:** PARTIAL  
**Risk:** Incorrect fail treatment can omit replacement liquidity or count the same obligation multiple times.  
**Standards mapping:** PFMI Principles 7 and 8, SEC Rule 17Ad-22(e)(7)

**Challenge questions**

- Are fails-to-receive and fails-to-deliver treated asymmetrically where required?
- Are recoveries credited only when timely and reliable?
- Are persistent fails carried forward without duplicating original settlement obligations?

**Evidence files**

- `configs/settlement_fail_stress.yaml`
- `docs/settlement_fail_stress_methodology.md`
- `src/ficc_liquidity/stress/settlement_fail_stress.py`
- `tests/test_settlement_fail_stress.py`

**Missing evidence groups**

- double counting | double-counting

**Remediation:** Introduce obligation identifiers, persistence roll-forward logic, and explicit recovery eligibility.

### Resource eligibility

**Status:** FAIL  
**Risk:** Counting unavailable or ineligible resources can create a false LCR surplus.  
**Standards mapping:** PFMI Principle 7, SEC Rule 17Ad-22(e)(7)

**Challenge questions**

- Can every counted resource be accessed in the relevant currency and time bucket?
- Are encumbrance, haircuts, provider reliability, and operational capacity reflected?
- Are contingent or uncommitted resources excluded from available qualified resources?

**Evidence files**

- `configs/baseline_liquidity.yaml`
- `docs/baseline_liquidity_methodology.md`

**Missing evidence groups**

- unencumbered | encumbered
- committed | prearranged funding
- same-day | monetization

**Remediation:** Maintain a resource eligibility register with legal, operational, currency, timing, haircut, and encumbrance attributes.

### Netting assumptions

**Status:** FAIL  
**Risk:** Overly broad netting can materially suppress peak settlement liquidity.  
**Standards mapping:** PFMI Principles 1, 7, and 8

**Challenge questions**

- Is netting supported by enforceable rules for the modeled default state?
- Are only compatible currency, date, product, and settlement-system obligations netted?
- Does the model revert to gross obligations when criteria fail?

**Evidence files**

- `configs/baseline_liquidity.yaml`
- `docs/baseline_liquidity_methodology.md`

**Missing evidence groups**

- legally enforceable | enforceability
- same currency | currency
- same settlement date | settlement date
- gross fallback | gross obligation
- bilateral netting | multilateral netting | netting set
- default scenario | defaulted member

**Remediation:** Define legal netting sets, operational compatibility criteria, and an automatic gross fallback.

### Scenario severity

**Status:** PARTIAL  
**Risk:** Weak or incoherent scenarios can fail to expose the model's true liquidity vulnerability.  
**Standards mapping:** PFMI Principles 4 and 7, CCP resilience guidance, DTCC stress testing framework

**Challenge questions**

- Are scenarios monotonic where expected and non-redundant?
- Is extreme-but-plausible severity supported by historical or hypothetical rationale?
- Do combined scenarios preserve coherent dependencies rather than simply summing maxima?

**Evidence files**

- `configs/historical_scenario_replay.yaml`
- `configs/historical_scenarios.yaml`
- `configs/hypothetical_scenarios.yaml`
- `docs/historical_scenarios_methodology.md`
- `docs/hypothetical_scenarios_methodology.md`
- `reports/tables/collateral_haircut_stress_scenario_summary.csv`
- `reports/tables/cover_analysis_scenario_summary.csv`
- `reports/tables/historical_scenario_double_count_controls.csv`
- `reports/tables/historical_scenario_member_results.csv`
- `reports/tables/historical_scenario_metrics.csv`
- `reports/tables/historical_scenario_summary.csv`
- `reports/tables/hypothetical_scenario_catalog.csv`
- `reports/tables/hypothetical_scenario_double_count_controls.csv`
- `reports/tables/hypothetical_scenario_member_results.csv`
- `reports/tables/hypothetical_scenario_summary.csv`
- `reports/tables/integrated_stress_scenario_summary.csv`
- `reports/tables/repo_funding_stress_scenario_summary.csv`
- `reports/tables/settlement_fail_stress_scenario_summary.csv`
- `reports/tables/treasury_yield_stress_scenario_summary_smoke.csv`
- `src/ficc_liquidity/scenarios/historical_scenarios.py`
- `src/ficc_liquidity/scenarios/hypothetical_scenarios.py`
- `tests/test_historical_scenarios.py`
- `tests/test_hypothetical_scenarios.py`

**Missing evidence groups**

- reverse stress

**Remediation:** Document severity calibration, dependence structure, historical anchors, and reverse-stress thresholds.

### Synthetic-member calibration

**Status:** PARTIAL  
**Risk:** Poor calibration can invalidate member concentration, default-set, and Cover 1/Cover 2 conclusions.  
**Standards mapping:** PFMI Principle 3, Model risk governance

**Challenge questions**

- Do synthetic members exactly reconcile to controlled Federal Reserve aggregates?
- Are concentration and tail behavior intentional, reproducible, and documented?
- Is any actual FICC participant identity or participant-level inference excluded?

**Evidence files**

- `configs/synthetic_calibration.yaml`
- `configs/synthetic_members.yaml`
- `docs/synthetic_calibration_methodology.md`
- `docs/synthetic_member_data_model.md`
- `src/ficc_liquidity/synthetic/calibrate_members.py`
- `tests/test_synthetic_calibration.py`
- `tests/test_synthetic_member_schema.py`

**Missing evidence groups**

- financing and fails reconciliation | fails reconciliation

**Remediation:** Retain reconciliation tables, deterministic seeds, distribution diagnostics, and explicit synthetic-data controls.

