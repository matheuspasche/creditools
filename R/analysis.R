#' Analyze trade-offs between approval rates and default rates
#'
#' @param data Input data
#' @param config Simulation configuration
#' @param cutoffs_range Range of cutoffs to evaluate
#' @param n_points Number of points to evaluate
#' @param parallel Whether to use parallel processing
#' @param n_cores Number of cores for parallel processing
#' @param show_progress Whether to show progress bar
#'
#' @return Data frame with trade-off metrics
#' @export
analyze_tradeoffs <- function(data, config, cutoffs_range = c(300, 850),
                              n_points = 50, parallel = FALSE, n_cores = NULL,
                              show_progress = TRUE) {

  # Validate inputs
  if (!is.data.frame(data)) {
    cli::cli_abort("{.arg data} must be a data frame")
  }

  if (length(cutoffs_range) != 2 || cutoffs_range[1] >= cutoffs_range[2]) {
    cli::cli_abort("{.arg cutoffs_range} must be a vector of two values where the first is less than the second")
  }

  if (n_points < 2) {
    cli::cli_abort("{.arg n_points} must be at least 2")
  }

  cli::cli_alert_info("Analyzing trade-offs for {length(config$score_columns)} score(s)")

  # Generate cutoff sequence
  cutoffs <- seq(cutoffs_range[1], cutoffs_range[2], length.out = n_points)

  # Setup parallel processing if requested
  if (parallel) {
    if (!requireNamespace("future", quietly = TRUE) ||
        !requireNamespace("furrr", quietly = TRUE)) {
      cli::cli_alert_warning("Parallel processing requires future and furrr packages. Using sequential processing.")
      parallel <- FALSE
    } else {
      n_cores <- n_cores %||% future::availableCores() - 1
      future::plan(future::multisession, workers = n_cores)
      on.exit(future::plan(future::sequential), add = TRUE)
    }
  }

  # Evaluate each score
  results <- purrr::map_dfr(config$score_columns, function(score_col) {
    cli::cli_alert_info("Analyzing score: {score_col}")

    # Create individual config for this score
    single_score_config <- create_config(
      score_columns = score_col,
      current_approval_col = config$current_approval_col,
      actual_default_col = config$actual_default_col,
      risk_level_col = config$risk_level_col,
      aggravation_factors = config$aggravation_factors,
      simulation_stages = config$simulation_stages,
      applicant_id_col = config$applicant_id_col,
      date_col = config$date_col
    )

    # Prepare data with this score's cutoff column
    data_prepared <- data
    cutoff_col <- paste0(score_col, "_min")

    # Ensure the cutoff column exists
    if (!cutoff_col %in% names(data_prepared)) {
      data_prepared[[cutoff_col]] <- median(data_prepared[[score_col]], na.rm = TRUE)
    }

    # Evaluate each cutoff
    if (parallel) {
      score_results <- furrr::future_map_dfr(
        cutoffs,
        ~ {
          data_temp <- data_prepared
          data_temp[[cutoff_col]] <- .x
          evaluate_single_cutoff(data_temp, single_score_config, score_col)
        },
        .options = furrr::furrr_options(
          globals = TRUE,
          packages = "creditSimulator",
          seed = TRUE
        ),
        .progress = show_progress
      )
    } else {
      if (show_progress) {
        score_results <- purrr::map_dfr(
          cutoffs,
          ~ {
            data_temp <- data_prepared
            data_temp[[cutoff_col]] <- .x
            evaluate_single_cutoff(data_temp, single_score_config, score_col)
          },
          .progress = show_progress
        )
      } else {
        score_results <- purrr::map_dfr(
          cutoffs,
          ~ {
            data_temp <- data_prepared
            data_temp[[cutoff_col]] <- .x
            evaluate_single_cutoff(data_temp, single_score_config, score_col)
          }
        )
      }
    }

    score_results %>%
      dplyr::mutate(score = score_col)
  })

  cli::cli_alert_success("Trade-off analysis completed")

  return(results)
}

