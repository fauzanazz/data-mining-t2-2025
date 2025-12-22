#!/usr/bin/env Rscript
# Final Evaluation Test: Improved Model on Separate Eval Set
# Tests improved model on 5 completely separate campaigns

library(readr)
library(DirichletReg)

cat("\n")
cat("╔", strrep("═", 78), "╗\n", sep="")
cat("║", sprintf("%-78s", "  FINAL EVAL TEST: IMPROVED MODEL ON SEPARATE DATA"), "║\n")
cat("╚", strrep("═", 78), "╝\n\n", sep="")

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG <- list(
  model_file = "data-preparation/improved_dirichlet_model.rds",
  eval_data_file = "data-preparation/data_preparation_eval_result.csv",
  output_file = "data-preparation/final_eval_results.csv",
  bin_values = c(3000, 20000, 50000, 100000, 350000),
  platform_fee = 0.05
)

cat("CONFIGURATION:\n")
cat(strrep("=", 78), "\n")
cat("  Model:      ", CONFIG$model_file, "\n")
cat("  Eval data:  ", CONFIG$eval_data_file, "\n")
cat("  Bin values: ", paste(CONFIG$bin_values, collapse=", "), "\n\n")

# ============================================================================
# STEP 1: Load Model and Eval Data
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 1: Loading Model and Eval Data\n")
cat(strrep("=", 78), "\n\n")

# Load improved model
model <- readRDS(CONFIG$model_file)
cat("✓ Improved model loaded\n")
cat(sprintf("  Features: %s\n\n", paste(model$features, collapse=", ")))

# Load eval data
eval_data <- read_csv(CONFIG$eval_data_file, show_col_types = FALSE)

cat(sprintf("✓ Eval data loaded: %d campaigns\n\n", nrow(eval_data)))

# ============================================================================
# STEP 2: Engineer Features for Eval Data
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 2: Engineering Features for Eval Data\n")
cat(strrep("=", 78), "\n\n")

# Add required features
if ("donation_concentration" %in% model$features) {
  eval_data$donation_concentration <- eval_data$p1
  cat("✓ Added: donation_concentration (p1)\n")
}

if ("log_target_per_donor" %in% model$features) {
  eval_data$log_target_per_donor <- log1p(eval_data$target_dana / eval_data$N)
  cat("✓ Added: log_target_per_donor\n")
}

if ("log_duration" %in% model$features) {
  eval_data$log_duration <- log1p(eval_data$campaign_duration)
  cat("✓ Added: log_duration\n")
}

cat("\n")

# ============================================================================
# STEP 3: Evaluate on Eval Set
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 3: Evaluating on Separate Eval Set\n")
cat(strrep("=", 78), "\n\n")

results <- data.frame()

for (i in 1:nrow(eval_data)) {
  campaign_row <- eval_data[i, ]

  # Calculate actual EV
  actual_probs <- c(campaign_row$p1, campaign_row$p2, campaign_row$p3,
                   campaign_row$p4, campaign_row$p5)
  expected_per_donor_actual <- sum(actual_probs * CONFIG$bin_values)
  ev_actual <- campaign_row$N * expected_per_donor_actual * (1 - CONFIG$platform_fee)

  # Prepare features
  new_data_list <- list()

  # Map eval column names to model feature names
  if ("n" %in% model$features) {
    new_data_list[["n"]] <- campaign_row$N
  }

  if ("current_duration" %in% model$features) {
    new_data_list[["current_duration"]] <- campaign_row$campaign_duration
  }

  if ("target_donation" %in% model$features) {
    new_data_list[["target_donation"]] <- campaign_row$target_dana
  }

  if ("donation_concentration" %in% model$features) {
    new_data_list[["donation_concentration"]] <- campaign_row$donation_concentration
  }

  if ("log_target_per_donor" %in% model$features) {
    new_data_list[["log_target_per_donor"]] <- campaign_row$log_target_per_donor
  }

  if ("log_duration" %in% model$features) {
    new_data_list[["log_duration"]] <- campaign_row$log_duration
  }

  new_data <- as.data.frame(new_data_list)

  # Scale using training parameters
  for (feat in model$features) {
    new_data[[feat]] <- (new_data[[feat]] - model$scales[[feat]]$mean) /
                        model$scales[[feat]]$sd

    # Replace NaN/Inf with 0
    new_data[[feat]][!is.finite(new_data[[feat]])] <- 0

    # Clamp to training domain
    domain <- model$train_domain[[feat]]
    new_data[[feat]] <- pmin(pmax(new_data[[feat]], domain[1]), domain[2])
  }

  # Predict
  predicted_probs <- tryCatch({
    as.numeric(predict(model, newdata = new_data)[1, ])
  }, error = function(e) {
    cat(sprintf("  ⚠ Prediction error for campaign %d: %s\n", i, e$message))
    return(rep(0.2, 5))
  })

  # Numerical safety
  predicted_probs[!is.finite(predicted_probs)] <- 1e-8
  predicted_probs <- pmax(predicted_probs, 1e-8)
  predicted_probs <- predicted_probs / sum(predicted_probs)

  # Calculate predicted EV
  expected_per_donor_pred <- sum(predicted_probs * CONFIG$bin_values)
  ev_predicted <- campaign_row$N * expected_per_donor_pred * (1 - CONFIG$platform_fee)

  # Calculate error
  error_absolute <- abs(ev_predicted - ev_actual)
  error_percentage <- abs((ev_predicted - ev_actual) / ev_actual) * 100

  # Store results
  results <- rbind(results, data.frame(
    campaign = campaign_row$campaign,
    N = campaign_row$N,
    p1 = campaign_row$p1,
    campaign_duration = campaign_row$campaign_duration,
    target_dana = campaign_row$target_dana,
    ev_actual = ev_actual,
    ev_predicted = ev_predicted,
    error_absolute = error_absolute,
    error_percentage = error_percentage
  ))

  # Print per campaign
  cat(sprintf("Eval %d: %s\n", i, campaign_row$campaign))
  cat(sprintf("  N=%d, p1=%.3f, Duration=%d\n",
              campaign_row$N, campaign_row$p1, campaign_row$campaign_duration))
  cat(sprintf("  EV Actual:    Rp %s\n", format(round(ev_actual), big.mark=",")))
  cat(sprintf("  EV Predicted: Rp %s\n", format(round(ev_predicted), big.mark=",")))
  cat(sprintf("  Error:        %.2f%%\n\n", error_percentage))
}

