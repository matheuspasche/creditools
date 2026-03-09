# Verify all vignettes in both sequential and parallel modes
library(creditools)
library(rmarkdown)
library(future)

vignette_files <- list.files("vignettes", pattern = "\\.Rmd$", full.names = TRUE)

results <- data.frame(
    vignette = basename(vignette_files),
    seq_status = "PENDING",
    par_status = "PENDING",
    stringsAsFactors = FALSE
)

cat("--- Starting Vignette Validation Sweep ---\n")

for (i in seq_along(vignette_files)) {
    v_file <- vignette_files[i]
    v_name <- basename(v_file)
    cat(sprintf("\nProcessing %s...\n", v_name))

    # 1. Sequential Mode
    cat("  - Testing Sequential Mode... ")
    tryCatch(
        {
            # We manually set the plan to sequential to be sure
            future::plan(future::sequential)
            # We render to a temp file
            render(v_file, output_file = tempfile(fileext = ".html"), quiet = TRUE)
            results$seq_status[i] <- "PASS"
            cat("PASS\n")
        },
        error = function(e) {
            results$seq_status[i] <- paste("FAIL:", e$message)
            cat("FAIL\n")
        }
    )

    # 2. Parallel Mode
    cat("  - Testing Parallel Mode (multisession)... ")
    tryCatch(
        {
            # We set a global plan to test if vignettes respect it
            # Some vignettes might explicitly pass parallel=TRUE, others might just inherited the plan
            future::plan(future::multisession, workers = 2)
            render(v_file, output_file = tempfile(fileext = ".html"), quiet = TRUE)
            results$par_status[i] <- "PASS"
            cat("PASS\n")
        },
        error = function(e) {
            results$par_status[i] <- paste("FAIL:", e$message)
            cat("FAIL\n")
        },
        finally = {
            future::plan(future::sequential)
        }
    )
}

cat("\n--- Final Results ---\n")
print(results)

if (any(grepl("FAIL", c(results$seq_status, results$par_status)))) {
    stop("One or more vignettes failed validation.")
} else {
    cat("\nAll vignettes passed validation in both modes.\n")
}
