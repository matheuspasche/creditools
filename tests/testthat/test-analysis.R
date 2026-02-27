library(testthat)

# Test the new, flexible run_tradeoff_analysis function
test_that("run_tradeoff_analysis works with a grid of multiple parameters", {
  
  # 1. Setup
  set.seed(42)
  test_data <- generate_sample_data(n_applicants = 1000)
  test_data$new_score_decile <- dplyr::ntile(test_data$new_score, 10)

  # Define a base policy with a fixed stage
  base_policy <- credit_policy(
    applicant_id_col = "id",
    score_cols = c("old_score", "new_score"),
    current_approval_col = "approved",
    actual_default_col = "defaulted",
    risk_level_col = "new_score_decile",
    simulation_stages = list(
      stage_rate(name = "anti_fraud", base_rate = 0.9) # A fixed stage
    ),
    stress_scenarios = list() # Stress will be added dynamically
  )

  # Define parameters to vary. This should result in 2x2=4 simulations.
  vary_params <- list(
    new_score_cutoff = c(500, 600),
    aggravation_factor = c(1.2, 1.5)
  )

  # 2. Execution
  results <- run_tradeoff_analysis(
    data = test_data,
    base_policy = base_policy,
    vary_params = vary_params,
    parallel = FALSE # Ensure tests run sequentially
  )

  # 3. Validation
  expect_true(tibble::is_tibble(results))
  expect_equal(nrow(results), 4)
  
  # Check for expected columns
  expected_cols <- c("new_score_cutoff", "aggravation_factor", "approval_rate", "default_rate")
  expect_true(all(expected_cols %in% names(results)))

  # Check that results are plausible
  expect_true(all(results$approval_rate >= 0 & results$approval_rate <= 1))
  expect_true(all(results$default_rate >= 0 & results$default_rate <= 1))
  
  # Check that the parameters were varied correctly
  expect_equal(sort(unique(results$new_score_cutoff)), c(500, 600))
  expect_equal(sort(unique(results$aggravation_factor)), c(1.2, 1.5))
})
