# FICC Treasury Clearing Liquidity Stress Testing and Model Validation

## Project charter

| Field | Value |
| --- | --- |
| Project phase | Phase I â€” Project and GitHub Foundation |
| Section | Section 1 â€” Project Charter and Validation Scope |
| Project owner | Yousef Nejatbakhsh |
| Effective date | 2026-07-19 |
| Scope approval | APPROVED |
| Clearing service in scope | FICC Government Securities Division (GSD), represented only through public-data proxies |
| Currency | U.S. dollars |

## Business objective

Develop a reproducible, independently testable research framework that estimates proxy liquidity needs for FICC Treasury cash and repo clearing under historical and hypothetical stress, compares those needs with a transparent proxy for qualifying liquid resources, and evaluates the sufficiency, sensitivity, and limitations of the resulting coverage measures.

The framework is a public-data model-validation portfolio project. It is not FICC's production liquidity model, does not reproduce confidential member-level settlement obligations, and cannot determine FICC's regulatory compliance.

## Research questions

1. How do Treasury-market rates, repo volumes, dealer financing, positions, and settlement fails relate to a public-data proxy for stressed clearing liquidity needs?
2. Does the proxy resource pool cover the largest modeled member-family liquidity need under the baseline Cover One construction?
3. How does coverage change under the conservative Cover Two challenger, defined as the combined modeled needs of the two largest member families?
4. Which historical stress windows and hypothetical shocks produce the lowest coverage ratio and largest liquidity shortfall?
5. How sensitive are the conclusions to exposure allocation, resource availability, settlement-cycle, haircut, concentration, and wrong-way-risk assumptions?
6. Are data lineage, transformations, scenario definitions, model versions, and validation conclusions reproducible and auditable?

## Intended model use

Permitted uses:

- research and professional portfolio demonstration;
- public-data Treasury and repo market surveillance;
- development and independent validation of a proxy liquidity stress-testing methodology;
- scenario comparison, sensitivity analysis, benchmarking, and limitation analysis;
- identification of data gaps that would need confidential clearing-agency evidence in a production validation.

Prohibited uses:

- regulatory attestation or a conclusion about FICC compliance;
- production liquidity, clearing, margin, funding, or default-management decisions;
- prediction of an identifiable clearing member's exposure or default;
- substitution for FICC rules, procedures, internal data, or management judgment;
- representation of synthetic member families as real firms.

## Public data in scope

The initial data universe is restricted to authoritative public sources. New York Fed Primary Dealer Statistics provide aggregate weekly positions, transactions, financing, and fails. New York Fed reference-rate data provide SOFR and associated volume statistics. FICC disclosure and CPMI-IOSCO quantitative disclosure materials provide public institutional context and aggregate resource or liquidity information where available. Other Federal Reserve, U.S. Treasury, or SEC series may be added only with source, definition, frequency, vintage, and transformation metadata.

## Liquidity Coverage Ratio methodology

The project Liquidity Coverage Ratio (LCR) is a CCP research metric and is not the Basel III bank LCR:

`LCR(s,t) = Available Qualifying Liquid Resources(s,t) / Stressed Net Liquidity Requirement(s,t)`

`Liquidity Shortfall(s,t) = max[0, Stressed Net Liquidity Requirement(s,t) - Available Qualifying Liquid Resources(s,t)]`

Interpretation:

- `LCR >= 1.00`: modeled resources cover the modeled stressed requirement;
- `LCR < 1.00`: modeled shortfall exists;
- the ratio is reported with the resource composition, scenario, horizon, data classifications, and uncertainty bounds;
- no PASS result is interpreted as proof of actual FICC sufficiency.

The numerator includes only resource amounts explicitly permitted by the selected scenario. Undrawn, unavailable, uncommitted, operationally inaccessible, or haircut-ineligible amounts are excluded. When public disclosure does not support a line item at the required frequency, the value is labeled assumed or synthetic rather than observed.

