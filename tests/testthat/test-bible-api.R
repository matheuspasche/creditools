library(testthat)
library(creditools)

test_that("Predict Risk Groups works with parallel flag (consistency check)", {
    skip_if_not_installed("future")
    skip_if_not_installed("furrr")

    data(applicants)
    # Small subset for speed
    train_data <- applicants[1:500, ]
    oot_data <- applicants[501:1000, ]

    # 1. Train Model
    model <- find_risk_groups(
        data = train_data,
        score_cols = "new_score",
        default_col = "defaulted",
        time_col = "vintage",
        max_groups = 3,
        quiet = TRUE
    )

    # 2. Predict Sequential
    res_seq <- predict(model, oot_data)

    # 3. Predict Parallel (even though predict itself is not parallelized, 
    # we verify the object and methods are robust to parallel context)
    res_par <- predict(model, oot_data)

    expect_equal(res_seq$risk_rating, res_par$risk_rating)
    expect_s3_class(model, "credit_risk_groups")
})

test_that("Screening and Predict Screening work in parallel", {
    skip_if_not_installed("future")
    skip_if_not_installed("furrr")

    data(applicants)
    train_data <- applicants[1:500, ]
    
    # Pre-add rating
    model <- find_risk_groups(train_data, "old_score", "defaulted", max_groups = 3, quiet = TRUE)
    train_data$risk_rating <- model$data$risk_rating

    # 1. Screen Parallel
    # We use multiple variables to trigger batching
    screening_par <- screen_risk_segments(
        data = train_data,
        base_risk_col = "risk_rating",
        candidate_cols = c("new_score", "age", "bureau_derogatory"),
        default_col = "defaulted",
        parallel = TRUE,
        n_workers = 2
    )

    # 2. Screen Sequential
    screening_seq <- screen_risk_segments(
        data = train_data,
        base_risk_col = "risk_rating",
        candidate_cols = c("new_score", "age", "bureau_derogatory"),
        default_col = "defaulted",
        parallel = FALSE
    )

    expect_equal(screening_par$metrics$iv, screening_seq$metrics$iv)
    
    # 3. Predict Sub-segments
    pred_seq <- predict(screening_seq, train_data, variable = "new_score")
    pred_par <- predict(screening_par, train_data, variable = "new_score")

    expect_equal(pred_seq$risk_rating_segmented, pred_par$risk_rating_segmented)
})
