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
#' @family analysis
#' @export
#'
#' @examples
#' # This example builds on the one from ?run_simulation
#' sample_data <- generate_sample_data(n_applicants = 1000, seed = 42)
#' sample_data$new_score_decile <- dplyr::ntile(sample_data$new_score, 10)
#' my_policy <- credit_policy(
#'   applicant_id_col = "id",
#'   score_cols = c("old_score", "new_score"),
#'   current_approval_col = "approved",
#'   actual_default_col = "defaulted",
#'   risk_level_col = "new_score_decile",
#'   simulation_stages = list(
#'     stage_cutoff(name = "credit_score", cutoffs = list(new_score = 600))
#'   )
#' )
#' results <- run_simulation(data = sample_data, policy = my_policy)
#'
#' # Summarize results by scenario and risk decile
#' summarize_results(results, by = "new_score_decile")
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


#' Run a flexible trade-off analysis simulation
#'
#' @description
#' This powerful wrapper function automates running multiple simulations to
#' analyze trade-offs between business and risk metrics. It iterates over a grid
#' of parameters, dynamically modifying a base credit policy for each combination.
#'
#' @details
#' The function generates a parameter grid from the named list provided in
#' `vary_params`. It then iterates through this grid, running a full simulation
#' for each combination. The function intelligently modifies the policy based on
#' the names of the parameters in `vary_params`:
#'
#' - A parameter named `<score_name>_cutoff` will create or modify a
#'   `stage_cutoff` for that score.
#' - A parameter named `aggravation_factor` will create or modify a
#'   `stress_aggravation` scenario.
#'
#' This allows for complex sensitivity analyses (e.g., creating an "efficient
#' frontier" between approval rate and default rate) by varying multiple
#' business and risk levers simultaneously.
#'
#' Parallel processing is supported via the `furrr` package. If `parallel` is
#' `TRUE`, the user must configure their parallel plan beforehand (e.g.,
#' using `future::plan(future::multisession)`).
#'
#' @param data A data frame containing the analytical base table.
#' @param base_policy A `credit_policy` object that serves as the template for
#'   each simulation run.
#' @param vary_params A named list of parameters to vary. The function will create
#'   a grid of all combinations of these parameters. For example:
#'   `list(new_score_cutoff = seq(500, 600, 10), aggravation_factor = c(1.2, 1.5))`
#' @param parallel A logical flag. If `TRUE`, the simulation runs in parallel
#'   using `furrr`. Defaults to `FALSE`.
#'
#' @return A data frame (tibble) summarizing the results for each parameter
#'   combination. It includes columns for each varied parameter, plus
#'   `approval_rate` and `default_rate`.
#'
#' @importFrom tidyr expand_grid
#' @importFrom purrr pmap_dfr
#' @importFrom furrr future_pmap_dfr
#' @importFrom rlang .data
#' @family analysis
#' @export
#'
#' @examples
#' # 1. Generate sample data and create a base policy
#' sample_data <- generate_sample_data(n_applicants = 1000, seed = 42)
#' sample_data$new_score_decile <- dplyr::ntile(sample_data$new_score, 10)
#'
#' base_policy <- credit_policy(
#'   applicant_id_col = "id",
#'   score_cols = c("old_score", "new_score"),
#'   current_approval_col = "approved",
#'   actual_default_col = "defaulted",
#'   risk_level_col = "new_score_decile",
#'   simulation_stages = list(
#'     # A fixed anti-fraud stage for all simulations
#'     stage_rate(name = "anti_fraud", base_rate = 0.95)
#'   )
#' )
#'
#' # 2. Define parameters to vary
#' # We will test a few cutoff points and 2 stress scenarios
#' vary_params <- list(
#'   new_score_cutoff = seq(500, 700, by = 50),
#'   aggravation_factor = c(1.2, 1.5)
#' )
#'
#' # 3. Run the analysis
#' tradeoff_results <- run_tradeoff_analysis(
#'   data = sample_data,
#'   base_policy = base_policy,
#'   vary_params = vary_params,
#'   parallel = FALSE
#' )
#'
#' # 4. Plot the results
#' if (requireNamespace("ggplot2", quietly = TRUE) && requireNamespace("dplyr", quietly = TRUE)) {
#'   library(ggplot2)
#'   library(dplyr)
#'   tradeoff_results %>%
#'     mutate(Stress = paste0(round((aggravation_factor - 1) * 100), "% PD Aggravation")) %>%
#'     ggplot(aes(x = approval_rate, y = default_rate, color = Stress)) +
#'     geom_line() +
#'     geom_point() +
#'     labs(
#'       title = "Efficient Frontier: Approval vs. Default Rate",
#'       x = "Overall Approval Rate", y = "Average Default Rate"
#'     ) +
#'     theme_minimal()
#' }
run_tradeoff_analysis <- function(data,
                                  base_policy,
                                  vary_params,
                                  parallel = FALSE) {
  if (!inherits(base_policy, "credit_policy")) {
    cli::cli_abort("{.arg base_policy} must be a {.cls credit_policy} object.")
  }
  if (!is.list(vary_params) || is.null(names(vary_params)) || length(vary_params) == 0) {
    cli::cli_abort("{.arg vary_params} must be a non-empty named list.")
  }

  # Create a grid of all combinations to test
  params_grid <- tidyr::expand_grid(!!!vary_params)

  run_single_sim <- function(...) {
    # Capture the current combination of parameters
    current_params <- list(...)
    temp_policy <- base_policy

    # --- Dynamically Modify Policy ---

    # 1. Handle Cutoffs
    cutoff_params <- current_params[grepl("_cutoff$", names(current_params))]
    if (length(cutoff_params) > 0) {
      names(cutoff_params) <- sub("_cutoff$", "", names(cutoff_params))
      # Create a new cutoff stage with all cutoffs for this iteration
      dynamic_cutoff_stage <- stage_cutoff(
        name = "dynamic_cutoffs",
        cutoffs = cutoff_params
      )
      # Append to existing stages
      temp_policy$simulation_stages <- c(temp_policy$simulation_stages, list(dynamic_cutoff_stage))
    }

    # 2. Handle Stress Scenarios (example for aggravation_factor)
    if ("aggravation_factor" %in% names(current_params)) {
      # This assumes we are modifying the *first* stress scenario.
      # A more robust implementation could target scenarios by name.
      agg_stress <- stress_aggravation(
        factor = current_params$aggravation_factor,
        by = temp_policy$risk_level_col # Inherit grouping from base policy
      )
      # Replace or append stress scenarios
      temp_policy$stress_scenarios <- list(dynamic_stress = agg_stress)
    }

    # --- Run Simulation & Summarize ---
    sim_results <- run_simulation(
      data = data,
      policy = temp_policy
    )

    final_data <- sim_results$data
    approved_pop <- final_data %>% dplyr::filter(.data$new_approval == TRUE)

    overall_approval_rate <- if (nrow(final_data) > 0) nrow(approved_pop) / nrow(final_data) else 0
    avg_default_rate_approved <- if (nrow(approved_pop) > 0) {
      mean(approved_pop$simulated_default, na.rm = TRUE)
    } else {
      0
    }

    # Combine params with results
    result_row <- tibble::as_tibble(current_params)
    result_row$approval_rate <- overall_approval_rate
    result_row$default_rate <- avg_default_rate_approved

    return(result_row)
  }

  # Choose the mapping function based on the parallel flag
  map_fun <- if (parallel) furrr::future_pmap_dfr else purrr::pmap_dfr

  cli::cli_alert_info("Running {nrow(params_grid)} simulations...")

  simulation_outputs <- map_fun(
    .l = params_grid,
    .f = run_single_sim,
    .progress = TRUE
  )

  cli::cli_alert_success("All simulations complete.")

  return(simulation_outputs)
}
