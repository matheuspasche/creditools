
<!-- README.md is generated from README.Rmd. Please edit that file -->

# creditools <img src="man/figures/logo.png" align="right" height="139" alt="" />

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
<!-- badges: end -->

**creditools** is a professional R framework designed for Credit Risk
Strategy and Decision Science. It provides the mathematical
infrastructure to simulate, optimize, and validate complex credit
policies, moving beyond static backtesting into the realm of
**Counterfactual Policy Simulation**.

In modern credit risk management, the most significant challenge is
“Selection Bias”: you only know the performance of applicants you have
already **approved**. When you evaluate a new policy, `creditools` fills
this gap by modeling “Swap-Ins” (the rejected who would be approved) and
“Swap-Outs” (the approved who would now be rejected).

## Technical Workflow: A Step-by-Step Guide

### 1. Counterfactual Portfolio Simulation (Vigente vs. Challenger)

The first step in any policy revision is understanding how the
transition impacts your portfolio metrics. We use the **Analytical
Reweighting** engine to calculate expected values deterministically.

In this scenario, we evaluate a new score with a **1.5x Aggravation
Factor** for the newly approved population (Swap-Ins). This accounts for
the higher uncertainty inherent in previously rejected applicants.

``` r
# Load built-in professional dataset (20,000 observations)
data(applicants)

# Run a deterministic analytical simulation with 1.5x stress
results <- simulate_from_data(
  data = applicants,
  current_score_col = "old_score",
  new_score_col     = "new_score",
  new_score_cutoff  = 640,
  aggravation_factor = 1.5,
  method = "analytical"
)

# Transition Summary:
# Note: Bad_Rate for 'swap_out' and 'keep_out' shows their HISTORICAL observed performance.
results$summary %>%
  mutate(Bad_Rate = percent(Bad_Rate, accuracy = 0.01)) %>%
  kbl(caption = "Portfolio Transition Analysis (1.5x Swap-In Stress)") %>%
  kable_styling(bootstrap_options = c("striped", "hover"), full_width = FALSE)
```

<table class="table table-striped table-hover" style="width: auto !important; margin-left: auto; margin-right: auto;">

<caption>

Portfolio Transition Analysis (1.5x Swap-In Stress)
</caption>

<thead>

<tr>

<th style="text-align:left;">

scenario
</th>

<th style="text-align:right;">

Applicants
</th>

<th style="text-align:right;">

Approved
</th>

<th style="text-align:right;">

Hired
</th>

<th style="text-align:left;">

Bad_Rate
</th>

</tr>

</thead>

<tbody>

<tr>

<td style="text-align:left;">

keep_in
</td>

<td style="text-align:right;">

5826
</td>

<td style="text-align:right;">

5826
</td>

<td style="text-align:right;">

3276.902
</td>

<td style="text-align:left;">

7.05%
</td>

</tr>

<tr>

<td style="text-align:left;">

keep_out
</td>

<td style="text-align:right;">

8670
</td>

<td style="text-align:right;">

0
</td>

<td style="text-align:right;">

0.000
</td>

<td style="text-align:left;">

13.03%
</td>

</tr>

<tr>

<td style="text-align:left;">

swap_in
</td>

<td style="text-align:right;">

1314
</td>

<td style="text-align:right;">

1314
</td>

<td style="text-align:right;">

772.130
</td>

<td style="text-align:left;">

11.78%
</td>

</tr>

<tr>

<td style="text-align:left;">

swap_out
</td>

<td style="text-align:right;">

4190
</td>

<td style="text-align:right;">

0
</td>

<td style="text-align:right;">

0.000
</td>

<td style="text-align:left;">

9.74%
</td>

</tr>

</tbody>

</table>

- **swap_in**: The “New Blood”. Applicants previously rejected but now
  approved. Their Bad_Rate is simulated with 1.5x stress.
- **swap_out**: The “Risk Reduction”. Historically approved applicants
  that the new model identifies as high risk. **The Bad_Rate here
  reflects their real historical default**, showing exactly which losses
  you are pruning.

