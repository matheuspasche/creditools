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


#' Define a Cutoff Stage
#' @name stage_cutoff
#' @title Define a Cutoff Stage
#' @description
#' `stage_cutoff()` defines a stage where approval is determined by one or more
#' score cutoffs. An applicant passes if their score is >= the cutoff for all
#' defined scores in this stage.
#'
#' @param name A character string for the name of the stage (e.g., "credit_check").
#' @param cutoffs A named list where names are score columns and values are
#'   the cutoffs to be applied.
#' @param observed_outcome_col Column in the original data that contains the
#'   observed outcome for this stage (0 or 1), if it exists. (Uses \code{tidyselect} syntax).
#'
#' @return A `credit_policy_stage` object of type `cutoff`.
#' @export
#' @examples
#' # Defines a stage that requires a 'new_score' of at least 650
#' # observed_outcome_col can be unquoted thanks to credit_policy resolution
#' credit_stage <- stage_cutoff(
#'   name = "credit_check", 
#'   cutoffs = list(new_score = 650),
#'   observed_outcome_col = approved_v1
#' )
stage_cutoff <- function(name, cutoffs, observed_outcome_col = NULL) {
  if (!is.list(cutoffs) || is.null(names(cutoffs))) {
    cli::cli_abort("{.arg cutoffs} must be a named list of score cutoffs.")
  }
  
  obs_col <- tryCatch(rlang::as_name(rlang::enquo(observed_outcome_col)), error = function(e) observed_outcome_col)

  new_credit_policy_stage(
    name = name,
    type = "cutoff",
    cutoffs = cutoffs,
    observed_outcome_col = obs_col
  )
}


#' Define a Rate Stage
#' @name stage_rate
#' @title Define a Rate Stage
#' @description
#' `stage_rate()` defines a stage where "approval" (e.g., conversion, acceptance)
#' is determined by a simulated rate. This is useful for stages that are not
#' score-based.
#'
#' @param name A character string for the name of the stage (e.g., "fraud_check").
#' @param base_rate The base rate for the simulation (e.g., 0.4 for a 40% conversion rate).
#' @param observed_outcome_col Column in the original data that contains the
#'   observed outcome for this stage (0 or 1), if it exists. (Uses \code{tidyselect} syntax).
#' @param stress_by_score An optional named list to stress the `base_rate` based on a
#'   score's value. Uses a monotonic increase assumption. See `stress_monotonic_increase()`.
#'
#' @return A `credit_policy_stage` object of type `rate`.
#' @export
#' @examples
#' # Defines a stage with a 95% pass rate (e.g., for fraud checks)
#' fraud_stage <- stage_rate(name = "fraud_check", base_rate = 0.95)
stage_rate <- function(name, base_rate, observed_outcome_col = NULL, stress_by_score = NULL) {
  if (!is.null(stress_by_score)) {
    if (!is.list(stress_by_score) || !all(c("score_col", "rate_at_min", "rate_at_max") %in% names(stress_by_score))) {
      cli::cli_abort("{.arg stress_by_score} must be a named list with 'score_col', 'rate_at_min', and 'rate_at_max'.")
    }
  }
  
  obs_col <- tryCatch(rlang::as_name(rlang::enquo(observed_outcome_col)), error = function(e) observed_outcome_col)

  new_credit_policy_stage(
    name = name,
    type = "rate",
    base_rate = base_rate,
    observed_outcome_col = obs_col,
    stress_by_score = stress_by_score
  )
}

#' @title Define a Hard Filter Stage
#' @description
#' `stage_filter()` defines a stage where approval is strictly determined by a
#' logical condition string (e.g., `"idade >= 18"` or `"status == 'V\u00e1lido'"`).
#' Applicants who evaluate to `FALSE` are immediately rejected from the funnel.
#'
#' @param name A character string for the name of the stage (e.g., "age_rule").
#' @param condition A character string representing the logical condition to be
#'   evaluated dynamically over the applicant data. Variables used in the string
#'   must exist in the data frame during simulation.
#' @param observed_outcome_col Column in the original data that contains the
#'   observed outcome for this stage (0 or 1), if it exists. (Uses \code{tidyselect} syntax).
#'
#' @return A `credit_policy_stage` object of type `filter`.
#' @export
#' @examples
#' # Defines a stage that rejects anyone under 18 years old
#' age_rule <- stage_filter(name = "age_check", condition = "age >= 18")
stage_filter <- function(name, condition, observed_outcome_col = NULL) {
  if (!is.character(condition) || length(condition) != 1) {
    cli::cli_abort("{.arg condition} must be a single string representing a logical statement.")
  }
  
  obs_col <- tryCatch(rlang::as_name(rlang::enquo(observed_outcome_col)), error = function(e) observed_outcome_col)

  new_credit_policy_stage(
    name = name,
    type = "filter",
    condition = condition,
    observed_outcome_col = obs_col
  )
}
