#include <Rcpp.h>
#include <limits>
#include <vector>
#include <algorithm>
#include <cmath>

using namespace Rcpp;

// Helper: Calculate Information Value (IV) for a bin
double calculate_bin_iv(double b_good, double b_bad, double total_good, double total_bad) {
    if (b_good <= 0 || b_bad <= 0) return 0.0;
    double dg = b_good / total_good;
    double db = b_bad / total_bad;
    return (dg - db) * std::log(dg / db);
}

// Helper: Calculate PD Volatility (Mean SD across time)
double calculate_pd_volatility(const std::vector<double>& m_vols, const std::vector<double>& m_bads) {
    int n = m_vols.size();
    if (n < 2) return 0.0;
    
    double sum_pd = 0;
    int n_valid = 0;
    std::vector<double> pds;
    
    for (int i = 0; i < n; ++i) {
        if (m_vols[i] > 0) {
            double pd = m_bads[i] / m_vols[i];
            pds.push_back(pd);
            sum_pd += pd;
            n_valid++;
        }
    }
    
    if (n_valid < 2) return 0.0;
    
    double mean_pd = sum_pd / n_valid;
    double var_sum = 0;
    for (double pd : pds) {
        var_sum += std::pow(pd - mean_pd, 2);
    }
    return std::sqrt(var_sum / (n_valid - 1));
}

// [[Rcpp::export]]
IntegerVector rcpp_iv_optimize_clusters(NumericVector bin_vols, 
                                        NumericVector bin_bads, 
                                        NumericMatrix monthly_vols, 
                                        NumericMatrix monthly_bads, 
                                        double min_vol_ratio, 
                                        double lambda_cross,
                                        double lambda_vol,
                                        int max_bins) {
    
    int n_bins = bin_vols.size();
    int n_months = monthly_vols.ncol();
    double total_vol = sum(bin_vols);
    double total_bads = sum(bin_bads);
    double total_goods = total_vol - total_bads;
    
    // Initialize group state
    std::vector<int> bin_to_group(n_bins);
    std::vector<double> g_vols(n_bins);
    std::vector<double> g_bads(n_bins);
    std::vector<std::vector<double>> g_m_vols(n_bins, std::vector<double>(n_months));
    std::vector<std::vector<double>> g_m_bads(n_bins, std::vector<double>(n_months));
    
    for(int i = 0; i < n_bins; ++i) {
        bin_to_group[i] = i;
        g_vols[i] = bin_vols[i];
        g_bads[i] = bin_bads[i];
        for(int m = 0; m < n_months; ++m) {
            g_m_vols[i][m] = monthly_vols(i, m);
            g_m_bads[i][m] = monthly_bads(i, m);
        }
    }
    
    std::vector<int> active_groups;
    for(int i = 0; i < n_bins; ++i) active_groups.push_back(i);
    
    while(active_groups.size() > (size_t)max_bins) {
        int n_active = active_groups.size();
        double best_cost = std::numeric_limits<double>::infinity();
        int best_i = -1;
        
        // Pre-calculate current IVs
        std::vector<double> current_ivs(n_active);
        for(int i = 0; i < n_active; ++i) {
            int g = active_groups[i];
            current_ivs[i] = calculate_bin_iv(g_vols[g] - g_bads[g], g_bads[g], total_goods, total_bads);
        }
        
        for (int i = 0; i < n_active - 1; ++i) {
            int g1 = active_groups[i];
            int g2 = active_groups[i+1];
            
            // 1. Safe PD for Monotonicity
            double vol_sum = g_vols[g1] + g_vols[g2];
            double pd_new = (vol_sum > 0) ? ((g_bads[g1] + g_bads[g2]) / vol_sum) : 0.0;
            
            // Monotonicity Check
            bool monotonic = true;
            if (i > 0) {
                int gp = active_groups[i-1];
                double pd_p = (g_vols[gp] > 0) ? (g_bads[gp] / g_vols[gp]) : 0.0;
                if (pd_p > pd_new) monotonic = false;
            }
            if (i < n_active - 2) {
                int gn = active_groups[i+2];
                double pd_n = (g_vols[gn] > 0) ? (g_bads[gn] / g_vols[gn]) : 0.0;
                if (pd_new > pd_n) monotonic = false;
            }
            
            // Force merge if volume is zero, regardless of monotonicity
            if (g_vols[g1] > 0 && g_vols[g2] > 0 && !monotonic) continue;
            
            // 2. Cost Calculation
            // IV Loss
            double new_iv = (vol_sum > 0) ? calculate_bin_iv(vol_sum - (g_bads[g1] + g_bads[g2]), 
                                                            g_bads[g1] + g_bads[g2], total_goods, total_bads) : 0.0;
            double loss_iv = (current_ivs[i] + current_ivs[i+1]) - new_iv;
            
            // Stability Penalty
            int crossings = 0;
            std::vector<double> m_vols_combined(n_months);
            std::vector<double> m_bads_combined(n_months);
            
            for (int m = 0; m < n_months; ++m) {
                m_vols_combined[m] = g_m_vols[g1][m] + g_m_vols[g2][m];
                m_bads_combined[m] = g_m_bads[g1][m] + g_m_bads[g2][m];
                
                // Check crossings with neighbors
                if (i > 0) {
                    int gp = active_groups[i-1];
                    if (g_m_vols[gp][m] > 0 && m_vols_combined[m] > 0) {
                        if ((g_m_bads[gp][m]/g_m_vols[gp][m]) > (m_bads_combined[m]/m_vols_combined[m])) crossings++;
                    }
                }
                if (i < n_active - 2) {
                    int gn = active_groups[i+2];
                    if (g_m_vols[gn][m] > 0 && m_vols_combined[m] > 0) {
                        if ((m_bads_combined[m]/m_vols_combined[m]) > (g_m_bads[gn][m]/g_m_vols[gn][m])) crossings++;
                    }
                }
            }
            
            double vol_sd = calculate_pd_volatility(m_vols_combined, m_bads_combined);
            double cost = loss_iv + (lambda_cross * crossings) + (lambda_vol * vol_sd);
            
            if (cost < best_cost) {
                best_cost = cost;
                best_i = i;
            }
        }
        
        if (best_i == -1) break; // No valid merge found
        
        // Execute Merge
        int g1 = active_groups[best_i];
        int g2 = active_groups[best_i+1];
        
        g_vols[g1] += g_vols[g2];
        g_bads[g1] += g_bads[g2];
        for (int m = 0; m < n_months; ++m) {
            g_m_vols[g1][m] += g_m_vols[g2][m];
            g_m_bads[g1][m] += g_m_bads[g2][m];
        }
        
        for (int b = 0; b < n_bins; ++b) {
            if (bin_to_group[b] == g2) bin_to_group[b] = g1;
        }
        
        active_groups.erase(active_groups.begin() + best_i + 1);
    }
    
    // Normalize and return
    IntegerVector final_ids(n_bins);
    std::vector<int> distinct_groups;
    for(int b = 0; b < n_bins; ++b) {
        int g = bin_to_group[b];
        if (std::find(distinct_groups.begin(), distinct_groups.end(), g) == distinct_groups.end()) {
            distinct_groups.push_back(g);
        }
    }
    for(int b = 0; b < n_bins; ++b) {
        int g = bin_to_group[b];
        auto it = std::find(distinct_groups.begin(), distinct_groups.end(), g);
        final_ids[b] = std::distance(distinct_groups.begin(), it) + 1;
    }
    
    return final_ids;
}
