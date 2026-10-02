#!/usr/bin/env bash
set -euo pipefail

USER_NAME=${USER:?USER is not set}
ACCOUNT=${ACCOUNT:-}

printf '{\n'
printf '  "user": "%s",\n' "$USER_NAME"
printf '  "accounts": [\n'

first_account=true

while IFS='|' read -r account qos default_qos; do
    [[ -z "$account" ]] && continue

    [[ "$first_account" == false ]] && printf ',\n'
    first_account=false

    printf '    {\n'
    printf '      "account": "%s",\n' "$account"
    printf '      "qos": ['

    first_qos=true
    IFS=',' read -ra qos_list <<< "$qos"

    for q in "${qos_list[@]}"; do
        [[ -z "$q" ]] && continue
        [[ "$first_qos" == false ]] && printf ', '
        first_qos=false
        printf '"%s"' "$q"
    done

    printf '],\n'
    printf '      "default_qos": "%s"\n' "${default_qos:-}"
    printf '    }'
done < <(
    if [[ -n "$ACCOUNT" ]]; then
        sacctmgr show assoc where user="$USER_NAME" account="$ACCOUNT" format=Account,Qos,DefaultQos -n -P 2>/dev/null
    else
        sacctmgr show assoc where user="$USER_NAME" format=Account,Qos,DefaultQos -n -P 2>/dev/null
    fi | awk -F'|' '!seen[$1 FS $2 FS $3]++'
)

printf '\n  ]\n'
printf '}\n'
