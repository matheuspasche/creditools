library(creditools)
library(tictoc)
library(future)

# Generate a large dataset for a meaningful test
cat("Generating 1,000,000 rows of test data...\n")
data(applicants)
# Expand applicants to 1M rows
large_data <- do.call(rbind, replicate(50, applicants, simplify = FALSE))
large_data$id <- seq_len(nrow(large_data))

cat(sprintf("Dataset size: %d rows.\n", nrow(large_data)))

# 1. Sequential Benchmark
cat("\n--- Running Sequential find_risk_groups ---\n")
tic("Sequential")
res_seq <- find_risk_groups(
    data = large_data,
    score_cols = c("old_score", "new_score"),
    default_col = "defaulted",
    time_col = "vintage",
    parallel = FALSE,
    quiet = TRUE
)
t_seq <- toc()

# 2. Parallel Benchmark (8 Workers)
cat("\n--- Running Parallel find_risk_groups (8 Workers) ---\n")
# Ensure any existing plan is cleared
future::plan(future::sequential)

tic("Parallel (8 workers)")
res_par <- find_risk_groups(
    data = large_data,
    score_cols = c("old_score", "new_score"),
    default_col = "defaulted",
    time_col = "vintage",
    parallel = TRUE,
    n_workers = 8,
    quiet = TRUE
)
t_par <- toc()

# Summary
cat("\n--- Performance Summary ---\n")
cat(sprintf("Sequential Time: %.2f seconds\n", t_seq$toc - t_seq$tic))
cat(sprintf("Parallel Time:   %.2f seconds\n", t_par$toc - t_par$tic))
cat(sprintf("Speedup:         %.2fx\n", (t_seq$toc - t_seq$tic) / (t_par$toc - t_par$tic)))

# Verification
cat("\nVerifying consistency of results... ")
if (identical(res_seq$report, res_par$report)) {
    cat("MATCH\n")
} else {
    cat("MISMATCH (check data mapping)\n")
}
