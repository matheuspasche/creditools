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
#'
#' @return A `credit_sim_results` object, which is a list containing the
#'   simulation `$data` (a data frame) and `$metadata` (a list with the policy
#'   object used in the simulation).
#' @family simulation
#' @export
#'
#' @param method The simulation method: `"stochastic"` (default) for row-by-row sampling
#'   or `"analytical"` for expected value calculation (reweighting).
#' @param quiet Whether to suppress progress and status messages. Default is FALSE.
#'
#' @examples
#' # 1. Generate sample data
#' sample_data <- generate_sample_data(n_applicants = 1000, seed = 42)
#'
#' # 2. Define a multi-stage credit policy
#' # - Stage 1: Must pass a cutoff on the new_score
#' # - Stage 2: Must pass a simulated anti-fraud check (85% pass rate)
#' my_policy <- credit_policy(
#'   applicant_id_col = "id",
#'   score_cols = c("old_score", "new_score"),
#'   current_approval_col = "approved",
#'   actual_default_col = "defaulted",
#'   simulation_stages = list(
#'     stage_cutoff(name = "credit_score", cutoffs = list(new_score = 600)),
#'     stage_rate(name = "anti_fraud", base_rate = 0.85)
#'   ),
#'   stress_scenarios = list(
#'     stress_aggravation(factor = 1.3) # 30% default aggravation for swap-ins
#'   )
#' )
#'
#' # 3. Run the simulation
#' results <- run_simulation(data = sample_data, policy = my_policy)
#'
#' # 4. Summarize the results by scenario
#' summarize_results(results)
run_simulation <- function(data, policy, method = c("stochastic", "analytical"), quiet = FALSE) {
  method <- match.arg(method)
  validate_simulation_inputs(data, policy)

  # This will hold the logical vector of approvals at each stage
  stage_approval_cols <- list()
  # Initialize with full approval probability
  data$pass_prob_funnel <- rep(1.0, nrow(data))

  if (!quiet && length(policy$simulation_stages) > 0) {
    if (requireNamespace("cli", quietly = TRUE)) {
      cli::cli_alert_info("Simulating funnel stages (n = {length(policy$simulation_stages)})")
      pb <- try(cli::cli_progress_bar("Simulating funnel stages", total = length(policy$simulation_stages)), silent = TRUE)
    }
  }

  # Sequentially process each stage in the funnel
  for (i in seq_along(policy$simulation_stages)) {
    stage <- policy$simulation_stages[[i]]
    if (!quiet) {
      if (requireNamespace("cli", quietly = TRUE)) {
        cli::cli_alert_info("Simulating stage {i}: {stage$name}")
        if (exists("pb") && !inherits(pb, "try-error")) {
          try(cli::cli_progress_update(id = pb), silent = TRUE)
        }
      }
    }

    stage_output_col <- paste0("approved_", stage$name, "_new")
    stage_approval_cols[[i]] <- stage_output_col

    if (method == "stochastic") {
      # Eligibility for the current stage is passing all *previous* new stages
      if (i == 1) {
        is_eligible <- rep(TRUE, nrow(data))
      } else {
        prev_approvals <- purrr::map(data[unlist(stage_approval_cols[1:(i - 1)])], function(col) col == 1 & !is.na(col))
        is_eligible <- Reduce(`&`, prev_approvals)
      }

      data[[stage_output_col]] <- NA_integer_
      if (any(is_eligible)) {
        data[is_eligible, stage_output_col] <- simulate_stage(data[is_eligible, ], stage, policy, method = "stochastic")
      }
    } else {
      # Analytical mode: accumulate probabilities
      # pass_prob_funnel already initialized to 1.0

      # Probability of passing THIS stage
      # Store the INDIVIDUAL stage result in the column
      stage_res <- simulate_stage(data, stage, policy, method = "analytical")

      # Safety: ensure correct length
      if (length(stage_res) != nrow(data)) {
        if (length(stage_res) == 0) {
          stage_res <- rep(0, nrow(data))
        } else if (length(stage_res) == 1) {
          stage_res <- rep(stage_res, nrow(data))
        } else {
          stop("Stage simulator returned incorrect vector length.")
        }
      }

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
      final_approval_flags <- purrr::map(data[unlist(stage_approval_cols)], function(col) col == 1 & !is.na(col))
      data$new_approval <- as.integer(Reduce(`&`, final_approval_flags))
    }
  } else {
    # In analytical mode, new_approval IS the pass_prob_funnel
    data$new_approval <- data$pass_prob_funnel
    data$pass_prob_funnel <- NULL # cleanup
  }

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
  # Create a matrix of approval decisions for each score in this stage
  approval_matrix <- purrr::map_dfc(names(stage$cutoffs), function(score_col) {
    res <- data[[score_col]] >= stage$cutoffs[[score_col]]
    tibble::tibble(!!score_col := res)
  })

  # Applicant passes if they meet ALL cutoffs in the stage
  res <- apply(approval_matrix, 1, all)

  if (length(res) == 0 && nrow(data) > 0) {
    # If no cutoffs were defined, everyone passes this stage
    res <- rep(TRUE, nrow(data))
  }

  if (method == "analytical") {
    return(as.numeric(res))
  }
  return(as.integer(res))
}

