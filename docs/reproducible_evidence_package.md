# Phase IX — Section 32: Reproducible Evidence Package

## Objective

Section 32 creates a controlled, reproducible package of the principal evidence
produced by the FICC Treasury clearing liquidity stress-testing and model-validation
workflow.

## Evidence scope

The package inventories and copies:

1. Data-quality results.
2. Scenario results.
3. Cover 1 and Cover 2 tables.
4. Liquidity coverage ratio results.
5. Liquidity shortfalls.
6. Stress-component contributions.
7. Sensitivity results.
8. Reverse-stress results.
9. Monitoring results.
10. Validation findings.
11. Configuration provenance.
12. Runtime and environment evidence.

## Reproducibility controls

Each package contains:

- A unique UTC package identifier linked to the current Git commit.
- Source-relative and package-relative artifact paths.
- SHA-256 checksums and file sizes.
- Category-level completeness status.
- Python, operating-system, package, Git branch, Git commit, and Git-status evidence.
- A ZIP archive and a refreshed `latest` alias.
- Diagnostic markers for missing evidence categories.

## Commands

From the repository root in the VS Code terminal:

```powershell
$env:PYTHONPATH = "$PWD\src"
python scripts\build_evidence_package.py --repo-root "$PWD"
```

Strict completeness gate:

```powershell
$env:PYTHONPATH = "$PWD\src"
python scripts\build_evidence_package.py --repo-root "$PWD" --strict
```

## Outputs

```text
reports/evidence_packages/<UTC_TIMESTAMP>_<GIT_COMMIT>/
reports/evidence_packages/<UTC_TIMESTAMP>_<GIT_COMMIT>.zip
reports/evidence_packages/latest/
reports/evidence_packages/latest.zip
```

## Interpretation

A category marked `AVAILABLE` contains one or more matching upstream artifacts.
A category marked `MISSING` contains only a diagnostic marker and must be resolved
before the package is accepted as final validation evidence.

## Gate

Section 32 is complete when:

- The targeted tests pass.
- The evidence package and ZIP archive are generated.
- All required categories are `AVAILABLE` under strict mode.
- The manifest contains valid SHA-256 checksums.
- Runtime, environment, configuration, and Git provenance are captured.
