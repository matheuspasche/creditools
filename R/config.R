#' Constructor for the credit_policy S3 class
#'
#' @description
#' Creates a new `credit_policy` object, which defines all the parameters
#' needed to run a credit simulation. This includes column mappings,
#' score definitions, simulation stages, and stress testing parameters.
#'
#' @param applicant_id_col The column with the unique applicant ID.
#' @param score_cols A character vector of column names for the credit scores.
#' @param current_approval_col The column indicating the historical approval decision.
#' @param actual_default_col The column indicating the observed default outcome.
#' @param risk_level_col Optional. A column for risk stratification (e.g., risk bands),
#'   used in some stress scenarios.
#' @param simulation_stages A list defining the sequence of simulation stages,
#'   created using `stage_cutoff()` or `stage_rate()`.
#' @param stress_scenarios A list defining stress testing scenarios for swap-ins,
#'   created with `stress_aggravation()` or `stress_monotonic_increase()`.
#' @param factor For `stress_aggravation`, the multiplicative factor to apply to the baseline default rate.
#' @param by For `stress_aggravation`, the column name to group by for stratified aggravation. If NULL, aggravation is applied globally.
#' @param rate_at_min For `stress_monotonic_increase`, the assumed default rate for the minimum score value.
#' @param rate_at_max For `stress_monotonic_increase`, the assumed default rate for the maximum score value.
#' @param score_col For `stress_monotonic_increase`, the score column to which the monotonic trend applies.
#' @param method For `stress_monotonic_increase`, the interpolation method (currently only "linear" is supported).
#'
#' @return A `credit_policy` object.
#' @export
#' @examples
#' # Define a simple credit policy
#' my_policy <- credit_policy(
#'   applicant_id_col = "id",
#'   score_cols = c("score_v1", "score_v2"),
#'   current_approval_col = "approved_v1",
#'   actual_default_col = "defaulted",
#'   risk_level_col = "risk_band",
#'   simulation_stages = list(
#'     # New policy requires passing a score cutoff AND a fraud check
#'     stage_cutoff(name = "credit_check", cutoffs = list(score_v2 = 700)),
#'     stage_rate(name = "fraud_check", base_rate = 0.98)
#'   ),
#'   stress_scenarios = list(
#'     # For swap-ins, simulate defaults with a 30% uplift on the baseline
#'     stress_aggravation(factor = 1.3, by = "risk_band")
#'   )
#' )
#'
#' # Print the policy to see a summary
#' print(my_policy)
credit_policy <- function(applicant_id_col,
                          score_cols,
                          current_approval_col,
                          actual_default_col,
                          risk_level_col = NULL,
                          simulation_stages = list(),
                          stress_scenarios = list()) {

  # --- Start: Robust validation for user-friendliness ---
  if (missing(applicant_id_col) || !is.character(applicant_id_col) || length(applicant_id_col) != 1) {
    cli::cli_abort("{.arg applicant_id_col} must be a single string.")
  }
  if (missing(score_cols) || !is.character(score_cols) || length(score_cols) == 0) {
    cli::cli_abort("{.arg score_cols} must be a character vector of at least one score column.")
  }
  if (missing(current_approval_col) || !is.character(current_approval_col) || length(current_approval_col) != 1) {
    cli::cli_abort("{.arg current_approval_col} must be a single string.")
  }
  if (missing(actual_default_col) || !is.character(actual_default_col) || length(actual_default_col) != 1) {
    cli::cli_abort("{.arg actual_default_col} must be a single string.")
  }
  # --- End: Robust validation ---

  policy <- new_credit_policy(
    applicant_id_col = applicant_id_col,
    score_cols = score_cols,
    current_approval_col = current_approval_col,
    actual_default_col = actual_default_col,
    risk_level_col = risk_level_col,
    simulation_stages = simulation_stages,
    stress_scenarios = stress_scenarios
  )

  # The validator is now mostly for internal consistency checks
  validate_credit_policy(policy)

  return(policy)
}

#' @rdname credit_policy
#' @export
stress_aggravation <- function(factor, by = NULL) {
  structure(
    list(
      type = "aggravation",
      factor = factor,
      by = by
    ),
    class = "stress_scenario"
  )
}

