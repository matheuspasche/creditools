#' Find optimal cutoffs for a credit policy stage
#'
#' @description
#' This function systematically evaluates a grid of cutoff combinations for a set
#' of scores to find the optimal set of cutoffs that maximizes a trade-off
#' score while respecting given constraints on default and approval rates.
#'
#' @details
#' The optimization works by modifying a base `credit_policy` object. For each
#' combination of cutoffs, it creates a new `stage_cutoff` and inserts it as the
#' first stage of the simulation funnel. It then runs the full multi-stage
#' simulation and evaluates the final metrics.
#'
#' @param data A data frame containing applicant data.
#' @param config A base `credit_policy` object. The optimization will add a
#'   `stage_cutoff` to this policy for each iteration.
#' @param cutoff_steps The number of steps to create for each score's cutoff range.
#'   The range is from the min to the max score in the data.
#' @param target_default_rate The maximum acceptable overall default rate for the approved population.
#' @param min_approval_rate The minimum acceptable overall approval rate.
#' @param parallel A logical flag indicating whether to use parallel processing.
#'   Requires the `future` and `furrr` packages.
#' @param n_cores The number of cores to use for parallel processing. Defaults to
#'   all available cores minus one.
#'
#' @return A data frame with the single best combination of cutoffs found, along
#'   with its performance metrics. The full evaluation results are available in
#'   the `evaluation_results` attribute of the returned object.
#' @export
find_optimal_cutoffs <- function(data, config,
                                 cutoff_steps = 10,
                                 target_default_rate = 0.05,
                                 min_approval_rate = 0.3,
                                 parallel = FALSE,
                                 n_cores = NULL) {

  validate_optimization_inputs(data, config, cutoff_steps, target_default_rate, min_approval_rate)

  # Generate cutoff ranges for each score defined in the base policy
  cutoff_ranges <- generate_cutoff_ranges(data, config$score_columns, cutoff_steps)

  # Evaluate all cutoff combinations
  results <- evaluate_cutoff_combinations(
    data, config, cutoff_ranges, target_default_rate, min_approval_rate, parallel, n_cores
  )

  # Find the best result from the evaluations
  optimal_results <- find_optimal_results(results, target_default_rate, min_approval_rate)

  # Add metadata for further analysis
  attr(optimal_results, "evaluation_results") <- results
  attr(optimal_results, "cutoff_ranges") <- cutoff_ranges
  attr(optimal_results, "optimization_params") <- list(
    target_default_rate = target_default_rate,
    min_approval_rate = min_approval_rate,
    cutoff_steps = cutoff_steps
  )

  class(optimal_results) <- c("credit_opt_results", class(optimal_results))

  return(optimal_results)
}

#' @keywords internal
validate_optimization_inputs <- function(data, config, cutoff_steps, target_default_rate, min_approval_rate) {
  if (!is.data.frame(data)) cli::cli_abort("{.arg data} must be a data frame")
  if (!inherits(config, "credit_policy")) cli::cli_abort("{.arg config} must be a credit_policy object")
  if (cutoff_steps < 1) cli::cli_abort("{.arg cutoff_steps} must be at least 1")
  if (target_default_rate < 0 || target_default_rate > 1) cli::cli_abort("{.arg target_default_rate} must be between 0 and 1")
  if (min_approval_rate < 0 || min_approval_rate > 1) cli::cli_abort("{.arg min_approval_rate} must be between 0 and 1")

  required_cols <- c(
    config$current_approval_col,
    config$actual_default_col,
    config$score_columns
  )
  if (!is.null(config$risk_level_col)) required_cols <- c(required_cols, config$risk_level_col)

  missing_cols <- setdiff(required_cols, names(data))
  if (length(missing_cols) > 0) {
    cli::cli_abort("Missing required columns in data: {missing_cols}")
  }
}

#' @keywords internal
generate_cutoff_ranges <- function(data, score_columns, cutoff_steps) {
  purrr::map(score_columns, function(score_col) {
    score_values <- data[[score_col]]
    min_val <- floor(min(score_values, na.rm = TRUE))
    max_val <- ceiling(max(score_values, na.rm = TRUE))

    if (cutoff_steps == 1) {
      stats::median(score_values, na.rm = TRUE)
    } else {
      seq(min_val, max_val, length.out = cutoff_steps)
    }
  }) %>% purrr::set_names(score_columns)
}

