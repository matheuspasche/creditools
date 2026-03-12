#' High-Scale Risk Segmentation Screening (Furar a Folhinha)
#'
#' @description
#' `screen_risk_segments()` identifying candidate variables that can further segment
#' existing risk groups (ratings) and increase overall discrimination power. It is designed
#' for high scalability, allowing the analysis of thousands of candidate variables
#' against a baseline grouping.
#'
#' @details
#' ### High-Scale Screening (Furar a Folhinha)
#' This function identifies which variables can most effectively "break" or further refine
#' existing risk groups. It is particularly useful for finding sub-segments (e.g., Rating 3.1, 3.2)
#' that have significantly different default behaviors.
#'
#' ### Longitudinal Segmentation
#' When `method` is `"ward"` or `"iv"`, the engine uses longitudinal clustering. It attempts to
#' find sub-segments that are not only different in their average PD, but whose PD curves are
#' stable and non-crossing over time (vintages). This ensures that the newly discovered
#' sub-segments are robust and not just artifacts of a specific time period.
#'
#' @param data A data frame containing the historical data.
#' @param base_risk_col Character. The name of the existing risk group/rating column.
#' @param candidate_cols Columns to test for segmentation power. (Uses \code{tidyselect} syntax).
#' @param default_col Character. The binary target column name (e.g., 0/1).
#' @param n_bins Integer. Number of quantiles to use for discretizing candidate variables. Default is 10.
#' @param method Character. The segmentation method: `"quantiles"` (default), `"ward"`, or `"iv"`.
#' @param max_groups Integer. Maximum number of sub-segments to create per tier (only used if `method` is `"ward"` or `"iv"`). Default is `NULL`.
#' @param min_vol_ratio Numeric. Minimum volume ratio for sub-segments (only used if `method` is `"ward"` or `"iv"`). Default is `0.01` (1%).
#' @param parallel Logical. Whether to use parallel processing (requires `future::plan()`). Default is `FALSE`.
#' @param .progress Logical. Whether to show a progress bar. Default is `FALSE`.
#' @param ... Additional arguments passed to internal functions (e.g., `lambda_cross`, `lambda_vol`).
#'
#' @return An object of class \code{credit_risk_screening}, which is a list containing:
#' \itemize{
#'   \item \code{metrics}: A long-format tibble reporting segmentation power (IV, PD Spread) for each variable/tier.
#'   \item \code{recipes}: A nested list of quantile boundaries and cluster mappings, enabling \code{predict()}.
#'   \item \code{metadata}: Internal parameters used during screening.
#' }
#'
#' @importFrom dplyr group_by summarise mutate n arrange ntile across all_of filter bind_rows select
#' @importFrom rlang sym .data
#' @importFrom purrr map_dfr
#' @importFrom furrr future_map_dfr
#' @importFrom tidyselect eval_select
#' @importFrom utils head
#' @family performance
#' @export
#'
#' @examples
#' \donttest{
#' data(applicants)
#' # Create a base grouping first
#' base_model <- find_risk_groups(applicants, "old_score", "defaulted", max_groups = 5)
#' applicants$rating <- base_model$data$risk_rating
#'
#' # Screen for variables that can "break" these ratings using tidyselect
#' screening <- screen_risk_segments(
#'     data = applicants,
#'     base_risk_col = "rating",
#'     candidate_cols = c(new_score, bureau_derogatory), # or everything(), starts_with(), etc.
#'     default_col = "defaulted",
#'     n_bins = 5,
#'     .progress = TRUE
#' )
#'
#' head(screening)
#' }
screen_risk_segments <- function(data,
                                 base_risk_col,
                                 candidate_cols,
                                 default_col,
                                 n_bins = 10,
                                 method = c("quantiles", "ward", "iv"),
                                 max_groups = NULL,
                                 min_vol_ratio = 0.01,
                                 parallel = FALSE,
                                 .progress = FALSE,
                                 ...) {
    method <- match.arg(method)

    # 1. Resolve Columns with Tidyselect
    # We use enquo to capture the expression for candidate_cols
    candidate_expr <- rlang::enquo(candidate_cols)
    selected_vars <- tidyselect::eval_select(candidate_expr, data)
    actual_candidates <- unique(names(selected_vars))

    # Basic Validation
    required_cols <- c(base_risk_col, default_col)
    missing <- setdiff(required_cols, names(data))
    if (length(missing) > 0) {
        cli::cli_abort("Missing columns in data: {.field {missing}}")
    }

    if (length(actual_candidates) == 0) {
        cli::cli_abort("No valid candidate columns selected.")
    }

    # 2. Setup Parallel Processing
    parallel_setup <- .setup_parallel(parallel = parallel, ...)

    # Pre-fetch vectors for speed and handle NAs in base/default once
    # We can't drop NAs for ALL candidates at once though (sparse data)
    # But we can at least have the base and default vectors ready
    base_vec <- as.integer(as.factor(data[[base_risk_col]]))
    default_vec <- as.integer(data[[default_col]])

    # 3. Process Variables in Batches
    # To save memory in parallel mode (multisession), we avoid sending thousands of large
    # vectors to workers at once. Instead, we process in manageable chunks.

    # 3. Process Variables in Batches
    batch_size <- if (parallel_setup$parallel) 100 else length(actual_candidates)
    var_batches <- split(actual_candidates, ceiling(seq_along(actual_candidates) / batch_size))

    # Internal worker function
    worker_fn <- function(var_name, data_vec, b_vec, d_vec, bins, method, max_groups, min_vol_ratio, extra_args) {
        valid_idx <- !is.na(data_vec) & !is.na(b_vec) & !is.na(d_vec)
        if (sum(valid_idx) == 0) return(NULL)

        x_vals <- as.numeric(data_vec[valid_idx])
        b_vals <- b_vec[valid_idx]
        d_vals <- d_vec[valid_idx]

        # 1. Capture boundaries for 'predict'
        q_probs <- seq(0, 1, length.out = bins + 1)
        bounds <- stats::quantile(x_vals, q_probs, na.rm = TRUE)
        bounds <- unique(bounds)

        # 2. Apply binning using findInterval for consistency
        bin_id <- findInterval(x_vals, bounds, all.inside = TRUE)

        if (method == "quantiles") {
            tier_metrics <- rcpp_calculate_tier_metrics(x_vals, b_vals, d_vals, bins)
            u_groups <- sort(unique(b_vals))
            sub_mappings <- stats::setNames(lapply(u_groups, function(g) seq_len(bins)), as.character(u_groups))
        } else {
            u_groups <- sort(unique(b_vals))
            tier_results <- list()
            sub_mappings <- list()

            for (g in u_groups) {
                g_idx <- b_vals == g
                if (sum(g_idx) == 0) next

                gx <- x_vals[g_idx]
                gd <- d_vals[g_idx]
                bin_id_g <- bin_id[g_idx]

                m_vols <- matrix(0, nrow = bins, ncol = 1)
                m_bads <- matrix(0, nrow = bins, ncol = 1)

                summary_bins <- tibble::tibble(bin = bin_id_g, d = gd) %>%
                    dplyr::group_by(.data$bin) %>%
                    dplyr::summarise(vol = dplyr::n(), bads = sum(.data$d), .groups = "drop")

                m_vols[summary_bins$bin, 1] <- summary_bins$vol
                m_bads[summary_bins$bin, 1] <- summary_bins$bads

                if (method == "ward") {
                    sub_groups <- rcpp_optimize_clusters(
                        bin_vols = m_vols[, 1],
                        bin_bads = m_bads[, 1],
                        monthly_vols = m_vols,
                        monthly_bads = m_bads,
                        min_vol_ratio = min_vol_ratio,
                        max_crossings = 0,
                        max_groups = if (is.null(max_groups)) 0 else max_groups
                    )
                } else {
                    sub_groups <- rcpp_iv_optimize_clusters(
                        bin_vols = m_vols[, 1],
                        bin_bads = m_bads[, 1],
                        monthly_vols = m_vols,
                        monthly_bads = m_bads,
                        min_vol_ratio = min_vol_ratio,
                        lambda_cross = extra_args$lambda_cross %||% 0.5,
                        lambda_vol = extra_args$lambda_vol %||% 0.2,
                        max_bins = if (is.null(max_groups)) 0 else max_groups
                    )
                }

                # Save mapping for this tier
                sub_mappings[[as.character(g)]] <- sub_groups
                
                # Calculate metrics
                final_sub_tier <- sub_groups[bin_id_g]
                tier_res <- tibble::tibble(sub = final_sub_tier, d = gd) %>%
                    dplyr::group_by(.data$sub) %>%
                    dplyr::summarise(vol = dplyr::n(), bads = sum(.data$d), pd = .data$bads / .data$vol, .groups = "drop")

                total_b <- sum(tier_res$bads)
                total_g <- sum(tier_res$vol) - total_b

                tier_res <- tier_res %>%
                    dplyr::mutate(
                        p_b = (.data$bads + 0.5) / (total_b + 1),
                        p_g = ((.data$vol - .data$bads) + 0.5) / (total_g + 1),
                        woe = log(.data$p_g / .data$p_b),
                        iv_part = (.data$p_g - .data$p_b) * .data$woe
                    )

                tier_results[[length(tier_results) + 1]] <- tibble::tibble(
                    risk_group = g,
                    iv = sum(tier_res$iv_part),
                    pd_min = min(tier_res$pd),
                    pd_max = max(tier_res$pd),
                    tier_vol = sum(tier_res$vol)
                )
            }
            tier_metrics <- dplyr::bind_rows(tier_results)
        }

        metrics_df <- if (is.data.frame(tier_metrics)) tier_metrics else tibble::as_tibble(tier_metrics)
        metrics_df <- metrics_df %>%
            dplyr::mutate(variable = var_name, pd_spread = .data$pd_max - .data$pd_min) %>%
            dplyr::select(dplyr::all_of(c("variable", "risk_group", "iv", "pd_min", "pd_max", "pd_spread", "tier_vol")))

        return(list(
            metrics = metrics_df,
            recipe = stats::setNames(list(list(boundaries = bounds, sub_mappings = sub_mappings)), var_name)
        ))
    }

    results_list <- list()
    for (i in seq_along(var_batches)) {
        batch_vars <- var_batches[[i]]
        cols_batch <- as.list(data[batch_vars])

        batch_res <- .parallel_pmap(
            list(var_name = batch_vars, data_vec = cols_batch),
            worker_fn,
            b_vec = base_vec,
            d_vec = default_vec,
            bins = n_bins,
            method = method,
            max_groups = max_groups,
            min_vol_ratio = min_vol_ratio,
            extra_args = list(...),
            .parallel = parallel_setup$parallel,
            .progress = if (i == 1) .progress else FALSE
        )
        results_list[[i]] <- batch_res
        rm(cols_batch, batch_res)
        if (parallel_setup$parallel) gc()
    }

    # 4. Consolidate Results
    all_results <- unlist(results_list, recursive = FALSE)
    all_metrics <- dplyr::bind_rows(lapply(all_results, function(x) x$metrics))
    all_recipes <- do.call(c, lapply(all_results, function(x) x$recipe))

    res <- list(
        metrics = all_metrics,
        recipes = all_recipes,
        metadata = list(
            base_risk_col = base_risk_col,
            n_bins = n_bins,
            method = method
        )
    )

    class(res) <- "credit_risk_screening"
    return(res)
}

