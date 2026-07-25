-- Section 29 monthly model-monitoring evidence tables for DuckDB.

CREATE TABLE IF NOT EXISTS monthly_monitoring_runs (
    run_id VARCHAR PRIMARY KEY,
    as_of_date DATE NOT NULL,
    executed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    overall_status VARCHAR NOT NULL,
    pass_count INTEGER NOT NULL,
    warning_count INTEGER NOT NULL,
    failure_count INTEGER NOT NULL,
    config_hash VARCHAR,
    input_manifest_path VARCHAR,
    report_path VARCHAR
);

CREATE TABLE IF NOT EXISTS monthly_monitoring_controls (
    run_id VARCHAR NOT NULL,
    control VARCHAR NOT NULL,
    metric VARCHAR NOT NULL,
    metric_value VARCHAR,
    warning_threshold VARCHAR,
    failure_threshold VARCHAR,
    status VARCHAR NOT NULL,
    severity VARCHAR NOT NULL,
    message VARCHAR NOT NULL,
    details VARCHAR,
    PRIMARY KEY (run_id, control),
    FOREIGN KEY (run_id) REFERENCES monthly_monitoring_runs(run_id)
);

CREATE TABLE IF NOT EXISTS monthly_monitoring_issues (
    issue_id VARCHAR PRIMARY KEY,
    run_id VARCHAR NOT NULL,
    control VARCHAR NOT NULL,
    owner VARCHAR,
    due_date DATE,
    issue_status VARCHAR NOT NULL,
    disposition VARCHAR,
    closure_evidence_path VARCHAR,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at TIMESTAMP,
    FOREIGN KEY (run_id) REFERENCES monthly_monitoring_runs(run_id)
);