# ============================================================================
# STEP 4: Calculate MAPE (All Eval Campaigns)
# ============================================================================

cat(strrep("═", 78), "\n")
cat("EVAL SET RESULTS: ALL 5 CAMPAIGNS\n")
cat(strrep("═", 78), "\n\n")

mape_all <- mean(results$error_percentage)

cat("ALL EVAL CAMPAIGNS:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  Total:         %d campaigns\n", nrow(results)))
cat(sprintf("  MAPE:          %.2f%%\n", mape_all))
cat(sprintf("  Min Error:     %.2f%%\n", min(results$error_percentage)))
cat(sprintf("  Max Error:     %.2f%%\n", max(results$error_percentage)))
cat(sprintf("  Median Error:  %.2f%%\n", median(results$error_percentage)))
cat(sprintf("  MAE (Rupiah):  Rp %s\n\n",
            format(round(mean(results$error_absolute)), big.mark=",")))

# ============================================================================
# STEP 5: Filtered Eval (N >= 50 AND Duration <= 1000)
# ============================================================================

cat(strrep("═", 78), "\n")
cat("FILTERED EVAL (N >= 50 AND Duration <= 1000)\n")
cat(strrep("═", 78), "\n\n")

results_filtered <- results[
  results$N >= 50 & results$campaign_duration <= 1000,
]

cat(sprintf("Filtered campaigns: %d/%d\n", nrow(results_filtered), nrow(results)))
cat("\n")

if (nrow(results_filtered) > 0) {
  mape_filtered <- mean(results_filtered$error_percentage)

  cat("FILTERED RESULTS:\n")
  cat(strrep("-", 78), "\n")
  cat(sprintf("  MAPE:          %.2f%%\n", mape_filtered))
  cat(sprintf("  Min Error:     %.2f%%\n", min(results_filtered$error_percentage)))
  cat(sprintf("  Max Error:     %.2f%%\n", max(results_filtered$error_percentage)))
  cat(sprintf("  Median Error:  %.2f%%\n\n", median(results_filtered$error_percentage)))
} else {
  mape_filtered <- NA
  cat("  No campaigns meet filter criteria\n\n")
}

# ============================================================================
# STEP 6: Comprehensive Comparison
# ============================================================================

cat(strrep("═", 78), "\n")
cat("COMPREHENSIVE COMPARISON: ALL APPROACHES\n")
cat(strrep("═", 78), "\n\n")

comparison <- data.frame(
  Model = c(
    "Baseline (80 campaigns, 3 feat)",
    "Improved - Train/Val (61 clean, 5 feat)",
    "Improved - Eval Set (61 clean, 5 feat)"
  ),

  Data_Source = c(
    "Train/Val split (16 val)",
    "Train/Val split (12 val)",
    "Separate eval (5 campaigns)"
  ),

  MAPE = c(
    "97.42%",
    "65.50%",
    sprintf("%.2f%%", mape_all)
  ),

  MAPE_Filtered = c(
    "113.57%",
    "N/A",
    if (!is.na(mape_filtered)) sprintf("%.2f%%", mape_filtered) else "N/A"
  ),

  Status = c(
    "Poor (Underfitting)",
    "Reasonable",
    if (mape_all < 60) "GOOD"
    else if (mape_all < 70) "Reasonable"
    else "Poor"
  )
)

print(comparison, row.names = FALSE)
cat("\n")

# ============================================================================
# STEP 7: Detailed Campaign Breakdown
# ============================================================================

cat(strrep("═", 78), "\n")
cat("DETAILED EVAL CAMPAIGN BREAKDOWN\n")
cat(strrep("═", 78), "\n\n")

# Sort by error
results_sorted <- results[order(results$error_percentage), ]

