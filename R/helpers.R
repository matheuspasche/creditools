#' Adicionar estratificação de risco
#' @keywords internal
add_risk_stratification <- function(data, config) {
  strat_config <- config$risk_stratification

  if (strat_config$method == "quantile") {
    # Criar estratificação baseada em quantis
    risk_scores <- data[[strat_config$score_column]]
    data[[strat_config$output_column]] <- cut(
      risk_scores,
      breaks = quantile(risk_scores, probs = seq(0, 1, length.out = strat_config$n_bins + 1), na.rm = TRUE),
      include.lowest = TRUE,
      labels = FALSE
    )
  } else if (strat_config$method == "custom") {
    # Usar definições de bins customizadas
    data[[strat_config$output_column]] <- cut(
      data[[strat_config$score_column]],
      breaks = strat_config$breaks,
      labels = strat_config$labels,
      include.lowest = TRUE
    )
  }

  return(data)
}

#' Calcular taxas históricas
#' @keywords internal
calculate_historical_rates <- function(data, config) {
  ref_data <- data %>%
    filter(.data[[config$date_col]] <= config$reference_data_period)

  # Calcular taxas para cada estágio de decisão
  stage_rates <- map(config$decision_stages, function(stage) {
    if (!is.null(stage$reference_column)) {
      rate <- mean(ref_data[[stage$reference_column]], na.rm = TRUE)
      list(stage = stage$name, rate = rate)
    }
  })

  # Calcular taxas para métricas de performance
  metric_rates <- if (!is.null(config$performance_metrics)) {
    map(config$performance_metrics, function(metric) {
      if (!is.null(metric$reference_column)) {
        rate <- mean(ref_data[[metric$reference_column]], na.rm = TRUE)
        list(metric = metric$name, rate = rate)
      }
    })
  }

  list(
    stage_rates = compact(stage_rates),
    metric_rates = compact(metric_rates)
  )
}

#' Calcular métricas de performance
#' @keywords internal
calculate_performance_metrics <- function(data, historical_rates, config) {
  for (metric_config in config$performance_metrics) {
    metric_name <- metric_config$name
    output_col <- paste0(metric_name, "_simulated")

    # Obter taxa base
    base_rate <- get_base_rate(metric_config, historical_rates)

    # Aplicar agravamento por risco se configurado
    if (isTRUE(metric_config$risk_aggravation) && !is.null(config$risk_stratification)) {
      data <- apply_risk_aggravation(data, metric_config, base_rate, output_col, config)
    } else {
      # Simular sem agravamento
      data[[output_col]] <- as.integer(runif(nrow(data)) < base_rate)
    }
  }

  return(data)
}

#' Obter taxa base para métrica
#' @keywords internal
get_base_rate <- function(metric_config, historical_rates) {
  if (!is.null(metric_config$reference_column)) {
    # Encontrar taxa histórica para esta métrica
    hist_rates <- keep(historical_rates$metric_rates, ~ .x$metric == metric_config$name)
    if (length(hist_rates) > 0) hist_rates[[1]]$rate else metric_config$base_rate
  } else {
    metric_config$base_rate
  }
}

#' Aplicar agravamento por risco
#' @keywords internal
apply_risk_aggravation <- function(data, metric_config, base_rate, output_col, config) {
  risk_col <- config$risk_stratification$output_column

  # Calcular taxa agravada para cada nível de risco
  risk_levels <- unique(data[[risk_col]])
  risk_factors <- get_risk_factors(risk_levels, metric_config)

  # Aplicar agravamento
  data[[output_col]] <- map_int(seq_len(nrow(data)), function(i) {
    risk_level <- data[[risk_col]][i]
    aggravated_rate <- base_rate * risk_factors[as.character(risk_level)]
    as.integer(runif(1) < aggravated_rate)
  })

  data
}

#' Obter fatores de risco
#' @keywords internal
get_risk_factors <- function(risk_levels, metric_config) {
  # Fatores de agravamento padrão (aumento de 10% por nível de risco)
  default_factors <- setNames(1 + 0.1 * (risk_levels - 1), risk_levels)

  # Usar fatores customizados se fornecidos
  if (!is.null(metric_config$risk_factors)) {
    custom_factors <- metric_config$risk_factors
    # Preencher fatores não especificados com valores padrão
    for (level in risk_levels) {
      if (!as.character(level) %in% names(custom_factors)) {
        custom_factors[as.character(level)] <- default_factors[as.character(level)]
      }
    }
    custom_factors
  } else {
    default_factors
  }
}
