test_that("tradeoff analysis works correctly", {
  # Generate sample data
  data <- generate_sample_data(n_samples = 1000, seed = 123)

  # Create config
  config <- create_config(
    score_columns = c("score_1"),
    simulation_stages = list(
      list(name = "credit", type = "threshold")
    )
  )

  # Run tradeoff analysis
  tradeoff_results <- analyze_tradeoffs(
    data, config,
    cutoffs_range = c(600, 800),
    n_points = 5,
    parallel = FALSE,
    show_progress = FALSE
  )

  # Check results structure
  expect_true(all(c("cutoff", "approval_rate", "default_rate", "score") %in% names(tradeoff_results)))
  expect_equal(unique(tradeoff_results$score), "score_1")
  expect_equal(nrow(tradeoff_results), 5)
})

test_that("optimal cutoff finding works correctly", {
  # Create test data
  tradeoff_data <- tibble::tibble(
    score = rep("score_1", 10),
    cutoff = seq(600, 780, by = 20),
    approval_rate = seq(0.9, 0.1, by = -0.1),
    default_rate = seq(0.01, 0.1, by = 0.01)
  )

  # Test different optimization criteria
  min_default <- find_optimal_cutoffs(tradeoff_data, "min_default")
  expect_equal(min_default, c(score_1 = 600))

  max_approval <- find_optimal_cutoffs(tradeoff_data, "max_approval")
  expect_equal(max_approval, c(score_1 = 600))
})
