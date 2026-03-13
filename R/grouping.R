#' Find Stable Risk Groups (Ratings) from Multiple Scores
#'
#' @description
#' `find_risk_groups()` is a powerful analytical engine designed to create a unified,
#' stable risk rating from one or multiple challenger scores. It automatically mattresses
#' the scores, generates a 1D risk ranking based on expected defaults, and applies
#' statistical pruning algorithms (Volume Pruning and Non-Crossing Stability Pruning)
#' to merge statistically insignificant or overlapping bands across time (vintages).
#'
#' @details
#' ### Longitudinal Clustering (Temporal Stability)
#' The "Heart" of `creditools` is ensuring that risk groups remain stable and ordered over time.
#' When `time_col` is provided, the clustering engine (Ward or IV) does not just look at global PDs.
#' Instead, it treats each potential group as a longitudinal vector of PDs across vintages.
#'
#' 1. **Ward Method (Stability)**: Minimizes the Euclidean distance between the PD curves of
#'    adjacent groups. Two groups with similar global PDs but different behavior in crisis
#'    periods will be kept separate.
#' 2. **PD Crossings**: The `max_crossings` parameter acts as a hard constraint. If two groups
#'    invert their risk ordering (e.g., Group 1 has higher PD than Group 2) in more than
#'    `max_crossings` months, the engine will force a merge to ensure reliable decisioning.
#'
#' @param data A data frame containing the historical applicant data.
#' @param score_cols Columns containing the names of the score columns to matrix. (Uses \code{tidyselect} syntax).
#' @param default_col Column name indicating the observed default (0 or 1). (Uses \code{tidyselect} syntax).
#' @param time_col Optional column name representing the vintage/time cohort (e.g., "YYYY-MM"). (Uses \code{tidyselect} syntax). It will be internally coerced to Date.
#' @param min_vol_ratio The minimum acceptable population percentage for a risk group. Groups below this threshold are merged with their nearest risk neighbor. Default is 0.05 (5%).
#' @param max_crossings Maximum number of vintage periods where an adjacent lower-risk group can have a HIGHER observed PD than the next group (crossing). Uses absolute count, not proportion - so it is robust to small vintage windows (6-18 months). Default is `1`, meaning at most 1 month of inversion is tolerated before forcing a merge.
#' @param bins An integer defining the granularity of the initial matrix grid before pruning. E.g., `bins = 20` slices each score into 20 tiles (every 5 percentiles).
#' @param oot_date An optional cutoff Date/POSIXt object. Data where `time_col >= oot_date` will be preserved exclusively for Out-Of-Time (OOT) validation reporting.
#' @param max_groups An optional integer specifying the maximum number of risk groups to return. If NULL, pruning is driven solely by volume and stability thresholds.
#' @param quiet Whether to suppress progress and status messages. Default is FALSE.
#' @param optimization_method The clustering algorithm to use: `"ward"` (default, ultra-stable) or `"iv"` (experimental, maximizes Information Value).
#' @param lambda_cross Penalty weight for vintage PD crossings (only used if `optimization_method = "iv"`). Default is 0.5.
#' @param lambda_vol Penalty weight for PD volatility over time (only used if `optimization_method = "iv"`). Default is 0.2.
#' @param ... Additional options passed to internal functions (e.g., `parallel = TRUE`, `n_workers = 4`).
#'
#' @return An object of class \code{credit_risk_groups}, which is a list containing:
#' \itemize{
#'   \item \code{data}: The original data frame with a new column \code{risk_rating} attached.
#'   \item \code{mapping}: A lookup table defining the boundaries of the final merged risk groups.
#'   \item \code{recipes}: A list of quantile boundaries for each score used, enabling \code{predict()}.
#'   \item \code{report}: A summary tibble validating the monotonicity and volume of the final hierarchy in BOTH train and OOT periods.
#'   \item \code{metadata}: Internal parameters used during training.
#' }
#'
#' @importFrom dplyr mutate filter group_by summarize arrange ntile bind_rows left_join n pull select everything
#' @importFrom stats setNames
#' @importFrom purrr reduce map_df
#' @importFrom rlang .data enquo
#' @importFrom tidyselect eval_select
#' @importFrom tidyr drop_na pivot_wider complete
#' @export
#'
#' @examples
#' \donttest{
#' # Use the built-in applicants dataset
#' data(applicants)
#' # Using tidyselect syntax (unquoted names)
#' groups <- find_risk_groups(
#'     data = applicants,
#'     score_cols = old_score,
#'     default_col = defaulted,
#'     time_col = vintage,
#'     max_groups = 5
#' )
#'
#' # View the distribution of PD across groups
#' print(groups$report)
#'
#' # Visualize the group stability over time
#' plot(groups)
#' }
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
                             optimization_method = c("ward", "iv"),
                             lambda_cross = 0.5,
                             lambda_vol = 0.2,
                             ...) {
    optimization_method <- match.arg(optimization_method)

    # 1. Resolve Columns with Tidyselect
    score_expr <- rlang::enquo(score_cols)
    default_expr <- rlang::enquo(default_col)
    time_expr <- rlang::enquo(time_col)

    sel_scores <- names(tidyselect::eval_select(score_expr, data))
    sel_default <- names(tidyselect::eval_select(default_expr, data))
    
    # Optional time_col
    sel_time <- NULL
    if (!rlang::quo_is_null(time_expr)) {
        sel_time <- names(tidyselect::eval_select(time_expr, data))
        if (length(sel_time) == 0) {
            sel_time <- NULL
        } else if (length(sel_time) != 1) {
            cli::cli_abort("{.arg time_col} must resolve to exactly one column.")
        }
    }

    if (length(sel_scores) == 0) cli::cli_abort("{.arg score_cols} must resolve to at least one column.")
    if (length(sel_default) != 1) cli::cli_abort("{.arg default_col} must resolve to exactly one column.")

    # Basic Validation
    required_cols <- c(sel_scores, sel_default, sel_time)
    missing_cols <- setdiff(required_cols, names(data))
    if (length(missing_cols) > 0) {
        cli::cli_abort("Missing columns in data: {.field {missing_cols}}")
    }

    # Strict Date Evaluation (only if time_col provided)
    if (!is.null(sel_time)) {
        if (!inherits(data[[sel_time]], c("Date", "POSIXt"))) {
            cli::cli_abort("Column {.arg {sel_time}} must be a Date or POSIXt object. Please format your data before matrixing.")
        }
    }

    # Handle Parallelism Setup
    parallel_setup <- .setup_parallel(...)
    parallel <- parallel_setup$parallel

    # 1. Split Train & OOT
    if (!is.null(oot_date) && !is.null(sel_time)) {
        if (!inherits(oot_date, c("Date", "POSIXt"))) {
            cli::cli_abort("{.arg oot_date} must be a Date or POSIXt object.")
        }

        train_data <- data %>% dplyr::filter(!!rlang::sym(sel_time) < oot_date)
        oot_data <- data %>% dplyr::filter(!!rlang::sym(sel_time) >= oot_date)
        if (nrow(oot_data) == 0) cli::cli_warn("OOT Date provided but no data fell into the OOT horizon.")
    } else {
        train_data <- data
        oot_data <- data.frame()
    }

    # --- STEP 1 & 2: INITIAL N-DIMENSIONAL BINNING & 1D EMPIRICAL RANKING ---

    # Bin each score independently into tiles
    # We store the boundaries (recipe) for each score to enable prediction
    bin_cols <- paste0(sel_scores, "_bin")
    score_recipes <- list()

    for (i in seq_along(sel_scores)) {
        sc <- sel_scores[i]
        bc <- bin_cols[i]

        # Calculate quantile-based boundaries on the training data
        # We use type = 7 (default) for continuity
        q_probs <- seq(0, 1, length.out = bins + 1)
        bounds <- stats::quantile(train_data[[sc]], q_probs, na.rm = TRUE)
        # Ensure unique boundaries to avoid findInterval issues with ties
        bounds <- unique(bounds)
        score_recipes[[sc]] <- bounds

        # Apply binning using findInterval for consistency with future predicts
        # findInterval returns index in [1, length(bounds)]
        train_data[[bc]] <- findInterval(train_data[[sc]], bounds, all.inside = TRUE)
    }

    # Aggregate combinations and determine their global empirical PD
    # We use complete() to ensure ALL possible combinations are present (handling matrix sparsity)
    matrix_summary <- train_data %>%
        dplyr::group_by(dplyr::across(dplyr::all_of(bin_cols))) %>%
        dplyr::summarize(
            combo_vol = dplyr::n(),
            combo_bads = sum(!!rlang::sym(sel_default), na.rm = TRUE),
            empirical_pd = .data$combo_bads / .data$combo_vol,
            .groups = "drop"
        )
    
    # Fill missing cells with zero volume and global expected PD (interpolation fallback)
    # This prevents NA risk_ratings during OOT prediction
    all_bins <- lapply(score_recipes, function(b) seq_len(length(b) - 1))
    names(all_bins) <- bin_cols
    
    matrix_summary <- matrix_summary %>%
        dplyr::ungroup() %>%
        tidyr::complete(!!!all_bins, fill = list(combo_vol = 0, combo_bads = 0)) %>%
        dplyr::mutate(
            empirical_pd = ifelse(.data$combo_vol == 0, mean(train_data[[sel_default]], na.rm = TRUE), .data$empirical_pd)
        ) %>%
        # Sort from Lowest Risk to Highest Risk
        # We use explicit column indices to break ties and ensure determinism (crucial for parallel consistency)
        dplyr::arrange(.data$empirical_pd, !!!rlang::syms(bin_cols)) %>%
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
    if (!is.null(sel_time)) {
        monthly_stats <- train_data %>%
            dplyr::group_by(.data$micro_rating, !!rlang::sym(sel_time)) %>%
            dplyr::summarize(
                bads = sum(!!rlang::sym(sel_default), na.rm = TRUE),
                vols = dplyr::n(),
                .groups = "drop"
            )
    } else {
        monthly_stats <- NULL
    }

    # --- AGGLOMERATIVE CLUSTERING OPTIMIZATION LOOP ---
    # --- AGGLOMERATIVE CLUSTERING OPTIMIZATION (Rcpp) ---
    if (!quiet) cli::cli_alert_info("Optimizing risk clusters via Rcpp engine...")

    # Prepare matrices for stability checks if time_col provided
    n_bins <- nrow(matrix_summary)
    if (!is.null(sel_time)) {
        # Ensure we have all periods for all micro-ratings
        periods <- sort(unique(train_data[[sel_time]]))
        n_months <- length(periods)

        m_vols <- matrix(0, nrow = n_bins, ncol = n_months)
        m_bads <- matrix(0, nrow = n_bins, ncol = n_months)

        period_map <- setNames(seq_along(periods), as.character(periods))

        # Fill matrices using the pre-calculated monthly_stats
        for (i in seq_len(nrow(monthly_stats))) {
            r <- monthly_stats$micro_rating[i]
            p <- as.character(monthly_stats[[sel_time]][i])
            c <- period_map[p]
            if (!is.na(c)) {
                m_vols[r, c] <- monthly_stats$vols[i]
                m_bads[r, c] <- monthly_stats$bads[i]
            }
        }
    } else {
        # Dummy matrices for C++ if no longitudinal data
        m_vols <- matrix(0, nrow = n_bins, ncol = 1)
        m_bads <- matrix(0, nrow = n_bins, ncol = 1)
    }

    # Execute C++ Optimization Engine
    if (optimization_method == "ward") {
        final_group_mapping <- rcpp_optimize_clusters(
            bin_vols = matrix_summary$combo_vol,
            bin_bads = matrix_summary$combo_bads,
            monthly_vols = m_vols,
            monthly_bads = m_bads,
            min_vol_ratio = min_vol_ratio,
            max_crossings = max_crossings,
            max_groups = if (is.null(max_groups)) 0 else max_groups
        )
    } else {
        final_group_mapping <- rcpp_iv_optimize_clusters(
            bin_vols = matrix_summary$combo_vol,
            bin_bads = matrix_summary$combo_bads,
            monthly_vols = m_vols,
            monthly_bads = m_bads,
            min_vol_ratio = min_vol_ratio,
            lambda_cross = lambda_cross,
            lambda_vol = lambda_vol,
            max_bins = if (is.null(max_groups)) 0 else max_groups
        )
    }

    # Assign optimized group IDs back to the mapping
    current_groups <- matrix_summary %>%
        dplyr::mutate(group_id = final_group_mapping)

    # --- FINALIZING AND REPORTING ---

    # We have our finalized groups (Ratings)! Let's build a lookup dictionary mapping the initial N-Dimensional Bins to the Final Group.
    final_mapping <- matrix_summary %>%
        dplyr::select(dplyr::all_of(bin_cols), dplyr::all_of("micro_rating")) %>%
        dplyr::left_join(current_groups %>% dplyr::select(dplyr::all_of(c("micro_rating", "group_id"))), by = "micro_rating") %>%
        dplyr::rename(risk_rating = "group_id")

    # Function to apply the mappings safely to any dataset
    apply_ratings <- function(df) {
        # Bin scores according to the boundaries established during training (the "recipe")
        for (i in seq_along(sel_scores)) {
            sc <- sel_scores[i]
            bc <- bin_cols[i]
            bounds <- score_recipes[[sc]]
            df[[bc]] <- findInterval(df[[sc]], bounds, all.inside = TRUE)
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
                avg_pd = sum(!!rlang::sym(sel_default), na.rm = TRUE) / .data$total_vol,
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
        recipes = score_recipes,
        metadata = list(
            score_cols = sel_scores,
            default_col = sel_default,
            time_col = sel_time,
            min_vol_ratio = min_vol_ratio,
            max_crossings = max_crossings,
            bins = bins,
            oot_date = oot_date,
            max_groups = max_groups,
            optimization_method = optimization_method
        )
    )

    class(res) <- c("credit_risk_groups", class(res))
    return(res)
}

#' Predict Risk Groups on New Data
#'
#' @description
#' `predict.credit_risk_groups()` applies a previously trained risk group model
#' to a new dataset. It uses the exact quantile boundaries from the training
#' data to ensure consistent binning before applying the final matrix mapping.
#'
#' @param object An object of class `credit_risk_groups`.
#' @param newdata A data frame containing the same score columns as the training data.
#' @param ... Not used.
#'
#' @return The `newdata` data frame with an additional `risk_rating` column.
#' @export
#' @importFrom stats predict
predict.credit_risk_groups <- function(object, newdata, ...) {
    score_cols <- object$metadata$score_cols
    score_recipes <- object$recipes
    bin_cols <- paste0(score_cols, "_bin")
    final_mapping <- object$mapping

    # 1. Apply Binning Recipes
    for (sc in score_cols) {
        bounds <- score_recipes[[sc]]
        bc <- paste0(sc, "_bin")
        newdata[[bc]] <- findInterval(newdata[[sc]], bounds, all.inside = TRUE)
    }

    # 2. Join with Final Mapping
    # We join by the bin columns to retrieve the final rating
    res <- newdata %>%
        dplyr::left_join(final_mapping %>% dplyr::select(-dplyr::any_of("micro_rating")), by = bin_cols)

    # 3. Clean up and Return
    res <- res %>% dplyr::select(-dplyr::all_of(bin_cols))
    return(res)
}

#' @export
print.credit_risk_groups <- function(x, ...) {
    cli::cli_h1("Risk Rating Model Object")
    cli::cli_alert_info("Scores: {.val {x$metadata$score_cols}}")
    cli::cli_alert_info("Final Groups: {.val {length(unique(x$mapping$risk_rating))}}")
    cat("\n")
    print(x$report)
    invisible(x)
}

#' @export
summary.credit_risk_groups <- function(object, ...) {
    object$report
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
#' @param primary_score Primary/legacy score column. (Uses \code{tidyselect} syntax).
#' @param challenger_scores Challenger score columns. (Uses \code{tidyselect} syntax).
#' @param default_col Column name indicating the observed default (0 or 1). (Uses \code{tidyselect} syntax).
#' @param time_col Column name representing the vintage/time cohort. (Uses \code{tidyselect} syntax).
#' @param quiet Whether to suppress progress and status messages. Default is FALSE.
#' @param optimization_method The clustering algorithm to use: `"ward"` or `"iv"`.
#' @param ... Additional arguments passed natively to `find_risk_groups()` (e.g., `parallel = TRUE`).
#'
#' @return A named list where each element contains the clustered Output List from `find_risk_groups` tied to a specific Challenger.
#' @export
#'
#' @examples
#' \donttest{
#' data(applicants)
#' results <- find_pairwise_risk_groups(
#'     data = applicants,
#'     primary_score = old_score,
#'     challenger_scores = starts_with("new_"),
#'     default_col = defaulted,
#'     time_col = vintage,
#'     max_groups = 3
#' )
#' }
find_pairwise_risk_groups <- function(data,
                                      primary_score,
                                      challenger_scores,
                                      default_col,
                                      time_col,
                                      quiet = FALSE,
                                      optimization_method = c("ward", "iv"),
                                      ...) {
    optimization_method <- match.arg(optimization_method)

    # 1. Resolve Columns with Tidyselect
    primary_expr <- rlang::enquo(primary_score)
    challengers_expr <- rlang::enquo(challenger_scores)
    default_expr <- rlang::enquo(default_col)
    time_expr <- rlang::enquo(time_col)

    sel_primary <- names(tidyselect::eval_select(primary_expr, data))
    sel_challengers <- names(tidyselect::eval_select(challengers_expr, data))
    sel_default <- names(tidyselect::eval_select(default_expr, data))
    sel_time <- names(tidyselect::eval_select(time_expr, data))

    if (length(sel_primary) != 1) cli::cli_abort("{.arg primary_score} must resolve to exactly one column.")
    if (length(sel_challengers) == 0) cli::cli_abort("{.arg challenger_scores} must resolve to at least one column.")
    if (length(sel_default) != 1) cli::cli_abort("{.arg default_col} must resolve to exactly one column.")
    if (length(sel_time) != 1) cli::cli_abort("{.arg time_col} must resolve to exactly one column.")

    if (!quiet && requireNamespace("cli", quietly = TRUE)) {
        cli::cli_alert_info("Starting pairwise Risk Group search for 1 Primary vs {length(sel_challengers)} Challengers...")
    }

    # Handle Parallelism Setup
    parallel_setup <- .setup_parallel(...)
    parallel <- parallel_setup$parallel

    # Capture dots for passing to find_risk_groups
    extra_args <- list(...)

    if (parallel && .Platform$OS.type == "unix") {
        # Use mclapply on Unix for speed and simplicity
        results_list <- parallel::mclapply(sel_challengers, function(challenger) {
            inner_args <- utils::modifyList(extra_args, list(parallel = FALSE))
            res <- do.call(find_risk_groups, c(list(
                data = data,
                score_cols = c(sel_primary, challenger),
                default_col = sel_default,
                time_col = sel_time,
                quiet = TRUE,
                optimization_method = optimization_method
            ), inner_args))
            return(list(challenger = challenger, result = res))
        }, mc.cores = parallel_setup$n_workers %||% (parallel::detectCores() - 1))
    } else if (parallel) {
        # Use parLapply on Windows (or as fallback)
        cl <- parallel::makeCluster(parallel_setup$n_workers %||% (parallel::detectCores() - 1))
        on.exit(parallel::stopCluster(cl), add = TRUE)
        
        # Export necessary data and functions
        parallel::clusterExport(cl, varlist = c("data", "sel_primary", "sel_default", "sel_time", "optimization_method", "extra_args", "find_risk_groups"), envir = environment())
        parallel::clusterEvalQ(cl, library(creditools))
        
        results_list <- parallel::parLapply(cl, sel_challengers, function(challenger) {
            inner_args <- utils::modifyList(extra_args, list(parallel = FALSE))
            res <- do.call(find_risk_groups, c(list(
                data = data,
                score_cols = c(sel_primary, challenger),
                default_col = sel_default,
                time_col = sel_time,
                quiet = TRUE,
                optimization_method = optimization_method
            ), inner_args))
            return(list(challenger = challenger, result = res))
        })
    } else {
        # Sequential
        results_list <- lapply(sel_challengers, function(challenger) {
            inner_args <- utils::modifyList(extra_args, list(parallel = FALSE))
            res <- do.call(find_risk_groups, c(list(
                data = data,
                score_cols = c(sel_primary, challenger),
                default_col = sel_default,
                time_col = sel_time,
                quiet = quiet,
                optimization_method = optimization_method
            ), inner_args))
            return(list(challenger = challenger, result = res))
        })
    }

    # Reconstruct named list
    results <- list()
    for (item in results_list) {
        results[[paste0(sel_primary, "_vs_", item$challenger)]] <- item$result
    }

    return(results)
}