for (i in 1:nrow(results_sorted)) {
  row <- results_sorted[i, ]

  tier <- if (row$error_percentage < 20) "✓ GOOD"
         else if (row$error_percentage < 50) "⚠ REASONABLE"
         else "✗ POOR"

  filter_status <- if (row$N >= 50 && row$campaign_duration <= 1000) "[INCLUDED]" else "[EXCLUDED]"

  cat(sprintf("%d. %s %s\n", i, tier, filter_status))
  cat(sprintf("   Campaign: %s\n", row$campaign))
  cat(sprintf("   N=%d, p1=%.3f, Duration=%d days\n",
              row$N, row$p1, row$campaign_duration))
  cat(sprintf("   Error: %.2f%%  (Actual: Rp %s, Predicted: Rp %s)\n\n",
              row$error_percentage,
              format(round(row$ev_actual), big.mark=","),
              format(round(row$ev_predicted), big.mark=",")))
}

# ============================================================================
# STEP 8: Save Results
# ============================================================================

cat(strrep("=", 78), "\n")
cat("Saving Results\n")
cat(strrep("=", 78), "\n\n")

write_csv(results, CONFIG$output_file)
cat(sprintf("✓ Results saved: %s\n\n", CONFIG$output_file))

# Save comprehensive summary
final_summary <- list(
  eval_campaigns = nrow(results),
  mape_all = mape_all,
  mape_filtered = mape_filtered,
  baseline_mape_trainval = 97.42,
  improved_mape_trainval = 65.50,
  improvement_trainval = 31.92,
  model_features = model$features,
  bin_values = CONFIG$bin_values
)

saveRDS(final_summary, "data-preparation/final_eval_summary.rds")
cat("✓ Summary saved\n\n")

# ============================================================================
# FINAL COMPARISON TABLE
# ============================================================================

cat(strrep("═", 78), "\n")
cat("FINAL COMPARISON: EVOLUTION OF MODEL IMPROVEMENTS\n")
cat(strrep("═", 78), "\n\n")

evolution <- data.frame(
  Stage = c(
    "1. Original (30 campaigns)",
    "2. + More data (80 campaigns)",
    "3. + Clean + Features (61 campaigns)",
    "   3a. Validation: Train/Val Split",
    "   3b. Validation: Separate Eval"
  ),

  Features = c(
    "3 (baseline)",
    "3 (baseline)",
    "5 (+ p1 + log_ratio)",
    "5 (+ p1 + log_ratio)",
    "5 (+ p1 + log_ratio)"
  ),

  Validation = c(
    "5 separate",
    "16 train/val",
    "12 train/val",
    "12 train/val",
    "5 separate"
  ),

  MAPE = c(
    "49.53% (filtered)",
    "97.42%",
    "N/A",
    "65.50%",
    sprintf("%.2f%%", mape_all)
  ),

  Notes = c(
    "Optimistic (small sample)",
    "Realistic (underfitting)",
    "Training phase",
    "✓ Target achieved",
    "True out-of-distribution"
  )
)

print(evolution, row.names = FALSE)
cat("\n")

# ============================================================================
# FINAL VERDICT
# ============================================================================

cat(strrep("═", 78), "\n")
cat("FINAL VERDICT\n")
cat(strrep("═", 78), "\n\n")

cat("IMPROVED MODEL PERFORMANCE:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  Eval Set MAPE:      %.2f%%\n", mape_all))

if (!is.na(mape_filtered) && nrow(results_filtered) > 0) {
  cat(sprintf("  Filtered MAPE:      %.2f%% (%d campaigns)\n",
              mape_filtered, nrow(results_filtered)))
}

cat("\n")

cat("STATUS:\n")
cat(strrep("-", 78), "\n")

if (mape_all < 60) {
  cat("  ✓ EXCELLENT! Model achieves GOOD FORECAST on eval set\n")
  cat("  → Ready for production deployment\n")
} else if (mape_all < 70) {
  cat("  ✓ GOOD! Model achieves REASONABLE FORECAST on eval set\n")
  cat("  → Acceptable for business use with monitoring\n")
} else if (mape_all < 90) {
  cat("  ⚠ MODERATE! Model shows improvement but still high error\n")
  cat("  → Use with caution, consider ensemble approach\n")
} else {
  cat("  ✗ POOR! Model performs similar to baseline\n")
  cat("  → Need fundamental rethink or more data\n")
}

cat("\n")

cat("KEY IMPROVEMENTS ACHIEVED:\n")
cat(strrep("-", 78), "\n")
cat("  ✓ Data cleaning: Removed 19 bad campaigns (Duration=0, 2.5T targets)\n")
cat("  ✓ Feature engineering: Added p1 concentration + log_target_per_donor\n")
cat("  ✓ Feature selection: BIC-based selection (5 features chosen)\n")
cat(sprintf("  ✓ Performance: %.2f%% → %.2f%% (train/val improvement)\n",
            97.42, 65.50))

cat("\n")
cat(strrep("═", 78), "\n")
cat("✓ FINAL EVAL TEST COMPLETE!\n")
cat(strrep("═", 78), "\n\n")
