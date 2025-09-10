#' Generate sample data with realistic business logic
#'
#' @param n_samples Number of samples
#' @param seed Seed for reproducibility
#'
#' @return Data frame with sample data
#' @export
generate_sample_data <- function(n_samples = 10000, seed = 123) {
  set.seed(seed)

  data <- tibble::tibble(
    applicant_id = 1:n_samples,
    current_approval = sample(c(0, 1), n_samples, replace = TRUE, prob = c(0.4, 0.6)),
    observed_default = NA_integer_,
    risk_level = sample(c("Low_Risk", "Medium_Risk", "High_Risk"), n_samples,
                        replace = TRUE, prob = c(0.6, 0.3, 0.1)),
    income = pmax(round(rnorm(n_samples, mean = 5000, sd = 2000)), 1000)
  )

  # Generate scores with different distributions by risk level
  data <- data %>%
    dplyr::mutate(
      score_1 = dplyr::case_when(
        risk_level == "Low_Risk" ~ pmin(pmax(rnorm(dplyr::n(), mean = 700, sd = 50), 300), 850),
        risk_level == "Medium_Risk" ~ pmin(pmax(rnorm(dplyr::n(), mean = 650, sd = 70), 300), 850),
        risk_level == "High_Risk" ~ pmin(pmax(rnorm(dplyr::n(), mean = 600, sd = 90), 300), 850)
      ),
      score_2 = dplyr::case_when(
        risk_level == "Low_Risk" ~ pmin(pmax(rnorm(dplyr::n(), mean = 720, sd = 40), 300), 850),
        risk_level == "Medium_Risk" ~ pmin(pmax(rnorm(dplyr::n(), mean = 670, sd = 60), 300), 850),
        risk_level == "High_Risk" ~ pmin(pmax(rnorm(dplyr::n(), mean = 620, sd = 80), 300), 850)
      ),
      score_1_min = 650,  # Cutoff for score 1
      score_2_min = 680,  # Cutoff for score 2
      # Add historical conversion and anti-fraud rates for keep_in-based simulation
      historical_conversion = dplyr::case_when(
        risk_level == "Low_Risk" ~ 0.8,
        risk_level == "Medium_Risk" ~ 0.7,
        risk_level == "High_Risk" ~ 0.6
      ),
      historical_anti_fraud = dplyr::case_when(
        risk_level == "Low_Risk" ~ 0.95,
        risk_level == "Medium_Risk" ~ 0.9,
        risk_level == "High_Risk" ~ 0.85
      )
    )

  # Simulate observed default only for approved applicants
  approved_mask <- data$current_approval == 1
  data$observed_default[approved_mask] <- as.integer(
    stats::runif(sum(approved_mask)) < dplyr::case_when(
      data$risk_level[approved_mask] == "Low_Risk" ~ 0.02,
      data$risk_level[approved_mask] == "Medium_Risk" ~ 0.05,
      data$risk_level[approved_mask] == "High_Risk" ~ 0.10
    )
  )



  return(data)
}
