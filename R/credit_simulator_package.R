#' Credit Decision Simulation System
#'
#' @description
#' A comprehensive system for simulating credit decision processes with
#' multiple scores, stages, and optimization capabilities.
#'
#' @details
#' The package provides functionality to:
#' - Compare existing credit decisions with new decision rules
#' - Simulate multiple decision stages (credit, anti-fraud, conversion)
#' - Analyze trade-offs between approval and default rates
#' - Find optimal cutoffs for credit scores
#' - Handle large datasets efficiently
#'
#' @import cli
#' @import tibble
#' @importFrom stats runif quantile median
#' @importFrom tidyr pivot_longer
#' @importFrom stringr str_detect str_remove
#' @importFrom utils packageVersion
#'
#' @keywords internal
"_PACKAGE"

# Global configuration messages
.onAttach <- function(libname, pkgname) {
  cli::cli_alert_info("creditools {packageVersion('creditools')} loaded")
  cli::cli_alert_info("Use {.fn create_config} to set up simulation parameters")
}