## Cover One and Cover Two assumptions

Let `NLR(i,s,t)` be the positive modeled net liquidity requirement for synthetic member family `i`, scenario `s`, and date `t`.

- Cover One requirement: `max_i NLR(i,s,t)`. This is the baseline aligned to FICC's public description of sizing for the member or member family with the largest aggregate liquidity exposure under extreme but plausible conditions.
- Cover Two requirement: the sum of the two largest positive values of `NLR(i,s,t)`. This is a conservative project challenger and sensitivity benchmark. It is not presented as FICC's disclosed GSD regulatory minimum.
- Affiliated entities are aggregated to a member-family unit only in the synthetic allocation layer.
- Joint-default dependence, concentration, and wrong-way effects are explicit scenario assumptions.
- Cover One and Cover Two are calculated for the same scenario date, liquidity horizon, currency, exposure universe, and resource-availability convention.

## Historical stress coverage

Historical replay will include all feasible observations within the downloaded source history and named event windows supported by available series, including the 2007â€“2009 financial crisis, the September 2019 repo-market disruption, the March 2020 Treasury-market disruption, the 2022 rate-volatility period, and later publicly observed stress episodes. A window is used only when the necessary source coverage is adequate. Historical shocks are observed or derived; application of those shocks to synthetic member exposures produces modeled results.

## Hypothetical stress coverage

The minimum scenario library includes:

- parallel and nonparallel Treasury yield shocks;
- repo-rate and funding-spread shocks;
- increases in settlement volume and financing demand;
- Treasury and agency settlement-fail shocks;
- reduced or delayed resource availability;
- collateral haircut and liquidation-cost increases;
- concentrated member-family exposure;
- same-day and multiday settlement-horizon extensions;
- combined wrong-way scenarios linking greater needs with lower resource availability;
- Cover Two joint-default sensitivity.

Severity levels and combinations are configuration controlled. Every hypothetical parameter is labeled assumed, and every scenario result is labeled modeled.

## Independent validation objectives

The independent validation will assess conceptual soundness, data fitness and lineage, implementation correctness, outcome behavior, benchmark agreement, sensitivity, stress severity, limitations, reproducibility, and model governance. It will challenge both the liquidity-need estimate and resource-availability estimate, not merely recalculate the final ratio.

## Success criteria

- all source fields and model outputs carry the required value classification;
- Cover One and Cover Two calculations are reproducible from version-controlled configuration;
- historical and hypothetical scenarios generate complete coverage, shortfall, and diagnostic outputs;
- independent tests reconcile transformations and core formulas within documented tolerances;
- conclusions remain appropriately qualified by public aggregate-data limitations;
- all Section 1 completion gates pass.

## Authoritative references

- [FICC Disclosure Framework, 2026 Q1](https://www.dtcc.com/-/media/Files/Downloads/legal/policy-and-compliance/FICC-DISCLOSURE-FRAMEWORK-2026-Q1.pdf)
- [FICC and NSCC CPMI-IOSCO Public Quantitative Disclosures, 2026 Q1](https://www.dtcc.com/-/media/Files/Downloads/legal/policy-and-compliance/CPMI-IOSCO-Public-Quantitative-Disclosures-Q1-2026.pdf)
- [17 CFR 240.17Ad-22](https://www.ecfr.gov/current/title-17/chapter-II/part-240/subject-group-ECFR97c9b2f89790a51/section-240.17ad-22)
- [CPMI-IOSCO Principles for Financial Market Infrastructures](https://www.bis.org/cpmi/publ/d101a.pdf)
- [New York Fed Primary Dealer Statistics](https://www.newyorkfed.org/markets/counterparties/primary-dealers-statistics)
- [New York Fed SOFR Data](https://www.newyorkfed.org/markets/reference-rates/sofr)

References were reviewed for project scoping as of 2026-07-19. Later phases must record the exact download date and data vintage.
