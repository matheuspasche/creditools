
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

## Installation

``` r
# install.packages("devtools")
devtools::install_github("matheuspasche/creditools")
```

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
  current_score_col = old_score, # Uses tidyselect!
  new_score_col     = new_score,
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

<table class="table table-striped table-hover" style="color: black; width: auto !important; margin-left: auto; margin-right: auto;">

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
the legacy model versus the new ML model using the
`calculate_efficient_frontier()` wrapper.

``` r
# Generate a larger synthetic population (50,000) for high-resolution curves
sim_data <- generate_sample_data(n_applicants = 50000, seed = 123)

# Define base policy with 1.5x stress
base_policy <- credit_policy(
  applicant_id_col = id,
  score_cols = old_score,
  current_approval_col = approved,
  actual_default_col = defaulted
) %>% add_stress_scenario(stress_aggravation(factor = 1.5))

# Calculate frontiers using the high-level wrapper
old_frontier <- calculate_efficient_frontier(
  sim_data, base_policy, old_score,
  cutoff_steps = 30, target_default_rate = 0.12, method = "analytical"
)

new_frontier <- calculate_efficient_frontier(
  sim_data, base_policy, new_score,
  cutoff_steps = 30, target_default_rate = 0.12, method = "analytical"
)

comparison_df <- bind_rows(old_frontier, new_frontier)

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

<table class="table table-striped table-hover" style="color: black; width: auto !important; margin-left: auto; margin-right: auto;">

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

### The Temporal Stability Engine (“Heart of Credit”)

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
   score_cols = new_score,
   default_col = defaulted,
   time_col = vintage,   # The Engine of Stability
   max_groups = 5
 )
```

------------------------------------------------------------------------

``` r
# Create 20 micro-bins and merge them into 5 stable, monotonic Risk Ratings
risk_groups <- find_risk_groups(
  data = sim_data %>% filter(approved == 1),
  score_cols = new_score,
  default_col = defaulted,
  time_col = vintage,
  bins = 20,
  max_groups = 5,
  min_vol_ratio = 0.02
)

# Visualize stability and monotonicity across historical cohorts
plot(risk_groups)
```

<img src="man/figures/README-grouping-1.png" width="100%" />

------------------------------------------------------------------------

### 5. High-Scale Risk Tier Breakdown

In portfolios with thousands of candidate variables, identifying which
ones provide incremental discrimination within an existing rating is a
massive computational task.

`creditools` provides `screen_risk_segments()`, a high-performance
screening engine that uses a **C++ kernel** to evaluate IV (Information
Value) and PD Spread across candidate variables for each of your
existing risk tiers.

``` r
# 1. Establish existing ratings (Simplified for demo)
rating_model <- find_risk_groups(sim_data, "old_score", "defaulted", bins = 5, quiet = TRUE)

# 2. Screen for variables that can "break" these ratings
screening_res <- screen_risk_segments(
  data = rating_model$data,
  base_risk_col = risk_rating,
  candidate_cols = c(new_score, bureau_derogatory, age),
  default_col = defaulted
)

# Identify top variables to further segment the middle rating (e.g. 5)
screening_res$metrics %>%
  filter(risk_group == 5) %>%
  arrange(desc(iv)) %>%
  slice(1:5) %>%
  kbl(caption = "Tier Breakdown Analysis: Top Discriminators for Rating 5") %>%
  kable_styling(bootstrap_options = c("striped", "hover"), full_width = FALSE)
```

<table class="table table-striped table-hover" style="color: black; width: auto !important; margin-left: auto; margin-right: auto;">

<caption>

Tier Breakdown Analysis: Top Discriminators for Rating 5
</caption>

<thead>

<tr>

<th style="text-align:left;">

variable
</th>

<th style="text-align:right;">

risk_group
</th>

<th style="text-align:right;">

iv
</th>

<th style="text-align:right;">

pd_min
</th>

<th style="text-align:right;">

pd_max
</th>

<th style="text-align:right;">

pd_spread
</th>

<th style="text-align:right;">

tier_vol
</th>

</tr>

</thead>

<tbody>

<tr>

<td style="text-align:left;">

new_score
</td>

<td style="text-align:right;">

5
</td>

<td style="text-align:right;">

0.0350171
</td>

<td style="text-align:right;">

0.1183551
</td>

<td style="text-align:right;">

0.2004008
</td>

<td style="text-align:right;">

0.0820457
</td>

<td style="text-align:right;">

9973
</td>

</tr>

<tr>

<td style="text-align:left;">

bureau_derogatory
</td>

<td style="text-align:right;">

5
</td>

<td style="text-align:right;">

0.0115534
</td>

<td style="text-align:right;">

0.1384152
</td>

<td style="text-align:right;">

0.1873747
</td>

<td style="text-align:right;">

0.0489595
</td>

<td style="text-align:right;">

9973
</td>

</tr>

<tr>

<td style="text-align:left;">

