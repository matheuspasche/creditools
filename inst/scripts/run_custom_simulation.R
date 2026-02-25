# Load necessary libraries
# Ensure you have these packages installed:
# install.packages(c("devtools", "tidyverse", "ggplot2", "cli"))

# Load the creditools package from the local source
devtools::load_all()

library(tidyverse)
library(creditools)
library(ggplot2)

# --- 1. Custom Data Generation ---
generate_custom_data <- function(n_applicants = 20000, seed = 123) {
  if (!is.null(seed)) {
    set.seed(seed)
  }

  cli::cli_alert_info("Generating custom dataset with {n_applicants} applicants...")

  # Create a tibble with two scores
  df <- tibble(
    id = 1:n_applicants,
    score_vigente = runif(n_applicants, 300, 850),
    novo_score = runif(n_applicants, 300, 850)
  )

  # Create deciles for each score
  df <- df %>%
    mutate(
      decil_vigente = ntile(score_vigente, 10),
      decil_novo = ntile(novo_score, 10)
    )

  # Define default rates for each decile using linear interpolation
  # Note: ntile creates deciles from 1 (lowest scores) to 10 (highest scores)
  default_rates_vigente <- seq(from = 0.15, to = 0.03, length.out = 10) # Worst to best
  default_rates_novo <- seq(from = 0.17, to = 0.01, length.out = 10)     # Worst to best

  df <- df %>%
    mutate(
      prob_default_vigente = default_rates_vigente[decil_vigente],
      prob_default_novo = default_rates_novo[decil_novo]
    )

  # Generate default column based on the "novo_score" probabilities
  df$defaulted <- as.integer(runif(n_applicants) < df$prob_default_novo)

  # Define historical approval based on score_vigente (e.g., approve top 80%)
  cutoff_vigente <- quantile(df$score_vigente, 0.20)
  df$approved <- as.integer(df$score_vigente >= cutoff_vigente)

  cli::cli_alert_success("Custom data generated successfully.")

  # Return a sample for inspection if needed, but the full df for simulation
  return(df)
}

# --- 2. Simulation Setup ---

# Generate the data
sample_data <- generate_custom_data(n_applicants = 50000)

# Define the credit policy with stress scenarios
# We will aggravate the default rate of swap-ins by 20% and 40%
policy <- credit_policy(
  applicant_id_col = "id",
  score_cols = c("score_vigente", "novo_score"),
  current_approval_col = "approved",
  actual_default_col = "defaulted",
  risk_level_col = "decil_novo", # Use deciles for grouped aggravation
  stress_scenarios = list(
    stress_aggravation(factor = 1.2, by = "decil_novo"),
    stress_aggravation(factor = 1.4, by = "decil_novo")
  )
)

# Define the cutoffs for the new policy.
# We'll use a single cutoff on the 'novo_score'.
# Let's set it to the median for this example.
cutoffs <- list(
  novo_score = median(sample_data$novo_score)
)

cli::cli_alert_info("Running simulation with a cutoff of {cutoffs$novo_score} for 'novo_score'...")

# --- 3. Run Simulation ---
simulation_results <- run_simulation(
  data = sample_data,
  policy = policy,
  cutoffs = cutoffs
)

# --- 4. Visualize and Analyze Results ---

cli::cli_alert_info("Analyzing tradeoffs and generating plot...")

# The optimization and analysis functions in the package are currently
# inconsistent with the simulation flow.
# We will manually calculate the metrics from the simulation results
# to create the tradeoff plot, bypassing the broken functions.

# Calculate the overall approval and default rates from the simulation results.
# The 'new_approval' column indicates who is approved under the new policy.
# The 'simulated_default' column contains the final default outcome,
# using historical data for keep-ins and simulated data for swap-ins.
overall_metrics <- simulation_results %>%
  summarise(
    overall_approval_rate = mean(new_approval, na.rm = TRUE),
    overall_default_rate = mean(simulated_default, na.rm = TRUE)
  )

# The plotting functions expect a `credit_tradeoff_analysis` object.
# We will construct one manually for our single simulation point.
analysis_results <- list(
  overall_analysis = overall_metrics,
  optimal_result = overall_metrics, # For a single point, the optimal is the point itself
  pareto_frontier = overall_metrics, # Same for pareto frontier
  optimization_params = list( # Dummy params to satisfy the function
    target_default_rate = 1,
    min_approval_rate = 0,
    cutoff_steps = 1
  ),
  score_analysis = NULL # Not performing by-score analysis here
)
# The `visualize_tradeoffs` function checks for this class.
class(analysis_results) <- "credit_tradeoff_analysis"

# Now, create the plot using the exported function.
tradeoff_plot <- create_tradeoff_plot(analysis_results)

# Save the plot
ggsave("tradeoff_plot.png", plot = tradeoff_plot, width = 8, height = 6)
cli::cli_alert_success("Tradeoff plot saved to tradeoff_plot.png")


# --- 5. Create Analytical Base ---
# The user wants the resulting dataframe from the simulation
write.csv(simulation_results, "analytical_base.csv", row.names = FALSE)
cli::cli_alert_success("Analytical base saved to analytical_base.csv")

# Print a summary of the results to the console
cli::cli_h1("Simulation Summary")
summary <- simulation_results %>%
  group_by(scenario) %>%
  summarise(
    count = n(),
    avg_default_simulated = mean(simulated_default, na.rm = TRUE)
  )
print(summary)
