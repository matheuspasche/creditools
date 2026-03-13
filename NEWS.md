# creditools 0.5.1: "Tidyselect Refactor & Efficient Frontier"

*   **Efficient Frontier Wrapper**:
    - Introduced `calculate_efficient_frontier()`, a high-level wrapper that automates the process of finding optimal cutoffs and extracting the Pareto frontier in a single step.
*   **Tidyselect Standardization**:
    - Core functions (`find_risk_groups`, `screen_risk_segments`, `calculate_ks_table`) now consistently support `tidyselect` syntax for column selection.
    - `credit_policy()` implements a hybrid resolution logic, supporting both unquoted symbols and variable names.
*   **Documentation Polish**:
    - Standardized all package documentation, vignettes, and messages to English.
    - Improved README layout and formatting (moving Installation to the top, using `kbl()` for tables).
    - Added a professional hexagonal logo.
    - Resolved LaTeX syntax errors in PDF manual generation.
*   **Robustness**:
    - Enhanced validation for `credit_policy` arguments with clear error messages.
    - Improved handling of optional columns in simulation and grouping engines.

# creditools 0.5.0: "High-Performance Release"

*   **Temporal Stability Engine**:
    - High-performance longitudinal clustering kernels in C++ (Ward and IV-based).
*   **Recipe-Based Predict API**: 
    - Full serialization support for clustering models. `find_risk_groups` and `screen_risk_segments` now return "recipes" (quantile boundaries and mappings).
    - Introduced `predict()` S3 methods for `credit_risk_groups` and `credit_risk_screening` classes, enabling model-like application on OOT data.
*   **High-Scale Segment Screening**:
    - `screen_risk_segments()` handling thousands of candidate variables with memory-safe parallel batching.
    - Tier-wise metrics (Information Value, PD Spread) calculated at the C++ level for maximum speed.
*   **Production Readiness**:
    - Robust matrix completion logic to handle unseen score/decile combinations in OOT data.
    - Unified parallel processing framework via `utils-parallel.R`.

# creditools 0.4.2

*   **Tidyverse Best Practices**: Comprehensive standardization of selection (`select()`, `rename()`) and data-masking contexts across the package, resolving `tidyselect` deprecation warnings.
*   **Simulation Logic**: Refined `simulate_swap_in_defaults()` to default to a neutral stress (1.0x multiplier) instead of `NA` when no stress scenarios are defined.
*   **Documentation Assets**: Unblocked PNG files in `.gitignore` and `.Rbuildignore` to ensure README and vignette plots render correctly on GitHub.
*   **Performance Optimization**: Identified that parallelizing the inner clustering loop of `find_risk_groups` was counterproductive due to overhead; reverted that specific loop to sequential while maintaining parallelism for higher-level operations.

# creditools 0.4.1

*   **Analytical Precision**: Fixed `Bad_Rate` calculation for swap-out populations in both `summarize_results()` and `simulate_from_data()`. It now correctly reports historical observed PD instead of zeroing out.
*   **English Standardization**: Standardized the entire package to English. This includes all documentation, error messages, and unit test examples (e.g., translated `idade` to `age` and `Válido` to `Valid`).
*   **CRAN Compliance & Encoding**: 
    - Replaced all non-ASCII characters with CRAN-compliant ASCII or Unicode escapes.
    - Fixed duplicate vignette titles and missing YAML delimiters in `multi-stage-funnel.Rmd` and `case-study-used-vehicles.Rmd`.
    - Improved `stage_filter()` error handling with descriptive, standardized English messages.
*   **Release Automation**: Introduced `dev/release_audit.R`, a comprehensive auditor script to verify documentation, unit tests, character encoding, and full `R CMD check` compliance before release.

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

# creditools 0.2.0

*   **Trade-off Analysis**: Introduced `run_tradeoff_analysis()` for large-scale policy parameter search.
*   **S3 Interface**: Refactored `credit_policy` as a formal S3 class with validation.

# creditools 0.1.0

*   Initial release focus on basic PD simulation.
