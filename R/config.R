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
#' @param factor For `stress_aggravation`, the multiplicative factor to apply to the baseline default rate. Can be a numeric scalar, or a character string mapping to a column in the data containing custom applicant-level stress factors.
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

  # Mandatory arguments check
  if (missing(applicant_id_col)) cli::cli_abort("{.arg applicant_id_col} must be a single string or a symbol.")
  if (missing(score_cols)) cli::cli_abort("{.arg score_cols} must be a character vector or symbols.")
  if (missing(current_approval_col)) cli::cli_abort("{.arg current_approval_col} must be a single string or a symbol.")
  if (missing(actual_default_col)) cli::cli_abort("{.arg actual_default_col} must be a single string or a symbol.")

  # Hybrid resolution helper
  # If it evaluates to a character, use that value (supports variables).
  # Otherwise, take the symbol name as is (supports unquoted names).
  resolve_hybrid <- function(q, arg_name, default_val = NULL) {
    if (rlang::quo_is_null(q)) return(default_val)
    val <- try(rlang::eval_tidy(q), silent = TRUE)
    if (!inherits(val, "try-error") && is.character(val) && length(val) >= 1) {
      if (length(val) > 1 && arg_name != "score_cols") {
          cli::cli_abort("{.arg {arg_name}} must be a single string or a symbol.")
      }
      return(val)
    }
    # Fallback to symbol name if it's a symbol
    tryCatch(rlang::as_name(q), error = function(e) {
        if (!is.null(default_val)) return(default_val)
        cli::cli_abort("{.arg {arg_name}} must be a single string or a symbol.")
    })
  }

  id_col <- resolve_hybrid(rlang::enquo(applicant_id_col), "applicant_id_col")
  curr_app_col <- resolve_hybrid(rlang::enquo(current_approval_col), "current_approval_col")
  act_def_col <- resolve_hybrid(rlang::enquo(actual_default_col), "actual_default_col")

  # Special handling for score_cols to support c(s1, s2)
  sc_q <- rlang::enquo(score_cols)
  sc_expr <- rlang::quo_get_expr(sc_q)
  
  if (is.call(sc_expr) && rlang::is_call(sc_expr, "c")) {
      # Extract names from c(...) call
      args <- rlang::call_args(sc_expr)
      sc_cols <- tryCatch({
          unname(purrr::map_chr(args, function(a) {
              # Try to resolve each element in c()
              res <- try(rlang::eval_tidy(a, q = rlang::quo_get_env(sc_q)), silent = TRUE)
              if (!inherits(res, "try-error") && is.character(res) && length(res) == 1) return(res)
              rlang::as_string(a)
          }))
      }, error = function(e) {
          cli::cli_abort("{.arg score_cols} must be a character vector or symbols.")
      })
  } else {
      # For single score_cols, we use resolve_hybrid but with score_cols specific error
      sc_cols <- tryCatch({
          resolve_hybrid(sc_q, "score_cols")
      }, error = function(e) {
          cli::cli_abort("{.arg score_cols} must be a character vector or symbols.")
      })
  }

  risk_col <- NULL
  if (!is.null(risk_level_col)) {
      risk_col <- tryCatch(rlang::as_name(rlang::enquo(risk_level_col)), error = function(e) risk_level_col)
  }

  # --- Start: Robust validation for user-friendliness ---
  if (is.null(id_col) || length(id_col) != 1) {
    cli::cli_abort("{.arg applicant_id_col} must resolve to a single string.")
  }
  if (is.null(sc_cols) || length(sc_cols) == 0) {
    cli::cli_abort("{.arg score_cols} must resolve to a non-empty character vector.")
  }
  if (is.null(curr_app_col) || length(curr_app_col) != 1) {
    cli::cli_abort("{.arg current_approval_col} must resolve to a single string.")
  }
  if (is.null(act_def_col) || length(act_def_col) != 1) {
    cli::cli_abort("{.arg actual_default_col} must resolve to a single string.")
  }
  # --- End: Robust validation ---

  policy <- new_credit_policy(
    applicant_id_col = id_col,
    score_cols = sc_cols,
    current_approval_col = curr_app_col,
    actual_default_col = act_def_col,
    risk_level_col = risk_col,
    simulation_stages = simulation_stages,
    stress_scenarios = stress_scenarios
  )

  # The validator is now mostly for internal consistency checks
  validate_credit_policy(policy)

  return(policy)
}

