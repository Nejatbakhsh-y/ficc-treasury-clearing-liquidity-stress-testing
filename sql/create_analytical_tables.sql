-- Section 8: controlled analytical tables.
-- Execute from the repository root so the relative Parquet paths resolve.

CREATE OR REPLACE TABLE fed_liquidity_factors AS
SELECT *
FROM read_parquet('data/processed/fed_liquidity_factors.parquet');

CREATE OR REPLACE TABLE treasury_market_factors AS
SELECT *
FROM read_parquet('data/processed/treasury_market_factors.parquet');

CREATE OR REPLACE VIEW fed_liquidity_factors_daily AS
SELECT * FROM fed_liquidity_factors
WHERE alignment_frequency = 'daily';

CREATE OR REPLACE VIEW fed_liquidity_factors_weekly AS
SELECT * FROM fed_liquidity_factors
WHERE alignment_frequency = 'weekly';

CREATE OR REPLACE VIEW treasury_market_factors_daily AS
SELECT * FROM treasury_market_factors
WHERE alignment_frequency = 'daily';

CREATE OR REPLACE VIEW treasury_market_factors_weekly AS
SELECT * FROM treasury_market_factors
WHERE alignment_frequency = 'weekly';

CREATE OR REPLACE VIEW latest_factor_observations AS
WITH combined AS (
    SELECT 'fed_liquidity' AS dataset_name, * FROM fed_liquidity_factors
    UNION ALL BY NAME
    SELECT 'treasury_market' AS dataset_name, * FROM treasury_market_factors
), ranked AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY dataset_name, alignment_frequency, source_name, source_series_id
            ORDER BY observation_date DESC
        ) AS recency_rank
    FROM combined
)
SELECT * EXCLUDE (recency_rank)
FROM ranked
WHERE recency_rank = 1;

CREATE OR REPLACE VIEW source_lineage_summary AS
SELECT
    source_name,
    source_file,
    source_sha256,
    min(observation_date) AS minimum_observation_date,
    max(observation_date) AS maximum_observation_date,
    count(*) AS analytical_rows,
    count(DISTINCT source_series_id) AS series_count
FROM (
    SELECT * FROM fed_liquidity_factors
    UNION ALL BY NAME
    SELECT * FROM treasury_market_factors
)
GROUP BY source_name, source_file, source_sha256;