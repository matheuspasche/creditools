# Provide bindings for Non-Standard Evaluation (NSE) variables used by dplyr/purrr
# to prevent 'R CMD check' from flagging them as "no visible binding for global variable".
utils::globalVariables(c(
  "combo_bads", "combo_vol", "empirical_pd", "micro_rating",
  "group_id", "vol", "pd", "mean_pd", "sd_pd", "cv_pd", "risk_rating", "."
))
