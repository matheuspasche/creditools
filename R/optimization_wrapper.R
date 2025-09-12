#' Simplified interface for credit score optimization
#'
#' This provides a user-friendly interface for finding optimal credit score cutoffs
#' with sensible defaults and clear recommendations.
#'
#' @param data Input data
#' @param config Simulation configuration
#' @param optimization_strategy Optimization strategy ("balanced", "conservative", "aggressive")
#' @param show_details Whether to show detailed recommendations
#'
#' @return List with optimal cutoffs and recommendations
#' @export
optimize_credit_scores <- function(data, config,
                                   optimization_strategy = c("balanced", "conservative", "aggressive"),
                                   show_details = TRUE) {

  strategy <- match.arg(optimization_strategy)

  # Set parameters based on strategy
  params <- switch(strategy,
                   "conservative" = list(
                     target_default_rate = 0.03,
                     min_approval_rate = 0.4,
                     cutoff_steps = 15
                   ),
                   "balanced" = list(
                     target_default_rate = 0.05,
                     min_approval_rate = 0.5,
                     cutoff_steps = 20
                   ),
                   "aggressive" = list(
                     target_default_rate = 0.07,
                     min_approval_rate = 0.6,
                     cutoff_steps = 25
                   )
  )

  if (show_details) {
    cli::cli_alert_info("Running optimization with {strategy} strategy")
    cli::cli_alert_info("Target default rate: {params$target_default_rate}")
    cli::cli_alert_info("Minimum approval rate: {params$min_approval_rate}")
  }

  # Run optimization
  results <- find_optimal_cutoffs(
    data = data,
    config = config,
    cutoff_steps = params$cutoff_steps,
    target_default_rate = params$target_default_rate,
    min_approval_rate = params$min_approval_rate,
    parallel = TRUE,
    show_progress = TRUE
  )

  # Extract recommendations
  recommendations <- extract_recommendations(results, strategy)

  if (show_details) {
    print_recommendations(recommendations, strategy)
  }

  return(list(
    optimal_cutoffs = results,
    recommendations = recommendations,
    strategy = strategy
  ))
}

#' Extract recommendations from optimization results
#' @keywords internal
extract_recommendations <- function(opt_results, strategy) {
  tradeoff_analysis <- attr(opt_results, "tradeoff_analysis")

  purrr::map(tradeoff_analysis$score_analysis, function(score_analysis) {
    # Get optimal points for this score
    optimal_points <- score_analysis$optimal_points

    # Select recommendation based on strategy
    recommendation <- switch(strategy,
                             "conservative" = optimal_points$min_default,
                             "balanced" = optimal_points$best_tradeoff,
                             "aggressive" = optimal_points$max_approval
    )

    # Find point of diminishing returns
    diminishing_returns <- find_diminishing_returns(score_analysis$results)

    list(
      recommended_cutoff = recommendation$cutoff,
      expected_approval_rate = recommendation$approval_rate,
      expected_default_rate = recommendation$default_rate,
      diminishing_returns_cutoff = diminishing_returns$cutoff,
      diminishing_returns_approval = diminishing_returns$approval_rate,
      diminishing_returns_default = diminishing_returns$default_rate,
      tradeoff_data = score_analysis$results
    )
  })
}

#' Print optimization recommendations
#' @keywords internal
print_recommendations <- function(recommendations, strategy) {
  cli::cli_h1("Optimization Recommendations ({toupper(strategy)} Strategy)")

  purrr::walk(names(recommendations), function(score_name) {
    rec <- recommendations[[score_name]]

    cli::cli_h2("Score: {score_name}")
    cli::cli_alert_info("Recommended cutoff: {round(rec$recommended_cutoff, 1)}")
    cli::cli_alert_info("Expected approval rate: {scales::percent(rec$expected_approval_rate, accuracy = 0.1)}")
    cli::cli_alert_info("Expected default rate: {scales::percent(rec$expected_default_rate, accuracy = 0.1)}")
    cli::cli_alert_warning("Diminishing returns at cutoff: {round(rec$diminishing_returns_cutoff, 1)}")
    cli::cli_alert_warning("Beyond this point, default rate increases significantly")

    cli::cat_line()
  })

  cli::cli_alert_success("Use these cutoffs as starting points for manual refinement")
  cli::cli_alert_info("Conservative strategies favor lower default rates")
  cli::cli_alert_info("Aggressive strategies favor higher approval rates")
  cli::cli_alert_info("Consider business context and risk appetite when finalizing cutoffs")
}
