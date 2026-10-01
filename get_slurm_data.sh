#!/usr/bin/env bash
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    echo "Usage: $0 USER [ACCOUNT]" >&2
    exit 1
fi

USER_NAME=$1
ACCOUNT_FILTER=${2:-}

yaml_quote() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

trim() {
    local s=${1-}
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

csv_contains() {
    local needle=$1
    local csv=${2:-}
    local item

    [[ -z "$csv" || "$csv" == "NONE" ]] && return 1

    IFS=',' read -r -a _csv_items <<< "$csv"

    for item in "${_csv_items[@]}"; do
        item=$(trim "$item")
        [[ "$item" == "$needle" ]] && return 0
    done

    return 1
}

csv_to_array() {
    local csv=${1:-}
    local -n out=$2
    local item

    out=()

    [[ -z "$csv" || "$csv" == "NONE" ]] && return 0

    IFS=',' read -r -a _items <<< "$csv"

    for item in "${_items[@]}"; do
        item=$(trim "$item")
        [[ -n "$item" ]] && out+=("$item")
    done
}

partition_field() {
    local line=$1
    local wanted=$2

    awk -v wanted="$wanted" 'BEGIN{FS="[[:space:]]+"} {for(i=1;i<=NF;i++){p=index($i,"="); if(p>0 && substr($i,1,p-1)==wanted){print substr($i,p+1); exit}}}' <<< "$line"
}

config_field() {
    local config=$1
    local wanted=$2

    awk -v wanted="$wanted" 'match($0,/^[[:space:]]*([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.*)$/,m) {if(m[1]==wanted){v=m[2]; sub(/[[:space:]]+$/,"",v); print v; exit}}' <<< "$config"
}

memory_to_mib() {
    local value=${1:-}
    local number suffix

    value=$(trim "$value")

    [[ -z "$value" ]] && return 1
    [[ "$value" == "UNLIMITED" ]] && return 1
    [[ "$value" == "UNLIMITED(M)" ]] && return 1
    [[ "$value" == "NONE" ]] && return 1

    if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)([KkMmGgTtPp]([Ii][Bb])?)?$ ]]; then
        number=${BASH_REMATCH[1]}
        suffix=${BASH_REMATCH[3]:-}

        case "${suffix,,}" in
            "")
                awk -v n="$number" 'BEGIN{printf "%d\n", n}'
                ;;
            k|ki|kib)
                awk -v n="$number" 'BEGIN{printf "%d\n", n/1024}'
                ;;
            m|mi|mib)
                awk -v n="$number" 'BEGIN{printf "%d\n", n}'
                ;;
            g|gi|gib)
                awk -v n="$number" 'BEGIN{printf "%d\n", n*1024}'
                ;;
            t|ti|tib)
                awk -v n="$number" 'BEGIN{printf "%d\n", n*1024*1024}'
                ;;
            p|pi|pib)
                awk -v n="$number" 'BEGIN{printf "%d\n", n*1024*1024*1024}'
                ;;
            *)
                return 1
                ;;
        esac

        return 0
    fi

    return 1
}

