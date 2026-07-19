[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing",
    [string]$ProjectOwner = "Yousef Nejatbakhsh",
    [ValidateSet("APPROVED", "PENDING")]
    [string]$ApprovalStatus = "APPROVED",
    [switch]$Commit,
    [switch]$Push,
    [ValidateSet("public", "private")]
    [string]$GitHubVisibility = "public",
    [string]$GitHubRepositoryName = "ficc-treasury-clearing-liquidity-stress-testing"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowExitCodeOne
    )

    & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not ($AllowExitCodeOne -and $exitCode -eq 1)) {
        throw "Command failed with exit code ${exitCode}: $Command $($Arguments -join ' ')"
    }
    return $exitCode
}

function Expand-Template {
    param([string]$Text)
    return $Text.Replace("{{DATE}}", $script:RunDate).Replace("{{OWNER}}", $ProjectOwner).Replace("{{APPROVAL_STATUS}}", $ApprovalStatus)
}

function Write-ManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        $relativePath = $Path.Substring($ProjectRoot.Length).TrimStart([char[]]@('\', '/'))
        $backupPath = Join-Path $script:BackupRoot $relativePath
        $backupParent = Split-Path -Parent $backupPath
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }

    $expanded = (Expand-Template -Text $Content).Trim() + [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $expanded, $utf8NoBom)
}

function Test-RequiredPatterns {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string[]]$Patterns
    )

    $combined = ($Paths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
    foreach ($pattern in $Patterns) {
        if ($combined -notmatch $pattern) {
            return $false
        }
    }
    return $true
}

$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$script:RunDate = (Get-Date).ToString("yyyy-MM-dd")
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$script:BackupRoot = Join-Path $ProjectRoot ".backups\phase1_section1\$stamp"

$docsDirectory = Join-Path $ProjectRoot "docs"
$evidenceDirectory = Join-Path $ProjectRoot "reports\evidence"
$projectCharterPath = Join-Path $docsDirectory "project_charter.md"
$scopePath = Join-Path $docsDirectory "model_scope_and_limitations.md"
$validationCharterPath = Join-Path $docsDirectory "validation_charter.md"
$inventoryPath = Join-Path $docsDirectory "model_inventory.md"
$gatePath = Join-Path $evidenceDirectory "phase1_section1_completion_gate.md"
$manifestPath = Join-Path $evidenceDirectory "phase1_section1_manifest.csv"

Write-Step "Preparing the project directories"
New-Item -ItemType Directory -Path $ProjectRoot, $docsDirectory, $evidenceDirectory -Force | Out-Null

$projectCharter = @'
# FICC Treasury Clearing Liquidity Stress Testing and Model Validation

## Project charter

| Field | Value |
| --- | --- |
| Project phase | Phase I — Project and GitHub Foundation |
| Section | Section 1 — Project Charter and Validation Scope |
| Project owner | {{OWNER}} |
| Effective date | {{DATE}} |
| Scope approval | {{APPROVAL_STATUS}} |
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

Historical replay will include all feasible observations within the downloaded source history and named event windows supported by available series, including the 2007–2009 financial crisis, the September 2019 repo-market disruption, the March 2020 Treasury-market disruption, the 2022 rate-volatility period, and later publicly observed stress episodes. A window is used only when the necessary source coverage is adequate. Historical shocks are observed or derived; application of those shocks to synthetic member exposures produces modeled results.

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

References were reviewed for project scoping as of {{DATE}}. Later phases must record the exact download date and data vintage.
'@

$scopeDocument = @'
# Model Scope and Limitations

## Scope statement

This project models a public-data proxy for FICC GSD Treasury-clearing liquidity stress. The unit of analysis is a synthetic member family; the output is a research estimate of stressed net liquidity requirements, proxy available qualifying liquid resources, coverage ratios, and shortfalls. Actual FICC members, obligations, resources, intraday payment queues, and default-management actions are outside the observable dataset.

## In-scope components

