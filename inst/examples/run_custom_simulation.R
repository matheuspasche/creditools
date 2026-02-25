# ---
# title: "Run Custom Credit Policy Simulation"
# description: "This script generates a realistic analytical base, runs a credit
# policy simulation, and saves the results. It demonstrates how to use the
# creditools package to evaluate the impact of switching from an old score
# to a new one."
# ---

# Load necessary libraries and the local package
# Ensure you have these packages installed:
# install.packages(c("devtools", "tidyverse", "cli", "writexl", "fs"))
devtools::load_all()

# --- 1. Data Generation ---
# Generate a realistic dataset with two correlated scores.
# The `correlation` parameter controls how similar the scores are.
# The `churn_rate` parameter controls the amount of rank migration, creating
# the swap-in/swap-out dynamics we want to analyze.
cli::cli_h1("1. Generating Analytical Base")
analytical_base <- creditools::generate_sample_data(
  n_applicants = 5000000,
  correlation = 0.75,
  churn_rate = 1.2,
  seed = 42
)

# Add a decile column for the new score, to be used for stratified analysis
analytical_base$decil_novo <- dplyr::ntile(analytical_base$score_novo, 10)

cli::cli_alert_info("Checking score correlation: {round(cor(analytical_base$score_antigo, analytical_base$score_novo), 2)}")

# --- 2. Validate Score Migration ---
# This table shows how applicants move between risk deciles from the old
# score to the new one. The off-diagonal values represent the migration or "churn".
cli::cli_h1("2. Validating Score Decile Migration")
migration_table <- table(
  `Decil Antigo` = dplyr::ntile(analytical_base$score_antigo, 10),
  `Decil Novo` = analytical_base$decil_novo
)
print(migration_table)


# --- 3. Simulation Setup ---
cli::cli_h1("3. Setting up Credit Policy Simulation")

# Stage 1: Credit decision based on the new score
cutoff_value <- stats::median(analytical_base$score_novo)
credit_stage <- stage_cutoff(
  name = "credit_decision",
  cutoffs = list(score_novo = cutoff_value)
)
cli::cli_alert_info("Stage 1 (Credit): Approve if score_novo >= {round(cutoff_value)}")

# Stage 2: Anti-fraud model with a flat approval rate
antifraud_stage <- stage_rate(
  name = "anti_fraud",
  base_rate = 0.85
)
cli::cli_alert_info("Stage 2 (Anti-Fraud): 85% pass rate for those approved on credit.")

# Stage 3: Conversion rate that is monotonically decreasing with score
# Worst scores have a 90% conversion rate, best scores have 75%.
conversion_stage <- stage_rate(
  name = "conversion",
  base_rate = 0, # Placeholder, as logic is driven by stress_by_score
  stress_by_score = list(
    score_col = "score_novo",
    rate_at_min = 0.90, # Corresponds to the lowest score
    rate_at_max = 0.75  # Corresponds to the highest score
  )
)
cli::cli_alert_info("Stage 3 (Conversion): Monotonic rate from 90% (worst scores) to 75% (best scores).")


# Create the full policy object with the 3-stage funnel and a single stress scenario.
policy <- credit_policy(
  applicant_id_col = "id",
  score_cols = c("score_antigo", "score_novo"),
  current_approval_col = "approved",
  actual_default_col = "defaulted",
  risk_level_col = "decil_novo", # For stratified stress tests
  simulation_stages = list(
    credit_stage,
    antifraud_stage,
    conversion_stage
  ),
  stress_scenarios = list(
    stress_aggravation(factor = 1.3, by = "decil_novo")
  )
)


# --- 4. Run Simulation ---
cli::cli_h1("4. Running Simulation")
simulation_results <- run_simulation(
  data = analytical_base,
  policy = policy
)


# --- 5. Summarize and Save Results ---
cli::cli_h1("5. Summarizing and Saving Outputs")
# The summary aggregates key metrics by risk decile for each scenario.
summary_table <- summarize_results(
  simulation_results,
  by = "decil_novo"
)

# Define output paths
output_dir <- "inst"
fs::dir_create(output_dir) # Ensure directory exists
summary_path <- fs::path(output_dir, "simulation_summary.xlsx")
analytical_base_path <- fs::path(output_dir, "extdata", "analytical_base.csv")

# Create the extdata directory for the analytical base
fs::dir_create(fs::path_dir(analytical_base_path))

# Save summary table to Excel
writexl::write_xlsx(summary_table, path = summary_path)
cli::cli_alert_success("Simulation summary saved to {.path {summary_path}}")

# Save the generated data with simulation results to CSV
readr::write_csv(simulation_results$data, file = analytical_base_path)
cli::cli_alert_success("Full analytical base saved to {.path {analytical_base_path}}")

cli::cli_h2("Simulation Complete")
print(summary_table)


summary%>%
  summarise(pd_simulada = mean(simulated_default, na.rm = T), .by = c(decil_novo, scenario))%>%
  pivot_wider(names_from = scenario, values_from =pd_simulada)%>%
  filter(!is.na(keep_in))%>%
  arrange(decil_novo)%>%
  select(1,2,5)%>%
  mutate(delta = swap_in/keep_in)
