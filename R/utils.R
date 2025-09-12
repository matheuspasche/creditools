#' Generate a sequence of cutoff values
#'
#' @param min_cutoff Minimum cutoff value
#' @param max_cutoff Maximum cutoff value
#' @param n_points Number of points to generate
#' @param method Method for generating sequence ("linear", "quantile", "optimal")
#' @param data Optional data for quantile-based generation
#' @param score_col Optional score column for quantile-based generation
#'
#' @return Sequence of cutoff values
#' @export
generate_cutoff_sequence <- function(min_cutoff = 300, max_cutoff = 850,
                                     n_points = 50, method = c("linear", "quantile", "optimal"),
                                     data = NULL, score_col = NULL) {

  method <- match.arg(method)

  if (method %in% c("quantile", "optimal") && (is.null(data) || is.null(score_col))) {
    cli::cli_abort("Data and score_col are required for quantile and optimal methods")
  }

  switch(method,
         "linear" = {
           seq(min_cutoff, max_cutoff, length.out = n_points)
         },
         "quantile" = {
           score_values <- data[[score_col]]
           probs <- seq(0, 1, length.out = n_points)
           stats::quantile(score_values, probs = probs, na.rm = TRUE) %>%
             as.numeric()
         },
         "optimal" = {
           score_values <- data[[score_col]]
           # Focus on regions where cutoffs are likely to matter
           probs <- seq(0.1, 0.9, length.out = n_points)
           stats::quantile(score_values, probs = probs, na.rm = TRUE) %>%
             as.numeric()
         }
  )
}

#' Calculate detailed decile statistics
#'
#' @param data Input data
#' @param score_col Score column name
#' @param default_col Default column name
#'
#' @return Data frame with decile statistics
#' @export
calculate_decile_stats <- function(data, score_col, default_col = "observed_default") {
  data %>%
    dplyr::mutate(decile = dplyr::ntile(.data[[score_col]], 10)) %>%
    dplyr::group_by(decile) %>%
    dplyr::summarise(
      min_score = min(.data[[score_col]], na.rm = TRUE),
      max_score = max(.data[[score_col]], na.rm = TRUE),
      avg_score = mean(.data[[score_col]], na.rm = TRUE),
      default_rate = mean(.data[[default_col]], na.rm = TRUE),
      n_observations = dplyr::n(),
      .groups = "drop"
    ) %>%
    dplyr::arrange(decile)
}
