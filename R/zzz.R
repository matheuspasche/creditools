# Provide bindings for Non-Standard Evaluation (NSE) variables used by dplyr/purrr
# to prevent 'R CMD check' from flagging them as "no visible binding for global variable".
utils::globalVariables(c(
  "combo_bads", "combo_vol", "empirical_pd", "micro_rating",
  "group_id", "vol", "pd", "mean_pd", "sd_pd", "cv_pd", "risk_rating", "."
))

# This function is called when the package is loaded.
# We use it to manually register S3 methods that are not exported,
# which is a robust way to ensure they are found by R's dispatch mechanism.
.onLoad <- function(libname, pkgname) {
  # Register S3 methods for simulate_stage
  try(utils::registerS3method("simulate_stage", "stage_cutoff", simulate_stage.stage_cutoff), silent = TRUE)
  try(utils::registerS3method("simulate_stage", "stage_rate", simulate_stage.stage_rate), silent = TRUE)
  try(utils::registerS3method("simulate_stage", "stage_filter", simulate_stage.stage_filter), silent = TRUE)

  invisible()
}
