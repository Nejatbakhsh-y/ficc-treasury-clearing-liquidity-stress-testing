# Section 10 — Historical Stress-Window Identification

## Objective

Select historical liquidity-stress windows from observable Federal Reserve and
Treasury-market data. The procedure does not automatically include named crisis
periods. Candidate episodes are used only as labels when objectively selected
windows overlap their date ranges.

## Stress channels

1. **SOFR spikes:** positive daily rate changes and positive robust deviations
   from a rolling median.
2. **Treasury yield shocks:** the largest absolute daily yield change across
   available maturities, expressed in basis points where necessary.
3. **Settlement-fail increases:** positive changes and elevated rolling levels
   of aggregate settlement fails.
4. **Financing-volume disruptions:** large absolute log changes, with explicit
   sensitivity to contractions.
5. **Reserve-balance contractions:** negative log changes in reserve balances.

Each channel is converted to a full-sample empirical percentile. The combined
indicator is a weighted average over available channels. It is calculated only
when the configured minimum number of channels is present.

## Window selection

Daily observations at or above the configured combined-score tail quantile are
clustered when separated by no more than the configured gap. Each cluster is
expanded by pre-window and post-window buffers. Windows are ranked by peak and
mean combined stress and capped at the configured maximum.

## Controls

- Controlled YAML parameters and explicit optional series mappings.
- SHA-256 lineage for processed analytical inputs and controlled outputs.
- No imputation of unavailable stress channels.
- Candidate historical episodes are not forced into the result.
- Unit tests cover bounded component scores, minimum-component enforcement,
  empirical shock detection, and non-forced anchor treatment.
- CSV, YAML, and text evidence are reproducibly generated from one CLI.