#' Simulate a rate-based stage (e.g., conversion)
#' @keywords internal
#' @exportS3Method simulate_stage stage_rate
simulate_stage.stage_rate <- function(data, stage, policy, method = c("stochastic", "analytical")) {
  method <- match.arg(method)

  # Default to an empty vector of results
  stage_outcome <- integer(nrow(data))

  # If there's an observed outcome column, use it for "keep-ins" at this stage
  if (!is.null(stage$observed_outcome_col)) {
    # A "keep-in" for this stage is someone who was approved in the original policy
    # AND had a positive outcome observed for this specific stage.
    # CRITICAL: They must also be eligible based on the NEW funnel so far!
    is_original_approved <- data[[policy$current_approval_col]] == 1
    has_observed_outcome <- data[[stage$observed_outcome_col]] == 1

    # Eligibility for the NEW funnel so far
    if (method == "stochastic") {
      # In stochastic, eligibility is handled by the caller (Reduce &)
      # But we need to check if the caller passed us a subset with NA or 0
      # Wait, the caller filters 'data' before calling this.
      # So everyone passed to this function in stochastic mode is eligible.
      keep_in_idx <- which(is_original_approved & has_observed_outcome)
    } else {
      # In analytical mode, everyone is passed, so we check pass_prob_funnel > 0
      # Actually, new_approval here is cumulative_prob_so_far
      # We only treat as "keep-in" if they were historically approved AND pass the new funnel (p=1)
      # If p < 1, they are partly swap-ins. To keep it simple, we treat anyone
      # with p < 1 as a swap-in for the "new" portion.
      keep_in_idx <- which(is_original_approved & has_observed_outcome & data$pass_prob_funnel == 1)
    }

    if (length(keep_in_idx) > 0) {
      stage_outcome[keep_in_idx] <- 1
    }

    # "Swap-ins" for this stage are everyone else who is eligible
    if (method == "stochastic") {
      swap_in_idx <- which(!(is_original_approved & has_observed_outcome))
    } else {
      swap_in_idx <- which(data$pass_prob_funnel > 0 & !(seq_len(nrow(data)) %in% keep_in_idx))
    }
  } else {
    # If no observed data, everyone is a "swap-in" for this stage
    if (method == "stochastic") {
      swap_in_idx <- seq_len(nrow(data))
    } else {
      swap_in_idx <- which(data$pass_prob_funnel > 0)
    }
  }

  if (length(swap_in_idx) == 0) {
    return(stage_outcome)
  }

  swap_ins_data <- data[swap_in_idx, ]

  # Calculate the probability of a positive outcome for swap-ins
  if (!is.null(stage$stress_by_score)) {
    # Use monotonic stress logic if provided
    prob <- calc_prob_monotonic(
      swap_ins_data,
      stage$stress_by_score$score_col,
      stage$stress_by_score
    )
  } else {
    # Otherwise, use the flat base rate
    prob <- stage$base_rate
  }

  # If method is analytical, return probabilities [0, 1] for all rows
  if (method == "analytical") {
    analytical_prob <- numeric(nrow(data))
    # Keep-ins have prob = 1 (if they had observed outcome)
    if (exists("keep_in_idx")) {
      analytical_prob[keep_in_idx] <- 1
    }
    # Swap-ins have the calculated prob
    analytical_prob[swap_in_idx] <- prob
    return(analytical_prob)
  }

  # Stochastic mode: Simulate the outcome
  simulated_outcome <- as.integer(stats::runif(length(swap_in_idx)) < prob)
  stage_outcome[swap_in_idx] <- simulated_outcome

  return(stage_outcome)
}

