#include <Rcpp.h>
#include <cmath>
#include <algorithm>
#include <vector>

using namespace Rcpp;

//' Fast calculation of metrics per tier for a candidate variable
//' 
//' @param x NumericVector candidate variable values
//' @param groups IntegerVector base risk groups (ratings)
//' @param defaults IntegerVector binary target (0/1)
//' @param n_bins int number of bins for discretization
//' @return List of metrics per tier
//' @export
//' @examples
//' \dontrun{
//' x <- runif(100)
//' g <- rep(1:2, each = 50)
//' d <- rbinom(100, 1, 0.1)
//' rcpp_calculate_tier_metrics(x, g, d, 2)
//' }
// [[Rcpp::export]]
List rcpp_calculate_tier_metrics(NumericVector x, IntegerVector groups, IntegerVector defaults, int n_bins) {
    int n = x.size();
    
    // 1. Identify unique groups and setup structures
    // Assuming groups are 1-based integers (typical for ratings)
    int max_group = 0;
    for(int i = 0; i < n; ++i) {
        if (groups[i] > max_group) max_group = groups[i];
    }
    
    // Results containers per group
    std::vector<double> group_iv(max_group + 1, 0.0);
    std::vector<double> group_pd_min(max_group + 1, 1.0);
    std::vector<double> group_pd_max(max_group + 1, 0.0);
    std::vector<int> group_vol(max_group + 1, 0);
    std::vector<int> group_bads(max_group + 1, 0);
    
    // Process each group independently
    for (int g = 1; g <= max_group; ++g) {
        // Collect indices for current group
        std::vector<double> group_x;
        std::vector<int> group_defaults;
        int total_bads = 0;
        int total_vols = 0;
        
        for (int i = 0; i < n; ++i) {
            if (groups[i] == g) {
                group_x.push_back(x[i]);
                group_defaults.push_back(defaults[i]);
                if (defaults[i] == 1) total_bads++;
                total_vols++;
            }
        }
        
        if (total_vols == 0) continue;
        
        group_vol[g] = total_vols;
        group_bads[g] = total_bads;
        
        // Discretize group_x using quantiles (simple rank-based bins)
        int g_n = group_x.size();
        std::vector<int> indices(g_n);
        for(int i=0; i<g_n; ++i) indices[i] = i;
        
        std::sort(indices.begin(), indices.end(), [&](int i, int j){
            return group_x[i] < group_x[j];
        });
        
        // Bin counts
        std::vector<int> bin_vols(n_bins, 0);
        std::vector<int> bin_bads(n_bins, 0);
        
        for (int i = 0; i < g_n; ++i) {
            int bin = (i * n_bins) / g_n;
            if (bin >= n_bins) bin = n_bins - 1;
            bin_vols[bin]++;
            if (group_defaults[indices[i]] == 1) bin_bads[bin]++;
        }
        
        // Calculate Metrics
        double iv = 0.0;
        double min_pd = 1.0;
        double max_pd = 0.0;
        int total_goods = total_vols - total_bads;
        
        for (int b = 0; b < n_bins; ++b) {
            if (bin_vols[b] == 0) continue;
            
            double pd = (double)bin_bads[b] / bin_vols[b];
            if (pd < min_pd) min_pd = pd;
            if (pd > max_pd) max_pd = pd;
            
            // Tier-wise IV
            int goods = bin_vols[b] - bin_bads[b];
            
            // Adjust proportions to avoid log(0)
            double p_b = (bin_bads[b] + 0.5) / (total_bads + 1.0);
            double p_g = (goods + 0.5) / (total_goods + 1.0);
            
            iv += (p_g - p_b) * std::log(p_g / p_b);
        }
        
        group_iv[g] = iv;
        group_pd_min[g] = min_pd;
        group_pd_max[g] = max_pd;
    }
    
    // Prepare R result
    IntegerVector r_groups;
    NumericVector r_iv, r_pd_min, r_pd_max, r_vol;
    
    for (int g = 1; g <= max_group; ++g) {
        if (group_vol[g] > 0) {
            r_groups.push_back(g);
            r_iv.push_back(group_iv[g]);
            r_pd_min.push_back(group_pd_min[g]);
            r_pd_max.push_back(group_pd_max[g]);
            r_vol.push_back(group_vol[g]);
        }
    }
    
    return List::create(
        Named("risk_group") = r_groups,
        Named("iv") = r_iv,
        Named("pd_min") = r_pd_min,
        Named("pd_max") = r_pd_max,
        Named("tier_vol") = r_vol
    );
}
