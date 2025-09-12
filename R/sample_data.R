#' Generate realistic sample data for credit simulation
#'
#' @param n_samples Number of samples
#' @param seed Seed for reproducibility
#'
#' @return Data frame with sample data
#' @export
generate_sample_data <- function(n_samples = 10000, seed = 123) {
  set.seed(seed)

  # Create base data
  data <- tibble::tibble(
    applicant_id = 1:n_samples,
    current_approval = sample(c(0, 1), n_samples, replace = TRUE, prob = c(0.4, 0.6)),
    income = pmax(round(rnorm(n_samples, mean = 5000, sd = 2000)), 1000),
    age = pmax(round(rnorm(n_samples, mean = 45, sd = 15)), 18)
  )

  # Generate scores with realistic distributions
  data <- data %>%
    dplyr::mutate(
      # Score 1: Better discrimination, lower default rates
      score_1 = generate_realistic_score(n_samples, mean = 700, sd = 80, skew = -0.5),

      # Score 2: Wider distribution, higher default rates
      score_2 = generate_realistic_score(n_samples, mean = 650, sd = 100, skew = 0.2)
    )

  # Calculate deciles for each score
  data <- data %>%
    dplyr::mutate(
      decile_score_1 = dplyr::ntile(score_1, 10),
      decile_score_2 = dplyr::ntile(score_2, 10)
    )

  # Define default rates by decile for each score
  default_rates_1 <- seq(0.02, 0.20, length.out = 10)  # Score 1: 2% to 20%
  default_rates_2 <- seq(0.03, 0.17, length.out = 10)  # Score 2: 3% to 17%

  # Define conversion rates by decile (higher for worse scores)
  conversion_rates <- seq(0.82, 0.95, length.out = 10)  # 82% to 95%

  # Simulate observed default with specified patterns
  data <- data %>%
    dplyr::mutate(
      # Default rates by decile for score 1
      observed_default_score_1 = purrr::map_int(
        decile_score_1,
        ~ as.integer(runif(1) < default_rates_1[.x])
      ),

      # Default rates by decile for score 2
      observed_default_score_2 = purrr::map_int(
        decile_score_2,
        ~ as.integer(runif(1) < default_rates_2[.x])
      ),

      # Use score_1 as primary observed default
      observed_default = observed_default_score_1,

      # Conversion rates (higher for worse deciles)
      conversion_rate = conversion_rates[decile_score_1]
    )

  # Define risk levels based on deciles (using score_1 deciles)
  data <- data %>%
    dplyr::mutate(
      risk_level = dplyr::case_when(
        decile_score_1 >= 8 ~ "Low_Risk",    # Deciles 8-10
        decile_score_1 >= 4 ~ "Medium_Risk", # Deciles 4-7
        TRUE ~ "High_Risk"                   # Deciles 1-3
      )
    )

  # Calculate aggravation factors based on observed default rates
  # Use a multiplier on the observed default rate for each risk level
  data <- data %>%
    dplyr::mutate(
      aggravation_factor = dplyr::case_when(
        risk_level == "Low_Risk" ~ 1.0 + (0.5 * observed_default),
        risk_level == "Medium_Risk" ~ 1.2 + (0.7 * observed_default),
        risk_level == "High_Risk" ~ 1.5 + (1.0 * observed_default)
      )
    )

  # Add historical rates for simulation
  data <- data %>%
    dplyr::mutate(
      historical_anti_fraud = 0.92,  # Base anti-fraud rate
      historical_conversion = conversion_rate  # Use conversion rates based on decile
    )

  # Set initial cutoffs (will be varied in analysis)
  data <- data %>%
    dplyr::mutate(
      score_1_min = 650,
      score_2_min = 620
    )

  return(data)
}

#' Generate realistic credit score distribution
#' @keywords internal
generate_realistic_score <- function(n, mean = 700, sd = 80, skew = 0) {
  # Generate base normal distribution
  base_scores <- rnorm(n, mean = mean, sd = sd)

  # Apply skewness if needed
  if (skew != 0) {
    base_scores <- base_scores + skew * (base_scores - mean(base_scores))^2 / sd(base_scores)
  }

  # Ensure scores are within typical credit score range
  base_scores <- pmin(pmax(base_scores, 300), 850)

  return(round(base_scores))
}
