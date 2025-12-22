#!/usr/bin/env python3
"""
Data Cleaning: Remove Outliers and Invalid Campaigns
Removes:
1. 2 extreme outliers (target > 1 Trillion)
2. 19 campaigns with Duration = 0
Result: 80 → 59 clean campaigns
"""

import pandas as pd
import json
from pathlib import Path

print("=" * 80)
print("DATA CLEANING: REMOVE OUTLIERS")
print("=" * 80)
print()

# Configuration
INPUT_FILE = Path('data-preparation/data_preparation_result_80.csv')
OUTPUT_FILE = Path('data-preparation/data_preparation_clean.csv')
REPORT_FILE = Path('data-preparation/outliers_removed.json')

# Thresholds
MAX_TARGET = 1_000_000_000_000  # 1 trillion Rp max (above = error)
MIN_DURATION = 1  # Must be at least 1 day

# Load data
print(f"Loading: {INPUT_FILE}")
df = pd.read_csv(INPUT_FILE)
print(f"✓ Loaded {len(df)} campaigns")
print()

# Normalize column names
df.columns = df.columns.str.lower().str.strip()

# Identify outliers
outliers_removed = []
reasons = []

print("IDENTIFYING OUTLIERS:")
print("-" * 80)

# 1. Target outliers (>1T)
target_outliers = df[df['target_donation'] > MAX_TARGET]
print(f"\n1. Extreme Target Outliers (> 1 Trillion):")
print(f"   Found: {len(target_outliers)} campaigns")

for idx, row in target_outliers.iterrows():
    campaign_name = row.get('campaign', f'row_{idx}')
    outliers_removed.append({
        'campaign': campaign_name,
        'reason': 'extreme_target',
        'target_donation': float(row['target_donation']),
        'n': int(row['n'])
    })
    reasons.append('extreme_target')
    print(f"   - {campaign_name[:50]}")
    print(f"     Target: Rp {row['target_donation']:,.0f} (N={row['n']})")

# 2. Duration = 0 outliers
duration_outliers = df[df['current_duration'] == 0]
print(f"\n2. Zero Duration Campaigns:")
print(f"   Found: {len(duration_outliers)} campaigns")

for idx, row in duration_outliers.iterrows():
    campaign_name = row.get('campaign', f'row_{idx}')
    # Skip if already in target outliers
    if idx not in target_outliers.index:
        outliers_removed.append({
            'campaign': campaign_name,
            'reason': 'zero_duration',
            'duration': int(row['current_duration']),
            'n': int(row['n'])
        })
        reasons.append('zero_duration')

print(f"   (showing first 10)")
for i, (idx, row) in enumerate(duration_outliers.head(10).iterrows(), 1):
    campaign_name = row.get('campaign', f'row_{idx}')
    print(f"   {i}. {campaign_name[:60]}")
    print(f"      N={row['n']}, Target=Rp {row['target_donation']:,.0f}")

if len(duration_outliers) > 10:
    print(f"   ... and {len(duration_outliers) - 10} more")

print()

# Remove outliers
print("CLEANING DATA:")
print("-" * 80)

df_clean = df[
    (df['target_donation'] <= MAX_TARGET) &
    (df['current_duration'] >= MIN_DURATION)
].copy()

removed_count = len(df) - len(df_clean)

print(f"  Original campaigns:  {len(df)}")
print(f"  Removed outliers:    {removed_count}")
print(f"    - Extreme targets: {len(target_outliers)}")
print(f"    - Zero duration:   {len(duration_outliers)}")
print(f"  Clean campaigns:     {len(df_clean)}")
print()

# Statistics of clean data
print("CLEAN DATA STATISTICS:")
print("-" * 80)
print(f"  N range:        {df_clean['n'].min()} - {df_clean['n'].max()}")
print(f"  N median:       {df_clean['n'].median():.0f}")
print(f"  Duration range: {df_clean['current_duration'].min()} - {df_clean['current_duration'].max()} days")
print(f"  Duration median: {df_clean['current_duration'].median():.0f} days")
print(f"  Target range:   Rp {df_clean['target_donation'].min():,.0f} - Rp {df_clean['target_donation'].max():,.0f}")
print(f"  Target median:  Rp {df_clean['target_donation'].median():,.0f}")
print()

# Save cleaned data
df_clean.to_csv(OUTPUT_FILE, index=False)
print(f"✓ Clean data saved: {OUTPUT_FILE}")
print()

# Save report
report = {
    'total_original': len(df),
    'total_removed': removed_count,
    'total_clean': len(df_clean),
    'removal_percentage': (removed_count / len(df)) * 100,
    'removed_by_reason': {
        'extreme_target': len(target_outliers),
        'zero_duration': len([r for r in reasons if r == 'zero_duration'])
    },
    'outliers': outliers_removed
}

with open(REPORT_FILE, 'w') as f:
    json.dump(report, f, indent=2)

print(f"✓ Outlier report saved: {REPORT_FILE}")
print()

print("=" * 80)
print(f"✓ DATA CLEANING COMPLETE: {len(df)} → {len(df_clean)} campaigns")
print("=" * 80)
print()
