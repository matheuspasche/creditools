# Internal environment for package state
existing_warnings <- new.env(parent = emptyenv())
existing_warnings$warned_no_stress <- FALSE

#' Run a credit policy simulation with multiple stages
#'
#' @description
#' This is the main entry point for running a multi-stage simulation. It takes
#' a dataset and a `credit_policy` object, then applies the defined sequential
#' stages in the policy to simulate new approval decisions and their outcomes.
#'
#' @param data A data frame containing applicant data. Must include columns
#'   specified in the `credit_policy` object.
#' @param policy A `credit_policy` object created by `credit_policy()`, with
#'   a list of stages created by `stage_cutoff()` or `stage_rate()`.
#' @param method The simulation method: `"stochastic"` (default) for row-by-row sampling
#'   or `"analytical"` for expected value calculation (reweighting).
#' @param quiet Whether to suppress progress and status messages. Default is FALSE.
#'
#' @return A `credit_sim_results` object, which is a list containing the
#'   simulation `$data` (a data frame) and `$metadata` (a list with the policy
#'   object used in the simulation).
#' @family simulation
#' @export
#'
run_simulation <- function(data,
                           policy,
                           method = c("stochastic", "analytical"),
                           quiet = FALSE) {
  method <- match.arg(method)

  if (!quiet) {
    if (requireNamespace("cli", quietly = TRUE)) {
      cli::cli_h1("Creditools: Multi-Stage Credit Policy Simulation")
    }
  }

  # 1. Validation
  validate_simulation_inputs(data, policy)

  # 2. Sequential execution of stages
  stage_approval_cols <- list()
  data$pass_prob_funnel <- 1.0 # Tracks the cumulative pass probability

  if (length(policy$simulation_stages) > 0) {
    if (!quiet) {
      if (requireNamespace("cli", quietly = TRUE)) {
        cli::cli_alert_info("Simulating funnel stages (n = {length(policy$simulation_stages)})")
      }
    }

    if (!quiet) {
      pb <- try(cli::cli_progress_bar("Running stages", total = length(policy$simulation_stages)), silent = TRUE)
    }

    for (i in seq_along(policy$simulation_stages)) {
      stage <- policy$simulation_stages[[i]]
      if (!quiet) {
        if (requireNamespace("cli", quietly = TRUE)) {
          cli::cli_alert_info("Simulating stage {i}: {stage$name}")
        }
      }
      if (!quiet && exists("pb") && !inherits(pb, "try-error")) {
        try(cli::cli_progress_update(id = pb), silent = TRUE)
      }

      stage_res <- simulate_stage(data, stage, policy, method = method)
      stage_output_col <- paste0("stage_", i, "_", stage$name)
      stage_approval_cols <- c(stage_approval_cols, stage_output_col)

      data[[stage_output_col]] <- stage_res

      # The column should represent the probability of PASSING THE FUNNEL UP TO THIS STAGE
      data$pass_prob_funnel <- data$pass_prob_funnel * data[[stage_output_col]]
      data[[stage_output_col]] <- data$pass_prob_funnel
    }
  }

  # Determine final approval status under the new policy
  if (method == "stochastic") {
    if (length(stage_approval_cols) == 0) {
      data$new_approval <- rep(1L, nrow(data))
    } else {
      # Use pass_prob_funnel directly for stochastic as well if it's already binary in that mode
      # But to be safe and consistent with previous logic:
      final_approval_flags <- purrr::map(data[unlist(stage_approval_cols)], function(col) col == 1 & !is.na(col))
      data$new_approval <- as.integer(Reduce(`&`, final_approval_flags))
    }
  } else {
    # In analytical mode, new_approval IS the pass_prob_funnel
    data$new_approval <- data$pass_prob_funnel
  }

  data$pass_prob_funnel <- NULL # cleanup

  # Classify scenarios based on old vs. new final approval
  data <- classify_scenarios(data, policy, "new_approval")

  # Assign default outcomes for the newly approved population
  data <- assign_simulated_defaults(data, policy, method = method)

  if (!quiet && exists("pb") && !inherits(pb, "try-error")) {
    try(cli::cli_progress_done(id = pb), silent = TRUE)
  }

  if (!quiet) {
    if (requireNamespace("cli", quietly = TRUE)) {
      cli::cli_alert_success("Multi-stage simulation completed for {nrow(data)} applicants.")
    }
  }

  # Structure the output
  results <- structure(
    list(
      data = data,
      metadata = list(
        policy = policy,
        timestamp = Sys.time()
      )
    ),
    class = "credit_sim_results"
  )

  return(results)
}

#' Generic function to simulate a single stage
#' @return A numeric or integer vector of simulated stage outcomes.
#' @keywords internal
#' @export
simulate_stage <- function(data, stage, policy, method = c("stochastic", "analytical")) {
  UseMethod("simulate_stage", stage)
}

