# shellcheck shell=bash

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

factory_rules() {
  local file="$1"
  local section body
  for section in style build testing documentation environment quality observability security; do
    body=$(factory_section "$section" "$file")
    [ -z "$body" ] && continue
    printf '\n%s\n%s\n' "[$section]" "$body"
  done
}

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

resolve_knob() {
  local val="${!1:-}"
  [ -n "$val" ] || val=$(read_env_bullet "$2" "$DETROIT/factory.md")
  [ -n "$val" ] || val="$3"
  echo "$val"
}

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
