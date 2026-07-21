# Official Federal Reserve Data Catalog and Source Contracts

**Catalog as of:** 2026-07-19

**Branch:** `feature/02-fed-data-catalog`

## Purpose

This catalog is the controlled source-of-truth for official Federal Reserve and New York Fed inputs used by the FICC Treasury Clearing Liquidity Stress Testing and Model Validation project. It defines acquisition, lineage, publication timing, revision handling, intended use, and known limitations before any data are transformed.

## Mandatory controls

- Use HTTPS official-source endpoints only.
- Record retrieval timestamp in UTC.
- Retain the original raw payload and a SHA-256 checksum.
- Record source publication date, observation date, and revision indicator where available.
- Do not overwrite a source vintage used by a completed model run.
- Apply reporting-regime mappings before combining FR 2004 history.
- Separate observed, derived, synthetic, assumed, and modeled values.
- Document all imputations; do not forward-fill across unverified publication gaps.

## Value classification

| Classification | Meaning |
|---|---|
| `observed` | Directly published official values retained without economic transformation. |
| `derived` | Deterministic calculations from observed values; must record formula and lineage. |
| `synthetic` | Generated data used only where public aggregates cannot support member-level analysis. |
| `assumed` | Expert or policy assumptions; must not be represented as observed Federal Reserve data. |
| `modeled` | Outputs produced by the liquidity stress-testing model. |

## Source-level catalog

| Source | Publisher | Publication calendar | Available history |
|---|---|---|---|
| FR 2004 Primary Dealer Statistics | Federal Reserve Bank of New York | Weekly; updated Thursday at approximately 4:15 p.m. ET with the previous reporting week's statistics. | Primary Dealer Statistics are available from 1998-01-28 to present and are segmented by reporting regime. Treasury settlement-fails history extends to July 1990. |
| New York Fed SOFR | Federal Reserve Bank of New York | Each U.S. government-securities business day at approximately 8:00 a.m. ET, normally reflecting the prior business day's transactions. | SOFR value date history begins 2018-04-02; first publication was 2018-04-03. |
| Federal Reserve H.15 Selected Interest Rates | Board of Governors of the Federal Reserve System | Daily Monday through Friday at 4:15 p.m. ET; not posted on holidays or when the Board is closed. | History varies by maturity. Long-tenor nominal constant-maturity series generally begin in 1962; bill and newer maturity series begin later. |
| Federal Reserve H.4.1 Factors Affecting Reserve Balances | Board of Governors of the Federal Reserve System | Weekly each Thursday, generally at 4:30 p.m. ET. Publication may shift to the next business day when the regular date is a federal holiday. | Selected current-format FRED/DDP series used here begin 2002-12-18; older historical tables exist for some H.4.1 concepts. |

## Series-level source contracts

Every required series below is classified as an **observed official aggregate**. Any downstream transformation must be separately classified as derived, synthetic, assumed, or modeled.

### FR2004_TSY_NET_POSITIONS â€” FR 2004A/B/C; Treasury net-position API code resolved from /api/pd/list/timeseries.csv

- **Official source:** FR 2004 Primary Dealer Statistics
- **Official source URL:** https://www.newyorkfed.org/markets/counterparties/primary-dealers-statistics
- **Machine-access URL:** https://markets.newyorkfed.org/api/pd/list/timeseries.csv
- **Definition:** Aggregate net positions of primary dealers in U.S. Treasury securities for the applicable maturity or reporting bucket.
- **Unit:** USD millions
- **Frequency:** Weekly, as of reporting date
- **Publication calendar:** Weekly; Thursday approximately 4:15 p.m. ET, reporting the previous week's statistics.
- **Available history:** 1998-01-28 to present; segmented when FR 2004 reporting structure changes.
- **Revision policy:** Retain immutable raw snapshots and SHA-256 hashes. Resolve the official NY Fed API code from the time-series-list endpoint for the applicable reporting regime; do not splice regime segments without an explicit mapping.
- **Intended model use:** Dealer-inventory state variable; proxy for intermediation capacity and inventory liquidation pressure.
- **Known limitations:** Aggregate primary-dealer data; no dealer identities, no FICC-member mapping, structural breaks across reporting regimes, and no direct CCP liquidity obligation.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### FR2004_TSY_OUTRIGHT_TRANSACTIONS â€” FR 2004A/B/C; Treasury outright-transaction API code resolved from /api/pd/list/timeseries.csv

