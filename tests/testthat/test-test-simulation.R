test_that("simulation works correctly", {
  # Generate sample data
  data <- generate_sample_data(1000)

  # Create config
  config <- create_config(
    score_columns = c("score_1", "score_2"),
    simulation_stages = list(
      list(name = "credit", type = "threshold"),
      list(name = "anti_fraud", type = "random_removal", approval_rate = 0.9)
    )
  )

  # Run simulation
  results <- simulate_credit_process(data, config)

  # Check results structure
  expect_s3_class(results, "credit_sim_results")
  expect_true(all(c("approval_score_1", "approval_score_2") %in% names(results$data)))
  expect_true(all(c("scenario_score_1", "scenario_score_2") %in% names(results$data)))
})

test_that("optimization works correctly", {
  # Generate sample data
  data <- generate_sample_data(1000)

  # Create config
  config <- create_config(
    score_columns = c("score_1"),
    simulation_stages = list(
      list(name = "credit", type = "threshold")
    )
  )

  # Run optimization
  optimal <- find_optimal_cutoffs(
    data, config,
    cutoff_steps = 5,
    target_default_rate = 0.1,
    min_approval_rate = 0.3
  )

  # Check results structure
  expect_s3_class(optimal, "credit_opt_results")
  expect_true("cutoff_score_1" %in% names(optimal))
})
