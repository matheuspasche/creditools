## R CMD check results

0 errors | 0 warnings | 1 note

* Checking for future file timestamps ... NOTE
  unable to verify current time
  
  This note is common in some transient environments and does not reflect a package issue.

## Test coverage

65 tests passed (100% of defined tests).

## Reverse dependencies

There are currently no reverse dependencies for this package.

## Compliance and Policy Fixes

*   **Tidyverse Best Practices**: Standardized all calls to `select()`, `rename()`, and `pivot_*()` to use string literals or `all_of()`, future-proofing the package against `tidyselect` deprecation warnings.
*   **Robust Simulation**: Refined `simulate_swap_in_defaults()` to avoid returning `NA` values. It now defaults to a neutral stress (1.0x multiplier) based on historical baselines when no scenarios are defined.
*   **Startup Messages**: Standardized `.onAttach` messages to respect `suppressPackageStartupMessages()`.
*   **Global State**: Removed all usage of `options()` for internal control, switching to a package-level environment to prevent side effects.