#' @rdname credit_policy
#' @export
stress_monotonic_increase <- function(rate_at_min, rate_at_max, score_col, method = "linear") {
  structure(
    list(
      type = "monotonic_increase",
      rate_at_min = rate_at_min,
      rate_at_max = rate_at_max,
      score_col = score_col,
      method = method
    ),
    class = "stress_scenario"
  )
}

#' @rdname credit_policy
#' @param func For `stress_custom`, an arbitrary R function that takes the `data` frame of swap-ins and returns a numeric vector with probabilities.
#' @export
stress_custom <- function(func) {
  if (!is.function(func)) {
    cli::cli_abort("{.arg func} must be an R function that takes a data frame and returns a numeric vector of probabilities/rates.")
  }
  structure(
    list(
      type = "custom",
      func = func
    ),
    class = "stress_scenario"
  )
}

#' Low-level constructor for the `credit_policy` class
#' @keywords internal
new_credit_policy <- function(applicant_id_col = character(),
                              score_cols = character(),
                              current_approval_col = character(),
                              actual_default_col = character(),
                              risk_level_col = NULL,
                              simulation_stages = list(),
                              stress_scenarios = list()) {
  structure(
    list(
      applicant_id_col = applicant_id_col,
      score_cols = score_cols,
      current_approval_col = current_approval_col,
      actual_default_col = actual_default_col,
      risk_level_col = risk_level_col,
      simulation_stages = simulation_stages,
      stress_scenarios = stress_scenarios
    ),
    class = "credit_policy"
  )
}

#' Validator for the `credit_policy` class
#' @keywords internal
validate_credit_policy <- function(policy) {
  if (!inherits(policy, "credit_policy")) {
    cli::cli_abort("Input must be of class {.cls credit_policy}.")
  }

  required_fields <- c("applicant_id_col", "score_cols", "current_approval_col", "actual_default_col")
  for (field in required_fields) {
    if (is.null(policy[[field]]) || length(policy[[field]]) == 0) {
      cli::cli_abort("Policy field {.arg {field}} is missing or empty.")
    }
  }

  if (length(policy$stress_scenarios) > 0) {
    if (!is.list(policy$stress_scenarios) || !all(purrr::map_lgl(policy$stress_scenarios, inherits, "stress_scenario"))) {
      cli::cli_abort("{.arg stress_scenarios} must be a list of objects from {.fn stress_aggravation}, {.fn stress_monotonic_increase}, or {.fn stress_custom}.")
    }
    is_agg_by <- purrr::map_lgl(policy$stress_scenarios, ~ .x$type == "aggravation" && !is.null(.x$by))
    if (any(is_agg_by) && is.null(policy$risk_level_col)) {
      cli::cli_abort("A {.arg risk_level_col} must be provided in the policy when using {.code by} in {.fn stress_aggravation}.")
    }
  }

  if (length(policy$simulation_stages) > 0) {
    if (!is.list(policy$simulation_stages) || !all(purrr::map_lgl(policy$simulation_stages, inherits, "credit_policy_stage"))) {
      cli::cli_abort("{.arg simulation_stages} must be a list of objects from {.fn stage_cutoff} or {.fn stage_rate}.")
    }
  }

  return(invisible(policy))
}

#' Print method for credit_policy
#' @param x A `credit_policy` object.
#' @param ... Additional arguments passed to `print`.
#' @export
print.credit_policy <- function(x, ...) {
  cli::cli_rule("Credit Simulation Policy")
  cli::cli_bullets(c(
    "*" = "Applicant ID: {.field {x$applicant_id_col}}",
    "*" = "Score Columns: {x$score_cols}",
    "*" = "Current Approval: {.field {x$current_approval_col}}",
    "*" = "Actual Default: {.field {x$actual_default_col}}",
    if (!is.null(x$risk_level_col)) "*" <- "Risk Stratification: {.field {x$risk_level_col}}",
    "*" = "{length(x$simulation_stages)} simulation stage(s) defined",
    "*" = "{length(x$stress_scenarios)} stress scenario(s) defined"
  ))
  invisible(x)
}