get_gpu_count() {
    local gres=${1:-}
    local item name count total=0

    [[ -z "$gres" || "$gres" == "NONE" ]] && { echo 0; return; }

    IFS=',' read -r -a _gres_items <<< "$gres"

    for item in "${_gres_items[@]}"; do
        item=$(trim "$item")
        [[ -z "$item" ]] && continue

        IFS=':' read -r -a _gres_parts <<< "$item"

        name=${_gres_parts[0]}

        [[ "$name" != "gpu" ]] && continue

        count=1

        if (( ${#_gres_parts[@]} >= 2 )); then
            if [[ "${_gres_parts[1]}" =~ ^[0-9]+$ ]]; then
                count=${_gres_parts[1]}
            elif (( ${#_gres_parts[@]} >= 3 )) && [[ "${_gres_parts[2]}" =~ ^[0-9]+$ ]]; then
                count=${_gres_parts[2]}
            fi
        fi

        total=$((total + count))
    done

    echo "$total"
}

get_node_field() {
    local line=$1
    local wanted=$2

    awk -v wanted="$wanted" 'BEGIN{FS="[[:space:]]+"} {for(i=1;i<=NF;i++){p=index($i,"="); if(p>0 && substr($i,1,p-1)==wanted){print substr($i,p+1); exit}}}' <<< "$line"
}

get_node_hardware() {
    local node=$1
    local line
    local sockets cores_per_socket threads_per_core cpu_tot real_memory gres
    local cores_per_node gpus

    line=$(scontrol show node "$node" -o 2>/dev/null || true)

    [[ -z "$line" ]] && return 1

    sockets=$(get_node_field "$line" "Sockets")
    cores_per_socket=$(get_node_field "$line" "CoresPerSocket")
    threads_per_core=$(get_node_field "$line" "ThreadsPerCore")
    cpu_tot=$(get_node_field "$line" "CPUTot")
    real_memory=$(get_node_field "$line" "RealMemory")
    gres=$(get_node_field "$line" "Gres")

    [[ "$sockets" =~ ^[0-9]+$ ]] || sockets=""
    [[ "$cores_per_socket" =~ ^[0-9]+$ ]] || cores_per_socket=""
    [[ "$threads_per_core" =~ ^[0-9]+$ ]] || threads_per_core=""
    [[ "$cpu_tot" =~ ^[0-9]+$ ]] || cpu_tot=""
    [[ "$real_memory" =~ ^[0-9]+$ ]] || real_memory=""

    if [[ -n "$sockets" && -n "$cores_per_socket" ]]; then
        cores_per_node=$((sockets * cores_per_socket))
    elif [[ -n "$cpu_tot" && -n "$threads_per_core" && "$threads_per_core" -gt 0 ]]; then
        cores_per_node=$((cpu_tot / threads_per_core))
    elif [[ -n "$cpu_tot" ]]; then
        cores_per_node=$cpu_tot
    else
        cores_per_node=""
    fi

    gpus=$(get_gpu_count "$gres")

    NODE_HW_SOCKETS=$sockets
    NODE_HW_CORES_PER_SOCKET=$cores_per_socket
    NODE_HW_THREADS_PER_CORE=$threads_per_core
    NODE_HW_CORES_PER_NODE=$cores_per_node
    NODE_HW_MEMORY_MIB=$real_memory
    NODE_HW_GPUS=$gpus
}

sample_partition_hardware() {
    local nodes_expr=$1
    local expanded
    local node
    local count=0
    local have_reference=0

    HW_AVAILABLE=0
    HW_SOCKETS=""
    HW_CORES_PER_SOCKET=""
    HW_THREADS_PER_CORE=""
    HW_CORES_PER_NODE=""
    HW_MEMORY_MIB=""
    HW_GPUS=""

    [[ -z "$nodes_expr" || "$nodes_expr" == "ALL" || "$nodes_expr" == "NONE" ]] && return 0

    expanded=$(scontrol show hostnames "$nodes_expr" 2>/dev/null || true)

    [[ -z "$expanded" ]] && return 0

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue

        (( count += 1 ))

        get_node_hardware "$node" || continue

        if (( have_reference == 0 )); then
            HW_SOCKETS=$NODE_HW_SOCKETS
            HW_CORES_PER_SOCKET=$NODE_HW_CORES_PER_SOCKET
            HW_THREADS_PER_CORE=$NODE_HW_THREADS_PER_CORE
            HW_CORES_PER_NODE=$NODE_HW_CORES_PER_NODE
            HW_MEMORY_MIB=$NODE_HW_MEMORY_MIB
            HW_GPUS=$NODE_HW_GPUS
            have_reference=1
        else
            [[ "$HW_SOCKETS" == "$NODE_HW_SOCKETS" ]] || return 0
            [[ "$HW_CORES_PER_SOCKET" == "$NODE_HW_CORES_PER_SOCKET" ]] || return 0
            [[ "$HW_THREADS_PER_CORE" == "$NODE_HW_THREADS_PER_CORE" ]] || return 0
            [[ "$HW_CORES_PER_NODE" == "$NODE_HW_CORES_PER_NODE" ]] || return 0
            [[ "$HW_MEMORY_MIB" == "$NODE_HW_MEMORY_MIB" ]] || return 0
            [[ "$HW_GPUS" == "$NODE_HW_GPUS" ]] || return 0
        fi

        (( count >= 3 )) && break
    done <<< "$expanded"

    (( have_reference == 1 )) || return 0

    HW_AVAILABLE=1
}

# ---------------------------------------------------------------------------
# Validate user
# ---------------------------------------------------------------------------

if ! id "$USER_NAME" >/dev/null 2>&1; then
    echo "Unknown user: $USER_NAME" >&2
    exit 1
fi

USER_GROUPS=$(id -Gn "$USER_NAME" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Cluster configuration
# ---------------------------------------------------------------------------

CONFIG=$(scontrol show config 2>/dev/null || true)

SELECT_TYPE=$(config_field "$CONFIG" "SelectType")
SELECT_TYPE_PARAMETERS=$(config_field "$CONFIG" "SelectTypeParameters")
DEF_MEM_PER_CPU=$(config_field "$CONFIG" "DefMemPerCPU")

CPU_GRANULARITY="core"

case "${SELECT_TYPE_PARAMETERS^^}" in
    *CR_CPU_MEMORY*|*CR_CPU*)
        CPU_GRANULARITY="cpu"
        ;;
    *CR_SOCKET_MEMORY*|*CR_SOCKET*)
        CPU_GRANULARITY="socket"
        ;;
    *CR_CORE_MEMORY*|*CR_CORE*)
        CPU_GRANULARITY="core"
        ;;
    *)
        CPU_GRANULARITY="core"
        ;;
esac

# ---------------------------------------------------------------------------
# User associations
# ---------------------------------------------------------------------------

ASSOC_RAW=$(sacctmgr show assoc where user="$USER_NAME" format=Cluster,Account,User,DefaultAccount,Qos,DefaultQos -n -P 2>/dev/null || true)

declare -A ACCOUNT_EXISTS=()
declare -A ACCOUNT_QOS=()
declare -A ACCOUNT_DEFAULT_QOS=()

DEFAULT_ACCOUNT=$(sacctmgr show user "$USER_NAME" format=DefaultAccount -n -P 2>/dev/null | head -n1 | tr -d '[:space:]' || true)

while IFS='|' read -r cluster account assoc_user default_account qos default_qos; do
    [[ -z "$account" ]] && continue
    [[ -n "$assoc_user" && "$assoc_user" != "$USER_NAME" ]] && continue

    ACCOUNT_EXISTS["$account"]=1
    ACCOUNT_QOS["$account"]=${qos:-}
    ACCOUNT_DEFAULT_QOS["$account"]=${default_qos:-}

    if [[ -n "$default_account" ]]; then
        DEFAULT_ACCOUNT=$default_account
    fi
done <<< "$ASSOC_RAW"

if [[ -z "$DEFAULT_ACCOUNT" ]]; then
    DEFAULT_ACCOUNT=$(sacctmgr show user "$USER_NAME" format=DefaultAccount -n -P 2>/dev/null | awk -F'|' 'NF{print $1; exit}' | tr -d '[:space:]' || true)
fi

if [[ -n "$ACCOUNT_FILTER" ]]; then
    if [[ -z "${ACCOUNT_EXISTS[$ACCOUNT_FILTER]+x}" ]]; then
        echo "User $USER_NAME has no association with account $ACCOUNT_FILTER" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# QOS definitions
# ---------------------------------------------------------------------------

QOS_RAW=$(sacctmgr show qos format=Name,MinTRES,MaxTRESPerJob,MaxWall -n -P 2>/dev/null || true)

declare -A QOS_EXISTS=()
declare -A QOS_MIN=()
declare -A QOS_MAX=()
declare -A QOS_MAX_WALL=()

while IFS='|' read -r qos_name min_tres max_tres max_wall; do
    [[ -z "$qos_name" ]] && continue

    QOS_EXISTS["$qos_name"]=1
    QOS_MIN["$qos_name"]=${min_tres:-}
    QOS_MAX["$qos_name"]=${max_tres:-}
    QOS_MAX_WALL["$qos_name"]=${max_wall:-}
done <<< "$QOS_RAW"

# ---------------------------------------------------------------------------
# Partition definitions
# ---------------------------------------------------------------------------

PARTITIONS_RAW=$(scontrol show partition -o 2>/dev/null || true)

declare -A PARTITION_LINE=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    partition=$(partition_field "$line" "PartitionName")
    [[ -z "$partition" ]] && continue

    PARTITION_LINE["$partition"]=$line
done <<< "$PARTITIONS_RAW"

# ---------------------------------------------------------------------------
# Effective QOS for account + partition
# ---------------------------------------------------------------------------

effective_qos_for_partition() {
    local account=$1
    local line=$2
    local account_qos allow_qos deny_qos
    local q
    local -a account_qos_list=()
    local -a allow_qos_list=()
    local -a deny_qos_list=()
    local -a result=()

    account_qos=${ACCOUNT_QOS[$account]:-}

    allow_qos=$(partition_field "$line" "AllowQos")
    [[ -z "$allow_qos" ]] && allow_qos=$(partition_field "$line" "AllowQOS")

    deny_qos=$(partition_field "$line" "DenyQos")
    [[ -z "$deny_qos" ]] && deny_qos=$(partition_field "$line" "DenyQOS")

    if [[ -z "$account_qos" || "$account_qos" == "ALL" ]]; then
        for q in "${!QOS_EXISTS[@]}"; do
            account_qos_list+=("$q")
        done
    else
        csv_to_array "$account_qos" account_qos_list
    fi

    if [[ -z "$allow_qos" || "$allow_qos" == "ALL" ]]; then
        allow_qos_list=("${account_qos_list[@]}")
    else
        csv_to_array "$allow_qos" allow_qos_list
    fi

    csv_to_array "$deny_qos" deny_qos_list

    for q in "${account_qos_list[@]}"; do
        [[ -v "QOS_EXISTS[$q]" ]] || continue

        if [[ -n "$allow_qos" && "$allow_qos" != "ALL" ]] && ! csv_contains "$q" "$allow_qos"; then
            continue
        fi

        if [[ -n "$deny_qos" ]] && csv_contains "$q" "$deny_qos"; then
            continue
        fi

        result+=("$q")
    done

    if ((${#result[@]} > 0)); then
        printf '%s\n' "${result[@]}" | sort
    fi
}

# ---------------------------------------------------------------------------
# Partition account/group access
# ---------------------------------------------------------------------------

partition_account_allowed() {
    local account=$1
    local line=$2
    local allow_accounts deny_accounts allow_groups
    local group

    allow_accounts=$(partition_field "$line" "AllowAccounts")
    deny_accounts=$(partition_field "$line" "DenyAccounts")
    allow_groups=$(partition_field "$line" "AllowGroups")

    if [[ -n "$deny_accounts" && "$deny_accounts" != "NONE" && "$deny_accounts" != "ALL" ]] && csv_contains "$account" "$deny_accounts"; then
        return 1
    fi

    if [[ -n "$allow_accounts" && "$allow_accounts" != "ALL" ]]; then
        csv_contains "$account" "$allow_accounts" || return 1
    fi

    if [[ -n "$allow_groups" && "$allow_groups" != "ALL" ]]; then
        local group_allowed=1

        IFS=',' read -r -a _allowed_groups <<< "$allow_groups"

        for group in "${_allowed_groups[@]}"; do
            group=$(trim "$group")

            if [[ "$group" == "$USER_NAME" ]] || printf '%s\n' "$USER_GROUPS" | tr ' ' '\n' | grep -Fxq "$group"; then
                group_allowed=0
                break
            fi
        done

        (( group_allowed == 0 )) || return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# YAML header
# ---------------------------------------------------------------------------

printf 'id: '
yaml_quote "$USER_NAME"
printf '\n'

if [[ -n "$ACCOUNT_FILTER" ]]; then
    printf 'account: '
    yaml_quote "$ACCOUNT_FILTER"
    printf '\n'
fi

printf 'default_account: '
yaml_quote "$DEFAULT_ACCOUNT"
printf '\n'

printf 'accounts:\n'

# ---------------------------------------------------------------------------
# Emit account
# ---------------------------------------------------------------------------

emit_account() {
    local account=$1
    local account_default=false

    [[ "$account" == "$DEFAULT_ACCOUNT" ]] && account_default=true

    printf '  '
    yaml_quote "$account"
    printf ':\n'

    printf '    default: %s\n' "$account_default"
    printf '    partitions:\n'

    local partition line state
    local nodes_expr max_nodes max_time max_cpus_per_node
    local def_mem_per_node
    local oversubscribe exclusive_user exclusive_topo
    local whole_node
    local qos
    local memory_request memory_source
    local def_mem_mib def_mem_cpu_mib
    local -a effective_qos=()

    while IFS= read -r partition; do
        [[ -z "$partition" ]] && continue

        line=${PARTITION_LINE[$partition]}

        state=$(partition_field "$line" "State")

        [[ "$state" == "DOWN" || "$state" == "INACTIVE" || "$state" == "DRAIN" || "$state" == "DRAINING" ]] && continue

        partition_account_allowed "$account" "$line" || continue

        mapfile -t effective_qos < <(effective_qos_for_partition "$account" "$line")

        ((${#effective_qos[@]} > 0)) || continue

        nodes_expr=$(partition_field "$line" "Nodes")
        max_nodes=$(partition_field "$line" "MaxNodes")
        max_time=$(partition_field "$line" "MaxTime")
        max_cpus_per_node=$(partition_field "$line" "MaxCPUsPerNode")
        def_mem_per_node=$(partition_field "$line" "DefMemPerNode")
        oversubscribe=$(partition_field "$line" "OverSubscribe")
        exclusive_user=$(partition_field "$line" "ExclusiveUser")
        exclusive_topo=$(partition_field "$line" "ExclusiveTopo")

        whole_node=false

        if [[ "${oversubscribe^^}" == "EXCLUSIVE" || "${exclusive_topo^^}" == "YES" || "${exclusive_topo^^}" == "TOPO" || "${exclusive_user^^}" == "NODE" ]]; then
            whole_node=true
        fi

        # ---------------------------------------------------------------
        # Probe representative nodes.
        # ---------------------------------------------------------------

        sample_partition_hardware "$nodes_expr"

        # ---------------------------------------------------------------
        # Request memory.
        #
        # Priority:
        #
        # 1. DefMemPerNode / physical cores_per_node
        # 2. DefMemPerCPU
        #
        # RealMemory is deliberately NOT used for request calculation.
        # ---------------------------------------------------------------

        memory_request=""
        memory_source=""

        if [[ -n "$def_mem_per_node" && "$def_mem_per_node" != "UNLIMITED" && "$def_mem_per_node" != "NONE" && -n "$HW_CORES_PER_NODE" && "$HW_CORES_PER_NODE" =~ ^[0-9]+$ && "$HW_CORES_PER_NODE" -gt 0 ]]; then
            if def_mem_mib=$(memory_to_mib "$def_mem_per_node"); then
                memory_request=$((def_mem_mib / HW_CORES_PER_NODE))
                memory_source="DefMemPerNode / cores_per_node"
            fi
        fi

        if [[ -z "$memory_request" && -n "$DEF_MEM_PER_CPU" ]]; then
            if def_mem_cpu_mib=$(memory_to_mib "$DEF_MEM_PER_CPU"); then
                memory_request=$def_mem_cpu_mib
                memory_source="DefMemPerCPU"
            fi
        fi

        # ---------------------------------------------------------------
        # Partition key: emitted exactly once.
        # ---------------------------------------------------------------

        printf '      '
        yaml_quote "$partition"
        printf ':\n'

        # ---------------------------------------------------------------
        # QOS
        # ---------------------------------------------------------------

        printf '        qos:\n'

        for qos in "${effective_qos[@]}"; do
            printf '          '
            yaml_quote "$qos"
            printf ':\n'

            if [[ -n "${QOS_MIN[$qos]:-}" || -n "${QOS_MAX[$qos]:-}" || -n "${QOS_MAX_WALL[$qos]:-}" ]]; then
                printf '            constraints:\n'

                if [[ -n "${QOS_MIN[$qos]:-}" ]]; then
                    printf '              min: '
                    yaml_quote "${QOS_MIN[$qos]}"
                    printf '\n'
                fi

                if [[ -n "${QOS_MAX[$qos]:-}" ]]; then
                    printf '              max: '
                    yaml_quote "${QOS_MAX[$qos]}"
                    printf '\n'
                fi

                if [[ -n "${QOS_MAX_WALL[$qos]:-}" ]]; then
                    printf '              time:\n'
                    printf '                max: '
                    yaml_quote "${QOS_MAX_WALL[$qos]}"
                    printf '\n'
                fi
            fi
        done

        # ---------------------------------------------------------------
        # Hardware
        # ---------------------------------------------------------------

        if (( HW_AVAILABLE )); then
            printf '        hardware:\n'

            if [[ -n "$HW_SOCKETS" ]]; then
                printf '          sockets_per_node: %s\n' "$HW_SOCKETS"
            fi

            if [[ -n "$HW_CORES_PER_SOCKET" ]]; then
                printf '          cores_per_socket: %s\n' "$HW_CORES_PER_SOCKET"
            fi

            if [[ -n "$HW_THREADS_PER_CORE" ]]; then
                printf '          threads_per_core: %s\n' "$HW_THREADS_PER_CORE"
            fi

            if [[ -n "$HW_CORES_PER_NODE" ]]; then
                printf '          cores_per_node: %s\n' "$HW_CORES_PER_NODE"
            fi

            if [[ -n "$HW_MEMORY_MIB" ]]; then
                printf '          memory_per_node_mib: %s\n' "$HW_MEMORY_MIB"
            fi

            if [[ -n "$HW_GPUS" ]]; then
                printf '          gpus_per_node: %s\n' "$HW_GPUS"
            fi
        fi

        # ---------------------------------------------------------------
        # Request
        # ---------------------------------------------------------------

        printf '        request:\n'

        printf '          whole_node:\n'
        printf '            enabled: %s\n' "$whole_node"

        if [[ "$whole_node" == true ]]; then
            printf '            memory_all: "--mem=0"\n'
        fi

        printf '          cpu_granularity: '
        yaml_quote "$CPU_GRANULARITY"
        printf '\n'

        if [[ -n "$memory_request" ]]; then
            printf '          memory:\n'
            printf '            per_core_mib: %s\n' "$memory_request"
            printf '            source: '
            yaml_quote "$memory_source"
            printf '\n'
        fi

        # ---------------------------------------------------------------
        # Partition metadata
        # ---------------------------------------------------------------

        printf '        partition:\n'

        if [[ -n "$max_nodes" ]]; then
            printf '          max_nodes: '
            yaml_quote "$max_nodes"
            printf '\n'
        fi

        if [[ -n "$max_time" ]]; then
            printf '          max_time: '
            yaml_quote "$max_time"
            printf '\n'
        fi

        if [[ -n "$max_cpus_per_node" ]]; then
            printf '          max_cpus_per_node: '
            yaml_quote "$max_cpus_per_node"
            printf '\n'
        fi

        printf '          whole_node: %s\n' "$whole_node"
    done < <(printf '%s\n' "${!PARTITION_LINE[@]}" | sort)
}

# ---------------------------------------------------------------------------
# Select accounts
# ---------------------------------------------------------------------------

declare -a OUTPUT_ACCOUNTS=()

if [[ -n "$ACCOUNT_FILTER" ]]; then
    OUTPUT_ACCOUNTS+=("$ACCOUNT_FILTER")
else
    while IFS= read -r account; do
        [[ -n "$account" ]] && OUTPUT_ACCOUNTS+=("$account")
    done < <(printf '%s\n' "${!ACCOUNT_EXISTS[@]}" | sort)
fi

for account in "${OUTPUT_ACCOUNTS[@]}"; do
    emit_account "$account"
done
