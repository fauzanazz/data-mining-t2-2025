#!/usr/bin/env Rscript
# Train Improved Model with Feature Selection
# Tests 6 feature combinations and selects best by BIC

library(readr)
library(DirichletReg)

cat("\n")
cat("╔", strrep("═", 78), "╗\n", sep="")
cat("║", sprintf("%-78s", "  IMPROVED MODEL: FEATURE SELECTION"), "║\n")
cat("╚", strrep("═", 78), "╝\n\n", sep="")

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG <- list(
  data_file = "data-preparation/data_preparation_features.csv",
  output_model = "data-preparation/improved_dirichlet_model.rds",
  val_split = 0.20,
  seed = 42
)

cat("CONFIGURATION:\n")
cat(strrep("=", 78), "\n")
cat("  Data file:       ", CONFIG$data_file, "\n")
cat("  Val split:       ", CONFIG$val_split * 100, "%\n")
cat("  Random seed:     ", CONFIG$seed, "\n\n")

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

# Train/Val split
set.seed(CONFIG$seed)
n_total <- nrow(all_data)
n_val <- round(n_total * CONFIG$val_split)
n_train <- n_total - n_val

shuffled_indices <- sample(1:n_total)
train_indices <- shuffled_indices[1:n_train]
val_indices <- shuffled_indices[(n_train + 1):n_total]

train_data <- all_data[train_indices, ]
val_data <- all_data[val_indices, ]

cat("DATA SPLIT:\n")
cat(sprintf("  Total:       %d campaigns\n", n_total))
cat(sprintf("  Training:    %d campaigns (%.0f%%)\n", n_train, (1 - CONFIG$val_split) * 100))
cat(sprintf("  Validation:  %d campaigns (%.0f%%)\n\n", n_val, CONFIG$val_split * 100))

# ============================================================================
# STEP 2: Define Feature Sets to Test
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 2: Feature Selection Strategy\n")
cat(strrep("=", 78), "\n\n")

# Define 6 feature combinations
feature_sets <- list(
  base = c("n", "current_duration", "target_donation"),

  base_p1 = c("n", "current_duration", "target_donation",
              "donation_concentration"),

  base_ratio = c("n", "current_duration", "target_donation",
                 "log_target_per_donor"),

  base_duration = c("n", "current_duration", "target_donation",
                    "log_duration"),

  base_p1_ratio = c("n", "current_duration", "target_donation",
                    "donation_concentration", "log_target_per_donor"),

  all_features = c("n", "current_duration", "target_donation",
                   "donation_concentration", "log_target_per_donor", "log_duration")
)

cat("Feature combinations to test:\n")
for (i in seq_along(feature_sets)) {
  set_name <- names(feature_sets)[i]
  features <- feature_sets[[set_name]]
  cat(sprintf("  %d. %-15s: %d features\n", i, set_name, length(features)))
}
cat("\n")

cat("Selection Criteria:\n")
cat("  - BIC (Bayesian Information Criterion): Lower = better\n")
cat("  - Significant coefficients: More = better (p < 0.05)\n")
cat("  - Balance fit vs complexity\n\n")

# ============================================================================
# STEP 3: Train Models with Different Feature Sets
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 3: Training Models with Feature Selection\n")
cat(strrep("=", 78), "\n\n")

# Prepare Dirichlet response (same for all models)
prob_cols <- c("p1", "p2", "p3", "p4", "p5")
prob_matrix <- as.matrix(train_data[, prob_cols])
prob_matrix <- prob_matrix / rowSums(prob_matrix)
Y <- DirichletReg::DR_data(prob_matrix)

results <- list()

