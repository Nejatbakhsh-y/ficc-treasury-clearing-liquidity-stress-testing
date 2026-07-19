# Independent Validation Charter

## Authorization and approval

| Field | Value |
| --- | --- |
| Validation subject | Public-data FICC GSD Treasury-clearing liquidity stress model |
| Model owner | Yousef Nejatbakhsh |
| Independent validation role | Methodological challenge and verification separated from model-development conclusions |
| Effective date | 2026-07-19 |
| Approval status | APPROVED |
| Approval authority | Yousef Nejatbakhsh, project owner |

Approval authorizes the documented public-data research scope only. It is not approval of FICC methodology, regulatory compliance, production use, or a final model-risk rating.

## Validation mandate

Independently determine whether the proxy framework is conceptually sound for its stated research use, implemented as designed, supported by fit-for-purpose public data, appropriately conservative and sensitive under stress, reproducible, and presented without overstating what aggregate data can establish.

## Objectives

1. Confirm that intended use, users, decisions, exclusions, and limitations are explicit.
2. Challenge the economic and settlement logic connecting public market indicators to modeled liquidity needs.
3. Verify data provenance, classification, transformations, dates, units, and definition changes.
4. Reconcile Cover One, Cover Two, resource-availability, coverage-ratio, and shortfall calculations through independent tests.
5. Assess synthetic allocation behavior, concentration, dependence, uncertainty, and random-seed reproducibility.
6. Evaluate historical-event selection, hypothetical severity, combined stresses, and wrong-way risk.
7. Compare results with transparent benchmarks and simpler challenger methods.
8. Test sensitivity to all material assumptions and identify nonlinear or unstable behavior.
9. Confirm that reports distinguish observed evidence from derived, synthetic, assumed, and modeled values.
10. Assign findings, severity, owners, target dates, and closure evidence.

## Validation workstreams

| Workstream | Minimum evidence |
| --- | --- |
| Governance and intended use | Approved charters, model inventory, version history, roles |
| Conceptual soundness | Methodology review, assumptions challenge, regulatory and market rationale |
| Data validation | Source manifest, checksums, schemas, quality results, lineage tests |
| Process verification | Independent formula implementation, unit tests, code review, configuration reconciliation |
| Outcomes analysis | Descriptive diagnostics, benchmarks, backtests, stability and error analysis |
| Stress testing | Historical replay, hypothetical shocks, combined and reverse stress |
| Sensitivity and uncertainty | Parameter sweeps, allocation uncertainty, confidence or scenario ranges |
| Limitations and use controls | Report disclosures, prohibited-use checks, residual-risk assessment |

## Independence controls

- Development assumptions and validation challenges are recorded separately.
- A failed validation test cannot be overwritten by a narrative conclusion; remediation or formal risk acceptance is required.
- Validation code uses independent calculations for critical formulas where practicable.
- Model changes after validation are versioned and assessed for revalidation impact.
- The project owner may approve scope, but evidence, test status, and findings remain traceable and cannot be silently altered.

## Finding severity

| Severity | Definition | Required disposition |
| --- | --- | --- |
| Critical | Invalidates intended use or creates a materially misleading conclusion | Stop use until remediated and revalidated |
| High | Material weakness affecting key coverage or stress conclusions | Remediate before model approval |
| Medium | Important control, data, or methodology weakness with bounded impact | Time-bound remediation and monitoring |
| Low | Limited weakness or documentation gap | Track to closure |
| Observation | Improvement that does not presently impair intended use | Consider in roadmap |

## Completion and approval criteria

Final validation approval requires all critical and high findings to be closed or formally risk accepted, all required tests to have evidence, limitations to be prominent, results to be reproducible, and the model version to match the validated version. Section 1 approval establishes only that the scope is sufficiently defined to begin implementation.

## Section 1 scope decision

Independent validation scope approved: **APPROVED**  
Approved by: **Yousef Nejatbakhsh**  
Approval date: **2026-07-19**
