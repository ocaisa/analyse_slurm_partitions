#!/usr/bin/env bash
#
# validate_qos_submissions.sh
#
# For every partition - and every QoS usable on it - build a MINIMAL and a
# MAXIMAL sbatch request and verify that Slurm will accept it.
#
#   MIN job: the smallest trivial request (tiny walltime, no TRES). Proves the
#            partition/QoS accepts a minimal job (no per-job minimum is being
#            enforced) and that the QoS is allowed on the partition.
#   MAX job: a request pushed to the QoS per-job ceilings (MaxTRESPerJob
#            cpu/memory/gpu, walltime = min(QoS MaxWall, partition MaxTime),
#            node count derived from cpus-per-node). Proves the computed
#            ceiling is within what Slurm accepts at submission time.
#
# QoS set per partition = the cluster default (submitted with NO -q, labelled
# "default") plus every QoS in the partition's QOSList + MinQOS. On a partition
# with a restrictive MinQOS the no-"-q" (default) job is EXPECTED to FAIL - that
# is the point: it proves MinQOS is enforced.
#
# By default nothing is submitted: each job is validated with `sbatch --dryrun`.
# `--mode submit` actually submits each job with --hold and cancels it again
# (scancel) unless `--keep` is given.
#
# Uses only scontrol + sbatch (+ scancel in submit mode). No python, no YAML
# input - everything is read live from the cluster.
#
# Usage:
#   ./validate_qos_submissions.sh [options]
#
# Options:
#   --mode dryrun|submit   execution mode (default: dryrun)
#   --jobs min|max|both    which jobs to build (default: both)
#   --partitions a,b,c     only these partitions
#   --qos default,a,b      only these QoS ("default" = submit with no -q)
#   --limit N              stop after N partitions
#   --yaml FILE            also write a YAML summary to FILE
#   --keep                 (submit mode) do not scancel after submitting
#   --verbose              also print the raw sbatch output
#   -h, --help             show this help
#
# Exit status: 0 if every checked job is submittable, 1 if any failed,
#              2 on a usage/environment error.

set -uo pipefail

MODE="dryrun"
JOBS="both"
PART_FILTER=""
QOS_FILTER=""
LIMIT=""
YAML_OUT=""
KEEP=0
VERBOSE=0

usage() {
    cat <<'USAGE'
Usage: validate_qos_submissions.sh [options]

Builds a minimal and a maximal sbatch request for each partition/QoS and checks
that Slurm accepts it. Uses only scontrol + sbatch (+ scancel in submit mode).

Options:
  --mode dryrun|submit   execution mode (default: dryrun)
  --jobs min|max|both    which jobs to build (default: both)
  --partitions a,b,c     only these partitions
  --qos default,a,b      only these QoS ("default" = submit with no -q)
  --limit N              stop after N partitions
  --yaml FILE            also write a YAML summary to FILE
  --keep                 (submit mode) do not scancel after submitting
  --verbose              also print the raw sbatch output
  -h, --help             show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)     MODE="${2:-}"; shift 2 ;;
        --jobs)     JOBS="${2:-}"; shift 2 ;;
        --partitions) PART_FILTER="${2:-}"; shift 2 ;;
        --qos)      QOS_FILTER="${2:-}"; shift 2 ;;
        --limit)    LIMIT="${2:-}"; shift 2 ;;
        --yaml)     YAML_OUT="${2:-}"; shift 2 ;;
        --keep)     KEEP=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERROR: unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

