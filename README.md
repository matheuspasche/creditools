
<!-- README.md is generated from README.Rmd. Please edit that file -->

# creditools

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
<!-- badges: end -->

The goal of `creditools` is to put the computational power of an entire
risk analytics team into a single, scalable R package. It provides a
flexible framework for mathematically simulating and optimizing credit
policies.

Instead of spending weeks writing ad-hoc code to backtest a single
credit score, `creditools` allows risk and business analysts to
instantly model multi-stage decision funnels (Credit, Anti-fraud,
Conversion), simulate the impact of new strategies, and discover the
**Optimal Efficient Frontier** between approval volume and default
rates.

## Why creditools? (The Business Value)

In modern credit risk management, finding the sweet spot of
profitability requires testing endless permutations. `creditools` was
designed to answer complex business questions in minutes:

- **Test N-Scores Simultaneously:** Why validate one challenger score
  when you can simulate 10 different scores at once? Find out exactly
  which model yields the best risk-adjusted return.
- **Find the Optimal Cutoff:** Extract the exact approval rates needed
  to keep delinquency constant, or find the maximum possible delinquency
  mitigation while holding your approval volume steady.
- **Surgical Stress Testing (Swap-ins):** When approving new profiles,
  delinquency doesn’t behave linearly. `creditools` lets you inject
  custom stress scenarios (e.g., *increase PD by 20% for deciles 9 and
  10, 50% for deciles 6-8, and 80% for the rest*).
- **Preserve Funnel Conversion:** Easily lock empirical conversion and
  activation rates by stage, ensuring your simulated business volumes
  reflect real-world borrower behavior.
- **Massive Scalability:** Under the hood, the engine supports `future`
  parallel processing. Simulate millions of applicants across hundreds
  of scenarios effortlessly.

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
4.  **`simulate_from_data()`**: The high-level “Data-to-Insights”
    wrapper. Perfect for analysts who already have a flat table with
    historical outcomes and just want to backtest a single cutoff with
    Ward-clustering and PD stress in one command.

## Quick Start: Data-to-Insights

If you already have a historical dataset with scores and outcomes
(Default, Approval, Hiring), you don’t need to define complex stages.
You can get a complete tradeoff and RBP matrix in one line:

``` r
devtools::load_all(".")

# 1. Generate sample data with the new complex demographics (bureau_derogatory, id_valid)
# and a 2x PD multiplier for better volume in tail stress tests
data <- generate_sample_data(
  n_applicants = 100000, 
  pd_multiplier = 2.0, 
  complex_demographics = TRUE,
  seed = 42
)

# 2. Run high-level simulation
# This automatically:
# - Simulates a 600-point cutoff
# - Finds optimal Ward Risk Groups
# - Projects 1.3x PD stress on Swap-Ins
results <- simulate_from_data(
  data = data,
  current_score_col = "old_score",
  new_score_col = "new_score",
  new_score_cutoff = 600,
  aggravation_factor = 1.30,
  time_col = "vintage"
)

# 3. View the Business Summary
print(results$summary)
#> # A tibble: 4 x 5
#>   scenario Applicants Approved Hired Bad_Rate
#>   <chr>         <int>    <int> <int>    <dbl>
#> 1 keep_in       31847    31847 18262    0.142
#> 2 keep_out      41947        0     0  NaN    
#> 3 swap_in        8020     8020  4839    0.201
#> 4 swap_out      18186        0     0  NaN

# 4. Visual Insights:
# - Scenario Composition (Bars)
# - Risk Group Stability (Lines over Vintages)
plot(results)             # Scenario bad rates
```

<img src="man/figures/README-quick-start-1.png" width="100%" />

``` r
plot(results$risk_groups) # Ward cluster stability
```

<img src="man/figures/README-quick-start-2.png" width="100%" />

------------------------------------------------------------------------

## A Complete Example (Funnel-Based)

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
devtools::load_all(".")
library(dplyr)
library(ggplot2)
library(future)

# Sequential processing for README generation stability
# future::plan(multisession) 

# Generate a massive analytical base (1.5 Million applicants)
sample_data <- generate_sample_data(n_applicants = 1500000, seed = 42)

# Create stratification bands for the new score
sample_data$new_score_decile <- dplyr::ntile(sample_data$new_score, 10)

