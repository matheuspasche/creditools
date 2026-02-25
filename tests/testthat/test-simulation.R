# Tests for the new simulation pipeline

# Helper function to create a sample policy for tests
get_test_policy <- function(...) {
  credit_policy(
    applicant_id_col = "id",
    score_cols = c("score1", "score2"),
    current_approval_col = "approved",
    actual_default_col = "defaulted",
    risk_level_col = "risk",
    ...
  )
}

# Sample data for testing
sample_data <- tibble::tribble(
  ~id, ~score1, ~score2, ~approved, ~defaulted, ~risk,
  1,   800,     750,     1,         0,          "low",
  2,   650,     700,     1,         1,          "med",
  3,   550,     600,     0,         NA,         "high",
  4,   700,     500,     0,         NA,         "med",
  5,   720,     800,     1,         0,          "low"
)

test_that("validate_simulation_inputs works correctly", {
  policy <- get_test_policy()
  cutoffs <- list(score1 = 700)
  
  expect_true(validate_simulation_inputs(sample_data, policy, cutoffs))
  
  # Fail if policy is wrong
  expect_error(validate_simulation_inputs(sample_data, list(), cutoffs), "must be a")
  
  # Fail if data is missing columns
  bad_data <- sample_data[, -1]
  expect_error(validate_simulation_inputs(bad_data, policy, cutoffs), "missing")
  
  # Fail if cutoffs are bad
  expect_error(validate_simulation_inputs(sample_data, policy, list()), "at least one")
  expect_error(validate_simulation_inputs(sample_data, policy, list(score3 = 100)), "not defined")
})

test_that("apply_cutoffs works with single and multiple scores", {
  # Single cutoff
  data1 <- apply_cutoffs(sample_data, list(score1 = 700))
  expect_equal(data1$new_approval, c(1, 0, 0, 1, 1))
  
  # Multiple cutoffs (AND logic)
  data2 <- apply_cutoffs(sample_data, list(score1 = 700, score2 = 750))
  expect_equal(data2$new_approval, c(1, 0, 0, 0, 1))
})

test_that("classify_scenarios identifies all four scenarios", {
  policy <- get_test_policy()
  
  data <- sample_data
  data$new_approval <- c(1, 0, 1, 0, 1) # Manually set new approvals
  # old approved: 1, 1, 0, 0, 1
  # new approved: 1, 0, 1, 0, 1
  # expected: keep_in, swap_out, swap_in, keep_out, keep_in
  
  result <- classify_scenarios(data, policy)
  expect_equal(result$scenario, c("keep_in", "swap_out", "swap_in", "keep_out", "keep_in"))
})