- **Official source:** FR 2004 Primary Dealer Statistics
- **Official source URL:** https://www.newyorkfed.org/markets/counterparties/primary-dealers-statistics
- **Machine-access URL:** https://markets.newyorkfed.org/api/pd/list/timeseries.csv
- **Definition:** Aggregate outright purchases and sales of U.S. Treasury securities, generally reported as a daily average for the week.
- **Unit:** USD millions, daily average
- **Frequency:** Weekly publication
- **Publication calendar:** Weekly; Thursday approximately 4:15 p.m. ET, reporting the previous week's statistics.
- **Available history:** 1998-01-28 to present; segmented when FR 2004 reporting structure changes.
- **Revision policy:** Retain immutable raw snapshots and SHA-256 hashes. Resolve the official NY Fed API code from the time-series-list endpoint for the applicable reporting regime; do not splice regime segments without an explicit mapping.
- **Intended model use:** Market-turnover and liquidation-capacity proxy used to scale stressed liquidation horizons and market-depth assumptions.
- **Known limitations:** Aggregate primary-dealer data; no dealer identities, no FICC-member mapping, structural breaks across reporting regimes, and no direct CCP liquidity obligation. Transactions exclude repurchase and reverse-repurchase agreements.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### FR2004_TSY_REPO_FINANCING â€” FR 2004A/B/C; Treasury repo-financing API code resolved from /api/pd/list/timeseries.csv

- **Official source:** FR 2004 Primary Dealer Statistics
- **Official source URL:** https://www.newyorkfed.org/markets/counterparties/primary-dealers-statistics
- **Machine-access URL:** https://markets.newyorkfed.org/api/pd/list/timeseries.csv
- **Definition:** Aggregate primary-dealer securities-out financing in repurchase agreements collateralized by Treasury securities.
- **Unit:** USD millions
- **Frequency:** Weekly, as of reporting date
- **Publication calendar:** Weekly; Thursday approximately 4:15 p.m. ET, reporting the previous week's statistics.
- **Available history:** 1998-01-28 to present; segmented when FR 2004 reporting structure changes.
- **Revision policy:** Retain immutable raw snapshots and SHA-256 hashes. Resolve the official NY Fed API code from the time-series-list endpoint for the applicable reporting regime; do not splice regime segments without an explicit mapping.
- **Intended model use:** Secured-funding dependence and rollover-pressure proxy for hypothetical liquidity stresses.
- **Known limitations:** Aggregate primary-dealer data; no dealer identities, no FICC-member mapping, structural breaks across reporting regimes, and no direct CCP liquidity obligation. Aggregation and netting conventions may change by reporting regime.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### FR2004_TSY_REVERSE_REPO_FINANCING â€” FR 2004A/B/C; Treasury reverse-repo/securities-in API code resolved from /api/pd/list/timeseries.csv

- **Official source:** FR 2004 Primary Dealer Statistics
- **Official source URL:** https://www.newyorkfed.org/markets/counterparties/primary-dealers-statistics
- **Machine-access URL:** https://markets.newyorkfed.org/api/pd/list/timeseries.csv
- **Definition:** Aggregate primary-dealer securities-in financing through reverse repurchase agreements collateralized by Treasury securities.
- **Unit:** USD millions
- **Frequency:** Weekly, as of reporting date
- **Publication calendar:** Weekly; Thursday approximately 4:15 p.m. ET, reporting the previous week's statistics.
- **Available history:** 1998-01-28 to present; segmented when FR 2004 reporting structure changes.
- **Revision policy:** Retain immutable raw snapshots and SHA-256 hashes. Resolve the official NY Fed API code from the time-series-list endpoint for the applicable reporting regime; do not splice regime segments without an explicit mapping.
- **Intended model use:** Collateral sourcing, matched-book activity, and secured-funding-flow proxy.
- **Known limitations:** Aggregate primary-dealer data; no dealer identities, no FICC-member mapping, structural breaks across reporting regimes, and no direct CCP liquidity obligation. Does not identify centrally cleared versus uncleared financing at participant level.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### FR2004_TSY_FAILS_TO_RECEIVE â€” FR 2004F; U.S. Treasury securities cumulative weekly fails to receive

