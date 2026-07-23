# Section 19 â€” Integrated Stressed Liquidity Requirement

- Generated at: `2026-07-23T15:24:52.293850+00:00`
- Run type: `CONTROLLED_MODEL_RUN`
- Model version: `section-19-v1`
- Deterministic reproduction: `True`
- Final decision: `PASS`

## Validation gates

| Gate | Result |
|---|---|
| expected member scenario rows | PASS |
| unique member scenario keys | PASS |
| finite required outputs | PASS |
| nonnegative required outputs | PASS |
| stressed requirement identity | PASS |
| lcr identity | PASS |
| zero requirement lcr convention | PASS |
| lcr status identity | PASS |
| double count controls pass | PASS |
| scenario summary complete | PASS |
| aggregate requirement nondecreasing | PASS |
| synthetic only | PASS |
| deterministic reproduction | PASS |

## Scenario results

| Scenario | Requirement (USD) | AQLR (USD) | LCR | Breach members |
|---|---:|---:|---:|---:|
| control | 2,509,734,833,314.87 | 3,585,520,931,632.54 | 1.428645 | 2 |
| moderate_integrated_stress | 3,505,313,928,129.73 | 3,585,520,931,632.54 | 1.022882 | 24 |
| severe_integrated_stress | 4,926,478,561,479.71 | 3,585,520,931,632.54 | 0.727806 | 45 |
| extreme_integrated_crisis | 7,335,880,341,173.29 | 3,585,520,931,632.54 | 0.488765 | 48 |

## No-double-counting disposition

The engine selects atomic Section 16 repo-rollover and funding-cost components instead of the Section 16 composite outflow. It selects the Section 18 settlement-only requirement instead of the Section 18 combined settlement-and-funding outflow. It uses the Section 14 modeled AQLR numerator rather than the Section 17 stressed AQLR field, because the Section 17 field already subtracts posted collateral and would duplicate the separately included haircut requirement.

All member records are fictional synthetic observations. No output identifies or infers an actual FICC participant.