#' Simulate a hard-filter stage (Binary Rules)
#' @keywords internal
#' @exportS3Method simulate_stage stage_filter
simulate_stage.stage_filter <- function(data, stage, policy, method = c("stochastic", "analytical")) {
  method <- match.arg(method)
  # Evaluate the string condition against the subset of eligible data
  # using base R eval to allow things like "idade > 18 & status == 'Válido'"
  tryCatch(
    {
      # Parse and evaluate inside the isolated data environment
      eval_result <- eval(parse(text = stage$condition), envir = data)

      # Convert to logical and handle unexpected outputs
      if (!is.logical(eval_result)) {
        cli::cli_abort("Condition '{stage$condition}' did not return a logical vector.")
      }

      # Handle NAs (treat as rejection if the evaluation produces NA)
      eval_result[is.na(eval_result)] <- FALSE

      # Return as integer (1 = Passed, 0 = Rejected)
      res <- as.integer(eval_result)
      if (method == "analytical") {
        return(as.numeric(res))
      }
      return(as.integer(res))
    },
    error = function(e) {
      cli::cli_abort(
        c(
          "Failed to evaluate filter condition '{stage$condition}' in stage '{stage$name}'.",
          "x" = "Error message: {e$message}",
          "i" = "Ensure all referenced variables exist in the applicant data."
        )
      )
    }
  )
}

#' Default simulator for unknown stage types
#' @keywords internal
simulate_stage.default <- function(data, stage, policy) {
  cli::cli_abort("Unknown simulation stage type: {.cls {class(stage)[1]}}")
  # Return vector of NAs with the correct size
  rep(NA_integer_, nrow(data))
}


# --- Helper and Core Logic Functions ---

#' Validate inputs for a simulation run
#' @return Boolean TRUE if valid, otherwise an error is thrown.
#' @keywords internal
validate_simulation_inputs <- function(data, policy) {
  if (!inherits(policy, "credit_policy")) {
    cli::cli_abort("{.arg policy} must be a {.cls credit_policy} object.")
  }
  if (!is.data.frame(data)) {
    cli::cli_abort("{.arg data} must be a data frame.")
  }
  # Relaxed: allow 0 stages (passes everyone)
  # Further validation for columns can be added here
  return(invisible(TRUE))
}


