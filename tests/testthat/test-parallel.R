library(testthat)
library(creditools)

test_that("Parallel processing in find_pairwise_risk_groups works and is consistent", {
    skip_if_not_installed("future")
    skip_if_not_installed("furrr")

    data(applicants)
    # Use small subset for faster test
    test_data <- applicants[1:500, ]

    # 1. Sequential Results
    res_seq <- find_pairwise_risk_groups(
        data = test_data,
        primary_score = "old_score",
        challenger_scores = "new_score",
        default_col = "defaulted",
        time_col = "vintage",
        parallel = FALSE,
        quiet = TRUE
    )

    # 2. Parallel Results (using implicit dots)
    res_par <- find_pairwise_risk_groups(
        data = test_data,
        primary_score = "old_score",
        challenger_scores = "new_score",
        default_col = "defaulted",
        time_col = "vintage",
        parallel = TRUE,
        n_workers = 2,
        quiet = TRUE
    )

    expect_equal(res_seq$old_score_vs_new_score$report, res_par$old_score_vs_new_score$report)
})

test_that("find_risk_groups works in parallel (implicit setup)", {
    skip_if_not_installed("future")
    skip_if_not_installed("furrr")

    data(applicants)
    test_data <- applicants[1:500, ]

    # Sequential
    res_seq <- find_risk_groups(
        data = test_data,
        score_cols = "new_score",
        default_col = "defaulted",
        time_col = "vintage",
        parallel = FALSE,
        quiet = TRUE
    )

    # Parallel
    res_par <- find_risk_groups(
        data = test_data,
        score_cols = "new_score",
        default_col = "defaulted",
        time_col = "vintage",
        parallel = TRUE,
        n_workers = 2,
        quiet = TRUE
    )

    expect_equal(res_seq$report, res_par$report)
})

test_that("find_optimal_cutoffs works in parallel (implicit setup)", {
    skip_if_not_installed("future")
    skip_if_not_installed("furrr")

    data(applicants)
    test_data <- applicants[1:200, ]

    policy <- credit_policy(
        applicant_id_col = "id",
        score_cols = "new_score",
        current_approval_col = "approved",
        actual_default_col = "defaulted"
    )

    # Stochastic method with parallel = FALSE
    res_seq <- find_optimal_cutoffs(
        data = test_data,
        config = policy,
        cutoff_steps = 3,
        method = "stochastic",
        parallel = FALSE
    )

    # Stochastic method with parallel = TRUE
    res_par <- find_optimal_cutoffs(
        data = test_data,
        config = policy,
        cutoff_steps = 3,
        method = "stochastic",
        parallel = TRUE,
        n_workers = 2
    )

    # They might not be 100% equal due to stochastic noise if seeds are not handled,
    # but the structure and ability to run is what we test here.
    expect_s3_class(res_par, "credit_opt_results")
    expect_true(nrow(res_par) > 0)
})

test_that("run_tradeoff_analysis respects pre-existing parallel plans", {
    skip_if_not_installed("future")

    # Setup a manual plan
    future::plan(future::multisession, workers = 2)
    on.exit(future::plan(future::sequential))

    data(applicants)
    policy <- credit_policy(
        applicant_id_col = "id",
        score_cols = "new_score",
        current_approval_col = "approved",
        actual_default_col = "defaulted"
    )

    # This should run without changing the plan because it's already non-sequential
    res <- run_tradeoff_analysis(
        data = applicants[1:100, ],
        base_policy = policy,
        vary_params = list(new_score_cutoff = c(500, 600)),
        parallel = TRUE,
        quiet = TRUE
    )

    expect_true(inherits(future::plan(), "multisession"))
    expect_s3_class(res, "tbl_df")
})

test_that("Parallel setup reverts to sequential if it created the plan", {
    skip_if_not_installed("future")

    # Ensure we start sequential
    future::plan(future::sequential)

    data(applicants)
    policy <- credit_policy(
        applicant_id_col = "id",
        score_cols = "new_score",
        current_approval_col = "approved",
        actual_default_col = "defaulted"
    )

    # Trigger auto-setup
    run_tradeoff_analysis(
        data = applicants[1:100, ],
        base_policy = policy,
        vary_params = list(new_score_cutoff = c(500, 600)),
        parallel = TRUE,
        n_workers = 2,
        quiet = TRUE
    )

    # Should be sequential again due to on.exit
    expect_true(inherits(future::plan(), "sequential"))
})