for (set_name in names(feature_sets)) {
  features <- feature_sets[[set_name]]

  cat(sprintf("Training: %-15s (%d features)\n", set_name, length(features)))

  # Prepare predictors
  predictors <- as.data.frame(train_data[, features])
  names(predictors) <- features

  # Store scaling parameters
  scales <- list()
  for (feat in features) {
    scales[[feat]] <- list(
      mean = mean(predictors[[feat]], na.rm = TRUE),
      sd = sd(predictors[[feat]], na.rm = TRUE)
    )
  }

  # Scale predictors
  for (feat in features) {
    predictors[[feat]] <- scale(predictors[[feat]])
    predictors[[feat]][!is.finite(predictors[[feat]])] <- 0
  }

  # Store domain
  train_domain <- list()
  for (feat in features) {
    train_domain[[feat]] <- range(predictors[[feat]], na.rm = TRUE)
  }

  # Train model with explicit formula
  model <- tryCatch({
    if (length(features) == 3) {
      DirichReg(Y ~ n + current_duration + target_donation,
               data = predictors, model = "alternative")
    } else if (length(features) == 4) {
      if ("donation_concentration" %in% features) {
        DirichReg(Y ~ n + current_duration + target_donation + donation_concentration,
                 data = predictors, model = "alternative")
      } else if ("log_target_per_donor" %in% features) {
        DirichReg(Y ~ n + current_duration + target_donation + log_target_per_donor,
                 data = predictors, model = "alternative")
      } else {
        DirichReg(Y ~ n + current_duration + target_donation + log_duration,
                 data = predictors, model = "alternative")
      }
    } else if (length(features) == 5) {
      DirichReg(Y ~ n + current_duration + target_donation +
                   donation_concentration + log_target_per_donor,
               data = predictors, model = "alternative")
    } else {
      DirichReg(Y ~ n + current_duration + target_donation +
                   donation_concentration + log_target_per_donor + log_duration,
               data = predictors, model = "alternative")
    }
  }, error = function(e) {
    cat(sprintf("  ✗ Failed: %s\n", e$message))
    return(NULL)
  })

  if (!is.null(model)) {
    # Calculate metrics
    bic_val <- BIC(model)
    aic_val <- AIC(model)

    # Print metrics (simplified - just BIC/AIC)
    cat(sprintf("  ✓ BIC=%.2f, AIC=%.2f\n", bic_val, aic_val))

    n_significant <- NA  # Will analyze after selection
    n_total_coeffs <- NA

    # Store results
    results[[set_name]] <- list(
      model = model,
      scales = scales,
      train_domain = train_domain,
      features = features,
      bic = bic_val,
      aic = aic_val,
      n_significant = n_significant,
      n_total_coeffs = n_total_coeffs
    )
  }
}

cat("\n")

# ============================================================================
# STEP 4: Select Best Model
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 4: Model Selection (Best by BIC)\n")
cat(strrep("=", 78), "\n\n")

# Extract BIC values
bic_values <- sapply(results, function(x) x$bic)

# Sort by BIC
sorted_names <- names(bic_values)[order(bic_values)]

cat("RANKING (by BIC, lower = better):\n")
cat(strrep("-", 78), "\n")

for (i in seq_along(sorted_names)) {
  set_name <- sorted_names[i]
  res <- results[[set_name]]

  status <- if (i == 1) "🥇 BEST" else if (i == 2) "🥈" else if (i == 3) "🥉" else ""

  cat(sprintf("%d. %-15s  BIC=%.2f  AIC=%.2f  Features=%d  %s\n",
              i, set_name, res$bic, res$aic, length(res$features), status))
}

cat("\n")

# Select best model
best_set_name <- sorted_names[1]
best_result <- results[[best_set_name]]

cat("SELECTED MODEL:\n")
cat(strrep("-", 78), "\n")
cat(sprintf("  Name:      %s\n", best_set_name))
cat(sprintf("  Features:  %s\n", paste(best_result$features, collapse=", ")))
cat(sprintf("  BIC:       %.2f\n", best_result$bic))
cat(sprintf("  AIC:       %.2f\n\n", best_result$aic))

# ============================================================================
# STEP 5: Save Final Model
# ============================================================================

cat(strrep("=", 78), "\n")
cat("STEP 5: Saving Final Model\n")
cat(strrep("=", 78), "\n\n")

# Attach metadata to model
final_model <- best_result$model
final_model$scales <- best_result$scales
final_model$train_domain <- best_result$train_domain
final_model$features <- best_result$features
final_model$feature_set_name <- best_set_name
final_model$selection_bic <- best_result$bic

# Save
saveRDS(final_model, CONFIG$output_model)

cat(sprintf("✓ Model saved: %s\n", CONFIG$output_model))
cat(sprintf("  Features: %s\n", paste(best_result$features, collapse=", ")))
cat("\n")

cat(strrep("=", 78), "\n")
cat("✓ MODEL TRAINING COMPLETE!\n")
cat(strrep("=", 78), "\n\n")

cat("Next step:\n")
cat("  → Run: Rscript script/evaluate_improved_model.R\n\n")
