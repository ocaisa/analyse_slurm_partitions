#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Slurm configuration discovery workflow
# ============================================================================
#
# This script runs the complete discovery pipeline:
#
#   1. Collect private user/account information.
#   2. Collect the user's Slurm configuration as YAML.
#   3. Resolve the YAML into concrete srun/job options.
#   4. Run architecture detection on the available partitions.
#   5. Convert the YAML into generic JSON, keeping only partitions for which
#      architecture detection succeeded.
#   6. Run the options resolver a second time against the filtered JSON.
#
# The final files are:
#
#   slurm.json
#   options-final.yaml
#
# Intermediate files are deliberately kept:
#
#   user.json
#   slurm.yaml
#   options.yaml
#   architecture.json
#
# This makes every stage independently inspectable.
#
# Expected scripts in the current directory:
#
#   slurm-resolve-options.sh
#   slurm-user-info.sh
#   slurm-yaml2json.sh
#   architecture_collector.sh
#   get_slurm_data.sh
#
# ============================================================================

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

# User for which the Slurm configuration is being discovered.
#
# Defaults to the current Unix user.
#
# Example:
#
#   USER_NAME=eualano ./workflow.sh
#
USER_NAME=${USER_NAME:-$(id -un)}

# Optional account passed to get_slurm_data.sh.
#
# Leave empty to let get_slurm_data.sh determine the relevant accounts.
#
# Example:
#
#   ACCOUNT=d2026d04-065-users ./workflow.sh
#
ACCOUNT=${ACCOUNT:-}

# Intermediate and final filenames.
USER_JSON=${USER_JSON:-user.json}
SLURM_YAML=${SLURM_YAML:-slurm.yaml}
OPTIONS_YAML=${OPTIONS_YAML:-options.yaml}
ARCHITECTURE_JSON=${ARCHITECTURE_JSON:-architecture.json}
SLURM_JSON=${SLURM_JSON:-slurm.json}

# This is the second, filtered options file.
#
# It is deliberately separate from options.yaml so that the original
# discovery options remain available for debugging.
FINAL_OPTIONS_YAML=${FINAL_OPTIONS_YAML:-options-final.yaml}

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------

# Print a visible section header.
step() {
    printf '\n============================================================\n'
    printf '%s\n' "$1"
    printf '============================================================\n'
}

# Check that a required helper script exists and is executable.
require_script() {
    local script=$1

    if [[ ! -f "$script" ]]; then
        echo "ERROR: required script not found: $script" >&2
        exit 1
    fi

    if [[ ! -x "$script" ]]; then
        echo "ERROR: required script is not executable: $script" >&2
        echo "Run: chmod +x $script" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Check basic dependencies.
# ----------------------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 not found" >&2
    exit 1
}

command -v scontrol >/dev/null 2>&1 || {
    echo "ERROR: scontrol not found" >&2
    exit 1
}

command -v sacctmgr >/dev/null 2>&1 || {
    echo "ERROR: sacctmgr not found" >&2
    exit 1
}

command -v srun >/dev/null 2>&1 || {
    echo "ERROR: srun not found" >&2
    exit 1
}

# ----------------------------------------------------------------------------
# Check that all pipeline scripts are available.
# ----------------------------------------------------------------------------

require_script "./slurm-resolve-options.sh"
require_script "./slurm-user-info.sh"
require_script "./slurm-yaml2json.sh"
require_script "./architecture_collector.sh"
require_script "./get_slurm_data.sh"

# ----------------------------------------------------------------------------
# Stage 1: collect private user/account information.
# ----------------------------------------------------------------------------
#
# This produces user.json.
#
# It contains user-specific information such as:
#
#   - username
#   - accounts
#   - QOS available through each account
#   - default QOS information
#
# This information is needed by the options resolver but is not intended to
# become part of the generic slurm.json.
# ----------------------------------------------------------------------------

step "1/6: Collecting user/account information"

./slurm-user-info.sh "$USER_NAME" > "$USER_JSON"

echo "Created: $USER_JSON"

# ----------------------------------------------------------------------------
# Stage 2: collect the raw Slurm configuration.
# ----------------------------------------------------------------------------
#
# get_slurm_data.sh creates the YAML representation of the user's Slurm
# configuration.
#
# Its interface is:
#
#   get_slurm_data.sh USER [ACCOUNT]
#
# The YAML is kept as an intermediate file because both the initial options
# discovery and the final JSON conversion use it.
# ----------------------------------------------------------------------------

