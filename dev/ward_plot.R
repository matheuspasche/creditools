devtools::load_all(quiet = TRUE)
library(dplyr, warn.conflicts = FALSE)
library(ggplot2)

set.seed(42)
n <- 50000
vintages <- seq(as.Date("2023-01-01"), as.Date("2024-03-01"), by = "month")

base <- tibble::tibble(
    id = 1:n,
    vintage = sample(vintages, n, replace = TRUE),
    current_score = round(rnorm(n, 550, 90)),
    new_score = round(rnorm(n, 560, 75))
) |>
    dplyr::mutate(
        current_score = pmax(300, pmin(800, current_score)),
        new_score = pmax(300, pmin(800, new_score)),
        risk_logit = 4.0 + (-0.008) * current_score + (-0.004) * new_score + rnorm(n, 0, 0.5),
        true_pd = 1 / (1 + exp(-risk_logit)),
        defaulted = as.integer(runif(n) < true_pd),
        approved = as.integer(current_score >= 500)
    )

approved_all <- dplyr::filter(base, approved == 1)
message("Default rate aprovados: ", round(100 * mean(approved_all$defaulted), 1), "%")

result <- find_risk_groups(
    data             = approved_all,
    score_cols       = c("current_score", "new_score"),
    default_col      = "defaulted",
    time_col         = "vintage",
    min_vol_ratio    = 0.06,
    max_crossings    = 1L,
    bins             = 15,
    max_groups       = 7
)
n_groups <- length(unique(result$data$risk_rating))
message("Grupos formados: ", n_groups)

monthly_pd <- result$data |>
    dplyr::filter(!is.na(risk_rating)) |>
    dplyr::group_by(risk_rating, vintage) |>
    dplyr::summarize(vol = dplyr::n(), bads = sum(defaulted), pd = bads / vol, .groups = "drop")

summary_pd <- monthly_pd |>
    dplyr::group_by(risk_rating) |>
    dplyr::summarize(
        vol_pct = round(100 * sum(vol) / nrow(approved_all)),
        pd_mean = mean(pd),
        .groups = "drop"
    )

labels <- paste0(
    "G", summary_pd$risk_rating,
    " | PD=", formatC(summary_pd$pd_mean * 100, digits = 1, format = "f"), "%",
    " | vol=", summary_pd$vol_pct, "%"
)

monthly_pd <- dplyr::left_join(monthly_pd, summary_pd, by = "risk_rating")
cols <- rev(RColorBrewer::brewer.pal(max(3, n_groups), "RdYlGn")[seq_len(n_groups)])

p <- ggplot(
    monthly_pd,
    aes(
        x = vintage, y = pd * 100,
        color = factor(risk_rating, levels = sort(unique(risk_rating))),
        group = factor(risk_rating)
    )
) +
    geom_line(linewidth = 1.3, alpha = 0.85) +
    geom_point(size = 3) +
    scale_color_manual(values = cols, name = "Grupo de Risco", labels = labels) +
    scale_x_date(date_labels = "%b/%y", date_breaks = "2 months") +
    scale_y_continuous(
        labels = scales::label_percent(scale = 1, accuracy = 0.1),
        expand = expansion(mult = c(0.02, 0.1))
    ) +
    labs(
        title = "Ward Agglomerative Clustering - Estabilidade de PD por Grupo de Risco",
        subtitle = paste0(
            "Base: ", scales::comma(nrow(approved_all)), " aprovados | ",
            n_groups, " grupos | Sem cruzamentos inter-faixas"
        ),
        x = "Safra",
        y = "Inadimplencia Mensal (%)",
        caption = "Custo de merge: delta = (Va x Vb)/(Va+Vb) x (PDa - PDb)^2 | min_vol=6% | max_overlap=15%"
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

out <- "C:/Users/Matheus/.gemini/antigravity/brain/9e37136d-4a66-4734-aa31-9a4560214b41/ward_stability_v2.png"
ggsave(out, p, width = 14, height = 7, dpi = 150)
message("Salvo: ", out)
