#' Kolmogorov-Smirnov (KS) Diagnostic Table
#'
#' @description
#' Generates a comprehensive performance table for a credit score, including
#' event/non-event distributions by quantiles and the Kolmogorov-Smirnov (KS)
#' statistic. This table is a standard tool for assessing model discrimination power.
#'
#' @param data A data frame containing the score and the binary target.
#' @param score_col Character. The name of the score column. Higher scores should usually represent lower risk.
#' @param default_col Character. The name of the target column (e.g., defaulted = 1, non-event = 0).
#' @param n_bins Integer. The number of quantiles to split the data into. Default is 10 (deciles).
#'
#' @return A tibble containing:
#'   - `bin`: The quantile index.
#'   - `non_event`: Count of 0s in the bin.
#'   - `event`: Count of 1s in the bin.
#'   - `pct_non_event`: Proportion of total non-events in the bin.
#'   - `pct_event`: Proportion of total events in the bin.
#'   - `cum_pct_event`: Cumulative proportion of events.
#'   - `cum_pct_non_event`: Cumulative proportion of non-events.
#'   - `diff`: The absolute difference between cumulative proportions.
#'
#' @importFrom dplyr group_by summarize mutate n arrange ntile
#' @importFrom rlang sym .data
#' @family performance
#' @export
#'
#' @examples
#' data(applicants)
#' # Standard Decile Table
#' calculate_ks_table(applicants, "old_score", "defaulted", n_bins = 10)
calculate_ks_table <- function(data, score_col, default_col, n_bins = 10) {

    # Filter NAs
    data <- data %>%
        dplyr::filter(!is.na(!!rlang::sym(score_col)), !is.na(!!rlang::sym(default_col)))

    # Total Statistics
    total_events <- sum(data[[default_col]], na.rm = TRUE)
    total_non_events <- nrow(data) - total_events

    # Calculate Bins
    res <- data %>%
        dplyr::mutate(
            bin = dplyr::ntile(!!rlang::sym(score_col), n_bins)
        ) %>%
        dplyr::group_by(.data$bin) %>%
        dplyr::summarize(
            non_event = sum(!!rlang::sym(default_col) == 0, na.rm = TRUE),
            event = sum(!!rlang::sym(default_col) == 1, na.rm = TRUE),
            .groups = "drop"
        ) %>%
        dplyr::arrange(.data$bin) %>%
        dplyr::mutate(
            pct_non_event = (.data$non_event / total_non_events),
            pct_event = (.data$event / total_events),
            cum_pct_event = cumsum(.data$pct_event),
            cum_pct_non_event = cumsum(.data$pct_non_event),
            diff = abs(.data$cum_pct_event - .data$cum_pct_non_event)
        )

    # Ensure cum totals don't exceed 1.0 due to rounding
    res$cum_pct_event[res$cum_pct_event > 1.0] <- 1.0
    res$cum_pct_non_event[res$cum_pct_non_event > 1.0] <- 1.0

    return(res)
}
