library(creditools)
library(future)
library(dplyr)
library(tictoc)

# 1. Setup Data
message("Generating sample data for benchmark...")
data(applicants)
# Scale up for more significant benchmark
large_data <- lapply(1:10, function(i) applicants) %>% bind_rows()
large_data$id <- seq_len(nrow(large_data))

# 2. Define Policy
base_policy <- credit_policy(
    applicant_id_col = "id",
    score_cols = "new_score",
    current_approval_col = "approved",
    actual_default_col = "defaulted"
)

# 3. Benchmark run_tradeoff_analysis (Stochastic)
vary_params <- list(
    new_score_cutoff = seq(400, 700, length.out = 10),
    aggravation_factor = c(1.1, 1.3, 1.5)
)

message("\n--- Testing run_tradeoff_analysis (Stochastic) ---")
message("n_simulations: ", prod(lengths(vary_params)))

# A. Sequential
message("Sequential run...")
tic()
res_seq <- run_tradeoff_analysis(large_data, base_policy, vary_params, parallel = FALSE, quiet = TRUE)
toc()

# B. Parallel
message("Parallel run (multisession)...")
plan(multisession, workers = parallel::detectCores() - 1)
tic()
res_par <- run_tradeoff_analysis(large_data, base_policy, vary_params, parallel = TRUE, quiet = TRUE)
toc()
plan(sequential)

# 4. Benchmark find_optimal_cutoffs (Stochastic)
message("\n--- Testing find_optimal_cutoffs (Stochastic) ---")

# A. Sequential
message("Sequential run...")
tic()
opt_seq <- find_optimal_cutoffs(
    large_data, base_policy,
    cutoff_steps = 10,
    parallel = FALSE,
    method = "stochastic"
)
toc()

# B. Parallel
message("Parallel run...")
tic()
opt_par <- find_optimal_cutoffs(
    large_data, base_policy,
    cutoff_steps = 10,
    parallel = TRUE,
    method = "stochastic"
)
toc()

# 5. Benchmark Analytical (Optimization)
# Currently analytical optimization is sequential only in the codebase.
# I will test the current sequential performance as baseline.
message("\n--- Testing find_optimal_cutoffs (Analytical, Current: Sequential) ---")
tic()
opt_analytical <- find_optimal_cutoffs(
    large_data, base_policy,
    cutoff_steps = 50, # Much higher density for analytical
    parallel = FALSE,
    method = "analytical"
)
toc()
