library(testthat)
library(creditools)

test_that("Tidyselect works across core functions", {
  library(dplyr)
  set.seed(42)
  df <- generate_sample_data(n_applicants = 1000)
  
  # 1. find_risk_groups with unquoted names
  res_rg <- find_risk_groups(
    data = df,
    score_cols = new_score,
    default_col = defaulted,
    quiet = TRUE
  )
  expect_s3_class(res_rg, "credit_risk_groups")
  expect_true("risk_rating" %in% names(res_rg$data))
  
  # 2. find_risk_groups with helpers
  res_rg_helper <- find_risk_groups(
    data = df,
    score_cols = starts_with("new_"),
    default_col = defaulted,
    quiet = TRUE
  )
  expect_equal(res_rg_helper$metadata$score_cols, "new_score")

  # 3. screen_risk_segments with unquoted and helpers
  df_with_rating <- res_rg$data
  res_screen <- screen_risk_segments(
    data = df_with_rating,
    base_risk_col = risk_rating,
    candidate_cols = c(old_score, starts_with("new_")),
    default_col = defaulted
  )
  expect_true("old_score" %in% unique(res_screen$metrics$variable))
  expect_true("new_score" %in% unique(res_screen$metrics$variable))

  # 4. credit_policy with unquoted names
  pol <- credit_policy(
    applicant_id_col = id,
    score_cols = c(old_score, new_score),
    current_approval_col = approved,
    actual_default_col = defaulted
  )
  expect_equal(pol$applicant_id_col, "id")
  expect_equal(pol$score_cols, c("old_score", "new_score"))

  # 5. summarize_results with unquoted 'by'
  sim_res <- run_simulation(df, pol, quiet = TRUE)
  sum_res <- summarize_results(sim_res, by = age)
  expect_true("age" %in% names(sum_res))

  # 6. simulate_from_data with unquoted names
  sim_data_res <- simulate_from_data(
    data = df,
    applicant_id_col = id,
    current_score_col = old_score,
    new_score_col = new_score,
    historical_approval_col = approved,
    historical_hired_col = hired,
    actual_default_col = defaulted,
    new_score_cutoff = 600
  )
  expect_s3_class(sim_data_res, "creditools_simulation_from_data")
  
  # 7. calculate_ks_table with unquoted names
  ks_tab <- calculate_ks_table(df, score_col = new_score, default_col = defaulted)
  expect_true("ks_metric" %in% names(attributes(ks_tab)))
})