| Component | In scope | Treatment |
| --- | --- | --- |
| Treasury cash and repo market conditions | Yes | Observed aggregate Federal Reserve or other authoritative public data |
| Dealer positions, transactions, financing, and fails | Yes | Observed aggregates; derived features are separately labeled |
| Synthetic member-family exposures | Yes | Generated from documented allocation and concentration assumptions |
| Cover One | Yes | Baseline: largest synthetic member-family requirement |
| Cover Two | Yes | Conservative challenger: two largest synthetic member-family requirements |
| Historical replay | Yes | Public observed or derived shocks applied through the proxy model |
| Hypothetical stress | Yes | Configuration-controlled assumed shocks |
| Resource sufficiency | Yes, as a proxy | Uses public observed aggregates where suitable and explicitly assumed or synthetic amounts otherwise |
| Actual FICC compliance determination | No | Prohibited interpretation |

## Data-classification standard

Every numeric analytical value must have exactly one primary classification:

| Classification | Definition | Example | Permitted claim |
| --- | --- | --- | --- |
| Observed | Value published by an authoritative source and retained without analytical alteration other than type or unit normalization | Published aggregate dealer financing or SOFR volume | The source reported this aggregate value |
| Derived | Deterministic transformation of observed values | Weekly change, rolling volatility, normalized stress percentile | The value was calculated from named observed inputs |
| Synthetic | Artificial micro-level value created to make analysis possible without confidential data | Synthetic member-family exposure | The value is simulated and does not identify a real member |
| Assumed | Expert, policy, or scenario choice not directly established by the public data | Resource-availability haircut or Cover Two dependence parameter | The value is a documented scenario assumption |
| Modeled | Output produced by a statistical, econometric, allocation, or stress model | Stressed requirement, LCR, or shortfall | The value is a model estimate subject to validation |

Required lineage fields are `value_type`, `source_id`, `source_url`, `as_of_date`, `retrieval_timestamp_utc`, `transformation_id`, `assumption_id`, `scenario_id`, and `model_version`. Nonapplicable fields must be null, not fabricated. A modeled value must retain links to all material observed, derived, synthetic, and assumed inputs.

## Explicit public aggregate-data limitations

Public aggregate data do not reveal:

- actual FICC member or affiliate-family positions, novated trades, obligations, concentration, or defaults;
- actual intraday settlement timing, payment queues, operational delays, liquidity calls, or end-of-day closeout activity;
- member-specific clearing-fund deposits, CCLF obligations, committed facility terms, draw capacity, collateral eligibility, haircuts, or operational availability;
- FICC's confidential scenario design, dependence structure, stress parameters, liquidity forecast, backtesting exceptions, management overlays, or intraday monitoring;
- the mapping between primary dealers and FICC member families or the activity of non-primary-dealer clearing participants;
- transaction-level distributions hidden by aggregation, including tail exposures and offsetting positions.

Consequences of these limitations:

1. Aggregate dealer activity cannot be disaggregated into true member exposures. Any allocation is synthetic.
2. Aggregate market volumes cannot be interpreted as FICC settlement obligations or liquidity needs.
3. Quarterly public resource disclosures and weekly or daily market series create frequency mismatch.
4. Reporting-definition changes can cause structural breaks that resemble economic shocks.
5. Revised observations, publication lags, missing values, and event-window coverage can affect backtests.
6. A proxy LCR above one does not prove actual FICC liquidity sufficiency; a proxy LCR below one does not prove an actual FICC shortfall.
7. Cover Two results are an analytical challenger, not a statement that FICC is required to or does maintain Cover Two for GSD.

## Model boundary

The project begins with ingestion of named public datasets and ends with research reports and validation findings. It excludes production deployment, real-time clearing integration, confidential or personal data, legal advice, regulatory reporting, recovery and wind-down execution, and actual liquidity facility activation.

## Controls required by later phases