#' Evaluate a single cutoff for a specific score
#' @keywords internal
evaluate_single_cutoff <- function(data, config, score_col) {
  # Run simulation
  results <- simulate_credit_process(
    data, config, parallel = FALSE, show_progress = FALSE
  )

  # Calculate metrics
  final_approval_col <- get_final_approval_col(config$simulation_stages, score_col)
  default_col <- paste0("default_simulated_", score_col)

  approval_rate <- mean(results$data[[final_approval_col]], na.rm = TRUE)
  default_rate <- mean(results$data[[default_col]], na.rm = TRUE)

  # Return results
  tibble::tibble(
    cutoff = data[[paste0(score_col, "_min")]][1],
    approval_rate = approval_rate,
    default_rate = default_rate
  )
}

#' Apply suggested cutoffs to data
#'
#' @param data Input data
#' @param suggested_cutoffs Named vector or list of suggested cutoffs
#' @param config Simulation configuration
#'
#' @return Data frame with applied cutoffs
#' @export
apply_suggested_cutoffs <- function(data, suggested_cutoffs, config) {
  # Validate inputs
  if (!is.data.frame(data)) {
    cli::cli_abort("{.arg data} must be a data frame")
  }

  if (!is.list(suggested_cutoffs) && !is.vector(suggested_cutoffs)) {
    cli::cli_abort("{.arg suggested_cutoffs} must be a list or named vector")
  }

  # Apply each suggested cutoff
  data_with_cutoffs <- data

  for (score_col in names(suggested_cutoffs)) {
    cutoff_col <- paste0(score_col, "_min")
    data_with_cutoffs[[cutoff_col]] <- suggested_cutoffs[[score_col]]
  }

  # Run final simulation
  final_results <- simulate_credit_process(
    data_with_cutoffs, config, parallel = TRUE, show_progress = TRUE
  )

  return(final_results)
}

#' Find optimal cutoffs from trade-off analysis
#'
#' @param tradeoff_results Results from analyze_tradeoffs
#' @param optimization_criterion Criterion for optimization ("min_default", "max_approval", "balanced")
#' @param default_rate_threshold Maximum acceptable default rate (for "balanced" criterion)
#' @param approval_rate_threshold Minimum acceptable approval rate (for "balanced" criterion)
#'
#' @return Named vector with optimal cutoffs
#' @export
find_optimal_cutoffs <- function(tradeoff_results, optimization_criterion = "balanced",
                                 default_rate_threshold = 0.05, approval_rate_threshold = 0.3) {

  optimization_criterion <- match.arg(
    optimization_criterion,
    c("min_default", "max_approval", "balanced")
  )

  optimal_cutoffs <- tradeoff_results %>%
    dplyr::group_by(score) %>%
    dplyr::group_map(~ {
      score_data <- .x
      score_name <- .y$score

      switch(optimization_criterion,
             "min_default" = {
               # Find cutoff with minimum default rate
               optimal_row <- score_data[which.min(score_data$default_rate), ]
               optimal_cutoff <- optimal_row$cutoff
               names(optimal_cutoff) <- score_name
               optimal_cutoff
             },
             "max_approval" = {
               # Find cutoff with maximum approval rate
               optimal_row <- score_data[which.max(score_data$approval_rate), ]
               optimal_cutoff <- optimal_row$cutoff
               names(optimal_cutoff) <- score_name
               optimal_cutoff
             },
             "balanced" = {
               # Find cutoff that meets thresholds and has best trade-off
               valid_rows <- score_data %>%
                 dplyr::filter(
                   default_rate <= default_rate_threshold,
                   approval_rate >= approval_rate_threshold
                 )

               if (nrow(valid_rows) == 0) {
                 cli::cli_alert_warning("No cutoffs meet the criteria for {score_name}. Using best trade-off.")
                 # Calculate trade-off score (approval - 5*default)
                 valid_rows <- score_data %>%
                   dplyr::mutate(tradeoff_score = approval_rate - 5 * default_rate) %>%
                   dplyr::arrange(desc(tradeoff_score))
               } else {
                 # Calculate trade-off score for valid rows
                 valid_rows <- valid_rows %>%
                   dplyr::mutate(tradeoff_score = approval_rate - 5 * default_rate) %>%
                   dplyr::arrange(desc(tradeoff_score))
               }

               optimal_row <- valid_rows[1, ]
               optimal_cutoff <- optimal_row$cutoff
               names(optimal_cutoff) <- score_name
               optimal_cutoff
             }
      )
    }) %>%
    purrr::flatten_dbl()

  return(optimal_cutoffs)
}
