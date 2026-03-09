library(creditools)
library(tictoc)
library(future)

# 20k rows, 10 challengers
cat("Generating 20,000 rows, 10 challengers...\n")
data(applicants)
test_data <- applicants[rep(seq_len(nrow(applicants)), length.out = 20000), ]
challenger_scores <- paste0("ch_", 1:10)
for (ch in challenger_scores) {
    test_data[[ch]] <- test_data$new_score + rnorm(nrow(test_data), 0, 50)
}

# 1. Sequential
cat("\n--- Running Sequential find_pairwise_risk_groups (10 tasks) ---\n")
tic("Sequential")
res_seq <- find_pairwise_risk_groups(
    data = test_data,
    primary_score = "old_score",
    challenger_scores = challenger_scores,
    default_col = "defaulted",
    time_col = "vintage",
    parallel = FALSE,
    quiet = F
)
t_seq <- toc()

# 2. Parallel (8 workers)
cat("\n--- Running Parallel find_pairwise_risk_groups (8 workers, 10 tasks) ---\n")
future::plan(future::sequential)
tic("Parallel (8 workers)")
res_par <- find_pairwise_risk_groups(
    data = test_data,
    primary_score = "old_score",
    challenger_scores = challenger_scores,
    default_col = "defaulted",
    time_col = "vintage",
    parallel = TRUE,
    n_workers = 8,
    quiet = F
)
t_par <- toc()

# Summary
cat("\n--- Pairwise Performance Summary ---\n")
cat(sprintf("Sequential Time: %.2f seconds\n", t_seq$toc - t_seq$tic))
cat(sprintf("Parallel Time:   %.2f seconds\n", t_par$toc - t_par$tic))
cat(sprintf("Speedup:         %.2fx\n", (t_seq$toc - t_seq$tic) / (t_par$toc - t_par$tic)))
