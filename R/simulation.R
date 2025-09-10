#' Execute credit process simulation
#'
#' @param data Input data
#' @param config Simulation configuration
#' @param parallel Whether to use parallel processing
#' @param n_cores Number of cores for parallel processing
#'
#' @return Simulation results
#' @export
simulate_credit_process <- function(data, config, parallel = FALSE, n_cores = NULL) {
  # Validate inputs
  validate_config(config)

  if (!is.data.frame(data)) {
    cli::cli_abort("{.arg data} must be a data frame")
  }

  # Check for required columns
  required_cols <- c(
    config$current_approval_col,
    config$actual_default_col,
    config$risk_level_col,
    config$score_columns
  )

  # Add cutoff columns if needed
  cutoff_cols <- paste0(config$score_columns, "_min")
  required_cols <- c(required_cols, cutoff_cols)

  missing_cols <- setdiff(required_cols, names(data))
  if (length(missing_cols) > 0) {
    cli::cli_abort("Missing required columns in data: {missing_cols}")
  }

  # Start timing
  start_time <- Sys.time()
  cli::cli_alert_info("Starting simulation with {length(config$score_columns)} score(s)")

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

  # Process each score
  if (parallel) {
    results <- furrr::future_map(
      config$score_columns,
      ~ evaluate_score(data, .x, config),
      .options = furrr::furrr_options(seed = TRUE)
    )
  } else {
    results <- purrr::map(
      config$score_columns,
      ~ evaluate_score(data, .x, config)
    )
  }

  # Combine results
  combined_results <- purrr::reduce(
    results,
    ~ dplyr::left_join(.x, .y, by = config$applicant_id_col),
    .init = data
  )

  # Add metadata
  metadata <- list(
    run_time = Sys.time() - start_time,
    n_applicants = nrow(data),
    n_scores = length(config$score_columns),
    config = config
  )

  result_obj <- list(data = combined_results, metadata = metadata)
  class(result_obj) <- "credit_sim_results"

  cli::cli_alert_success("Simulation completed in {round(metadata$run_time, 2)} seconds")

  return(result_obj)
}

#' Evaluate a specific score
#' @keywords internal
evaluate_score <- function(data, score_col, config) {
  # Prepare column names
  col_names <- prepare_column_names(score_col)

  # Calculate approval by new score
  data <- data %>%
    calculate_new_approval(score_col, col_names$new_approval)

  # Apply all simulation stages
  data <- purrr::reduce(
    config$simulation_stages,
    function(data, stage_config) {
      apply_simulation_stage(data, stage_config, col_names$new_approval, score_col, config)
    },
    .init = data
  )

  # Classify scenarios based on final approval
  final_approval_col <- get_final_approval_col(config$simulation_stages, score_col)
  data <- data %>%
    classify_scenarios(
      config$current_approval_col,
      final_approval_col,
      col_names$scenario
    )

  # Calculate simulated defaults
  data <- data %>%
    simulate_defaults(score_col, config, col_names)

  # Select only relevant columns
  data %>%
    dplyr::select(
      dplyr::all_of(config$applicant_id_col),
      dplyr::all_of(col_names$new_approval),
      dplyr::all_of(get_stage_cols(config$simulation_stages, score_col)),
      dplyr::all_of(col_names$scenario),
      dplyr::all_of(col_names$simulated_default)
    )
}

#' Apply a simulation stage
#' @keywords internal
apply_simulation_stage <- function(data, stage_config, approval_col, score_col, config) {
  stage_name <- stage_config$name
  stage_col <- paste0(stage_name, "_", score_col)

  switch(stage_config$type,
         "threshold" = apply_threshold_stage(data, stage_config, approval_col, stage_col, score_col),
         "random_removal" = apply_random_removal_stage(data, stage_config, approval_col, stage_col),
         "keep_in_based" = apply_keep_in_based_stage(data, stage_config, approval_col, stage_col, config, score_col),
         "variable_based" = apply_variable_based_stage(data, stage_config, approval_col, stage_col),
         cli::cli_abort("Unknown simulation stage type: {stage_config$type}")
  )
}

#' Apply threshold-based simulation stage
#' @keywords internal
apply_threshold_stage <- function(data, stage_config, approval_col, stage_col, score_col) {
  cutoff_col <- paste0(score_col, "_min")

  data %>%
    dplyr::mutate(
      !!stage_col := as.integer(.data[[approval_col]] == 1 &
                                  .data[[score_col]] >= .data[[cutoff_col]])
    )
}

#' Apply random removal simulation stage
#' @keywords internal
apply_random_removal_stage <- function(data, stage_config, approval_col, stage_col) {
  data %>%
    dplyr::mutate(
      !!stage_col := dplyr::case_when(
        .data[[approval_col]] == 0 ~ 0L,
        .data[[approval_col]] == 1 ~ as.integer(stats::runif(dplyr::n()) < stage_config$approval_rate),
        TRUE ~ NA_integer_
      )
    )
}

