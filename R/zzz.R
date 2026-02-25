# This function is called when the package is loaded.
# We use it to manually register S3 methods that are not exported,
# which is a robust way to ensure they are found by R's dispatch mechanism.
.onLoad <- function(libname, pkgname) {
  # Register S3 methods for simulate_stage
  try(utils::registerS3method("simulate_stage", "stage_cutoff", simulate_stage.stage_cutoff), silent = TRUE)
  try(utils::registerS3method("simulate_stage", "stage_rate", simulate_stage.stage_rate), silent = TRUE)
  
  invisible()
}