#' @keywords internal
evaluate_cutoff_combinations <- function(data, config, cutoff_ranges,
                                         target_default_rate, min_approval_rate,
                                         parallel = FALSE, n_cores = NULL) {
  cutoff_combinations <- expand.grid(cutoff_ranges) %>%
    tibble::as_tibble() %>%
    dplyr::mutate(combination_id = dplyr::row_number())

  cli::cli_alert_info("Evaluating {nrow(cutoff_combinations)} cutoff combinations...")

  if (parallel) {
    if (!requireNamespace("future", quietly = TRUE) || !requireNamespace("furrr", quietly = TRUE)) {
      cli::cli_alert_warning("Parallel processing requires 'future' and 'furrr'. Using sequential processing.")
      parallel <- FALSE
    } else {
      n_cores <- n_cores %||% (future::availableCores() - 1)
      future::plan(future::multisession, workers = n_cores)
      on.exit(future::plan(future::sequential))
    }
  }

  eval_fun <- if (parallel) furrr::future_map_dfr else purrr::map_dfr
  
  results <- eval_fun(
    1:nrow(cutoff_combinations),
    ~ evaluate_single_combination(.x, cutoff_combinations, data, config, target_default_rate, min_approval_rate),
    .progress = TRUE,
    .options = if (parallel) furrr::furrr_options(seed = TRUE) else NULL
  )

  return(results)
}

#' @keywords internal
evaluate_single_combination <- function(combo_id, cutoff_combinations, data, config,
                                        target_default_rate, min_approval_rate) {
  cutoffs <- cutoff_combinations[combo_id, ] %>%
    dplyr::select(-combination_id) %>%
    as.list()

  # Create a temporary policy for this run, adding a cutoff stage for this iteration.
  # This assumes the cutoff stage is the first stage to be applied.
  temp_policy <- config
  cutoff_stage <- stage_cutoff(name = "optimization_credit", cutoffs = cutoffs)
  temp_policy$simulation_stages <- c(list(cutoff_stage), temp_policy$simulation_stages)

  # Run the full multi-stage simulation
  sim_results <- run_simulation(data, temp_policy)

  # Calculate performance metrics from the final simulation results
  metrics <- calculate_metrics(sim_results)

  constraints_met <- all(
    metrics$overall_default_rate <= target_default_rate,
    metrics$overall_approval_rate >= min_approval_rate,
    !is.na(metrics$overall_default_rate)
  )

  result_row <- tibble::tibble(
    combination_id = combo_id,
    overall_approval_rate = metrics$overall_approval_rate,
    overall_default_rate = metrics$overall_default_rate,
    constraints_met = constraints_met,
    tradeoff_score = calculate_tradeoff_score(metrics$overall_approval_rate, metrics$overall_default_rate)
  )

  # Add cutoff values to the result row
  result_row <- dplyr::bind_cols(result_row, tibble::as_tibble(cutoffs))

  return(result_row)
}

#' @keywords internal
calculate_metrics <- function(sim_data) {
  # Calculate overall approval rate from the final `new_approval` flag
  approval_rate <- mean(sim_data$new_approval, na.rm = TRUE)

  # Filter for the population that was actually approved under the new policy
  approved_population <- sim_data[sim_data$new_approval == TRUE & !is.na(sim_data$new_approval), ]

  # Calculate default rate ONLY on the approved population
  if (nrow(approved_population) > 0) {
    default_rate <- mean(approved_population$simulated_default, na.rm = TRUE)
  } else {
    default_rate <- 0 # No one approved, so 0 defaults
  }

  list(
    overall_approval_rate = approval_rate,
    overall_default_rate = default_rate
  )
}

#' @keywords internal
calculate_tradeoff_score <- function(approval_rate, default_rate) {
  # Return NA if inputs are NA, to avoid errors in optimization
  if (is.na(approval_rate) || is.na(default_rate)) {
    return(NA_real_)
  }
  # Simple tradeoff: approval rate minus weighted default rate
  approval_rate - (5 * default_rate)
}

#' @keywords internal
find_optimal_results <- function(results, target_default_rate, min_approval_rate) {
  valid_results <- results %>%
    dplyr::filter(.data$constraints_met == TRUE)

  if (nrow(valid_results) == 0) {
    cli::cli_alert_warning("No cutoff combinations met the specified constraints. Returning the best-effort result.")
    # If no combination is valid, find the one with the highest tradeoff score among all results
    # This might be a high-risk or low-approval option, but it's the "best" found
    return(
      results %>%
        dplyr::arrange(dplyr::desc(.data$tradeoff_score)) %>%
        dplyr::slice(1)
    )
  }

  # From the valid results, find the one with the highest tradeoff score
  optimal_result <- valid_results %>%
    dplyr::arrange(dplyr::desc(.data$tradeoff_score)) %>%
    dplyr::slice(1)

  return(optimal_result)
}

