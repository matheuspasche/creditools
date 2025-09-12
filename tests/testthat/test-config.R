test_that("create_config validates inputs correctly", {
  # Valid configuration
  expect_silent(create_config(c("score_1", "score_2")))

  # Invalid score_columns
  expect_error(create_config(NULL), "must be a non-empty character vector")
  expect_error(create_config(character(0)), "must be a non-empty character vector")

  # Invalid simulation_stages
  expect_error(create_config("score_1", simulation_stages = list()), "must be a non-empty list")
})

test_that("config validation works correctly", {
  config <- create_config(c("score_1", "score_2"))
  expect_true(validate_config(config))

  # Test invalid config
  invalid_config <- structure(list(), class = "credit_sim_config")
  expect_error(validate_config(invalid_config), "must be created with create_config")
})