- **Official source:** FR 2004 Primary Dealer Statistics
- **Official source URL:** https://www.newyorkfed.org/markets/pridealers_failsprimer.html
- **Machine-access URL:** https://markets.newyorkfed.org/api/pd/list/timeseries.csv
- **Definition:** Cumulative weekly total obtained by summing each business day's outstanding Treasury fails to receive for the primary-dealer community.
- **Unit:** USD millions, cumulative weekly total
- **Frequency:** Weekly
- **Publication calendar:** Weekly; Thursday approximately 4:15 p.m. ET, reporting the previous week's statistics.
- **Available history:** July 1990 to present for Treasury fails, subject to historical reporting changes.
- **Revision policy:** Retain immutable raw snapshots and SHA-256 hashes. Resolve the official NY Fed API code from the time-series-list endpoint for the applicable reporting regime; do not splice regime segments without an explicit mapping.
- **Intended model use:** Settlement-friction stress indicator and historical scenario trigger for liquidity calls and delayed incoming securities.
- **Known limitations:** Primary-dealer aggregate only; cumulative weekly flow-like measure is not a point-in-time exposure and should not be summed again.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### FR2004_TSY_FAILS_TO_DELIVER â€” FR 2004F; U.S. Treasury securities cumulative weekly fails to deliver

- **Official source:** FR 2004 Primary Dealer Statistics
- **Official source URL:** https://www.newyorkfed.org/markets/pridealers_failsprimer.html
- **Machine-access URL:** https://markets.newyorkfed.org/api/pd/list/timeseries.csv
- **Definition:** Cumulative weekly total obtained by summing each business day's outstanding Treasury fails to deliver for the primary-dealer community.
- **Unit:** USD millions, cumulative weekly total
- **Frequency:** Weekly
- **Publication calendar:** Weekly; Thursday approximately 4:15 p.m. ET, reporting the previous week's statistics.
- **Available history:** July 1990 to present for Treasury fails, subject to historical reporting changes.
- **Revision policy:** Retain immutable raw snapshots and SHA-256 hashes. Resolve the official NY Fed API code from the time-series-list endpoint for the applicable reporting regime; do not splice regime segments without an explicit mapping.
- **Intended model use:** Settlement-friction stress indicator and historical scenario trigger for outgoing-delivery disruption and liquidity substitution.
- **Known limitations:** Primary-dealer aggregate only; cumulative weekly flow-like measure is not a point-in-time exposure and should not be summed again.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### SOFR_RATE â€” SOFR / API field percentRate

- **Official source:** New York Fed SOFR
- **Official source URL:** https://www.newyorkfed.org/markets/reference-rates/sofr
- **Machine-access URL:** https://markets.newyorkfed.org/api/rates/secured/sofr/search.json
- **Definition:** Volume-weighted median rate for eligible overnight Treasury repo transactions.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Business daily at approximately 8:00 a.m. ET for the prior business day's transactions.
- **Available history:** 2018-04-02 value date to present; first published 2018-04-03.
- **Revision policy:** Capture the first publication and any approximately 2:30 p.m. ET same-day revision. Rate revision is expected only when the change exceeds one basis point; prior-day revisions are exceptional.
- **Intended model use:** Base secured-funding rate, liquidity-cost benchmark, and starting point for repo-rate stress shocks.
- **Known limitations:** Broad Treasury-repo benchmark including tri-party, GCF Repo, and filtered FICC DVP bilateral activity; not FICC-only, not participant-specific, and subject to contingency methodology.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### SOFR_P01 â€” SOFR / API field percentile1

- **Official source:** New York Fed SOFR
- **Official source URL:** https://www.newyorkfed.org/markets/reference-rates/sofr
- **Machine-access URL:** https://markets.newyorkfed.org/api/rates/secured/sofr/search.json
- **Definition:** 1st volume-weighted percentile of eligible overnight Treasury repo transaction rates.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Business daily at approximately 8:00 a.m. ET for the prior business day's transactions.
- **Available history:** 2018-04-02 value date to present; first published 2018-04-03.
- **Revision policy:** Capture the first publication and any approximately 2:30 p.m. ET same-day revision. Rate revision is expected only when the change exceeds one basis point; prior-day revisions are exceptional.
- **Intended model use:** Distribution-shape and tail-spread input used to calibrate funding-rate dispersion and stressed haircuts.
- **Known limitations:** Broad Treasury-repo benchmark including tri-party, GCF Repo, and filtered FICC DVP bilateral activity; not FICC-only, not participant-specific, and subject to contingency methodology. Percentiles may be unavailable when contingency data are used.
- **Null policy:** Allow source-declared missing percentile values only when the NY Fed indicates contingency publication; otherwise reject.
- **Value classification:** `observed`
- **Required:** `true`