case "$MODE" in dryrun|submit) ;; *) echo "ERROR: --mode must be dryrun|submit" >&2; exit 2 ;; esac
case "$JOBS" in min|max|both) ;; *) echo "ERROR: --jobs must be min|max|both" >&2; exit 2 ;; esac
if [[ -n "$LIMIT" && ! "$LIMIT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --limit must be a positive integer" >&2; exit 2
fi

command -v scontrol >/dev/null 2>&1 || { echo "ERROR: scontrol not found" >&2; exit 2; }
command -v sbatch   >/dev/null 2>&1 || { echo "ERROR: sbatch not found" >&2; exit 2; }
if [[ "$MODE" == "submit" ]]; then
    command -v scancel >/dev/null 2>&1 || { echo "ERROR: scancel not found (needed for --mode submit)" >&2; exit 2; }
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract a single "key=value" token from a one-line scontrol partition record.
getkv() {
    local line="$1" key="$2" v=""
    case "$line" in
        *"$key="*)
            v="${line##*"$key="}"
            printf '%s' "${v%% *}"
            return 0
            ;;
    esac
    return 1
}

# "UNLIMITED" / "" / non-numeric -> 0 ; otherwise the number.
num_or_0() {
    local v="${1:-}"
    if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; else printf '0'; fi
}

# walltime -> seconds. Accepts D-HH:MM:SS, HH:MM:SS, MM, seconds, UNLIMITED.
to_seconds() {
    local wt="${1:-}"
    if [[ -z "$wt" || "$wt" == "UNLIMITED" ]]; then printf '0'; return; fi
    if [[ "$wt" =~ ^[0-9]+$ ]]; then printf '%s' "$wt"; return; fi
    local days=0 rest="$wt"
    if [[ "$rest" == *-* ]]; then days="${rest%%-*}"; rest="${rest#*-}"; fi
    local h m s
    IFS=: read -r h m s <<< "$rest"
    h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0})); days=$((10#${days:-0}))
    printf '%d' $(( days*86400 + h*3600 + m*60 + s ))
}

fmt_walltime() {
    local t="$1"
    printf '%02d:%02d:%02d' $(( t / 3600 )) $(( (t % 3600) / 60 )) $(( t % 60 ))
}

# min of two "seconds" values, where 0 means "unlimited" (ignored).
min_nonzero() {
    local a="$1" b="$2"
    if [[ "$a" -le 0 ]]; then printf '%s' "$b"; return; fi
    if [[ "$b" -le 0 ]]; then printf '%s' "$a"; return; fi
    if (( a < b )); then printf '%s' "$a"; else printf '%s' "$b"; fi
}

ceildiv() {
    local a="$1" b="$2"
    if (( b < 1 )); then b=1; fi
    printf '%d' $(( (a + b - 1) / b ))
}

# Value of one TRES in a "name=count,..." string (e.g. cpu=128,memory=900G).
tres_val() {
    local tres="${1:-}" name="$2" item
    if [[ -z "$tres" ]]; then return 0; fi
    IFS=',' read -r -a items <<< "$tres"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        if [[ "$item" == "$name="* ]]; then printf '%s' "${item#*=}"; return 0; fi
    done
    return 0
}

# Split "900G" by a node count -> per-node value in the same unit (floor, min 1).
mem_per_node() {
    local m="${1:-}" n="${2:-1}" num unit per
    if [[ -z "$m" || n -lt 1 ]]; then return 0; fi
    num="${m%%[KkMmGgTtPp]*}"
    unit="${m:${#num}}"
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then return 0; fi
    per=$(( num / n ))
    if (( per < 1 )); then per=1; fi
    printf '%s%s' "$per" "$unit"
}

# Run one sbatch. Sets globals RC (exit code), OUT (combined output), JID.
exec_sbatch() {
    local mode="$1"; shift
    local out="" rc=0 jid=""
    if [[ "$mode" == "dryrun" ]]; then
        out="$( sbatch --dryrun "$@" 2>&1 )" || rc=$?
    else
        out="$( sbatch --hold "$@" 2>&1 )" || rc=$?
    fi
    JID=""
    if [[ "$mode" == "submit" && "$rc" -eq 0 ]]; then
        jid="$( printf '%s\n' "$out" | grep -oE 'Submitted batch job [0-9]+' | head -n1 | awk '{print $NF}' || true )"
        if [[ -n "$jid" ]]; then
            JID="$jid"
            if [[ "$KEEP" -ne 1 ]]; then
                scancel "$jid" >/dev/null 2>&1 || true
            fi
        fi
    fi
    RC=$rc
    OUT="$out"
}

# ---------------------------------------------------------------------------
# Gather + parse scontrol data
# ---------------------------------------------------------------------------

qos_raw="$(scontrol show qos 2>/dev/null || true)"
part_raw="$(scontrol show partitions 2>/dev/null || true)"

if [[ -z "$part_raw" ]]; then
    echo "ERROR: could not read partition data (scontrol show partitions)" >&2
    exit 2
fi

declare -A Q_EXISTS=() Q_DEFAULT=() Q_MAXTRESJOB=() Q_MAXWALL=()
declare -A Q_MAXCPUNODE=() Q_MAXNODES=() Q_MINNODES=()

cur=""
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
        QOSName=*)
            cur="${line#QOSName=}"
            Q_EXISTS["$cur"]=1
            ;;
        *=*)
            if [[ -z "$cur" ]]; then continue; fi
            k="${line%%=*}"
            v="${line#*=}"
            case "$k" in
                Default)       Q_DEFAULT["$cur"]="$v" ;;
                MaxTRESPerJob) Q_MAXTRESJOB["$cur"]="$v" ;;
                MaxWall)       Q_MAXWALL["$cur"]="$v" ;;
                MaxCPUsNode)   Q_MAXCPUNODE["$cur"]="$v" ;;
                MaxNodes)      Q_MAXNODES["$cur"]="$v" ;;
                MinNodes)      Q_MINNODES["$cur"]="$v" ;;
            esac
            ;;
    esac
