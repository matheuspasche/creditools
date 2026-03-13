#' Kolmogorov-Smirnov (KS) Diagnostic Table
#'
#' @description
#' Generates a comprehensive performance table for a credit score, including
#' event/non-event distributions by quantiles and the Kolmogorov-Smirnov (KS)
#' statistic. This table is a standard tool for assessing model discrimination power.
#'
#' @param data A data frame containing the score and the binary target.
#' @param score_col Column for the score. (Uses \code{tidyselect} syntax).
#'   Higher scores should usually represent lower risk.
#' @param default_col Column for the target. (Uses \code{tidyselect} syntax, e.g., defaulted = 1, non-event = 0).
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
#' @importFrom dplyr group_by summarize mutate n arrange ntile filter
#' @importFrom rlang sym .data enquo
#' @importFrom tidyselect eval_select
#' @family performance
#' @export
#'
#' @examples
#' data(applicants)
#' # Standard Decile Table using names
#' calculate_ks_table(applicants, old_score, defaulted, n_bins = 10)
#' 
#' # Using strings (works thanks to tidyselect)
#' calculate_ks_table(applicants, "old_score", "defaulted")
calculate_ks_table <- function(data, score_col, default_col, n_bins = 10) {

    # Resolve columns with tidyselect
    score_expr <- rlang::enquo(score_col)
    default_expr <- rlang::enquo(default_col)
    
    sel_score <- names(tidyselect::eval_select(score_expr, data))
    sel_default <- names(tidyselect::eval_select(default_expr, data))
    
    if (length(sel_score) != 1) cli::cli_abort("{.arg score_col} must resolve to exactly one column.")
    if (length(sel_default) != 1) cli::cli_abort("{.arg default_col} must resolve to exactly one column.")

    # Filter NAs
    data <- data %>%
        dplyr::filter(!is.na(!!rlang::sym(sel_score)), !is.na(!!rlang::sym(sel_default)))

    # Total Statistics
    total_events <- sum(data[[sel_default]], na.rm = TRUE)
    total_non_events <- nrow(data) - total_events

    # Calculate Bins
    res <- data %>%
        dplyr::mutate(
            bin = dplyr::ntile(!!rlang::sym(sel_score), n_bins)
        ) %>%
        dplyr::group_by(.data$bin) %>%
        dplyr::summarize(
            non_event = sum(!!rlang::sym(sel_default) == 0, na.rm = TRUE),
            event = sum(!!rlang::sym(sel_default) == 1, na.rm = TRUE),
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

    res$cum_pct_event[res$cum_pct_event > 1.0] <- 1.0
    res$cum_pct_non_event[res$cum_pct_non_event > 1.0] <- 1.0

    attr(res, "ks_metric") <- max(res$diff, na.rm = TRUE)

    return(res)
}
