#!/usr/bin/env Rscript
# Evaluate Improved Model on Validation Split

library(readr)
library(DirichletReg)

cat("\n")
cat("╔", strrep("═", 78), "╗\n", sep="")
cat("║", sprintf("%-78s", "  EVALUATION: IMPROVED MODEL"), "║\n")
cat("╚", strrep("═", 78), "╝\n\n", sep="")

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG <- list(
  model_file = "data-preparation/improved_dirichlet_model.rds",
  data_file = "data-preparation/data_preparation_features.csv",
  output_file = "data-preparation/improved_mape_results.csv",
  bin_values = c(3000, 20000, 50000, 100000, 350000),
  platform_fee = 0.05,
  val_split = 0.20,
  seed = 42,
  baseline_mape = 97.42  # From train_val_split_evaluation
)

# ============================================================================
# STEP 1: Load Model and Data
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 1: Loading Model and Data\n")
cat(strrep("=", 78), "\n\n")

# Load improved model
model <- readRDS(CONFIG$model_file)
cat("✓ Model loaded\n")
cat(sprintf("  Features: %s\n\n", paste(model$features, collapse=", ")))

# Load data
all_data <- read_csv(CONFIG$data_file, show_col_types = FALSE)
names(all_data) <- tolower(trimws(names(all_data)))
names(all_data) <- sub(".*\\.", "", names(all_data))

# Get validation split (same as training)
set.seed(CONFIG$seed)
n_total <- nrow(all_data)
n_val <- round(n_total * CONFIG$val_split)
n_train <- n_total - n_val

shuffled_indices <- sample(1:n_total)
val_data <- all_data[shuffled_indices[(n_train + 1):n_total], ]

cat(sprintf("✓ Validation data: %d campaigns\n\n", nrow(val_data)))

# ============================================================================
# STEP 2: Evaluate on Validation Set
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 2: Evaluating on Validation Set\n")
cat(strrep("=", 78), "\n\n")

results <- data.frame()

for (i in 1:nrow(val_data)) {
  campaign_row <- val_data[i, ]

  # Calculate actual EV
  actual_probs <- c(campaign_row$p1, campaign_row$p2, campaign_row$p3,
                   campaign_row$p4, campaign_row$p5)
  expected_per_donor_actual <- sum(actual_probs * CONFIG$bin_values)
  ev_actual <- campaign_row$n * expected_per_donor_actual * (1 - CONFIG$platform_fee)

  # Prepare features for prediction
  new_data_list <- list()
  for (feat in model$features) {
    new_data_list[[feat]] <- campaign_row[[feat]]
  }
  new_data <- as.data.frame(new_data_list)

  # Scale using training parameters
  for (feat in model$features) {
    new_data[[feat]] <- (new_data[[feat]] - model$scales[[feat]]$mean) /
                        model$scales[[feat]]$sd

    # Replace any NaN/Inf with 0
    new_data[[feat]][!is.finite(new_data[[feat]])] <- 0

    # Clamp to training domain
    domain <- model$train_domain[[feat]]
    new_data[[feat]] <- pmin(pmax(new_data[[feat]], domain[1]), domain[2])
  }

  # Predict probabilities
  predicted_probs <- tryCatch({
    as.numeric(predict(model, newdata = new_data)[1, ])
  }, error = function(e) {
    return(rep(0.2, 5))
  })

  # Numerical safety
  predicted_probs[!is.finite(predicted_probs)] <- 1e-8
  predicted_probs <- pmax(predicted_probs, 1e-8)
  predicted_probs <- predicted_probs / sum(predicted_probs)

  # Calculate predicted EV
  expected_per_donor_pred <- sum(predicted_probs * CONFIG$bin_values)
  ev_predicted <- campaign_row$n * expected_per_donor_pred * (1 - CONFIG$platform_fee)

  # Calculate error
  error_absolute <- abs(ev_predicted - ev_actual)
  error_percentage <- abs((ev_predicted - ev_actual) / ev_actual) * 100

  # Store results
  results <- rbind(results, data.frame(
    campaign_id = i,
    N = campaign_row$n,
    p1 = campaign_row$p1,
    duration = campaign_row$current_duration,
    ev_actual = ev_actual,
    ev_predicted = ev_predicted,
    error_percentage = error_percentage
  ))
}

cat(sprintf("✓ Evaluated %d validation campaigns\n\n", nrow(results)))

# ============================================================================
# STEP 3: Calculate MAPE
# ============================================================================

cat(strrep("═", 78), "\n")
cat("VALIDATION RESULTS: IMPROVED MODEL\n")
cat(strrep("═", 78), "\n\n")

mape <- mean(results$error_percentage)

