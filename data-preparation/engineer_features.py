#!/usr/bin/env python3
"""
Feature Engineering: Add Domain-Specific Features

Adds 3 new features:
1. donation_concentration (p1 value) - High p1 correlates with high error
2. log_target_per_donor - Campaign ambition relative to donor base
3. log_duration - Normalized duration for better stability
"""

import pandas as pd
import numpy as np
from pathlib import Path

print("=" * 80)
print("FEATURE ENGINEERING: DOMAIN-SPECIFIC FEATURES")
print("=" * 80)
print()

# Configuration
INPUT_FILE = Path('data-preparation/data_preparation_clean.csv')
OUTPUT_FILE = Path('data-preparation/data_preparation_features.csv')

# Load cleaned data
print(f"Loading: {INPUT_FILE}")
df = pd.read_csv(INPUT_FILE)
print(f"✓ Loaded {len(df)} clean campaigns")
print()

# Display current columns
print("Current features:")
for col in ['n', 'current_duration', 'target_donation', 'p1', 'p2', 'p3', 'p4', 'p5']:
    if col in df.columns:
        print(f"  ✓ {col}")
print()

# ============================================================================
# FEATURE 1: Donation Concentration (p1 level)
# ============================================================================

print("FEATURE 1: Donation Concentration")
print("-" * 80)

df['donation_concentration'] = df['p1']

print(f"  Formula: donation_concentration = p1")
print(f"  Range:   {df['donation_concentration'].min():.3f} - {df['donation_concentration'].max():.3f}")
print(f"  Median:  {df['donation_concentration'].median():.3f}")
print()

print("  Business Logic:")
print("    - High p1 (>0.95): Many small donors → lower EV per donor")
print("    - Low p1 (<0.7):  More large donors → higher EV per donor")
print()

print("  Why it helps:")
print("    - High p1 campaigns currently have 524% error (systematic over-prediction)")
print("    - This feature allows model to adjust for donation concentration")
print()

# ============================================================================
# FEATURE 2: Log(Target / N) - Target per Donor Ratio
# ============================================================================

print("FEATURE 2: Log Target Per Donor")
print("-" * 80)

target_per_donor = df['target_donation'] / df['n']
df['log_target_per_donor'] = np.log1p(target_per_donor)

print(f"  Formula: log(1 + target_donation / n)")
print(f"  Range:   {df['log_target_per_donor'].min():.3f} - {df['log_target_per_donor'].max():.3f}")
print(f"  Median:  {df['log_target_per_donor'].median():.3f}")
print()

print("  Business Logic:")
print("    - High ratio: Ambitious target for small donor base")
print("    - Low ratio:  Realistic/achievable target")
print()

print("  Why it helps:")
print("    - Normalizes wide range (9M - 5B targets, 9 - 7020 donors)")
print("    - Captures campaign feasibility/ambition level")
print()

# ============================================================================
# FEATURE 3: Log(Duration) - Normalized Duration
# ============================================================================

print("FEATURE 3: Log Duration")
print("-" * 80)

df['log_duration'] = np.log1p(df['current_duration'])

print(f"  Formula: log(1 + current_duration)")
print(f"  Range:   {df['log_duration'].min():.3f} - {df['log_duration'].max():.3f}")
print(f"  Median:  {df['log_duration'].median():.3f}")
print()

print("  Business Logic:")
print("    - Longer campaigns: Different donor patterns, more stability")
print("    - Log transform: Handles skewed distribution (1-4411 days)")
print()

print("  Why it helps:")
print("    - Better numerical stability for regression")
print("    - Captures non-linear relationship between duration and donations")
print()

# ============================================================================
# VALIDATION
# ============================================================================

print("FEATURE VALIDATION:")
print("-" * 80)

new_features = ['donation_concentration', 'log_target_per_donor', 'log_duration']
all_valid = True

for feat in new_features:
    nan_count = df[feat].isna().sum()
    inf_count = np.isinf(df[feat]).sum()

    if nan_count > 0 or inf_count > 0:
        print(f"  ✗ {feat}: NaN={nan_count}, Inf={inf_count}")
        all_valid = False
    else:
        print(f"  ✓ {feat}: No NaN/Inf")

print()

if not all_valid:
    print("⚠️  WARNING: Some features have invalid values!")
    print("    Recommend: Check data before model training")
else:
    print("✓ All features valid (no NaN/Inf)")

print()

# ============================================================================
# SAVE ENGINEERED DATA
# ============================================================================

print("SAVING ENGINEERED DATA:")
print("-" * 80)

df.to_csv(OUTPUT_FILE, index=False)

print(f"✓ Saved: {OUTPUT_FILE}")
print(f"  Campaigns: {len(df)}")
print(f"  Features:  {len(df.columns)}")
print()

print("Feature Summary:")
print("  Base features (3):")
print("    - n (donors)")
print("    - current_duration (days)")
print("    - target_donation (Rupiah)")
print()
print("  New features (3):")
print("    - donation_concentration (p1 level)")
print("    - log_target_per_donor (campaign ambition)")
print("    - log_duration (normalized time)")
print()
print("  Probability features (5):")
print("    - p1, p2, p3, p4, p5 (bin distributions)")
print()

print("=" * 80)
print("✓ FEATURE ENGINEERING COMPLETE!")
print("=" * 80)
print()

print("Next step:")
print("  → Run: Rscript script/train_improved_model.R")
print()
