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
           # Focus on regions where cutoffs are likely to matter
           probs <- seq(0.1, 0.9, length.out = n_steps)
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
           # Focus on regions around typical decision boundaries
           # Use percentiles that are most relevant for credit decisions
           probs <- c(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)
           if (n_steps > 9) {
             # Add more percentiles if needed
             extra_probs <- seq(0.05, 0.95, length.out = n_steps - 8)
             probs <- sort(c(probs, extra_probs))
           }
           stats::quantile(score_values, probs = probs, na.rm = TRUE) %>%
             unique() %>%
             as.numeric()
         }
  )
}

#' Calculate the trade-off elasticity between approval and default rates
#'
#' This function measures how much the default rate changes relative to
#' changes in the approval rate, helping identify where small increases
#' in approval lead to large increases in default.
#'
#' @param tradeoff_data Data frame with approval and default rates
#' @param elasticity_threshold Threshold for significant elasticity
#'
#' @return Data frame with elasticity calculations
#' @export
calculate_tradeoff_elasticity <- function(tradeoff_data, elasticity_threshold = 2.0) {
  tradeoff_data %>%
    dplyr::arrange(approval_rate) %>%
    dplyr::mutate(
      approval_change = approval_rate - dplyr::lag(approval_rate),
      default_change = default_rate - dplyr::lag(default_rate),
      elasticity = ifelse(approval_change != 0, default_change / approval_change, NA),
      significant_elasticity = abs(elasticity) > elasticity_threshold
    ) %>%
    dplyr::filter(!is.na(elasticity))
}

#' Find the point of diminishing returns in the trade-off curve
#'
#' Identifies where additional increases in approval rate lead to
#' disproportionately large increases in default rate.
#'
#' @param tradeoff_data Data frame with approval and default rates
#' @param min_elasticity Minimum elasticity to consider as diminishing returns
#'
#' @return The point of diminishing returns
#' @export
find_diminishing_returns <- function(tradeoff_data, min_elasticity = 2.0) {
  elasticity_data <- calculate_tradeoff_elasticity(tradeoff_data, min_elasticity)

  # Find the first point where elasticity exceeds threshold
  diminishing_point <- elasticity_data %>%
    dplyr::filter(significant_elasticity) %>%
    dplyr::slice(1)

  if (nrow(diminishing_point) == 0) {
    # If no point exceeds threshold, return the last point
    diminishing_point <- tradeoff_data %>%
      dplyr::arrange(approval_rate) %>%
      dplyr::slice(n())
  }

  return(diminishing_point)
}
