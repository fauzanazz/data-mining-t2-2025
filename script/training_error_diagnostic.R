#!/usr/bin/env Rscript
# Training Error Diagnostic
# Evaluate model on SAME data it was trained on (data leakage experiment)
# Useful for diagnosing overfitting/underfitting

library(readr)
library(DirichletReg)

cat("\n")
cat("╔", strrep("═", 78), "╗\n", sep="")
cat("║", sprintf("%-78s", "  TRAINING ERROR DIAGNOSTIC (DATA LEAKAGE EXPERIMENT)"), "║\n")
cat("║", sprintf("%-78s", "  ⚠️  For diagnostic purposes only - NOT for production"), "║\n")
cat("╚", strrep("═", 78), "╝\n\n", sep="")

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG <- list(
  data_file = "data-preparation/data_preparation_result_80.csv",
  bin_values = c(3000, 20000, 50000, 100000, 350000),
  platform_fee = 0.05
)

# ============================================================================
# STEP 1: Load Data
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 1: Loading Training Data\n")
cat(strrep("=", 78), "\n\n")

train_data <- read_csv(CONFIG$data_file, show_col_types = FALSE)

names(train_data) <- tolower(trimws(names(train_data)))
names(train_data) <- sub(".*\\.", "", names(train_data))

cat("✓ Loaded", nrow(train_data), "campaigns\n\n")

# ============================================================================
# STEP 2: Train Model
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 2: Training Dirichlet Model\n")
cat(strrep("=", 78), "\n\n")

prob_cols <- c("p1", "p2", "p3", "p4", "p5")
prob_matrix <- as.matrix(train_data[, prob_cols])
prob_matrix <- prob_matrix / rowSums(prob_matrix)

Y <- DirichletReg::DR_data(prob_matrix)

predictors <- data.frame(
  n = train_data$n,
  current_duration = train_data$current_duration,
  target_donation = train_data$target_donation
)

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

predictors$n <- scale(predictors$n)
predictors$current_duration <- scale(predictors$current_duration)
predictors$target_donation <- scale(predictors$target_donation)

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

cat("✓ Model trained on", nrow(train_data), "campaigns\n\n")

# ============================================================================
# STEP 3: Evaluate on SAME Training Data (Data Leakage)
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 3: Evaluating on SAME Training Data (⚠️  DATA LEAKAGE)\n")
cat(strrep("=", 78), "\n\n")

results <- data.frame()

for (i in 1:nrow(train_data)) {
  campaign_row <- train_data[i, ]

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
  predicted_probs[!is.finite(predicted_probs)] <- 1e-8
  predicted_probs <- pmax(predicted_probs, 1e-8)
  predicted_probs <- predicted_probs / sum(predicted_probs)

  # Calculate predicted EV
  expected_per_donor_pred <- sum(predicted_probs * CONFIG$bin_values)
  ev_predicted <- campaign_row$n * expected_per_donor_pred * (1 - CONFIG$platform_fee)

  # Calculate errors
  error_absolute <- abs(ev_predicted - ev_actual)
  error_percentage <- abs((ev_predicted - ev_actual) / ev_actual) * 100

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
}

cat(sprintf("✓ Evaluated %d campaigns (same as training)\n\n", nrow(results)))

# ============================================================================
# STEP 4: Calculate Training MAPE
# ============================================================================

cat(strrep("═", 78), "\n")
cat("TRAINING ERROR (Best Case - WITH Data Leakage)\n")
cat(strrep("═", 78), "\n\n")

mape_training_all <- mean(results$error_percentage)

cat("ALL TRAINING CAMPAIGNS (80):\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  MAPE:          %.2f%%\n", mape_training_all))
cat(sprintf("  Min Error:     %.2f%%\n", min(results$error_percentage)))
cat(sprintf("  Max Error:     %.2f%%\n", max(results$error_percentage)))
cat(sprintf("  Median Error:  %.2f%%\n", median(results$error_percentage)))
cat(sprintf("  Std Dev:       %.2f%%\n\n", sd(results$error_percentage)))

# With filters
results_filtered <- results[
  results$N >= 50 &
  results$campaign_duration > 0 &
  results$campaign_duration <= 1000,
]

cat(sprintf("FILTERED (N >= 50 AND 0 < Duration <= 1000): %d campaigns\n",
            nrow(results_filtered)))
cat(strrep("-", 78), "\n")