#' Predict Risk Segmentation on New Data
#'
#' @description
#' `predict.credit_risk_screening()` applies the sub-segmentation logic discovered
#' during screening for a specific variable to a new dataset.
#'
#' @param object An object of class `credit_risk_screening`.
#' @param newdata A data frame containing the same base risk and candidate columns.
#' @param variable Character. The name of the variable whose segmentation recipe should be applied.
#' @param output_col Optional. The name of the new column.
#' @param ... Not used.
#'
#' @return The `newdata` data frame with an additional column of sub-segments.
#' @export
#' @importFrom stats predict
predict.credit_risk_screening <- function(object, newdata, variable, output_col = NULL, ...) {
    if (is.null(output_col)) {
        output_col <- paste0(object$metadata$base_risk_col, "_segmented")
    }

    recipe <- object$recipes[[variable]]
    if (is.null(recipe)) {
        cli::cli_abort("Recipe for variable {.field {variable}} not found in screening object.")
    }

    base_risk_col <- object$metadata$base_risk_col
    bounds <- recipe$boundaries
    sub_mappings <- recipe$sub_mappings

    # Process per tier
    u_groups <- names(sub_mappings)
    res_list <- lapply(u_groups, function(g) {
        tier_idx <- newdata[[base_risk_col]] == g
        tier_data <- newdata[tier_idx, , drop = FALSE]
        if (nrow(tier_data) == 0) return(NULL)

        # 1. Apply Quantile Recipe
        bin_id <- findInterval(as.numeric(tier_data[[variable]]), bounds, all.inside = TRUE)

        # 2. Apply Sub-mapping
        sub_map <- sub_mappings[[g]]
        final_sub <- sub_map[bin_id]

        tier_data[[output_col]] <- paste0(g, ".", final_sub)
        return(tier_data)
    })

    return(dplyr::bind_rows(res_list))
}

#' @export
as.data.frame.credit_risk_screening <- function(x, ...) {
    as.data.frame(x$metrics)
}

#' @export
print.credit_risk_screening <- function(x, ...) {
    cli::cli_h1("Risk Segmentation Screening Object")
    cli::cli_alert_info("Variables screened: {.val {length(x$recipes)}}")
    cli::cli_alert_info("Method: {.val {x$metadata$method}} ({x$metadata$n_bins} bins)")
    cat("\n")
    print(head(x$metrics, 10))
    if (nrow(x$metrics) > 10) cli::cli_text("... and {nrow(x$metrics) - 10} more rows.")
    invisible(x)
}

#' @export
summary.credit_risk_screening <- function(object, ...) {
    object$metrics
}

