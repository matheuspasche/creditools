test_that("generate_sample_data produces correct output", {
  data <- generate_sample_data(n_samples = 1000, seed = 123)

  # Check structure
  expect_equal(nrow(data), 1000)
  expect_true(all(c("score_1", "score_2", "observed_default", "risk_level") %in% names(data)))

  # Check score ranges
  expect_true(all(data$score_1 >= 300 & data$score_1 <= 850))
  expect_true(all(data$score_2 >= 300 & data$score_2 <= 850))

  # Check risk levels
  expect_true(all(data$risk_level %in% c("Low_Risk", "Medium_Risk", "High_Risk")))

  # Check default rates by decile
  decile_stats <- calculate_decile_stats(data, "score_1")
  expect_true(all(decile_stats$default_rate >= 0 & decile_stats$default_rate <= 1))
})

test_that("decile calculation works correctly", {
  data <- generate_sample_data(n_samples = 1000, seed = 123)
  decile_stats <- calculate_decile_stats(data, "score_1")

  expect_equal(nrow(decile_stats), 10)
  expect_true(all(decile_stats$decile == 1:10))
  expect_true(all(decile_stats$min_score <= decile_stats$max_score))
})
