test_that("visualization functions work correctly", {
  # Create test data
  tradeoff_data <- tibble::tibble(
    score = rep(c("score_1", "score_2"), each = 5),
    cutoff = rep(seq(600, 680, by = 20), 2),
    approval_rate = rep(seq(0.9, 0.5, by = -0.1), 2),
    default_rate = rep(seq(0.01, 0.05, by = 0.01), 2)
  )

  # Test visualization functions
  expect_s3_class(visualize_tradeoffs(tradeoff_data), "ggplot")
  expect_s3_class(visualize_cutoff_default(tradeoff_data), "ggplot")
  expect_s3_class(visualize_cutoff_approval(tradeoff_data), "ggplot")

  # Test with specific score
  expect_s3_class(visualize_tradeoffs(tradeoff_data, "score_1"), "ggplot")
})
