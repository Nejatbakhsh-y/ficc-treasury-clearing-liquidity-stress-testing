-- Phase VIII Section 30 monitoring-governance evidence tables for DuckDB.

CREATE TABLE IF NOT EXISTS monitoring_governance_runs (
    run_id VARCHAR PRIMARY KEY,
    as_of_date DATE NOT NULL,
    overall_traffic_light VARCHAR NOT NULL,
    green_count INTEGER NOT NULL,
    amber_count INTEGER NOT NULL,
    red_count INTEGER NOT NULL,
    model_change_trigger_count INTEGER NOT NULL,
    revalidation_required BOOLEAN NOT NULL,
    monthly_sign_off_status VARCHAR NOT NULL,
    annual_validation_status VARCHAR NOT NULL,
    annual_validation_due_date DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS monitoring_breach_actions (
    run_id VARCHAR NOT NULL,
    as_of_date DATE NOT NULL,
    control_name VARCHAR NOT NULL,
    metric_name VARCHAR NOT NULL,
    monitoring_status VARCHAR NOT NULL,
    traffic_light VARCHAR NOT NULL,
    severity VARCHAR NOT NULL,
    primary_owner VARCHAR NOT NULL,
    secondary_owner VARCHAR NOT NULL,
    acknowledgment_due_date DATE,
    investigation_due_date DATE,
    remediation_due_date DATE,
    investigation_required BOOLEAN NOT NULL,
    use_restriction_assessment BOOLEAN NOT NULL,
    model_change_trigger BOOLEAN NOT NULL,
    revalidation_trigger BOOLEAN NOT NULL,
    revalidation_reason VARCHAR,
    disposition_status VARCHAR NOT NULL,
    management_acceptance_required BOOLEAN NOT NULL,
    message VARCHAR,
    details VARCHAR,
    PRIMARY KEY (run_id, control_name, metric_name),
    FOREIGN KEY (run_id) REFERENCES monitoring_governance_runs(run_id)
);

CREATE TABLE IF NOT EXISTS monitoring_monthly_signoffs (
    run_id VARCHAR NOT NULL,
    as_of_date DATE NOT NULL,
    role_name VARCHAR NOT NULL,
    signer_name VARCHAR,
    decision VARCHAR NOT NULL,
    signature_date DATE,
    comments VARCHAR,
    governance_status VARCHAR NOT NULL,
    PRIMARY KEY (run_id, role_name),
    FOREIGN KEY (run_id) REFERENCES monitoring_governance_runs(run_id)
);

CREATE TABLE IF NOT EXISTS monitoring_annual_validations (
    validation_id VARCHAR PRIMARY KEY,
    validation_start_date DATE,
    validation_completion_date DATE,
    validation_due_date DATE NOT NULL,
    validation_status VARCHAR NOT NULL,
    independent_validator VARCHAR,
    scope_statement VARCHAR,
    report_location VARCHAR,
    open_high_or_critical_findings INTEGER DEFAULT 0,
    management_acceptance_date DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
