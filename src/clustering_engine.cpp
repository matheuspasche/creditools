#include <Rcpp.h>
#include <limits>
#include <vector>
#include <algorithm>

using namespace Rcpp;

// [[Rcpp::export]]
IntegerVector rcpp_optimize_clusters(NumericVector bin_vols, 
                                     NumericVector bin_bads, 
                                     NumericMatrix monthly_vols, 
                                     NumericMatrix monthly_bads, 
                                     double min_vol_ratio, 
                                     int max_crossings, 
                                     int max_groups) {
    
    int n_bins = bin_vols.size();
    int n_months = monthly_vols.ncol();
    double total_vol = sum(bin_vols);
    
    // Track current group for each bin
    std::vector<int> bin_to_group(n_bins);
    for(int i = 0; i < n_bins; ++i) bin_to_group[i] = i;
    
    // Current group statistics
    std::vector<double> g_vols(n_bins);
    std::vector<double> g_bads(n_bins);
    std::vector<std::vector<double>> g_m_vols(n_bins, std::vector<double>(n_months));
    std::vector<std::vector<double>> g_m_bads(n_bins, std::vector<double>(n_months));
    
    for(int i = 0; i < n_bins; ++i) {
        g_vols[i] = bin_vols[i];
        g_bads[i] = bin_bads[i];
        for(int m = 0; m < n_months; ++m) {
            g_m_vols[i][m] = monthly_vols(i, m);
            g_m_bads[i][m] = monthly_bads(i, m);
        }
    }
    
    // Active groups (initially all)
    std::vector<int> active_groups;
    for(int i = 0; i < n_bins; ++i) active_groups.push_back(i);
    
    bool converged = false;
    while (!converged) {
        int n_active = active_groups.size();
        if (n_active <= 1) break;
        
        double min_cost = std::numeric_limits<double>::infinity();
        int best_idx = -1; // index in active_groups
        
        for (int i = 0; i < n_active - 1; ++i) {
            int g1 = active_groups[i];
            int g2 = active_groups[i+1];
            
            double v1 = g_vols[g1] / total_vol;
            double v2 = g_vols[g2] / total_vol;
            
            // Safe division for PD
            double pd1 = (g_vols[g1] > 0) ? (g_bads[g1] / g_vols[g1]) : 0.0;
            double pd2 = (g_vols[g2] > 0) ? (g_bads[g2] / g_vols[g2]) : 0.0;
            
            // Ward Distance
            double delta = (v1 + v2 > 0) ? ((v1 * v2) / (v1 + v2) * std::pow(pd1 - pd2, 2)) : 0.0;
            double cost = delta;
            
            // Priority 0: Zero Volume (Absolute Merge Priority)
            if (g_vols[g1] <= 0 || g_vols[g2] <= 0) {
                cost = -2e9 + delta;
            }
            // Priority 1: Monotonicity (Inversion / Flat)
            else if (pd1 >= pd2) {
                cost = -1e9 + delta;
            }
            // Priority 2: Volume constraint
            else if (v1 < min_vol_ratio || v2 < min_vol_ratio) {
                if (cost > -1e6) cost = -1e6 + delta;
            }
            // Priority 3: Stability (Non-Crossing)
            else if (n_months > 1) {
                int crossings = 0;
                for (int m = 0; m < n_months; ++m) {
                    if (g_m_vols[g1][m] > 0 && g_m_vols[g2][m] > 0) {
                        double mpd1 = g_m_bads[g1][m] / g_m_vols[g1][m];
                        double mpd2 = g_m_bads[g2][m] / g_m_vols[g2][m];
                        if (mpd1 >= mpd2) crossings++;
                    }
                }
                if (crossings > max_crossings) {
                    if (cost > -1e3) cost = -1e3 + delta;
                }
            }
            
            if (cost < min_cost) {
                min_cost = cost;
                best_idx = i;
            }
        }
        
        // Merge if constraints violated OR if we still have too many groups
        bool must_merge = (min_cost < 0) || (max_groups > 0 && n_active > max_groups);
        
        if (must_merge && best_idx != -1) {
            // Merge active_groups[best_idx] and active_groups[best_idx+1]
            int g1 = active_groups[best_idx];
            int g2 = active_groups[best_idx+1];
            
            // Update g1 stats with g2
            g_vols[g1] += g_vols[g2];
            g_bads[g1] += g_bads[g2];
            for (int m = 0; m < n_months; ++m) {
                g_m_vols[g1][m] += g_m_vols[g2][m];
                g_m_bads[g1][m] += g_m_bads[g2][m];
            }
            
            // Update bin_to_group mapping
            for (int b = 0; b < n_bins; ++b) {
                if (bin_to_group[b] == g2) bin_to_group[b] = g1;
            }
            
            // Remove g2 from active_groups
            active_groups.erase(active_groups.begin() + best_idx + 1);
        } else {
            // Constraints satisfied, check max_groups
            if (max_groups > 0 && n_active > max_groups) {
                // Same merge logic but for volume reduction
                int g1 = active_groups[best_idx];
                int g2 = active_groups[best_idx+1];
                g_vols[g1] += g_vols[g2];
                g_bads[g1] += g_bads[g2];
                for (int m = 0; m < n_months; ++m) {
                    g_m_vols[g1][m] += g_m_vols[g2][m];
                    g_m_bads[g1][m] += g_m_bads[g2][m];
                }
                for (int b = 0; b < n_bins; ++b) {
                    if (bin_to_group[b] == g2) bin_to_group[b] = g1;
                }
                active_groups.erase(active_groups.begin() + best_idx + 1);
            } else {
                converged = true;
            }
        }
    }
    
    // Normalize group IDs to 1..K in original order
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
