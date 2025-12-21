# ==============================================================================
# Dirichlet Regression & Expected Value Calculation

# Input:
# - training_data.csv: (N, campaign_duration, target_dana, p1, p2, ..., pn)
# - bin_values.csv: (bin, value) - nilai representatif per bin
#
# Output:
# - Model Dirichlet (.rds)
# - Expected Value untuk 3 skenario
# - Visualisasi hasil
# ==============================================================================

# Install packages jika belum ada
# install.packages("DirichletReg")
# install.packages("jsonlite")
# install.packages("readr")
# install.packages("ggplot2")
# install.packages("gridExtra")

library(DirichletReg)
library(jsonlite)
library(readr)
library(ggplot2)
library(gridExtra)

# ==============================================================================
# CONFIGURATION
# ==============================================================================

CONFIG <- list(
  training_data_file = "training_data.json", 
  bin_values_file = "bin_values.json",
  model_output_file = "dirichlet_model.rds",
  results_output_file = "ev_results.csv",
  plot_output_file = "ev_visualization.png",

  n_bins = 8, 
  campaign_duration = 30, 
  target_dana = 100000000, 
  platform_fee = 0.05,  # 5%

  N_min = NULL,  
  N_avg = NULL,
  N_max = NULL,

  bin_values = NULL  
)

# 1. LOAD DATA
load_data <- function(config) {
  cat("Loading training data from:", config$training_data_file, "\n")
  if (grepl("\\.json$", config$training_data_file)) {
    training_data <- fromJSON(config$training_data_file)
    if (is.list(training_data) && !is.data.frame(training_data)) {
      training_data <- as.data.frame(training_data)
    }
  } else {
    training_data <- read_csv(config$training_data_file, show_col_types = FALSE)
  }

  cat("Loaded", nrow(training_data), "campaigns\n\n")

  if (is.null(config$bin_values)) {
    cat("Loading bin values from:", config$bin_values_file, "\n")

    if (grepl("\\.json$", config$bin_values_file)) {
      bin_data <- fromJSON(config$bin_values_file)
      if (is.list(bin_data) && "value" %in% names(bin_data)) {
        bin_values <- bin_data$value
      } else if (is.data.frame(bin_data) && "value" %in% colnames(bin_data)) {
        bin_values <- bin_data$value
      } else if (is.numeric(bin_data)) {
        bin_values <- bin_data
      } else {
        bin_values <- as.numeric(unlist(bin_data))
      }
    } else {
      bin_data <- read_csv(config$bin_values_file, show_col_types = FALSE)
      bin_values <- bin_data$value
    }

    cat("Loaded", length(bin_values), "bin values\n\n")
  } else {
    bin_values <- config$bin_values
    cat("Using provided bin values:", bin_values, "\n\n")
  }

  return(list(
    training_data = training_data,
    bin_values = bin_values
  ))
}

# 2. PREPARE DATA FOR DIRICHLET REGRESSION
prepare_dirichlet_data <- function(training_data, n_bins) {
  predictors <- training_data[, c("N", "campaign_duration", "target_dana")]
  prob_cols <- paste0("p", 1:n_bins)
  probabilities <- training_data[, prob_cols]
  prob_matrix <- as.matrix(probabilities)
  prob_matrix <- prob_matrix / rowSums(prob_matrix)

  cat("Probability matrix dimensions:", nrow(prob_matrix), "x", ncol(prob_matrix), "\n")
  cat("Sample probabilities (first row):\n")
  print(prob_matrix[1, ])
  cat("\n")

  Y <- DR_data(prob_matrix)
  dirichlet_data <- cbind(predictors, Y)
  cat("Data prepared successfully\n\n")

  return(dirichlet_data)
}

# 3. TRAIN MODEL

train_model <- function(dirichlet_data, output_file) {
  cat("Fitting model: Y ~ N + campaign_duration + target_dana\n\n")

  model <- DirichReg(
    Y ~ N + campaign_duration + target_dana,
    data = dirichlet_data,
    model = "common"
  )

  cat("Model trained successfully!\n\n")
  cat(rep("-", 70), "\n", sep = "")
  cat("MODEL SUMMARY\n")
  cat(rep("-", 70), "\n\n", sep = "")
  print(summary(model))
  cat("\n")

  saveRDS(model, file = output_file)
  cat("Model saved to:", output_file, "\n\n")

  return(model)
}

