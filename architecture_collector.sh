#!/usr/bin/env bash
set -euo pipefail

OPTIONS_YAML=${1:-options.yaml}
OUTPUT_JSON=${2:-architecture.json}

ARCHDETECT_SRUN_OPTIONS=${ARCHDETECT_SRUN_OPTIONS:-}

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }
command -v srun >/dev/null 2>&1 || { echo "ERROR: srun not found" >&2; exit 1; }
[[ -f "$OPTIONS_YAML" ]] || { echo "ERROR: options YAML not found: $OPTIONS_YAML" >&2; exit 1; }

TMPDIR_LOCAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

COMMANDS_TSV="$TMPDIR_LOCAL/commands.tsv"
RESULTS_TSV="$TMPDIR_LOCAL/results.tsv"
FAILURES_TSV="$TMPDIR_LOCAL/failures.tsv"
SKIPPED_TSV="$TMPDIR_LOCAL/skipped.tsv"

: > "$RESULTS_TSV"
: > "$FAILURES_TSV"
: > "$SKIPPED_TSV"

python3 - "$OPTIONS_YAML" "$OUTPUT_JSON" "$COMMANDS_TSV" "$SKIPPED_TSV" <<'PY'
import json
import os
import sys
import yaml

options_path = sys.argv[1]
architecture_path = sys.argv[2]
commands_path = sys.argv[3]
skipped_path = sys.argv[4]