### SOFR_P25 â€” SOFR / API field percentile25

- **Official source:** New York Fed SOFR
- **Official source URL:** https://www.newyorkfed.org/markets/reference-rates/sofr
- **Machine-access URL:** https://markets.newyorkfed.org/api/rates/secured/sofr/search.json
- **Definition:** 25th volume-weighted percentile of eligible overnight Treasury repo transaction rates.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Business daily at approximately 8:00 a.m. ET for the prior business day's transactions.
- **Available history:** 2018-04-02 value date to present; first published 2018-04-03.
- **Revision policy:** Capture the first publication and any approximately 2:30 p.m. ET same-day revision. Rate revision is expected only when the change exceeds one basis point; prior-day revisions are exceptional.
- **Intended model use:** Distribution-shape and tail-spread input used to calibrate funding-rate dispersion and stressed haircuts.
- **Known limitations:** Broad Treasury-repo benchmark including tri-party, GCF Repo, and filtered FICC DVP bilateral activity; not FICC-only, not participant-specific, and subject to contingency methodology. Percentiles may be unavailable when contingency data are used.
- **Null policy:** Allow source-declared missing percentile values only when the NY Fed indicates contingency publication; otherwise reject.
- **Value classification:** `observed`
- **Required:** `true`

### SOFR_P75 â€” SOFR / API field percentile75

- **Official source:** New York Fed SOFR
- **Official source URL:** https://www.newyorkfed.org/markets/reference-rates/sofr
- **Machine-access URL:** https://markets.newyorkfed.org/api/rates/secured/sofr/search.json
- **Definition:** 75th volume-weighted percentile of eligible overnight Treasury repo transaction rates.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Business daily at approximately 8:00 a.m. ET for the prior business day's transactions.
- **Available history:** 2018-04-02 value date to present; first published 2018-04-03.
- **Revision policy:** Capture the first publication and any approximately 2:30 p.m. ET same-day revision. Rate revision is expected only when the change exceeds one basis point; prior-day revisions are exceptional.
- **Intended model use:** Distribution-shape and tail-spread input used to calibrate funding-rate dispersion and stressed haircuts.
- **Known limitations:** Broad Treasury-repo benchmark including tri-party, GCF Repo, and filtered FICC DVP bilateral activity; not FICC-only, not participant-specific, and subject to contingency methodology. Percentiles may be unavailable when contingency data are used.
- **Null policy:** Allow source-declared missing percentile values only when the NY Fed indicates contingency publication; otherwise reject.
- **Value classification:** `observed`
- **Required:** `true`

### SOFR_P99 â€” SOFR / API field percentile99

- **Official source:** New York Fed SOFR
- **Official source URL:** https://www.newyorkfed.org/markets/reference-rates/sofr
- **Machine-access URL:** https://markets.newyorkfed.org/api/rates/secured/sofr/search.json
- **Definition:** 99th volume-weighted percentile of eligible overnight Treasury repo transaction rates.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Business daily at approximately 8:00 a.m. ET for the prior business day's transactions.
- **Available history:** 2018-04-02 value date to present; first published 2018-04-03.
- **Revision policy:** Capture the first publication and any approximately 2:30 p.m. ET same-day revision. Rate revision is expected only when the change exceeds one basis point; prior-day revisions are exceptional.
- **Intended model use:** Distribution-shape and tail-spread input used to calibrate funding-rate dispersion and stressed haircuts.
- **Known limitations:** Broad Treasury-repo benchmark including tri-party, GCF Repo, and filtered FICC DVP bilateral activity; not FICC-only, not participant-specific, and subject to contingency methodology. Percentiles may be unavailable when contingency data are used.
- **Null policy:** Allow source-declared missing percentile values only when the NY Fed indicates contingency publication; otherwise reject.
- **Value classification:** `observed`
- **Required:** `true`