- source-file checksums and immutable raw-data storage;
- schema, unit, frequency, revision, and missingness tests;
- explicit definition-break handling;
- deterministic random seeds for synthetic allocations;
- configuration-controlled scenarios and assumptions;
- no real-firm labels in synthetic member data;
- independent code reconciliation for coverage and shortfall formulas;
- separate reporting of observed evidence and model inference;
- limitation banner on every decision-facing report or dashboard.

## Interpretation policy

Language such as "FICC will require," "FICC member exposure," or "FICC is insufficient" is prohibited unless supported by actual authoritative evidence for that exact claim. Preferred language is "public-data proxy," "synthetic member family," "modeled requirement," and "research scenario." Material conclusions must state the dominant data and assumption limitations.

## Acceptance

This scope is accepted for public-data research and independent model-validation development by {{OWNER}} on {{DATE}}. Approval status: **{{APPROVAL_STATUS}}**.
'@

$validationCharter = @'
# Independent Validation Charter

## Authorization and approval

| Field | Value |
| --- | --- |
| Validation subject | Public-data FICC GSD Treasury-clearing liquidity stress model |
| Model owner | {{OWNER}} |
| Independent validation role | Methodological challenge and verification separated from model-development conclusions |
| Effective date | {{DATE}} |
| Approval status | {{APPROVAL_STATUS}} |
| Approval authority | {{OWNER}}, project owner |

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

Independent validation scope approved: **{{APPROVAL_STATUS}}**  
Approved by: **{{OWNER}}**  
Approval date: **{{DATE}}**
'@

$modelInventory = @'
# Model Inventory

## Inventory purpose

This inventory identifies the analytical components planned for the public-data FICC GSD liquidity stress framework. IDs remain stable across code, configuration, tests, evidence, findings, and reports.

| Model ID | Component | Purpose | Primary inputs | Primary outputs | Value class | Materiality | Validation status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LST-001 | Market Data Ingestion and Harmonization | Acquire and align authoritative public Treasury and repo series | NY Fed, Federal Reserve, DTCC, SEC, U.S. Treasury data | Versioned analytical time series | Observed and derived | High | Planned |
| LST-002 | Market Stress Feature Engine | Convert public observations into standardized liquidity-stress indicators | Harmonized time series | Changes, volatilities, percentiles, event shocks | Derived | High | Planned |
| LST-003 | Synthetic Member-Family Allocator | Allocate aggregate activity to anonymous member families | Aggregate activity, seed, concentration assumptions | Synthetic family exposures | Synthetic and assumed | Critical | Planned |
| LST-004 | Baseline Liquidity-Need Model | Estimate net settlement liquidity need by synthetic family | Synthetic exposures, settlement assumptions, market features | Baseline net liquidity requirement | Modeled | Critical | Planned |
| LST-005 | Historical Stress Engine | Replay public historical shocks through the proxy portfolio | Historical event shocks, baseline requirements | Historically stressed requirements | Derived and modeled | Critical | Planned |
| LST-006 | Hypothetical Stress Engine | Apply configuration-controlled extreme but plausible shocks | Scenario assumptions, baseline requirements | Hypothetically stressed requirements | Assumed and modeled | Critical | Planned |
| LST-007 | Qualifying Liquid Resources Proxy | Estimate resources available within each scenario and horizon | Public disclosures, eligibility and availability assumptions | Available-resource proxy | Observed, assumed, synthetic, and modeled | Critical | Planned |
| LST-008 | Cover One Aggregator | Select the largest positive synthetic member-family requirement | Family-level stressed requirements | Cover One requirement | Modeled | Critical | Planned |
| LST-009 | Cover Two Challenger | Sum the two largest positive synthetic family requirements | Family-level stressed requirements | Cover Two challenger requirement | Modeled | High | Planned |
| LST-010 | Coverage and Shortfall Calculator | Compare available resources with stressed requirements | Resource proxy, Cover One or Cover Two requirement | LCR, shortfall, breach flag | Modeled | Critical | Planned |
| LST-011 | Sensitivity and Uncertainty Engine | Quantify dependence on material assumptions | Parameter grids, alternative seeds and models | Sensitivity surfaces and uncertainty ranges | Modeled | High | Planned |
| LST-012 | Monitoring and Validation Reporting | Produce traceable diagnostics and decision-use controls | Model outputs, test results, findings | Reports, evidence, dashboards | Derived and modeled | High | Planned |

