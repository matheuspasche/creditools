#' Define a Simulation Stage
#'
#' @description
#' These functions create definitions for different types of stages in a
#' credit policy simulation funnel.
#'
#' @param name A character string for the name of the stage (e.g., "credit", "fraud", "conversion").
#' @param ... Specific parameters for the stage type.
#'
#' @return A `credit_policy_stage` object.
#' @keywords internal
new_credit_policy_stage <- function(name, type, ...) {
  structure(
    list(
      name = name,
      type = type,
      ...
    ),
    class = c(paste0("stage_", type), "credit_policy_stage")
  )
}


#' @description
#' `stage_cutoff()` defines a stage where approval is determined by one or more
#' score cutoffs. An applicant passes if their score is >= the cutoff for all
#' defined scores in this stage.
#'
#' @param cutoffs A named list where names are score columns and values are
#'   the cutoffs to be applied.
#' @param observed_outcome_col The column in the original data that contains the
#'   observed outcome for this stage (0 or 1), if it exists. Used for `keep_in` analysis.
#'
#' @rdname new_credit_policy_stage
#' @export
stage_cutoff <- function(name, cutoffs, observed_outcome_col = NULL) {
  if (!is.list(cutoffs) || is.null(names(cutoffs))) {
    cli::cli_abort("{.arg cutoffs} must be a named list of score cutoffs.")
  }
  new_credit_policy_stage(
    name = name,
    type = "cutoff",
    cutoffs = cutoffs,
    observed_outcome_col = observed_outcome_col
  )
}


#' @description
#' `stage_rate()` defines a stage where "approval" (e.g., conversion, acceptance)
#' is determined by a simulated rate. This is useful for stages that are not
#' score-based.
#'
#' @param base_rate The base rate for the simulation (e.g., 0.4 for a 40% conversion rate).
#' @param observed_outcome_col The column in the original data that contains the
#'   observed outcome for this stage (0 or 1), if it exists.
#' @param stress_by_score An optional named list to stress the `base_rate` based on a
#'   score's value. Uses a monotonic increase assumption. See `stress_monotonic_increase()`.
#'
#' @rdname new_credit_policy_stage
#' @export
stage_rate <- function(name, base_rate, observed_outcome_col = NULL, stress_by_score = NULL) {
  if (!is.null(stress_by_score)) {
    if (!is.list(stress_by_score) || !all(c("score_col", "rate_at_min", "rate_at_max") %in% names(stress_by_score))) {
      cli::cli_abort("{.arg stress_by_score} must be a named list with 'score_col', 'rate_at_min', and 'rate_at_max'.")
    }
  }
  new_credit_policy_stage(
    name = name,
    type = "rate",
    base_rate = base_rate,
    observed_outcome_col = observed_outcome_col,
    stress_by_score = stress_by_score
  )
}
