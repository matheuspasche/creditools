# This file is used to declare global variables used in dplyr verbs
# to avoid NOTES during R CMD check.

utils::globalVariables(c(
  ".data", "approval_distance", "combination_id", "cutoff", "default_distance",
  "overall_approval_rate", "overall_default_rate", "total_distance", "tradeoff_score"
))

#' @importFrom stats setNames
NULL
