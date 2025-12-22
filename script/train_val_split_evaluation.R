#!/usr/bin/env Rscript
# Train/Validation Split Evaluation
# Split 80 campaigns into train/val and evaluate MAPE

library(readr)
library(DirichletReg)

cat("\n")
cat("╔", strrep("═", 78), "╗\n", sep="")
cat("║", sprintf("%-78s", "  TRAIN/VAL SPLIT EVALUATION (80 CAMPAIGNS)"), "║\n")
cat("╚", strrep("═", 78), "╝\n\n", sep="")

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG <- list(
  data_file = "data-preparation/data_preparation_result_80.csv",
  bin_values = c(3000, 20000, 50000, 100000, 350000),
  platform_fee = 0.05,
  val_split = 0.20,  # 20% for validation
  random_seed = 42
)

cat("CONFIGURATION:\n")
cat(strrep("=", 78), "\n")
cat("  Data file:       ", CONFIG$data_file, "\n")
cat("  Bin values:      ", paste(CONFIG$bin_values, collapse=", "), "\n")
cat("  Validation split:", CONFIG$val_split * 100, "%\n")
cat("  Random seed:     ", CONFIG$random_seed, "\n\n")

# ============================================================================
# STEP 1: Load and Split Data
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 1: Loading and Splitting Data\n")
cat(strrep("=", 78), "\n\n")

all_data <- read_csv(CONFIG$data_file, show_col_types = FALSE)

# Normalize column names
names(all_data) <- tolower(trimws(names(all_data)))
names(all_data) <- sub(".*\\.", "", names(all_data))

cat("✓ Loaded", nrow(all_data), "campaigns\n\n")

# Set random seed for reproducibility
set.seed(CONFIG$random_seed)

# Random split
n_total <- nrow(all_data)
n_val <- round(n_total * CONFIG$val_split)
n_train <- n_total - n_val

# Shuffle indices
shuffled_indices <- sample(1:n_total)

# Split
train_indices <- shuffled_indices[1:n_train]
val_indices <- shuffled_indices[(n_train + 1):n_total]

train_data <- all_data[train_indices, ]
val_data <- all_data[val_indices, ]

cat("DATA SPLIT:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  Total:       %d campaigns\n", n_total))
cat(sprintf("  Training:    %d campaigns (%.0f%%)\n", n_train, (1 - CONFIG$val_split) * 100))
cat(sprintf("  Validation:  %d campaigns (%.0f%%)\n\n", n_val, CONFIG$val_split * 100))

# Statistics
cat("TRAINING SET STATISTICS:\n")
cat(sprintf("  N range:        %d - %d\n", min(train_data$n), max(train_data$n)))
cat(sprintf("  Duration range: %d - %d days\n",
            min(train_data$current_duration), max(train_data$current_duration)))
cat(sprintf("  Target range:   Rp %s - Rp %s\n",
            format(min(train_data$target_donation), big.mark=","),
            format(max(train_data$target_donation), big.mark=",")))
cat("\n")

cat("VALIDATION SET STATISTICS:\n")
cat(sprintf("  N range:        %d - %d\n", min(val_data$n), max(val_data$n)))
cat(sprintf("  Duration range: %d - %d days\n",
            min(val_data$current_duration), max(val_data$current_duration)))
cat(sprintf("  Target range:   Rp %s - Rp %s\n\n",
            format(min(val_data$target_donation), big.mark=","),
            format(max(val_data$target_donation), big.mark=",")))

# ============================================================================
# STEP 2: Train Model
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 2: Training Model on Training Split\n")
cat(strrep("=", 78), "\n\n")

# Prepare Dirichlet response
prob_cols <- c("p1", "p2", "p3", "p4", "p5")
prob_matrix <- as.matrix(train_data[, prob_cols])
prob_matrix <- prob_matrix / rowSums(prob_matrix)

Y <- DirichletReg::DR_data(prob_matrix)

# Prepare predictors
predictors <- data.frame(
  n = train_data$n,
  current_duration = train_data$current_duration,
  target_donation = train_data$target_donation
)

# Store scaling parameters
scales <- list(
  n = list(mean = mean(predictors$n), sd = sd(predictors$n)),
  current_duration = list(
    mean = mean(predictors$current_duration),
    sd = sd(predictors$current_duration)
  ),
  target_donation = list(
    mean = mean(predictors$target_donation),
    sd = sd(predictors$target_donation)
  )
)

