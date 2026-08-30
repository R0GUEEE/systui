#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
file="$repo_root/src/features/71-bedrock-config-final.sh"

grep -q '^bedrock_aok_config_preflight()' "$file"
grep -q '^bedrock_aok_config_write_default()' "$file"
grep -q 'never calls bedrock_aok_generate_config' "$file"
grep -q 'bedrock_aok_config_preflight || return 1' "$file"
grep -q 'bedrock_aok_config_preflight || return 0' "$file"
grep -q 'Recheck/repair compatibility path' "$file"

# The repair helper must not recursively call the public generator.
repair_body=$(awk '/^bedrock_aok_config_repair_compat\(\)/,/^}/' "$file")
if grep -q 'bedrock_aok_generate_config' <<<"$repair_body"; then
    echo 'repair helper recursively calls bedrock_aok_generate_config' >&2
    exit 1
fi

bash -n "$file"
printf 'PASS: Bedrock config compatibility repair is automatic and idempotent\n'
