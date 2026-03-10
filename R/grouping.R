#' Find Stable Risk Groups (Ratings) from Multiple Scores
#'
#' @description
#' `find_risk_groups()` is a powerful analytical engine designed to create a unified,
#' stable risk rating from one or multiple challenger scores. It automatically mattresses
#' the scores, generates a 1D risk ranking based on expected defaults, and applies
#' statistical pruning algorithms (Volume Pruning and Non-Crossing Stability Pruning)
#' to merge statistically insignificant or overlapping bands across time (vintages).
#'
#' @param data A data frame containing the historical applicant data.
#' @param score_cols A character vector containing the names of the score columns to matrix.
#' @param default_col A character string with the column name indicating the observed default (0 or 1).
#' @param time_col A character string with the column name representing the vintage/time cohort (e.g., "YYYY-MM"). It will be internally coerced to Date.
#' @param min_vol_ratio The minimum acceptable population percentage for a risk group. Groups below this threshold are merged with their nearest risk neighbor. Default is 0.05 (5%).
#' @param max_crossings Maximum number of vintage periods where an adjacent lower-risk group can have a HIGHER observed PD than the next group (crossing). Uses absolute count, not proportion - so it is robust to small vintage windows (6-18 months). Default is `1`, meaning at most 1 month of inversion is tolerated before forcing a merge.
#' @param bins An integer defining the granularity of the initial matrix grid before pruning. E.g., `bins = 20` slices each score into 20 tiles (every 5 percentiles).
#' @param oot_date An optional cutoff Date/POSIXt object. Data where `time_col >= oot_date` will be preserved exclusively for Out-Of-Time (OOT) validation reporting.
#' @param max_groups An optional integer specifying the maximum number of risk groups to return. If NULL, pruning is driven solely by volume and stability thresholds.
#' @param quiet Whether to suppress progress and status messages. Default is FALSE.
#' @param ... Additional options passed to internal functions (e.g., `parallel = TRUE`, `n_workers = 4`).
#'
#' @return A list containing:
#'   - `$data`: The original data frame with a new column `final_risk_group` attached to each row.
#'   - `$mapping`: A lookup table defining the boundaries of the final merged risk groups.
#'   - `$report`: A summary tibble validating the monotonicity and volume of the final hierarchy in BOTH train and OOT periods.
#'
#' @importFrom dplyr mutate filter group_by summarize arrange ntile bind_rows left_join n pull select everything
#' @importFrom purrr reduce map_df
#' @importFrom rlang .data
#' @importFrom tidyr drop_na pivot_wider
#' @export
#'
#' @examples
#' # Use the built-in applicants dataset
#' data(applicants)
#' groups <- find_risk_groups(
#'     data = applicants,
#'     score_cols = "old_score",
#'     default_col = "defaulted",
#'     time_col = "vintage",
#'     max_groups = 5
#' )
#'
#' # View the distribution of PD across groups
#' print(groups$report)
#'
#' # Visualize the group stability over time
#' plot(groups)
find_risk_groups <- function(data,
                             score_cols,
                             default_col,
                             time_col = NULL,
                             min_vol_ratio = 0.05,
                             max_crossings = 1L,
                             bins = 20,
                             oot_date = NULL,
                             max_groups = NULL,
                             quiet = FALSE,
                             ...) {

    # Basic Validation
    missing_cols <- setdiff(c(score_cols, default_col, time_col), names(data))
    if (length(missing_cols) > 0) {
        cli::cli_abort("Missing columns in data: {.field {missing_cols}}")
    }

    # Strict Date Evaluation (only if time_col provided)
    if (!is.null(time_col)) {
        if (!inherits(data[[time_col]], c("Date", "POSIXt"))) {
            cli::cli_abort("Column {.arg {time_col}} must be a Date or POSIXt object. Please format your data before matrixing.")
        }
    }

    # Handle Parallelism Setup
    parallel_setup <- .setup_parallel(...)
    parallel <- parallel_setup$parallel

    # 1. Split Train & OOT
    if (!is.null(oot_date) && !is.null(time_col)) {
        if (!inherits(oot_date, c("Date", "POSIXt"))) {
            cli::cli_abort("{.arg oot_date} must be a Date or POSIXt object.")
        }

        train_data <- data %>% dplyr::filter(!!rlang::sym(time_col) < oot_date)
        oot_data <- data %>% dplyr::filter(!!rlang::sym(time_col) >= oot_date)
        if (nrow(oot_data) == 0) cli::cli_warn("OOT Date provided but no data fell into the OOT horizon.")
    } else {
        train_data <- data
        oot_data <- data.frame()
    }

    # --- STEP 1 & 2: INITIAL N-DIMENSIONAL BINNING & 1D EMPIRICAL RANKING ---

    # Bin each score independently into tiles
    bin_cols <- paste0(score_cols, "_bin")
    for (i in seq_along(score_cols)) {
        sc <- score_cols[i]
        bc <- bin_cols[i]
        train_data[[bc]] <- dplyr::ntile(train_data[[sc]], bins)
    }

    # Aggregate combinations and determine their global empirical PD
    matrix_summary <- train_data %>%
        dplyr::group_by(dplyr::across(dplyr::all_of(bin_cols))) %>%
        dplyr::summarize(
            combo_vol = dplyr::n(),
            combo_bads = sum(!!rlang::sym(default_col), na.rm = TRUE),
            empirical_pd = .data$combo_bads / .data$combo_vol,
            .groups = "drop"
        ) %>%
        # Sort from Lowest Risk to Highest Risk
        dplyr::arrange(.data$empirical_pd) %>%
        # Assign an initial continuous 1D ranking
        dplyr::mutate(micro_rating = dplyr::row_number())

    # Append ranking back to training data for vintage-level aggregations
    train_data <- train_data %>%
        dplyr::left_join(matrix_summary %>% dplyr::select(dplyr::all_of(c(bin_cols, "micro_rating"))), by = bin_cols)

    # --- SETUP MATHEMATICAL BASE ---
    total_vol <- nrow(train_data)

    current_groups <- matrix_summary %>%
        dplyr::select(dplyr::all_of(c("micro_rating", "empirical_pd", "combo_vol"))) %>%
        dplyr::mutate(group_id = .data$micro_rating)

    # Pre-calculate monthly PDs for stability checks (only if time_col provided)
    if (!is.null(time_col)) {
        monthly_stats <- train_data %>%
            dplyr::group_by(.data$micro_rating, !!rlang::sym(time_col)) %>%
            dplyr::summarize(
                bads = sum(!!rlang::sym(default_col), na.rm = TRUE),
                vols = dplyr::n(),
                .groups = "drop"
            )
    } else {
        monthly_stats <- NULL
    }

    # --- AGGLOMERATIVE CLUSTERING OPTIMIZATION LOOP ---
    if (!quiet) cli::cli_alert_info("Optimizing risk clusters (Ward Distance + Stability)...")

    converged <- FALSE
    while (!converged) {
        group_bads_vols <- current_groups %>%
            dplyr::mutate(combo_bads = .data$empirical_pd * .data$combo_vol) %>%
            dplyr::group_by(.data$group_id) %>%
            dplyr::summarize(
                vol = sum(.data$combo_vol),
                bads = sum(.data$combo_bads),
                pd = .data$bads / .data$vol,
                .groups = "drop"
            ) %>%
            dplyr::arrange(.data$group_id)

        group_summary <- group_bads_vols %>%
            dplyr::mutate(vol_ratio = .data$vol / total_vol, mean_pd = .data$pd)

        n_groups <- nrow(group_summary)
        if (n_groups <= 1) break

        if (!is.null(monthly_stats)) {
            current_monthly <- monthly_stats %>%
                dplyr::inner_join(current_groups %>% dplyr::select(dplyr::all_of(c("micro_rating", "group_id"))), by = "micro_rating") %>%
                dplyr::group_by(.data$group_id, !!rlang::sym(time_col)) %>%
                dplyr::summarize(
                    pd = sum(.data$bads) / sum(.data$vols),
                    .groups = "drop"
                ) %>%
                tidyr::pivot_wider(names_from = tidyselect::all_of("group_id"), values_from = tidyselect::all_of("pd"))
        } else {
            current_monthly <- NULL
        }

        g_ids <- group_summary$group_id

        # NOTE: Benchmarks showed that parallelizing this inner loop
        # (furrr::future_map) is counter-productive due to overhead of small tasks.
        # Keeping it sequential for maximum efficiency in single-run clustering.
        min_cost <- Inf
        best_pair <- NULL

        for (i in seq_len(n_groups - 1)) {
            g1 <- g_ids[i]
            g2 <- g_ids[i + 1]

            v1 <- group_summary$vol_ratio[i]
            v2 <- group_summary$vol_ratio[i + 1]

            pd1 <- group_summary$mean_pd[i]
            pd2 <- group_summary$mean_pd[i + 1]

            # Ward Distance
            delta <- (v1 * v2) / (v1 + v2) * (pd1 - pd2)^2
            cost <- delta

            # Priority 1: Monotonicity (Inversion / Flat)
            if (pd1 >= pd2) {
                cost <- -1e9 + delta
            }
            # Priority 2: Volume constraint
            else if (v1 < min_vol_ratio || v2 < min_vol_ratio) {
                if (cost > -1e6) cost <- -1e6 + delta
            }
            # Priority 3: Stability (Non-Crossing)
            else {
                col1 <- as.character(g1)
                col2 <- as.character(g2)

                if (!is.null(current_monthly) && col1 %in% names(current_monthly) && col2 %in% names(current_monthly)) {
                    valid_idx <- !is.na(current_monthly[[col1]]) & !is.na(current_monthly[[col2]])
                    if (sum(valid_idx) > 0) {
                        n_crossings <- sum(current_monthly[[col1]][valid_idx] >= current_monthly[[col2]][valid_idx])
                        if (n_crossings > max_crossings) {
                            if (cost > -1e3) cost <- -1e3 + delta
                        }
                    }
                }
            }

            if (cost < min_cost) {
                min_cost <- cost
                best_pair <- c(g1, g2)
            }
        }

        if (min_cost < 0) {
            # Constraint violated: Merge the pair with the most urgent penalty (and smallest delta)
            current_groups <- current_groups %>%
                dplyr::mutate(group_id = ifelse(.data$group_id == best_pair[2], best_pair[1], .data$group_id))
            current_groups$group_id <- as.integer(as.factor(current_groups$group_id))
        } else {
            # Constraints satisfied
            # Priority 4: Max Groups Tail Compression
            if (!is.null(max_groups) && n_groups > max_groups) {
                current_groups <- current_groups %>%
                    dplyr::mutate(group_id = ifelse(.data$group_id == best_pair[1] | .data$group_id == best_pair[2], min(best_pair), .data$group_id))
                current_groups$group_id <- as.integer(as.factor(current_groups$group_id))
            } else {
                converged <- TRUE
            }
        }
    }

    # --- FINALIZING AND REPORTING ---

    # We have our finalized groups (Ratings)! Let's build a lookup dictionary mapping the initial N-Dimensional Bins to the Final Group.
    final_mapping <- matrix_summary %>%
        dplyr::select(dplyr::all_of(bin_cols), dplyr::all_of("micro_rating")) %>%
        dplyr::left_join(current_groups %>% dplyr::select(dplyr::all_of(c("micro_rating", "group_id"))), by = "micro_rating") %>%
        dplyr::rename(risk_rating = "group_id")

    # Function to apply the mappings safely to any dataset
    apply_ratings <- function(df) {
        # Bin scores according to provided parameters
        # (Internal ntile is vectorized across rows but we do have multiple scores)
        for (i in seq_along(score_cols)) {
            sc <- score_cols[i]
            bc <- bin_cols[i]
            df[[bc]] <- dplyr::ntile(df[[sc]], bins)
        }

        # Left join the master lookup
        df <- df %>%
            dplyr::left_join(final_mapping %>% dplyr::select(-"micro_rating"), by = bin_cols)

        # Clean up transient bin columns
        df <- df %>% dplyr::select(-dplyr::all_of(bin_cols))
        return(df)
    }

    train_data <- apply_ratings(
        train_data %>% dplyr::select(-dplyr::any_of(c(bin_cols, "micro_rating")))
    )

    if (nrow(oot_data) > 0) {
        oot_data <- apply_ratings(oot_data)
        final_data <- dplyr::bind_rows(train_data, oot_data)
    } else {
        final_data <- train_data
    }

    # Generate High-Level Summary Report
    summarize_group <- function(df, period_name) {
        df %>%
            dplyr::group_by(.data$risk_rating) %>%
            dplyr::summarize(
                period = period_name,
                total_vol = dplyr::n(),
                avg_pd = sum(!!rlang::sym(default_col), na.rm = TRUE) / .data$total_vol,
                .groups = "drop"
            )
    }

    report <- summarize_group(train_data, "Train")
    if (nrow(oot_data) > 0) {
        report <- dplyr::bind_rows(report, summarize_group(oot_data, "OOT (Validation)"))
    }

    res <- list(
        data = final_data,
        mapping = final_mapping,
        report = report,
        metadata = list(
            score_cols = score_cols,
            default_col = default_col,
            time_col = time_col,
            min_vol_ratio = min_vol_ratio,
            max_crossings = max_crossings,
            bins = bins,
            oot_date = oot_date,
            max_groups = max_groups
        )
    )

    class(res) <- c("credit_risk_groups", class(res))
    return(res)
}

