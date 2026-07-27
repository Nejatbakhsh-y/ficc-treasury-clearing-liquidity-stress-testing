# Final Repository Controls Evidence Report

- **Section:** Phase X Section 35 - Final Repository Controls
- **Generated:** 2026-07-27T01:51:56Z
- **Repository:** Nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing
- **Base branch:** main
- **Overall status:** **FAIL**
- **PASS:** 8
- **WARN:** 0
- **FAIL:** 3

## Control results

| Control | Status | Evidence | Required remediation |
|---|---:|---|---|
| GitHub authentication and repository access | PASS | Authenticated repository: Nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing. | None. |
| Feature-branch entry and documented pull requests | PASS | 1 merged pull requests reviewed; branch naming, PR documentation, and sampled main-branch commit association passed. | None. |
| CI checks passed | PASS | 1 checks on main completed successfully, neutrally, or as intentionally skipped. | None. |
| Branch protection active | PASS | main is protected by a branch-protection rule or ruleset. | None. |
| No secrets committed | FAIL | Sensitive files=0; history pattern groups=0; open GitHub alerts=1. | Revoke exposed credentials, remove them from Git history, rotate affected secrets, and close verified alerts. |
| No raw data committed | FAIL | Current prohibited data paths=30; historical prohibited data paths=28. | Remove data artifacts from Git history and retain only contracts, manifests, metadata, and approved small test fixtures. |
| No confidential FICC information | PASS | No high-risk confidentiality markers were detected in Git history, and the README states the public/synthetic data boundary. | None. |
| Runtime outputs properly controlled | PASS | No prohibited runtime outputs are tracked, and mandatory ignore patterns are present. | None. |
| README installation instructions tested | PASS | README contains Python 3.11 environment, editable installation, Pytest, Ruff, and Mypy commands; execution is validated by the fresh-clone gate. | None. |
| Fresh-clone reproduction tested | PASS | A depth-one clone of origin/main created Python 3.11, installed the project, imported the package, and passed Pytest, Ruff, Mypy, and pip check. | None. |
| Security and dependency checks passed | FAIL | pip-audit or Bandit failed, or the tools could not be installed. See fresh_clone_reproduction.log. GitHub reports 1 open Dependabot alert(s). | Remediate or dismiss with documented rationale every open Dependabot alert, then rerun. |

## Scope and limitations

This evidence package combines local Git-tree and full-history pattern checks, GitHub API evidence where permissions allow, clean-clone execution, dependency auditing, and static security analysis. Pattern scans are preventive controls, not a substitute for human review of intellectual property, confidentiality, licensing, or data-release authorization.

No WARN or FAIL may be represented as full Section 35 completion. Close each exception with dated evidence before merging the final sign-off pull request.