#' Classify scenarios based on current and new approval decisions
#' @return The data frame with a new `scenario` column.
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
assign_simulated_defaults <- function(data, policy, method = c("stochastic", "analytical")) {
  method <- match.arg(method)
  swap_in_defaults <- simulate_swap_in_defaults(data, policy, method = method)

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
simulate_swap_in_defaults <- function(data, policy, method = c("stochastic", "analytical")) {
  method <- match.arg(method)
  swap_ins <- data[data$scenario == "swap_in" & !is.na(data$scenario), ]

  if (nrow(swap_ins) == 0) {
    return(tibble::tibble())
  }

  if (length(policy$stress_scenarios) == 0) {
    if (!isTRUE(existing_warnings$warned_no_stress)) {
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

  # For each applicant, take the highest (most conservative) probability
  final_prob <- apply(prob_matrix, 1, max, na.rm = TRUE)
  # Ensure probability is between 0 and 1
  final_prob[is.infinite(final_prob)] <- 1
  final_prob <- pmin(pmax(final_prob, 0), 1)

  # If method is analytical, return the final_prob directly
  if (method == "analytical") {
    simulated_outcomes <- final_prob
  } else {
    # Simulate default based on the final probability (stochastic)
    simulated_outcomes <- as.integer(stats::runif(length(final_prob)) < final_prob)
  }

  res_df <- tibble::tibble(
    tmp_id = swap_ins[[policy$applicant_id_col]],
    swap_in_default = simulated_outcomes
  )
  colnames(res_df)[1] <- policy$applicant_id_col
  return(res_df)
}

#' Calculate default probability based on aggravation
#' @return A numeric vector of probabilities.
#' @keywords internal
calc_prob_aggravation <- function(data, policy, scenario) {
  group_vars <- rlang::`%||%`(scenario$by, policy$risk_level_col)

  # Baseline should be calculated on the original approved population
  keep_ins <- data[data$scenario == "keep_in" & !is.na(data$scenario), ]

  if (is.null(group_vars)) {
    # Global aggravation
    baseline_rate <- mean(keep_ins[[policy$actual_default_col]], na.rm = TRUE)
    swap_ins <- data[data$scenario == "swap_in" & !is.na(data$scenario), ]

    if (is.character(scenario$factor) && length(scenario$factor) == 1) {
      if (!scenario$factor %in% names(swap_ins)) {
        cli::cli_abort("Dynamic stress factor column '{scenario$factor}' not found in data.")
      }
      agg_factor <- swap_ins[[scenario$factor]]
    } else {
      agg_factor <- scenario$factor
    }

    agg_rate <- baseline_rate * agg_factor
    if (length(agg_rate) == 1) agg_rate <- rep(agg_rate, nrow(swap_ins))
    return(agg_rate)
  }

  # Grouped aggravation (No pipe to avoid linter warnings)
  baseline_rates <- dplyr::summarise(
    dplyr::group_by(keep_ins, dplyr::across(dplyr::all_of(group_vars))),
    baseline_rate = mean(!!rlang::sym(policy$actual_default_col), na.rm = TRUE),
    .groups = "drop"
  )

  swap_ins <- data[data$scenario == "swap_in" & !is.na(data$scenario), ]

  if (is.character(scenario$factor) && length(scenario$factor) == 1) {
    if (!scenario$factor %in% names(swap_ins)) {
      cli::cli_abort("Dynamic stress factor column '{scenario$factor}' not found in data.")
    }
    agg_factor <- swap_ins[[scenario$factor]]
  } else {
    agg_factor <- scenario$factor
  }

  swap_ins <- dplyr::left_join(swap_ins, baseline_rates, by = group_vars)
  swap_ins$agg_rate <- swap_ins$baseline_rate * agg_factor

  if (anyNA(swap_ins$agg_rate)) {
    global_baseline <- mean(keep_ins[[policy$actual_default_col]], na.rm = TRUE)
    na_idx <- is.na(swap_ins$agg_rate)

    if (length(agg_factor) == 1) {
      swap_ins$agg_rate[na_idx] <- global_baseline * agg_factor
    } else {
      swap_ins$agg_rate[na_idx] <- global_baseline * agg_factor[na_idx]
    }
    if (requireNamespace("cli", quietly = TRUE)) {
      cli::cli_alert_warning("Some swap-in groups had no baseline for default aggravation and used the global average.")
    }
  }

  return(swap_ins$agg_rate)
}

#' Calculate probability based on a monotonic score-to-rate trend
#' @return A numeric vector of probabilities.
#' @keywords internal
calc_prob_monotonic <- function(data, score_col, params) {
  score_values <- data[[score_col]]

  interp_fun <- stats::approxfun(
    x = c(0, 1000),
    y = c(params$rate_at_min, params$rate_at_max),
    rule = 2 # Use the closest value for points outside the range
  )

  interp_fun(score_values)
}