#' Pairwise Matrixing of Challengers vs Primary Score
#'
#' @description
#' `find_pairwise_risk_groups()` is a convenience wrapper that tests a single `primary_score`
#' against a vector of `challenger_scores`. Instead of attempting a massive N-Dimensional
#' cross (which geometrically blows up for 3+ scores), it iterates 1x1 (primary vs challenger 1,
#' primary vs challenger 2...) and generates parallel Risk Groups. Includes a progress bar mapping
#' the heavy algorithmic lifting natively.
#'
#' @param data A data frame containing the historical applicant data.
#' @param primary_score A character string. The baseline/legacy score.
#' @param challenger_scores A character vector containing the names of the challenger score columns.
#' @param default_col A character string with the column name indicating the observed default (0 or 1).
#' @param time_col A character string with the column name representing the vintage/time cohort.
#' @param quiet Whether to suppress progress and status messages. Default is FALSE.
#' @param ... Additional arguments passed natively to `find_risk_groups()` (e.g., `parallel = TRUE`).
#'
#' @return A named list where each element contains the clustered Output List from `find_risk_groups` tied to a specific Challenger.
#' @export
#'
#' @examples
#' data(applicants)
#' results <- find_pairwise_risk_groups(
#'     data = applicants,
#'     primary_score = "old_score",
#'     challenger_scores = "new_score",
#'     default_col = "defaulted",
#'     time_col = "vintage",
#'     max_groups = 3
#' )
find_pairwise_risk_groups <- function(data,
                                      primary_score,
                                      challenger_scores,
                                      default_col,
                                      time_col,
                                      quiet = FALSE,
                                      ...) {
    if (!quiet && requireNamespace("cli", quietly = TRUE)) {
        cli::cli_alert_info("Starting pairwise Risk Group search for 1 Primary vs {length(challenger_scores)} Challengers...")
    }

    # Handle Parallelism Setup
    parallel_setup <- .setup_parallel(...)
    parallel <- parallel_setup$parallel

    # Capture dots for passing to find_risk_groups
    extra_args <- list(...)

    results_list <- .parallel_map(
        .x = challenger_scores,
        .f = function(challenger) {
            if (!quiet && requireNamespace("cli", quietly = TRUE)) {
                cli::cli_alert_info("Matrixing: {primary_score} x {challenger}")
            }
            # Prevent nested parallelism by forcing parallel = FALSE in the inner call
            inner_args <- utils::modifyList(extra_args, list(parallel = FALSE))
            res <- do.call(find_risk_groups, c(list(
                data = data,
                score_cols = c(primary_score, challenger),
                default_col = default_col,
                time_col = time_col,
                quiet = quiet
            ), inner_args))
            return(list(challenger = challenger, result = res))
        },
        .parallel = parallel,
        .progress = !quiet,
        # Don't pass furrr_options directly in the argument evaluation
        .options = list(globals = TRUE, packages = c("creditools", "dplyr"))
    )

    # Reconstruct named list
    results <- list()
    for (item in results_list) {
        results[[paste0(primary_score, "_vs_", item$challenger)]] <- item$result
    }

    return(results)
}