### SOFR_VOLUME â€” SOFR / API field volumeInBillions

- **Official source:** New York Fed SOFR
- **Official source URL:** https://www.newyorkfed.org/markets/reference-rates/sofr
- **Machine-access URL:** https://markets.newyorkfed.org/api/rates/secured/sofr/search.json
- **Definition:** Total eligible overnight transaction volume used in the SOFR calculation, rounded to the nearest USD billion.
- **Unit:** USD billions
- **Frequency:** Business daily
- **Publication calendar:** Business daily at approximately 8:00 a.m. ET for the prior business day's transactions.
- **Available history:** 2018-04-02 value date to present; first published 2018-04-03.
- **Revision policy:** Capture the first publication and any approximately 2:30 p.m. ET same-day revision. Rate revision is expected only when the change exceeds one basis point; prior-day revisions are exceptional.
- **Intended model use:** Market-depth state variable and scaling input for stressed liquidation and funding-capacity scenarios.
- **Known limitations:** Broad Treasury-repo benchmark including tri-party, GCF Repo, and filtered FICC DVP bilateral activity; not FICC-only, not participant-specific, and subject to contingency methodology. Volume is rounded and may be unavailable under contingency publication.
- **Null policy:** Allow source-declared missing volume only during documented contingency publication; otherwise reject.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS1MO â€” DGS1MO

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS1MO
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS1MO
- **Definition:** Market yield on U.S. Treasury securities at 1-month constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 2001-07-31 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 1-month liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS3MO â€” DGS3MO

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS3MO
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS3MO
- **Definition:** Market yield on U.S. Treasury securities at 3-month constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1981-09-01 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 3-month liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS6MO â€” DGS6MO

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS6MO
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS6MO
- **Definition:** Market yield on U.S. Treasury securities at 6-month constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1981-09-01 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 6-month liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS1 â€” DGS1

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS1
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS1
- **Definition:** Market yield on U.S. Treasury securities at 1-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1962-01-02 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 1-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS2 â€” DGS2

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS2
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS2
- **Definition:** Market yield on U.S. Treasury securities at 2-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1976-06-01 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 2-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS3 â€” DGS3

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS3
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS3
- **Definition:** Market yield on U.S. Treasury securities at 3-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1962-01-02 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 3-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS5 â€” DGS5

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS5
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS5
- **Definition:** Market yield on U.S. Treasury securities at 5-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1962-01-02 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 5-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS7 â€” DGS7

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS7
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS7
- **Definition:** Market yield on U.S. Treasury securities at 7-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1969-07-01 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 7-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS10 â€” DGS10

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS10
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS10
- **Definition:** Market yield on U.S. Treasury securities at 10-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1962-01-02 to present
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 10-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS20 â€” DGS20

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS20
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS20
- **Definition:** Market yield on U.S. Treasury securities at 20-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1962-01-02 to present, with historical discontinuity/gaps
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 20-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H15_DGS30 â€” DGS30

- **Official source:** Federal Reserve H.15 Selected Interest Rates
- **Official source URL:** https://fred.stlouisfed.org/series/DGS30
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS30
- **Definition:** Market yield on U.S. Treasury securities at 30-year constant maturity, quoted on an investment basis.
- **Unit:** Percent per annum
- **Frequency:** Business daily
- **Publication calendar:** Daily Monday-Friday at 4:15 p.m. ET; no release on holidays or Board-closure days.
- **Available history:** 1977-02-15 to present, with historical discontinuity/gaps
- **Revision policy:** Preserve retrieval date and source vintage. Revisions or corrections must create a new raw-data version; do not overwrite a vintage used in a completed model run.
- **Intended model use:** Treasury curve node for discounting, parallel/nonparallel yield shocks, and 30-year liquidation-value stress.
- **Known limitations:** Nominal constant-maturity yield is an interpolated par yield based on Treasury market inputs; it is not an executable transaction rate. Missing dates must follow the official business calendar.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H41_WRBWFRBL â€” WRBWFRBL

