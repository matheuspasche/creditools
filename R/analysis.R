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
  # A robust check for analytical: does new_approval contain fractions?
  # In run_simulation, analytical results are always numeric [0,1]
  # We check if it's numeric and has any values that are NOT exactly 0 or 1.
  # Also check if it's explicitly numeric.
  is_analytical <- is.numeric(data$new_approval) &&
    (any(data$new_approval > 0 & data$new_approval < 1, na.rm = TRUE) ||
      any(data$simulated_default > 0 & data$simulated_default < 1, na.rm = TRUE))

  # If it's a baseline run with no rate stages, it might be all 0/1 but still numeric.
  # We check the method used in the metadata if available.
  if (is.numeric(data$new_approval) && !is_analytical) {
    if (!is.null(results$metadata$method) && results$metadata$method == "analytical") {
      is_analytical <- TRUE
    } else {
      # Fallback: if it's numeric and we are in a context that likely is analytical
      is_analytical <- TRUE
    }
  }

  # Validate 'by' columns if provided
  if (!is.null(by)) {
    missing_cols <- setdiff(by, names(data))
    if (length(missing_cols) > 0) {
      cli::cli_abort("Grouping variable(s) not found in the data: {missing_cols}")
    }
  }

  # Always group by scenario, and add any other requested columns
  grouping_vars <- c(by, "scenario")

  if (!is_analytical) {
    summary <- data %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(grouping_vars))) %>%
      dplyr::summarise(
        Applicants = dplyr::n(),
        Approved = sum(.data$new_approval, na.rm = TRUE),
        Hired = sum(.data$new_approval, na.rm = TRUE), # In Stochastic, Approved=Hired if no conversion stage
        # Note: Default rate is calculated only on the approved population
        Bad_Rate = mean(.data$simulated_default[.data$new_approval == 1], na.rm = TRUE),
        .groups = "drop"
      )
  } else {
    # Weighted summary for Analytical mode
    summary <- data %>%
      dplyr::group_by(dplyr::across(dplyr::all_of(grouping_vars))) %>%
      dplyr::summarise(
        Applicants = dplyr::n(),
        Approved = sum(.data$new_approval, na.rm = TRUE),
        Hired = sum(.data$new_approval, na.rm = TRUE),
        Bad_Rate = ifelse(sum(.data$new_approval, na.rm = TRUE) > 0,
          sum(.data$simulated_default * .data$new_approval, na.rm = TRUE) /
            sum(.data$new_approval, na.rm = TRUE),
          0
        ),
        .groups = "drop"
      )
  }

  # For groups where total_approved is 0, default rate is NaN. Replace with 0.
  summary$Bad_Rate[is.nan(summary$Bad_Rate)] <- 0

  return(summary)
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
#' - A parameter named `<stage_name>_base_rate` will dynamically update the
#'   `base_rate` of an existing `stage_rate` matching that name.
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
#' @param quiet Whether to suppress progress and status messages. Default is FALSE.
#'
#' @return A tibble with the results of all simulation runs, including columns for
#'   the varied parameters in `vary_params`, plus `approval_rate` and `default_rate`.
#'
#' @importFrom tidyr expand_grid
#' @importFrom purrr pmap_dfr
#' @importFrom furrr future_pmap_dfr
#' @importFrom rlang .data
#' @family analysis
#' @export
#'
#' @examples
#' \donttest{
#' data <- generate_sample_data(n_applicants = 1000)
#' policy <- credit_policy(
#'   applicant_id_col = "id",
#'   score_cols = "new_score",
#'   current_approval_col = "approved",
#'   actual_default_col = "defaulted"
#' )
#' vary <- list(new_score_cutoff = c(500, 600))
#' run_tradeoff_analysis(data, policy, vary)
#' }
run_tradeoff_analysis <- function(data,
                                  base_policy,
                                  vary_params,
                                  parallel = FALSE,
                                  quiet = FALSE) {
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

    # 3. Handle Dynamic Stage Base Rates (e.g., anti_fraud_base_rate)
    base_rate_params <- current_params[grepl("_base_rate$", names(current_params))]
    if (length(base_rate_params) > 0) {
      for (param_name in names(base_rate_params)) {
        stage_name_to_mod <- sub("_base_rate$", "", param_name)
        new_rate <- base_rate_params[[param_name]]

        for (i in seq_along(temp_policy$simulation_stages)) {
          if (temp_policy$simulation_stages[[i]]$name == stage_name_to_mod &&
            temp_policy$simulation_stages[[i]]$type == "rate") {
            temp_policy$simulation_stages[[i]]$base_rate <- new_rate
          }
        }
      }
    }

    # --- Run Simulation & Summarize ---
    sim_results <- run_simulation(
      data = data,
      policy = temp_policy,
      quiet = TRUE
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
    result_row <- tibble::as_tibble_row(current_params)
    result_row$approval_rate <- overall_approval_rate
    result_row$default_rate <- avg_default_rate_approved

    return(result_row)
  }

  simulation_outputs <- if (parallel) {
    furrr::future_pmap_dfr(
      .l = params_grid,
      .f = run_single_sim,
      .progress = !quiet,
      .options = furrr::furrr_options(globals = TRUE, packages = c("creditools", "dplyr"))
    )
  } else {
    purrr::pmap_dfr(
      .l = params_grid,
      .f = run_single_sim,
      .progress = !quiet
    )
  }

  if (!quiet) cli::cli_alert_success("All simulations complete.")

  return(simulation_outputs)
}


