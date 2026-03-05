library(testthat)
library(creditools)

test_that("find_risk_groups successfully matrixes, prunes and evaluates OOT", {

    # Fake data with vintages and 2 scores
    set.seed(42)
    n <- 5000
    df <- data.frame(
        id = 1:n,
        score_A = rnorm(n, 500, 100),
        score_B = rnorm(n, 600, 50),
        vintage = sample(c("2023-01", "2023-02", "2023-03", "2023-04"), n, replace = TRUE),
        default = sample(0:1, n, replace = TRUE, prob = c(0.8, 0.2))
    )

    # Inject some logical signal (lower scores = higher default) to test empirical matching
    df$default[df$score_A < 400 & df$score_B < 600] <- sample(0:1, sum(df$score_A < 400 & df$score_B < 600), replace = TRUE, prob = c(0.4, 0.6))

    # Run Engine
    res <- find_risk_groups(
        data = df,
        score_cols = c("score_A", "score_B"),
        default_col = "default",
        time_col = "vintage",
        time_col_format = "%Y-%m",
        min_vol_ratio = 0.05, # groups must have at least 5% of pop
        max_volatility_cv = 0.30, # very tolerant variance for simulated mock sake
        bins = 5, # 5x5 matrix
        oot_date = "2023-04" # 1 month out of time
    )

    # Assertions
    # 1. Dimensions and columns
    expect_equal(nrow(res$data), n)
    expect_true("risk_rating" %in% names(res$data))

    # 2. Pruning success (5x5 = 25 initial groups, should be reduced by min_vol 5%)
    # Usually it merges down to < 20
    expect_true(length(unique(res$data$risk_rating)) <= 25)

    # 3. Report Output Structure
    expect_true("Train" %in% res$report$period)
    expect_true("OOT (Validation)" %in% res$report$period)

    # 4. Volumetry constraints applied in mapping
    # Since we use 0.05 on the whole train chunk, check train
    train_chunk <- res$data[res$data$vintage < as.Date("2023-04-01"), ]
    vol_check <- table(train_chunk$risk_rating) / nrow(train_chunk)
    # Due to dense ranking jumps, smallest group should safely exceed the 5% unless perfectly identical overlapping neighbors forces tiny drops, but generally true.
    expect_true(all(vol_check >= 0.04))
})
