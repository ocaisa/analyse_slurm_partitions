#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Slurm configuration discovery workflow
# ============================================================================
#
# This script runs the complete discovery pipeline:
#
#   1. Collect the user's private account/QOS information.
#   2. Collect the user's Slurm configuration as YAML, unless it already exists.
#   3. Convert the YAML into generic JSON.
#   4. Resolve the generic JSON into concrete job options.
#   5. Detect CPU/accelerator architectures on the available partitions.
#   6. Convert the YAML into filtered generic JSON using the detected
#      architectures.
#   7. Resolve the filtered JSON into the final job options.
#
# The important distinction between the two JSON conversions is:
#
#   Initial conversion:
#
#       slurm.yaml -> slurm.json
#
#   This includes all discovered partitions and is used to generate the
#   srun commands needed for architecture detection.
#
#   Final conversion:
#
#       slurm.yaml + architecture.json -> slurm.json
#
#   This keeps only partitions for which architecture detection succeeded and
#   attaches the detected architecture to each partition.
#
# The final options are then generated from this filtered JSON.
#
# Final files:
#
#   slurm.json
#   options-final.yaml
#
# Intermediate files:
#
#   user.json
#   slurm.yaml
#   options.yaml
#   architecture.json
#
# Expected scripts in the current directory:
#
#   slurm_discover.sh
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
#   USER_NAME=eualano ./slurm_discover.sh
#
USER_NAME=${USER_NAME:-$(id -un)}

# Optional account passed to get_slurm_data.sh.
#
# Leave empty to let get_slurm_data.sh determine the relevant accounts.
#
# Example:
#
#   ACCOUNT=d2026d04-065-users ./slurm_discover.sh
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

step "1/7: Collecting user/account information"

./slurm-user-info.sh "$USER_NAME" > "$USER_JSON"

echo "Created: $USER_JSON"

# ----------------------------------------------------------------------------
# Stage 2: collect the raw Slurm configuration.
# ----------------------------------------------------------------------------
#
# get_slurm_data.sh creates the YAML representation of the user's Slurm
# configuration.
#
# If slurm.yaml already exists, it is reused instead of querying Slurm again.
#
# Its interface is:
#
#   get_slurm_data.sh USER [ACCOUNT]
#
# ----------------------------------------------------------------------------

step "2/7: Collecting Slurm configuration"

if [[ -f "$SLURM_YAML" ]]; then
    echo "Existing Slurm YAML found: $SLURM_YAML"
    echo "Skipping Slurm configuration discovery."
else
    if [[ -n "$ACCOUNT" ]]; then
        ./get_slurm_data.sh "$USER_NAME" "$ACCOUNT" > "$SLURM_YAML"
    else
        ./get_slurm_data.sh "$USER_NAME" > "$SLURM_YAML"
    fi

    echo "Created: $SLURM_YAML"
fi

# ----------------------------------------------------------------------------
# Stage 3: convert YAML to initial generic JSON.
# ----------------------------------------------------------------------------
#
# This conversion does NOT supply architecture.json.
#
# Therefore every partition discovered in slurm.yaml is included.
#
# This initial JSON is required because slurm-resolve-options.sh operates on
# the generic JSON representation.
# ----------------------------------------------------------------------------

step "3/7: Creating initial generic Slurm JSON"

./slurm-yaml2json.sh "$SLURM_YAML" "$SLURM_JSON"

echo "Created: $SLURM_JSON"

# ----------------------------------------------------------------------------
# Stage 4: resolve initial job options.
# ----------------------------------------------------------------------------
#
# The first options pass uses:
#
#   slurm.json
#   user.json
#
# The resulting options.yaml contains the concrete allocations needed by
# architecture_collector.sh.
#
# At this point all discovered partitions are still present.
# ----------------------------------------------------------------------------

step "4/7: Resolving initial Slurm job options"

./slurm-resolve-options.sh "$SLURM_JSON" "$USER_JSON" > "$OPTIONS_YAML"

echo "Created: $OPTIONS_YAML"

# ----------------------------------------------------------------------------
# Stage 5: detect partition architectures.
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
#   ARCHDETECT_SRUN_OPTIONS="--constraint=foo --job-name=eessi-archdetect" ./slurm_discover.sh
#
# The variable is intentionally not set here.
# ----------------------------------------------------------------------------

step "5/7: Detecting partition architectures"

./architecture_collector.sh "$OPTIONS_YAML" "$ARCHITECTURE_JSON"

echo "Created/updated: $ARCHITECTURE_JSON"

# ----------------------------------------------------------------------------
# Stage 6: create the filtered generic JSON.
# ----------------------------------------------------------------------------
#
# Passing architecture.json as the third argument makes slurm-yaml2json.sh:
#
#   1. Keep only partitions present in architecture.json.
#   2. Add the corresponding architecture information to each partition.
#
# Therefore slurm.json now becomes the authoritative filtered/generic view
# of the usable Slurm configuration.
#
# This intentionally overwrites the initial unfiltered slurm.json.
# ----------------------------------------------------------------------------

step "6/7: Creating filtered generic Slurm JSON"

./slurm-yaml2json.sh "$SLURM_YAML" "$SLURM_JSON" "$ARCHITECTURE_JSON"

echo "Updated: $SLURM_JSON"

# ----------------------------------------------------------------------------
# Stage 7: resolve final job options.
# ----------------------------------------------------------------------------
#
# The second resolver pass uses:
#
#   filtered slurm.json
#   user.json
#
# Since slurm.json has now been filtered using architecture.json, the final
# options file contains only partitions for which architecture detection
# succeeded.
#
# This is the options file that should be consumed by downstream users.
# ----------------------------------------------------------------------------

step "7/7: Resolving final filtered Slurm job options"

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
printf 'Initial JSON      : %s\n' "$SLURM_JSON"
printf 'Initial options   : %s\n' "$OPTIONS_YAML"
printf 'Architecture      : %s\n' "$ARCHITECTURE_JSON"
printf 'Filtered JSON     : %s\n' "$SLURM_JSON"
printf 'Final options     : %s\n' "$FINAL_OPTIONS_YAML"
printf '\n'
