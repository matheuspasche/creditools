test_that("simulation works correctly", {
  # Generate sample data
  data <- generate_sample_data(n_samples = 1000, seed = 123)

  # Create config
  config <- create_config(
    score_columns = c("score_1", "score_2"),
    simulation_stages = list(
      list(name = "credit", type = "threshold"),
      list(name = "anti_fraud", type = "random_removal", approval_rate = 0.9)
    )
  )

  # Run simulation
  results <- simulate_credit_process(data, config, parallel = FALSE, show_progress = FALSE)

  # Check results structure
  expect_s3_class(results, "credit_sim_results")
  expect_true(all(c("approval_score_1", "approval_score_2") %in% names(results$data)))
  expect_true(all(c("scenario_score_1", "scenario_score_2") %in% names(results$data)))
})

test_that("scenario classification works correctly", {
  test_data <- tibble::tibble(
    current_approval = c(0, 1, 1, 0),
    final_approval = c(1, 0, 1, 0)
  )

  result <- classify_scenarios(test_data, "current_approval", "final_approval", "scenario")
  expect_equal(result$scenario, c("swap_in", "swap_out", "keep_in", "keep_out"))
})
