# Final Repository Controls

## Purpose

This control standard closes Phase X, Section 35 for the FICC Treasury Clearing Liquidity Stress Testing and Model Validation repository. It governs source control, pull-request evidence, continuous integration, information security, data handling, reproducibility, dependency security, and public-portfolio publication.

## Mandatory controls

1. All substantive work enters through branches named `feature/*`, `fix/*`, `data/*`, `docs/*`, `chore/*`, or `dependabot/*`.
2. Pull requests require a descriptive title, scope, validation evidence, and limitations or remediation notes.
3. The protected `main` branch prohibits force pushes and deletion and requires pull-request entry.
4. Required CI and security checks must complete successfully before merge.
5. Secrets, credentials, private keys, tokens, and local environment files are prohibited from Git history.
6. Raw, participant-level, confidential, proprietary, and non-public FICC or DTCC information is prohibited.
7. Only official public market data, controlled metadata, configuration, documentation, and synthetic member representations may be published.
8. Generated datasets, DuckDB files, Parquet files, logs, caches, dashboard exports, and other runtime outputs remain outside Git.
9. README installation commands must be executable from a fresh Python 3.11 clone.
10. A fresh-clone test must install the package and pass Pytest, Ruff, Mypy, dependency consistency, dependency vulnerability, and static security checks.
11. Section 35 evidence is retained under `reports/evidence/final_repository_controls`; only concise control evidence, not bulky runtime output, is versioned.

## Evidence interpretation

- **PASS**: objective evidence satisfies the control.
- **WARN**: the control could not be verified completely because a GitHub feature, permission, or service was unavailable.
- **FAIL**: objective evidence contradicts the control or a mandatory gate failed.

A WARN or FAIL must not be presented as successful completion. Any exception requires documented rationale, owner, target date, and closure evidence.
