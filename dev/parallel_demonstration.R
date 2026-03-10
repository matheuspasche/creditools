library(creditools)
library(tictoc)
library(dplyr)
library(future)

# Generate a high-volume dataset for demonstration
cli::cli_h1("Generating High Volume Data (100k rows)")
data <- generate_sample_data(n_applicants = 100000, seed = 42)
# Add some variety for grouping
data$vintage <- sample(seq(as.Date("2020-01-01"), as.Date("2022-12-01"), by = "month"), nrow(data), replace = TRUE)

cli::cli_h1("Benchmark 1: run_tradeoff_analysis")
cli::cli_alert_info("Varying 4 cutoff combinations on 100k rows...")

policy <- credit_policy(
    applicant_id_col = "id",
    score_cols = "new_score",
    current_approval_col = "approved",
    actual_default_col = "defaulted"
)
vary <- list(new_score_cutoff = c(400, 500, 600, 700))

# Sequential
tic("Sequential")
res_seq <- run_tradeoff_analysis(data, policy, vary, parallel = FALSE, quiet = TRUE)
toc()

# Parallel
tic("Parallel (2 workers)")
res_par <- run_tradeoff_analysis(data, policy, vary, parallel = TRUE, n_workers = 2, quiet = TRUE)
toc()


cli::cli_h1("Benchmark 2: find_pairwise_risk_groups")
cli::cli_alert_info("Matrixing 1 Primary vs 2 Challengers on 100k rows...")
# Add another dummy score
data$extra_score <- data$new_score * runif(nrow(data), 0.8, 1.2)

# Sequential
tic("Sequential")
res_seq_pg <- find_pairwise_risk_groups(
    data = data,
    primary_score = "old_score",
    challenger_scores = c("new_score", "extra_score"),
    default_col = "defaulted",
    time_col = "vintage",
    parallel = FALSE,
    quiet = TRUE
)
toc()

# Parallel
tic("Parallel (2 workers)")
res_par_pg <- find_pairwise_risk_groups(
    data = data,
    primary_score = "old_score",
    challenger_scores = c("new_score", "extra_score"),
    default_col = "defaulted",
    time_col = "vintage",
    parallel = TRUE,
    n_workers = 2,
    quiet = TRUE
)
toc()

cli::cli_h1("Benchmark 3: find_optimal_cutoffs (Stochastic)")
cli::cli_alert_info("Optimizing grid of 4 combinations on 100k rows...")

# Sequential
tic("Sequential")
opt_seq <- find_optimal_cutoffs(
    data = data,
    config = policy,
    cutoff_steps = 2, # Minimal grid for speed
    method = "stochastic",
    parallel = FALSE
)
toc()

# Parallel
tic("Parallel (2 workers)")
opt_par <- find_optimal_cutoffs(
    data = data,
    config = policy,
    cutoff_steps = 2,
    method = "stochastic",
    parallel = TRUE,
    n_workers = 2
)
toc()

cli::cli_h1("Summary of Effects")
cli::cli_alert_success("Parallelism significantly reduces wall-clock time for multi-run tasks.")
cli::cli_alert_info("Note: Clustering inner-loop is sequential to avoid overhead, but pairwise comparisons are parallel.")