# 4. CALCULATE N VALUES
calculate_N_values <- function(training_data, config) {
  cat(rep("=", 70), "\n", sep = "")
  cat("DETERMINING N VALUES\n")
  cat(rep("=", 70), "\n\n", sep = "")

  if (is.null(config$N_min)) {
    N_min <- as.integer(min(training_data$N))
    cat("N_min (auto-calculated):", N_min, "\n")
  } else {
    N_min <- config$N_min
    cat("N_min (from config):", N_min, "\n")
  }

  if (is.null(config$N_avg)) {
    N_avg <- as.integer(mean(training_data$N))
    cat("N_avg (auto-calculated):", N_avg, "\n")
  } else {
    N_avg <- config$N_avg
    cat("N_avg (from config):", N_avg, "\n")
  }

  if (is.null(config$N_max)) {
    N_max <- as.integer(max(training_data$N))
    cat("N_max (auto-calculated):", N_max, "\n")
  } else {
    N_max <- config$N_max
    cat("N_max (from config):", N_max, "\n")
  }

  cat("\n")

  return(list(
    min = N_min,
    avg = N_avg,
    max = N_max
  ))
}

# 5. INFERENCE & CALCULATE EXPECTED VALUE
calculate_ev <- function(model, N_values, bin_values, config) {
  cat(rep("=", 70), "\n", sep = "")
  cat("CALCULATING EXPECTED VALUE\n")
  cat(rep("=", 70), "\n\n", sep = "")

  cat("Campaign Parameters:\n")
  cat("  Duration:", config$campaign_duration, "days\n")
  cat("  Target Dana: Rp", format(config$target_dana, big.mark = ",", scientific = FALSE), "\n")
  cat("  Platform Fee:", config$platform_fee * 100, "%\n\n")

  cat("Bin Values:\n")
  for (i in 1:length(bin_values)) {
    cat(sprintf("  v%d = Rp%s\n", i, format(bin_values[i], big.mark = ",", scientific = FALSE)))
  }
  cat("\n")

  results <- data.frame()

  scenarios <- c("min", "avg", "max")

  for (scenario in scenarios) {
    N <- N_values[[scenario]]

    cat(rep("-", 70), "\n", sep = "")
    cat("SCENARIO:", toupper(scenario), "(N =", N, ")\n")
    cat(rep("-", 70), "\n\n", sep = "")

    new_data <- data.frame(
      N = N,
      campaign_duration = config$campaign_duration,
      target_dana = config$target_dana
    )

    predictions <- predict(model, newdata = new_data)
    if (is.matrix(predictions)) {
      probs <- as.vector(predictions[1, ])
    } else {
      probs <- predictions
    }

    cat("Predicted Probabilities:\n")
    for (i in 1:length(probs)) {
      cat(sprintf("  p%d = %.4f (%.2f%%)\n", i, probs[i], probs[i] * 100))
    }
    cat("\n")

    # Calculate expected donation per donor
    expected_per_donor <- sum(probs * bin_values)
    cat("Expected donation per donor: Rp", format(expected_per_donor, big.mark = ",", scientific = FALSE), "\n")

    # Calculate EV before fee
    ev_before_fee <- N * expected_per_donor
    cat("EV before platform fee: Rp", format(ev_before_fee, big.mark = ",", scientific = FALSE), "\n")

    # Calculate platform fee
    fee_amount <- ev_before_fee * config$platform_fee
    cat("Platform fee (", config$platform_fee * 100, "%): -Rp", format(fee_amount, big.mark = ",", scientific = FALSE), "\n", sep = "")

    # Calculate EV after fee
    ev_after_fee <- ev_before_fee * (1 - config$platform_fee)
    cat("EV after platform fee: Rp", format(ev_after_fee, big.mark = ",", scientific = FALSE), "\n\n")

    # Store results
    result_row <- data.frame(
      scenario = scenario,
      N = N,
      expected_per_donor = expected_per_donor,
      ev_before_fee = ev_before_fee,
      platform_fee = fee_amount,
      ev_after_fee = ev_after_fee
    )

    # Add probabilities
    for (i in 1:length(probs)) {
      result_row[[paste0("p", i)]] <- probs[i]
    }

    results <- rbind(results, result_row)
  }

  return(results)
}