#' Simulate a cutoff-based stage
#' @keywords internal
#' @exportS3Method simulate_stage stage_cutoff
simulate_stage.stage_cutoff <- function(data, stage, policy, method = c("stochastic", "analytical")) {
  method <- match.arg(method)
  # Logical AND across all defined cutoffs in the stage
  results <- purrr::map(seq_along(stage$cutoffs), function(i) {
    col <- names(stage$cutoffs)[i]
    val <- stage$cutoffs[[i]]
    as.integer(data[[col]] >= val)
  })

  final_binary <- Reduce(`&`, results)

  if (method == "stochastic") {
    return(as.integer(final_binary))
  } else {
    return(as.numeric(final_binary))
  }
}

#' Simulate a logical filter stage
#' @keywords internal
#' @exportS3Method simulate_stage stage_filter
simulate_stage.stage_filter <- function(data, stage, policy, method = c("stochastic", "analytical")) {
  method <- match.arg(method)
  # Evaluate condition in the context of the data
  cond_call <- str2lang(stage$condition)

  final_binary <- tryCatch(
    {
      as.integer(eval(cond_call, envir = data))
    },
    error = function(e) {
      cli::cli_abort("Failed to evaluate filter condition: {.val {stage$condition}}", parent = e)
    }
  )

  # Handle NAs as 0 (rejected)
  final_binary[is.na(final_binary)] <- 0L

  if (method == "stochastic") {
    return(as.integer(final_binary))
  } else {
    return(as.numeric(final_binary))
  }
}

#' Simulate a rate-based stage (e.g., Conversion or Anti-Fraud)
#' @keywords internal
#' @exportS3Method simulate_stage stage_rate
simulate_stage.stage_rate <- function(data, stage, policy, method = c("stochastic", "analytical")) {
  method <- match.arg(method)
  base_prob <- stage$base_rate

  # If a variable is provided, we multiply the base_rate by that variable.
  # This allows for dynamic rates based on data.
  if (!is.null(stage$variable)) {
    # If the variable is a column name, use it. If not, assume it's a numeric constant.
    mult <- if (stage$variable %in% names(data)) data[[stage$variable]] else as.numeric(stage$variable)
    probs <- pmin(pmax(base_prob * mult, 0), 1)
  } else {
    probs <- rep(base_prob, nrow(data))
  }

  if (method == "stochastic") {
    return(as.integer(stats::runif(nrow(data)) < probs))
  } else {
    return(as.numeric(probs))
  }
}

#' Validate inputs for simulation
#' @keywords internal
validate_simulation_inputs <- function(data, policy) {
  if (!is.data.frame(data)) {
    cli::cli_abort("{.arg data} must be a data frame.")
  }
  if (!inherits(policy, "credit_policy")) {
    cli::cli_abort("{.arg policy} must be a {.cls credit_policy} object.")
  }

  # Check that all required columns exist in data
  required_cols <- c(
    policy$applicant_id_col,
    policy$current_approval_col,
    policy$actual_default_col,
    policy$score_cols
  )

  # Check columns inside stages
  stage_cols <- purrr::map(policy$simulation_stages, function(s) {
    if (s$type == "cutoff") {
      return(names(s$cutoffs))
    }
    return(NULL)
  }) %>% unlist()

  required_cols <- unique(c(required_cols, stage_cols))
  missing_cols <- setdiff(required_cols, names(data))

  if (length(missing_cols) > 0) {
    cli::cli_abort("Missing required columns in data: {.var {missing_cols}}")
  }

  return(TRUE)
}

#' Classify applicants into transition scenarios
#' @keywords internal
classify_scenarios <- function(data, policy, new_approval_col) {
  # Pre-allocate result vector
  n <- nrow(data)
  res <- rep(NA_character_, n)

  # Extract columns
  old_app <- data[[policy$current_approval_col]]
  new_app <- data[[new_approval_col]]

  # Handle NAs and cast to binary flag for categorization
  # In analytical mode, anyone with > 0 pass probability is "approved" for categorization
  # The actual intensity is handled by weights in summary functions.
  old_app_flag <- as.integer(old_app > 0)
  new_app_flag <- as.integer(new_app > 0)

  old_app_flag[is.na(old_app_flag)] <- 0
  new_app_flag[is.na(new_app_flag)] <- 0

  # Vectorized assignments
  res[old_app_flag == 0 & new_app_flag == 1] <- "swap_in"
  res[old_app_flag == 1 & new_app_flag == 0] <- "swap_out"
  res[old_app_flag == 1 & new_app_flag == 1] <- "keep_in"
  res[old_app_flag == 0 & new_app_flag == 0] <- "keep_out"

  data$scenario <- res
  return(data)
}


#' Assign default outcomes for the final approved population
#' @return The data frame with a new `simulated_default` column.
#' @keywords internal
assign_simulated_defaults <- function(data, policy, method = c("stochastic", "analytical"), quiet = FALSE) {
  method <- match.arg(method)
  swap_in_defaults <- simulate_swap_in_defaults(data, policy, method = method, quiet = quiet)

  if (nrow(swap_in_defaults) > 0) {
    data <- dplyr::left_join(data, swap_in_defaults, by = policy$applicant_id_col)
  } else {
    data$swap_in_default <- NA_integer_
  }

  data$simulated_default <- dplyr::case_when(
    data$scenario == "keep_in" ~ data[[policy$actual_default_col]],
    data$scenario == "swap_in" ~ data$swap_in_default,
    TRUE ~ NA_integer_
  )

  data$swap_in_default <- NULL
  return(data)
}

