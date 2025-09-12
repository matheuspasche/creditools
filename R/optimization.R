#' Analyze trade-offs between approval rates and default rates
#'
#' @param data Input data
#' @param config Simulation configuration
#' @param cutoffs_range Range of cutoffs to evaluate
#' @param n_points Number of points to evaluate
#' @param parallel Whether to use parallel processing
#' @param n_cores Number of cores for parallel processing
#'
#' @return Data frame with trade-off metrics
#' @export
analyze_tradeoffs <- function(data, config, cutoffs_range = c(300, 850),
                              n_points = 50, parallel = FALSE, n_cores = NULL) {

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

  # Evaluate each score INDIVIDUALLY with its own config
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
        .progress = TRUE
      )
    } else {
      score_results <- purrr::map_dfr(
        cutoffs,
        ~ {
          data_temp <- data_prepared
          data_temp[[cutoff_col]] <- .x
          evaluate_single_cutoff(data_temp, single_score_config, score_col)
        },
        .progress = TRUE
      )
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

#' Evaluate a specific cutoff
#' @keywords internal
evaluate_cutoff <- function(data, config, score_col, cutoff) {
  # Create a copy of the data with the current cutoff
  data_with_cutoff <- data
  cutoff_col <- paste0(score_col, "_min")
  data_with_cutoff[[cutoff_col]] <- cutoff

  # Run simulation
  results <- simulate_credit_process(
    data_with_cutoff, config, parallel = FALSE, show_progress = FALSE
  )

  # Calculate metrics
  final_approval_col <- get_final_approval_col(config$simulation_stages, score_col)
  default_col <- paste0("default_simulated_", score_col)

  approval_rate <- mean(results$data[[final_approval_col]], na.rm = TRUE)
  default_rate <- mean(results$data[[default_col]], na.rm = TRUE)

  # Return results
  tibble::tibble(
    cutoff = cutoff,
    approval_rate = approval_rate,
    default_rate = default_rate
  )
}

#' Calculate trade-off metrics
#'
#' @param tradeoff_data Trade-off analysis results
#'
#' @return Data frame with trade-off metrics
#' @export
calculate_tradeoff_metrics <- function(tradeoff_data) {
  tradeoff_data %>%
    dplyr::group_by(score) %>%
    dplyr::arrange(cutoff) %>%
    dplyr::mutate(
      approval_change = approval_rate - dplyr::lag(approval_rate),
      default_change = default_rate - dplyr::lag(default_rate),
      tradeoff_ratio = ifelse(approval_change != 0, default_change / approval_change, NA),
      marginal_benefit = ifelse(default_change != 0, approval_change / default_change, NA)
    ) %>%
    dplyr::ungroup()
}