# 6. VISUALIZE RESULTS
visualize_results <- function(results, bin_values, config) {
  cat(rep("=", 70), "\n", sep = "")
  cat("CREATING VISUALIZATIONS\n")
  cat(rep("=", 70), "\n\n", sep = "")

  results$scenario_label <- factor(
    results$scenario,
    levels = c("min", "avg", "max"),
    labels = c("Minimum", "Average", "Maximum")
  )

  # Plot 1: EV Comparison
  p1 <- ggplot(results, aes(x = scenario_label)) +
    geom_col(aes(y = ev_before_fee, fill = "Before Fee"), alpha = 0.7, position = "dodge", width = 0.4) +
    geom_col(aes(y = ev_after_fee, fill = "After Fee"), alpha = 0.7, position = position_nudge(x = 0.4), width = 0.4) +
    geom_hline(yintercept = config$target_dana, linetype = "dashed", color = "red", size = 1) +
    geom_text(aes(x = 1.5, y = config$target_dana, label = "Target Dana"),
              vjust = -0.5, color = "red", size = 3.5) +
    scale_fill_manual(values = c("Before Fee" = "skyblue", "After Fee" = "coral")) +
    scale_y_continuous(labels = scales::comma) +
    labs(
      title = "Expected Value Comparison",
      subtitle = paste("Campaign:", config$campaign_duration, "days | Target: Rp",
                      format(config$target_dana, big.mark = ",", scientific = FALSE)),
      x = "Scenario",
      y = "Expected Value (Rupiah)",
      fill = ""
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      legend.position = "top"
    )

  # Plot 2: Probability Distribution
  n_bins <- length(bin_values)
  prob_cols <- paste0("p", 1:n_bins)

  prob_data <- data.frame()
  for (i in 1:nrow(results)) {
    for (j in 1:n_bins) {
      prob_data <- rbind(prob_data, data.frame(
        scenario = results$scenario_label[i],
        bin = paste0("Bin ", j),
        probability = results[[prob_cols[j]]][i]
      ))
    }
  }

  p2 <- ggplot(prob_data, aes(x = bin, y = probability, color = scenario, group = scenario)) +
    geom_line(size = 1.2) +
    geom_point(size = 3) +
    scale_color_manual(values = c("Minimum" = "#E69F00", "Average" = "#56B4E9", "Maximum" = "#009E73")) +
    labs(
      title = "Predicted Probability Distributions",
      subtitle = "Distribution of donors across donation bins",
      x = "Donation Bin",
      y = "Probability",
      color = "Scenario"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      legend.position = "top"
    )

  # Plot 3: N vs EV
  p3 <- ggplot(results, aes(x = N, y = ev_after_fee)) +
    geom_point(aes(color = scenario_label), size = 5, alpha = 0.7) +
    geom_line(alpha = 0.5, linetype = "dashed") +
    geom_text(aes(label = scenario_label), vjust = -1, size = 3.5) +
    scale_color_manual(values = c("Minimum" = "#E69F00", "Average" = "#56B4E9", "Maximum" = "#009E73")) +
    scale_y_continuous(labels = scales::comma) +
    scale_x_continuous(labels = scales::comma) +
    labs(
      title = "Number of Donors vs Expected Value",
      subtitle = "Impact of donor count on total expected value",
      x = "Number of Donors (N)",
      y = "Expected Value After Fee (Rupiah)",
      color = "Scenario"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      legend.position = "none"
    )

  # Plot 4: Platform Fee Impact
  p4 <- ggplot(results, aes(x = scenario_label, y = platform_fee, fill = scenario_label)) +
    geom_col(alpha = 0.7) +
    geom_text(aes(label = paste0("Rp ", format(round(platform_fee), big.mark = ","))),
              vjust = -0.5, size = 3.5) +
    scale_fill_manual(values = c("Minimum" = "#E69F00", "Average" = "#56B4E9", "Maximum" = "#009E73")) +
    scale_y_continuous(labels = scales::comma) +
    labs(
      title = "Platform Fee per Scenario",
      subtitle = paste0("Platform fee: ", config$platform_fee * 100, "% of total donations"),
      x = "Scenario",
      y = "Platform Fee (Rupiah)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      legend.position = "none"
    )

  # Combine plots
  combined_plot <- grid.arrange(p1, p2, p3, p4, ncol = 2,
                                top = textGrob("Expected Value Analysis - Tugas Besar 2 IF4041",
                                              gp = gpar(fontsize = 16, fontface = "bold")))

  # Save plot
  ggsave(config$plot_output_file, combined_plot, width = 14, height = 10, dpi = 300)
  cat("✓ Visualization saved to:", config$plot_output_file, "\n\n")

  return(combined_plot)
}