compare_policies <- function(sim_new, sim_old) {
  if (!inherits(sim_new, "credit_sim_results") || !inherits(sim_old, "credit_sim_results")) {
    cli::cli_abort("Both {.arg sim_new} and {.arg sim_old} must be {.cls credit_sim_results} objects.")
  }

  data_new <- sim_new$data
  data_old <- sim_old$data

  # Determine if analytical
  is_analytical <- inherits(data_new$new_approval, "numeric")

  # 1. Global Metrics
  if (!is_analytical) {
    # Stochastic
    app_new <- sum(data_new$new_approval, na.rm = TRUE)
    bad_new <- mean(data_new$simulated_default[data_new$new_approval == 1], na.rm = TRUE)

    app_old <- sum(data_old$new_approval, na.rm = TRUE)
    bad_old <- mean(data_old$simulated_default[data_old$new_approval == 1], na.rm = TRUE)
  } else {
    # Analytical
    app_new <- sum(data_new$new_approval, na.rm = TRUE)
    bad_new <- sum(data_new$simulated_default * data_new$new_approval, na.rm = TRUE) / pmax(app_new, 1)

    app_old <- sum(data_old$new_approval, na.rm = TRUE)
    bad_old <- sum(data_old$simulated_default * data_old$new_approval, na.rm = TRUE) / pmax(app_old, 1)
  }

  n_total <- nrow(data_new)
  metrics <- tibble::tibble(
    Metric = c("Approval Rate", "Bad Rate"),
    Old = c(app_old / n_total, bad_old),
    New = c(app_new / n_total, bad_new),
    Delta_Abs = c((app_new - app_old) / n_total, bad_new - bad_old),
    Delta_Rel = c((app_new / pmax(app_old, 1)) - 1, (bad_new / pmax(bad_old, 0.0001)) - 1)
  )

  # 2. Swap Analysis
  swaps <- summarize_results(sim_new)

  # Calculate Swap-In to Keep-In Ratio
  if ("scenario" %in% names(swaps)) {
    vol_si <- swaps$Approved[swaps$scenario == "swap_in"]
    vol_ki <- swaps$Approved[swaps$scenario == "keep_in"]
    vol_si <- if (length(vol_si) > 0) vol_si else 0
    vol_ki <- if (length(vol_ki) > 0) vol_ki else 0
    si_ki_ratio <- if (vol_ki > 0) vol_si / vol_ki else NA_real_
  } else {
    si_ki_ratio <- NA_real_
  }

  return(list(
    metrics = metrics,
    swaps = swaps,
    ratio = si_ki_ratio
  ))
}