#' Apply keep_in-based simulation stage
#' @keywords internal
apply_keep_in_based_stage <- function(data, stage_config, approval_col, stage_col, config, score_col) {
  # Calculate rates from keep_ins
  if (is.null(stage_config$grouping_vars)) {
    stage_config$grouping_vars <- config$risk_level_col
  }

  # Use the current score's approval for reference if not specified
  if (is.null(stage_config$reference_column)) {
    stage_config$reference_column <- paste0("approval_", score_col)
  }

  keep_in_rates <- data %>%
    dplyr::filter(.data[[config$current_approval_col]] == 1) %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(stage_config$grouping_vars))) %>%
    dplyr::summarise(
      keep_in_rate = mean(.data[[stage_config$reference_column]], na.rm = TRUE),
      .groups = "drop"
    )

  # Apply rates with optional aggravation
  data <- data %>%
    dplyr::left_join(keep_in_rates, by = stage_config$grouping_vars) %>%
    dplyr::mutate(
      aggravated_rate = keep_in_rate * (stage_config$aggravation_factor %||% 1),
      !!stage_col := dplyr::case_when(
        .data[[approval_col]] == 0 ~ 0L,
        .data[[approval_col]] == 1 ~ as.integer(stats::runif(dplyr::n()) < aggravated_rate),
        TRUE ~ NA_integer_
      )
    ) %>%
    dplyr::select(-keep_in_rate, -aggravated_rate)

  return(data)
}

#' Apply variable-based simulation stage
#' @keywords internal
apply_variable_based_stage <- function(data, stage_config, approval_col, stage_col) {
  data %>%
    dplyr::mutate(
      !!stage_col := dplyr::case_when(
        .data[[approval_col]] == 0 ~ 0L,
        .data[[approval_col]] == 1 ~ as.integer(.data[[stage_config$variable]] >= stage_config$threshold),
        TRUE ~ NA_integer_
      )
    )
}

#' Get final approval column name
#' @keywords internal
get_final_approval_col <- function(simulation_stages, score_col) {
  if (length(simulation_stages) == 0) {
    return(paste0("approval_", score_col))
  }

  last_stage <- simulation_stages[[length(simulation_stages)]]
  paste0(last_stage$name, "_", score_col)
}

#' Get all stage column names
#' @keywords internal
get_stage_cols <- function(simulation_stages, score_col) {
  purrr::map_chr(simulation_stages, ~ paste0(.x$name, "_", score_col))
}

#' Prepare column names
#' @keywords internal
prepare_column_names <- function(score_col) {
  list(
    new_approval = paste0("approval_", score_col),
    scenario = paste0("scenario_", score_col),
    simulated_default = paste0("default_simulated_", score_col)
  )
}

#' Calculate approval by new score
#' @keywords internal
calculate_new_approval <- function(data, score_col, new_approval_col) {
  cutoff_col <- paste0(score_col, "_min")

  data %>%
    dplyr::mutate(
      !!new_approval_col := as.integer(.data[[score_col]] >= .data[[cutoff_col]])
    )
}

#' Classify scenarios
#' @keywords internal
classify_scenarios <- function(data, current_approval_col, final_approval_col, scenario_col) {
  data %>%
    dplyr::mutate(
      !!scenario_col := dplyr::case_when(
        .data[[current_approval_col]] == 0 & .data[[final_approval_col]] == 1 ~ "swap_in",
        .data[[current_approval_col]] == 1 & .data[[final_approval_col]] == 0 ~ "swap_out",
        .data[[current_approval_col]] == 1 & .data[[final_approval_col]] == 1 ~ "keep_in",
        .data[[current_approval_col]] == 0 & .data[[final_approval_col]] == 0 ~ "keep_out",
        TRUE ~ NA_character_
      )
    )
}

#' Simulate defaults
#' @keywords internal
simulate_defaults <- function(data, score_col, config, col_names) {
  # Calculate base rates by risk level from keep_ins
  base_rates <- data %>%
    dplyr::filter(.data[[col_names$scenario]] == "keep_in") %>%
    dplyr::group_by(.data[[config$risk_level_col]]) %>%
    dplyr::summarise(
      base_rate = mean(.data[[config$actual_default_col]], na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::mutate(
      aggravated_rate = base_rate * config$aggravation_factors[.data[[config$risk_level_col]]]
    )

  # Join base rates with main data
  data <- data %>%
    dplyr::left_join(base_rates, by = config$risk_level_col)

  # Simulate default only for swap_ins and keep_ins
  data %>%
    dplyr::mutate(
      !!col_names$simulated_default := dplyr::case_when(
        # Keep observed default for keep_ins
        .data[[col_names$scenario]] == "keep_in" ~ .data[[config$actual_default_col]],

        # Simulate default for swap_ins with aggravation
        .data[[col_names$scenario]] == "swap_in" ~ as.integer(stats::runif(dplyr::n()) < .data$aggravated_rate),

        # NA for swap_out and keep_out (not approved)
        TRUE ~ NA_integer_
      )
    ) %>%
    dplyr::select(-base_rate, -aggravated_rate)
}