try:
    with open(options_path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
except Exception as exc:
    print(f"ERROR: failed to read YAML: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print("ERROR: options YAML must contain a mapping at the top level", file=sys.stderr)
    sys.exit(1)

partitions = data.get("partitions")

if not isinstance(partitions, dict) or not partitions:
    print("ERROR: options YAML does not contain any partitions", file=sys.stderr)
    sys.exit(1)

existing = {}

if os.path.exists(architecture_path):
    try:
        with open(architecture_path, "r", encoding="utf-8") as fh:
            existing = json.load(fh)
    except Exception as exc:
        print(f"ERROR: failed to read existing architecture JSON: {exc}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(existing, dict):
        print("ERROR: existing architecture JSON must contain an object", file=sys.stderr)
        sys.exit(1)

    existing_partitions = existing.get("partitions", {})

    if not isinstance(existing_partitions, dict):
        print("ERROR: existing architecture JSON has invalid 'partitions'", file=sys.stderr)
        sys.exit(1)
else:
    existing_partitions = {}

with open(commands_path, "w", encoding="utf-8") as commands, open(skipped_path, "w", encoding="utf-8") as skipped:
    for partition_name, partition_data in partitions.items():
        if partition_name in existing_partitions:
            skipped.write(f"{partition_name}\n")
            continue

        if not isinstance(partition_data, dict):
            print(f"ERROR: partition {partition_name!r} is not a mapping", file=sys.stderr)
            sys.exit(1)

        options = partition_data.get("options")

        if not isinstance(options, list):
            print(f"ERROR: partition {partition_name!r} has no options list", file=sys.stderr)
            sys.exit(1)

        minimum = None

        for option in options:
            if isinstance(option, dict) and isinstance(option.get("minimum"), dict):
                minimum = option["minimum"]
                break

        if minimum is None:
            print(f"ERROR: partition {partition_name!r} has no minimum allocation", file=sys.stderr)
            sys.exit(1)

        cpu_options = minimum.get("cpu_options")

        if not isinstance(cpu_options, dict):
            print(f"ERROR: partition {partition_name!r} minimum allocation has no cpu_options", file=sys.stderr)
            sys.exit(1)

        command = None

        ntasks = cpu_options.get("ntasks")

        if isinstance(ntasks, dict) and ntasks.get("command"):
            command = ntasks["command"]

        if command is None:
            cpus_per_task = cpu_options.get("cpus_per_task")

            if isinstance(cpus_per_task, dict) and cpus_per_task.get("valid") and cpus_per_task.get("command"):
                command = cpus_per_task["command"]

        if not command:
            print(f"ERROR: partition {partition_name!r} has no usable CPU request command", file=sys.stderr)
            sys.exit(1)

        commands.write(f"{partition_name}\t{command}\n")
PY

TOTAL_PARTITIONS=$(wc -l < "$COMMANDS_TSV")
SKIPPED_PARTITIONS=$(wc -l < "$SKIPPED_TSV")
FAILED_PARTITIONS=0
SUCCESSFUL_PARTITIONS=0

if [[ -f "$OUTPUT_JSON" ]]; then
    echo "Existing architecture file found: $OUTPUT_JSON" >&2
    echo "Partitions already present will not be rerun." >&2
else
    echo "No existing architecture file found." >&2
    echo "All partitions require detection." >&2
fi

echo >&2

if (( SKIPPED_PARTITIONS > 0 )); then
    echo "Skipping existing partitions:" >&2

    while IFS= read -r PARTITION; do
        [[ -n "$PARTITION" ]] || continue
        echo "  $PARTITION" >&2
    done < "$SKIPPED_TSV"

    echo >&2
fi

if (( TOTAL_PARTITIONS > 0 )); then
    while IFS=$'\t' read -r PARTITION COMMAND; do
        [[ -n "$PARTITION" ]] || continue
        [[ -n "$COMMAND" ]] || continue

        echo "============================================================" >&2
        echo "Architecture detection: $PARTITION" >&2
        echo "Generated srun options: $COMMAND" >&2

        if [[ -n "$ARCHDETECT_SRUN_OPTIONS" ]]; then
            echo "Additional srun options: $ARCHDETECT_SRUN_OPTIONS" >&2
        fi

        echo "============================================================" >&2

        read -r -a BASE_SRUN_ARGS <<< "$COMMAND"

        EXTRA_SRUN_ARGS=()

        if [[ -n "$ARCHDETECT_SRUN_OPTIONS" ]]; then
            read -r -a EXTRA_SRUN_ARGS <<< "$ARCHDETECT_SRUN_OPTIONS"
        fi

        # EESSI architecture detection script is pure bash, safe to use any system
        EESSI_ARCHDETECT=${EESSI_ARCHDETECT:-/cvmfs/software.eessi.io/versions/2026.06/init/eessi_archdetect.sh}
        DETECTION_SCRIPT="if [[ ! -f \"$EESSI_ARCHDETECT\" ]]; then echo \"__EESSI_ERROR__EESSI architecture detection script not found: $EESSI_ARCHDETECT\" >&2; exit 100; fi; if [[ ! -x \"$EESSI_ARCHDETECT\" ]]; then echo \"__EESSI_ERROR__EESSI architecture detection script is not executable: $EESSI_ARCHDETECT\" >&2; exit 100; fi; CPU=\$(\"$EESSI_ARCHDETECT\" cpupath); CPU_STATUS=\$?; if [[ \"\$CPU_STATUS\" -ne 0 || -z \"\$CPU\" ]]; then echo \"__EESSI_ERROR__CPU architecture detection failed with exit code \$CPU_STATUS\" >&2; exit 101; fi; ACCEL=\$(\"$EESSI_ARCHDETECT\" accelpath 2>/dev/null); ACCEL_STATUS=\$?; if [[ \"\$ACCEL_STATUS\" -ne 0 ]]; then echo \"__EESSI_ERROR__accelerator architecture detection failed with exit code \$ACCEL_STATUS\" >&2; exit 102; fi; printf '__EESSI_CPU__%s\\n' \"\$CPU\"; printf '__EESSI_ACCEL__%s\\n' \"\$ACCEL\""
        
        set +e
        OUTPUT=$(srun "${BASE_SRUN_ARGS[@]}" "${EXTRA_SRUN_ARGS[@]}" bash -lc "$DETECTION_SCRIPT" 2>&1)
        SRUN_STATUS=$?
        set -e

        if (( SRUN_STATUS != 0 )); then
            FAILED_PARTITIONS=$((FAILED_PARTITIONS + 1))

            printf '%s\t%s\t%s\n' "$PARTITION" "$SRUN_STATUS" "$OUTPUT" >> "$FAILURES_TSV"

            echo "ERROR: architecture detection failed for partition: $PARTITION" >&2
            echo "ERROR: srun exit code: $SRUN_STATUS" >&2
            echo "ERROR: srun output:" >&2
            printf '%s\n' "$OUTPUT" >&2
            echo >&2

            continue
        fi

        CPU=$(printf '%s\n' "$OUTPUT" | sed -n 's/^__EESSI_CPU__//p' | tail -n 1)
        ACCELERATOR=$(printf '%s\n' "$OUTPUT" | sed -n 's/^__EESSI_ACCEL__//p' | tail -n 1)

        if [[ -z "$CPU" ]]; then
            FAILED_PARTITIONS=$((FAILED_PARTITIONS + 1))

            printf '%s\t%s\t%s\n' "$PARTITION" "architecture-detection" "$OUTPUT" >> "$FAILURES_TSV"

            echo "ERROR: CPU architecture detection returned no result for partition: $PARTITION" >&2
            echo "ERROR: command completed but produced no CPU architecture." >&2
            echo "ERROR: output:" >&2
            printf '%s\n' "$OUTPUT" >&2
            echo >&2

            continue
        fi

        if [[ -z "$ACCELERATOR" || "$ACCELERATOR" == "none" || "$ACCELERATOR" == "unknown" ]]; then
            ACCELERATOR=""
        fi

        printf '%s\t%s\t%s\n' "$PARTITION" "$CPU" "$ACCELERATOR" >> "$RESULTS_TSV"

        SUCCESSFUL_PARTITIONS=$((SUCCESSFUL_PARTITIONS + 1))

        echo "SUCCESS: $PARTITION" >&2
        echo "  CPU: $CPU" >&2

        if [[ -n "$ACCELERATOR" ]]; then
            echo "  accelerator: $ACCELERATOR" >&2
        else
            echo "  accelerator: none" >&2
        fi

        echo >&2
    done < "$COMMANDS_TSV"
fi

python3 - "$OUTPUT_JSON" "$RESULTS_TSV" <<'PY'
import json
import os
import sys

architecture_path = sys.argv[1]
results_path = sys.argv[2]

if os.path.exists(architecture_path):
    with open(architecture_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    if not isinstance(data, dict):
        raise SystemExit("ERROR: existing architecture JSON must contain an object")

    if not isinstance(data.get("partitions", {}), dict):
        raise SystemExit("ERROR: existing architecture JSON has invalid 'partitions'")
else:
    data = {
        "version": 1,
        "partitions": {}
    }

data.setdefault("version", 1)
data.setdefault("partitions", {})

with open(results_path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")

        if not line:
            continue

        fields = line.split("\t", 2)

        if len(fields) != 3:
            raise SystemExit(f"ERROR: malformed detection result: {line!r}")

        partition, cpu, accelerator = fields

        if partition in data["partitions"]:
            continue

        data["partitions"][partition] = {
            "cpu": cpu,
            "accelerator": accelerator if accelerator else None
        }

temporary_path = architecture_path + ".tmp"

with open(temporary_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")

os.replace(temporary_path, architecture_path)
PY

echo "============================================================" >&2
echo "Architecture detection summary" >&2
echo "============================================================" >&2
echo "New partitions processed: $((TOTAL_PARTITIONS + SUCCESSFUL_PARTITIONS + FAILED_PARTITIONS - TOTAL_PARTITIONS))" >&2
echo "Successful this run:     $SUCCESSFUL_PARTITIONS" >&2
echo "Failed this run:         $FAILED_PARTITIONS" >&2
echo "Already present/skipped: $SKIPPED_PARTITIONS" >&2
echo "Architecture JSON:       $OUTPUT_JSON" >&2

if (( FAILED_PARTITIONS > 0 )); then
    echo >&2
    echo "WARNING: some partitions could not be detected." >&2
    echo "They remain absent from $OUTPUT_JSON and can be retried on the next run." >&2
fi

echo "============================================================" >&2