#' Analyze trade-offs between approval and default rates
#'
#' @param opt_results Optimization results from `find_optimal_cutoffs`.
#' @return A list containing the overall analysis, the Pareto frontier, and
#'   the optimal result.
#' @export
analyze_tradeoffs <- function(opt_results) {
  if (!inherits(opt_results, "credit_opt_results")) {
    cli::cli_abort("{.arg opt_results} must be from {.fn find_optimal_cutoffs}")
  }

  results <- attr(opt_results, "evaluation_results")
  params <- attr(opt_results, "optimization_params")

  overall_analysis <- results %>%
    dplyr::select(.data$overall_approval_rate, .data$overall_default_rate, .data$tradeoff_score) %>%
    dplyr::distinct() %>%
    dplyr::filter(!is.na(.data$overall_approval_rate) & !is.na(.data$overall_default_rate)) %>%
    dplyr::arrange(.data$overall_approval_rate, .data$overall_default_rate)

  pareto_front <- find_pareto_frontier(overall_analysis)

  analysis_results <- list(
    overall_analysis = overall_analysis,
    pareto_frontier = pareto_front,
    optimization_params = params,
    optimal_result = opt_results
  )

  class(analysis_results) <- "credit_tradeoff_analysis"
  return(analysis_results)
}

#' @keywords internal
find_pareto_frontier <- function(analysis_data) {
  # Sort by one objective ascending, the other descending
  sorted_data <- analysis_data %>%
    dplyr::arrange(.data$overall_approval_rate, dplyr::desc(.data$overall_default_rate))
  
  pareto_front <- sorted_data[0, ] # Initialize empty frontier
  
  max_approval_so_far <- -Inf
  
  for (i in 1:nrow(sorted_data)) {
    # If this point has a higher approval rate than any previous point on the frontier,
    # it must be part of the frontier because it's the "best" on that axis so far.
    # Because the data is sorted by approval rate, this check simplifies finding the frontier.
    if (sorted_data$overall_approval_rate[i] > max_approval_so_far) {
      pareto_front <- rbind(pareto_front, sorted_data[i, ])
      max_approval_so_far <- sorted_data$overall_approval_rate[i]
    }
  }
  
  return(pareto_front)
}


#' Visualize trade-off analysis
#'
#' @param analysis_results Trade-off analysis results from `analyze_tradeoffs`.
#' @param type The type of plot to generate: "tradeoff" for a scatter plot of
#'   all evaluated points, or "pareto" for the efficient frontier.
#'
#' @return A `ggplot` object.
#' @export
visualize_tradeoffs <- function(analysis_results, type = "tradeoff") {
  if (!inherits(analysis_results, "credit_tradeoff_analysis")) {
    cli::cli_abort("{.arg analysis_results} must be from {.fn analyze_tradeoffs}")
  }

  type <- match.arg(type, c("tradeoff", "pareto"))

  if (type == "tradeoff") {
    create_tradeoff_plot(analysis_results)
  } else {
    create_pareto_plot(analysis_results)
  }
}

#' @keywords internal
create_tradeoff_plot <- function(analysis_results) {
  plot_data <- analysis_results$overall_analysis
  optimal_point <- analysis_results$optimal_result

  ggplot2::ggplot(plot_data, ggplot2::aes(x = .data$overall_approval_rate, y = .data$overall_default_rate)) +
    ggplot2::geom_point(alpha = 0.5, color = "grey50") +
    ggplot2::geom_point(
      data = optimal_point,
      color = "red",
      size = 4,
      shape = 18
    ) +
    ggplot2::labs(
      title = "Approval vs. Default Rate Trade-off",
      subtitle = "Each point is a cutoff combination. Red diamond is the optimal result.",
      x = "Overall Approval Rate",
      y = "Overall Default Rate"
    ) +
    ggplot2::theme_minimal()
}

#' @keywords internal
create_pareto_plot <- function(analysis_results) {
  plot_data <- analysis_results$overall_analysis
  pareto_data <- analysis_results$pareto_frontier
  optimal_point <- analysis_results$optimal_result

  ggplot2::ggplot(plot_data, ggplot2::aes(x = .data$overall_approval_rate, y = .data.overall_default_rate)) +
    ggplot2::geom_point(alpha = 0.2, color = "grey70") +
    ggplot2::geom_line(data = pareto_data, color = "blue", size = 1) +
    ggplot2::geom_point(data = pareto_data, color = "blue", size = 2) +
    ggplot2::geom_point(
      data = optimal_point,
      color = "red",
      size = 4,
      shape = 18
    ) +
    ggplot2::labs(
      title = "Pareto Frontier of Optimal Solutions",
      subtitle = "The blue line represents the efficient frontier of non-dominated solutions.",
      x = "Overall Approval Rate",
      y = "Overall Default Rate"
    ) +
    ggplot2::theme_minimal()
}
