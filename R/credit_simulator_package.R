#' Credit Decision Simulation System
#'
#' @description
#' A comprehensive system for simulating credit decision processes with
#' multiple scores, stages, and trade-off analysis capabilities.
#'
#' @details
#' The package provides functionality to:
#' - Compare existing credit decisions with new decision rules
#' - Simulate multiple decision stages (credit, anti-fraud, conversion)
#' - Analyze trade-offs between approval and default rates
#' - Visualize the relationship between cutoffs, approval rates, and default rates
#'
#' @import cli
#' @import dplyr
#' @import purrr
#' @import rlang
#' @import tibble
#' @importFrom stats runif quantile median
#' @importFrom tidyr pivot_longer
#' @importFrom stringr str_detect str_remove
#' @import ggplot2
#' @importFrom future plan multisession sequential availableCores
#' @importFrom furrr future_map_dfr
#'
#' @keywords internal
"_PACKAGE"

# Global configuration messages
.onAttach <- function(libname, pkgname) {
  cli::cli_alert_info("creditSimulator {packageVersion('creditSimulator')} loaded")
  cli::cli_alert_info("Use {.fn create_config} to set up simulation parameters")
}
