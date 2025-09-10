#' Create simulation configuration
#'
#' @param score_columns Score columns to evaluate
#' @param current_approval_col Column with current approval decision
#' @param actual_default_col Column with observed default
#' @param risk_level_col Column with risk level
#' @param aggravation_factors Risk aggravation factors by risk level
#' @param simulation_stages List of simulation stages to apply
#' @param reference_data_period Reference period for historical data
#' @param applicant_id_col Applicant ID column name
#' @param date_col Date column name
#'
#' @return Configuration object for simulation
#' @export
create_config <- function(score_columns,
                          current_approval_col = "current_approval",
                          actual_default_col = "observed_default",
                          risk_level_col = "risk_level",
                          aggravation_factors = c(Low_Risk = 1.3, Medium_Risk = 1.5, High_Risk = 1.8),
                          simulation_stages = list(
                            list(
                              name = "credit",
                              type = "threshold"
                            )
                          ),
                          reference_data_period = NULL,
                          applicant_id_col = "applicant_id",
                          date_col = "application_date") {

  # Validate inputs
  if (!is.character(score_columns) || length(score_columns) == 0) {
    cli::cli_abort("{.arg score_columns} must be a non-empty character vector")
  }

  if (!is.list(simulation_stages) || length(simulation_stages) == 0) {
    cli::cli_abort("{.arg simulation_stages} must be a non-empty list")
  }

  # Validate each simulation stage
  purrr::walk(simulation_stages, function(stage) {
    if (!"name" %in% names(stage)) {
      cli::cli_abort("All simulation stages must have a {.field name}")
    }
    if (!"type" %in% names(stage)) {
      cli::cli_abort("All simulation stages must have a {.field type}")
    }
  })

  structure(list(
    score_columns = score_columns,
    current_approval_col = current_approval_col,
    actual_default_col = actual_default_col,
    risk_level_col = risk_level_col,
    aggravation_factors = aggravation_factors,
    simulation_stages = simulation_stages,
    reference_data_period = reference_data_period,
    applicant_id_col = applicant_id_col,
    date_col = date_col
  ), class = "credit_sim_config")
}

#' Validate configuration object
#' @keywords internal
validate_config <- function(config) {
  if (!inherits(config, "credit_sim_config")) {
    cli::cli_abort("Configuration must be created with {.fn create_config}")
  }

  required_fields <- c(
    "score_columns", "current_approval_col", "actual_default_col",
    "risk_level_col", "aggravation_factors", "simulation_stages",
    "applicant_id_col", "date_col"
  )

  missing_fields <- setdiff(required_fields, names(config))
  if (length(missing_fields) > 0) {
    cli::cli_abort("Missing required configuration fields: {missing_fields}")
  }

  TRUE
}
