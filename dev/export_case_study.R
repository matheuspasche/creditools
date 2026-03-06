# dev/export_case_study.R
devtools::load_all(quiet = TRUE)
library(dplyr, warn.conflicts = FALSE)
library(tidyr, warn.conflicts = FALSE)

cat("1. Generating 1M applicants with complex demographics (Used Vehicles Case Study)...\n")
set.seed(2024)
n <- 1000000L # 1 Million rows for the export

# --- Latent risk factor ---
z <- rnorm(n)
e1 <- rnorm(n)
e2 <- rnorm(n)
current_score <- round(pnorm(0.84 * z + 0.54 * e1) * 700 + 300)
latent_new <- 0.84 * z + 0.54 * e2
latent_new <- ifelse(latent_new > 0, latent_new * 1.15, latent_new)
new_score <- round(pnorm(latent_new) * 700 + 300)

# --- Hard filter vars ---
cpf_valid <- sample(c(TRUE, FALSE), n, replace = TRUE, prob = c(0.995, 0.005))
age <- sample(18:70, n, replace = TRUE)
age[sample(n, round(n * 0.003))] <- sample(17:18, round(n * 0.003), replace = TRUE)
neg_reg <- rexp(n, 1 / 100)
neg_reg[sample(n, round(n * 0.10))] <- runif(round(n * 0.10), 301, 5000)

vintage <- sample(seq.Date(as.Date("2023-01-01"), by = "month", length.out = 15), n, replace = TRUE)
base_pd <- plogis(-3.8 + (-1.5) * z)
defaulted <- as.integer(stats::runif(n) < base_pd)

decile <- ntile(current_score, 10)
decile_new <- ntile(new_score, 10)
appr_prob <- c(0.05, 0.08, 0.12, 0.17, 0.22, 0.28, 0.35, 0.42, 0.50, 0.60)
approved <- as.integer(stats::runif(n) < appr_prob[decile])

base_data <- data.frame(
    id = 1:n, current_score, new_score, cpf_valid, age,
    neg_registry = round(neg_reg, 2), vintage, defaulted, approved,
    risk_decile = decile, risk_decile_new = decile_new, z = z, pd_new = base_pd
)

cat("2. Defining complex multi-stage policies...\n")
# --- Shared funnel components ---
hf <- list(
    stage_filter(name = "cpf", condition = "cpf_valid == TRUE"),
    stage_filter(name = "age", condition = "age >= 19"),
    stage_filter(name = "neg", condition = "neg_registry <= 300")
)
fraud <- stage_rate(name = "fraud", base_rate = 0.98)

# Baseline Policy (Current Score)
make_policy_A <- function(cutoff = 300) {
    p <- credit_policy(
        applicant_id_col = "id", score_cols = "current_score", current_approval_col = "approved", actual_default_col = "defaulted",
        simulation_stages = c(hf, list(
            stage_cutoff(name = "credit", cutoffs = setNames(list(cutoff), "current_score")),
            fraud, stage_rate(name = "desk", base_rate = 0.50)
        ))
    )
    # Pass-through stress to retain EXACT `defaulted` flags for swap_ins that otherwise would be NA
    p$stress_scenarios <- list(stress_custom(function(swap_ins) {
        as.numeric(swap_ins$defaulted)
    }))
    p
}

# Challenger Policy (New Score)
make_policy_B <- function(cutoff = 300) {
    p <- credit_policy(
        applicant_id_col = "id", score_cols = "new_score", current_approval_col = "approved", actual_default_col = "defaulted",
        risk_level_col = "risk_decile_new",
        simulation_stages = c(hf, list(
            stage_cutoff(name = "credit", cutoffs = setNames(list(cutoff), "new_score")),
            fraud, stage_rate(name = "desk", base_rate = 0.50)
        ))
    )
    p$stress_scenarios <- list(stress_aggravation(factor = 1.30, by = "risk_decile_new"))
    p
}

