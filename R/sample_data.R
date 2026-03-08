#' Generate realistic sample data for credit simulation
#'
#' @description
#' Creates a large, realistic dataset for simulating credit policy changes.
#' This function generates two scores (`old_score` and `new_score`) with a
#' controllable correlation structure and realistic rank migration (i.e., churn
#' in risk deciles), mirroring the structure used in the
#' *Used Vehicles* case study vignette.
#'
#' When `complex_demographics = TRUE`, additional columns emulate a real
#' underwriting funnel:
#' - `id_valid`: proxy for CPF/document validation (˜ 0.5% invalid)
#' - `age`: applicant age with a small left tail below 19 years (˜ 0.3%)
#' - `bureau_derogatory`: negative registry amount in a credit bureau, with
#'   ˜ 10% of the population above a high-risk threshold (R$300+)
#' - `vintage`: monthly cohort across a fixed analysis window
#'
#' The generation process is based on a latent variable model:
#' 1. A "true risk" latent variable `z` is generated.
#' 2. Each score is a combination of this true risk and an idiosyncratic noise component.
#' 3. The `defaulted` outcome is a probabilistic function of the true risk `z`.
#' This ensures that the scores are predictive and the default rates are logical.
#'
#' Use `base_default_rate` to anchor the portfolio-level default rate,
#' `default_rate_dispersion` to control separation between good and bad risk
#' (higher values create more extreme tails), and `pd_multiplier` to inflate
#' the PD globally when you need extra bads in peripheral deciles for
#' volumetric stress testing. In combination, these levers reproduce the
#' high-intensity tails used in the *Used Vehicles* case study.
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
#' @param pd_multiplier A factor to artificially inflate the PD for volumetric testing (default: 1.0).
#' @param complex_demographics If TRUE, adds real-world columns like `age`, `id_valid`, `bureau_derogatory`, and `vintage`.
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
#'   pd_multiplier = 2,
#'   seed = 42
#' )
#' \dontrun{
#' # Check the migration
#' table(
#'   dplyr::ntile(analytical_base$old_score, 10),
#'   dplyr::ntile(analytical_base$new_score, 10)
#' )
#' }
generate_sample_data <- function(n_applicants = 20000,
                                 correlation = 0.7,
                                 churn_rate = 1.0,
                                 base_default_rate = 0.10,
                                 base_approval_rate = 0.5,
                                 default_rate_dispersion = 0.4,
                                 min_conversion_rate = 0.4,
                                 max_conversion_rate = 0.8,
                                 pd_multiplier = 1.0,
                                 complex_demographics = TRUE,
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
  pd <- pmin(pd * pd_multiplier, 1)

  # 4. Generate complex demographic variables if requested
  if (complex_demographics) {
    id_valid <- sample(c(TRUE, FALSE), n_applicants, replace = TRUE, prob = c(0.995, 0.005))
    age <- sample(18:70, n_applicants, replace = TRUE)
    age[sample(n_applicants, round(n_applicants * 0.003))] <- sample(17:18, round(n_applicants * 0.003), replace = TRUE)
    bureau_dero <- stats::rexp(n_applicants, 1 / 100)
    bureau_dero[sample(n_applicants, round(n_applicants * 0.10))] <- stats::runif(round(n_applicants * 0.10), 301, 5000)
    vintage <- sample(seq.Date(as.Date("2023-01-01"), by = "month", length.out = 15), n_applicants, replace = TRUE)
  } else {
    id_valid <- rep(TRUE, n_applicants)
    age <- rep(30L, n_applicants)
    bureau_dero <- rep(0, n_applicants)
    vintage <- rep(as.Date("2023-01-01"), n_applicants)
  }

  # 5. Create the final dataset
  analytical_base <- tibble::tibble(
    id = 1:n_applicants,
    # --- Scores ---
    old_score = round(stats::pnorm(latent_score_1) * 1000),
    new_score = round(stats::pnorm(latent_score_2) * 1000),

    # --- True Outcome ---
    defaulted = as.integer(stats::runif(n_applicants) < pd),

    # --- Demographics ---
    id_valid = id_valid,
    age = age,
    bureau_derogatory = round(bureau_dero, 2),
    vintage = vintage
  )

  # 6. Simulate historical policy outcomes
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
