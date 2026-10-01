#!/usr/bin/env bash
#
# slurm-submit-schema.sh
#
# Export the Slurm submission constraints/defaults relevant to a specific
# user/account identity as YAML.
#
# Usage:
#   ./slurm-submit-schema.sh USER [ACCOUNT]
#
# Examples:
#   ./slurm-submit-schema.sh alice
#   ./slurm-submit-schema.sh alice project123
#
# The output is intended to answer:
#   "What can this identity submit, and what should a minimal sbatch request
#    look like?"
#
# Intentionally ignored:
#   - GrpTRES
#   - GrpJobs
#   - GrpSubmitJobs
#   - other group/account-wide aggregate limits
#   - current node availability
#
# Those are scheduling/accounting constraints rather than per-job request
# construction constraints.

set -euo pipefail

USER_NAME="${1:-}"
ACCOUNT="${2:-}"

if [[ -z "$USER_NAME" ]]; then
    echo "Usage: $0 USER [ACCOUNT]" >&2
    exit 1
fi

command -v scontrol >/dev/null 2>&1 || {
    echo "ERROR: scontrol not found" >&2
    exit 1
}

command -v sacctmgr >/dev/null 2>&1 || {
    echo "ERROR: sacctmgr not found" >&2
    exit 1
}

###############################################################################
# Helpers
###############################################################################

yaml_quote() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# Extract KEY=value from a whitespace-separated scontrol line.
# Values emitted by scontrol for the fields we care about do not contain
# unescaped whitespace.
get_field() {
    local line="$1"
    local key="$2"

    awk -v key="$key" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ ("^" key "=")) {
                    sub(("^" key "="), "", $i)
                    print $i
                    exit
                }
            }
        }
    ' <<< "$line"
}

# Convert Slurm's unlimited-ish values into empty values for YAML.
is_unlimited() {
    local v="${1:-}"
    case "${v^^}" in
        ""|"NONE"|"UNLIMITED"-|"UNLIMITED"|"INFINITE")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Normalize resource names used by TRES fields.
normalize_resource() {
    local r="${1,,}"

    case "$r" in
        cpu|cpus)
            echo "cpu"
            ;;
        mem|memory)
            echo "memory"
            ;;
        gpu|gres/gpu)
            echo "gpu"
            ;;
        *)
            echo "$r"
            ;;
    esac
}

# Parse a TRES list such as:
#   cpu=32,mem=128G,gres/gpu=4
#
# Prints:
#   resource=value
#
parse_tres() {
    local tres="${1:-}"
    [[ -z "$tres" || "$tres" == "(null)" || "$tres" == "N/A" ]] && return

    IFS=',' read -ra entries <<< "$tres"

    local entry key value resource
    for entry in "${entries[@]}"; do
        [[ "$entry" != *=* ]] && continue

        key="${entry%%=*}"
        value="${entry#*=}"

        resource="$(normalize_resource "$key")"

        case "$resource" in
            cpu|memory|gpu)
                echo "${resource}=${value}"
                ;;
        esac
    done
}

# Print YAML scalar if value is meaningful.
yaml_scalar() {
    local value="${1:-}"

    if [[ -z "$value" || "$value" == "(null)" || "$value" == "N/A" ]]; then
        return
    fi

    printf '%s' "$value"
}

###############################################################################
# Cluster configuration
###############################################################################

CONFIG_LINE="$(scontrol show config -o)"

SELECT_TYPE="$(get_field "$CONFIG_LINE" "SelectType")"
SELECT_TYPE_PARAMETERS="$(get_field "$CONFIG_LINE" "SelectTypeParameters")"

GLOBAL_DEFAULT_TIME="$(get_field "$CONFIG_LINE" "DefaultTime")"
GLOBAL_DEF_MEM_PER_CPU="$(get_field "$CONFIG_LINE" "DefMemPerCPU")"
GLOBAL_DEF_MEM_PER_NODE="$(get_field "$CONFIG_LINE" "DefMemPerNode")"
GLOBAL_DEF_MEM_PER_GPU="$(get_field "$CONFIG_LINE" "DefMemPerGPU")"
GLOBAL_DEF_CPU_PER_GPU="$(get_field "$CONFIG_LINE" "DefCpuPerGPU")"
GLOBAL_JOB_DEFAULTS="$(get_field "$CONFIG_LINE" "JobDefaults")"

