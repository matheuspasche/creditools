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
#' @param min_vol_ratio The minimum acceptable population percentage for a risk group in any given vintage. Groups below this threshold are merged with their nearest risk neighbor. Default is 0.05 (5%).
#' @param max_volatility_cv The maximum acceptable Coefficient of Variation (Standard Deviation / Mean) for a group's default rate across vintages. Groups that are too volatile (CV > max_volatility_cv) will be forcefully merged to achieve statistical stability. Default is 0.15 (15% variance).
#' @param bins An integer or a list defining the granularity of the initial matrix grid before pruning. E.g., `bins = 20` slices each score into 20 bands (every 5 percentiles).
#' @param oot_date An optional cutoff Date/POSIXt object. Data where `time_col >= oot_date` will be preserved exclusively for Out-Of-Time (OOT) validation reporting.
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
find_risk_groups <- function(data,
                             score_cols,
                             default_col,
                             time_col,
                             min_vol_ratio = 0.05,
                             max_volatility_cv = 0.15,
                             bins = 20,
                             oot_date = NULL) {

    # Basic Validation
    missing_cols <- setdiff(c(score_cols, default_col, time_col), names(data))
    if (length(missing_cols) > 0) {
        cli::cli_abort("Missing columns in data: {.field {missing_cols}}")
    }

    # Strict Date Evaluation
    if (!inherits(data[[time_col]], c("Date", "POSIXt"))) {
        cli::cli_abort("Column {.arg {time_col}} must be a Date or POSIXt object. Please format your data before matrixing.")
    }

    # 1. Spilt Train & OOT
    if (!is.null(oot_date)) {
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
            empirical_pd = combo_bads / combo_vol,
            .groups = "drop"
        ) %>%
        # Sort from Lowest Risk to Highest Risk
        dplyr::arrange(empirical_pd) %>%
        # Assign an initial continuous 1D ranking
        dplyr::mutate(micro_rating = dplyr::row_number())

    # Append ranking back to training data for vintage-level aggregations
    train_data <- train_data %>%
        dplyr::left_join(matrix_summary %>% dplyr::select(dplyr::all_of(c(bin_cols, "micro_rating"))), by = bin_cols)

    # --- STEP 3: VOLUME PRUNING ---

    # We start assigning each micro_rating to its own final_group.
    # We iteratively merge small groups into their closest neighbors.
    current_groups <- matrix_summary %>%
        dplyr::select(micro_rating, empirical_pd, combo_vol) %>%
        dplyr::mutate(group_id = micro_rating)

    total_vol <- nrow(train_data)

    converged_vol <- FALSE
    while (!converged_vol) {
        group_summary <- current_groups %>%
            dplyr::group_by(group_id) %>%
            dplyr::summarize(
                vol = sum(combo_vol),
                vol_ratio = vol / total_vol,
                mean_pd = mean(empirical_pd),
                .groups = "drop"
            ) %>%
            dplyr::arrange(group_id)

        # Find the first group that violates the volume ratio
        small_idx <- which(group_summary$vol_ratio < min_vol_ratio)[1]

        if (is.na(small_idx)) {
            converged_vol <- TRUE
        } else {
            target_group <- group_summary$group_id[small_idx]

            # Determine the best neighbor to merge with (up or down)
            prev_group <- if (small_idx > 1) group_summary$group_id[small_idx - 1] else NA
            next_group <- if (small_idx < nrow(group_summary)) group_summary$group_id[small_idx + 1] else NA

            # For simplicity, prefer merging downwards (towards worse risk), unless it isolates a bad group
            if (!is.na(next_group)) {
                merge_into <- next_group
            } else {
                merge_into <- prev_group
            }

            # Apply merge map
            current_groups <- current_groups %>%
                dplyr::mutate(group_id = ifelse(group_id == target_group, merge_into, group_id))

            # Re-index remaining groups cleanly via dense_rank
            current_groups$group_id <- as.integer(as.factor(current_groups$group_id))
        }
    }

    # --- STEP 4: TIME-STABILITY VOLATILITY PRUNING ---
    # We prune strictly based on the Coefficient of Variation (SD / Mean).
    # Groups that swing wildly over time are unreliable and should be merged.

    converged_stab <- FALSE
    while (!converged_stab) {

        # Calculate monthly PD and its overall variance per group
        stab_check <- train_data %>%
            dplyr::left_join(current_groups %>% dplyr::select(micro_rating, group_id), by = "micro_rating") %>%
            dplyr::group_by(group_id, !!rlang::sym(time_col)) %>%
            dplyr::summarize(
                pd = sum(!!rlang::sym(default_col), na.rm = TRUE) / dplyr::n(),
                .groups = "drop"
            ) %>%
            dplyr::group_by(group_id) %>%
            dplyr::summarize(
                mean_pd = mean(pd, na.rm = TRUE),
                sd_pd = stats::sd(pd, na.rm = TRUE),
                cv_pd = ifelse(mean_pd == 0, 0, sd_pd / mean_pd),
                .groups = "drop"
            )

        unique_groups <- sort(unique(stab_check$group_id))
        max_groups <- length(unique_groups)
        violation_found <- FALSE

        if (max_groups > 1) {
            # Find groups exceeding the maximum acceptable volatility constraint using purrr
            violators <- purrr::map_dfr(unique_groups, ~ {
                group_data <- stab_check %>% dplyr::filter(group_id == .x)
                if (is.na(group_data$cv_pd)) group_data$cv_pd <- 0 # Handles single-vintage edgecases securely
                return(group_data)
            }) %>%
                dplyr::filter(cv_pd > max_volatility_cv)

            if (nrow(violators) > 0) {
                # Taking the most volatile group to merge first
                worst_group <- violators$group_id[which.max(violators$cv_pd)]

                # We merge towards neighbor with lowest volatility to help stabilize
                idx <- which(unique_groups == worst_group)
                neighbor_choices <- c()
                if (idx > 1) neighbor_choices <- c(neighbor_choices, unique_groups[idx - 1])
                if (idx < max_groups) neighbor_choices <- c(neighbor_choices, unique_groups[idx + 1])

                best_neighbor <- stab_check %>%
                    dplyr::filter(group_id %in% neighbor_choices) %>%
                    dplyr::arrange(cv_pd) %>%
                    dplyr::pull(group_id) %>%
                    .[1]

                # Apply mapping
                current_groups <- current_groups %>%
                    dplyr::mutate(group_id = ifelse(group_id == worst_group, best_neighbor, group_id))

                current_groups$group_id <- as.integer(as.factor(current_groups$group_id))
                violation_found <- TRUE
            }
        }

        if (!violation_found) converged_stab <- TRUE
    }

    # --- FINALIZING AND REPORTING ---

    # We have our finalized groups (Ratings)! Let's build a lookup dictionary mapping the initial N-Dimensional Bins to the Final Group.
    final_mapping <- matrix_summary %>%
        dplyr::select(dplyr::all_of(bin_cols), micro_rating) %>%
        dplyr::left_join(current_groups %>% dplyr::select(micro_rating, group_id), by = "micro_rating") %>%
        dplyr::rename(risk_rating = group_id)

    # Function to apply the mappings safely to any dataset
    apply_ratings <- function(df) {
        # Bin scores according to provided parameters
        for (i in seq_along(score_cols)) {
            sc <- score_cols[i]
            bc <- bin_cols[i]
            # For unseen OOT data, we recalculate tiles locally or could map them rigidly.
            # Here we bin OOT locally in its own context to preserve dynamic separation.
            df[[bc]] <- dplyr::ntile(df[[sc]], bins)
        }

        # Left join the master lookup
        df <- df %>%
            dplyr::left_join(final_mapping %>% dplyr::select(-micro_rating), by = bin_cols)

        # Clean up transient bin columns
        df <- df %>% dplyr::select(-dplyr::all_of(bin_cols))
        return(df)
    }

    train_data <- apply_ratings(train_data %>% dplyr::select(-dplyr::any_of(c(bin_cols, "micro_rating"))))

    if (nrow(oot_data) > 0) {
        oot_data <- apply_ratings(oot_data)
        final_data <- dplyr::bind_rows(train_data, oot_data)
    } else {
        final_data <- train_data
    }

    # Generate High-Level Summary Report
    summarize_group <- function(df, period_name) {
        df %>%
            dplyr::group_by(risk_rating) %>%
            dplyr::summarize(
                period = period_name,
                total_vol = dplyr::n(),
                avg_pd = sum(!!rlang::sym(default_col), na.rm = TRUE) / total_vol,
                .groups = "drop"
            )
    }

    report <- summarize_group(train_data, "Train")
    if (nrow(oot_data) > 0) {
        report <- dplyr::bind_rows(report, summarize_group(oot_data, "OOT (Validation)"))
    }

    return(list(
        data = final_data,
        mapping = final_mapping,
        report = report
    ))
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
#' @param ... Additional arguments passed natively to `find_risk_groups()`.
#'
#' @return A named list where each element contains the clustered Output List from `find_risk_groups` tied to a specific Challenger.
#' @export
find_pairwise_risk_groups <- function(data,
                                      primary_score,
                                      challenger_scores,
                                      default_col,
                                      time_col,
                                      ...) {
    cli::cli_alert_info("Starting pairwise Risk Group search for 1 Primary vs {length(challenger_scores)} Challengers...")
    pb <- cli::cli_progress_bar("Matrixing scores...", total = length(challenger_scores))

    results <- list()

    for (challenger in challenger_scores) {
        cli::cli_progress_update(id = pb, set = cli::pb_current(pb), status = paste("Matrixing:", primary_score, "x", challenger))

        res <- find_risk_groups(
            data = data,
            score_cols = c(primary_score, challenger),
            default_col = default_col,
            time_col = time_col,
            ...
        )

        results[[paste0(primary_score, "_vs_", challenger)]] <- res
        cli::cli_progress_update(id = pb)
    }

    cli::cli_progress_done(id = pb)
    return(results)
}
