## R CMD check results

0 errors | 1 warning | 1 note

* Checking for future file timestamps ... NOTE
  unable to verify current time
  
  This note is common in some transient environments and does not reflect a package issue.

* checking for size reduction of PDFs ... WARNING
  'qpdf' is needed for checks on size reduction of PDFs
  
  This warning is environmental (missing 'qpdf' tool locally) and does not indicate a problem with the package vignettes themselves.

## Test coverage

57 tests passed (100% of defined tests).

## Reverse dependencies

There are currently no reverse dependencies for this package.

## Compliance and Policy Fixes

*   **Startup Messages**: Replaced `cli` alerts in `.onAttach` with standard `packageStartupMessage()` to ensure they are correctly suppressed by `suppressPackageStartupMessages()`, resolving a previous CRAN note.
*   **Global State**: Removed all usage of `options()` for internal control, switching to a package-level environment to prevent side effects.
*   **Resource Usage**: Standardized vignette examples to use the new built-in `applicants` dataset (20,000 records). This ensures consistent, reproducible results while maintaining efficient build times on CRAN worker environments.
*   **Portability**: Cleaned up non-standard top-level directories and residual build artifacts.