# Inject simulated Vintages (Time Cohorts) and Categorical dimensions for Advanced Analytics showcase
sample_data$vintage_month <- sample(
  as.Date(c("2023-01-01", "2023-02-01", "2023-03-01", "2023-04-01", "2023-11-01", "2023-12-01")), 
  nrow(sample_data), replace = TRUE
)
sample_data$status <- sample(
  c("Approved", "Denied"), 
  nrow(sample_data), replace = TRUE, prob = c(0.85, 0.15)
)
```

### 2. Define Funnel Stages and Credit Policy

A risk credit policy is rarely a single cutoff. We build a multi-stage
funnel where applicants need to sequentially pass through a credit
filter, an anti-fraud engine, and finally, a conversion rate probability
(e.g. credit seekers are more likely to accept higher rates).

``` r
# Stage 1: Credit decision (Approval driven by a Score Cutoff)
credit_stage <- creditools::stage_cutoff(
  name = "credit_decision",
  cutoffs = list(new_score = 600) # This will be dynamically varied later
)

# Stage 2: Anti-fraud model (Flat 95% generic pass rate)
antifraud_stage <- creditools::stage_rate(
  name = "anti_fraud",
  base_rate = 0.95
)

# Stage 3: Conversion rate (Monotonically decreasing with score)
# Worst scores have a robust conversion rate (need credit), best scores have lower rate.
conversion_stage <- creditools::stage_rate(
  name = "conversion",
  base_rate = 0.70, # Baseline, overriding dynamically 
  stress_by_score = list(
    score_col = "new_score",
    rate_at_min = 0.90, 
    rate_at_max = 0.60
  )
)