if (nrow(results_filtered) > 0) {
  mape_training_filtered <- mean(results_filtered$error_percentage)

  cat(sprintf("  MAPE:          %.2f%%\n", mape_training_filtered))
  cat(sprintf("  Min Error:     %.2f%%\n", min(results_filtered$error_percentage)))
  cat(sprintf("  Max Error:     %.2f%%\n", max(results_filtered$error_percentage)))
  cat(sprintf("  Median Error:  %.2f%%\n\n", median(results_filtered$error_percentage)))
} else {
  mape_training_filtered <- NA
}

# ============================================================================
# STEP 5: Load Validation Results and Compare
# ============================================================================

cat(strrep("═", 78), "\n")
cat("TRAIN vs VALIDATION GAP ANALYSIS\n")
cat(strrep("═", 78), "\n\n")

# Load previous validation results
val_results <- readRDS("data-preparation/train_val_summary.rds")

cat("COMPARISON TABLE:\n")
cat(strrep("-", 78), "\n\n")

comparison <- data.frame(
  Dataset = c(
    "Training Error (All 80)",
    "Training Error (Filtered)",
    "Validation Error (All 16)",
    "Validation Error (Filtered 13)"
  ),

  Campaigns = c(
    80,
    nrow(results_filtered),
    val_results$val_campaigns,
    nrow(results_filtered)  # Approximation
  ),

  MAPE = c(
    sprintf("%.2f%%", mape_training_all),
    if (!is.na(mape_training_filtered)) sprintf("%.2f%%", mape_training_filtered) else "N/A",
    sprintf("%.2f%%", val_results$mape_all),
    sprintf("%.2f%%", val_results$mape_filtered)
  ),

  Note = c(
    "⚠️  DATA LEAKAGE (model sees this data)",
    "⚠️  DATA LEAKAGE",
    "✓ True generalization",
    "✓ True generalization"
  )
)

print(comparison, row.names = FALSE)
cat("\n")

# Calculate gaps
cat("OVERFITTING ANALYSIS:\n")
cat(strrep("-", 78), "\n")

gap_all <- val_results$mape_all - mape_training_all
gap_filtered <- val_results$mape_filtered - mape_training_filtered

cat(sprintf("  Training MAPE (All):     %.2f%%\n", mape_training_all))
cat(sprintf("  Validation MAPE (All):   %.2f%%\n", val_results$mape_all))
cat(sprintf("  Gap:                     %.2f pp", gap_all))

if (gap_all > 20) {
  cat(" ⚠️  OVERFITTING\n")
} else if (gap_all > 10) {
  cat(" ⚠️  Moderate overfitting\n")
} else {
  cat(" ✓ Good generalization\n")
}

cat("\n")

if (!is.na(mape_training_filtered)) {
  cat(sprintf("  Training MAPE (Filtered): %.2f%%\n", mape_training_filtered))
  cat(sprintf("  Validation MAPE (Filt):   %.2f%%\n", val_results$mape_filtered))
  cat(sprintf("  Gap:                      %.2f pp", gap_filtered))

  if (gap_filtered > 20) {
    cat(" ⚠️  OVERFITTING\n")
  } else if (gap_filtered > 10) {
    cat(" ⚠️  Moderate overfitting\n")
  } else {
    cat(" ✓ Good generalization\n")
  }
}

cat("\n")

# ============================================================================
# STEP 6: Error Distribution Analysis
# ============================================================================

cat(strrep("═", 78), "\n")
cat("ERROR DISTRIBUTION: Training vs Validation\n")
cat(strrep("═", 78), "\n\n")

# Training error distribution
train_excellent <- sum(results$error_percentage < 10)
train_good <- sum(results$error_percentage >= 10 & results$error_percentage < 20)
train_reasonable <- sum(results$error_percentage >= 20 & results$error_percentage < 50)
train_poor <- sum(results$error_percentage >= 50)

cat("TRAINING ERROR (80 campaigns):\n")
cat(sprintf("  < 10%%:      %d campaigns (%.0f%%)\n",
            train_excellent, (train_excellent / 80) * 100))
cat(sprintf("  10-20%%:     %d campaigns (%.0f%%)\n",
            train_good, (train_good / 80) * 100))
cat(sprintf("  20-50%%:     %d campaigns (%.0f%%)\n",
            train_reasonable, (train_reasonable / 80) * 100))
