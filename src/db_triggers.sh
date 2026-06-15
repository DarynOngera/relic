# shellcheck shell=bash
# shellcheck source=src/db_utils.sh

_db_triggers_init() {
  _DB_TRIGGERS_SET=()
  _DB_TRIGGERS_DELETE=()
}

_db_fire_triggers() {
  local event="$1"
  shift
  local funcs=()

  case "$event" in
    set)
      funcs=("${_DB_TRIGGERS_SET[@]}")
      ;;
    delete)
      funcs=("${_DB_TRIGGERS_DELETE[@]}")
      ;;
    *)
      return 0
      ;;
  esac

  for func in "${funcs[@]}"; do
    if [ -z "$func" ]; then
      continue
    fi
    if declare -f "$func" >/dev/null 2>&1; then
      if ! "$func" "$event" "$@" 2>/dev/null; then
        db_log_warn "Trigger '$func' for event '$event' failed"
      fi
    else
      db_log_warn "Trigger function '$func' not found; skipping"
    fi
  done
}

_db_fire_trigger_if_user_key() {
  local event="$1" key="$2"
  shift 2
  if _db_is_system_key "$key"; then
    return 0
  fi
  _db_fire_triggers "$event" "$key" "$@"
}

db_trigger() {
  if [ $# -lt 1 ]; then
    echo "Error: db_trigger requires action" >&2
    return 1
  fi

  local action="$1"

  case "$action" in
    set | delete)
      if [ $# -ne 2 ]; then
        echo "Error: db_trigger $action requires a function name" >&2
        return 1
      fi
      local func="$2"
      if ! declare -f "$func" >/dev/null 2>&1; then
        echo "Error: function '$func' is not defined" >&2
        return 1
      fi
      if [ "$action" = "set" ]; then
        _DB_TRIGGERS_SET+=("$func")
      else
        _DB_TRIGGERS_DELETE+=("$func")
      fi
      ;;
    list)
      printf '%s\n' "${_DB_TRIGGERS_SET[@]}" "${_DB_TRIGGERS_DELETE[@]}"
      ;;
    clear)
      _DB_TRIGGERS_SET=()
      _DB_TRIGGERS_DELETE=()
      ;;
    *)
      echo "Error: unknown trigger action '$action'" >&2
      return 1
      ;;
  esac
}

_db_triggers_init
