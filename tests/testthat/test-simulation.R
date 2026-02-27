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
  policy <- get_test_policy(simulation_stages = list(stage_cutoff("test", list(score1=700))))

  expect_true(validate_simulation_inputs(sample_data, policy))
  
  # Fail if policy is wrong
  expect_error(validate_simulation_inputs(sample_data, list()), "must be a")
  
  # Fail if policy has no stages
  expect_error(validate_simulation_inputs(sample_data, get_test_policy()), "no defined simulation stages")
})

test_that("simulate_stage.stage_cutoff works with single and multiple scores", {
  policy <- get_test_policy()
  
  # Single cutoff
  stage1 <- stage_cutoff("s1", cutoffs = list(score1 = 700))
  res1 <- simulate_stage(sample_data, stage1, policy)
  expect_equal(res1, c(1, 0, 0, 1, 1))
  
  # Multiple cutoffs (AND logic)
  stage2 <- stage_cutoff("s2", cutoffs = list(score1 = 700, score2 = 750))
  res2 <- simulate_stage(sample_data, stage2, policy)
  expect_equal(res2, c(1, 0, 0, 0, 1))
})

test_that("classify_scenarios identifies all four scenarios", {
  policy <- get_test_policy()
  
  data <- sample_data
  data$new_approval <- c(1, 0, 1, 0, 1) # Manually set new approvals
  # old approved: 1, 1, 0, 0, 1
  # new approved: 1, 0, 1, 0, 1
  # expected: keep_in, swap_out, swap_in, keep_out, keep_in
  
  result <- creditools:::classify_scenarios(data, policy, "new_approval")
  expect_equal(result$scenario, c("keep_in", "swap_out", "swap_in", "keep_out", "keep_in"))
})