## Critical-model conventions

- Critical components require independent formula reconciliation and documented test evidence.
- LST-003 outputs never use actual firm names or imply that allocation weights are observed.
- LST-007 reports observed resource disclosures separately from assumed availability and timing adjustments.
- LST-009 is a project challenger and is not labeled as FICC's disclosed minimum requirement.
- All model outputs include `model_id`, `model_version`, `run_id`, `scenario_id`, `as_of_date`, and `value_type`.

## Ownership and review cycle

| Role | Assigned party | Responsibility |
| --- | --- | --- |
| Project and model owner | {{OWNER}} | Requirements, implementation, documentation, remediation |
| Independent validation function | Independent validation workstream | Challenge, testing, findings, approval recommendation |
| Data owner | Public-data pipeline workstream | Source control, lineage, quality, definitions, revisions |
| Model-risk approver | Project governance role | Scope and final-use approval based on evidence |

Inventory review occurs at each phase gate and whenever a component, material assumption, data source, intended use, or critical output changes. The initial inventory was approved for implementation on {{DATE}} with scope status **{{APPROVAL_STATUS}}**.
'@

Write-Step "Creating the four Section 1 deliverables"
Write-ManagedFile -Path $projectCharterPath -Content $projectCharter
Write-ManagedFile -Path $scopePath -Content $scopeDocument
Write-ManagedFile -Path $validationCharterPath -Content $validationCharter
Write-ManagedFile -Path $inventoryPath -Content $modelInventory

Write-Step "Running the Section 1 completion gates"
$gates = @(
    [pscustomobject]@{
        Gate = "Project objective defined"
        Pass = Test-RequiredPatterns -Paths @($projectCharterPath) -Patterns @("## Business objective", "## Research questions", "reproducible")
    },
    [pscustomobject]@{
        Gate = "Intended use documented"
        Pass = Test-RequiredPatterns -Paths @($projectCharterPath, $scopePath) -Patterns @("## Intended model use", "Permitted uses", "Prohibited uses")
    },
    [pscustomobject]@{
        Gate = "Public-data limitations documented"
        Pass = Test-RequiredPatterns -Paths @($scopePath) -Patterns @("## Explicit public aggregate-data limitations", "cannot be disaggregated", "does not prove actual FICC")
    },
    [pscustomobject]@{
        Gate = "Independent validation scope approved"
        Pass = (Test-RequiredPatterns -Paths @($validationCharterPath) -Patterns @("## Validation mandate", "## Objectives", "Independent validation scope approved: \*\*APPROVED\*\*"))
    }
)

$gateRows = $gates | ForEach-Object {
    $status = if ($_.Pass) { "PASS" } else { "FAIL" }
    "| $($_.Gate) | $status |"
}

$gateReportTemplate = @'
# Phase I, Section 1 Completion Gate

| Field | Value |
| --- | --- |
| Project | FICC Treasury Clearing Liquidity Stress Testing and Model Validation |
| Run date | {{DATE}} |
| Project owner | {{OWNER}} |
| Scope approval setting | {{APPROVAL_STATUS}} |

| Completion gate | Status |
| --- | --- |
{{GATE_ROWS}}

## Deliverables verified

- `docs/project_charter.md`
- `docs/model_scope_and_limitations.md`
- `docs/validation_charter.md`
- `docs/model_inventory.md`

The gate validates required Section 1 documentation content. It does not validate later model implementation, data, results, or FICC regulatory compliance.
'@
$gateReport = $gateReportTemplate.Replace("{{GATE_ROWS}}", ($gateRows -join [Environment]::NewLine))
Write-ManagedFile -Path $gatePath -Content $gateReport

