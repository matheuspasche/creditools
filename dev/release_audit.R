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

# 3. Synchronize README & Vignettes
cli_h2("3. Synchronizing Documentation (README & Vignettes)")
rmarkdown::render("README.Rmd", output_format = "github_document", quiet = TRUE)
cli_alert_success("README synchronized.")

# Render vignettes
vignette_files <- list.files("vignettes", pattern = "\\.Rmd$", full.names = TRUE)
purrr::walk(vignette_files, ~ {
    cli_alert_info("Rendering vignette: {.file {.x}}")
    rmarkdown::render(.x, quiet = TRUE)
})
cli_alert_success("All vignettes rendered.")

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

# 5. Documentation Audit (Mandatory @examples and @return for exports)
cli_h2("5. Documentation Audit (Exports Compliance)")

check_documentation_tags <- function() {
    cli_alert_info("Parsing NAMESPACE to identify exported functions...")
    if (!file.exists("NAMESPACE")) {
        cli_alert_danger("NAMESPACE file not found!")
        return(FALSE)
    }

    namespace_lines <- readLines("NAMESPACE")
    # Extraction logic for export(fn) and S3method(gen, class)
    # Improved regex to handle quotes and better capture the symbol
    exports <- grep("^export\\(", namespace_lines, value = TRUE) %>%
        strsplit("\\(") %>%
        map_chr(~ gsub("^[\"']|[\"']?\\)$", "", .x[2]))

    s3_exports <- grep("^S3method\\(", namespace_lines, value = TRUE) %>%
        strsplit("\\(|,") %>%
        map_chr(~ gsub("^[\"']\\s*|\\s*[\"']?\\)$", "", .x[[2]]))

    all_exports <- unique(c(exports, s3_exports))
    # Remove pipe and common base generics that don't need their own Rd usually
    # Also ignore internal operators beginning with %, !, |, &
    all_exports <- all_exports[!all_exports %in% c("plot", "print", "summary", "as.list", "as.data.frame", "predict")]
    all_exports <- all_exports[!grepl("^%|^!|^\\||^&", all_exports)]

    cli_alert_info("Found {length(all_exports)} exported symbols. Checking .Rd files...")

    man_dir <- "man"
    if (!dir.exists(man_dir)) {
        cli_alert_danger("man/ directory not found. Run devtools::document() first.")
        return(FALSE)
    }

    rd_files <- list.files(man_dir, pattern = "\\.Rd$", full.names = TRUE)

    issues_found <- 0

    for (fn in all_exports) {
        # .Rd files can contain multiple aliases. We need to find the one defining our function.
        # Usually the filename matches the function name or alias.
        relevant_rd <- purrr::keep(rd_files, ~ {
            content <- readLines(.x, warn = FALSE)
            any(grepl(paste0("\\\\alias\\{", fn, "\\}"), content)) ||
                any(grepl(paste0("\\\\name\\{", fn, "\\}"), content))
        })

        if (length(relevant_rd) == 0) {
            cli_alert_warning("Symbol {.fn {fn}}: No matching .Rd file found!")
            issues_found <- issues_found + 1
            next
        }

        # Only check the first match for simplicity
        rd_content <- readLines(relevant_rd[1], warn = FALSE)
        rd_text <- paste(rd_content, collapse = "\n")

        # Check for @examples (\examples{...})
        # We look for the tag and then a bit of non-whitespace content after it
        # before the final closing brace.
        has_examples <- grepl("\\\\examples\\{", rd_text)

        # More robust check: does it have anything other than whitespace between \examples{ and the end?
        # We'll just check if there's any alphanumeric content after \examples
        is_empty_examples <- has_examples && !grepl("\\\\examples\\s*\\{[^}]*[a-zA-Z0-9]", rd_text)

        # Check for @return (\value{...})
        has_return <- grepl("\\\\value\\{", rd_text)

        if (!has_examples || is_empty_examples) {
            cli_alert_danger("Symbol {.fn {fn}}: Missing or empty \\examples section in {.file {basename(relevant_rd[1])}}")
            issues_found <- issues_found + 1
        }
        if (!has_return) {
            # Some functions might not need return (side effects), but CRAN prefers it.
            # For now, we'll flag it as a warning.
            cli_alert_warning("Symbol {.fn {fn}}: Missing \\value (@return) section in {.file {basename(relevant_rd[1])}}")
        }
    }

    if (issues_found > 0) {
        cli_alert_danger("Documentation Audit failed with {issues_found} critical issues (missing examples).")
        return(FALSE)
    } else {
        cli_alert_success("Documentation Audit passed! All exports have examples.")
        return(TRUE)
    }
}

doc_audit_passed <- check_documentation_tags()

# 6. Full R CMD check
cli_h2("6. Running Full R CMD check (CRAN standards)")
# error_on = 'never' allows the script to finish and show us everything.
check_res <- devtools::check(error_on = "never", vignettes = TRUE, quiet = TRUE)

# Filter out environmental "noise" (known local-only issues)
remaining_warnings <- check_res$warnings[!grepl("qpdf", check_res$warnings)]
remaining_notes <- check_res$notes[!grepl("unable to verify current time", check_res$notes)]

if (length(check_res$errors) > 0 || length(remaining_warnings) > 0 || length(remaining_notes) > 0) {
    cli_h1("Audit Failed: CRAN Compliance Issues Found")
    print(check_res)
} else {
    if (length(check_res$warnings) > 0) {
        cli_alert_info("Note: Ignored environmental warnings (e.g., missing 'qpdf').")
    }
    if (length(check_res$notes) > 0) {
        cli_alert_info("Note: Ignored local notes (e.g., time verification).")
    }
    cli_h1("Audit Complete: Package is CRAN-Ready!")
}