###############################################################################
# Determine CPU allocation granularity
###############################################################################

CPU_UNIT="core"

case "${SELECT_TYPE,,}" in
    *select/linear*)
        CPU_UNIT="core"
        ;;

    *select/cons_tres*)
        if [[ ",${SELECT_TYPE_PARAMETERS}," == *",CR_CPU,"* ]] ||
           [[ ",${SELECT_TYPE_PARAMETERS}," == *",CR_CPU_Memory,"* ]]; then
            CPU_UNIT="cpu"
        elif [[ ",${SELECT_TYPE_PARAMETERS}," == *",CR_Socket,"* ]] ||
             [[ ",${SELECT_TYPE_PARAMETERS}," == *",CR_Socket_Memory,"* ]]; then
            CPU_UNIT="socket"
        elif [[ ",${SELECT_TYPE_PARAMETERS}," == *",CR_Core,"* ]] ||
             [[ ",${SELECT_TYPE_PARAMETERS}," == *",CR_Core_Memory,"* ]]; then
            CPU_UNIT="core"
        else
            # Current Slurm defaults to CR_Core_Memory for cons_tres.
            CPU_UNIT="core"
        fi
        ;;
esac

###############################################################################
# User/account association
###############################################################################

ASSOC_ARGS=(
    "show"
    "assoc"
    "user=${USER_NAME}"
)

if [[ -n "$ACCOUNT" ]]; then
    ASSOC_ARGS+=("account=${ACCOUNT}")
fi

ASSOC_OUTPUT="$(
    sacctmgr "${ASSOC_ARGS[@]}" \
        format=Cluster,Account,User,Partition,QosLevel,DefaultQOS \
        -n -P
)"

if [[ -z "$ASSOC_OUTPUT" ]]; then
    echo "ERROR: no Slurm association found for user '${USER_NAME}'" >&2
    [[ -n "$ACCOUNT" ]] &&
        echo "       account: '${ACCOUNT}'" >&2
    exit 1
fi

###############################################################################
# Build association QOS information.
#
# ASSOC_QOS[partition] = comma-separated QOS list
# ASSOC_DEFAULT_QOS[partition] = default QOS
#
# A blank partition represents the association's general/default association.
###############################################################################

declare -A ASSOC_QOS
declare -A ASSOC_DEFAULT_QOS

while IFS='|' read -r cluster assoc_account assoc_user assoc_partition qos_level default_qos; do
    [[ -z "${cluster:-}" ]] && continue

    assoc_partition="${assoc_partition:-}"
    qos_level="${qos_level:-}"
    default_qos="${default_qos:-}"

    # sacctmgr can return "-" for unset values.
    [[ "$qos_level" == "-" ]] && qos_level=""
    [[ "$default_qos" == "-" ]] && default_qos=""

    if [[ -n "$qos_level" ]]; then
        if [[ -n "${ASSOC_QOS[$assoc_partition]:-}" ]]; then
            ASSOC_QOS["$assoc_partition"]+=",${qos_level}"
        else
            ASSOC_QOS["$assoc_partition"]="$qos_level"
        fi
    fi

    if [[ -n "$default_qos" ]]; then
        ASSOC_DEFAULT_QOS["$assoc_partition"]="$default_qos"
    fi
done <<< "$ASSOC_OUTPUT"

###############################################################################
# QOS configuration
###############################################################################

QOS_OUTPUT="$(scontrol show qos -o)"

declare -A QOS_MIN
declare -A QOS_MAX
declare -A QOS_MAX_WALL

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    qos_name="$(get_field "$line" "Name")"
    min_tres="$(get_field "$line" "MinTRES")"
    max_tres="$(get_field "$line" "MaxTRESPerJob")"
    max_wall="$(get_field "$line" "MaxWall")"

    [[ -z "$qos_name" ]] && continue

    QOS_MIN["$qos_name"]="$min_tres"
    QOS_MAX["$qos_name"]="$max_tres"
    QOS_MAX_WALL["$qos_name"]="$max_wall"
done <<< "$QOS_OUTPUT"

###############################################################################
# Partition configuration
###############################################################################

PARTITION_OUTPUT="$(scontrol -a show partition -o)"

###############################################################################
# Start YAML
###############################################################################

echo "id: $(yaml_quote "$USER_NAME")"

if [[ -n "$ACCOUNT" ]]; then
    echo "account: $(yaml_quote "$ACCOUNT")"
fi

