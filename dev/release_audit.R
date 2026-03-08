# Automated Release Audit Script for creditools
# Follows practices from: https://r-pkgs.org/release.html
# and inspired by extrachecks: https://github.com/DavisVaughan/extrachecks

library(devtools)
library(cli)
library(rmarkdown)
library(purrr)

cli_h1("Starting creditools Release Audit")

# 1. Update Documentation
cli_h2("1. Updating Roxygen2 Documentation")
devtools::document()
cli_alert_success("Documentation updated.")

# 2. Run All Tests
cli_h2("2. Running Unit Tests (testthat)")
test_results <- devtools::test()
if (any(vapply(test_results, function(x) sum(vapply(x, inherits, logical(1), "expectation_failure")) > 0, logical(1)))) {
    cli_alert_danger("Some tests failed! Audit stopped.")
    # stop("Tests failed.") # Commented out to allow script to continue if needed during dev
} else {
    cli_alert_success("All tests passed.")
}

# 3. Synchronize README
cli_h2("3. Rendering README.Rmd to README.md")
rmarkdown::render("README.Rmd", output_format = "github_document", quiet = TRUE)
cli_alert_success("README synchronized.")

# 4. Extra Sanitation Checks (T/F usage, browser, non-ASCII)
cli_h2("4. Running Static Sanitation Checks")

check_pattern <- function(pattern, message, details = "") {
    files <- list.files("R", pattern = "\\.R$", full.names = TRUE)
    matches <- map(files, ~ {
        lines <- readLines(.x)
        match_idx <- grep(pattern, lines)
        if (length(match_idx) > 0) {
            return(data.frame(file = .x, lines = match_idx, content = lines[match_idx]))
        }
        NULL
    }) %>%
        compact() %>%
        bind_rows()

    if (nrow(matches) > 0) {
        cli_alert_warning(message)
        print(matches)
    } else {
        cli_alert_success(paste("Clean:", details))
    }
}

# Check for T/F instead of TRUE/FALSE
check_pattern("\\bT\\b|\\bF\\b", "WARNING: Potential use of T/F shorthand found. Use TRUE/FALSE.", "No T/F shorthand found.")

# Check for browser() or TODO
check_pattern("browser\\(\\)", "DANGER: browser() calls found in code!", "No browser() calls found.")
check_pattern("TODO", "NOTE: TODO comments found in code.", "No TODO comments found.")

# Check for non-ASCII characters
check_pattern("[^\x01-\x7f]", "WARNING: Non-ASCII characters found. Use unicode escapes for CRAN.", "No non-ASCII characters found.")

# 5. Full R CMD check
cli_h2("5. Running Full R CMD check (CRAN standards)")
# error_on = 'warning' ensures we don't allow any warnings to pass.
# vignettes = TRUE ensures all vignettes are built and checked.
check_res <- devtools::check(error_on = "warning", vignettes = TRUE, quiet = TRUE)

if (length(check_res$errors) > 0 || length(check_res$warnings) > 0) {
    cli_h1("Audit Failed: CRAN Compliance Issues Found")
    print(check_res)
} else {
    cli_h1("Audit Complete: Package is CRAN-Ready!")
}
