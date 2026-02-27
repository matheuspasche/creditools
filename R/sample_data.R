#' Generate realistic sample data for credit simulation
#'
#' @description
#' Creates a large, realistic dataset for simulating credit policy changes.
#' This function generates two scores (`score_antigo` and `score_novo`) with a
#' controllable correlation structure and realistic rank migration (i.e., churn
#' in risk deciles).
#'
#' The generation process is based on a latent variable model:
#' 1. A "true risk" latent variable `z` is generated.
#' 2. Each score is a combination of this true risk and an idiosyncratic noise component.
#' 3. The `defaulted` outcome is a probabilistic function of the true risk `z`.
#' This ensures that the scores are predictive and the default rates are logical.
#'
#' @param n_applicants Number of applicants to generate.
#' @param correlation The desired correlation between the old and new scores.
#'   Must be between 0 and 1.
#' @param churn_rate A factor controlling the amount of rank migration. Higher
#'   values mean more customers change risk buckets between scores. A value of
#'   0 means the scores have a perfect rank correlation. A value of 1 gives
#'   a moderate amount of churn.
#' @param base_default_rate The approximate overall default rate in the population.
#' @param base_approval_rate The historical approval rate based on the old score.
#' @param default_rate_dispersion Controls the separation between good and bad risk.
#' @param min_conversion_rate The minimum conversion rate for the best scores.
#' @param max_conversion_rate The maximum conversion rate for the worst scores.
#' @param seed A random seed for reproducibility.
#'
#' @return A tibble with the generated sample data, including IDs, scores,
#'   historical policy outcomes, and the true default status.
#' @export
#'
#' @examples
#' # Generate a sample with high correlation and moderate churn
#' analytical_base <- generate_sample_data(
#'   n_applicants = 10000,
#'   correlation = 0.8,
#'   churn_rate = 1,
#'   seed = 42
#' )
#' \dontrun{
#' # Check the migration
#' table(
#'   dplyr::ntile(analytical_base$old_score, 10),
#'   dplyr::ntile(analytical_base$new_score, 10)
#' )
#'}
generate_sample_data <- function(n_applicants = 20000,
                                 correlation = 0.7,
                                 churn_rate = 1.0,
                                 base_default_rate = 0.10,
                                 base_approval_rate = 0.5,
                                 default_rate_dispersion = 0.4,
                                 min_conversion_rate = 0.4,
                                 max_conversion_rate = 0.8,
                                 seed = NULL) {
  if (!is.null(seed)) {
    set.seed(seed)
  }

  cli::cli_process_start("Generating realistic sample data for {n_applicants} applicants...")

  # Validate inputs
  stopifnot(correlation >= 0 && correlation <= 1)
  stopifnot(churn_rate >= 0)

  # 1. Define latent variables
  # z = true underlying risk (standard normal). A higher z means LOWER risk.
  # e1, e2 = idiosyncratic parts of each score (standard normal)
  z <- stats::rnorm(n_applicants)
  e1 <- stats::rnorm(n_applicants)
  e2 <- stats::rnorm(n_applicants)

  # 2. Generate latent scores based on the desired correlation and churn
  # The correlation between the two scores will be `a^2`.
  a <- sqrt(correlation)
  # The 'b' coefficient controls the churn. It's the magnitude of the idiosyncratic part.
  b <- churn_rate * sqrt(1 - correlation)

  # Latent scores. Higher values = better credit (maps to higher z)
  latent_score_1 <- a * z + b * e1
  latent_score_2 <- a * z + b * e2

  # 3. Generate default probability from the true risk 'z'
  # We use a logistic function. We need to find the intercept `intercept`
  # such that the average PD is equal to `base_default_rate`.
  # A higher z (lower risk) should lead to a lower PD.
  intercept <- log(base_default_rate / (1 - base_default_rate))

  # The coefficient for z determines how predictive the scores are (dispersion).
  z_coef <- default_rate_dispersion
  # The sign is negative because a higher z (better score) must lead to a lower probability of default.
  pd <- 1 / (1 + exp(-(intercept - z_coef * z)))

  # 4. Create the final dataset
  analytical_base <- tibble::tibble(
    id = 1:n_applicants,
    # --- Scores ---
    # We use pnorm to convert the unbounded normal latent scores to a [0, 1] scale,
    # then scale to 0-1000. This creates a more realistic, non-linear distribution.
    old_score = round(stats::pnorm(latent_score_1) * 1000),
    new_score = round(stats::pnorm(latent_score_2) * 1000),

    # --- True Outcome ---
    # Simulate who actually defaults based on their probability of default
    defaulted = as.integer(stats::runif(n_applicants) < pd)
  )

  # 5. Simulate historical policy outcomes
  # Historical approval was based on `old_score`
  cutoff_approval <- stats::quantile(analytical_base$old_score, 1 - base_approval_rate)
  analytical_base$approved <- as.integer(analytical_base$old_score >= cutoff_approval)

  # Historical hiring was conditional on approval, with a monotonic conversion rate
  analytical_base$hired <- 0L
  approved_idx <- which(analytical_base$approved == 1)
  
  if (length(approved_idx) > 0) {
    approved_scores <- analytical_base$old_score[approved_idx]
    min_score <- min(approved_scores, na.rm = TRUE)
    max_score <- max(approved_scores, na.rm = TRUE)

    # Linearly interpolate the conversion probability.
    # A higher score leads to a lower conversion rate.
    conversion_prob <- stats::approxfun(
      x = c(min_score, max_score),
      y = c(max_conversion_rate, min_conversion_rate),
      rule = 2 # Use the closest value for points outside the range
    )(approved_scores)

    hired_among_approved <- stats::runif(length(approved_idx)) < conversion_prob
    analytical_base$hired[approved_idx] <- as.integer(hired_among_approved)
  }

  # The `defaulted` flag is only "observed" for those who were hired in the past
  # For simulation purposes, we keep the "true" default status for everyone,
  # but in a real scenario, we would only have this for `hired == 1`.
  # The package functions are designed to handle this.

  cli::cli_process_done()

  return(analytical_base)
}
