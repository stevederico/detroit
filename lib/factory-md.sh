# shellcheck shell=bash
# lib/factory-md.sh — factory.md parsing.
# Spec: https://github.com/stevederico/factory-md

# factory_section <section-name> <factory.md path>
# Extracts the body of an H2 section from a factory.md file (case-insensitive).
factory_section() {
  local section="$1"
  local file="$2"
  awk -v target="## $section" '
    BEGIN { found=0; t=tolower(target) }
    /^## / {
      if (found) exit
      if (tolower($0) == t) { found=1; next }
    }
    found { print }
  ' "$file"
}

# factory_rules <factory.md path>
# Concatenates every known factory.md section with a heading prefix so the
# agent prompt contains every rule the factory declares.
factory_rules() {
  local file="$1"
  local section body
  for section in style build testing documentation environment quality observability security; do
    body=$(factory_section "$section" "$file")
    [ -z "$body" ] && continue
    printf '\n%s\n%s\n' "[$section]" "$body"
  done
}

# factory_stages <factory.md path>
# Emits the v2 `## stages` section as `stage:value` lines (stage lowercased).
# Empty output means no stage layer (v1 file) — callers fall back to flat gating.
factory_stages() {
  local file="$1" line stage val
  factory_section "stages" "$file" | while IFS= read -r line; do
    line=$(echo "$line" | sed -E 's/^[[:space:]]*[-*+][[:space:]]*//')
    case "$line" in
      *:*)
        stage=$(echo "${line%%:*}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        val=$(echo "${line#*:}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        [ -n "$stage" ] && printf '%s:%s\n' "$stage" "$val" ;;
    esac
  done
}

# read_env_bullet <key> <factory.md path>
# Reads a `key: value` bullet from `## environment` (same key:value bullet
# shape factory_stages established). First match wins; empty if absent.
read_env_bullet() {
  local key="$1" file="$2" line
  factory_section "environment" "$file" | while IFS= read -r line; do
    line=$(echo "$line" | sed -E 's/^[[:space:]]*[-*+][[:space:]]*//; s/^![[:space:]]*//')
    case "$line" in
      "$key:"*)
        echo "${line#*:}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
        break ;;
    esac
  done
}

# resolve_knob <ENV_VAR_NAME> <bullet-key> <default>
# Precedence: process env var > factory.md `## environment` bullet > default.
resolve_knob() {
  local val="${!1:-}"
  [ -n "$val" ] || val=$(read_env_bullet "$2" "$DETROIT/factory.md")
  [ -n "$val" ] || val="$3"
  echo "$val"
}

# factory_rules_for_stage <categories-csv> <factory.md path>
# Like factory_rules, but only the named gate-category sections (comma list).
factory_rules_for_stage() {
  local csv="$1" file="$2" section body
  local IFS=,
  for section in $csv; do
    section=$(echo "$section" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$section" in
      style|build|testing|documentation|environment|quality|observability|security) ;;
      *) continue ;;
    esac
    body=$(factory_section "$section" "$file")
    [ -z "$body" ] && continue
    printf '\n[%s]\n%s\n' "$section" "$body"
  done
}
