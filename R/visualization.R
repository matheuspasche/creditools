#' Visualize trade-off between approval and default rates
#'
#' @param tradeoff_data Trade-off analysis results
#' @param score_col Specific score to visualize (if NULL, all scores)
#'
#' @return ggplot object
#' @export
visualize_tradeoffs <- function(tradeoff_data, score_col = NULL) {
  if (!is.null(score_col)) {
    tradeoff_data <- tradeoff_data %>%
      dplyr::filter(score == score_col)
  }

  ggplot2::ggplot(tradeoff_data, ggplot2::aes(x = approval_rate, y = default_rate, color = score)) +
    ggplot2::geom_point(alpha = 0.7) +
    ggplot2::geom_line(alpha = 0.7) +
    ggplot2::labs(
      title = "Trade-off: Approval Rate vs Default Rate",
      x = "Approval Rate",
      y = "Default Rate",
      color = "Score"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::scale_x_continuous(labels = scales::percent) +
    ggplot2::scale_y_continuous(labels = scales::percent)
}

#' Visualize relationship between cutoff and default rate
#'
#' @param tradeoff_data Trade-off analysis results
#' @param score_col Specific score to visualize (if NULL, all scores)
#'
#' @return ggplot object
#' @export
visualize_cutoff_default <- function(tradeoff_data, score_col = NULL) {
  if (!is.null(score_col)) {
    tradeoff_data <- tradeoff_data %>%
      dplyr::filter(score == score_col)
  }

  ggplot2::ggplot(tradeoff_data, ggplot2::aes(x = cutoff, y = default_rate, color = score)) +
    ggplot2::geom_point(alpha = 0.7) +
    ggplot2::geom_line(alpha = 0.7) +
    ggplot2::labs(
      title = "Cutoff vs Default Rate",
      x = "Cutoff Score",
      y = "Default Rate",
      color = "Score"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::scale_y_continuous(labels = scales::percent)
}

#' Visualize relationship between cutoff and approval rate
#'
#' @param tradeoff_data Trade-off analysis results
#' @param score_col Specific score to visualize (if NULL, all scores)
#'
#' @return ggplot object
#' @export
visualize_cutoff_approval <- function(tradeoff_data, score_col = NULL) {
  if (!is.null(score_col)) {
    tradeoff_data <- tradeoff_data %>%
      dplyr::filter(score == score_col)
  }

  ggplot2::ggplot(tradeoff_data, ggplot2::aes(x = cutoff, y = approval_rate, color = score)) +
    ggplot2::geom_point(alpha = 0.7) +
    ggplot2::geom_line(alpha = 0.7) +
    ggplot2::labs(
      title = "Cutoff vs Approval Rate",
      x = "Cutoff Score",
      y = "Approval Rate",
      color = "Score"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::scale_y_continuous(labels = scales::percent)
}


#' Compare simulation results with current observed metrics
#'
#' @param results Simulation results
#' @param config Simulation configuration
#'
#' @return Data frame with comparison metrics
#' @export
compare_with_current <- function(results, config) {
  data <- results$data
  current_approval_col <- config$current_approval_col
  actual_default_col <- config$actual_default_col

  # Calculate current metrics
  current_metrics <- data %>%
    dplyr::summarise(
      current_approval_rate = mean(.data[[current_approval_col]], na.rm = TRUE),
      current_default_rate = mean(.data[[actual_default_col]], na.rm = TRUE)
    )

  # Calculate simulation metrics for each score
  simulation_metrics <- purrr::map_dfr(config$score_columns, function(score_col) {
    final_approval_col <- get_final_approval_col(config$simulation_stages, score_col)
    default_col <- paste0("default_simulated_", score_col)

    data %>%
      dplyr::summarise(
        score = score_col,
        simulated_approval_rate = mean(.data[[final_approval_col]], na.rm = TRUE),
        simulated_default_rate = mean(.data[[default_col]], na.rm = TRUE),
        approval_rate_change = simulated_approval_rate - current_metrics$current_approval_rate,
        default_rate_change = simulated_default_rate - current_metrics$current_default_rate,
        .groups = "drop"
      )
  })

  # Add current metrics to each row
  simulation_metrics %>%
    dplyr::mutate(
      current_approval_rate = current_metrics$current_approval_rate,
      current_default_rate = current_metrics$current_default_rate
    ) %>%
    dplyr::select(
      score, current_approval_rate, current_default_rate,
      simulated_approval_rate, simulated_default_rate,
      approval_rate_change, default_rate_change
    )
}

#' Create a comparison visualization
#'
#' @param comparison_data Comparison data from compare_with_current
#' @param metric Metric to visualize ("approval", "default", "both")
#'
#' @return ggplot object
#' @export
visualize_comparison <- function(comparison_data, metric = c("both", "approval", "default")) {
  metric <- match.arg(metric)

  if (metric == "both") {
    # Create a combined plot
    approval_plot <- ggplot2::ggplot(comparison_data, ggplot2::aes(x = score, y = approval_rate_change)) +
      ggplot2::geom_col(fill = "steelblue") +
      ggplot2::labs(title = "Change in Approval Rate", y = "Approval Rate Change") +
      ggplot2::theme_minimal()

    default_plot <- ggplot2::ggplot(comparison_data, ggplot2::aes(x = score, y = default_rate_change)) +
      ggplot2::geom_col(fill = "firebrick") +
      ggplot2::labs(title = "Change in Default Rate", y = "Default Rate Change") +
      ggplot2::theme_minimal()

    return(gridExtra::grid.arrange(approval_plot, default_plot, ncol = 2))
  } else if (metric == "approval") {
    ggplot2::ggplot(comparison_data, ggplot2::aes(x = score, y = approval_rate_change)) +
      ggplot2::geom_col(fill = "steelblue") +
      ggplot2::labs(title = "Change in Approval Rate", y = "Approval Rate Change") +
      ggplot2::theme_minimal()
  } else {
    ggplot2::ggplot(comparison_data, ggplot2::aes(x = score, y = default_rate_change)) +
      ggplot2::geom_col(fill = "firebrick") +
      ggplot2::labs(title = "Change in Default Rate", y = "Default Rate Change") +
      ggplot2::theme_minimal()
  }
}
