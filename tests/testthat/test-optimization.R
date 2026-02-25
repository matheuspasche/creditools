# Test for the optimization functions

# This test file will cover the `find_optimal_cutoffs` function and its related
# helpers to ensure that the optimization process is working as expected.

# The tests will cover the following scenarios:
# 1. The function returns a valid result with a simple configuration.
# 2. The function respects the constraints on default and approval rates.
# 3. The function works correctly with parallel processing.
# 4. The function handles cases where no solution meets the constraints.

# The test will use a small sample dataset to keep the execution time low.

test_that("find_optimal_cutoffs returns a valid result", {
  # Create a sample dataset
  sample_data <- tibble::tibble(
    applicant_id = 1:100,
    score = round(runif(100, 500, 800)),
    current_approval = rbinom(100, 1, 0.7),
    actual_default = rbinom(100, 1, 0.1)
  )

  # Create a base credit policy
  base_policy <- credit_policy(
    applicant_id_col = "applicant_id",
    score_cols = "score",
    current_approval_col = "current_approval",
    actual_default_col = "actual_default"
  )

  # Run the optimization
  optimal_results <- find_optimal_cutoffs(
    data = sample_data,
    config = base_policy,
    cutoff_steps = 5,
    target_default_rate = 0.15,
    min_approval_rate = 0.5
  )

  # Check that the result is a data frame
  expect_s3_class(optimal_results, "credit_opt_results")
  expect_s3_class(optimal_results, "data.frame")

  # Check that the result has the expected columns
  expect_named(optimal_results, c("combination_id", "overall_approval_rate", "overall_default_rate", "constraints_met", "tradeoff_score", "score"))

  # Check that the evaluation results are attached
  expect_true(!is.null(attr(optimal_results, "evaluation_results")))
})