cat(sprintf("  > 50%%:      %d campaigns (%.0f%%)\n\n",
            train_poor, (train_poor / 80) * 100))

cat("VALIDATION ERROR (16 campaigns):\n")
cat(sprintf("  < 10%%:      %d campaigns (%.0f%%)\n",
            val_results$excellent_count,
            (val_results$excellent_count / 16) * 100))
cat(sprintf("  10-20%%:     %d campaigns (%.0f%%)\n",
            val_results$good_count,
            (val_results$good_count / 16) * 100))
cat(sprintf("  20-50%%:     %d campaigns (%.0f%%)\n",
            val_results$reasonable_count,
            (val_results$reasonable_count / 16) * 100))
cat(sprintf("  > 50%%:      %d campaigns (%.0f%%)\n\n",
            val_results$poor_count,
            (val_results$poor_count / 16) * 100))

# ============================================================================
# STEP 7: Save Results
# ============================================================================

cat(strrep("=", 78), "\n")
cat("Saving Results\n")
cat(strrep("=", 78), "\n\n")

write_csv(results, "data-preparation/training_error_results.csv")
cat("✓ Training error results saved\n")

diagnostic_summary <- list(
  training_campaigns = nrow(train_data),
  training_mape_all = mape_training_all,
  training_mape_filtered = mape_training_filtered,
  validation_mape_all = val_results$mape_all,
  validation_mape_filtered = val_results$mape_filtered,
  overfitting_gap_all = gap_all,
  overfitting_gap_filtered = gap_filtered,
  train_excellent_pct = (train_excellent / 80) * 100,
  val_excellent_pct = (val_results$excellent_count / 16) * 100
)

saveRDS(diagnostic_summary, "data-preparation/diagnostic_summary.rds")
cat("✓ Diagnostic summary saved\n\n")

# ============================================================================
# FINAL DIAGNOSTIC REPORT
# ============================================================================

cat(strrep("═", 78), "\n")
cat("DIAGNOSTIC REPORT\n")
cat(strrep("═", 78), "\n\n")

cat("1. TRAINING ERROR (Best Case with Data Leakage):\n")
cat(sprintf("   MAPE: %.2f%%\n\n", mape_training_all))

cat("2. VALIDATION ERROR (True Generalization):\n")
cat(sprintf("   MAPE: %.2f%%\n\n", val_results$mape_all))

cat("3. TRAIN/VAL GAP:\n")
cat(sprintf("   Gap: %.2f pp\n", gap_all))

if (gap_all > 50) {
  cat("   Status: ⚠️  SEVERE OVERFITTING\n")
  cat("   → Model memorizes training data but fails on new data\n")
  cat("   → Need: More data, regularization, or simpler model\n")
} else if (gap_all > 20) {
  cat("   Status: ⚠️  MODERATE OVERFITTING\n")
  cat("   → Model fits training well but generalizes poorly\n")
  cat("   → Need: More training data or feature selection\n")
} else if (gap_all > 10) {
  cat("   Status: ⚠️  SLIGHT OVERFITTING\n")
  cat("   → Normal for complex models\n")
  cat("   → Acceptable with current data size\n")
} else {
  cat("   Status: ✓ GOOD GENERALIZATION\n")
  cat("   → Model generalizes well to unseen data\n")
}

cat("\n")

cat("4. INTERPRETATION:\n")

if (mape_training_all > 50 && val_results$mape_all > 50) {
  cat("   → UNDERFITTING: Model too simple for the problem\n")
  cat("   → Both training and validation errors are high\n")
  cat("   → Solution: Add features, more complex model\n")
} else if (mape_training_all < 30 && val_results$mape_all > 80) {
  cat("   → OVERFITTING: Model memorizes training data\n")
  cat("   → Training error low, validation error high\n")
  cat("   → Solution: More data, regularization, simpler model\n")
} else if (mape_training_all > 50 && val_results$mape_all < 50) {
  cat("   → UNUSUAL: Validation better than training (rare)\n")
  cat("   → May indicate: Lucky validation split or data issue\n")
} else {
  cat("   → BALANCED: Model shows reasonable fit\n")
  cat("   → Both errors in similar range\n")
  cat("   → Current approach is appropriate\n")
}

cat("\n")

cat(strrep("═", 78), "\n")
cat("✓ Training Error Diagnostic Complete!\n")
cat(strrep("═", 78), "\n\n")