step "2/6: Collecting Slurm configuration"

if [[ -n "$ACCOUNT" ]]; then
    ./get_slurm_data.sh "$USER_NAME" "$ACCOUNT" > "$SLURM_YAML"
else
    ./get_slurm_data.sh "$USER_NAME" > "$SLURM_YAML"
fi

echo "Created: $SLURM_YAML"

# ----------------------------------------------------------------------------
# Stage 3: resolve initial job options.
# ----------------------------------------------------------------------------
#
# This first resolver pass is intentionally performed before architecture
# detection.
#
# architecture_collector.sh needs options.yaml because it uses the generated
# minimum srun allocation for each partition to run EESSI architecture
# detection.
#
# Therefore this file may contain partitions that will eventually be removed
# because architecture detection fails on them.
# ----------------------------------------------------------------------------

step "3/6: Resolving initial Slurm job options"

./slurm-resolve-options.sh "$SLURM_YAML" "$USER_JSON" > "$OPTIONS_YAML"

echo "Created: $OPTIONS_YAML"

# ----------------------------------------------------------------------------
# Stage 4: detect partition architectures.
# ----------------------------------------------------------------------------
#
# architecture_collector.sh reads options.yaml and attempts architecture
# detection for every partition that is not already present in
# architecture.json.
#
# Existing architecture entries are preserved and are not rerun.
#
# Failed partitions are omitted from architecture.json.
#
# If a cluster requires additional srun options, the caller can provide:
#
#   ARCHDETECT_SRUN_OPTIONS
#
# For example:
#
#   ARCHDETECT_SRUN_OPTIONS="--constraint=foo --job-name=eessi-archdetect"
#
# This variable is intentionally not set here.
# ----------------------------------------------------------------------------

step "4/6: Detecting partition architectures"

./architecture_collector.sh "$OPTIONS_YAML" "$ARCHITECTURE_JSON"

echo "Created/updated: $ARCHITECTURE_JSON"

# ----------------------------------------------------------------------------
# Stage 5: create the filtered generic JSON.
# ----------------------------------------------------------------------------
#
# Passing architecture.json as the third argument makes slurm-yaml2json.sh:
#
#   1. Keep only partitions present in architecture.json.
#   2. Add the corresponding architecture information to each partition.
#
# Therefore slurm.json is now the authoritative filtered/generic view of the
# Slurm configuration.
# ----------------------------------------------------------------------------

step "5/6: Creating filtered generic Slurm JSON"

./slurm-yaml2json.sh "$SLURM_YAML" "$SLURM_JSON" "$ARCHITECTURE_JSON"

echo "Created: $SLURM_JSON"

# ----------------------------------------------------------------------------
# Stage 6: resolve options again using the filtered JSON.
# ----------------------------------------------------------------------------
#
# This is the second options-resolver pass.
#
# The first pass used:
#
#   slurm.yaml + user.json
#
# The second pass uses:
#
#   slurm.json + user.json
#
# Since slurm.json has already been filtered using architecture.json, the
# resulting options-final.yaml contains only partitions that survived
# architecture detection.
#
# This is the options file that should be consumed by later stages of the
# workflow.
# ----------------------------------------------------------------------------

step "6/6: Resolving final filtered Slurm job options"

./slurm-resolve-options.sh "$SLURM_JSON" "$USER_JSON" > "$FINAL_OPTIONS_YAML"

echo "Created: $FINAL_OPTIONS_YAML"

# ----------------------------------------------------------------------------
# Done.
# ----------------------------------------------------------------------------

printf '\n============================================================\n'
printf 'Workflow completed successfully\n'
printf '============================================================\n'
printf 'User information : %s\n' "$USER_JSON"
printf 'Slurm YAML        : %s\n' "$SLURM_YAML"
printf 'Initial options   : %s\n' "$OPTIONS_YAML"
printf 'Architecture      : %s\n' "$ARCHITECTURE_JSON"
printf 'Filtered JSON     : %s\n' "$SLURM_JSON"
printf 'Final options     : %s\n' "$FINAL_OPTIONS_YAML"
printf '\n'