------------------------------------------------------------------------

### 2. Multi-Model Optimization (The Efficient Frontier)

Choosing a model based on Gini or AUC is insufficient for business
planning. You need to know which model provides the most **Approval
Volume** for the same **Portfolio Bad Rate**.

`creditools` can analyze hundreds of score/cutoff combinations at once
to map their “Efficient Frontier.” Below, we compare the frontiers of
the legacy model versus the new ML model, restricted to a realistic
**0-70% Approval Rate** for professional aesthetics.

``` r
# Generate a larger synthetic population (50,000) for high-resolution curves
sim_data <- generate_sample_data(n_applicants = 50000, seed = 123)

get_frontier_data <- function(score_col) {
  opt <- find_optimal_cutoffs(
    data = sim_data,
    config = credit_policy(
      applicant_id_col = "id",
      score_cols = score_col,
      current_approval_col = "approved",
      actual_default_col = "defaulted"
    ) %>% add_stress_scenario(stress_aggravation(factor = 1.5)),
    cutoff_steps = 30,
    target_default_rate = 0.12,
    method = "analytical"
  )
  analysis <- analyze_tradeoffs(opt)
  df <- analysis$pareto_frontier
  df$model <- score_col
  return(df)
}

comparison_df <- map_dfr(c("old_score", "new_score"), get_frontier_data)

ggplot(comparison_df, aes(x = overall_approval_rate, y = overall_default_rate, color = model)) +
  geom_line(size = 1.5, alpha = 0.8) +
  geom_point(size = 2.5) +
  scale_y_continuous(labels = percent_format(), limits = c(0, 0.12)) +
  scale_x_continuous(labels = percent_format(), limits = c(0, 0.70)) +
  scale_color_manual(values = c("old_score" = "#ef8a62", "new_score" = "#67a9cf")) +
  labs(
    title = "Efficient Frontier Comparison: Stability under 1.5x Stress",
    subtitle = "Analysis of hundreds of score thresholds. Lower line = Superior Model.",
    x = "Portfolio Approval Rate",
    y = "Portfolio Default Rate (Bad Rate)",
    color = "Model Version"
  ) +
  theme_minimal(base_size = 13) +
  theme(legend.position = "bottom", panel.grid.minor = element_blank())
```

<img src="man/figures/README-comparison-plot-1.png" width="100%" />

------------------------------------------------------------------------

### 3. Iso-Approval Analysis: The Decision Table

The core business question often is: *“If we keep the same internal
approval volume, how much can we lower the Bad Rate?”*

``` r
# Baseline: Current Old Score Approval (~45%)
current_approval <- mean(sim_data$approved)
current_bad_rate <- mean(sim_data$defaulted[sim_data$approved == 1], na.rm = TRUE)

# New Policy: Finding the point on the New Score frontier with the same approval
iso_policy <- find_equivalent_policy(
  tradeoff_results = comparison_df %>% filter(model == "new_score"),
  target_metric = "approval_rate",
  target_value = current_approval,
  tolerance = 0.05
) %>% slice(1)

# Summary Comparison
iso_summary <- tibble(
  Metric = c("Approval Rate", "Portfolio Bad Rate"),
  `Current Strategy (Old)` = c(percent(current_approval), percent(current_bad_rate)),
  `Proposed Strategy (New)` = c(percent(iso_policy$overall_approval_rate), percent(iso_policy$overall_default_rate)),
  Delta = c("0.0%", percent(iso_policy$overall_default_rate - current_bad_rate, accuracy = 0.01))
)

iso_summary %>%
  kbl(caption = "Iso-Approval Impact Analysis (Business Decision Support)") %>%
  kable_styling(bootstrap_options = c("striped", "hover"), full_width = FALSE)
```

<table class="table table-striped table-hover" style="width: auto !important; margin-left: auto; margin-right: auto;">

<caption>

Iso-Approval Impact Analysis (Business Decision Support)
</caption>

<thead>

<tr>

<th style="text-align:left;">