# Scale predictors
predictors$n <- scale(predictors$n)
predictors$current_duration <- scale(predictors$current_duration)
predictors$target_donation <- scale(predictors$target_donation)

# Train model
cat(sprintf("Training model with %d campaigns...\n", n_train))

model <- DirichReg(
  Y ~ n + current_duration + target_donation,
  data = predictors,
  model = "alternative"
)

model$scales <- scales
model$train_domain <- list(
  n = range(predictors$n),
  current_duration = range(predictors$current_duration),
  target_donation = range(predictors$target_donation)
)

cat("✓ Model trained successfully\n\n")

# ============================================================================
# STEP 3: Evaluate on Validation Split
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 3: Evaluating on Validation Split\n")
cat(strrep("=", 78), "\n\n")

results <- data.frame()

for (i in 1:nrow(val_data)) {
  campaign_row <- val_data[i, ]

  # Calculate actual EV
  actual_probs <- c(campaign_row$p1, campaign_row$p2, campaign_row$p3,
                   campaign_row$p4, campaign_row$p5)
  expected_per_donor_actual <- sum(actual_probs * CONFIG$bin_values)
  ev_actual <- campaign_row$n * expected_per_donor_actual * (1 - CONFIG$platform_fee)

  # Prepare prediction data
  new_data <- data.frame(
    n = (campaign_row$n - model$scales$n$mean) / model$scales$n$sd,
    current_duration = (campaign_row$current_duration - model$scales$current_duration$mean) /
                      model$scales$current_duration$sd,
    target_donation = (campaign_row$target_donation - model$scales$target_donation$mean) /
                     model$scales$target_donation$sd
  )

  # Clamp to training domain
  new_data$n <- pmin(pmax(new_data$n, model$train_domain$n[1]),
                    model$train_domain$n[2])
  new_data$current_duration <- pmin(
    pmax(new_data$current_duration, model$train_domain$current_duration[1]),
    model$train_domain$current_duration[2]
  )
  new_data$target_donation <- pmin(
    pmax(new_data$target_donation, model$train_domain$target_donation[1]),
    model$train_domain$target_donation[2]
  )

  # Predict probabilities
  predicted_probs <- as.numeric(predict(model, newdata = new_data)[1, ])

  # Numerical safety
  predicted_probs[!is.finite(predicted_probs)] <- 1e-8
  predicted_probs <- pmax(predicted_probs, 1e-8)
  predicted_probs <- predicted_probs / sum(predicted_probs)

  # Calculate predicted EV
  expected_per_donor_pred <- sum(predicted_probs * CONFIG$bin_values)
  ev_predicted <- campaign_row$n * expected_per_donor_pred * (1 - CONFIG$platform_fee)

  # Calculate errors
  error_absolute <- abs(ev_predicted - ev_actual)
  error_percentage <- abs((ev_predicted - ev_actual) / ev_actual) * 100

  # Store results
  results <- rbind(results, data.frame(
    campaign = campaign_row$campaign,
    N = campaign_row$n,
    campaign_duration = campaign_row$current_duration,
    target_dana = campaign_row$target_donation,
    ev_actual = ev_actual,
    ev_predicted = ev_predicted,
    error_absolute = error_absolute,
    error_percentage = error_percentage
  ))

  cat(sprintf("Val Campaign %d: N=%d\n", i, campaign_row$n))
  cat(sprintf("  EV Actual:    Rp %s\n", format(round(ev_actual), big.mark=",")))
  cat(sprintf("  EV Predicted: Rp %s\n", format(round(ev_predicted), big.mark=",")))
  cat(sprintf("  Error:        %.2f%%\n\n", error_percentage))
}

# ============================================================================
# STEP 4: Calculate MAPE (All Validation Campaigns)
# ============================================================================

cat(strrep("═", 78), "\n")
cat("STEP 4: MAPE on Validation Split (All Campaigns)\n")
cat(strrep("═", 78), "\n\n")

mape_all <- mean(results$error_percentage)

