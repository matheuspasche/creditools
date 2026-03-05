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
appr_prob <- c(0.05, 0.08, 0.12, 0.17, 0.22, 0.28, 0.35, 0.42, 0.50, 0.60)
approved <- as.integer(stats::runif(n) < appr_prob[decile])

base_data <- data.frame(
    id = 1:n, current_score, new_score, cpf_valid, age,
    neg_registry = round(neg_reg, 2), vintage, defaulted, approved,
    risk_decile = decile, pd_new = base_pd # Storing pd_new to use in stress_custom
)

cat("2. Defining complex multi-stage policies...\n")
# --- Shared funnel components ---
hf <- list(
    stage_filter(name = "cpf", condition = "cpf_valid == TRUE"),
    stage_filter(name = "age", condition = "age >= 19"),
    stage_filter(name = "neg", condition = "neg_registry <= 300")
)
fraud <- stage_rate(name = "fraud", base_rate = 0.98)

make_policy <- function(score_col, cutoff = 450, apply_stress = FALSE) {
    p <- credit_policy(
        applicant_id_col = "id", score_cols = c("current_score", "new_score"),
        current_approval_col = "approved", actual_default_col = "defaulted",
        risk_level_col = "risk_decile",
        simulation_stages = c(hf, list(
            stage_cutoff(name = "credit", cutoffs = setNames(list(cutoff), score_col)),
            fraud,
            stage_rate(
                name = "desk", base_rate = 0.40,
                stress_by_score = list(score_col = score_col, rate_at_min = 0.10, rate_at_max = 0.70)
            )
        ))
    )
    if (apply_stress) {
        p$stress_scenarios <- list(
            stress_custom(function(swap_ins) {
                # Base PD aggravated by 30% for new profiles
                pmin(swap_ins$pd_new * 1.30, 1)
            })
        )
    }
    return(p)
}

cat("3. Simulating Policy A (Current)...\n")
sim_A <- run_simulation(base_data, make_policy("current_score", cutoff = 450, apply_stress = FALSE), quiet = TRUE)

target_vol <- sum(sim_A$data$new_approval)
target_rate <- target_vol / n
cat(sprintf("   Target Approval Volume: %s (%.2f%%)\n", format(target_vol, big.mark = ","), target_rate * 100))

cat("4. Grid Search for volume-neutral cutoff using run_tradeoff_analysis (10% sample)...\n")
set.seed(123)
base_samp <- base_data[sample(n, 100000), ]

tradeoff_res <- run_tradeoff_analysis(
    data = base_samp,
    base_policy = make_policy("new_score", apply_stress = FALSE),
    vary_params = list(new_score_cutoff = seq(350, 650, by = 2)),
    quiet = TRUE
)

# Encontrar o cutoff com a menor diferença na taxa de aprovação
best_row <- tradeoff_res %>%
    mutate(diff = abs(approval_rate - target_rate)) %>%
    arrange(diff) %>%
    slice(1)

best_cutoff <- best_row$new_score_cutoff
cat(sprintf(
    "   Optimal New Score Cutoff found: %d (Estimated Approval: %.2f%%)\n",
    best_cutoff, best_row$approval_rate * 100
))

cat("5. Simulating Policy B with volume-neutral cutoff...\n")
sim_B <- run_simulation(base_data, make_policy("new_score", cutoff = best_cutoff, apply_stress = TRUE), quiet = TRUE)

cat("6. Finding Risk Groups (Ward Clustering)...\n")
app_A <- sim_A$data %>% filter(new_approval == TRUE)
app_B <- sim_B$data %>% filter(new_approval == TRUE)

rg_B <- find_risk_groups(
    data = app_B, score_cols = "new_score",
    default_col = "defaulted", time_col = "vintage",
    bins = 15, min_vol_ratio = 0.05, max_crossings = 1L,
    oot_date = as.Date("2024-01-01"), max_groups = 7
)

rg_M <- find_risk_groups(
    data = app_A, score_cols = c("current_score", "new_score"),
    default_col = "defaulted", time_col = "vintage",
    bins = 8, min_vol_ratio = 0.05, max_crossings = 1L,
    oot_date = as.Date("2024-01-01"), max_groups = 7
)

cat("7. Exporting CSV with complex funnel flags and clusters...\n")
export <- sim_B$data %>%
    select(
        id, current_score, new_score, age, neg_registry, vintage,
        approved, defaulted, scenario,
        approved_cpf_new, approved_age_new, approved_neg_new,
        approved_credit_new, approved_fraud_new, approved_desk_new,
        new_approval, simulated_default
    ) %>%
    left_join(rg_B$data %>% select(id, risk_rating_new_score = risk_rating), by = "id") %>%
    left_join(rg_M$data %>% select(id, risk_rating_matrix = risk_rating), by = "id")

out_path <- "C:/Users/Matheus/Documents/case_study_export_complex.csv"
readr::write_csv(export, out_path)
cat("SUCCESS! Exported", nrow(export), "rows to:", out_path, "\n")
