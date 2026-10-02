#!/usr/bin/env bash
set -euo pipefail

SLURM_JSON=${1:-slurm.json}
USER_JSON=${2:-user.json}
PARTITION=${3:-}

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
[[ -f "$SLURM_JSON" ]] || { echo "ERROR: Slurm JSON not found: $SLURM_JSON" >&2; exit 1; }
[[ -f "$USER_JSON" ]] || { echo "ERROR: user JSON not found: $USER_JSON" >&2; exit 1; }

MIN_WALLTIME="00:01:00"

yaml_quote() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

if [[ -z "${OPTIONS_WORKER:-}" ]]; then
    if [[ -n "$PARTITION" ]]; then
        jq -e --arg partition "$PARTITION" '.partitions | has($partition)' "$SLURM_JSON" >/dev/null || {
            echo "ERROR: partition not found: $PARTITION" >&2
            exit 1
        }

        PARTITIONS=("$PARTITION")
    else
        mapfile -t PARTITIONS < <(jq -r '.partitions | keys[]' "$SLURM_JSON")

        if [[ ${#PARTITIONS[@]} -eq 0 ]]; then
            echo "ERROR: no partitions found in $SLURM_JSON" >&2
            exit 1
        fi
    fi

    printf '# Slurm job options generated from the partition policy and user associations.\n'
    printf '#\n'
    printf '# The optional partition argument only filters which partitions are emitted.\n'
    printf '# The YAML structure is identical whether one or all partitions are selected.\n'
    printf '#\n'
    printf 'partitions:\n'

    FIRST=true

    for PARTITION_NAME in "${PARTITIONS[@]}"; do
        if [[ "$FIRST" == false ]]; then
            printf '\n'
        fi

        FIRST=false

        printf '  # Partition: %s\n' "$PARTITION_NAME"
        printf '  '
        yaml_quote "$PARTITION_NAME"
        printf ':\n'

        OPTIONS_WORKER=1 "$0" "$SLURM_JSON" "$USER_JSON" "$PARTITION_NAME" | awk '
            /^partition: / {
                found_partition = 1
                next
            }
            found_partition {
                print "    " $0
            }
        '
    done

    exit 0
fi

[[ -n "$PARTITION" ]] || {
    echo "ERROR: internal worker requires a partition" >&2
    exit 1
}

min_numeric() {
    local a=$1
    local b=$2

    if (( a < b )); then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

max_numeric() {
    local a=$1
    local b=$2

    if (( a > b )); then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

parse_slurm_time() {
    local value=${1:-}
    local days hours minutes seconds

    [[ -z "$value" ]] && return 1
    [[ "$value" == "UNLIMITED" || "$value" == "NONE" ]] && return 1

    if [[ "$value" =~ ^([0-9]+)-([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
        days=${BASH_REMATCH[1]}
        hours=${BASH_REMATCH[2]}
        minutes=${BASH_REMATCH[3]}
        seconds=${BASH_REMATCH[4]}
        printf '%d\n' $((days * 86400 + 10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
        return 0
    fi

    if [[ "$value" =~ ^([0-9]{1,3}):([0-9]{2}):([0-9]{2})$ ]]; then
        hours=${BASH_REMATCH[1]}
        minutes=${BASH_REMATCH[2]}
        seconds=${BASH_REMATCH[3]}
        printf '%d\n' $((10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
        return 0
    fi

    return 1
}

format_slurm_time() {
    local seconds=$1
    local days hours minutes secs

    days=$((seconds / 86400))
    seconds=$((seconds % 86400))
    hours=$((seconds / 3600))
    seconds=$((seconds % 3600))
    minutes=$((seconds / 60))
    secs=$((seconds % 60))

    if (( days > 0 )); then
        printf '%d-%02d:%02d:%02d' "$days" "$hours" "$minutes" "$secs"
    else
        printf '%02d:%02d:%02d' "$hours" "$minutes" "$secs"
    fi
}

calculate_nodes_for_cpus() {
    local cpus=$1
    local effective_per_node=$2

    [[ "$cpus" =~ ^[0-9]+$ ]] || {
        printf '1\n'
        return
    }

    [[ "$effective_per_node" =~ ^[0-9]+$ ]] || {
        printf '1\n'
        return
    }

    (( effective_per_node > 0 )) || {
        printf '1\n'
        return
    }

    printf '%d\n' $(( (cpus + effective_per_node - 1) / effective_per_node ))
}

calculate_effective_cpus_per_node() {
    local result=""

    if [[ -n "$CORES_PER_NODE" && "$CORES_PER_NODE" =~ ^[0-9]+$ ]]; then
        result=$CORES_PER_NODE
    fi

    if [[ -n "$PARTITION_MAX_CPUS_PER_NODE" && "$PARTITION_MAX_CPUS_PER_NODE" =~ ^[0-9]+$ ]]; then
        if [[ -z "$result" ]]; then
            result=$PARTITION_MAX_CPUS_PER_NODE
        else
            result=$(min_numeric "$result" "$PARTITION_MAX_CPUS_PER_NODE")
        fi
    fi

    printf '%s\n' "$result"
}

calculate_max_cpus() {
    local max_nodes=$1
    local qos_max_cpu=$2
    local result=""

    if [[ -n "$qos_max_cpu" && "$qos_max_cpu" =~ ^[0-9]+$ ]]; then
        result=$qos_max_cpu
    fi

    if [[ -n "$EFFECTIVE_CPUS_PER_NODE" && "$EFFECTIVE_CPUS_PER_NODE" =~ ^[0-9]+$ ]]; then
        local hardware_limit=$((max_nodes * EFFECTIVE_CPUS_PER_NODE))

        if [[ -z "$result" ]]; then
            result=$hardware_limit
        else
            result=$(min_numeric "$result" "$hardware_limit")
        fi
    fi

    printf '%s\n' "$result"
}

calculate_max_walltime() {
    local qos_time=$1
    local partition_time=$2
    local qos_seconds partition_seconds

    if [[ -z "$qos_time" && -z "$partition_time" ]]; then
        return 0
    fi

    if [[ -z "$qos_time" ]]; then
        printf '%s\n' "$partition_time"
        return
    fi

    if [[ -z "$partition_time" ]]; then
        printf '%s\n' "$qos_time"
        return
    fi

    qos_seconds=$(parse_slurm_time "$qos_time" || true)
    partition_seconds=$(parse_slurm_time "$partition_time" || true)

    if [[ -z "$qos_seconds" ]]; then
        printf '%s\n' "$partition_time"
        return
    fi

    if [[ -z "$partition_seconds" ]]; then
        printf '%s\n' "$qos_time"
        return
    fi

    if (( qos_seconds < partition_seconds )); then
        format_slurm_time "$qos_seconds"
    else
        format_slurm_time "$partition_seconds"
    fi
}

calculate_cpus_per_task_layout() {
    local requested_cpus=$1
    local max_nodes=$2
    local min_nodes=$3
    local max_cpus_per_node=$4
    local mode=$5

    local effective_per_node
    local candidate_nodes
    local candidate_cpt
    local candidate_allocated
    local best_cpt=0
    local best_nodes=0
    local best_tasks=0
    local best_allocated=0

    CPU_TASK_NODES=""
    CPU_TASK_NTASKS=""
    CPU_TASK_CPUS_PER_TASK=""
    CPU_TASK_TOTAL_CPUS=""

    [[ "$requested_cpus" =~ ^[0-9]+$ ]] || return 0
    [[ "$max_nodes" =~ ^[0-9]+$ ]] || return 0
    [[ "$min_nodes" =~ ^[0-9]+$ ]] || return 0

    if [[ -n "$max_cpus_per_node" && "$max_cpus_per_node" =~ ^[0-9]+$ ]]; then
        effective_per_node=$max_cpus_per_node
    elif [[ -n "$EFFECTIVE_CPUS_PER_NODE" && "$EFFECTIVE_CPUS_PER_NODE" =~ ^[0-9]+$ ]]; then
        effective_per_node=$EFFECTIVE_CPUS_PER_NODE
    else
        return 0
    fi

    (( effective_per_node > 0 )) || return 0
    (( max_nodes >= min_nodes )) || return 0

    for ((candidate_nodes=min_nodes; candidate_nodes<=max_nodes; candidate_nodes++)); do
        if [[ "$mode" == "minimum" ]]; then
            candidate_cpt=$(( (requested_cpus + candidate_nodes - 1) / candidate_nodes ))

            (( candidate_cpt > effective_per_node )) && continue
            (( candidate_cpt > 0 )) || continue

            candidate_allocated=$((candidate_nodes * candidate_cpt))

            if (( best_allocated == 0 || candidate_allocated < best_allocated )); then
                best_allocated=$candidate_allocated
                best_nodes=$candidate_nodes
                best_tasks=$candidate_nodes
                best_cpt=$candidate_cpt
            elif (( candidate_allocated == best_allocated && candidate_nodes < best_nodes )); then
                best_nodes=$candidate_nodes
                best_tasks=$candidate_nodes
                best_cpt=$candidate_cpt
            fi
        else
            candidate_cpt=$((requested_cpus / candidate_nodes))

            (( candidate_cpt > effective_per_node )) && candidate_cpt=$effective_per_node
            (( candidate_cpt > 0 )) || continue

            candidate_allocated=$((candidate_nodes * candidate_cpt))

            (( candidate_allocated > requested_cpus )) && continue

            if (( candidate_allocated > best_allocated )); then
                best_allocated=$candidate_allocated
                best_nodes=$candidate_nodes
                best_tasks=$candidate_nodes
                best_cpt=$candidate_cpt
            elif (( candidate_allocated == best_allocated && candidate_nodes < best_nodes )); then
                best_nodes=$candidate_nodes
                best_tasks=$candidate_nodes
                best_cpt=$candidate_cpt
            fi
        fi
    done

    (( best_allocated > 0 )) || return 0

    CPU_TASK_NODES=$best_nodes
    CPU_TASK_NTASKS=$best_tasks
    CPU_TASK_CPUS_PER_TASK=$best_cpt
    CPU_TASK_TOTAL_CPUS=$best_allocated
}

calculate_gpu_layout() {
    local requested_gpu=$1
    local max_nodes=$2
    local min_nodes=$3
    local mode=$4

    GPU_LAYOUT_NODES=""
    GPU_LAYOUT_PER_NODE=""
    GPU_LAYOUT_TOTAL=""

    [[ "$GPU_PER_NODE" =~ ^[0-9]+$ ]] || return 0
    (( GPU_PER_NODE > 0 )) || return 0
    [[ "$max_nodes" =~ ^[0-9]+$ ]] || return 0
    [[ "$min_nodes" =~ ^[0-9]+$ ]] || return 0

    local candidate_nodes
    local candidate_gpu_per_node
    local candidate_total
    local best_nodes=0
    local best_gpu_per_node=0
    local best_total=0

    for ((candidate_nodes=min_nodes; candidate_nodes<=max_nodes; candidate_nodes++)); do
        if [[ "$mode" == "minimum" ]]; then
            candidate_gpu_per_node=$(( (requested_gpu + candidate_nodes - 1) / candidate_nodes ))

            (( candidate_gpu_per_node > GPU_PER_NODE )) && continue
            (( candidate_gpu_per_node > 0 )) || continue

            candidate_total=$((candidate_nodes * candidate_gpu_per_node))

            if (( best_total == 0 || candidate_total < best_total )); then
                best_total=$candidate_total
                best_nodes=$candidate_nodes
                best_gpu_per_node=$candidate_gpu_per_node
            elif (( candidate_total == best_total && candidate_nodes < best_nodes )); then
                best_nodes=$candidate_nodes
                best_gpu_per_node=$candidate_gpu_per_node
            fi
        else
            candidate_gpu_per_node=$GPU_PER_NODE
            candidate_total=$((candidate_nodes * candidate_gpu_per_node))

            if (( candidate_total > requested_gpu )); then
                candidate_gpu_per_node=$((requested_gpu / candidate_nodes))
                (( candidate_gpu_per_node > GPU_PER_NODE )) && candidate_gpu_per_node=$GPU_PER_NODE
                candidate_total=$((candidate_nodes * candidate_gpu_per_node))
            fi

            (( candidate_gpu_per_node > 0 )) || continue
            (( candidate_total > requested_gpu )) && continue

            if (( candidate_total > best_total )); then
                best_total=$candidate_total
                best_nodes=$candidate_nodes
                best_gpu_per_node=$candidate_gpu_per_node
            elif (( candidate_total == best_total && candidate_nodes < best_nodes )); then
                best_nodes=$candidate_nodes
                best_gpu_per_node=$candidate_gpu_per_node
            fi
        fi
    done

    (( best_total > 0 )) || return 0

    GPU_LAYOUT_NODES=$best_nodes
    GPU_LAYOUT_PER_NODE=$best_gpu_per_node
    GPU_LAYOUT_TOTAL=$best_total
}

emit_cpu_option_ntasks() {
    local partition=$1
    local account=$2
    local qos=$3
    local nodes=$4
    local cpus=$5
    local walltime=$6
    local gpu_per_node=$7
    local indent=$8

    local prefix command

    prefix=$(printf '%*s' "$indent" '')

    command="--partition=$partition --account=$account --qos=$qos --nodes=$nodes --ntasks=$cpus"

    if [[ -n "$gpu_per_node" && "$gpu_per_node" =~ ^[0-9]+$ && "$gpu_per_node" -gt 0 ]]; then
        command+=" --gres=gpu:$gpu_per_node"
    fi

    if [[ -n "$walltime" ]]; then
        command+=" --time=$walltime"
    fi

    printf '%sntasks:\n' "$prefix"
    printf '%s  # One Slurm task per allocated CPU.\n' "$prefix"
    printf '%s  nodes: %s\n' "$prefix" "$nodes"
    printf '%s  ntasks: %s\n' "$prefix" "$cpus"
    printf '%s  cpus_per_task: 1\n' "$prefix"
    printf '%s  total_cpus: %s\n' "$prefix" "$cpus"

    if [[ -n "$gpu_per_node" && "$gpu_per_node" =~ ^[0-9]+$ && "$gpu_per_node" -gt 0 ]]; then
        printf '%s  gpus_per_node: %s\n' "$prefix" "$gpu_per_node"
        printf '%s  total_gpus: %s\n' "$prefix" "$((nodes * gpu_per_node))"
    fi

    printf '%s  command: ' "$prefix"
    yaml_quote "$command"
    printf '\n'
}

emit_cpu_option_cpus_per_task() {
    local partition=$1
    local account=$2
    local qos=$3
    local requested_cpus=$4
    local min_nodes=$5
    local max_nodes=$6
    local max_cpus_per_node=$7
    local walltime=$8
    local gpu_per_node=$9
    local indent=${10}

    local prefix command

    prefix=$(printf '%*s' "$indent" '')

    calculate_cpus_per_task_layout "$requested_cpus" "$max_nodes" "$min_nodes" "$max_cpus_per_node" "$CPU_LAYOUT_MODE"

    printf '%scpus_per_task:\n' "$prefix"

    if [[ -z "$CPU_TASK_NODES" ]]; then
        printf '%s  valid: false\n' "$prefix"
        printf '%s  reason: ' "$prefix"
        yaml_quote "The requested CPU allocation cannot be represented using one uniform cpus-per-task value within the available node limits."
        printf '\n'
        return
    fi

    command="--partition=$partition --account=$account --qos=$qos --nodes=$CPU_TASK_NODES --ntasks=$CPU_TASK_NTASKS --cpus-per-task=$CPU_TASK_CPUS_PER_TASK"

    if [[ -n "$gpu_per_node" && "$gpu_per_node" =~ ^[0-9]+$ && "$gpu_per_node" -gt 0 ]]; then
        command+=" --gres=gpu:$gpu_per_node"
    fi

    if [[ -n "$walltime" ]]; then
        command+=" --time=$walltime"
    fi

    printf '%s  valid: true\n' "$prefix"
    printf '%s  nodes: %s\n' "$prefix" "$CPU_TASK_NODES"
    printf '%s  ntasks: %s\n' "$prefix" "$CPU_TASK_NTASKS"
    printf '%s  cpus_per_task: %s\n' "$prefix" "$CPU_TASK_CPUS_PER_TASK"
    printf '%s  total_cpus: %s\n' "$prefix" "$CPU_TASK_TOTAL_CPUS"

    if (( CPU_TASK_TOTAL_CPUS != requested_cpus )); then
        printf '%s  requested_cpus: %s\n' "$prefix" "$requested_cpus"
        printf '%s  note: ' "$prefix"
        if [[ "$CPU_LAYOUT_MODE" == "minimum" ]]; then
            yaml_quote "Uniform cpus-per-task cannot represent the requested CPU minimum exactly, so this uses the smallest representable allocation at or above the required minimum."
        else
            yaml_quote "Uniform cpus-per-task cannot represent the requested CPU maximum exactly, so this uses the largest representable allocation not exceeding the maximum."
        fi
        printf '\n'
    fi

    printf '%s  command: ' "$prefix"
    yaml_quote "$command"
    printf '\n'
}

emit_allocation() {
    local name=$1
    local partition=$2
    local account=$3
    local qos=$4
    local nodes=$5
    local cpus=$6
    local walltime=$7
    local min_nodes=$8
    local max_nodes=$9
    local max_cpus_per_node=${10}
    local requested_gpus=${11}
    local gpu_mode=${12}

    local gpu_nodes=""
    local gpu_per_node=""

    if [[ -n "$GPU_PER_NODE" && "$GPU_PER_NODE" =~ ^[0-9]+$ && "$GPU_PER_NODE" -gt 0 ]]; then
        calculate_gpu_layout "$requested_gpus" "$max_nodes" "$min_nodes" "$gpu_mode"

        if [[ -n "$GPU_LAYOUT_NODES" ]]; then
            gpu_nodes=$GPU_LAYOUT_NODES
            gpu_per_node=$GPU_LAYOUT_PER_NODE
        fi
    fi

    printf '    %s:\n' "$name"
    printf '      # Calculated allocation before selecting a CPU request style.\n'
    printf '      nodes: %s\n' "$nodes"
    printf '      cpus: %s\n' "$cpus"

    if [[ -n "$walltime" ]]; then
        printf '      walltime: '
        yaml_quote "$walltime"
        printf '\n'
    else
        printf '      walltime: null\n'
    fi

    if [[ -n "$GPU_PER_NODE" && "$GPU_PER_NODE" =~ ^[0-9]+$ && "$GPU_PER_NODE" -gt 0 ]]; then
        printf '      gpu:\n'

        if [[ -z "$gpu_per_node" ]]; then
            printf '        valid: false\n'
            printf '        reason: '
            yaml_quote "No uniform GPU-per-node allocation can satisfy the requested GPU constraint."
            printf '\n'
        else
            printf '        valid: true\n'
            printf '        gpus_per_node: %s\n' "$gpu_per_node"
            printf '        total_gpus: %s\n' "$((nodes * gpu_per_node))"
        fi
    fi

    printf '      cpu_options:\n'

    CPU_LAYOUT_MODE="$gpu_mode"
    emit_cpu_option_ntasks "$partition" "$account" "$qos" "$nodes" "$cpus" "$walltime" "$gpu_per_node" 8
    emit_cpu_option_cpus_per_task "$partition" "$account" "$qos" "$cpus" "$min_nodes" "$max_nodes" "$max_cpus_per_node" "$walltime" "$gpu_per_node" 8
}

DATA=$(jq -n --arg partition "$PARTITION" --slurpfile slurm "$SLURM_JSON" --slurpfile user "$USER_JSON" '
    ($slurm[0]) as $s |
    ($user[0]) as $u |
    ($s.partitions[$partition] // null) as $p |
    if $p == null then
        error("partition not found: " + $partition)
    else
        ($p.qos // {}) as $partition_qos |
        [
            ($u.accounts // [])[] as $account |
            ($account.qos // [])[] as $q |
            select($partition_qos | has($q)) |
            {
                account: $account.account,
                default_qos: ($account.default_qos // ""),
                qos: $q,
                constraints: ($partition_qos[$q].constraints // {})
            }
        ] |
        unique_by([.account, .qos]) |
        {
            partition: $partition,
            partition_constraints: ($p.partition // {}),
            hardware: ($p.hardware // {}),
            request: ($p.request // {}),
            accounts: .
        }
    end
')

PARTITION_NODE_COUNT=$(jq -r '.partition_constraints.node_count // empty' <<< "$DATA")
PARTITION_MAX_NODES=$(jq -r '.partition_constraints.max_nodes // empty' <<< "$DATA")
PARTITION_MAX_TIME=$(jq -r '.partition_constraints.max_time // empty' <<< "$DATA")
PARTITION_MAX_CPUS_PER_NODE=$(jq -r '.partition_constraints.max_cpus_per_node // empty' <<< "$DATA")
CORES_PER_NODE=$(jq -r '.hardware.cores_per_node // empty' <<< "$DATA")
GPU_PER_NODE=$(jq -r '.hardware.gpus_per_node // empty' <<< "$DATA")
CPU_GRANULARITY=$(jq -r '.request.cpu_granularity // "core"' <<< "$DATA")
WHOLE_NODE=$(jq -r '.request.whole_node.enabled // false' <<< "$DATA")

[[ "$PARTITION_NODE_COUNT" =~ ^[0-9]+$ ]] || PARTITION_NODE_COUNT=""
[[ "$PARTITION_MAX_NODES" =~ ^[0-9]+$ ]] || PARTITION_MAX_NODES=""
[[ "$PARTITION_MAX_CPUS_PER_NODE" =~ ^[0-9]+$ ]] || PARTITION_MAX_CPUS_PER_NODE=""
[[ "$CORES_PER_NODE" =~ ^[0-9]+$ ]] || CORES_PER_NODE=""
[[ "$GPU_PER_NODE" =~ ^[0-9]+$ ]] || GPU_PER_NODE=""

EFFECTIVE_CPUS_PER_NODE=$(calculate_effective_cpus_per_node)

if [[ -n "$PARTITION_NODE_COUNT" ]]; then
    if [[ -n "$PARTITION_MAX_NODES" ]]; then
        PARTITION_MAX_NODES=$(min_numeric "$PARTITION_NODE_COUNT" "$PARTITION_MAX_NODES")
    else
        PARTITION_MAX_NODES=$PARTITION_NODE_COUNT
    fi
fi

printf '# Slurm job options generated from the partition policy and user associations.\n'
printf '# Partition: %s\n' "$PARTITION"
printf '#\n'
printf '# Each account/QOS combination contains a minimum and maximum allocation.\n'
printf '#\n'
printf '# CPU request styles:\n'
printf '#   ntasks: one Slurm task per allocated CPU.\n'
printf '#   cpus_per_task: multiple nodes are allowed; the calculated layout uses\n'
printf '#                   one task per node and assigns CPUs to each task.\n'
printf '#\n'
printf '# cpus_per_task is limited by the CPUs available on one node.\n'
printf '# Minimum allocations use a minimum walltime of 1 minute.\n'
printf '#\n'

printf 'partition: '
yaml_quote "$PARTITION"
printf '\n'

printf 'policy:\n'
printf '  cpu_granularity: '
yaml_quote "$CPU_GRANULARITY"
printf '\n'
printf '  whole_node: %s\n' "$WHOLE_NODE"
printf '  minimum_walltime: '
yaml_quote "$MIN_WALLTIME"
printf '\n'

if [[ -n "$PARTITION_NODE_COUNT" ]]; then
    printf '  node_count: %s\n' "$PARTITION_NODE_COUNT"
fi

if [[ -n "$CORES_PER_NODE" ]]; then
    printf '  cores_per_node: %s\n' "$CORES_PER_NODE"
fi

if [[ -n "$GPU_PER_NODE" ]]; then
    printf '  gpus_per_node: %s\n' "$GPU_PER_NODE"
fi

if [[ -n "$EFFECTIVE_CPUS_PER_NODE" ]]; then
    printf '  effective_cpus_per_node: %s\n' "$EFFECTIVE_CPUS_PER_NODE"
fi

if [[ -n "$PARTITION_MAX_NODES" ]]; then
    printf '  effective_max_nodes: %s\n' "$PARTITION_MAX_NODES"
fi

if [[ -n "$PARTITION_MAX_CPUS_PER_NODE" ]]; then
    printf '  partition_max_cpus_per_node: %s\n' "$PARTITION_MAX_CPUS_PER_NODE"
fi

printf '\n'
printf 'options:\n'

ACCOUNT_COUNT=$(jq '.accounts | length' <<< "$DATA")

if (( ACCOUNT_COUNT == 0 )); then
    printf '  []\n'
    exit 0
fi

while IFS= read -r RECORD; do
    ACCOUNT=$(jq -r '.account' <<< "$RECORD")
    QOS=$(jq -r '.qos' <<< "$RECORD")
    DEFAULT_QOS=$(jq -r '.default_qos' <<< "$RECORD")
    CONSTRAINTS=$(jq -c '.constraints // {}' <<< "$RECORD")

    MIN_CPU=$(jq -r '.min.cpu // empty' <<< "$CONSTRAINTS")
    MIN_NODE=$(jq -r '.min.node // empty' <<< "$CONSTRAINTS")
    MAX_CPU=$(jq -r '.max.cpu // empty' <<< "$CONSTRAINTS")
    MAX_NODE=$(jq -r '.max.node // empty' <<< "$CONSTRAINTS")
    MIN_GPU=$(jq -r '.min.gpu // .min["gres/gpu"] // empty' <<< "$CONSTRAINTS")
    MAX_GPU=$(jq -r '.max.gpu // .max["gres/gpu"] // empty' <<< "$CONSTRAINTS")
    MAX_WALLTIME=$(jq -r '.time.max // empty' <<< "$CONSTRAINTS")

    [[ "$MIN_CPU" =~ ^[0-9]+$ ]] || MIN_CPU=""
    [[ "$MIN_NODE" =~ ^[0-9]+$ ]] || MIN_NODE=""
    [[ "$MAX_CPU" =~ ^[0-9]+$ ]] || MAX_CPU=""
    [[ "$MAX_NODE" =~ ^[0-9]+$ ]] || MAX_NODE=""
    [[ "$MIN_GPU" =~ ^[0-9]+$ ]] || MIN_GPU=""
    [[ "$MAX_GPU" =~ ^[0-9]+$ ]] || MAX_GPU=""

    MIN_NODES=${MIN_NODE:-1}

    if [[ -n "$EFFECTIVE_CPUS_PER_NODE" && -n "$MIN_CPU" ]]; then
        REQUIRED_NODES=$(calculate_nodes_for_cpus "$MIN_CPU" "$EFFECTIVE_CPUS_PER_NODE")

        if (( REQUIRED_NODES > MIN_NODES )); then
            MIN_NODES=$REQUIRED_NODES
        fi
    fi

    if [[ -n "$PARTITION_MAX_NODES" && "$MIN_NODES" -gt "$PARTITION_MAX_NODES" ]]; then
        continue
    fi

    if [[ -n "$MIN_CPU" ]]; then
        MIN_CPUS=$MIN_CPU
    else
        MIN_CPUS=1
    fi

    if [[ "$WHOLE_NODE" == true && -n "$EFFECTIVE_CPUS_PER_NODE" ]]; then
        MIN_CPUS=$((MIN_NODES * EFFECTIVE_CPUS_PER_NODE))
    fi

    MAX_NODES="$MAX_NODE"

    if [[ -n "$PARTITION_MAX_NODES" ]]; then
        if [[ -z "$MAX_NODES" ]]; then
            MAX_NODES=$PARTITION_MAX_NODES
        else
            MAX_NODES=$(min_numeric "$MAX_NODES" "$PARTITION_MAX_NODES")
        fi
    fi

    if [[ -z "$MAX_NODES" ]]; then
        if [[ -n "$MAX_CPU" && -n "$EFFECTIVE_CPUS_PER_NODE" ]]; then
            MAX_NODES=$(calculate_nodes_for_cpus "$MAX_CPU" "$EFFECTIVE_CPUS_PER_NODE")
        elif [[ -n "$EFFECTIVE_CPUS_PER_NODE" ]]; then
            MAX_NODES=1
        else
            MAX_NODES=1
        fi
    fi

    if (( MAX_NODES < MIN_NODES )); then
        continue
    fi

    MAX_CPUS=$(calculate_max_cpus "$MAX_NODES" "$MAX_CPU")

    if [[ -z "$MAX_CPUS" ]]; then
        MAX_CPUS=$MIN_CPUS
    fi

    if (( MAX_CPUS < MIN_CPUS )); then
        continue
    fi

    if [[ -n "$EFFECTIVE_CPUS_PER_NODE" ]]; then
        REQUIRED_NODES=$(calculate_nodes_for_cpus "$MAX_CPUS" "$EFFECTIVE_CPUS_PER_NODE")

        if (( REQUIRED_NODES > MAX_NODES )); then
            MAX_CPUS=$((MAX_NODES * EFFECTIVE_CPUS_PER_NODE))
        fi
    fi

    if [[ "$WHOLE_NODE" == true && -n "$EFFECTIVE_CPUS_PER_NODE" ]]; then
        MIN_CPUS=$((MIN_NODES * EFFECTIVE_CPUS_PER_NODE))
        MAX_CPUS=$((MAX_NODES * EFFECTIVE_CPUS_PER_NODE))

        if [[ -n "$MAX_CPU" ]]; then
            MAX_CPUS=$(min_numeric "$MAX_CPUS" "$MAX_CPU")
        fi

        if [[ -n "$PARTITION_MAX_CPUS_PER_NODE" ]]; then
            MAX_CPUS=$(min_numeric "$MAX_CPUS" "$((MAX_NODES * PARTITION_MAX_CPUS_PER_NODE))")
        fi

        if (( MAX_CPUS < MIN_CPUS )); then
            continue
        fi
    fi

    if [[ -n "$GPU_PER_NODE" && "$GPU_PER_NODE" =~ ^[0-9]+$ && "$GPU_PER_NODE" -gt 0 ]]; then
        MIN_GPUS=${MIN_GPU:-1}
        MAX_GPUS=$((MAX_NODES * GPU_PER_NODE))

        if [[ -n "$MAX_GPU" ]]; then
            MAX_GPUS=$(min_numeric "$MAX_GPUS" "$MAX_GPU")
        fi

        if (( MAX_GPUS < MIN_GPUS )); then
            continue
        fi
    else
        MIN_GPUS=""
        MAX_GPUS=""
    fi

    EFFECTIVE_MAX_WALLTIME=$(calculate_max_walltime "$MAX_WALLTIME" "$PARTITION_MAX_TIME" || true)

    printf '  - account: '
    yaml_quote "$ACCOUNT"
    printf '\n'

    printf '    qos: '
    yaml_quote "$QOS"
    printf '\n'

    if [[ "$QOS" == "$DEFAULT_QOS" ]]; then
        printf '    default_qos: true\n'
    else
        printf '    default_qos: false\n'
    fi

    printf '    # Original QOS constraints used in the calculation.\n'
    printf '    constraints: %s\n' "$CONSTRAINTS"

    emit_allocation "minimum" "$PARTITION" "$ACCOUNT" "$QOS" "$MIN_NODES" "$MIN_CPUS" "$MIN_WALLTIME" "$MIN_NODES" "$MAX_NODES" "$PARTITION_MAX_CPUS_PER_NODE" "${MIN_GPUS:-0}" "minimum"

    emit_allocation "maximum" "$PARTITION" "$ACCOUNT" "$QOS" "$MAX_NODES" "$MAX_CPUS" "$EFFECTIVE_MAX_WALLTIME" "$MIN_NODES" "$MAX_NODES" "$PARTITION_MAX_CPUS_PER_NODE" "${MAX_GPUS:-0}" "maximum"
done < <(jq -c '.accounts[]' <<< "$DATA")