echo "partitions:"

###############################################################################
# Process each partition
###############################################################################

while IFS= read -r partition_line; do
    [[ -z "$partition_line" ]] && continue

    PARTITION="$(get_field "$partition_line" "PartitionName")"
    [[ -z "$PARTITION" ]] && continue

    #
    # Partition configuration
    #
    PART_DEFAULT="$(get_field "$partition_line" "Default")"

    PART_MIN_NODES="$(get_field "$partition_line" "MinNodes")"
    PART_MAX_NODES="$(get_field "$partition_line" "MaxNodes")"

    PART_MAX_TIME="$(get_field "$partition_line" "MaxTime")"
    PART_DEFAULT_TIME="$(get_field "$partition_line" "DefaultTime")"

    PART_MAX_CPUS_PER_NODE="$(get_field "$partition_line" "MaxCPUsPerNode")"
    PART_MAX_CPUS_PER_SOCKET="$(get_field "$partition_line" "MaxCPUsPerSocket")"

    PART_MAX_MEM_PER_CPU="$(get_field "$partition_line" "MaxMemPerCPU")"
    PART_MAX_MEM_PER_NODE="$(get_field "$partition_line" "MaxMemPerNode")"

    PART_DEF_MEM_PER_CPU="$(get_field "$partition_line" "DefMemPerCPU")"
    PART_DEF_MEM_PER_NODE="$(get_field "$partition_line" "DefMemPerNode")"
    PART_DEF_MEM_PER_GPU="$(get_field "$partition_line" "DefMemPerGPU")"
    PART_DEF_CPU_PER_GPU="$(get_field "$partition_line" "DefCpuPerGPU")"

    PART_ALLOW_QOS="$(get_field "$partition_line" "AllowQos")"
    PART_DENY_QOS="$(get_field "$partition_line" "DenyQos")"

    PART_ALLOW_ACCOUNTS="$(get_field "$partition_line" "AllowAccounts")"
    PART_DENY_ACCOUNTS="$(get_field "$partition_line" "DenyAccounts")"

    PART_OVERSUBSCRIBE="$(get_field "$partition_line" "OverSubscribe")"
    PART_EXCLUSIVE="$(get_field "$partition_line" "Exclusive")"

    #
    # Some older Slurm versions/configurations may expose the deprecated
    # ExclusiveUser / ExclusiveTopo fields rather than Exclusive.
    #
    PART_EXCLUSIVE_USER="$(get_field "$partition_line" "ExclusiveUser")"
    PART_EXCLUSIVE_TOPO="$(get_field "$partition_line" "ExclusiveTopo")"

    #
    # Modern Slurm:
    #
    #   Exclusive=NODE -> whole node
    #   Exclusive=TOPO -> whole node / topology exclusivity
    #
    # Legacy:
    #
    #   OverSubscribe=EXCLUSIVE -> whole node
    #
    # Also account for old ExclusiveTopo=YES.
    #
    WHOLE_NODE="false"
    EXCLUSIVITY="none"

    case "${PART_EXCLUSIVE^^}" in
        NODE)
            WHOLE_NODE="true"
            EXCLUSIVITY="node"
            ;;
        TOPO)
            WHOLE_NODE="true"
            EXCLUSIVITY="topo"
            ;;
        USER)
            EXCLUSIVITY="user"
            ;;
    esac

    if [[ "${PART_OVERSUBSCRIBE^^}" == "EXCLUSIVE" ]]; then
        WHOLE_NODE="true"
        EXCLUSIVITY="node"
    fi

    if [[ "${PART_EXCLUSIVE_TOPO^^}" == "YES" ]]; then
        WHOLE_NODE="true"
        EXCLUSIVITY="topo"
    fi

    if [[ "${PART_EXCLUSIVE_USER^^}" == "YES" &&
          "$EXCLUSIVITY" == "none" ]]; then
        EXCLUSIVITY="user"
    fi

    #
    # Effective defaults: partition value overrides cluster-wide value.
    #
    EFFECTIVE_DEFAULT_TIME="$PART_DEFAULT_TIME"
    [[ -z "$EFFECTIVE_DEFAULT_TIME" ]] &&
        EFFECTIVE_DEFAULT_TIME="$GLOBAL_DEFAULT_TIME"

    EFFECTIVE_DEF_MEM_PER_CPU="$PART_DEF_MEM_PER_CPU"
    [[ -z "$EFFECTIVE_DEF_MEM_PER_CPU" ]] &&
        EFFECTIVE_DEF_MEM_PER_CPU="$GLOBAL_DEF_MEM_PER_CPU"

    EFFECTIVE_DEF_MEM_PER_NODE="$PART_DEF_MEM_PER_NODE"
    [[ -z "$EFFECTIVE_DEF_MEM_PER_NODE" ]] &&
        EFFECTIVE_DEF_MEM_PER_NODE="$GLOBAL_DEF_MEM_PER_NODE"

    EFFECTIVE_DEF_MEM_PER_GPU="$PART_DEF_MEM_PER_GPU"
    [[ -z "$EFFECTIVE_DEF_MEM_PER_GPU" ]] &&
        EFFECTIVE_DEF_MEM_PER_GPU="$GLOBAL_DEF_MEM_PER_GPU"

    EFFECTIVE_DEF_CPU_PER_GPU="$PART_DEF_CPU_PER_GPU"
    [[ -z "$EFFECTIVE_DEF_CPU_PER_GPU" ]] &&
        EFFECTIVE_DEF_CPU_PER_GPU="$GLOBAL_DEF_CPU_PER_GPU"

    #
    # Determine QOSs usable by this identity on this partition.
    #
    #
    # Association QOS can be partition-specific, otherwise fall back to the
    # general association.
    #
    ASSOC_QOS_LIST="${ASSOC_QOS[$PARTITION]:-${ASSOC_QOS[""]:-}}"

    #
    # Convert association QOS list to an associative set.
    #
    declare -A ALLOWED_QOS=()
    declare -A DENIED_QOS=()

    if [[ -n "$ASSOC_QOS_LIST" ]]; then
        IFS=',' read -ra assoc_qos_array <<< "$ASSOC_QOS_LIST"

        for q in "${assoc_qos_array[@]}"; do
            q="${q// /}"
            [[ -z "$q" || "$q" == "-" ]] && continue
            ALLOWED_QOS["$q"]=1
        done
    fi

    #
    # If AllowQos is configured, restrict to that list.
    #
    if [[ -n "$PART_ALLOW_QOS" &&
          "$PART_ALLOW_QOS" != "ALL" &&
          "$PART_ALLOW_QOS" != "(null)" ]]; then

        declare -A PART_ALLOWED_SET=()

        IFS=',' read -ra part_allowed_array <<< "$PART_ALLOW_QOS"

        for q in "${part_allowed_array[@]}"; do
            q="${q// /}"
            [[ -z "$q" ]] && continue
            PART_ALLOWED_SET["$q"]=1
        done

        for q in "${!ALLOWED_QOS[@]}"; do
            [[ -n "${PART_ALLOWED_SET[$q]:-}" ]] || unset 'ALLOWED_QOS[$q]'
        done
    fi

    #
    # Apply DenyQos.
    #
    if [[ -n "$PART_DENY_QOS" &&
          "$PART_DENY_QOS" != "NONE" &&
          "$PART_DENY_QOS" != "(null)" ]]; then

        IFS=',' read -ra part_denied_array <<< "$PART_DENY_QOS"

        for q in "${part_denied_array[@]}"; do
            q="${q// /}"
            [[ -z "$q" ]] && continue
            DENIED_QOS["$q"]=1
            unset 'ALLOWED_QOS[$q]'
        done
    fi

    #
    # If AllowQos is not specified and no association QOS was found, there is
    # no user-level QOS to emit.
    #

    ###########################################################################
    # YAML partition
    ###########################################################################

    echo "  $(yaml_quote "$PARTITION"):"

    echo "    allocation:"
    echo "      cpu:"
    echo "        unit: $(yaml_quote "$CPU_UNIT")"
    echo "      whole_node: $WHOLE_NODE"
    echo "      exclusivity: $(yaml_quote "$EXCLUSIVITY")"

    if [[ -n "$PART_OVERSUBSCRIBE" ]]; then
        echo "      oversubscribe: $(yaml_quote "$PART_OVERSUBSCRIBE")"
    fi

    ###########################################################################
    # Partition limits
    ###########################################################################

    echo "    limits:"

    emitted_partition_limit=false

    if [[ -n "$PART_MIN_NODES" &&
          "$PART_MIN_NODES" != "0" ]]; then
        echo "      nodes:"
        echo "        min: $PART_MIN_NODES"
        emitted_partition_limit=true
    fi

    if [[ -n "$PART_MAX_NODES" &&
          "$PART_MAX_NODES" != "UNLIMITED" &&
          "$PART_MAX_NODES" != "-1" ]]; then

        if [[ "$emitted_partition_limit" == false ]]; then
            echo "      nodes:"
        fi

        echo "        max: $PART_MAX_NODES"
        emitted_partition_limit=true
    fi

    if [[ -n "$PART_MAX_TIME" ]] &&
       ! is_unlimited "$PART_MAX_TIME"; then
        echo "      time:"
        echo "        max: $(yaml_quote "$PART_MAX_TIME")"
        emitted_partition_limit=true
    fi

    if [[ -n "$PART_MAX_CPUS_PER_NODE" &&
          "$PART_MAX_CPUS_PER_NODE" != "UNLIMITED" &&
          "$PART_MAX_CPUS_PER_NODE" != "-1" ]]; then
        echo "      cpu:"
        echo "        max_per_node: $PART_MAX_CPUS_PER_NODE"
        emitted_partition_limit=true
    fi

    if [[ -n "$PART_MAX_CPUS_PER_SOCKET" &&
          "$PART_MAX_CPUS_PER_SOCKET" != "UNLIMITED" &&
          "$PART_MAX_CPUS_PER_SOCKET" != "-1" ]]; then
        if [[ "$emitted_partition_limit" == false ]]; then
            echo "      cpu:"
        fi
        echo "        max_per_socket: $PART_MAX_CPUS_PER_SOCKET"
        emitted_partition_limit=true
    fi

    if [[ -n "$PART_MAX_MEM_PER_CPU" &&
          "$PART_MAX_MEM_PER_CPU" != "UNLIMITED" &&
          "$PART_MAX_MEM_PER_CPU" != "-1" ]]; then
        echo "      memory:"
        echo "        max_per_cpu: $(yaml_quote "$PART_MAX_MEM_PER_CPU")"
        emitted_partition_limit=true
    fi

    if [[ -n "$PART_MAX_MEM_PER_NODE" &&
          "$PART_MAX_MEM_PER_NODE" != "UNLIMITED" &&
          "$PART_MAX_MEM_PER_NODE" != "-1" ]]; then

        if [[ "$emitted_partition_limit" == false ]]; then
            echo "      memory:"
        fi

        echo "        max_per_node: $(yaml_quote "$PART_MAX_MEM_PER_NODE")"
        emitted_partition_limit=true
    fi

    if [[ "$emitted_partition_limit" == false ]]; then
        echo "      {}"
    fi

    ###########################################################################
    # Partition defaults
    ###########################################################################

    echo "    defaults:"

    emitted_default=false

    if [[ -n "$EFFECTIVE_DEFAULT_TIME" ]] &&
       ! is_unlimited "$EFFECTIVE_DEFAULT_TIME"; then
        echo "      time: $(yaml_quote "$EFFECTIVE_DEFAULT_TIME")"
        emitted_default=true
    fi

    if [[ -n "$EFFECTIVE_DEF_MEM_PER_CPU" ]]; then
        echo "      memory_per_cpu: $(yaml_quote "$EFFECTIVE_DEF_MEM_PER_CPU")"
        emitted_default=true
    elif [[ -n "$EFFECTIVE_DEF_MEM_PER_NODE" ]]; then
        echo "      memory_per_node: $(yaml_quote "$EFFECTIVE_DEF_MEM_PER_NODE")"
        emitted_default=true
    elif [[ -n "$EFFECTIVE_DEF_MEM_PER_GPU" ]]; then
        echo "      memory_per_gpu: $(yaml_quote "$EFFECTIVE_DEF_MEM_PER_GPU")"
        emitted_default=true
    fi

    if [[ -n "$EFFECTIVE_DEF_CPU_PER_GPU" ]]; then
        echo "      cpu_per_gpu: $(yaml_quote "$EFFECTIVE_DEF_CPU_PER_GPU")"
        emitted_default=true
    fi

    if [[ -n "$GLOBAL_JOB_DEFAULTS" ]]; then
        echo "      job_defaults: $(yaml_quote "$GLOBAL_JOB_DEFAULTS")"
        emitted_default=true
    fi

    if [[ "$emitted_default" == false ]]; then
        echo "      {}"
    fi

    ###########################################################################
    # Submission request hints
    ###########################################################################

    echo "    request:"

    #
    # Partition:
    # If this is the cluster default partition, it can normally be omitted.
    #
    if [[ "${PART_DEFAULT^^}" == "YES" ]]; then
        echo "      partition: optional"
    else
        echo "      partition: optional"
    fi

    #
    # QOS is optional because Slurm can select/use a default QOS.
    #
    echo "      qos: optional"

    #
    # Slurm can infer nodes/tasks/CPUs depending on the job request and site
    # configuration, so don't mark these as mandatory merely because the
    # partition has limits.
    #
    echo "      nodes: optional"
    echo "      tasks: optional"
    echo "      cpus_per_task: optional"
    echo "      memory: optional"
    echo "      gpus: optional"
    echo "      time: optional"

    #
    # Whole-node partitions deserve an explicit hint:
    #
    # Slurm's documentation says Exclusive=NODE gives the job all CPUs and
    # generic resources on the allocated nodes, but only as much memory as
    # requested. --mem=0 requests all node memory.
    #
    if [[ "$WHOLE_NODE" == "true" ]]; then
        echo "      whole_node:"
        echo "        enabled: true"
        echo "        memory_all: \"--mem=0\""
    fi

    ###########################################################################
    # QOS
    ###########################################################################

    if [[ ${#ALLOWED_QOS[@]} -gt 0 ]]; then
        echo "    qos:"

        #
        # Obtain partition-specific default QOS first, then general default.
        #
        DEFAULT_QOS="${ASSOC_DEFAULT_QOS[$PARTITION]:-${ASSOC_DEFAULT_QOS[""]:-}}"

        #
        # Sort QOS names for deterministic YAML.
        #
        mapfile -t SORTED_QOS < <(
            printf '%s\n' "${!ALLOWED_QOS[@]}" | sort
        )

        for QOS_NAME in "${SORTED_QOS[@]}"; do
            [[ -z "$QOS_NAME" ]] && continue

            echo "      $(yaml_quote "$QOS_NAME"):"

            if [[ "$QOS_NAME" == "$DEFAULT_QOS" ]]; then
                echo "        default: true"
            else
                echo "        default: false"
            fi

            MIN_TRES="${QOS_MIN[$QOS_NAME]:-}"
            MAX_TRES="${QOS_MAX[$QOS_NAME]:-}"
            MAX_WALL="${QOS_MAX_WALL[$QOS_NAME]:-}"

            #
            # Collect min/max resources into associative maps so we don't
            # flatten min/max into a single value.
            #
            declare -A QOS_RES_MIN=()
            declare -A QOS_RES_MAX=()

            while IFS='=' read -r resource value; do
                [[ -z "$resource" ]] && continue
                QOS_RES_MIN["$resource"]="$value"
            done < <(parse_tres "$MIN_TRES")

            while IFS='=' read -r resource value; do
                [[ -z "$resource" ]] && continue
                QOS_RES_MAX["$resource"]="$value"
            done < <(parse_tres "$MAX_TRES")

            #
            # Emit the union of resources appearing in min or max.
            #
            declare -A QOS_RES_ALL=()

            for resource in "${!QOS_RES_MIN[@]}"; do
                QOS_RES_ALL["$resource"]=1
            done

            for resource in "${!QOS_RES_MAX[@]}"; do
                QOS_RES_ALL["$resource"]=1
            done

            if [[ ${#QOS_RES_ALL[@]} -gt 0 || -n "$MAX_WALL" ]]; then
                echo "        limits:"
            else
                echo "        limits: {}"
            fi

            #
            # Stable resource order.
            #
            for resource in cpu memory gpu; do
                [[ -n "${QOS_RES_ALL[$resource]:-}" ]] || continue

                echo "          $resource:"

                if [[ -n "${QOS_RES_MIN[$resource]:-}" ]]; then
                    echo "            min: $(yaml_quote "${QOS_RES_MIN[$resource]}")"
                fi

                if [[ -n "${QOS_RES_MAX[$resource]:-}" ]]; then
                    echo "            max: $(yaml_quote "${QOS_RES_MAX[$resource]}")"
                fi
            done

            if [[ -n "$MAX_WALL" ]] &&
               ! is_unlimited "$MAX_WALL"; then
                echo "          time:"
                echo "            max: $(yaml_quote "$MAX_WALL")"
            fi
        done
    fi

done <<< "$PARTITION_OUTPUT"
