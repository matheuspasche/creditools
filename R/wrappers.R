#' Simulate Challenger Policy Core Metrics from Flat Data
#'
#' @description
#' A high-level analytical wrapper designed for Credit Analysts.
#' Bypasses the complex simulation engine and directly computes
#' volumetric trade-offs, approval funnel metrics, and
#' stressed default rates based on Ward Risk Clustering.
#'
#' @details
#' Internally, it mirrors the core engine semantics:
#' - classifies applicants into `keep_in`, `swap_in`, `swap_out`, `keep_out`
#'   quadrants based on historical vs. challenger approval;
#' - derives implied conversion curves from *observed* history by score tier;
#' - runs `find_risk_groups()` on the challenger-approved population to obtain
#'   stable `risk_rating` clusters; and
#' - applies a multiplicative PD stress per `risk_rating` bucket, equivalent
#'   in spirit to a `stress_aggravation(by = "risk_rating")` scenario.
#'
#' It expects a flat data frame where real-world operational
#' outcomes (like approved vs rejected, hired vs not, and
#' defaulted vs paid) are already present historically.
#'
#' @param data A data frame containing the historical applicant data.
#' @param applicant_id_col Column containing unique applicant IDs. (Uses \code{tidyselect} syntax).
#' @param current_score_col Column containing the current historical score. (Uses \code{tidyselect} syntax).
#' @param new_score_col Column containing the challenger score. (Uses \code{tidyselect} syntax).
#' @param historical_approval_col Column with the binary approval flag (1 = Approved, 0 = Rejected). (Uses \code{tidyselect} syntax).
#' @param historical_hired_col Column with the binary hired/conversion flag (1 = Hired, 0 = Lost). (Uses \code{tidyselect} syntax).
#' @param actual_default_col Column with the true default flag for hired customers. (Uses \code{tidyselect} syntax).
#' @param new_score_cutoff The threshold for the challenger score to approve an applicant.
#' @param aggravation_factor The +X% stress applied to Swap-Ins (defaults to 1.30 for 30% penalty).
#' @param method The simulation method: `"stochastic"` (default) for row-by-row sampling
#'   or `"analytical"` for expected value calculation (reweighting).
#' @param time_col Optional. Name of the vintage/date column to ensure temporal stability in Risk Groups. (Uses \code{tidyselect} syntax).
#'
#' @return A list containing the resulting metrics, the generated risk groups, and the appended dataset.
#' @export
#'
#' @examples
#' # High-level wrapper for credit analysts
#' data <- generate_sample_data(n_applicants = 1000)
#' results <- simulate_from_data(
#'     data = data,
#'     current_score_col = old_score, # Use tidyselect syntax
#'     new_score_col = new_score,
#'     new_score_cutoff = 600,
#'     aggravation_factor = 1.3
#' )
#'
#' # View the scenario summary
#' print(results$summary)
#'
#' # Plot the results
#' plot(results)
simulate_from_data <- function(data,
                               applicant_id_col = "id",
                               current_score_col = "current_score",
                               new_score_col = "new_score",
                               historical_approval_col = "approved",
                               historical_hired_col = "hired",
                               actual_default_col = "defaulted",
                               new_score_cutoff,
                               aggravation_factor = 1.30,
                               method = c("stochastic", "analytical"),
                               time_col = NULL) {
    method <- match.arg(method)
    cli::cli_h1("Creditools: {ifelse(method == 'analytical', 'Analytical', 'Stochastic')} Simulation from Flat Data")

    # Resolve Columns with Tidyselect
    # We use enquo and eval_select to allow unquoted names and helpers
    sel_id <- names(tidyselect::eval_select(rlang::enquo(applicant_id_col), data))
    sel_cur <- names(tidyselect::eval_select(rlang::enquo(current_score_col), data))
    sel_new <- names(tidyselect::eval_select(rlang::enquo(new_score_col), data))
    sel_act_def <- names(tidyselect::eval_select(rlang::enquo(actual_default_col), data))
    
    # Optional columns
    sel_hist_app <- names(tidyselect::eval_select(rlang::enquo(historical_approval_col), data))
    if (length(sel_hist_app) == 0) sel_hist_app <- NULL
    
    sel_hist_hired <- names(tidyselect::eval_select(rlang::enquo(historical_hired_col), data))
    if (length(sel_hist_hired) == 0) sel_hist_hired <- NULL
    
    sel_time <- names(tidyselect::eval_select(rlang::enquo(time_col), data))
    if (length(sel_time) == 0) sel_time <- NULL

    # Validation
    if (length(sel_id) != 1) cli::cli_abort("{.arg applicant_id_col} must resolve to 1 column.")
    if (length(sel_cur) != 1) cli::cli_abort("{.arg current_score_col} must resolve to 1 column.")
    if (length(sel_new) != 1) cli::cli_abort("{.arg new_score_col} must resolve to 1 column.")
    if (length(sel_hist_app) != 1) cli::cli_abort("{.arg historical_approval_col} must resolve to 1 column.")
    if (length(sel_hist_hired) != 1) cli::cli_abort("{.arg historical_hired_col} must resolve to 1 column.")
    if (length(sel_act_def) != 1) cli::cli_abort("{.arg actual_default_col} must resolve to 1 column.")

    if (!is.numeric(aggravation_factor) || length(aggravation_factor) != 1 || aggravation_factor <= 0) {
        cli::cli_abort("{.arg aggravation_factor} must be a positive numeric scalar.")
    }

    cli::cli_alert_info("1. Simulating Challenger Policy (Cutoff = {new_score_cutoff})...")

    # Calculate new approval logic
    data$new_approval <- as.integer(data[[sel_new]] >= new_score_cutoff)

    # Identify quadrants (Tradeoff Scenarios)
    data$scenario <- dplyr::case_when(
        data[[sel_hist_app]] == 1 & data$new_approval == 1 ~ "keep_in",
        data[[sel_hist_app]] == 0 & data$new_approval == 1 ~ "swap_in",
        data[[sel_hist_app]] == 1 & data$new_approval == 0 ~ "swap_out",
        data[[sel_hist_app]] == 0 & data$new_approval == 0 ~ "keep_out",
        TRUE ~ NA_character_
    )

    cli::cli_alert_info("2. Extracting Real-World Implied Conversion Rates...")

    # Real conversion rate per new score decile
    data$score_tier <- dplyr::ntile(data[[sel_new]], 10)

    conversion_rates <- data %>%
        dplyr::filter(.data[[sel_hist_app]] == 1) %>%
        dplyr::group_by(.data$score_tier) %>%
        dplyr::summarise(implied_conversion = mean(.data[[sel_hist_hired]], na.rm = TRUE), .groups = "drop")

    # Attach conversion rates for projection
    data <- data %>%
        dplyr::left_join(conversion_rates, by = "score_tier")

    # Default to global conversion if missing
    global_conversion <- mean(data[[sel_hist_hired]][data[[sel_hist_app]] == 1], na.rm = TRUE)
    data$implied_conversion[is.na(data$implied_conversion)] <- global_conversion

    if (method == "stochastic") {
        data$new_hired <- data$new_approval * as.integer(stats::runif(nrow(data)) < data$implied_conversion)
    } else {
        # Analytical mode: Expected conversion
        data$new_hired <- data$new_approval * data$implied_conversion
    }

    cli::cli_alert_info("3. Computing Ward Risk Clustering on Challenger Population...")

    # Create the target subset for clustering
    # In analytical mode, new_approval is a probability, so we take anyone with p > 0
    approved_data <- data %>% dplyr::filter(.data$new_approval > 0)

    rg <- find_risk_groups(
        data = approved_data,
        score_cols = dplyr::all_of(sel_new),
        default_col = dplyr::all_of(sel_act_def),
        time_col = if (!is.null(sel_time)) dplyr::all_of(sel_time) else NULL,
        min_vol_ratio = 0.05,
        max_crossings = 1L,
        bins = 10,
        max_groups = 7
    )

    # Inject Risk Ratings back to main dataset
    data <- data %>% dplyr::left_join(rg$data %>% dplyr::select(dplyr::all_of(c(sel_id, "risk_rating"))), by = sel_id)

    cli::cli_h2("4. Applying {aggravation_factor}x Stress Aggravation by Risk Rating to Swap-Ins...")

    # Calculate Baseline Default by Risk Rating (Keep-Ins only)
    if (method == "stochastic") {
        baselines <- data %>%
            dplyr::filter(.data$scenario == "keep_in", .data$new_hired == 1) %>%
            dplyr::group_by(.data$risk_rating) %>%
            dplyr::summarise(pd_baseline = mean(.data[[sel_act_def]], na.rm = TRUE), .groups = "drop")
    } else {
        # Analytical: Weighted mean (defaults weighted by hire probability)
        # Note: actual_default_col is 0/1 for keep_ins
        baselines <- data %>%
            dplyr::filter(.data$scenario == "keep_in", .data$new_hired > 0) %>%
            dplyr::group_by(.data$risk_rating) %>%
            dplyr::summarise(
                pd_baseline = sum(.data[[sel_act_def]] * .data$new_hired, na.rm = TRUE) / sum(.data$new_hired, na.rm = TRUE),
                .groups = "drop"
            )
    }

    data <- data %>% dplyr::left_join(baselines, by = "risk_rating")

    # Fallback for risk ratings with no keep-ins: Global average
    keep_ins_mask <- data$scenario == "keep_in" & !is.na(data$scenario)
    global_pd_baseline <- if (method == "stochastic") {
        mean(data[[sel_act_def]][keep_ins_mask & data$new_hired == 1], na.rm = TRUE)
    } else {
        sum(as.numeric(data[[sel_act_def]][keep_ins_mask]) * data$new_hired[keep_ins_mask], na.rm = TRUE) /
            sum(data$new_hired[keep_ins_mask], na.rm = TRUE)
    }
    data$pd_baseline[is.na(data$pd_baseline) & !is.na(data$risk_rating)] <- global_pd_baseline

    # Apply empirical defaults to Keep-Ins, Stressed prediction to Swap-Ins
    if (method == "stochastic") {
        data$simulated_default <- dplyr::case_when(
            data$scenario == "keep_in" ~ (as.numeric(data[[sel_act_def]])),
            data$scenario == "swap_in" ~ as.numeric(stats::runif(nrow(data)) < (data$pd_baseline * aggravation_factor)),
            TRUE ~ NA_real_
        )
    } else {
        # Analytical mode: Expected PD (Production-weighted)
        data$simulated_default <- dplyr::case_when(
            data$scenario == "keep_in" ~ (as.numeric(data[[sel_act_def]]) * data$new_hired),
            data$scenario == "swap_in" ~ (data$pd_baseline * aggravation_factor * data$new_hired),
            TRUE ~ NA_real_
        )
    }

    # Cleanup intermediate columns (Delayed until end)
    data$score_tier <- NULL

    # Summary View
    vol_summary <- data %>%
        dplyr::group_by(.data$scenario) %>%
        dplyr::summarise(
            Applicants = dplyr::n(),
            Approved = sum(.data$new_approval, na.rm = TRUE),
            Hired = sum(.data$new_hired, na.rm = TRUE),
            Bad_Rate = if (method == "analytical") {
                # For swap_out/keep_out, we show historical observed average.
                if (unique(.data$scenario) %in% c("swap_out", "keep_out")) {
                    mean(.data[[sel_act_def]], na.rm = TRUE)
                } else {
                    denom <- sum(.data$new_hired[!is.na(.data$simulated_default)], na.rm = TRUE)
                    if (denom > 0) {
                        sum(.data$simulated_default, na.rm = TRUE) / denom
                    } else {
                        0
                    }
                }
            } else {
                # Stochastic: for dropouts, mean of historical outcome
                if (unique(.data$scenario) %in% c("swap_out", "keep_out")) {
                    mean(.data[[sel_act_def]], na.rm = TRUE)
                } else {
                    mean(.data$simulated_default[.data$new_hired == 1], na.rm = TRUE)
                }
            },
            .groups = "drop"
        )

    cli::cli_alert_success("Simulation complete! Check the $summary output.")

    res <- list(
        data = data,
        risk_groups = rg,
        summary = vol_summary
    )
    class(res) <- c("creditools_simulation_from_data", class(res))
    return(res)
}
