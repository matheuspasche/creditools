# creditools 0.3.0

* Implemented `stage_filter` to dynamically inject categorical SQL-like dropouts inside simulation funnels.
* Developed `find_risk_groups()` heuristic: A robust N-Score RBP matrix clusterer with Volatility check (SD/Mean) and Vintage parsers out-of-the-box.
* Added `find_pairwise_risk_groups()`, a high-level wrapper scaling Matrix combinatorics for multiple challenger scores smoothly via `furrr/purrr`.
* Integrated standard `cli` Progress Bars into `run_simulation` and grouping wraps to handle heavy workloads (>1.5M rows) interactively.
* Extensive TDD Suite built for Matrix Volume Pruning and Non-Crossing overlap routines.

# creditools 0.2.1
# creditools 0.2.0

* Implemented `stress_custom(func)` to allow arbitrary closure behavior over simulation engine.
* Enhanced `run_tradeoff_analysis` to dynamically intercept `<stage>_base_rate` from params grid.
* Massive showcase >1.5M applicants with `future` parallel logic built natively in `README.Rmd`.
* Structural cleaning and reduction of repository unused/non-CRAN files.

# creditools 0.1.0

* Initial development version.
* Added functions for credit policy simulation, trade-off analysis, and optimization.
* Added a vignette demonstrating the trade-off analysis workflow.
* Set up package structure for CRAN submission.
