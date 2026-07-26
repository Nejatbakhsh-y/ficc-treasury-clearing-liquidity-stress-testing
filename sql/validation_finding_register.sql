-- Phase VIII, Section 31: validation finding register evidence structures.
-- Compatible with DuckDB.

CREATE TABLE IF NOT EXISTS validation_finding_register (
    finding_id VARCHAR PRIMARY KEY,
    category VARCHAR NOT NULL,
    condition VARCHAR NOT NULL,
    evidence VARCHAR NOT NULL,
    risk VARCHAR NOT NULL,
    recommendation VARCHAR NOT NULL,
    management_response VARCHAR NOT NULL,
    owner VARCHAR NOT NULL,
    target_date DATE NOT NULL,
    status VARCHAR NOT NULL,
    closure_evidence VARCHAR NOT NULL,
    CHECK (category IN ('Critical', 'High', 'Medium', 'Low', 'Observation')),
    CHECK (
        status IN (
            'Open',
            'Remediation in Progress',
            'Pending Validation Review',
            'Risk Accepted',
            'Closed',
            'Overdue'
        )
    )
);

CREATE OR REPLACE VIEW validation_findings_active AS
SELECT *
FROM validation_finding_register
WHERE status IN (
    'Open',
    'Remediation in Progress',
    'Pending Validation Review',
    'Overdue'
);

CREATE OR REPLACE VIEW validation_findings_overdue AS
SELECT *
FROM validation_finding_register
WHERE
    status = 'Overdue'
    OR (
        status IN ('Open', 'Remediation in Progress', 'Pending Validation Review')
        AND target_date < current_date
    );

CREATE OR REPLACE VIEW validation_finding_classification_summary AS
SELECT
    category,
    count(*) AS finding_count,
    sum(
        CASE
            WHEN status IN (
                'Open',
                'Remediation in Progress',
                'Pending Validation Review',
                'Overdue'
            )
            THEN 1
            ELSE 0
        END
    ) AS active_finding_count,
    sum(CASE WHEN status = 'Overdue' THEN 1 ELSE 0 END) AS overdue_finding_count
FROM validation_finding_register
GROUP BY category;

CREATE OR REPLACE VIEW validation_finding_owner_summary AS
SELECT
    owner,
    count(*) AS finding_count,
    sum(CASE WHEN status = 'Closed' THEN 1 ELSE 0 END) AS closed_count,
    sum(CASE WHEN status = 'Overdue' THEN 1 ELSE 0 END) AS overdue_count
FROM validation_finding_register
GROUP BY owner;
