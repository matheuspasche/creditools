# creditools 0.4.0

*   **Built-in Data**: Introduced `applicants` dataset (20,000 records) for professional examples and vignettes.
*   **Documentation**: Massive overhaul of all exported and internal functions to ensure 100% '@return' and '@examples' coverage.
*   **CRAN Compliance**: 
    - Fixed `.onAttach` startup messages to be suppressible by `packageStartupMessage()`.
    - Removed all global state modifications (`options()`) in favor of internal package environments.
    - Simplified library requirements in vignettes for better portability across CRAN workers.
    - Audited all URLs to ensure `https://` protocol compliance.
*   **Performance**: Optimized `run_simulation` logic to handle datasets with 5M+ rows efficiently.
*   **UX**: New high-level wrapper `simulate_from_data()` for one-line analysis.
*   **Analytics**: `stress_aggravation()` now supports dynamic factor columns.

# creditools 0.3.0

## New Algorithm: Ward Agglomerative Clustering in `find_risk_groups()`

* **Breaking change:** Parameter `max_volatility_cv` (and its interim alias `max_overlap_rate`) 
  replaced by `max_crossings` — an integer count of the maximum number of vintage periods where 
  adjacent risk groups may invert their PD ordering. This is more robust than a proportion-based 
  threshold when working with small vintage windows (6–18 months), which is the common case in 
  credit analysis.

* **New algorithm:** `find_risk_groups()` now uses **Ward Agglomerative Clustering** instead of
  sequential heuristics. The merge cost is the Ward Distance:
  `delta = (Va * Vb) / (Va + Vb) * (PDa - PDb)^2`
  This guarantees maximum inter-group separation while enforcing a strict hierarchy of constraints:
  1. Monotonicity (PD must increase with group index — no inversions)
  2. Minimum volume per group (`min_vol_ratio`)
  3. Maximum PD crossings over time (`max_crossings`)
  4. Tail compression (`max_groups`, optional)

* Removed `time_col_format` parameter — `time_col` must now be a proper `Date` or `POSIXt` column.
  This eliminates ambiguous parsing and simplifies the interface.

## Other Improvements

* Fixed `New names: ...1` warnings in `run_tradeoff_analysis()`, `simulate_swap_in_defaults()`, 
  and `evaluate_cutoff_combinations()` by using `as_tibble_row()`, `!!col_name :=` assignment,
  and `.name_repair = "unique_quiet"` respectively.

* Updated documentation and `README.md` to reflect the new Ward algorithm, constraint hierarchy,
  and best practices (train on approved population, not full applicant base).

---

# creditools 0.2.1 / 0.2.0

* Implemented `stress_custom(func)` to allow arbitrary closure behavior over simulation engine.
* Enhanced `run_tradeoff_analysis` to dynamically intercept `<stage>_base_rate` from params grid.
* Massive showcase >1.5M applicants with `future` parallel logic built natively in `README.Rmd`.
* Structural cleaning and reduction of repository unused/non-CRAN files.

---

# creditools 0.1.0

* Initial development version.
* Added functions for credit policy simulation, trade-off analysis, and optimization.
* Added a vignette demonstrating the trade-off analysis workflow.
* Set up package structure for CRAN submission.
