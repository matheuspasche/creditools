#' Find optimal cutoffs for multiple scores
#'
#' @param data Input data
#' @param config Simulation configuration
#' @param cutoff_steps Step size for cutoff exploration
#' @param target_default_rate Maximum acceptable default rate
#' @param min_approval_rate Minimum acceptable approval rate
#' @param parallel Whether to use parallel processing
#' @param n_cores Number of cores for parallel processing
#'
#' @return Data frame with optimal cutoffs and metrics
#' @export
find_optimal_cutoffs <- function(data, config,
                                 cutoff_steps = 10,
                                 target_default_rate = 0.05,
                                 min_approval_rate = 0.3,
                                 parallel = FALSE,
                                 n_cores = NULL) {

  # Validate inputs
  validate_optimization_inputs(data, config, cutoff_steps, target_default_rate, min_approval_rate)

  # Generate cutoff ranges for each score
  cutoff_ranges <- generate_cutoff_ranges(data, config$score_columns, cutoff_steps)

  # Evaluate all cutoff combinations
  results <- evaluate_cutoff_combinations(
    data, config, cutoff_ranges, target_default_rate, min_approval_rate, parallel, n_cores
  )

  # Find optimal cutoffs
  optimal_results <- find_optimal_results(results, target_default_rate, min_approval_rate)

  # Add metadata
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

#' Validate optimization inputs
#' @keywords internal
validate_optimization_inputs <- function(data, config, cutoff_steps, target_default_rate, min_approval_rate) {
  if (!is.data.frame(data)) {
    cli::cli_abort("{.arg data} must be a data frame")
  }

  if (cutoff_steps < 1) {
    cli::cli_abort("{.arg cutoff_steps} must be at least 1")
  }

  if (target_default_rate < 0 || target_default_rate > 1) {
    cli::cli_abort("{.arg target_default_rate} must be between 0 and 1")
  }

  if (min_approval_rate < 0 || min_approval_rate > 1) {
    cli::cli_abort("{.arg min_approval_rate} must be between 0 and 1")
  }

  # Check if required columns exist
  required_cols <- c(
    config$current_approval_col,
    config$actual_default_col,
    config$risk_level_col,
    config$score_columns,
    paste0(config$score_columns, "_min")
  )

  missing_cols <- setdiff(required_cols, names(data))
  if (length(missing_cols) > 0) {
    cli::cli_abort("Missing required columns: {missing_cols}")
  }
}

#' Generate cutoff ranges for all scores
#' @keywords internal
generate_cutoff_ranges <- function(data, score_columns, cutoff_steps) {
  purrr::map(score_columns, function(score_col) {
    score_values <- data[[score_col]]
    min_val <- floor(min(score_values, na.rm = TRUE))
    max_val <- ceiling(max(score_values, na.rm = TRUE))

    # Create sequence based on step size
    if (cutoff_steps == 1) {
      # Use median if only one step
      stats::median(score_values, na.rm = TRUE)
    } else {
      seq(min_val, max_val, length.out = cutoff_steps)
    }
  }) %>% purrr::set_names(score_columns)
}

#' Evaluate all cutoff combinations
#' @keywords internal
evaluate_cutoff_combinations <- function(data, config, cutoff_ranges,
                                         target_default_rate, min_approval_rate,
                                         parallel = FALSE, n_cores = NULL) {

  # Create all combinations of cutoffs
  cutoff_combinations <- expand.grid(cutoff_ranges) %>%
    tibble::as_tibble() %>%
    dplyr::mutate(combination_id = dplyr::row_number())

  cli::cli_alert_info("Evaluating {nrow(cutoff_combinations)} cutoff combinations")

  # Setup parallel processing if requested
  if (parallel) {
    if (!requireNamespace("future", quietly = TRUE) ||
        !requireNamespace("furrr", quietly = TRUE)) {
      cli::cli_alert_warning("Parallel processing requires future and furrr packages. Using sequential processing.")
      parallel <- FALSE
    } else {
      n_cores <- n_cores %||% future::availableCores() - 1
      future::plan(future::multisession, workers = n_cores)
      on.exit(future::plan(future::sequential))
    }
  }

  # Evaluate each combination
  if (parallel) {
    results <- furrr::future_map_dfr(
      1:nrow(cutoff_combinations),
      ~ evaluate_single_combination(.x, cutoff_combinations, data, config, target_default_rate, min_approval_rate),
      .progress = TRUE,
      .options = furrr::furrr_options(seed = TRUE)
    )
  } else {
    # Sequential processing with progress bar
    results <- purrr::map_dfr(
      1:nrow(cutoff_combinations),
      ~ evaluate_single_combination(.x, cutoff_combinations, data, config, target_default_rate, min_approval_rate),
      .progress = TRUE
    )
  }

  return(results)
}

#' Evaluate a single cutoff combination
#' @keywords internal
evaluate_single_combination <- function(combo_id, cutoff_combinations, data, config,
                                        target_default_rate, min_approval_rate) {

  # Get cutoffs for this combination
  cutoffs <- cutoff_combinations[combo_id, ] %>%
    dplyr::select(-combination_id) %>%
    as.list()

  # Apply cutoffs to data
  data_with_cutoffs <- data
  for (score_col in names(cutoffs)) {
    cutoff_col <- paste0(score_col, "_min")
    data_with_cutoffs[[cutoff_col]] <- cutoffs[[score_col]]
  }

  # Run simulation
  results <- simulate_credit_process(data_with_cutoffs, config)

  # Calculate metrics
  metrics <- calculate_metrics(results, config)

  # Check if constraints are satisfied
  constraints_met <- all(
    metrics$overall_default_rate <= target_default_rate,
    metrics$overall_approval_rate >= min_approval_rate
  )

  # Create result row
  result_row <- tibble::tibble(
    combination_id = combo_id,
    overall_approval_rate = metrics$overall_approval_rate,
    overall_default_rate = metrics$overall_default_rate,
    constraints_met = constraints_met,
    tradeoff_score = calculate_tradeoff_score(metrics$overall_approval_rate, metrics$overall_default_rate)
  )

  # Add cutoff values
  for (score_col in names(cutoffs)) {
    result_row[[paste0("cutoff_", score_col)]] <- cutoffs[[score_col]]
  }

  return(result_row)
}

#' Calculate performance metrics from simulation results
#' @keywords internal
calculate_metrics <- function(results, config) {
  data <- results$data

  # Calculate overall approval rate (average of all scores)
  approval_rates <- purrr::map_dbl(config$score_columns, function(score_col) {
    final_approval_col <- get_final_approval_col(config$simulation_stages, score_col)
    mean(data[[final_approval_col]], na.rm = TRUE)
  })

  # Calculate overall default rate (average of all scores)
  default_rates <- purrr::map_dbl(config$score_columns, function(score_col) {
    default_col <- paste0("default_simulated_", score_col)
    mean(data[[default_col]], na.rm = TRUE)
  })

  list(
    overall_approval_rate = mean(approval_rates, na.rm = TRUE),
    overall_default_rate = mean(default_rates, na.rm = TRUE),
    approval_rates = approval_rates,
    default_rates = default_rates
  )
}

#' Calculate tradeoff score between approval and default rates
#' @keywords internal
calculate_tradeoff_score <- function(approval_rate, default_rate) {
  # Simple tradeoff: approval rate minus weighted default rate
  # You can customize this function based on business requirements
  approval_rate - (5 * default_rate)  # Weight default rate 5x more than approval rate
}

#' Find optimal results based on constraints and tradeoff score
#' @keywords internal
find_optimal_results <- function(results, target_default_rate, min_approval_rate) {
  # Filter results that meet constraints
  valid_results <- results %>%
    dplyr::filter(
      overall_default_rate <= target_default_rate,
      overall_approval_rate >= min_approval_rate
    )

  if (nrow(valid_results) == 0) {
    cli::cli_alert_warning("No cutoff combinations meet the specified constraints")
    cli::cli_alert_info("Relaxing constraints to find nearest solutions")

    # Find results that are closest to meeting constraints
    valid_results <- results %>%
      dplyr::mutate(
        default_distance = abs(overall_default_rate - target_default_rate),
        approval_distance = abs(overall_approval_rate - min_approval_rate),
        total_distance = default_distance + approval_distance
      ) %>%
      dplyr::arrange(total_distance) %>%
      dplyr::slice(1:5)  # Top 5 closest solutions
  }

  # Find the result with the highest tradeoff score
  optimal_result <- valid_results %>%
    dplyr::arrange(dplyr::desc(tradeoff_score)) %>%
    dplyr::slice(1)

  return(optimal_result)
}

#' Analyze trade-offs between approval and default rates
#'
#' @param opt_results Optimization results from find_optimal_cutoffs
#' @param by_score Whether to analyze trade-offs by individual score
#'
#' @return List with trade-off analysis results
#' @export
analyze_tradeoffs <- function(opt_results, by_score = FALSE) {
  if (!inherits(opt_results, "credit_opt_results")) {
    cli::cli_abort("{.arg opt_results} must be from {.fn find_optimal_cutoffs}")
  }

  # Get all evaluation results
  results <- attr(opt_results, "evaluation_results")
  cutoff_ranges <- attr(opt_results, "cutoff_ranges")
  params <- attr(opt_results, "optimization_params")

  # Overall trade-off analysis
  overall_analysis <- results %>%
    dplyr::select(overall_approval_rate, overall_default_rate, tradeoff_score) %>%
    dplyr::distinct() %>%
    dplyr::arrange(overall_approval_rate, overall_default_rate)

  # Find Pareto frontier
  pareto_front <- find_pareto_frontier(overall_analysis)

  # Analyze by score if requested
  score_analysis <- NULL
  if (by_score && length(cutoff_ranges) > 1) {
    score_analysis <- analyze_tradeoffs_by_score(results, cutoff_ranges)
  }

  # Create result object
  analysis_results <- list(
    overall_analysis = overall_analysis,
    pareto_frontier = pareto_front,
    score_analysis = score_analysis,
    optimization_params = params,
    optimal_result = opt_results
  )

  class(analysis_results) <- "credit_tradeoff_analysis"

  return(analysis_results)
}

#' Find Pareto frontier of non-dominated solutions
#' @keywords internal
find_pareto_frontier <- function(analysis_data) {
  # Sort by approval rate (ascending) and default rate (descending)
  sorted_data <- analysis_data %>%
    dplyr::arrange(overall_approval_rate, dplyr::desc(overall_default_rate))

  # Initialize Pareto frontier
  pareto_front <- sorted_data[1, ]

  # Find non-dominated solutions
  for (i in 2:nrow(sorted_data)) {
    current_row <- sorted_data[i, ]
    is_dominated <- FALSE

    for (j in 1:nrow(pareto_front)) {
      frontier_row <- pareto_front[j, ]

      # Check if current solution is dominated
      if (current_row$overall_approval_rate <= frontier_row$overall_approval_rate &&
          current_row$overall_default_rate >= frontier_row$overall_default_rate) {
        is_dominated = TRUE
        break
      }
    }

    if (!is_dominated) {
      # Remove any solutions dominated by the current one
      pareto_front <- pareto_front %>%
        dplyr::filter(
          !(overall_approval_rate >= current_row$overall_approval_rate &&
              overall_default_rate <= current_row$overall_default_rate)
        )

      # Add current solution to Pareto frontier
      pareto_front <- dplyr::bind_rows(pareto_front, current_row)
    }
  }

  return(pareto_front %>% dplyr::arrange(overall_approval_rate))
}

#' Analyze trade-offs by individual score
#' @keywords internal
analyze_tradeoffs_by_score <- function(results, cutoff_ranges) {
  score_names <- names(cutoff_ranges)

  purrr::map(score_names, function(score_col) {
    cutoff_col <- paste0("cutoff_", score_col)

    # Extract results for this score
    score_results <- results %>%
      dplyr::select(
        cutoff = !!cutoff_col,
        approval_rate = overall_approval_rate,
        default_rate = overall_default_rate,
        tradeoff_score
      ) %>%
      dplyr::distinct() %>%
      dplyr::arrange(cutoff)

    # Find optimal cutoff for this score
    optimal_cutoff <- score_results %>%
      dplyr::arrange(dplyr::desc(tradeoff_score)) %>%
      dplyr::slice(1)

    list(
      score_name = score_col,
      results = score_results,
      optimal_cutoff = optimal_cutoff,
      cutoff_range = cutoff_ranges[[score_col]]
    )
  }) %>% purrr::set_names(score_names)
}

#' Visualize trade-off analysis
#'
#' @param analysis_results Trade-off analysis results
#' @param type Type of visualization ("tradeoff", "pareto", "by_score")
#'
#' @return ggplot object
#' @export
visualize_tradeoffs <- function(analysis_results, type = "tradeoff") {
  if (!inherits(analysis_results, "credit_tradeoff_analysis")) {
    cli::cli_abort("{.arg analysis_results} must be from {.fn analyze_tradeoffs}")
  }

  switch(type,
         "tradeoff" = create_tradeoff_plot(analysis_results),
         "pareto" = create_pareto_plot(analysis_results),
         "by_score" = create_by_score_plot(analysis_results),
         cli::cli_abort("Unknown visualization type: {type}")
  )
}

#' Create trade-off scatter plot
#' @keywords internal
create_tradeoff_plot <- function(analysis_results) {
  plot_data <- analysis_results$overall_analysis

  ggplot2::ggplot(plot_data, ggplot2::aes(x = overall_approval_rate, y = overall_default_rate)) +
    ggplot2::geom_point(alpha = 0.6) +
    ggplot2::geom_point(
      data = analysis_results$optimal_result,
      color = "red",
      size = 3
    ) +
    ggplot2::labs(
      title = "Approval vs Default Rate Trade-off",
      x = "Approval Rate",
      y = "Default Rate"
    ) +
    ggplot2::theme_minimal()
}

#' Create Pareto frontier plot
#' @keywords internal
create_pareto_plot <- function(analysis_results) {
  plot_data <- analysis_results$overall_analysis
  pareto_data <- analysis_results$pareto_frontier

  ggplot2::ggplot(plot_data, ggplot2::aes(x = overall_approval_rate, y = overall_default_rate)) +
    ggplot2::geom_point(alpha = 0.3, color = "gray") +
    ggplot2::geom_line(data = pareto_data, color = "blue", size = 1) +
    ggplot2::geom_point(
      data = analysis_results$optimal_result,
      color = "red",
      size = 3
    ) +
    ggplot2::labs(
      title = "Pareto Frontier of Optimal Solutions",
      x = "Approval Rate",
      y = "Default Rate"
    ) +
    ggplot2::theme_minimal()
}

#' Create by-score visualization
#' @keywords internal
create_by_score_plot <- function(analysis_results) {
  if (is.null(analysis_results$score_analysis)) {
    cli::cli_abort("Score analysis not available. Run analyze_tradeoffs with by_score = TRUE")
  }

  # Prepare data for faceting
  score_data <- purrr::map_dfr(analysis_results$score_analysis, function(score_analysis) {
    score_analysis$results %>%
      dplyr::mutate(score_name = score_analysis$score_name)
  })

  ggplot2::ggplot(score_data, ggplot2::aes(x = cutoff, y = tradeoff_score)) +
    ggplot2::geom_line() +
    ggplot2::facet_wrap(~score_name, scales = "free_x") +
    ggplot2::labs(
      title = "Trade-off Score by Cutoff and Score",
      x = "Cutoff Value",
      y = "Trade-off Score"
    ) +
    ggplot2::theme_minimal()
}
