#' Generate efficient cutoff sequences based on score distribution
#'
#' @param data Input data
#' @param score_col Score column name
#' @param n_steps Number of steps
#' @param method Method for generating steps ("quantile", "linear", "optimal")
#'
#' @return Sequence of cutoff values
#' @export
generate_efficient_cutoff_sequence <- function(data, score_col, n_steps = 10,
                                               method = c("quantile", "linear", "optimal")) {
  method <- match.arg(method)
  score_values <- data[[score_col]]

  switch(method,
         "quantile" = {
           probs <- seq(0, 1, length.out = n_steps + 1)
           stats::quantile(score_values, probs = probs, na.rm = TRUE) %>%
             unique() %>%
             as.numeric()
         },
         "linear" = {
           min_val <- min(score_values, na.rm = TRUE)
           max_val <- max(score_values, na.rm = TRUE)
           seq(min_val, max_val, length.out = n_steps)
         },
         "optimal" = {
           # Focus on regions where cutoffs are likely to matter
           # Use percentiles around typical decision boundaries
           probs <- c(0, 0.1, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1)
           if (n_steps > 9) {
             # Add more percentiles if needed
             extra_probs <- seq(0, 1, length.out = n_steps - 8)
             probs <- sort(c(probs, extra_probs))
           }
           stats::quantile(score_values, probs = probs, na.rm = TRUE) %>%
             unique() %>%
             as.numeric()
         }
  )
}

#' Calculate required cutoff steps based on desired precision
#'
#' @param score_range Range of the score
#' @param desired_precision Desired precision in score units
#' @param max_steps Maximum number of steps to consider
#'
#' @return Number of steps needed
#' @export
calculate_required_steps <- function(score_range, desired_precision = 10, max_steps = 100) {
  range_size <- diff(score_range)
  required_steps <- ceiling(range_size / desired_precision)
  min(required_steps, max_steps)
}

#' Estimate computation requirements for optimization
#'
#' @param config Simulation configuration
#' @param cutoff_steps Number of cutoff steps per score
#' @param sample_size Sample size for estimation
#'
#' @return List with computation estimates
#' @export
estimate_computation_requirements <- function(config, cutoff_steps, sample_size = 10000) {
  n_scores <- length(config$score_columns)
  n_combinations <- cutoff_steps ^ n_scores

  # Estimate time per simulation (very rough estimate)
  time_per_sim <- 0.1 * (sample_size / 10000)  # 0.1 seconds per 10,000 rows

  total_time <- n_combinations * time_per_sim
  total_time_human <- format_time(total_time)

  list(
    n_scores = n_scores,
    n_combinations = n_combinations,
    estimated_total_time_seconds = total_time,
    estimated_total_time_human = total_time_human,
    recommendation = ifelse(n_combinations > 1000, "Use parallel processing", "Sequential is fine")
  )
}

#' Format time in human-readable format
#' @keywords internal
format_time <- function(seconds) {
  if (seconds < 60) {
    paste(round(seconds, 1), "seconds")
  } else if (seconds < 3600) {
    paste(round(seconds / 60, 1), "minutes")
  } else {
    paste(round(seconds / 3600, 1), "hours")
  }
}
