# Example script to generate a large sample dataset for business validation
#
# To run this script:
# 1. Make sure the `creditools` package is loaded (e.g., using devtools::load_all())
# 2. Execute the code below.

# Load required packages
# This assumes the package is loaded, e.g. via devtools::load_all()
if (!requireNamespace("readr", quietly = TRUE)) {
  install.packages("readr")
}

# --- Parameters ---
N_APPLICANTS <- 100000
OUTPUT_FILE <- "data/large_sample_data.csv"
SEED <- 42

# --- Generation ---
cli::cli_h1("Generating Large Sample Dataset")

# Generate the data using the package function
sample_df <- creditools::generate_sample_data(
  n_applicants = N_APPLICANTS,
  seed = SEED
)

# --- Saving the data ---
cli::cli_alert_info("Saving data to {.path {OUTPUT_FILE}}...")
readr::write_csv(sample_df, OUTPUT_FILE)

cli::cli_alert_success("Successfully created the large sample dataset.")