#' Add a stage to a credit policy
#'
#' @param policy A `credit_policy` object.
#' @param stage A simulation stage created with `stage_cutoff`, `stage_rate`, etc.
#'
#' @return An updated `credit_policy` object.
#' @export
#'
#' @examples
#' policy <- credit_policy(
#'   applicant_id_col = "id",
#'   score_cols = "new_score",
#'   current_approval_col = "approved",
#'   actual_default_col = "defaulted"
#' )
#' policy <- add_stage(policy, stage_cutoff("score", list(new_score = 600)))
add_stage <- function(policy, stage) {
  if (!inherits(policy, "credit_policy")) {
    cli::cli_abort("{.arg policy} must be a {.cls credit_policy} object.")
  }

  policy$simulation_stages <- c(policy$simulation_stages, list(stage))
  validate_credit_policy(policy)
  return(policy)
}

#' Add a stress scenario to a credit policy
#'
#' @param policy A `credit_policy` object.
#' @param scenario A stress scenario created with `stress_aggravation()`, `stress_monotonic_increase()`, or `stress_custom()`.
#'
#' @return An updated `credit_policy` object.
#' @export
#'
#' @examples
#' policy <- credit_policy(
#'   applicant_id_col = "id",
#'   score_cols = "new_score",
#'   current_approval_col = "approved",
#'   actual_default_col = "defaulted"
#' )
#' policy <- add_stress_scenario(policy, stress_aggravation(factor = 1.5))
add_stress_scenario <- function(policy, scenario) {
  if (!inherits(policy, "credit_policy")) {
    cli::cli_abort("{.arg policy} must be a {.cls credit_policy} object.")
  }
  if (!inherits(scenario, "stress_scenario")) {
    cli::cli_abort("{.arg scenario} must be a {.cls stress_scenario} object, created by {.fn stress_aggravation}, {.fn stress_monotonic_increase}, or {.fn stress_custom}.")
  }

  policy$stress_scenarios <- c(policy$stress_scenarios, list(scenario))
  validate_credit_policy(policy)
  return(policy)
}

#' @rdname credit_policy
#' @export
#' @return A `stress_scenario` object.
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
#' @return A `stress_scenario` object.
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
#' @return A `stress_scenario` object.
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
#' @return A `credit_policy` object.
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
#' @return The validated `credit_policy` object, invisibly.
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
    if (!is.list(policy$stress_scenarios) || !all(.parallel_map_lgl(policy$stress_scenarios, inherits, "stress_scenario", .parallel = FALSE))) {
      cli::cli_abort("{.arg stress_scenarios} must be a list of objects from {.fn stress_aggravation}, {.fn stress_monotonic_increase}, or {.fn stress_custom}.")
    }
    is_agg_by <- .parallel_map_lgl(policy$stress_scenarios, ~ .x$type == "aggravation" && !is.null(.x$by), .parallel = FALSE)
    if (any(is_agg_by) && is.null(policy$risk_level_col)) {
      cli::cli_abort("A {.arg risk_level_col} must be provided in the policy when using {.code by} in {.fn stress_aggravation}.")
    }
  }

  if (length(policy$simulation_stages) > 0) {
    if (!is.list(policy$simulation_stages) || !all(.parallel_map_lgl(policy$simulation_stages, inherits, "credit_policy_stage", .parallel = FALSE))) {
      cli::cli_abort("{.arg simulation_stages} must be a list of objects from {.fn stage_cutoff} or {.fn stage_rate}.")
    }
  }

  return(invisible(policy))
}

#' Print method for credit_policy
#' @param x A `credit_policy` object.
#' @param ... Additional arguments passed to `print`.
#'
#' @return The original object `x`, invisibly.
#' @export
#'
#' @examples
#' policy <- credit_policy("id", "score", "app", "def")
#' print(policy)
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