$manifest = @($projectCharterPath, $scopePath, $validationCharterPath, $inventoryPath, $gatePath) | ForEach-Object {
    $hash = Get-FileHash -LiteralPath $_ -Algorithm SHA256
    [pscustomobject]@{
        relative_path = $_.Substring($ProjectRoot.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        sha256 = $hash.Hash.ToLowerInvariant()
        generated_on = $script:RunDate
        approval_status = $ApprovalStatus
    }
}
$manifest | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8

$failedGates = @($gates | Where-Object { -not $_.Pass })
foreach ($gate in $gates) {
    $color = if ($gate.Pass) { "Green" } else { "Red" }
    $status = if ($gate.Pass) { "PASS" } else { "FAIL" }
    Write-Host ("{0,-47} {1}" -f ($gate.Gate + ":"), $status) -ForegroundColor $color
}

if ($failedGates.Count -gt 0) {
    throw "Section 1 is not complete. Review $gatePath. ApprovalStatus must be APPROVED for the approval gate to pass."
}

if ($Push -and -not $Commit) {
    throw "-Push requires -Commit so that only a verified Section 1 version is published."
}

if ($Commit) {
    Write-Step "Recording the verified deliverables in Git"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or is not available in PATH."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot ".git"))) {
        Invoke-NativeCommand -Command "git" -Arguments @("-C", $ProjectRoot, "init", "-b", "main") | Out-Null
    }

    $branchName = "phase-1-section-1-project-charter"
    & git -C $ProjectRoot show-ref --verify --quiet "refs/heads/$branchName"
    if ($LASTEXITCODE -eq 0) {
        Invoke-NativeCommand -Command "git" -Arguments @("-C", $ProjectRoot, "switch", $branchName) | Out-Null
    }
    else {
        Invoke-NativeCommand -Command "git" -Arguments @("-C", $ProjectRoot, "switch", "-c", $branchName) | Out-Null
    }

    $gitAddArguments = @(
        "-C", $ProjectRoot, "add", "--",
        "docs/project_charter.md",
        "docs/model_scope_and_limitations.md",
        "docs/validation_charter.md",
        "docs/model_inventory.md",
        "reports/evidence/phase1_section1_completion_gate.md",
        "reports/evidence/phase1_section1_manifest.csv"
    )
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot "P1S1_Project_Charter_Automation.ps1")) {
        $gitAddArguments += "P1S1_Project_Charter_Automation.ps1"
    }
    Invoke-NativeCommand -Command "git" -Arguments $gitAddArguments | Out-Null

    & git -C $ProjectRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
        Invoke-NativeCommand -Command "git" -Arguments @("-C", $ProjectRoot, "commit", "-m", "docs: complete Phase I Section 1 charter and scope") | Out-Null
    }
    elseif ($LASTEXITCODE -ne 0) {
        throw "Git could not inspect the staged changes."
    }
    else {
        Write-Host "No new Git changes were required." -ForegroundColor Yellow
    }

    if ($Push) {
        Write-Step "Publishing the verified branch to GitHub"
        & git -C $ProjectRoot remote get-url origin 2>$null
        $originExists = ($LASTEXITCODE -eq 0)

        if ($originExists) {
            Invoke-NativeCommand -Command "git" -Arguments @("-C", $ProjectRoot, "push", "-u", "origin", $branchName) | Out-Null
        }
        else {
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
                throw "No origin remote exists and GitHub CLI is unavailable. Install/authenticate gh or add an origin remote, then rerun with -Commit -Push."
            }
            Invoke-NativeCommand -Command "gh" -Arguments @(
                "repo", "create", $GitHubRepositoryName, "--$GitHubVisibility",
                "--source", $ProjectRoot, "--remote", "origin", "--push"
            ) | Out-Null
        }
    }
}

Write-Step "Phase I, Section 1 completed successfully"
Write-Host "Project root: $ProjectRoot"
Write-Host "Completion evidence: $gatePath"
Write-Host "Existing deliverables, if any, were backed up under: $script:BackupRoot"
Write-Host "All four required completion gates: PASS" -ForegroundColor Green