# Matrix Policy (Diagonal/Combined Logic via filter)
make_policy_M <- function(cutoff = 300) {
    # Approves if sum of scores >= 2 * cutoff
    p <- credit_policy(
        applicant_id_col = "id", score_cols = c("current_score", "new_score"), current_approval_col = "approved", actual_default_col = "defaulted",
        risk_level_col = "risk_decile",
        simulation_stages = c(hf, list(
            stage_filter(name = "credit", condition = sprintf("(current_score + new_score) >= %d", cutoff * 2)),
            fraud, stage_rate(name = "desk", base_rate = 0.50)
        ))
    )
    p$stress_scenarios <- list(stress_aggravation(factor = 1.30, by = "risk_decile"))
    p
}

cat("3. Finding Policy A Cutoff for exactly 25% Approval...\n")
set.seed(42)
base_samp <- base_data[sample(n, 100000), ]
base_samp$defaulted <- 0

tradeoff_A <- run_tradeoff_analysis(data = base_samp, base_policy = make_policy_A(300), vary_params = list(current_score_cutoff = seq(350, 650, by = 2)), quiet = TRUE)
best_cutoff_A <- tradeoff_A %>%
    mutate(diff = abs(approval_rate - 0.25)) %>%
    arrange(diff) %>%
    slice(1) %>%
    pull(current_score_cutoff)
cat(sprintf("   Optimal Current Score (A) Cutoff: %d\n", best_cutoff_A))

cat("4. Calibrating true default rate to EXACTLY 3% inside the Policy A approved base...\n")
sim_A_pre <- run_simulation(base_data, make_policy_A(best_cutoff_A), quiet = TRUE)
approved_A_idx <- which(sim_A_pre$data$new_approval == 1)
z_app <- base_data$z[approved_A_idx]

find_intercept <- function(int) {
    mean(plogis(int + (-1.5) * z_app)) - 0.03
}
opt_int <- uniroot(find_intercept, c(-20, 20), extendInt = "yes")$root
cat(sprintf("   Calibrated PD intercept: %.3f\n", opt_int))

base_pd <- plogis(opt_int + (-1.5) * base_data$z)
base_data$pd_new <- base_pd
set.seed(123)
base_data$defaulted <- as.integer(stats::runif(n) < base_pd)

cat("5. Re-Simulating Policy A with Calibrated Defaults...\n")
sim_A <- run_simulation(base_data, make_policy_A(best_cutoff_A), quiet = TRUE)
target_vol <- sum(sim_A$data$new_approval == 1, na.rm = TRUE)
target_rate <- target_vol / n
cat(sprintf("   Policy A Approval Volume: %s (%.2f%%) | Observed Default: %.2f%%\n", format(target_vol, big.mark = ","), target_rate * 100, mean(sim_A$data$simulated_default[sim_A$data$new_approval == 1], na.rm = TRUE) * 100))

cat("6. Grid Search for volume-neutral cutoff on Policy B & M (10% sample)...\n")
# Policy B (New Score)
tradeoff_B <- run_tradeoff_analysis(data = base_data[sample(n, 100000), ], base_policy = make_policy_B(300), vary_params = list(new_score_cutoff = seq(400, 700, by = 2)), quiet = TRUE)
best_cutoff_B <- tradeoff_B %>%
    mutate(diff = abs(approval_rate - target_rate)) %>%
    arrange(diff) %>%
    slice(1) %>%
    pull(new_score_cutoff)

# Policy M (Matrix) - We'll manually test cutoff thresholds for the Matrix (sum / 2)
eval_M <- sapply(seq(400, 650, by = 2), function(cut) {
    tmp <- run_simulation(base_data[sample(n, 50000), ], make_policy_M(cut), quiet = TRUE)
    mean(tmp$data$new_approval == 1, na.rm = TRUE)
})
best_cutoff_M <- seq(400, 650, by = 2)[which.min(abs(eval_M - target_rate))]

cat(sprintf("   Optimal New Score (B) Cutoff: %d\n", best_cutoff_B))
cat(sprintf("   Optimal Matrix (M) Mean Score Cutoff: %d\n", best_cutoff_M))

