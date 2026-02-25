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
#' @export
run_simulation <- function(data, policy) {
  validate_simulation_inputs(data, policy)

  # This will hold the logical vector of approvals at each stage
  stage_approval_cols <- list()

  # Sequentially process each stage in the funnel
  for (i in seq_along(policy$simulation_stages)) {
    stage <- policy$simulation_stages[[i]]
    stage_output_col <- paste0("approved_", stage$name, "_new")
    stage_approval_cols[[i]] <- stage_output_col

    # Eligibility for the current stage is passing all *previous* new stages
    if (i == 1) {
      is_eligible <- rep(TRUE, nrow(data))
    } else {
      # Get the logical vectors for all previous stages, handling NAs
      prev_approvals <- purrr::map(data[unlist(stage_approval_cols[1:(i-1)])], function(col) col == 1 & !is.na(col))
      is_eligible <- Reduce(`&`, prev_approvals)
    }

    # Simulate the current stage ONLY for the eligible population
    data[[stage_output_col]] <- NA_integer_
    if (any(is_eligible)) {
       data[is_eligible, stage_output_col] <- simulate_stage(data[is_eligible, ], stage, policy)
    }
  }

  # Determine final approval status under the new policy
  final_approval_flags <- purrr::map(data[unlist(stage_approval_cols)], function(col) col == 1 & !is.na(col))
  data$new_approval <- Reduce(`&`, final_approval_flags)

  # Classify scenarios based on old vs. new final approval
  data <- classify_scenarios(data, policy, "new_approval")

  # Assign default outcomes for the newly approved population
  data <- assign_simulated_defaults(data, policy)

  cli::cli_alert_success("Multi-stage simulation completed for {nrow(data)} applicants.")

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
#' @keywords internal
simulate_stage <- function(data, stage, policy) {
  UseMethod("simulate_stage", stage)
}

#' Simulate a cutoff-based stage
#' @keywords internal
simulate_stage.stage_cutoff <- function(data, stage, policy) {
  # Create a matrix of approval decisions for each score in this stage
  approval_matrix <- purrr::map_dfc(names(stage$cutoffs), function(score_col) {
    data[[score_col]] >= stage$cutoffs[[score_col]]
  })

  # Applicant passes if they meet ALL cutoffs in the stage
  as.integer(apply(approval_matrix, 1, all))
}

#' Simulate a rate-based stage (e.g., conversion)
#' @keywords internal
simulate_stage.stage_rate <- function(data, stage, policy) {

  # Default to an empty vector of results
  stage_outcome <- integer(nrow(data))

  # If there's an observed outcome column, use it for "keep-ins" at this stage
  if (!is.null(stage$observed_outcome_col)) {
    # A "keep-in" for this stage is someone who was approved in the original policy
    # AND had a positive outcome observed for this specific stage.
    is_original_approved <- data[[policy$current_approval_col]] == 1
    has_observed_outcome <- data[[stage$observed_outcome_col]] == 1

    keep_in_idx <- which(is_original_approved & has_observed_outcome)

    if(length(keep_in_idx) > 0) {
      stage_outcome[keep_in_idx] <- 1
    }

    # "Swap-ins" for this stage are everyone else who is eligible
    swap_in_idx <- which(!(is_original_approved & has_observed_outcome))
  } else {
    # If no observed data, everyone is a "swap-in" for this stage
    swap_in_idx <- seq_len(nrow(data))
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

  # Simulate the outcome for swap-ins
  simulated_outcome <- as.integer(stats::runif(nrow(swap_ins_data)) < prob)
  stage_outcome[swap_in_idx] <- simulated_outcome

  return(stage_outcome)
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
#' @keywords internal
validate_simulation_inputs <- function(data, policy) {
  if (!inherits(policy, "credit_policy")) {
    cli::cli_abort("{.arg policy} must be a {.cls credit_policy} object.")
  }
  if (!is.data.frame(data)) {
    cli::cli_abort("{.arg data} must be a data frame.")
  }
  if (length(policy$simulation_stages) == 0) {
    cli::cli_abort("The policy has no defined simulation stages. Use {.fn stage_cutoff} or {.fn stage_rate} to add stages.")
  }
  # Further validation for columns can be added here
  return(invisible(TRUE))
}


#' Classify scenarios based on current and new approval decisions
#' @keywords internal
classify_scenarios <- function(data, policy, new_approval_col) {
  current_approval_col <- policy$current_approval_col

  data$scenario <- dplyr::case_when(
    data[[current_approval_col]] == 0 & data[[new_approval_col]] == TRUE ~ "swap_in",
    data[[current_approval_col]] == 1 & data[[new_approval_col]] == FALSE ~ "swap_out",
    data[[current_approval_col]] == 1 & data[[new_approval_col]] == TRUE ~ "keep_in",
    data[[current_approval_col]] == 0 & data[[new_approval_col]] == FALSE ~ "keep_out",
    TRUE ~ NA_character_
  )

  return(data)
}


#' Assign default outcomes for the final approved population
#' @keywords internal
assign_simulated_defaults <- function(data, policy) {
  swap_in_defaults <- simulate_swap_in_defaults(data, policy)

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
#' @keywords internal
simulate_swap_in_defaults <- function(data, policy) {
  swap_ins <- data[data$scenario == "swap_in" & !is.na(data$scenario), ]

  if (nrow(swap_ins) == 0) {
    return(tibble::tibble())
  }

  if (length(policy$stress_scenarios) == 0) {
    cli::cli_alert_warning("No stress scenarios defined for swap-in defaults. Default outcomes will be NA.")
    return(tibble::tibble(!!policy$applicant_id_col := swap_ins[[policy$applicant_id_col]], swap_in_default = NA_integer_))
  }

  # Calculate probability for each stress scenario
  prob_matrix <- purrr::map_dfc(policy$stress_scenarios, function(scenario) {
    switch(scenario$type,
           "aggravation" = calc_prob_aggravation(data, policy, scenario),
           "monotonic_increase" = calc_prob_monotonic(swap_ins, scenario$score_col, scenario),
           cli::cli_abort("Unknown stress scenario type: {scenario$type}")
    )
  })

  # For each applicant, take the highest (most conservative) probability
  final_prob <- apply(prob_matrix, 1, max, na.rm = TRUE)
  # Ensure probability is between 0 and 1
  final_prob[is.infinite(final_prob)] <- 1
  final_prob <- pmin(pmax(final_prob, 0), 1)

  # Simulate default based on the final probability
  simulated_outcomes <- as.integer(stats::runif(length(final_prob)) < final_prob)

  tibble::tibble(
    !!policy$applicant_id_col := swap_ins[[policy$applicant_id_col]],
    swap_in_default = simulated_outcomes
  )
}

#' Calculate default probability based on aggravation
#' @keywords internal
calc_prob_aggravation <- function(data, policy, scenario) {
  group_vars <- rlang::`%||%`(scenario$by, policy$risk_level_col)

  # Baseline should be calculated on the original approved population
  keep_ins <- data[data$scenario == "keep_in" & !is.na(data$scenario), ]

  if (is.null(group_vars)) {
    # Global aggravation
    baseline_rate <- mean(keep_ins[[policy$actual_default_col]], na.rm = TRUE)
    agg_rate <- baseline_rate * scenario$factor
    return(rep(agg_rate, nrow(data[data$scenario == "swap_in" & !is.na(data$scenario), ])))
  }

  # Grouped aggravation
  baseline_rates <- keep_ins %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(group_vars))) %>%
    dplyr::summarise(baseline_rate = mean(.data[[policy$actual_default_col]], na.rm = TRUE), .groups = "drop")

  agg_factor <- scenario$factor

  swap_ins <- data %>%
    dplyr::filter(.data$scenario == "swap_in" & !is.na(.data$scenario)) %>%
    dplyr::left_join(baseline_rates, by = group_vars) %>%
    dplyr::mutate(agg_rate = .data$baseline_rate * agg_factor)

  if (anyNA(swap_ins$agg_rate)) {
    global_baseline <- mean(keep_ins[[policy$actual_default_col]], na.rm = TRUE)
    swap_ins$agg_rate[is.na(swap_ins$agg_rate)] <- global_baseline * scenario$factor
    cli::cli_alert_warning("Some swap-in groups had no baseline for default aggravation and used the global average.")
  }

  return(swap_ins$agg_rate)
}

#' Calculate probability based on a monotonic score-to-rate trend
#' @keywords internal
calc_prob_monotonic <- function(data, score_col, params) {
  score_values <- data[[score_col]]

  interp_fun <- stats::approxfun(
    x = range(score_values, na.rm = TRUE),
    y = c(params$rate_at_min, params$rate_at_max),
    rule = 2 # Use the closest value for points outside the range
  )

  interp_fun(score_values)
}