age
</td>

<td style="text-align:right;">

5
</td>

<td style="text-align:right;">

0.0016241
</td>

<td style="text-align:right;">

0.1474423
</td>

<td style="text-align:right;">

0.1653307
</td>

<td style="text-align:right;">

0.0178883
</td>

<td style="text-align:right;">

9973
</td>

</tr>

</tbody>

</table>

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

# Distribution of the new segmented rating with risk metrics
# We show a clean summary of the Top 10 segments by volume
oot_final %>%
  group_by(Rating = risk_rating_segmented) %>%
  summarise(
    Volume = n(),
    `Volume %` = n() / nrow(oot_final),
    `Bad Rate` = mean(defaulted, na.rm = TRUE),
    `Avg Score` = mean(new_score, na.rm = TRUE)
  ) %>%
  mutate(
    `Volume %` = percent(`Volume %`, accuracy = 0.1),
    `Bad Rate` = percent(`Bad Rate`, accuracy = 0.01),
    `Avg Score` = round(`Avg Score`, 0)
  ) %>%
  arrange(desc(Volume)) %>%
  slice(1:10) %>% # Keep it professional and concise
  kbl(caption = "OOT Deployment: Top Segmented Ratings (Stability & Risk Stats)") %>%
  kable_styling(bootstrap_options = c("striped", "hover"), full_width = FALSE)
```

<table class="table table-striped table-hover" style="color: black; width: auto !important; margin-left: auto; margin-right: auto;">

<caption>

OOT Deployment: Top Segmented Ratings (Stability & Risk Stats)
</caption>

<thead>

<tr>

<th style="text-align:left;">

Rating
</th>

<th style="text-align:right;">

Volume
</th>

<th style="text-align:left;">

Volume %
</th>

<th style="text-align:left;">

Bad Rate
</th>

<th style="text-align:right;">

Avg Score
</th>

</tr>

</thead>

<tbody>

<tr>

<td style="text-align:left;">

1.10
</td>

<td style="text-align:right;">

343
</td>

<td style="text-align:left;">

6.9%
</td>

<td style="text-align:left;">

5.54%
</td>

<td style="text-align:right;">

955
</td>

</tr>

<tr>

<td style="text-align:left;">

5.1
</td>

<td style="text-align:right;">

340
</td>

<td style="text-align:left;">

6.8%
</td>

<td style="text-align:left;">

17.06%
</td>

<td style="text-align:right;">

46
</td>

</tr>

<tr>

<td style="text-align:left;">

1.9
</td>

<td style="text-align:right;">

225
</td>

<td style="text-align:left;">

4.5%
</td>

<td style="text-align:left;">

8.44%
</td>

<td style="text-align:right;">

851
</td>

</tr>

<tr>

<td style="text-align:left;">

5.2
</td>

<td style="text-align:right;">

212
</td>

<td style="text-align:left;">

4.2%
</td>

<td style="text-align:left;">

12.74%
</td>

<td style="text-align:right;">

145
</td>

</tr>

<tr>

<td style="text-align:left;">

1.8
</td>

<td style="text-align:right;">

173
</td>

<td style="text-align:left;">

3.5%
</td>

<td style="text-align:left;">

8.09%
</td>

<td style="text-align:right;">

752
</td>

</tr>

<tr>

<td style="text-align:left;">

5.3
</td>

<td style="text-align:right;">

170
</td>

<td style="text-align:left;">

3.4%
</td>

<td style="text-align:left;">

17.06%
</td>

<td style="text-align:right;">

247
</td>

</tr>

<tr>

<td style="text-align:left;">

4.4
</td>

<td style="text-align:right;">

157
</td>

<td style="text-align:left;">

3.1%
</td>

<td style="text-align:left;">

17.20%
</td>

<td style="text-align:right;">

342
</td>

</tr>

<tr>

<td style="text-align:left;">

2.8
</td>

<td style="text-align:right;">

149
</td>

<td style="text-align:left;">

3.0%
</td>

<td style="text-align:left;">

4.70%
</td>

<td style="text-align:right;">

749
</td>

</tr>

<tr>

<td style="text-align:left;">

2.9
</td>

<td style="text-align:right;">

143
</td>

<td style="text-align:left;">

2.9%
</td>

<td style="text-align:left;">

7.69%
</td>

<td style="text-align:right;">

847
</td>

</tr>

<tr>

<td style="text-align:left;">

4.2
</td>

<td style="text-align:right;">

141
</td>

<td style="text-align:left;">

2.8%
</td>

<td style="text-align:left;">

16.31%
</td>

<td style="text-align:right;">

150
</td>

</tr>

</tbody>

</table>

------------------------------------------------------------------------

## Documentation

For detailed guides and case studies: -
`vignette("risk-segmentation-screening", package = "creditools")` -
**New!** - `vignette("multi-stage-funnel", package = "creditools")` -
`vignette("tradeoff-analysis", package = "creditools")`
