#!/usr/bin/env bash
set -euo pipefail

INPUT=${1:?Usage: $0 INPUT.yaml OUTPUT.json [ARCHITECTURE.json]}
OUTPUT=${2:?Usage: $0 INPUT.yaml OUTPUT.json [ARCHITECTURE.json]}
ARCHITECTURE=${3:-}

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found" >&2; exit 1; }

if [[ -n "$ARCHITECTURE" && ! -f "$ARCHITECTURE" ]]; then
    echo "ERROR: architecture JSON not found: $ARCHITECTURE" >&2
    exit 1
fi

python3 - "$INPUT" "$OUTPUT" "$ARCHITECTURE" <<'PY'
import json
import sys

try:
    import yaml
except ImportError:
    print("ERROR: Python module PyYAML not found", file=sys.stderr)
    sys.exit(1)

input_file = sys.argv[1]
output_file = sys.argv[2]
architecture_file = sys.argv[3]

with open(input_file, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f)

if not isinstance(data, dict):
    print("ERROR: top-level YAML document must be a mapping", file=sys.stderr)
    sys.exit(1)

accounts = data.get("accounts", {})

if not isinstance(accounts, dict):
    print("ERROR: 'accounts' must be a mapping", file=sys.stderr)
    sys.exit(1)

architecture_partitions = None

if architecture_file:
    with open(architecture_file, "r", encoding="utf-8") as f:
        architecture_data = json.load(f)

    if not isinstance(architecture_data, dict):
        print("ERROR: architecture JSON must contain an object", file=sys.stderr)
        sys.exit(1)

    architecture_partitions = architecture_data.get("partitions")

    if not isinstance(architecture_partitions, dict):
        print("ERROR: architecture JSON must contain a 'partitions' mapping", file=sys.stderr)
        sys.exit(1)

partitions = {}

for account_name, account_data in accounts.items():
    if not isinstance(account_data, dict):
        continue

    account_partitions = account_data.get("partitions", {})

    if not isinstance(account_partitions, dict):
        continue

    for partition_name, partition_data in account_partitions.items():
        if not isinstance(partition_data, dict):
            continue

        if architecture_partitions is not None and partition_name not in architecture_partitions:
            continue

        destination = partitions.setdefault(partition_name, {})

        qos = partition_data.get("qos", {})

        if isinstance(qos, dict):
            destination.setdefault("qos", {})

            for qos_name, qos_data in qos.items():
                if qos_name not in destination["qos"]:
                    destination["qos"][qos_name] = qos_data

        for field in ("hardware", "request", "partition"):
            value = partition_data.get(field)

            if value is None:
                continue

            if field not in destination:
                destination[field] = value
                continue

            if destination[field] != value:
                print(
                    f"ERROR: conflicting '{field}' data for partition "
                    f"'{partition_name}' while processing account "
                    f"'{account_name}'",
                    file=sys.stderr,
                )
                print(
                    f"Existing: {json.dumps(destination[field], sort_keys=True)}",
                    file=sys.stderr,
                )
                print(
                    f"New:      {json.dumps(value, sort_keys=True)}",
                    file=sys.stderr,
                )
                sys.exit(1)

if architecture_partitions is not None:
    for partition_name in partitions:
        partitions[partition_name]["architecture"] = architecture_partitions[partition_name]

output = {
    "version": 1,
    "profile": "generic",
    "partitions": partitions,
}

with open(output_file, "w", encoding="utf-8") as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
