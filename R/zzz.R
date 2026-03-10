# Provide bindings for Non-Standard Evaluation (NSE) variables used by dplyr/purrr
# to prevent 'R CMD check' from flagging them as "no visible binding for global variable".
utils::globalVariables(c(
  "combo_bads", "combo_vol", "empirical_pd", "micro_rating",
  "group_id", "vol", "vols", "bads", "pd", "mean_pd", "sd_pd", "cv_pd", "risk_rating",
  "time", "Hired", "approval_rate", "score", "default_rate", "cutoff",
  "Bad_Rate", "scenario", "Applicants", "Approved", ".",
  "approval_distance", "combination_id", "default_distance",
  "overall_approval_rate", "overall_default_rate", "total_distance", "tradeoff_score",
  "score_tier", "new_approval", "new_hired", "simulated_default"
))