cat("7. Simulating Policy B & M with volume-neutral cutoffs...\n")
sim_B <- run_simulation(base_data, make_policy_B(best_cutoff_B), quiet = TRUE)
sim_M <- run_simulation(base_data, make_policy_M(best_cutoff_M), quiet = TRUE)

cat("   Policy B Default Rate:", round(mean(sim_B$data$simulated_default[sim_B$data$new_approval == 1], na.rm = TRUE) * 100, 2), "%\n")
cat("   Policy M Default Rate:", round(mean(sim_M$data$simulated_default[sim_M$data$new_approval == 1], na.rm = TRUE) * 100, 2), "%\n")

cat("8. Finding Risk Groups (Ward Clustering)...\n")
rg_A <- find_risk_groups(data = sim_A$data %>% filter(new_approval == 1), score_cols = "current_score", default_col = "defaulted", time_col = "vintage", bins = 15, min_vol_ratio = 0.05, max_crossings = 1L, oot_date = as.Date("2024-01-01"), max_groups = 7)
rg_B <- find_risk_groups(data = sim_B$data %>% filter(new_approval == 1), score_cols = "new_score", default_col = "defaulted", time_col = "vintage", bins = 15, min_vol_ratio = 0.05, max_crossings = 1L, oot_date = as.Date("2024-01-01"), max_groups = 7)
rg_M_groups <- find_risk_groups(data = sim_M$data %>% filter(new_approval == 1), score_cols = c("current_score", "new_score"), default_col = "defaulted", time_col = "vintage", bins = 5, min_vol_ratio = 0.05, max_crossings = 1L, oot_date = as.Date("2024-01-01"), max_groups = 7)

cat("9. Exporting CSV with complex funnel flags and clusters...\n")
export <- base_data %>%
    select(id, current_score, risk_decile, new_score, risk_decile_new, age, neg_registry, vintage, approved_historical = approved, defaulted_true = defaulted) %>%
    left_join(sim_A$data %>% select(id, cpf_A = approved_cpf_new, age_A = approved_age_new, neg_A = approved_neg_new, credit_A = approved_credit_new, fraud_A = approved_fraud_new, conversion_A = approved_desk_new, approval_A = new_approval, default_A = simulated_default, scenario_A = scenario), by = "id") %>%
    left_join(sim_B$data %>% select(id, cpf_B = approved_cpf_new, age_B = approved_age_new, neg_B = approved_neg_new, credit_B = approved_credit_new, fraud_B = approved_fraud_new, conversion_B = approved_desk_new, approval_B = new_approval, default_B = simulated_default, scenario_B = scenario), by = "id") %>%
    left_join(sim_M$data %>% select(id, cpf_M = approved_cpf_new, age_M = approved_age_new, neg_M = approved_neg_new, credit_M = approved_credit_new, fraud_M = approved_fraud_new, conversion_M = approved_desk_new, approval_M = new_approval, default_M = simulated_default, scenario_M = scenario), by = "id") %>%
    left_join(rg_A$data %>% select(id, risk_rating_A = risk_rating), by = "id") %>%
    left_join(rg_B$data %>% select(id, risk_rating_B = risk_rating), by = "id") %>%
    left_join(rg_M_groups$data %>% select(id, risk_rating_matrix = risk_rating), by = "id")

out_path <- "C:/Users/Matheus/Documents/case_study_export_complex_v3.xlsx"
if (!requireNamespace("writexl", quietly = TRUE)) install.packages("writexl", repos = "https://cloud.r-project.org")

save_success <- tryCatch(
    {
        writexl::write_xlsx(export, out_path)
        TRUE
    },
    error = function(e) {
        FALSE
    }
)

if (!save_success) {
    out_path <- sprintf("C:/Users/Matheus/Documents/case_study_export_complex_v3_%s.xlsx", format(Sys.time(), "%H%M%S"))
    cat("   ! Permission denied on standard file. Saving to new path to prevent data loss...\n")
    writexl::write_xlsx(export, out_path)
}

cat(sprintf("   Done! Exported to %s\n", out_path))
