# Tests for the sample data generation function

test_that("generate_sample_data produces correct output dimensions and types", {
  n_app <- 100
  
  data <- generate_sample_data(n_applicants = n_app, seed = 1)
  
  expect_s3_class(data, "tbl_df")
  expect_equal(nrow(data), n_app)
  
  # Check for expected columns
  expected_cols <- c("id", "old_score", "new_score", "defaulted", "approved", "hired")
  expect_true(all(expected_cols %in% names(data)))
  
  # Check types
  expect_type(data$id, "integer")
  expect_type(data$old_score, "double")
  expect_type(data$new_score, "double")
  expect_type(data$approved, "integer")
  expect_type(data$defaulted, "integer")
  expect_type(data$hired, "integer")
})

test_that("generate_sample_data is reproducible with a seed", {
  data1 <- generate_sample_data(n_applicants = 50, seed = 42)
  data2 <- generate_sample_data(n_applicants = 50, seed = 42)
  
  expect_equal(data1, data2)
})

test_that("generate_sample_data approximates the target rates", {
  n_app <- 50000
  app_rate <- 0.7
  def_rate <- 0.1
  tolerance <- 0.03
  
  data <- generate_sample_data(
    n_applicants = n_app,
    base_approval_rate = app_rate,
    base_default_rate = def_rate,
    seed = 42
  )
  
  # Check approval rate is close to the target
  actual_app_rate <- mean(data$approved)
  expect_lt(abs(actual_app_rate - app_rate), tolerance)
  
  # Check overall default rate is close to the target
  actual_def_rate <- mean(data$defaulted, na.rm = TRUE)
  expect_lt(abs(actual_def_rate - def_rate), tolerance)
})
