library(testthat)
library(creditools)

test_that("stage_filter correctly parses and drops out invalid rows", {
    # Fake Population
    df <- data.frame(
        id = 1:5,
        idade = c(17, 18, 25, 30, NA),
        status = c("Valido", "Invalido", "Valido", "Valido", "Valido"),
        old_score = c(600, 600, 600, 600, 600),
        new_score = c(600, 600, 600, 600, 600),
        approved = rep(0, 5),
        defaulted = rep(0, 5),
        new_score_decile = rep(1, 5)
    )

    # Stage Config
    filter_1 <- stage_filter(name = "age_check", condition = "idade >= 18")
    filter_2 <- stage_filter(name = "status_check", condition = "status == 'Valido'")

    policy <- credit_policy(
        applicant_id_col = "id",
        score_cols = c("old_score", "new_score"),
        current_approval_col = "approved",
        actual_default_col = "defaulted",
        risk_level_col = "new_score_decile",
        simulation_stages = list(filter_1, filter_2)
    )

    # Run Sim
    res <- run_simulation(df, policy, quiet = TRUE)
    sim_df <- res$data

    # Only IDs 3 and 4 should pass both filters
    # ID 1 fails age_check
    # ID 2 fails status_check
    # ID 5 is NA for age, so fails age_check implicitly
    expect_equal(sim_df$new_approval[sim_df$id == 1], 0)
    expect_equal(sim_df$new_approval[sim_df$id == 2], 0)
    expect_equal(sim_df$new_approval[sim_df$id == 3], 1)
    expect_equal(sim_df$new_approval[sim_df$id == 4], 1)
    expect_equal(sim_df$new_approval[sim_df$id == 5], 0)
})

test_that("stage_filter alerts correctly on malformed conditions", {
    df <- head(generate_sample_data(), 10)

    # Invalid var
    policy_fail <- credit_policy(
        applicant_id_col = "id",
        score_cols = c("old_score", "new_score"),
        current_approval_col = "current_approved",
        actual_default_col = "defaulted",
        risk_level_col = "risk_band",
        simulation_stages = list(stage_filter("b", "nome_inventado >= 0"))
    )

    expect_error(run_simulation(df, policy_fail, quiet = TRUE), "Failed to evaluate filter condition")
})
