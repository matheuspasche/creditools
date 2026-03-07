#' Visualize relationship between cutoff and default rate
#'
#' These helper plots are thin wrappers around the output of
#' `run_tradeoff_analysis()`. They expect a data frame where each row is a
#' parameter combination (e.g., `new_score_cutoff`, `aggravation_factor`) and
#' columns `cutoff`, `approval_rate`, `default_rate`, and `score` have been
#' prepared by the caller.
#'
#' @param tradeoff_data Trade-off analysis results with at least
#'   `cutoff`, `default_rate` and `score` columns.
#' @param score_col Specific score to visualize (if NULL, all scores).
#'
#' @return A ggplot object.
#' @export
visualize_cutoff_default <- function(tradeoff_data, score_col = NULL) {
  if (!is.null(score_col)) {
    tradeoff_data <- tradeoff_data %>%
      dplyr::filter(.data$score == score_col)
  }

  ggplot2::ggplot(tradeoff_data, ggplot2::aes(x = .data$cutoff, y = .data$default_rate, color = .data$score)) +
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
#' See `visualize_cutoff_default()` for the expected structure of
#' `tradeoff_data`. This function simply switches the y-axis to
#' `approval_rate`.
#'
#' @inheritParams visualize_cutoff_default
#'
#' @return A ggplot object.
#' @export
visualize_cutoff_approval <- function(tradeoff_data, score_col = NULL) {
  if (!is.null(score_col)) {
    tradeoff_data <- tradeoff_data %>%
      dplyr::filter(.data$score == score_col)
  }

  ggplot2::ggplot(tradeoff_data, ggplot2::aes(x = .data$cutoff, y = .data$approval_rate, color = .data$score)) +
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



#' Create a comparison visualization
#'
#' This function is intended for pre-aggregated comparison data where each row
#' summarizes the delta in approval and/or default rates for a given score or
#' strategy.
#'
#' When `metric = "both"`, it requires the optional `gridExtra` package to be
#' installed (see `Suggests` in DESCRIPTION). If `gridExtra` is not available,
#' you can still request the single-panel variants `"approval"` or `"default"`.
#'
#' @param comparison_data Comparison data with columns `score`,
#'   `approval_rate_change` and/or `default_rate_change`.
#' @param metric Metric to visualize (`"approval"`, `"default"`, or `"both"`).
#'
#' @return A ggplot object, or a combined grid of two plots when
#'   `metric = "both"`.
#' @export
visualize_comparison <- function(comparison_data, metric = c("both", "approval", "default")) {
  metric <- match.arg(metric)

  if (metric == "both") {
    if (!requireNamespace("gridExtra", quietly = TRUE)) {
      cli::cli_abort(
        "Package 'gridExtra' is required when {.code metric = \"both\"}. \\
         Please install it or set {.code metric} to \"approval\" or \"default\"."
      )
    }

    # Create a combined plot
    approval_plot <- ggplot2::ggplot(comparison_data, ggplot2::aes(x = .data$score, y = .data$approval_rate_change)) +
      ggplot2::geom_col(fill = "steelblue") +
      ggplot2::labs(title = "Change in Approval Rate", y = "Approval Rate Change") +
      ggplot2::theme_minimal()

    default_plot <- ggplot2::ggplot(comparison_data, ggplot2::aes(x = .data$score, y = .data$default_rate_change)) +
      ggplot2::geom_col(fill = "firebrick") +
      ggplot2::labs(title = "Change in Default Rate", y = "Default Rate Change") +
      ggplot2::theme_minimal()

    return(gridExtra::grid.arrange(approval_plot, default_plot, ncol = 2))
  } else if (metric == "approval") {
    ggplot2::ggplot(comparison_data, ggplot2::aes(x = .data$score, y = .data$approval_rate_change)) +
      ggplot2::geom_col(fill = "steelblue") +
      ggplot2::labs(title = "Change in Approval Rate", y = "Approval Rate Change") +
      ggplot2::theme_minimal()
  } else {
    ggplot2::ggplot(comparison_data, ggplot2::aes(x = .data$score, y = .data$default_rate_change)) +
      ggplot2::geom_col(fill = "firebrick") +
      ggplot2::labs(title = "Change in Default Rate", y = "Default Rate Change") +
      ggplot2::theme_minimal()
  }
}

#' Plot method for credit_risk_groups objects
#'
#' @param x A `credit_risk_groups` object returned by `find_risk_groups()`.
#' @param ... Unused, included for S3 method compatibility.
#'
#' @return A `ggplot` object (invisibly), after drawing the plot.
#' @export
plot.credit_risk_groups <- function(x, ...) {
  if (!inherits(x, "credit_risk_groups")) {
    cli::cli_abort("{.arg x} must be a {.cls credit_risk_groups} object.")
  }

  d <- x$data
  meta <- x$metadata %||% list()

  time_col <- meta$time_col
  default_col <- meta$default_col

  if (is.null(time_col) || !time_col %in% names(d)) {
    cli::cli_abort("Time column metadata is missing in {.cls credit_risk_groups} object.")
  }
  if (is.null(default_col) || !default_col %in% names(d)) {
    cli::cli_abort("Default column metadata is missing in {.cls credit_risk_groups} object.")
  }

  time_sym <- rlang::sym(time_col)
  default_sym <- rlang::sym(default_col)

  plot_data <- d %>%
    dplyr::filter(!is.na(.data$risk_rating)) %>%
    dplyr::group_by(.data$risk_rating, !!time_sym) %>%
    dplyr::summarise(
      vol = dplyr::n(),
      pd = mean(!!default_sym, na.rm = TRUE),
      .groups = "drop"
    )

  names(plot_data)[names(plot_data) == time_col] <- "time"

  p <- ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = .data$time, y = .data$pd, color = factor(.data$risk_rating), group = .data$risk_rating)
  ) +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::geom_point(size = 2) +
    ggplot2::scale_y_continuous(labels = scales::label_percent(accuracy = 0.1)) +
    ggplot2::labs(
      title = "PD Stability by Risk Rating",
      x = "Vintage",
      y = "Default Rate",
      color = "Risk Rating"
    ) +
    ggplot2::theme_minimal()

  print(p)
  invisible(p)
}

