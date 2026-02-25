#' Summarize simulation results
#'
#' @param results Simulation results
#' @param by Grouping variables
#'
#' @importFrom purrr map_dfr
#' @importFrom dplyr group_by across all_of summarise n
#'
#' @return Data frame with summary statistics
#' @export
summarize_results <- function(results, by = NULL) {
  if (!inherits(results, "credit_sim_results")) {
    cli::cli_abort("{.arg results} must be a credit_sim_results object")
  }

  data <- results$data
  config <- results$metadata$config

  # If by is not specified, use risk level if available
  if (is.null(by)) {
    by <- grep("risk|level", names(data), value = TRUE, ignore.case = TRUE)[1]
    if (is.na(by)) by <- NULL
  }

  # For each score, calculate metrics
  score_metrics <- map_dfr(config$score_columns, function(score_col) {
    scenario_col <- paste0("scenario_", score_col)
    default_col <- paste0("default_simulated_", score_col)
    final_approval_col <- get_final_approval_col(config$simulation_stages, score_col)

    data %>%
      group_by(across(all_of(c(by, scenario_col)))) %>%
      summarise(
        score = score_col,
        volume = n(),
        approval_rate = mean(.data[[final_approval_col]], na.rm = TRUE),
        default_rate = mean(.data[[default_col]], na.rm = TRUE),
        .groups = "drop"
      )
  })

  return(score_metrics)
}

#' Get final approval column name
#' @keywords internal
get_final_approval_col <- function(simulation_stages, score_col) {
  if (length(simulation_stages) == 0) {
    return(paste0("approval_", score_col))
  }

  last_stage <- simulation_stages[[length(simulation_stages)]]
  paste0(last_stage$name, "_", score_col)
}