Metric
</th>

<th style="text-align:left;">

Current Strategy (Old)
</th>

<th style="text-align:left;">

Proposed Strategy (New)
</th>

<th style="text-align:left;">

Delta
</th>

</tr>

</thead>

<tbody>

<tr>

<td style="text-align:left;">

Approval Rate
</td>

<td style="text-align:left;">

50%
</td>

<td style="text-align:left;">

52%
</td>

<td style="text-align:left;">

0.0%
</td>

</tr>

<tr>

<td style="text-align:left;">

Portfolio Bad Rate
</td>

<td style="text-align:left;">

8%
</td>

<td style="text-align:left;">

9%
</td>

<td style="text-align:left;">

0.50%
</td>

</tr>

</tbody>

</table>

------------------------------------------------------------------------

### 4. Ward Clustering: Monotonic Risk Segmentation

For Risk Based Pricing (RBP), you need stable risk bands (Risk Ratings).
Standard methods (quantiles) often produce non-monotonic results in
low-default segments.

`creditools` implements **Agglomerative Hierarchical Clustering using
Ward’s Method**, modified to strictly enforce monotonicity.

#### The Mathematical Foundation

The merging process minimizes the increase in the **Expected Sum of
Squares (ESS)** at each step:

``` math
 d_{ij} = \frac{n_i n_j}{n_i + n_j} || \bar{x}_i - \bar{x}_j ||^2 
```

Where $`n_i`$ is the volume in cluster $`i`$ and $`\bar{x}_i`$ is the
centroid (mean default rate). This minimizes the intra-cluster variance,
while `creditools` ensures that the final $`N`$ groups follow a strictly
increasing risk order, preventing “noisy” reversals in the Risk Matrix.

\### The Temporal Stability Engine (“Heart of Credit”)

In credit risk, a model that is accurate today but flips its risk
ordering tomorrow is dangerous. `creditools` (v0.5.0+) introduces the
**Temporal Stability Engine**:

1.  **Longitudinal Centroids**: Clustering engines (Ward/IV) work in a
    longitudinal space, treating each potential group as a vector of PDs
    across vintages.
2.  **Non-Crossing Constraint**: Strictly enforces that Group $`i`$ must
    have a lower PD than Group $`i+1`$ across historical cohorts.
3.  **Cross-Vintage Optimization**: Minimizes PD variance across time
    windows, ensuring that Rating 1 is always the safest, even in crisis
    periods.

``` r
# Enable temporal stability by passing the vintage column
risk_groups <- find_risk_groups(
  data = sim_data,
  score_cols = "new_score",
  default_col = "defaulted",
  time_col = "vintage",   # The Engine of Stability
  max_groups = 5
)
```

------------------------------------------------------------------------

``` r
# Create 20 micro-bins and merge them into 5 stable, monotonic Risk Ratings
risk_groups <- find_risk_groups(
  data = sim_data %>% filter(approved == 1),
  score_cols = "new_score",
  default_col = "defaulted",
  time_col = "vintage",
  bins = 20,
  max_groups = 5,
  min_vol_ratio = 0.02
)

# Visualize stability and monotonicity across historical cohorts
plot(risk_groups)
```

<img src="man/figures/README-grouping-1.png" width="100%" />

------------------------------------------------------------------------

### 5. High-Scale Risk Screening (“Furar a Folhinha”)

In portfolios with thousands of candidate variables, identifying which
ones provide incremental discrimination within an existing rating is a
massive computational task.

`creditools` provides `screen_risk_segments()`, a high-performance
screening engine that uses a **C++ kernel** to evaluate IV (Information
Value) and PD Spread across candidate variables for each of your
existing risk tiers.