done <<< "$qos_raw"

defqos=""
for q in "${!Q_DEFAULT[@]}"; do
    if [[ "${Q_DEFAULT[$q]:-}" == "1" ]]; then defqos="$q"; break; fi
done
if [[ -z "$defqos" ]]; then defqos="normal"; fi

# ---------------------------------------------------------------------------
# Report / counters / YAML
# ---------------------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a YAML_LINES=()
PARTITION_COUNT=0

USE_COLOR=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then USE_COLOR=1; fi

report() {
    local status="$1" part="$2" qos="$3" jtype="$4" cmd="$5" reason="${6:-}"
    local tag="$status"
    if [[ "$USE_COLOR" -eq 1 ]]; then
        case "$status" in
            PASS) printf '\033[32m';; FAIL) printf '\033[31m';; *) printf '\033[33m';;
        esac
        tag="$(printf '%s' "$status")"
        printf '[%s\033[0m] ' "$tag"
    else
        printf '[%s] ' "$status"
    fi
    printf '%-12s / %-12s / %-3s  %s\n' "$part" "$qos" "$jtype" "$cmd"
    if [[ -n "$reason" ]]; then
        while IFS= read -r rl; do
            [[ -n "$rl" ]] && printf '              %s\n' "$rl"
        done <<< "$reason"
    fi
    if [[ "$VERBOSE" -eq 1 && -n "${OUT:-}" ]]; then
        printf '              (sbatch: %s)\n' "${OUT//$'\n'/ | }"
    fi
}

yaml_escape() {
    local v="${1:-}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "$v"
}

yaml_add() { YAML_LINES+=("$1"); }

# ---------------------------------------------------------------------------
# Argument-builder for one (partition, qos) case. Fills global ARGS[] + CMDSTR.
# Globals read: P_NAME, P_MAXTIME, P_MAXCPUNODE, P_MINNODES, P_MAXNODES,
#               P_TOTALCPUS, P_TOTALNODES, plus per-qos values passed by name.
# ---------------------------------------------------------------------------

build_min() {
    local entry="$1" src_qos="$2" maxwall="$3" pmaxtime="$4" qminnodes="$5" pminnodes="$6"
    local mwe minwallsec pn qn minnodes
    ARGS=(-p "$P_NAME")
    if [[ "$entry" != "default" ]]; then ARGS+=(-q "$entry"); fi
    mwe="$(min_nonzero "$(to_seconds "$maxwall")" "$(to_seconds "$pmaxtime")")"
    minwallsec=300
    if (( mwe > 0 && mwe < 300 )); then minwallsec="$mwe"; fi
    ARGS+=(--time "$(fmt_walltime "$minwallsec")")
    pn="$(num_or_0 "$pminnodes")"; qn="$(num_or_0 "$qminnodes")"
    minnodes=$(( pn > qn ? pn : qn ))
    if (( minnodes > 0 )); then ARGS+=(--nodes "$minnodes"); fi
    ARGS+=(--wrap "true")
    CMDSTR="sbatch"
    for a in "${ARGS[@]}"; do CMDSTR+=" $a"; done
}

