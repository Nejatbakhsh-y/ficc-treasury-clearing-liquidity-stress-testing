# Section 25 â€” Independent Implementation Verification

## Objective

Section 25 provides a second calculation path for liquidity stress results. The independent path recalculates stress components, default sets, aggregate reconciliations, stressed liquidity requirements, qualified resources, liquidity coverage ratios, and shortfalls.

The independent module does not import or call production calculation functions. It consumes only flat CSV contracts and implements the formulas directly.

## Independence boundary

The independent implementation is located at:

`src/ficc_liquidity/validation/independent_implementation.py`

The module imports Python standard-library modules, pandas, and PyYAML. It does not import any module under `ficc_liquidity`. The test `test_independent_module_imports_no_production_package_code` parses the module with Python's AST and fails if an internal package import is added.

The runner may import the independent module. The independent module itself may not import production code.

## Independent formulas

For each member and scenario:

1. Settlement liquidity need equals positive settlement obligations net of incoming settlement cash and approved netting credit.
2. Repo rollover need equals repo maturity multiplied by the rollover-failure rate.
3. Incremental funding cost equals refinanced repo multiplied by the SOFR shock and the funding-horizon day count divided by 360.
4. Additional haircut requirement equals collateral market value multiplied by the haircut increase and concentration multiplier.
5. Treasury liquidation loss uses a direct modified-duration and convexity approximation.
6. Settlement-fail requirement equals positive fails-to-receive plus delayed incoming payments less fails-to-deliver credit, multiplied by persistence days.
7. Concentration adjustment equals the concentration base multiplied by the independent add-on percentage.
8. Operational liquidity buffer equals the operational base multiplied by its buffer percentage.
9. Stressed liquidity requirement equals the sum of the eight independently calculated components.

## Cover 1 and Cover 2

Members are ranked by independently calculated stressed liquidity requirement. Cover 1 selects the largest member. Cover 2 selects the two largest members. Ties are resolved deterministically by member identifier.

Qualified resources are recalculated from nominal amount, eligibility, liquidity haircut, and availability factor. Resources owned by a defaulting member are excluded from the corresponding default set.

`LCR = available qualified resources / stressed liquidity requirement`

`Liquidity shortfall = max(stressed liquidity requirement - available qualified resources, 0)`

`Resource utilization = stressed liquidity requirement / available qualified resources`

## Aggregate reconciliation

`configs/independent_verification.yaml` identifies aggregate-control inputs. Every control specifies its source table, metric, expected total, absolute tolerance, and relative tolerance. The verification fails when neither tolerance is met.

## Controlled fixture and production comparison

The automation creates a small hand-calculated fixture. This proves formula correctness, deterministic default-set selection, resource exclusion, reconciliation, and comparison logic.

To compare against actual production outputs, export the Section 22 results to a CSV with these columns:

- `scenario_id`
- `coverage_basis`
- `default_members`
- `stressed_requirement`
- `available_resources`
- `lcr`
- `liquidity_shortfall`

Then run:

```powershell
.\.venv\Scripts\python.exe scripts\run_section25_independent_verification.py `
  --config configs\independent_verification.yaml `
  --production-results reports\tables\section22_cover_results.csv `
  --comparison-label production_section22
```

The production CSV is treated as read-only output. No production function is imported or invoked.

## Evidence outputs

- `reports/tables/section25_member_calculations.csv`
- `reports/tables/section25_qualified_resources.csv`
- `reports/tables/section25_default_sets.csv`
- `reports/tables/section25_cover_results.csv`
- `reports/tables/section25_aggregate_reconciliation.csv`
- `reports/tables/section25_calculation_comparison.csv`
- `reports/evidence/section25_independent_verification_summary.json`
- `reports/evidence/section25_independent_verification.txt`

## Acceptance criteria

- Independent module contains no internal production imports: PASS.
- Controlled component calculations match hand calculations: PASS.
- Cover 1 and Cover 2 selection is deterministic: PASS.
- Defaulting-member resources are excluded: PASS.
- Aggregate controls reconcile within tolerance: PASS.
- Controlled result comparison passes: PASS.
- Actual production comparison is performed using exported results before final model-validation sign-off.