cat("ALL VALIDATION CAMPAIGNS:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  Total:         %d campaigns\n", nrow(results)))
cat(sprintf("  MAPE:          %.2f%%\n", mape_all))
cat(sprintf("  Min Error:     %.2f%%\n", min(results$error_percentage)))
cat(sprintf("  Max Error:     %.2f%%\n", max(results$error_percentage)))
cat(sprintf("  Median Error:  %.2f%%\n", median(results$error_percentage)))
cat(sprintf("  Std Dev:       %.2f%%\n\n", sd(results$error_percentage)))

# ============================================================================
# STEP 5: MAPE with Filters
# ============================================================================

cat(strrep("═", 78), "\n")
cat("STEP 5: MAPE with Filters (N >= 50 AND Duration <= 1000)\n")
cat(strrep("═", 78), "\n\n")

results_filtered <- results[
  results$N >= 50 & results$campaign_duration <= 1000,
]

cat(sprintf("Filtered campaigns: %d/%d (%.0f%%)\n",
            nrow(results_filtered), nrow(results),
            (nrow(results_filtered) / nrow(results)) * 100))
cat("\n")

if (nrow(results_filtered) > 0) {
  mape_filtered <- mean(results_filtered$error_percentage)

  cat("FILTERED RESULTS:\n")
  cat(strrep("-", 78), "\n")
  cat(sprintf("  MAPE:          %.2f%%\n", mape_filtered))
  cat(sprintf("  Min Error:     %.2f%%\n", min(results_filtered$error_percentage)))
  cat(sprintf("  Max Error:     %.2f%%\n", max(results_filtered$error_percentage)))
  cat(sprintf("  Median Error:  %.2f%%\n", median(results_filtered$error_percentage)))
  cat(sprintf("  MAE (Rupiah):  Rp %s\n\n",
      format(round(mean(results_filtered$error_absolute)), big.mark=",")))
} else {
  mape_filtered <- NA
  cat("No campaigns meet filter criteria\n\n")
}

# ============================================================================
# STEP 6: Comparison with Previous Results
# ============================================================================

cat(strrep("═", 78), "\n")
cat("COMPARISON: Different Validation Approaches\n")
cat(strrep("═", 78), "\n\n")

comparison <- data.frame(
  Approach = c(
    "Separate Eval Set (5 campaigns)",
    "Train/Val Split (16 campaigns)",
    "Train/Val Filtered"
  ),

  Training = c(
    "80 campaigns",
    paste(n_train, "campaigns"),
    paste(n_train, "campaigns")
  ),

  Validation = c(
    "5 campaigns (separate)",
    paste(n_val, "campaigns (20% split)"),
    sprintf("%d campaigns (filtered)", nrow(results_filtered))
  ),

  MAPE = c(
    "45.26%",
    sprintf("%.2f%%", mape_all),
    if (!is.na(mape_filtered)) sprintf("%.2f%%", mape_filtered) else "N/A"
  ),

  Status = c(
    "Reasonable",
    if (mape_all < 20) "GOOD"
    else if (mape_all < 50) "Reasonable"
    else "Poor",
    if (!is.na(mape_filtered) && mape_filtered < 20) "GOOD"
    else if (!is.na(mape_filtered) && mape_filtered < 50) "Reasonable"
    else "Poor"
  )
)

print(comparison, row.names = FALSE)
cat("\n")

# ============================================================================
# STEP 7: Detailed Breakdown
# ============================================================================

cat(strrep("═", 78), "\n")
cat("DETAILED VALIDATION RESULTS\n")
cat(strrep("═", 78), "\n\n")

# Sort by error
results_sorted <- results[order(results$error_percentage), ]

cat("ALL VALIDATION CAMPAIGNS (Sorted by Error):\n")
cat(strrep("-", 78), "\n\n")

for (i in 1:nrow(results_sorted)) {
  row <- results_sorted[i, ]

  status_icon <- if (row$error_percentage < 20) "✓"
                else if (row$error_percentage < 50) "⚠"
                else "✗"

  filter_status <- if (row$N >= 50 && row$campaign_duration <= 1000) "[PASS]" else "[EXCL]"

  cat(sprintf("%2d. %s %s (N=%d, Dur=%d)\n",
              i, status_icon, filter_status, row$N, row$campaign_duration))
  cat(sprintf("    Error: %.2f%%  |  EV: Rp %s vs Rp %s\n",
              row$error_percentage,
              format(round(row$ev_actual), big.mark=","),
              format(round(row$ev_predicted), big.mark=",")))
}

cat("\n")

# ============================================================================
# STEP 8: Statistical Analysis
# ============================================================================

