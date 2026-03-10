#' Internal helper for parallel processing setup
#'
#' @param ... Additional arguments passed to the function, potentially containing `parallel` and `n_workers`.
#' @param env Environment. The environment where on.exit should be registered (usually parent.frame()).
#' @return A list with parallel (logical) indicating if it should proceed in parallel.
#' @keywords internal
.setup_parallel <- function(..., env = parent.frame()) {
    opts <- list(...)
    # Extract from dots or fallback to FALSE
    parallel <- if (!is.null(opts$parallel)) isTRUE(opts$parallel) else FALSE
    n_workers <- opts$n_workers

    if (!parallel) {
        return(list(parallel = FALSE))
    }

    if (!requireNamespace("future", quietly = TRUE) || !requireNamespace("furrr", quietly = TRUE)) {
        if (requireNamespace("cli", quietly = TRUE)) {
            cli::cli_alert_warning("Parallel processing requires 'future' and 'furrr'. Using sequential processing.")
        }
        return(list(parallel = FALSE))
    }

    # Use rlang's null coalescing if available
    workers_count <- n_workers
    if (is.null(workers_count)) {
        workers_count <- max(1, future::availableCores() - 1)
    }

    if (inherits(future::plan(), "sequential")) {
        future::plan(future::multisession, workers = workers_count)
        # Register restoration in the caller's environment
        do.call("on.exit", list(quote(future::plan(future::sequential)), add = TRUE), envir = env)
    }

    return(list(parallel = TRUE))
}

#' Internal wrapper for parallel map operations
#'
#' @param .x A list or vector.
#' @param .f A function.
#' @param ... Additional arguments.
#' @param .parallel Logical.
#' @param .options furrr options (passed as a list or furrr_options object).
#' @param .progress Logical.
#' @keywords internal
.parallel_map <- function(.x, .f, ..., .parallel = FALSE, .options = NULL, .progress = FALSE) {
    args <- list(...)
    # Extract .seed if present, default to TRUE
    seed <- if (!is.null(args$.seed)) args$.seed else TRUE
    args$.seed <- NULL

    if (.parallel && requireNamespace("furrr", quietly = TRUE)) {
        # Construct/update .options to include the seed
        if (is.null(.options)) {
            .options <- furrr::furrr_options(globals = TRUE, packages = c("creditools", "dplyr"), seed = seed)
        } else if (inherits(.options, "furrr_options")) {
            # Update existing furrr_options with the seed
            .options$seed <- seed
        } else if (is.list(.options)) {
            # Convert list to furrr_options and add seed
            .options$seed <- seed
            .options <- do.call(furrr::furrr_options, .options)
        }

        # furrr 0.3.1 does not have .seed argument, it must be in .options
        do.call(furrr::future_map, c(list(.x = .x, .f = .f, .options = .options, .progress = .progress), args))
    } else {
        # Older purrr versions do not support .progress.
        do.call(purrr::map, c(list(.x = .x, .f = .f), args))
    }
}

#' Internal wrapper for parallel pmap operations
#' @keywords internal
.parallel_pmap <- function(.l, .f, ..., .parallel = FALSE, .options = NULL, .progress = FALSE) {
    args <- list(...)
    seed <- if (!is.null(args$.seed)) args$.seed else TRUE
    args$.seed <- NULL

    if (.parallel && requireNamespace("furrr", quietly = TRUE)) {
        if (is.null(.options)) {
            .options <- furrr::furrr_options(globals = TRUE, packages = c("creditools", "dplyr"), seed = seed)
        } else if (inherits(.options, "furrr_options")) {
            .options$seed <- seed
        } else if (is.list(.options)) {
            .options$seed <- seed
            .options <- do.call(furrr::furrr_options, .options)
        }
        do.call(furrr::future_pmap, c(list(.l = .l, .f = .f, .options = .options, .progress = .progress), args))
    } else {
        do.call(purrr::pmap, c(list(.l = .l, .f = .f), args))
    }
}

#' Internal wrapper for parallel map_dfr operations
#' @keywords internal
.parallel_map_dfr <- function(.x, .f, ..., .parallel = FALSE, .options = NULL, .progress = FALSE) {
    args <- list(...)
    seed <- if (!is.null(args$.seed)) args$.seed else TRUE
    args$.seed <- NULL

    if (.parallel && requireNamespace("furrr", quietly = TRUE)) {
        if (is.null(.options)) {
            .options <- furrr::furrr_options(globals = TRUE, packages = c("creditools", "dplyr"), seed = seed)
        } else if (inherits(.options, "furrr_options")) {
            .options$seed <- seed
        } else if (is.list(.options)) {
            .options$seed <- seed
            .options <- do.call(furrr::furrr_options, .options)
        }
        do.call(furrr::future_map_dfr, c(list(.x = .x, .f = .f, .options = .options, .progress = .progress), args))
    } else {
        do.call(purrr::map_dfr, c(list(.x = .x, .f = .f), args))
    }
}

#' Internal wrapper for parallel pmap_dfr operations
#' @keywords internal
.parallel_pmap_dfr <- function(.l, .f, ..., .parallel = FALSE, .options = NULL, .progress = FALSE) {
    args <- list(...)
    seed <- if (!is.null(args$.seed)) args$.seed else TRUE
    args$.seed <- NULL

    if (.parallel && requireNamespace("furrr", quietly = TRUE)) {
        if (is.null(.options)) {
            .options <- furrr::furrr_options(globals = TRUE, packages = c("creditools", "dplyr"), seed = seed)
        } else if (inherits(.options, "furrr_options")) {
            .options$seed <- seed
        } else if (is.list(.options)) {
            .options$seed <- seed
            .options <- do.call(furrr::furrr_options, .options)
        }
        do.call(furrr::future_pmap_dfr, c(list(.l = .l, .f = .f, .options = .options, .progress = .progress), args))
    } else {
        do.call(purrr::pmap_dfr, c(list(.l = .l, .f = .f), args))
    }
}
