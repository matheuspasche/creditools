test_that("screen_risk_segments works with different methods", {
    data(applicants)
    # Create a base grouping first
    base_model <- find_risk_groups(applicants, "old_score", "defaulted", max_groups = 5, quiet = TRUE)
    applicants$rating <- base_model$data$risk_rating

    # 1. Test Quantiles (Default)
    res_q <- screen_risk_segments(
        data = applicants,
        base_risk_col = "rating",
        candidate_cols = c(new_score, bureau_derogatory),
        default_col = "defaulted",
        n_bins = 5,
        method = "quantiles"
    )
    expect_s3_class(res_q, "credit_risk_screening")
    expect_true(all(c("variable", "risk_group", "iv", "pd_spread") %in% names(res_q$metrics)))
    expect_equal(unique(res_q$metrics$variable), c("new_score", "bureau_derogatory"))

    # 2. Test Ward
    res_w <- screen_risk_segments(
        data = applicants,
        base_risk_col = "rating",
        candidate_cols = c(new_score),
        default_col = "defaulted",
        n_bins = 10,
        method = "ward",
        max_groups = 2,
        min_vol_ratio = 0.05
    )
    expect_s3_class(res_w, "credit_risk_screening")
    expect_true(all(res_w$metrics$risk_group %in% 1:5))

    # 3. Test IV
    res_iv <- screen_risk_segments(
        data = applicants,
        base_risk_col = "rating",
        candidate_cols = c(new_score),
        default_col = "defaulted",
        n_bins = 10,
        method = "iv",
        max_groups = 2
    )
    expect_s3_class(res_iv, "credit_risk_screening")
})

test_that("screen_risk_segments handles tidyselect and parallel batches", {
    data(applicants)
    base_model <- find_risk_groups(applicants, "old_score", "defaulted", max_groups = 3, quiet = TRUE)
    applicants$rating <- base_model$data$risk_rating

    # Test batching logic (batch_size = 100 default, we have few vars here)
    res <- screen_risk_segments(
        data = applicants,
        base_risk_col = "rating",
        candidate_cols = starts_with("new_"),
        default_col = "defaulted",
        parallel = FALSE
    )
    expect_equal(unique(res$metrics$variable), "new_score")
})