# Create the full policy object
base_policy <- creditools::credit_policy(
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

### 3. Inspect a Single Simulation (Granular Audit)

Before running massive loops, you might want to audit exactly what
happens to each individual applicant. The `run_simulation()` engine
allows you to process a single policy and inspect the exact mathematical
flags applied to every single row (e.g., did they pass the cutoff? did
they convert? what is their simulated PD? did they default?).

``` r
# Run a single static pass of the policy over the 1.5M applicants
single_run <- creditools::run_simulation(
  data = sample_data, 
  policy = base_policy,
  quiet = TRUE
)

# Extract the granular data and inspect the first applicant who was a "Swap-In" (approved now, but rejected before)
granular_base <- single_run$data
granular_base %>% 
  dplyr::filter(scenario == "swap_in") %>% 
  dplyr::select(id, old_score, new_score, approved_credit_decision_new, approved_anti_fraud_new, new_approval, simulated_default) %>%
  head()
#> # A tibble: 6 x 7
#>      id old_score new_score approved_credit_decision_new approved_anti_fraud_new
#>   <int>     <dbl>     <dbl>                        <int>                   <int>
#> 1     4       346       913                            1                       1
#> 2    26       232       655                            1                       1
#> 3    31       343       762                            1                       1
#> 4    35       271       663                            1                       1
#> 5    66       422       964                            1                       1
#> 6    70       240       775                            1                       1
#> # i 2 more variables: new_approval <int>, simulated_default <int>
```

### 4. Run a Massively Parallel Trade-off Analysis

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

# Run the analysis!
tradeoff_results <- creditools::run_tradeoff_analysis(
  data = sample_data,
  base_policy = base_policy,
  vary_params = vary_params,
  parallel = FALSE, 
  quiet = TRUE
)

head(tradeoff_results)
#> # A tibble: 6 x 4
#>   new_score_cutoff aggravation_factor approval_rate default_rate
#>              <dbl>              <dbl>         <dbl>        <dbl>
#> 1              450                1.2         0.286       0.0766
#> 2              450                1.5         0.286       0.0818
#> 3              450                1.7         0.286       0.0853
#> 4              500                1.2         0.286       0.0769
#> 5              500                1.5         0.286       0.0825
#> 6              500                1.7         0.286       0.0853
```

### 5. Visualize the Results

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
#> Warning: Using `size` aesthetic for lines was deprecated in ggplot2 3.4.0.
#> i Please use `linewidth` instead.
#> This warning is displayed once per session.
#> Call `lifecycle::last_lifecycle_warnings()` to see where this warning was generated.
```

<img src="man/figures/README-example-plot-1.png" width="100%" />

## Advanced Analytics: Hard Filters & Risk Based Pricing (RBP)

Beyond point-in-time simulations, `creditools` operates as a robust
**Risk Matrix Engine**. Modern credit departments often need to answer:
*“Should I replace my primary score with this new provider, or matrix
them both into a combined stable Risk Tier?”*

The `find_risk_groups()` heuristic engine solves exactly this. It
automatically bins N-scores into intersecting dimensions, calculates
empirical risk, merges tiny pockets of poplation (`min_vol_ratio`), and
**prunes any groups with high PD volatility across vintages** to
guarantee perfectly stable horizontal curves over time
(`max_volatility_cv`). Furthermore, you can apply categorical rules
(`stage_filter`) prior to evaluation.

Let’s simulate a massive dataset with categorical constraints and search
for Risk Tiers evaluating the combined predictive power of our 2 scores.

### 1. Hard Filters & Finding Stable Risk Tiers

``` r
# Let's say we only want to evaluate the matrix on "Valid" segments that passed a basic 300 points Cutoff on our internal Score A.
advanced_policy <- credit_policy(
  applicant_id_col = "id",
  score_cols = c("old_score", "new_score"),
  current_approval_col = "approved",
  actual_default_col = "defaulted",
  risk_level_col = "new_score_decile",
  simulation_stages = list(
    # Stage 1: Categorical Filter (Dynamic execution)
    stage_filter(name = "status_filter", condition = "status == 'Approved'"),
    # Stage 2: Pre-Cutoff Screen
    stage_cutoff(name = "baseline", cutoffs = list(old_score = 300))
  )
)

# Pass the data through the hard filters first
filtered_candidates <- run_simulation(sample_data, advanced_policy, quiet = TRUE)$data %>% dplyr::filter(new_approval == TRUE)

# After isolating the approved funnel, we apply the clustering engine!
# We set `oot_date` to blindly validate our hierarchy outside of the train months.
rbp_matrix_results <- creditools::find_risk_groups(
    data = filtered_candidates, 
    score_cols = c("old_score", "new_score"), # Combining both!
    default_col = "defaulted", 
    time_col = "vintage_month",
    bins = 10,                 # Starts as a 10x10 matrix (100 pockets)
    min_vol_ratio = 0.05,      # Groups cannot be smaller than 5%
    max_crossings = 1L,        # Tolerates maximum 1 month of PD inversion
    oot_date = as.Date("2023-11-01") # Preserves Nov/Dec for Out-Of-Time validation!
)

# How many stable groups did it find?
print(rbp_matrix_results$report)
#> # A tibble: 20 x 4
#>    risk_rating period           total_vol avg_pd
#>          <int> <chr>                <int>  <dbl>
#>  1           1 Train                89227 0.0558
#>  2           2 Train                72605 0.0700
#>  3           3 Train                39924 0.0753
#>  4           4 Train                42629 0.0810
#>  5           5 Train                59413 0.0860
#>  6           6 Train                76047 0.0926
#>  7           7 Train                69947 0.101 
#>  8           8 Train                39170 0.108 
#>  9           9 Train                50222 0.115 
#> 10          10 Train                56567 0.125 
#> 11           1 OOT (Validation)     44499 0.0573
#> 12           2 OOT (Validation)     36381 0.0710
#> 13           3 OOT (Validation)     20023 0.0782
#> 14           4 OOT (Validation)     21156 0.0866
#> 15           5 OOT (Validation)     29651 0.0869
#> 16           6 OOT (Validation)     38208 0.0897
#> 17           7 OOT (Validation)     35014 0.102 
#> 18           8 OOT (Validation)     19510 0.106 
#> 19           9 OOT (Validation)     24944 0.114 
#> 20          10 OOT (Validation)     28300 0.126
```

The resulting `rbp_matrix_results$data` comes pre-attached with
`risk_rating` (from 1 to N), mapping perfectly to your custom Risk Based
Pricing matrix. The results clearly demonstrate if swapping or matrixing
scores offers more granular risk differentiation without vintage
intersections. This saves weeks of manual SAS/SQL matrix
cross-validations!
