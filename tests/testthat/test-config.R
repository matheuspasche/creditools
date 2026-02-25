# Tests for the credit_policy object and its constructor

test_that("credit_policy constructor works with valid inputs", {
  policy <- credit_policy(
    applicant_id_col = "ID",
    score_cols = "score_v1",
    current_approval_col = "approved",
    actual_default_col = "defaulted"
  )
  
  expect_s3_class(policy, "credit_policy")
  expect_equal(policy$applicant_id_col, "ID")
  expect_equal(policy$score_cols, "score_v1")
})

test_that("credit_policy fails with missing required arguments", {
  expect_error(
    credit_policy(score_cols = "s", current_approval_col = "a", actual_default_col = "d"),
    "applicant_id_col.*must be a single string"
  )
  expect_error(
    credit_policy(applicant_id_col = "id", current_approval_col = "a", actual_default_col = "d"),
    "score_cols.*must be a character vector"
  )
})

test_that("credit_policy fails with invalid argument types", {
  expect_error(
    credit_policy(
      applicant_id_col = 123,
      score_cols = "score_v1",
      current_approval_col = "approved",
      actual_default_col = "defaulted"
    ),
    "applicant_id_col.*must be a single string"
  )
  
  expect_error(
    credit_policy(
      applicant_id_col = "ID",
      score_cols = list("score_v1"),
      current_approval_col = "approved",
      actual_default_col = "defaulted"
    ),
    regexp = "score_cols.*must be a character vector"
  )
})

test_that("validate_credit_policy catches invalid objects", {
  # We test the internal validator by creating an invalid object manually
  bad_policy <- new_credit_policy(applicant_id_col = "ID")
  bad_policy$score_cols <- NULL # Manually create an invalid state
  
  expect_error(
    validate_credit_policy(bad_policy),
    "Policy field.*score_cols.*is missing or empty"
  )
  
  not_a_policy <- list(applicant_id_col = "ID")
  expect_error(
    validate_credit_policy(not_a_policy),
    "Input must be of class" # Adjusted to match cli output
  )
})

test_that("print method for credit_policy returns invisibly", {
  policy <- credit_policy(
    applicant_id_col = "ID",
    score_cols = c("s1", "s2"),
    current_approval_col = "a",
    actual_default_col = "d"
  )
  
  # The print method should return the object invisibly
  expect_invisible(print(policy))
})