- **Official source:** Federal Reserve H.4.1 Factors Affecting Reserve Balances
- **Official source URL:** https://fred.stlouisfed.org/series/WRBWFRBL
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=WRBWFRBL
- **Definition:** Reserve balances with Federal Reserve Banks: Wednesday level.
- **Unit:** USD millions, not seasonally adjusted
- **Frequency:** Weekly, as of Wednesday
- **Publication calendar:** Weekly each Thursday, generally 4:30 p.m. ET; may shift to the next business day for a federal holiday.
- **Available history:** 2002-12-18 to present for the selected current-format series.
- **Revision policy:** Retain immutable weekly vintages. Monitor H.4.1 announcements for corrections, reclassifications, facility additions/removals, and table-definition changes.
- **Intended model use:** Reserve-availability state variable and systemwide liquidity-regime indicator.
- **Known limitations:** Systemwide Federal Reserve balance-sheet aggregate; weekly and not FICC-specific. Accounting classifications and extraordinary facilities may create structural breaks.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H41_WRESBAL â€” WRESBAL

- **Official source:** Federal Reserve H.4.1 Factors Affecting Reserve Balances
- **Official source URL:** https://fred.stlouisfed.org/series/WRESBAL
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=WRESBAL
- **Definition:** Reserve balances with Federal Reserve Banks: week average.
- **Unit:** USD millions, not seasonally adjusted
- **Frequency:** Weekly, as of Wednesday
- **Publication calendar:** Weekly each Thursday, generally 4:30 p.m. ET; may shift to the next business day for a federal holiday.
- **Available history:** 2002-12-18 to present for the selected current-format series.
- **Revision policy:** Retain immutable weekly vintages. Monitor H.4.1 announcements for corrections, reclassifications, facility additions/removals, and table-definition changes.
- **Intended model use:** Smoothed reserve-availability state variable for weekly alignment and regime classification.
- **Known limitations:** Systemwide Federal Reserve balance-sheet aggregate; weekly and not FICC-specific. Accounting classifications and extraordinary facilities may create structural breaks.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H41_WALCL â€” WALCL

- **Official source:** Federal Reserve H.4.1 Factors Affecting Reserve Balances
- **Official source URL:** https://fred.stlouisfed.org/series/WALCL
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=WALCL
- **Definition:** Total assets of the Federal Reserve, less eliminations from consolidation: Wednesday level.
- **Unit:** USD millions, not seasonally adjusted
- **Frequency:** Weekly, as of Wednesday
- **Publication calendar:** Weekly each Thursday, generally 4:30 p.m. ET; may shift to the next business day for a federal holiday.
- **Available history:** 2002-12-18 to present for the selected current-format series.
- **Revision policy:** Retain immutable weekly vintages. Monitor H.4.1 announcements for corrections, reclassifications, facility additions/removals, and table-definition changes.
- **Intended model use:** Federal Reserve balance-sheet size and broad liquidity-condition indicator.
- **Known limitations:** Systemwide Federal Reserve balance-sheet aggregate; weekly and not FICC-specific. Accounting classifications and extraordinary facilities may create structural breaks.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H41_TREAST â€” TREAST

- **Official source:** Federal Reserve H.4.1 Factors Affecting Reserve Balances
- **Official source URL:** https://fred.stlouisfed.org/series/TREAST
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=TREAST
- **Definition:** U.S. Treasury securities held outright by the Federal Reserve: Wednesday level.
- **Unit:** USD millions, not seasonally adjusted
- **Frequency:** Weekly, as of Wednesday
- **Publication calendar:** Weekly each Thursday, generally 4:30 p.m. ET; may shift to the next business day for a federal holiday.
- **Available history:** 2002-12-18 to present for the selected current-format series.
- **Revision policy:** Retain immutable weekly vintages. Monitor H.4.1 announcements for corrections, reclassifications, facility additions/removals, and table-definition changes.
- **Intended model use:** SOMA Treasury-holdings state variable for market-float and liquidity-regime scenarios.
- **Known limitations:** Systemwide Federal Reserve balance-sheet aggregate; weekly and not FICC-specific. Accounting classifications and extraordinary facilities may create structural breaks.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H41_WLRRAL â€” WLRRAL