#' Plot method for simulate_from_data() results
#'
#' @param x A `creditools_simulation_from_data` object returned by
#'   `simulate_from_data()`.
#' @param ... Unused, included for S3 method compatibility.
#'
#' @return A `ggplot` object (invisibly), after drawing the plot.
#' @export
plot.creditools_simulation_from_data <- function(x, ...) {
  if (!inherits(x, "creditools_simulation_from_data")) {
    cli::cli_abort("{.arg x} must be a {.cls creditools_simulation_from_data} object.")
  }

  summary <- x$summary
  if (is.null(summary) || !"scenario" %in% names(summary)) {
    cli::cli_abort("The object passed to {.fn plot} does not contain a valid summary table.")
  }

  summary <- summary %>%
    dplyr::mutate(
      scenario = factor(.data$scenario, levels = c("keep_in", "swap_in", "swap_out", "keep_out"))
    )

  p <- ggplot2::ggplot(summary, ggplot2::aes(x = .data$scenario, y = .data$Hired, fill = .data$scenario)) +
    ggplot2::geom_col(alpha = 0.85) +
    ggplot2::geom_text(
      ggplot2::aes(label = scales::percent(.data$Bad_Rate, accuracy = 0.01)),
      vjust = -0.3,
      size = 3
    ) +
    ggplot2::scale_y_continuous(labels = scales::comma) +
    ggplot2::labs(
      title = "Scenario Composition and Bad Rate",
      x = "Scenario",
      y = "Hired Volume",
      fill = "Scenario"
    ) +
    ggplot2::theme_minimal()

  print(p)
  invisible(p)
}