# 7. SAVE RESULTS
save_results <- function(results, output_file) {
  write_csv(results, output_file)
  cat("✓ Results saved to:", output_file, "\n\n")
}

# 8. PRINT SUMMARY
print_summary <- function(results) {
  cat("\n")
  cat(rep("=", 70), "\n", sep = "")
  cat("SUMMARY OF RESULTS\n")
  cat(rep("=", 70), "\n\n", sep = "")

  for (i in 1:nrow(results)) {
    cat(toupper(results$scenario[i]), "Scenario:\n")
    cat("  N =", results$N[i], "donors\n")
    cat("  Expected Value (after fee) = Rp", format(round(results$ev_after_fee[i]), big.mark = ",", scientific = FALSE), "\n\n")
  }

  cat(rep("=", 70), "\n", sep = "")
  cat("FINAL EXPECTED VALUES\n")
  cat(rep("=", 70), "\n", sep = "")
  cat(sprintf("%-8s: Rp %15s\n", "MINIMUM", format(round(results$ev_after_fee[1]), big.mark = ",", scientific = FALSE)))
  cat(sprintf("%-8s: Rp %15s\n", "AVERAGE", format(round(results$ev_after_fee[2]), big.mark = ",", scientific = FALSE)))
  cat(sprintf("%-8s: Rp %15s\n", "MAXIMUM", format(round(results$ev_after_fee[3]), big.mark = ",", scientific = FALSE)))
  cat(rep("=", 70), "\n\n", sep = "")
}

# 9. MAIN FUNCTION
main <- function(config = CONFIG) {
  cat("\n")
  cat(rep("=", 70), "\n", sep = "")
  cat("DIRICHLET REGRESSION & EXPECTED VALUE CALCULATION\n")
  cat("Tugas Besar 2 - Decision Analytical Thinking\n")
  cat("IF4041 - Penambangan Data\n")
  cat(rep("=", 70), "\n", sep = "")

  # 1. Load data
  data <- load_data(config)

  # 2. Prepare data for Dirichlet
  dirichlet_data <- prepare_dirichlet_data(data$training_data, config$n_bins)

  # 3. Train model
  model <- train_model(dirichlet_data, config$model_output_file)

  # 4. Calculate N values
  N_values <- calculate_N_values(data$training_data, config)

  # 5. Calculate Expected Value
  results <- calculate_ev(model, N_values, data$bin_values, config)

  # 6. Visualize
  visualize_results(results, data$bin_values, config)

  # 7. Save results
  save_results(results, config$results_output_file)

  # 8. Print summary
  print_summary(results)

  cat("All done! Check the output files for detailed results.\n\n")

  return(list(
    model = model,
    results = results
  ))
}

# ==============================================================================
# 10. RUN MAIN FUNCTION
# ==============================================================================

# output <- main()

# Atau dengan konfigurasi custom:
# custom_config <- CONFIG
# custom_config$n_bins <- 7
# custom_config$campaign_duration <- 60
# custom_config$N_min <- 300
# output <- main(custom_config)

cat("\nScript loaded successfully!\n")
cat("Run main() to execute the complete workflow.\n")
cat("Modify CONFIG at the top of the script to customize parameters.\n\n")