- **Official source:** Federal Reserve H.4.1 Factors Affecting Reserve Balances
- **Official source URL:** https://fred.stlouisfed.org/series/WLRRAL
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=WLRRAL
- **Definition:** Federal Reserve reverse repurchase agreement liabilities: Wednesday level.
- **Unit:** USD millions, not seasonally adjusted
- **Frequency:** Weekly, as of Wednesday
- **Publication calendar:** Weekly each Thursday, generally 4:30 p.m. ET; may shift to the next business day for a federal holiday.
- **Available history:** 2002-12-18 to present for the selected current-format series.
- **Revision policy:** Retain immutable weekly vintages. Monitor H.4.1 announcements for corrections, reclassifications, facility additions/removals, and table-definition changes.
- **Intended model use:** Reserve-drain and money-market-liquidity state variable.
- **Known limitations:** Systemwide Federal Reserve balance-sheet aggregate; weekly and not FICC-specific. Accounting classifications and extraordinary facilities may create structural breaks.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H41_WDTGAL â€” WDTGAL

- **Official source:** Federal Reserve H.4.1 Factors Affecting Reserve Balances
- **Official source URL:** https://fred.stlouisfed.org/series/WDTGAL
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=WDTGAL
- **Definition:** U.S. Treasury General Account deposits at Federal Reserve Banks: Wednesday level.
- **Unit:** USD millions, not seasonally adjusted
- **Frequency:** Weekly, as of Wednesday
- **Publication calendar:** Weekly each Thursday, generally 4:30 p.m. ET; may shift to the next business day for a federal holiday.
- **Available history:** 2002-12-18 to present for the selected current-format series.
- **Revision policy:** Retain immutable weekly vintages. Monitor H.4.1 announcements for corrections, reclassifications, facility additions/removals, and table-definition changes.
- **Intended model use:** Treasury cash-balance drain on reserve liquidity and short-horizon system-liquidity scenario input.
- **Known limitations:** Systemwide Federal Reserve balance-sheet aggregate; weekly and not FICC-specific. Accounting classifications and extraordinary facilities may create structural breaks.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

### H41_WORAL â€” WORAL

- **Official source:** Federal Reserve H.4.1 Factors Affecting Reserve Balances
- **Official source URL:** https://fred.stlouisfed.org/series/WORAL
- **Machine-access URL:** https://fred.stlouisfed.org/graph/fredgraph.csv?id=WORAL
- **Definition:** Federal Reserve repurchase agreement assets: Wednesday level.
- **Unit:** USD millions, not seasonally adjusted
- **Frequency:** Weekly, as of Wednesday
- **Publication calendar:** Weekly each Thursday, generally 4:30 p.m. ET; may shift to the next business day for a federal holiday.
- **Available history:** 2002-12-18 to present for the selected current-format series.
- **Revision policy:** Retain immutable weekly vintages. Monitor H.4.1 announcements for corrections, reclassifications, facility additions/removals, and table-definition changes.
- **Intended model use:** Temporary reserve-supply and secured-market-support state variable.
- **Known limitations:** Systemwide Federal Reserve balance-sheet aggregate; weekly and not FICC-specific. Accounting classifications and extraordinary facilities may create structural breaks.
- **Null policy:** Reject unexpected nulls after source-calendar alignment.
- **Value classification:** `observed`
- **Required:** `true`

## Cross-source alignment rules

1. Store observation date, publication date, and retrieval timestamp as separate fields.
2. Align daily series to a project calendar without treating weekends or official holidays as missing-data defects.
3. Aggregate daily series to weekly frequency only with a documented rule and retain the unaggregated source data.
4. Do not directly splice FR 2004 reporting regimes; use a versioned mapping and structural-break indicator.
5. Retain original units. Unit conversions belong in a derived-data layer with explicit lineage.
6. Preserve revised and unrevised vintages when a model run used an earlier publication.

## Model-risk limitations

The catalog contains public aggregate data. It cannot reconstruct FICC member portfolios, participant-specific settlement obligations, committed liquidity facilities, intraday payment timing, or proprietary default-management information. Member-level and transaction-level inputs required by the stress model must therefore be clearly labeled synthetic or assumed and must never be presented as observed Federal Reserve data.

## Deliverable linkage

- Machine-readable source configuration: `configs/data_sources.yaml`
- Human-readable catalog: `docs/federal_reserve_data_catalog.md`
- Flat contract manifest: `data/manifests/data_source_contract.csv`