cat("ALL VALIDATION CAMPAIGNS:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  MAPE:          %.2f%%\n", mape))
cat(sprintf("  Min Error:     %.2f%%\n", min(results$error_percentage)))
cat(sprintf("  Max Error:     %.2f%%\n", max(results$error_percentage)))
cat(sprintf("  Median Error:  %.2f%%\n", median(results$error_percentage)))
cat(sprintf("  Std Dev:       %.2f%%\n\n", sd(results$error_percentage)))

# By p1 level
high_p1 <- results[results$p1 > 0.95, ]
low_p1 <- results[results$p1 <= 0.7, ]

if (nrow(high_p1) > 0) {
  cat(sprintf("HIGH p1 (>0.95): %d campaigns, MAPE=%.2f%%\n",
              nrow(high_p1), mean(high_p1$error_percentage)))
}

if (nrow(low_p1) > 0) {
  cat(sprintf("LOW p1 (<=0.7):  %d campaigns, MAPE=%.2f%%\n",
              nrow(low_p1), mean(low_p1$error_percentage)))
}

cat("\n")

# ============================================================================
# STEP 4: Comparison with Baseline
# ============================================================================

cat(strrep("═", 78), "\n")
cat("COMPARISON: BASELINE vs IMPROVED\n")
cat(strrep("═", 78), "\n\n")

improvement <- CONFIG$baseline_mape - mape
improvement_pct <- (improvement / CONFIG$baseline_mape) * 100

comparison <- data.frame(
  Model = c("Baseline (3 features)", "Improved (5 features)"),
  Features = c("n, duration, target", "base + p1 + log_ratio"),
  Training_Size = c("64 campaigns", "49 campaigns"),
  MAPE = c(sprintf("%.2f%%", CONFIG$baseline_mape), sprintf("%.2f%%", mape)),
  Status = c(
    "Poor",
    if (mape < 60) "GOOD" else if (mape < 70) "Reasonable" else "Poor"
  )
)

print(comparison, row.names = FALSE)
cat("\n")

cat("IMPROVEMENT:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  Baseline MAPE:   %.2f%%\n", CONFIG$baseline_mape))
cat(sprintf("  Improved MAPE:   %.2f%%\n", mape))
cat(sprintf("  Improvement:     %.2f pp (%.1f%% better)\n\n",
            improvement, improvement_pct))

if (improvement > 0) {
  if (mape < 60) {
    cat("✓ SUCCESS! Model reached GOOD FORECAST tier (<60%)\n")
  } else if (mape < 70) {
    cat("✓ SUCCESS! Model reached target (60-70%)\n")
  } else {
    cat("⚠ PARTIAL SUCCESS! Improved but not at target yet\n")
  }
} else {
  cat("✗ NO IMPROVEMENT! Model worse than baseline\n")
}

cat("\n")

# ============================================================================
# STEP 5: Save Results
# ============================================================================

cat(strrep("=", 78), "\n")
cat("Saving Results\n")
cat(strrep("=", 78), "\n\n")

write_csv(results, CONFIG$output_file)
cat(sprintf("✓ Results saved: %s\n\n", CONFIG$output_file))

# Save summary
summary_data <- list(
  model_features = model$features,
  mape = mape,
  baseline_mape = CONFIG$baseline_mape,
  improvement_pp = improvement,
  improvement_pct = improvement_pct,
  validation_campaigns = nrow(results),
  high_p1_mape = if (nrow(high_p1) > 0) mean(high_p1$error_percentage) else NA
)

saveRDS(summary_data, "data-preparation/improved_model_summary.rds")
cat("✓ Summary saved\n\n")

# ============================================================================
# FINAL SUMMARY
# ============================================================================

cat(strrep("═", 78), "\n")
cat("FINAL SUMMARY\n")
cat(strrep("═", 78), "\n\n")

cat(sprintf("MAPE:        %.2f%%\n", mape))
cat(sprintf("Improvement: %.2f pp from baseline\n", improvement))
cat(sprintf("Features:    %d (selected by BIC)\n", length(model$features)))
cat("\n")

if (mape < 70) {
  cat("✓ TARGET ACHIEVED! Model performance acceptable\n")
} else {
  cat("⚠ TARGET NOT MET! Further optimization needed\n")
  cat("  Recommendations:\n")
  cat("    - Add more training data\n")
  cat("    - Try ensemble approach (separate models for high/low p1)\n")
  cat("    - Consider non-parametric models (Random Forest)\n")
}

cat("\n")
cat(strrep("═", 78), "\n")
cat("✓ EVALUATION COMPLETE!\n")
cat(strrep("═", 78), "\n\n")