cat(strrep("═", 78), "\n")
cat("STATISTICAL ANALYSIS\n")
cat(strrep("═", 78), "\n\n")

# Categorize errors
excellent <- sum(results$error_percentage < 10)
good <- sum(results$error_percentage >= 10 & results$error_percentage < 20)
reasonable <- sum(results$error_percentage >= 20 & results$error_percentage < 50)
poor <- sum(results$error_percentage >= 50)

cat("ERROR DISTRIBUTION:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  Excellent (< 10%%):   %d campaigns (%.0f%%)\n",
            excellent, (excellent / nrow(results)) * 100))
cat(sprintf("  Good (10-20%%):       %d campaigns (%.0f%%)\n",
            good, (good / nrow(results)) * 100))
cat(sprintf("  Reasonable (20-50%%): %d campaigns (%.0f%%)\n",
            reasonable, (reasonable / nrow(results)) * 100))
cat(sprintf("  Poor (> 50%%):        %d campaigns (%.0f%%)\n\n",
            poor, (poor / nrow(results)) * 100))

# Percentiles
cat("ERROR PERCENTILES:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  10th percentile: %.2f%%\n", quantile(results$error_percentage, 0.10)))
cat(sprintf("  25th percentile: %.2f%%\n", quantile(results$error_percentage, 0.25)))
cat(sprintf("  50th percentile: %.2f%%\n", quantile(results$error_percentage, 0.50)))
cat(sprintf("  75th percentile: %.2f%%\n", quantile(results$error_percentage, 0.75)))
cat(sprintf("  90th percentile: %.2f%%\n\n", quantile(results$error_percentage, 0.90)))

# ============================================================================
# STEP 9: Save Results
# ============================================================================

cat(strrep("=", 78), "\n")
cat("Saving Results\n")
cat(strrep("=", 78), "\n\n")

# Save split data
write_csv(train_data, "data-preparation/train_split_64.csv")
cat("✓ Training split saved: train_split_64.csv\n")

write_csv(val_data, "data-preparation/val_split_16.csv")
cat("✓ Validation split saved: val_split_16.csv\n")

# Save model
saveRDS(model, "data-preparation/model_train_val_split.rds")
cat("✓ Model saved: model_train_val_split.rds\n")

# Save results
write_csv(results, "data-preparation/val_split_results.csv")
cat("✓ Validation results saved: val_split_results.csv\n")

# Save summary
summary_data <- list(
  total_campaigns = n_total,
  train_campaigns = n_train,
  val_campaigns = n_val,
  mape_all = mape_all,
  mape_filtered = mape_filtered,
  bin_values = CONFIG$bin_values,
  excellent_count = excellent,
  good_count = good,
  reasonable_count = reasonable,
  poor_count = poor
)

saveRDS(summary_data, "data-preparation/train_val_summary.rds")
cat("✓ Summary saved: train_val_summary.rds\n\n")

# ============================================================================
# FINAL SUMMARY
# ============================================================================

cat(strrep("═", 78), "\n")
cat("FINAL SUMMARY\n")
cat(strrep("═", 78), "\n\n")

cat("DATA SPLIT:\n")
cat(sprintf("  Training:    %d campaigns\n", n_train))
cat(sprintf("  Validation:  %d campaigns\n\n", n_val))

cat("RESULTS:\n")
cat(sprintf("  All Val Campaigns:  %.2f%% MAPE\n", mape_all))
if (!is.na(mape_filtered)) {
  cat(sprintf("  Filtered Val:       %.2f%% MAPE\n", mape_filtered))
}
cat("\n")

cat("PERFORMANCE TIER:\n")
if (!is.na(mape_filtered) && mape_filtered < 20) {
  cat("  ✓ GOOD FORECAST (< 20%)\n")
  cat("    → Model ready for production\n")
} else if (!is.na(mape_filtered) && mape_filtered < 50) {
  cat("  ✓ REASONABLE FORECAST (20-50%)\n")
  cat("    → Acceptable for business use with caution\n")
} else {
  cat("  ⚠ NEEDS IMPROVEMENT (> 50%)\n")
  cat("    → Further optimization required\n")
}

cat("\n")
cat(strrep("═", 78), "\n")
cat("✓ Train/Val Split Evaluation Complete!\n")
cat(strrep("═", 78), "\n\n")
