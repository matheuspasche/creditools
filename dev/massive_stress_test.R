library(creditools)
library(tictoc)
library(dplyr)
library(future)

# 1. Generate 5 Million Rows
cli::cli_h1("Generating 5 Million Rows Stress Test")
# We'll replicate the 20k rows dataset 250 times
data(applicants)
cli::cli_alert_info("Starting data replication...")
massive_data <- applicants %>%
    slice(rep(row_number(), 250)) %>%
    mutate(id = row_number())

cli::cli_alert_success("Data generated: {nrow(massive_data)} rows.")
print(object.size(massive_data), units = "Mb")

# 2. Setup Policy and Scenarios
policy <- credit_policy(
    applicant_id_col = "id",
    score_cols = "new_score",
    current_approval_col = "approved",
    actual_default_col = "defaulted"
)

# We'll use a stress scenario to make swap-in defaults calculation heavy
policy$stress_scenarios <- list(
    high_stress = stress_aggravation(factor = 1.5, by = "new_score")
)

vary <- list(new_score_cutoff = c(500, 600)) # 2 simulations

cli::cli_h1("Benchmark: Sequential vs Parallel (2 workers)")
cli::cli_alert_info("Task: Run 2 tradeoff simulations on 5M rows.")

# Sequential
cli::cli_h2("Running Sequential...")
tic("Sequential")
res_seq <- run_tradeoff_analysis(massive_data, policy, vary, parallel = FALSE, quiet = TRUE)
toc()

# Parallel
cli::cli_h2("Running Parallel (2 workers)...")
# Note: n_workers = 2 to stay safe in the environment
tic("Parallel")
res_par <- run_tradeoff_analysis(massive_data, policy, vary, parallel = TRUE, n_workers = 2, quiet = TRUE)
toc()

cli::cli_h1("Stress Test Summary")
cli::cli_alert_info("Memory usage for 5M rows is significant. Parallelism helps with wall-clock time at the cost of memory overhead per worker.")
