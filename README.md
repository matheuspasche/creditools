
<!-- README.md is generated from README.Rmd. Please edit that file -->

# creditools

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![R-CMD-check](https://github.com/matheuspasche/creditools/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/matheuspasche/creditools/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

The goal of `creditools` is to provide a flexible and powerful framework
for simulating and analyzing credit policies. It allows risk analysts to
model multi-stage decision funnels, simulate the impact of new
strategies (e.g., changing score cutoffs), and analyze the trade-off
between business metrics (like approval rate) and risk metrics (like
default rate) under various stress scenarios.

## Installation

You can install the development version of creditools from
[GitHub](https://github.com/) with:

``` r
# install.packages("devtools")
devtools::install_github("matheuspasche/creditools")
```

## Core Concepts

The package is built around three main ideas:

1.  **`credit_policy()`**: A central object that holds all the
    configuration for a simulation: column mappings, the sequence of
    decision stages, and stress scenarios for default simulation.
2.  **`stages`**: A policy is composed of sequential stages, such as
    `stage_cutoff()` (for score-based decisions) or `stage_rate()` (for
    probabilistic stages like fraud checks or conversion rates).
3.  **`run_simulation()` / `run_tradeoff_analysis()`**: The simulation
    engines. `run_simulation()` executes a single, defined policy, while
    `run_tradeoff_analysis()` is a powerful wrapper that runs dozens or
    hundreds of simulations to explore the impact of varying parameters.

## A Complete Example

Here is a walk-through of a complex, realistic simulation using a
massive analytical base (\> 1.5 Million applicants), multiple decision
stages (Credit, Fraud, Conversion), parallel processing, and custom
stress scenarios.

### 1. Load Package, Parallel Plan and Generate Data

First, we’ll generate 1,500,000 applicants mimicking a historical base
where applicants have an “old_score” and a new challenger “new_score”.
We want to evaluate if the `new_score` mitigates default risk while
retaining healthy approval and conversion metrics.

``` r
library(creditools)
library(dplyr)
library(ggplot2)
library(future)

# Enable parallel processing to handle the > 1.5 Million applicant volume swiftly
future::plan(multisession)

# Generate a massive analytical base (1.5 Million applicants)
sample_data <- generate_sample_data(n_applicants = 1500000, seed = 42)

# Create stratification bands for the new score
sample_data$new_score_decile <- dplyr::ntile(sample_data$new_score, 10)
```

### 2. Define Funnel Stages and Credit Policy

A risk credit policy is rarely a single cutoff. We build a multi-stage
funnel where applicants need to sequentially pass through a credit
filter, an anti-fraud engine, and finally, a conversion rate probability
(e.g. credit seekers are more likely to accept higher rates).

``` r
# Stage 1: Credit decision (Approval driven by a Score Cutoff)
credit_stage <- stage_cutoff(
  name = "credit_decision",
  cutoffs = list(new_score = 600) # This will be dynamically varied later
)

# Stage 2: Anti-fraud model (Flat 95% generic pass rate)
antifraud_stage <- stage_rate(
  name = "anti_fraud",
  base_rate = 0.95
)

# Stage 3: Conversion rate (Monotonically decreasing with score)
# Worst scores have a robust conversion rate (need credit), best scores have lower rate.
conversion_stage <- stage_rate(
  name = "conversion",
  base_rate = 0.70, # Baseline, overriding dynamically 
  stress_by_score = list(
    score_col = "new_score",
    rate_at_min = 0.90, 
    rate_at_max = 0.60
  )
)

# Create the full policy object
base_policy <- credit_policy(
  applicant_id_col = "id",
  score_cols = c("old_score", "new_score"),
  current_approval_col = "approved",
  actual_default_col = "defaulted",
  risk_level_col = "new_score_decile", # Required if we apply stratification in stress test
  simulation_stages = list(
    credit_stage,
    antifraud_stage,
    conversion_stage
  )
)
```

### 3. Run a Massively Parallel Trade-off Analysis

We will define parameters to vary dynamically. We want to test different
score cutoffs to see the “swap-in” effects, while also varying the base
conversion rate and aggravating the default expectation for newly
approved customers (a normal phenomena when exploring unsupervised score
bands).

``` r
# Define the simulation grid
vary_params <- list(
  new_score_cutoff = seq(450, 750, by = 50),
  aggravation_factor = c(1.2, 1.5, 1.7) # 20%, 50% and 70% PD Uplift
)

# Run the parallel analysis!
# `run_tradeoff_analysis` intercepts names like `*_base_rate` to dynamically override Funnel Stages
tradeoff_results <- run_tradeoff_analysis(
  data = sample_data,
  base_policy = base_policy,
  vary_params = vary_params,
  parallel = TRUE, # Using future multisession
  quiet = TRUE
)

head(tradeoff_results)
#> # A tibble: 6 x 4
#>   new_score_cutoff aggravation_factor approval_rate default_rate
#>              <dbl>              <dbl>         <dbl>        <dbl>
#> 1              450                1.2         0.286       0.0773
#> 2              450                1.5         0.286       0.0821
#> 3              450                1.7         0.286       0.0859
#> 4              500                1.2         0.286       0.0775
#> 5              500                1.5         0.286       0.0824
#> 6              500                1.7         0.286       0.0857
```

### 4. Visualize the Results

The results provide a data frame mapping out an efficient frontier. This
clearly highlights how migrating to `new_score` mitigates default risk
depending on the selected cutoff, and showcases the conservative
aggravation impacts on business volume.

``` r
tradeoff_results %>%
  mutate(Stress = paste0("+", round((aggravation_factor - 1) * 100), "% PD Aggravation")) %>%
  ggplot(aes(x = approval_rate, y = default_rate, color = Stress)) +
  geom_line(size = 1.2) +
  geom_point(aes(size = new_score_cutoff), alpha = 0.8) +
  labs(
    title = "Efficient Frontier: Migrating to 'New Score'",
    subtitle = "Trade-off analysis for > 1.5M applicants adjusting for Conversion funnels and PD Aggravations",
    x = "Overall Approval Volume (End of Funnel Rate)", 
    y = "Average Default Rate (%)",
    size = "New Score Cutoff"
  ) +
  scale_x_continuous(labels = scales::percent_format(accuracy=1)) +
  scale_y_continuous(labels = scales::percent_format(accuracy=0.1)) +
  theme_minimal(base_size = 14) +
  theme(legend.position = "bottom")
```

<img src="man/figures/README-example-plot-1.png" width="100%" />
