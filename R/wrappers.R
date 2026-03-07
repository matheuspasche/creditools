#' Simulate Challenger Policy Core Metrics from Flat Data
#'
#' @description
#' A high-level analytical wrapper designed for Credit Analysts.
#' Bypasses the complex simulation engine and directly computes
#' volumetric trade-offs, approval funnel metrics, and
#' stressed default rates based on Ward Risk Clustering.
#'
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
#' @param applicant_id_col Name of the column containing unique applicant IDs.
#' @param current_score_col Name of the column containing the current historical score.
#' @param new_score_col Name of the column containing the challenger score.
#' @param historical_approval_col Name of the column with the binary approval flag (1 = Approved, 0 = Rejected).
#' @param historical_hired_col Name of the column with the binary hired/conversion flag (1 = Hired, 0 = Lost).
#' @param actual_default_col Name of the column with the true default flag for hired customers.
#' @param new_score_cutoff The threshold for the challenger score to approve an applicant.
#' @param aggravation_factor The +X% stress applied to Swap-Ins (defaults to 1.30 for 30% penalty).
#' @param time_col Optional. Name of the vintage/date column to ensure temporal stability in Risk Groups.
#'
#' @return A list containing the resulting metrics, the generated risk groups, and the appended dataset.
#' @export
#'
simulate_from_data <- function(data,
                               applicant_id_col = "id",
                               current_score_col = "current_score",
                               new_score_col = "new_score",
                               historical_approval_col = "approved",
                               historical_hired_col = "hired",
                               actual_default_col = "defaulted",
                               new_score_cutoff,
                               aggravation_factor = 1.30,
                               time_col = NULL) {
    cli::cli_h1("Creditools: Analytical Simulation from Flat Data")

    # Ensure target columns exist
    req_cols <- c(applicant_id_col, current_score_col, new_score_col, historical_approval_col, historical_hired_col, actual_default_col)
    missing <- setdiff(req_cols, names(data))
    if (length(missing) > 0) {
        cli::cli_abort("Missing required columns in data: {.var {missing}}")
    }

    if (!is.numeric(aggravation_factor) || length(aggravation_factor) != 1 || aggravation_factor <= 0) {
        cli::cli_abort("{.arg aggravation_factor} must be a positive numeric scalar.")
    }

    cli::cli_alert_info("1. Simulating Challenger Policy (Cutoff = {new_score_cutoff})...")

    # Calculate new approval logic
    data$new_approval <- as.integer(data[[new_score_col]] >= new_score_cutoff)

    # Identify quadrants (Tradeoff Scenarios)
    data$scenario <- dplyr::case_when(
        data[[historical_approval_col]] == 1 & data$new_approval == 1 ~ "keep_in",
        data[[historical_approval_col]] == 0 & data$new_approval == 1 ~ "swap_in",
        data[[historical_approval_col]] == 1 & data$new_approval == 0 ~ "swap_out",
        data[[historical_approval_col]] == 0 & data$new_approval == 0 ~ "keep_out",
        TRUE ~ NA_character_
    )

    cli::cli_alert_info("2. Extracting Real-World Implied Conversion Rates...")

    # Real conversion rate per new score decile
    data$score_tier <- dplyr::ntile(data[[new_score_col]], 10)

    conversion_rates <- data %>%
        dplyr::filter(!!rlang::sym(historical_approval_col) == 1) %>%
        dplyr::group_by(.data$score_tier) %>%
        dplyr::summarise(implied_conversion = mean(!!rlang::sym(historical_hired_col), na.rm = TRUE), .groups = "drop")

    # Attach conversion rates for projection
    data <- data %>%
        dplyr::left_join(conversion_rates, by = "score_tier")

    # Default to global conversion if missing
    global_conversion <- mean(data[[historical_hired_col]][data[[historical_approval_col]] == 1], na.rm = TRUE)
    data$implied_conversion[is.na(data$implied_conversion)] <- global_conversion

    data$new_hired <- data$new_approval * as.integer(stats::runif(nrow(data)) < data$implied_conversion)

    cli::cli_alert_info("3. Computing Ward Risk Clustering on Challenger Population...")

    # Create the target subset for clustering
    approved_data <- data %>% dplyr::filter(.data$new_approval == 1)

    rg <- find_risk_groups(
        data = approved_data,
        score_cols = new_score_col,
        default_col = actual_default_col,
        time_col = time_col,
        min_vol_ratio = 0.05,
        max_crossings = 1L,
        bins = 10,
        max_groups = 7
    )

    # Inject Risk Ratings back to main dataset
    data <- data %>% dplyr::left_join(rg$data %>% dplyr::select(dplyr::all_of(c(applicant_id_col, "risk_rating"))), by = applicant_id_col)

    cli::cli_alert_info("4. Applying {aggravation_factor}x Stress Aggravation by Risk Rating to Swap-Ins...")

    # Calculate Baseline Default by Risk Rating (Keep-Ins only)
    baselines <- data %>%
        dplyr::filter(.data$scenario == "keep_in", .data$new_hired == 1) %>%
        dplyr::group_by(.data$risk_rating) %>%
        dplyr::summarise(pd_baseline = mean(!!rlang::sym(actual_default_col), na.rm = TRUE), .groups = "drop")

    data <- data %>% dplyr::left_join(baselines, by = "risk_rating")

    # Apply empirical defaults to Keep-Ins, Stressed prediction to Swap-Ins
    data$simulated_default <- dplyr::case_when(
        data$scenario == "keep_in" ~ (data[[actual_default_col]]),
        data$scenario == "swap_in" ~ as.integer(stats::runif(nrow(data)) < (data$pd_baseline * aggravation_factor)),
        TRUE ~ NA_integer_
    )

    # Cleanup intermediate columns
    data$score_tier <- NULL
    data$pd_baseline <- NULL

    # Summary View
    vol_summary <- data %>%
        dplyr::group_by(.data$scenario) %>%
        dplyr::summarise(
            Applicants = dplyr::n(),
            Approved = sum(.data$new_approval, na.rm = TRUE),
            Hired = sum(.data$new_hired, na.rm = TRUE),
            Bad_Rate = mean(.data$simulated_default[.data$new_hired == 1], na.rm = TRUE),
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
