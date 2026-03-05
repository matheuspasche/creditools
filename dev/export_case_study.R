# dev/export_case_study.R
devtools::load_all(quiet = TRUE)
library(dplyr, warn.conflicts = FALSE)
library(tidyr, warn.conflicts = FALSE)

set.seed(42)

cat("1. Generating 1M applicants...\n")
base <- generate_sample_data(n_applicants = 1000000, seed = 42)

# Vintages and Status
vintages <- seq(as.Date("2022-10-01"), as.Date("2023-12-01"), by = "month")
base$vintage <- sample(vintages, nrow(base), replace = TRUE)
base$status <- sample(c("Approved", "Denied"), nrow(base), replace = TRUE, prob = c(0.70, 0.30))

# Pre-computation of expected PDs
base <- base %>%
    mutate(
        pd_old = 1 / (1 + exp(-(-2.5 + (-0.006 * old_score) + rnorm(n(), 0, 0.3)))),
        pd_new = 1 / (1 + exp(-(-2.5 + (-0.007 * new_score) + rnorm(n(), 0, 0.2))))
    )
base$defaulted <- as.integer(runif(nrow(base)) < base$pd_old)

# Legacy policy
base$approved <- as.integer(base$old_score >= 500)
base$defaulted[base$approved == 0] <- as.integer(runif(sum(base$approved == 0)) < base$pd_old[base$approved == 0])

cat("2. Running Simulations...\n")
pol_A <- credit_policy(
    applicant_id_col = "id", score_cols = c("old_score", "new_score"),
    current_approval_col = "approved", actual_default_col = "defaulted",
    simulation_stages = list(
        stage_cutoff("credit_decision", cutoffs = list(old_score = 500)),
        stage_rate("anti_fraud", base_rate = 0.95),
        stage_rate("conversion", base_rate = 0.85)
    )
)

pol_B <- credit_policy(
    applicant_id_col = "id", score_cols = c("old_score", "new_score"),
    current_approval_col = "approved", actual_default_col = "defaulted",
    simulation_stages = list(
        stage_cutoff("credit_decision", cutoffs = list(new_score = 550)),
        stage_rate("anti_fraud", base_rate = 0.95),
        stage_rate("conversion", base_rate = 0.85)
    ),
    stress_scenarios = list(
        stress_custom(function(swap_ins) {
            # The engine expects a vector of default probabilities for the swap-in population
            swap_ins$pd_new
        })
    )
)

sim_A <- run_simulation(base, pol_A, quiet = TRUE)
sim_B <- run_simulation(base, pol_B, quiet = TRUE)

cat("3. Finding Risk Groups (Ward Clustering)...\n")
app_B <- sim_B$data %>% filter(new_approval == TRUE)
app_M <- sim_A$data %>% filter(new_approval == TRUE)

rg_B <- find_risk_groups(
    data = app_B, score_cols = "new_score", default_col = "defaulted",
    time_col = "vintage", bins = 15, min_vol_ratio = 0.05, max_crossings = 1L,
    oot_date = as.Date("2023-10-01"), max_groups = 7
)

rg_M <- find_risk_groups(
    data = app_M, score_cols = c("old_score", "new_score"), default_col = "defaulted",
    time_col = "vintage", bins = 8, min_vol_ratio = 0.05, max_crossings = 1L,
    oot_date = as.Date("2023-10-01"), max_groups = 7
)

cat("4. Exporting CSV with funnel flags and clusters...\n")
export <- sim_B$data %>%
    select(
        id, old_score, new_score, vintage,
        approved, defaulted, scenario,
        approved_credit_decision_new, approved_anti_fraud_new, approved_conversion_new,
        new_approval, simulated_default
    ) %>%
    left_join(rg_B$data %>% select(id, risk_rating_new_score = risk_rating), by = "id") %>%
    left_join(rg_M$data %>% select(id, risk_rating_matrix = risk_rating), by = "id")

out_path <- "C:/Users/Matheus/Documents/case_study_export.csv"
readr::write_csv(export, out_path)
cat("SUCCESS! Exported", nrow(export), "rows to:", out_path, "\n")
