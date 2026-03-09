library(devtools)
load_all(".")
library(tictoc)
library(dplyr)

# Setup Data
data(applicants)
# Scale up significantly to trigger parallel efficiency
# Using 500 bins for a dense matrix
big_data <- lapply(1:20, function(i) applicants) %>% bind_rows()
big_data$id <- seq_len(nrow(big_data))

message("\n--- Integrity & Performance Test: find_risk_groups ---")

# 1. Baseline: Sequential
message("Running Sequential baseline...")
tic()
res_seq <- find_risk_groups(
    data = big_data,
    score_cols = "new_score",
    default_col = "defaulted",
    time_col = "vintage",
    bins = 200, # Dense grid to test loop efficiency
    max_groups = 5,
    parallel = FALSE,
    quiet = TRUE
)
t_seq <- toc()

# 2. Optimized: Parallel
message("Running Parallel optimization...")
# Use 2 workers for safety in test environment
library(future)
plan(multisession, workers = 2)

tic()
res_par <- find_risk_groups(
    data = big_data,
    score_cols = "new_score",
    default_col = "defaulted",
    time_col = "vintage",
    bins = 200,
    max_groups = 5,
    parallel = TRUE,
    quiet = TRUE
)
t_par <- toc()
plan(sequential)

# 3. Validation
message("\n--- Results Comparison ---")
identical_report <- all.equal(res_seq$report, res_par$report)
message("Reports match exactly: ", isTRUE(identical_report))

if (!isTRUE(identical_report)) {
    message("Warning: Reports differ!")
    print(all.equal(res_seq$report, res_par$report))
}

# Check mapping counts
n_mappings_seq <- nrow(res_seq$mapping)
n_mappings_par <- nrow(res_par$mapping)
message("Mapping size match: ", n_mappings_seq == n_mappings_par)

# Performance calculation
speedup <- (t_seq$toc - t_seq$tic) / (t_par$toc - t_par$tic)
message(sprintf("Speedup Factor: %.2fx", speedup))