``` r
# 1. Establish existing ratings
rating_model <- find_risk_groups(sim_data, "old_score", "defaulted", bins = 10, quiet = TRUE)

# 2. Screen for variables that can "break" these ratings
# This engine can handle 5000+ variables and millions of rows in seconds
screening_res <- screen_risk_segments(
  data = rating_model$data,
  base_risk_col = "risk_rating",
  candidate_cols = c(new_score, bureau_derogatory, age),
  default_col = "defaulted"
)

# Identify top variables to "punch through" for the middle rating (e.g. 5)
screening_res$metrics %>% 
  filter(risk_group == 5) %>% 
  arrange(desc(iv))
#> # A tibble: 3 x 7
#>   variable          risk_group      iv pd_min pd_max pd_spread tier_vol
#>   <chr>                  <int>   <dbl>  <dbl>  <dbl>     <dbl>    <dbl>
#> 1 new_score                  5 0.0340   0.074  0.124    0.0498     5006
#> 2 bureau_derogatory          5 0.0202   0.082  0.120    0.0378     5006
#> 3 age                        5 0.00524  0.092  0.116    0.0238     5006
```

### 6. The “Recipe” Predict Workflow

A unique feature of `creditools` is the ability to treat your
segmentation as a model. Both rating and screening objects store their
**“Recipes”** (absolute quantile boundaries and cluster mappings),
ensuring that Out-Of-Time (OOT) validation is mathematically consistent.

``` r
# Apply the training boundaries to a new Out-Of-Time dataset
oot_data <- generate_sample_data(n = 5000, seed = 99)
oot_with_rating <- predict(rating_model, oot_data)

# Materialize a specific sub-segmentation chosen during screening
oot_final <- predict(screening_res, oot_with_rating, variable = "new_score")

table(oot_final$risk_rating_segmented)
#> 
#> 1.10  1.3  1.4  1.5  1.6  1.7  1.8  1.9 10.1 10.2 10.3 10.4 10.5 10.6 10.7 10.8 
#>  241    5    8    8   18   38   75  107  216   95   70   51   26   13    6    4 
#> 10.9  2.1 2.10  2.2  2.3  2.4  2.5  2.6  2.7  2.8  2.9  3.1 3.10  3.2  3.3  3.4 
#>    1    2  102    3   13   16   37   49   84   98  118    7   67   15   21   39 
#>  3.5  3.6  3.7  3.8  3.9  4.1 4.10  4.2  4.3  4.4  4.5  4.6  4.7  4.8  4.9  5.1 
#>   47   65   74   84   80   11   53   16   35   58   60   73   64   65   63   11 
#> 5.10  5.2  5.3  5.4  5.5  5.6  5.7  5.8  5.9  6.1 6.10  6.2  6.3  6.4  6.5  6.6 
#>   20   33   52   55   59   59   76   58   49   33   13   52   66   65   74   63 
#>  6.7  6.8  6.9  7.1 7.10  7.2  7.3  7.4  7.5  7.6  7.7  7.8  7.9  8.1 8.10  8.2 
#>   64   56   32   36    7   65   62   89   74   64   44   33   25   73    4   76 
#>  8.3  8.4  8.5  8.6  8.7  8.8  8.9  9.1 9.10  9.2  9.3  9.4  9.5  9.6  9.7  9.8 
#>   72   68   45   47   40   23   17  124    1  117  100   85   54   33   13   12 
#>  9.9 
#>    6
```

------------------------------------------------------------------------

## Capabilities Summary

`creditools` is built for industry-scale deployment: - **Massive
Analysis**: Evaluate hundreds of scores and cutoff combinations
simultaneously. - **Hierarchical Matrixing**: Generate stable, monotonic
Risk Matrices (RBP) using Ward or IV-based Rcpp engines. - **High-Scale
Screening**: “Furar a Folhinha” with thousands of variables and
**model-like Predict API**. - **Governance**: A deterministic,
reproducible framework for Justification and Model Transition
documentation.

## Installation

``` r
# install.packages("devtools")
devtools::install_github("matheuspasche/creditools")
```

## Documentation

For detailed guides and case studies: -
`vignette("risk-segmentation-screening", package = "creditools")` -
**New!** - `vignette("multi-stage-funnel", package = "creditools")` -
`vignette("tradeoff-analysis", package = "creditools")`
