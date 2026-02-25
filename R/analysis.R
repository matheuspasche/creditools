#' Summarize simulation results
#'
#' @description
#' Calculates summary metrics from a `credit_sim_results` object, such as
#' volume and default rates, grouped by scenario and other optional variables.
#'
#' @param results A `credit_sim_results` object returned by `run_simulation()`.
#' @param by A character vector of column names to group the summary by, in
#'   addition to the default grouping by `scenario`.
#'
#' @return A data frame (tibble) with summary statistics, including columns
#'   for the grouping variables, `scenario`, `volume`, `total_approved`,
#'   `overall_approval_rate`, and `avg_default_rate_approved`.
#'
#' @importFrom dplyr group_by across all_of summarise n
#' @export
summarize_results <- function(results, by = NULL) {
  if (!inherits(results, "credit_sim_results")) {
    cli::cli_abort("{.arg results} must be a {.cls credit_sim_results} object from {.fn run_simulation}.")
  }

  data <- results$data
  policy <- results$metadata$policy

  # Validate 'by' columns if provided
  if (!is.null(by)) {
    missing_cols <- setdiff(by, names(data))
    if (length(missing_cols) > 0) {
      cli::cli_abort("Grouping variable(s) not found in the data: {missing_cols}")
    }
  }

  # Always group by scenario, and add any other requested columns
  grouping_vars <- c(by, "scenario")

  summary <- data %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(grouping_vars))) %>%
    dplyr::summarise(
      volume = dplyr::n(),
      total_approved = sum(.data$new_approval, na.rm = TRUE),
      # Note: Default rate is calculated only on the approved population
      avg_default_rate_approved = mean(.data$simulated_default[.data$new_approval == TRUE], na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::mutate(
      overall_approval_rate = .data$total_approved / .data$volume
    )

  # For groups where total_approved is 0, default rate is NaN. Replace with 0.
  summary$avg_default_rate_approved[is.nan(summary$avg_default_rate_approved)] <- 0

  return(summary)
}

# This function is no longer needed as the logic is simplified
# and doesn't depend on iterating through score-specific columns.
#' @keywords internal
get_final_approval_col <- function(simulation_stages, score_col) {
  .Deprecated(msg = "'get_final_approval_col' is deprecated and no longer used.")
  return(NULL)
}


#' Run a trade-off analysis simulation
#'
#' @description
#' This wrapper function automates the process of running multiple simulations
#' to analyze the trade-off between business and risk metrics across a range of
#' cutoff points and stress scenarios.
#'
#' @details
#' The function generates a grid of parameters based on the provided cutoff
#' points and stress scenarios. It then iterates through this grid, running a

#' full simulation for each combination.
#'
#' The core logic supports varying a single cutoff score across one or more
#' simulation stages and applying different stress scenarios. This is useful for
#' creating sensitivity analysis plots, like the "efficient frontier" between
#' approval rate and default rate.
#'
#' Parallel processing is supported via the `furrr` package. If `parallel` is
#' set to `TRUE`, the user must configure their parallel plan beforehand (e.g.,
#' using `plan(multisession)`).
#'
#' @param data A data frame containing the analytical base table with applicant data.
#' @param policy_stages A list of `credit_policy_stage` objects, as created by
#'   `stage_cutoff()` or `stage_rate()`. These represent the fixed parts of the
#'   decision funnel.
#' @param cutoff_col A character string specifying the name of the score column
#'   to which the varying cutoffs will be applied.
#' @param cutoff_points A numeric vector of cutoff values to test.
#' @param stress_scenarios A named list of stress scenarios to test. The names
#'   of the list elements are used to identify the scenarios in the output.
#'   Each element should be a list of stress objects (e.g., from
#'   `stress_aggravation()`).
#' @param parallel A logical flag. If `TRUE`, the simulation will run in
#'   parallel using `furrr`. Defaults to `FALSE`.
#' @param applicant_id_col,score_cols,current_approval_col,actual_default_col,risk_level_col
#'   Arguments passed directly to `credit_policy()` to map columns in the data.
#'
#' @return A data frame (tibble) summarizing the results for each parameter
#'   combination. It includes columns for the cutoff value, scenario name,
#'   approval rate, and default rate.
#'
#' @importFrom tidyr expand_grid
#' @importFrom purrr map2_dfr
#' @importFrom furrr future_map2_dfr
#' @importFrom rlang .data
#' @export
run_tradeoff_analysis <- function(data,
                                  policy_stages,
                                  cutoff_col,
                                  cutoff_points,
                                  stress_scenarios,
                                  applicant_id_col,
                                  score_cols,
                                  current_approval_col,
                                  actual_default_col,
                                  risk_level_col = NULL,
                                  parallel = FALSE) {

  if (!is.character(cutoff_col) || length(cutoff_col) != 1) {
    cli::cli_abort("{.arg cutoff_col} must be a single character string.")
  }
  if (!is.numeric(cutoff_points)) {
    cli::cli_abort("{.arg cutoff_points} must be a numeric vector.")
  }
  if (!is.list(stress_scenarios) || is.null(names(stress_scenarios))) {
    cli::cli_abort("{.arg stress_scenarios} must be a named list.")
  }

  # Create a grid of all combinations to test
  params_grid <- tidyr::expand_grid(
    cutoff = cutoff_points,
    scenario_name = names(stress_scenarios)
  )

  run_single_sim <- function(cutoff_value, scenario_name) {
    # Dynamically create the cutoff stage for the current iteration
    cutoff_stage <- stage_cutoff(
      name = paste0("cutoff_", cutoff_col),
      cutoffs = stats::setNames(list(cutoff_value), cutoff_col)
    )

    # Combine the fixed stages with the dynamic cutoff stage
    full_stages <- c(policy_stages, list(cutoff_stage))

    # Create the full policy object
    temp_policy <- credit_policy(
      applicant_id_col = applicant_id_col,
      score_cols = score_cols,
      current_approval_col = current_approval_col,
      actual_default_col = actual_default_col,
      risk_level_col = risk_level_col,
      simulation_stages = full_stages,
      stress_scenarios = stress_scenarios[[scenario_name]]
    )

    # Run the simulation
    sim_results <- run_simulation(
      data = data,
      policy = temp_policy
    )

    # Summarize the results
    # We calculate metrics manually here to be more direct than summarize_results
    final_data <- sim_results$data
    approved_pop <- final_data %>% dplyr::filter(.data$new_approval == TRUE)

    overall_approval_rate <- nrow(approved_pop) / nrow(final_data)
    avg_default_rate_approved <- if (nrow(approved_pop) > 0) {
      mean(approved_pop$simulated_default, na.rm = TRUE)
    } else {
      0
    }

    tibble::tibble(
      cutoff = cutoff_value,
      scenario = scenario_name,
      approval_rate = overall_approval_rate,
      default_rate = avg_default_rate_approved
    )
  }

  # Choose the mapping function based on the parallel flag
  map_fun <- if (parallel) furrr::future_map2_dfr else purrr::map2_dfr

  cli::cli_alert_info("Running {nrow(params_grid)} simulations...")
  
  simulation_outputs <- map_fun(
    .x = params_grid$cutoff,
    .y = params_grid$scenario_name,
    .f = run_single_sim,
    .progress = TRUE
  )

  cli::cli_alert_success("All simulations complete.")

  return(simulation_outputs)
}