build_max() {
    local entry="$1" src_qos="$2" maxtresjob="$3" maxwall="$4" maxcpunode="$5"
    local pmaxtime="$6" qmaxnodes="$7" qminnodes="$8" pminnodes="$9"
    local has_limits="${10}"
    local cpu_max mem_max gpu_max cpn n ntasks mnodes mxn capped
    local mwe pernode

    HAS_LIMITS=1
    MAX_SKIPPED=""
    if [[ "$has_limits" != "1" ]]; then
        HAS_LIMITS=0
        MAX_SKIPPED="QoS '$src_qos' not found in 'scontrol show qos' (cannot compute a max)"
        return 0
    fi

    cpu_max="$(num_or_0 "$(tres_val "$maxtresjob" cpu)")"
    mem_max="$(tres_val "$maxtresjob" memory)"
    gpu_max="$(num_or_0 "$(tres_val "$maxtresjob" gpu)")"

    # Effective cpus-per-node: QoS > partition > total ratio > 1.
    cpn="$(num_or_0 "$maxcpunode")"
    if (( cpn < 1 )); then cpn="$(num_or_0 "$P_MAXCPUNODE")"; fi
    if (( cpn < 1 )); then
        local tc tn
        tc="$(num_or_0 "$P_TOTALCPUS")"; tn="$(num_or_0 "$P_TOTALNODES")"
        if (( tc > 0 && tn > 0 )); then cpn=$(( tc / tn )); else cpn=1; fi
    fi
    if (( cpn < 1 )); then cpn=1; fi

    # Node count from the cpu ceiling, clamped to [min_nodes, max_nodes].
    n=1
    if (( cpu_max > 0 )); then n="$(ceildiv "$cpu_max" "$cpn")"; fi
    local pn qn
    pn="$(num_or_0 "$pminnodes")"; qn="$(num_or_0 "$qminnodes")"
    mnodes=$(( pn > qn ? pn : qn ))
    if (( n < mnodes )); then n="$mnodes"; fi
    mxn=0
    local c
    for c in "$(num_or_0 "$qmaxnodes")" "$(num_or_0 "$P_MAXNODES")" "$(num_or_0 "$P_TOTALNODES")"; do
        if (( c > 0 && ( mxn == 0 || c < mxn ) )); then mxn="$c"; fi
    done
    capped=0
    if (( mxn > 0 && n > mxn )); then n="$mxn"; capped=1; fi
    if (( n < 1 )); then n=1; fi

    # CPU request (reduced if the node ceiling forced fewer nodes).
    ntasks=""
    if (( cpu_max > 0 )); then
        if (( capped )); then ntasks=$(( n * cpn )); else ntasks="$cpu_max"; fi
        if (( ntasks < 1 )); then ntasks=1; fi
    fi

    mwe="$(min_nonzero "$(to_seconds "$maxwall")" "$(to_seconds "$pmaxtime")")"

    ARGS=(-p "$P_NAME")
    if [[ "$entry" != "default" ]]; then ARGS+=(-q "$entry"); fi
    if (( mwe > 0 )); then ARGS+=(--time "$(fmt_walltime "$mwe")"); fi
    if (( n > 0 )); then ARGS+=(--nodes "$n"); fi
    if [[ -n "$ntasks" ]]; then ARGS+=(--ntasks "$ntasks" --cpus-per-task 1); fi
    if [[ -n "$mem_max" ]]; then
        pernode="$(mem_per_node "$mem_max" "$n")"
        if [[ -n "$pernode" ]]; then ARGS+=(--mem "$pernode"); fi
    fi
    if (( gpu_max > 0 )); then ARGS+=(--gres "gpu:$gpu_max"); fi
    ARGS+=(--wrap "true")

    CMDSTR="sbatch"
    for a in "${ARGS[@]}"; do CMDSTR+=" $a"; done
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

run_case() {
    local entry="$1" src_qos="$2" has_limits="$3"
    local maxtresjob maxwall maxcpunode qmaxnodes qminnodes
    maxtresjob="${Q_MAXTRESJOB[$src_qos]:-}"
    maxwall="${Q_MAXWALL[$src_qos]:-}"
    maxcpunode="${Q_MAXCPUNODE[$src_qos]:-}"
    qmaxnodes="${Q_MAXNODES[$src_qos]:-}"
    qminnodes="${Q_MINNODES[$src_qos]:-}"

    local jt status reason jid
    for jt in min max; do
        if [[ "$JOBS" == "min" && "$jt" == "max" ]]; then continue; fi
        if [[ "$JOBS" == "max" && "$jt" == "min" ]]; then continue; fi

        if [[ "$jt" == "min" ]]; then
            build_min "$entry" "$src_qos" "$maxwall" "$P_MAXTIME" "$qminnodes" "$P_MINNODES"
        else
            build_max "$entry" "$src_qos" "$maxtresjob" "$maxwall" "$maxcpunode" \
                      "$P_MAXTIME" "$qmaxnodes" "$qminnodes" "$P_MINNODES" "$has_limits"
        fi

        if [[ "$jt" == "max" && "$HAS_LIMITS" != "1" ]]; then
            status="SKIP"
            reason="$MAX_SKIPPED"
            yaml_check "$entry" "$jt" "$CMDSTR" "$status" "$reason"
            SKIP_COUNT=$(( SKIP_COUNT + 1 ))
            report "$status" "$P_NAME" "$entry" "$jt" "(skipped)" "$reason"
            continue
        fi

        exec_sbatch "$MODE" "${ARGS[@]}"
        if [[ "$RC" -eq 0 ]]; then
            status="PASS"
            reason=""
        else
            status="FAIL"
            reason="$OUT"
        fi
        if [[ "$status" == "PASS" ]]; then
            PASS_COUNT=$(( PASS_COUNT + 1 ))
        else
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        fi
        jid=""
        if [[ "$MODE" == "submit" && -n "${JID:-}" ]]; then jid=" (job ${JID})"; fi
        yaml_check "$entry" "$jt" "$CMDSTR" "$status" "$reason"
        report "$status" "$P_NAME" "$entry" "$jt" "$CMDSTR${jid:+  -> $jid}" "$reason"
    done
}

yaml_check() {
    local entry="$1" jt="$2" cmd="$3" status="$4" reason="${5:-}"
    if [[ -z "$YAML_OUT" ]]; then return 0; fi
    yaml_add "    - qos: $(yaml_escape "$entry")"
    yaml_add "      $jt:"
    yaml_add "        command: $(yaml_escape "$cmd")"
    if [[ -n "${JID:-}" && "$MODE" == "submit" && "$status" == "PASS" ]]; then
        yaml_add "        job_id: $JID"
    fi
    if [[ -n "$reason" ]]; then
        yaml_add "        reason: $(yaml_escape "$reason")"
    fi
    yaml_add "        status: $status"
}

# QoS filter: is a given entry (default or named) selected?
qos_selected() {
    local entry="$1"
    if [[ -z "$QOS_FILTER" ]]; then return 0; fi
    local tok
    IFS=',' read -r -a toks <<< "$QOS_FILTER"
    for tok in "${toks[@]}"; do
        tok="$(trim "$tok")"
        if [[ "$tok" == "$entry" ]]; then return 0; fi
    done
    return 1
}
trim() { local v="${1:-}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

part_selected() {
    local name="$1"
    if [[ -z "$PART_FILTER" ]]; then return 0; fi
    local tok
    IFS=',' read -r -a toks <<< "$PART_FILTER"
    for tok in "${toks[@]}"; do
        tok="$(trim "$tok")"
        if [[ "$tok" == "$name" ]]; then return 0; fi
    done
    return 1
}

printf '# QoS submission validation (%s mode) at %s\n' \
    "$MODE" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" >&2

declare -a PART_LINES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && PART_LINES+=("$line")
done < <(printf '%s\n' "$part_raw" | grep -E 'PartitionName=' || true)

for line in "${PART_LINES[@]}"; do
    P_NAME="$(getkv "$line" "PartitionName")"
    P_QOSLIST="$(getkv "$line" "QOSList" || true)"
    P_MINQOS="$(getkv "$line" "MinQOS" || true)"
    P_MAXTIME="$(getkv "$line" "MaxTime" || true)"
    P_MAXCPUNODE="$(getkv "$line" "MaxCPUsNode" || true)"
    P_MINNODES="$(getkv "$line" "MinNodes" || true)"
    P_MAXNODES="$(getkv "$line" "MaxNodes" || true)"
    P_TOTALCPUS="$(getkv "$line" "TotalCPUs" || true)"
    P_TOTALNODES="$(getkv "$line" "TotalNodes" || true)"
    P_STATE="$(getkv "$line" "State" || true)"

    if ! part_selected "$P_NAME"; then continue; fi

    PARTITION_COUNT=$(( PARTITION_COUNT + 1 ))
    if [[ -n "$LIMIT" && "$PARTITION_COUNT" -gt "$LIMIT" ]]; then
        continue
    fi

    state_up="${P_STATE^^}"
    if [[ "$state_up" == "DOWN" || "$state_up" == "DRAIN" || "$state_up" == "INACTIVE" ]]; then
        printf '[-] %-12s skipped (partition state: %s)\n' "$P_NAME" "$P_STATE" >&2
        continue
    fi

    # Build the ordered, deduplicated QoS list for this partition.
    declare -a named=()
    declare -A named_seen=()
    add_named() {
        local q="${1:-}"
        q="${q//[[:space:]]/}"
        if [[ -z "$q" || -n "${named_seen[$q]:-}" ]]; then return 0; fi
        named_seen["$q"]=1
        named+=("$q")
    }
    if [[ "$P_QOSLIST" != "(null)" && -n "$P_QOSLIST" ]]; then
        IFS=',' read -r -a qarr <<< "$P_QOSLIST"
        for q in "${qarr[@]}"; do add_named "$q"; done
    fi
    if [[ "$P_MINQOS" != "(null)" && -n "$P_MINQOS" ]]; then
        add_named "$P_MINQOS"
    fi

    if [[ "$YAML_OUT" != "" ]]; then
        yaml_add "  - partition_name: $(yaml_escape "$P_NAME")"
        yaml_add "    checks:"
    fi

    # "default" first (submitted with no -q, uses the default QoS limits),
    # then each named QoS (skipping one that equals the cluster default).
    entries=("default")
    for q in "${named[@]}"; do
        if [[ "$q" == "$defqos" ]]; then continue; fi
        entries+=("$q")
    done

    for entry in "${entries[@]}"; do
        if ! qos_selected "$entry"; then continue; fi
        if [[ "$entry" == "default" ]]; then
            src_qos="$defqos"
        else
            src_qos="$entry"
        fi
        has_limits=0
        if [[ -n "${Q_EXISTS[$src_qos]:-}" ]]; then has_limits=1; fi
        run_case "$entry" "$src_qos" "$has_limits"
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n# Summary: %d PASS, %d FAIL, %d SKIP  (%s mode, %d partitions)\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$MODE" "$PARTITION_COUNT" >&2

if [[ -n "$YAML_OUT" ]]; then
    {
        printf 'generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        printf 'mode: %s\n' "$MODE"
        printf 'summary:\n'
        printf '  pass: %d\n' "$PASS_COUNT"
        printf '  fail: %d\n' "$FAIL_COUNT"
        printf '  skip: %d\n' "$SKIP_COUNT"
        printf 'partitions:\n'
        if [[ "${#YAML_LINES[@]}" -gt 0 ]]; then
            printf '%s\n' "${YAML_LINES[@]}"
        fi
    } > "$YAML_OUT"
    printf '# YAML summary written to %s\n' "$YAML_OUT" >&2
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then exit 1; fi
exit 0
