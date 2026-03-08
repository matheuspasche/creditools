# ============================================================
# dev/explore_ward_clusters.R
# Ward Agglomerative Clustering — Diagnóstico Visual
# Base: aprovados totais com PD realista (5-25% range)
# ============================================================

devtools::load_all()
library(dplyr)
library(ggplot2)

set.seed(42)

# 1. Gerar base sintética com curva de PD realista ----------------
# Score varia de 300 a 800. Mau pagador tem score baixo.
# Taxa default geral no portfólio: ~8-12% (crédito veículos usados)
cat("Gerando base com PD realista...\n")
n <- 50000
vintages <- seq(as.Date("2023-01-01"), as.Date("2024-03-01"), by = "month")

base <- tibble::tibble(
    id            = 1:n,
    vintage       = sample(vintages, n, replace = TRUE),
    current_score = round(rnorm(n, 550, 90)), # media 550, dp 90
    new_score     = round(current_score * 0.7 + rnorm(n, 150, 40)) # correlacionado
) %>% dplyr::mutate(
    current_score = pmax(300, pmin(800, current_score)),
    new_score     = pmax(300, pmin(800, new_score)),
    # PD logística com range de ~2% (score 800) a ~30% (score 300)
    risk_logit    = 4.0 + (-0.008) * current_score + (-0.004) * new_score + rnorm(n, 0, 0.5),
    true_pd       = 1 / (1 + exp(-risk_logit)),
    defaulted     = as.integer(runif(n) < true_pd),
    # Aprovação: current_score >= 500 (corte padrão)
    approved      = as.integer(current_score >= 500)
)

approved_all <- base %>% dplyr::filter(approved == 1)
cat(sprintf(
    "Base total: %d | Aprovados: %d | Default rate aprovados: %.1f%%\n",
    n, nrow(approved_all), 100 * mean(approved_all$defaulted)
))
cat(sprintf(
    "Range de PD (aprovados): %.1f%% - %.1f%%\n",
    100 * min(approved_all$true_pd), 100 * max(approved_all$true_pd)
))

# 2. Ward Agglomerative Clustering --------------------------------
cat("\nRodando Ward Clustering nos aprovados...\n")
result <- find_risk_groups(
    data             = approved_all,
    score_cols       = c("current_score", "new_score"),
    default_col      = "defaulted",
    time_col         = "vintage",
    min_vol_ratio    = 0.06,
    max_overlap_rate = 0.15,
    bins             = 15,
    max_groups       = 7
)

n_groups <- length(unique(result$data$risk_rating))
cat(sprintf("Grupos formados: %d\n", n_groups))

# 3. PD mensal por grupo ------------------------------------------
monthly_pd <- result$data %>%
    dplyr::filter(!is.na(risk_rating)) %>%
    dplyr::group_by(risk_rating, vintage) %>%
    dplyr::summarize(
        vol = dplyr::n(),
        bads = sum(defaulted),
        pd = bads / vol,
        .groups = "drop"
    )

summary_pd <- monthly_pd %>%
    dplyr::group_by(risk_rating) %>%
    dplyr::summarize(
        vol_share = sum(vol) / nrow(approved_all),
        pd_mean   = mean(pd),
        cv        = ifelse(mean(pd) == 0, NA, sd(pd) / mean(pd)),
        .groups   = "drop"
    )

cat("\nResumo por grupo (vol%, PD médio, CV):\n")
print(summary_pd)

# 4. Gráfico de Estabilidade --------------------------------------
group_labels <- summary_pd %>%
    dplyr::mutate(
        label = paste0(
            "G", risk_rating,
            " | ", formatC(pd_mean * 100, digits = 1, format = "f"), "% PD",
            " | ", formatC(vol_share * 100, digits = 0, format = "f"), "% vol"
        )
    )

monthly_pd <- monthly_pd %>%
    dplyr::left_join(group_labels %>% dplyr::select(risk_rating, label), by = "risk_rating")

cols <- if (n_groups <= 7) {
    RColorBrewer::brewer.pal(max(3, n_groups), "RdYlGn")[1:n_groups] # vermelho = risco alto
} else {
    scales::hue_pal()(n_groups)
}
# Inverter: G1 = melhor (verde), G7 = pior (vermelho)
cols <- rev(cols)

p <- ggplot(
    monthly_pd,
    aes(
        x = vintage,
        y = pd * 100,
        color = factor(risk_rating, levels = sort(unique(risk_rating))),
        group = factor(risk_rating)
    )
) +
    geom_line(linewidth = 1.2, alpha = 0.85) +
    geom_point(size = 2.5, alpha = 0.9) +
    scale_color_manual(
        values = cols,
        name   = "Grupo",
        labels = group_labels$label[order(group_labels$risk_rating)]
    ) +
    scale_x_date(date_labels = "%b/%y", date_breaks = "2 months") +
    scale_y_continuous(
        labels = scales::label_percent(scale = 1, accuracy = 0.1),
        expand = expansion(mult = c(0.02, 0.1))
    ) +
    labs(
        title = "Ward Agglomerative Clustering — Estabilidade de PD por Grupo de Risco",
        subtitle = sprintf(
            "n=%s aprovados | %d grupos Ward | nenhum cruzamento inter-faixas forçado",
            scales::comma(nrow(approved_all)), n_groups
        ),
        x = NULL,
        y = "Inadimplência Mensal (%)",
        caption = "Custo de merge: <U+0394> = (V_A·V_B)/(V_A+V_B) × (PD_A-PD_B)² | min_vol=6% | max_overlap=15%"
    ) +
    theme_minimal(base_size = 13) +
    theme(
        legend.position  = "right",
        legend.text      = element_text(size = 9, family = "mono"),
        panel.grid.minor = element_blank(),
        plot.title       = element_text(face = "bold", size = 14),
        plot.subtitle    = element_text(color = "gray50"),
        plot.caption     = element_text(color = "gray60", size = 8),
        axis.text.x      = element_text(angle = 30, hjust = 1)
    )

out_path <- "C:/Users/Matheus/.gemini/antigravity/brain/9e37136d-4a66-4734-aa31-9a4560214b41/ward_stability_approved_payers.png"
ggsave(out_path, p, width = 14, height = 7, dpi = 150)
cat(sprintf("\nGrafico salvo: %s\n", out_path))