#' Simulate default outcomes for swap-in applicants
#' @return A tibble with `applicant_id_col` and `swap_in_default` columns.
#' @keywords internal
simulate_swap_in_defaults <- function(data, policy, method = c("stochastic", "analytical"), quiet = FALSE) {
  method <- match.arg(method)
  swap_ins <- data[data$scenario == "swap_in" & !is.na(data$scenario), ]

  if (nrow(swap_ins) == 0) {
    return(tibble::tibble())
  }

  if (length(policy$stress_scenarios) == 0) {
    if (!isTRUE(existing_warnings$warned_no_stress) && !quiet) {
      if (requireNamespace("cli", quietly = TRUE)) {
        cli::cli_alert_warning("No stress scenarios defined for swap-in defaults. Default outcomes will be NA.")
      }
      existing_warnings$warned_no_stress <- TRUE
    }
    res_df <- tibble::tibble(
      tmp_id = swap_ins[[policy$applicant_id_col]],
      swap_in_default = NA_real_
    )
    colnames(res_df)[1] <- policy$applicant_id_col
    return(res_df)
  }

  # Calculate probability for each stress scenario
  prob_matrix <- purrr::map_dfc(seq_along(policy$stress_scenarios), function(seq_idx) {
    scenario <- policy$stress_scenarios[[seq_idx]]
    res <- switch(scenario$type,
      "aggravation" = calc_prob_aggravation(data, policy, scenario),
      "monotonic_increase" = calc_prob_monotonic(swap_ins, scenario$score_col, scenario),
      "custom" = scenario$func(swap_ins),
      cli::cli_abort("Unknown stress scenario type: {scenario$type}")
    )
    col_name <- paste0("prob_", seq_idx)
    tibble::tibble(!!col_name := res)
  })

  # Aggregate probabilities across scenarios
  # For now, we take the maximum probability as a conservative estimate
  # This could be made configurable in the future.
  final_probs <- apply(prob_matrix, 1, max, na.rm = TRUE)

  if (method == "stochastic") {
    outcomes <- stats::runif(nrow(swap_ins)) < final_probs
    res_df <- tibble::tibble(
      tmp_id = swap_ins[[policy$applicant_id_col]],
      swap_in_default = as.integer(outcomes)
    )
  } else {
    res_df <- tibble::tibble(
      tmp_id = swap_ins[[policy$applicant_id_col]],
      swap_in_default = final_probs
    )
  }

  colnames(res_df)[1] <- policy$applicant_id_col
  return(res_df)
}

#' Calculate stressed default probability via aggravation factor
#' @keywords internal
calc_prob_aggravation <- function(data, policy, scenario) {
  # Get historical default outcomes for approved population
  # We use the risk_level_col grouping if defined
  swap_ins <- data[data$scenario == "swap_in" & !is.na(data$scenario), ]

  if (!is.null(scenario$by) && scenario$by %in% names(data)) {
    # Calculate historical PD per segment
    historical_pds <- data %>%
      dplyr::filter(.data[[policy$current_approval_col]] == 1) %>%
      dplyr::group_by(.data[[scenario$by]]) %>%
      dplyr::summarise(hist_pd = mean(.data[[policy$actual_default_col]], na.rm = TRUE), .groups = "drop")

    # Map back to swap-ins
    res <- swap_ins %>%
      dplyr::left_join(historical_pds, by = scenario$by) %>%
      dplyr::mutate(stressed_pd = pmin(.data$hist_pd * scenario$factor, 1)) %>%
      dplyr::pull(.data$stressed_pd)

    # Fill NAs with global historical PD
    global_pd <- mean(data[[policy$actual_default_col]][data[[policy$current_approval_col]] == 1], na.rm = TRUE)
    res[is.na(res)] <- pmin(global_pd * scenario$factor, 1)
  } else {
    # Use global historical PD
    global_pd <- mean(data[[policy$actual_default_col]][data[[policy$current_approval_col]] == 1], na.rm = TRUE)
    res <- rep(pmin(global_pd * scenario$factor, 1), nrow(swap_ins))
  }

  return(res)
}

#' Calculate default probability for monotonic increase stress
#' @keywords internal
calc_prob_monotonic <- function(swap_ins, score_col, scenario) {
  # Map score to probability linearly
  # Higher score = lower probability
  # But we apply a baseline shift + factor
  scores <- swap_ins[[score_col]]
  # Simple linear interpolation for demonstration
  # This could be improved with a proper sigmoid
  res <- pmin(pmax(scenario$baseline - (scores / 1000) * scenario$factor, 0), 1)
  return(res)
}
