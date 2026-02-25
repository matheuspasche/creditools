#' Generate realistic sample data for credit simulation
#'
#' @description
#' Creates a large, realistic dataset for testing and validating the credit
#' simulation package. It includes multiple correlated scores, a latent "true risk"
#' variable to make defaults logical, and columns for a historical policy.
#'
#' @param n_applicants Number of applicants to generate.
#' @param n_scores Number of different score columns to create.
#' @param base_approval_rate The approximate approval rate of the historical policy.
#' @param base_default_rate The approximate default rate for the approved population.
#' @param seed A random seed for reproducibility.
#'
#' @return A tibble with the generated sample data.
#' @export
#'
#' @examples
#' # Generate a small sample for exploration
#' sample_df <- generate_sample_data(n_applicants = 1000)
#'
#' # Generate a large sample for stress testing
#' \dontrun{
#'   large_sample <- generate_sample_data(n_applicants = 100000, seed = 42)
#' }
generate_sample_data <- function(n_applicants = 10000,
                                 n_scores = 3,
                                 base_approval_rate = 0.6,
                                 base_default_rate = 0.08,
                                 seed = NULL) {
  
  if (!is.null(seed)) {
    set.seed(seed)
  }
  
  cli::cli_alert_info("Generating {n_applicants} applicants with {n_scores} scores...")
  
  # 1. Create a latent "true risk" variable. This is the unobservable truth.
  # A lower value means higher risk.
  true_risk <- stats::rbeta(n_applicants, shape1 = 2, shape2 = 5)
  
  # 2. Generate scores that are correlated with the true risk
  score_list <- purrr::map(1:n_scores, function(i) {
    # Add some noise to each score
    noise <- stats::rnorm(n_applicants, mean = 0, sd = 0.1)
    # Scale true_risk to a typical score range (e.g., 300-850)
    score <- 300 + (1 - (true_risk + noise)) * 550
    # Ensure scores are within a reasonable range
    score <- pmin(pmax(score, 300), 850)
    return(score)
  })
  names(score_list) <- paste0("score_v", 1:n_scores)
  
  # 3. Create the main data frame
  df <- tibble::tibble(
    id = 1:n_applicants,
    .rows = n_applicants
  )
  df <- dplyr::bind_cols(df, tibble::as_tibble(score_list))
  
  # 4. Create the historical approval decision based on the first score
  cutoff_score <- stats::quantile(df$score_v1, 1 - base_approval_rate)
  df$approved <- as.integer(df$score_v1 >= cutoff_score)
  
  # 5. Generate default outcomes, which depend on true risk
  # The probability of default is inversely related to true_risk
  default_prob <- (1 - true_risk) * (base_default_rate / (1 - mean(true_risk)))
  df$defaulted <- NA_integer_
  
  approved_indices <- which(df$approved == 1)
  df$defaulted[approved_indices] <- as.integer(
    stats::runif(length(approved_indices)) < default_prob[approved_indices]
  )
  
  # 6. Add a risk stratification column based on score_v1 deciles
  df$risk_decile <- factor(dplyr::ntile(df$score_v1, 10))
  
  cli::cli_alert_success("Sample data generated successfully.")
  
  return(df)
}
