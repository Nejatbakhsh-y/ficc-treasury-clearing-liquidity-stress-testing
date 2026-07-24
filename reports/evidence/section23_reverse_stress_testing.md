# Section 23 — Reverse Stress Testing

- Generated at: `2026-07-24T00:30:40.309520+00:00`
- Run type: `full`
- Model version: `section-23-v1`
- Deterministic reproduction: `True`
- Final decision: `PASS`

## Validation gates

| Gate | Result |
|---|---|
| four reverse stress tests completed | PASS |
| threshold search minimality | PASS |
| finite threshold outputs | PASS |
| nonnegative liquidity outputs | PASS |
| requirement identity | PASS |
| combination ranking created | PASS |
| most vulnerable combination identified | PASS |
| synthetic identity controls | PASS |
| deterministic reproduction | PASS |
| exact section15 17 model reuse | PASS |
| all input members covered | PASS |

## Reverse-stress thresholds

| Test | Status | Minimum threshold | Unit | Binding entity | LCR | Shortfall (USD) |
|---|---|---:|---|---|---:|---:|
| minimum_yield_shock | BREACH_AT_LOWER_BOUND | 0.00000000 | basis_points | SYN-MBR-0045 | 0.889810 | 3,590,873,227.41 |
| minimum_rollover_failure_rate | BREACH_AT_LOWER_BOUND | 0.00000000 | decimal_rate | SYN-MBR-0045 | 0.889810 | 3,590,873,227.41 |
| minimum_haircut_increase | BREACH_AT_LOWER_BOUND | 0.00000000 | decimal_rate | SYN-MBR-0045 | 0.889810 | 3,590,873,227.41 |
| minimum_combined_scenario | BREACH_AT_LOWER_BOUND | 0.00000000 | normalized_severity | SYN-MBR-0002|SYN-MBR-0045 | 0.900433 | 8,789,256,398.37 |

## Most vulnerable member combination

- Combination: `SYN-MBR-0002|SYN-MBR-0045`
- Combined severity: `0.00000000`
- Requirement: `$88,274,767,668.68`
- Available resources: `$79,485,511,270.31`
- LCR: `0.900433`
- Shortfall: `$8,789,256,398.37`

## Interpretation controls

- All members are fictional synthetic records.
- No actual FICC participant is represented or inferred.
- The combined path scales parallel yield shock, rollover failure, and additive haircut increase with one normalized severity parameter.
- Member-combination requirements and resources are additive; cross-member netting is not assumed.
- Isolated yield testing disables market impact by default so the solved threshold is attributable to the yield shock itself.
