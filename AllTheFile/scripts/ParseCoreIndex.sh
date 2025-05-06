#!/bin/sh

INPUT="$KUBERNETES_EXCLUSIVE_CPUS"

parsed_numbers=""

IFS=','
for part in $INPUT; do
    if echo "$part" | grep -q '-'; then
        start=$(echo "$part" | cut -d'-' -f1)
        end=$(echo "$part" | cut -d'-' -f2)
        numbers=$(seq "$start" "$end" 2>/dev/null | tr '\n' ',')
        parsed_numbers="${parsed_numbers}${numbers}"
    else
        parsed_numbers="${parsed_numbers}${part},"
    fi
done
unset IFS

formatted_output=$(echo "$parsed_numbers" | tr ',' '\n' | grep -v '^$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

echo "$formatted_output"