#!/usr/bin/env bash
set -euo pipefail

MOUNT_DIR="${WEED_MOUNT_DIR:-/mnt}"
FILER_ADDR="${WEED_FILER_ADDR:-seaweedfs-filer-fuse:8888}"
FILER_PATH="${WEED_FILER_PATH:-/}"
SELENIUM_ASSETS_PATH="${SE_NODE_DOCKER_ASSETS_PATH:-/opt/selenium/assets}"
LOCAL_UID="$(id -u)"
LOCAL_GID="$(id -g)"
FILER_UID="${WEED_FILER_UID:-1000}"
FILER_GID="${WEED_FILER_GID:-1000}"
DEFAULT_PERMISSIONS="${WEED_DEFAULT_PERMISSIONS:-false}"
UMASK_VALUE="${WEED_UMASK:-0002}"
FIX_DIR_EXEC="${WEED_FIX_DIR_EXEC:-true}"
SCRIPT_START_TS="$(date +%s)"
HISTORY_UUID=""
WORK_ID=""
ACTOR_USERNAME=""
WORKSPACE_MOUNT_PATH=""
PUBLIC_MOUNT_PATH=""
WORKSPACE_SOURCE_PATH=""
PUBLIC_SOURCE_PATH="/public"
ACTOR_METADATA_FILE="/tmp/admingate_actor_metadata.json"
WEED_WORK_PID=""
WEED_PUBLIC_PID=""

resolve_admingate_mount_paths() {
  local capabilities_file
  capabilities_file="$({ find "$SELENIUM_ASSETS_PATH" -maxdepth 2 -type f -name sessionCapabilities.json -printf '%T@ %p\n' 2>/dev/null || true; } | awk -v min_ts="$SCRIPT_START_TS" '$1 >= min_ts {print $0}' | sort -nr | head -n1 | awk '{print $2}')"
  if [[ -z "${capabilities_file:-}" || ! -f "$capabilities_file" ]]; then
    return 0
  fi

  local parsed
  parsed="$(python3 - "$capabilities_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    print("")
    print("")
    raise SystemExit(0)

history_uuid = data.get("admingate:historyUuid", "")
work_id = data.get("admingate:workId", "")
username = data.get("admingate:username", "")
mount_paths = data.get("admingate:mountPaths") or {}
workspace_path = mount_paths.get("workspace", "")
public_path = mount_paths.get("public", "")

print(history_uuid)
print(work_id)
print(username)
print(workspace_path)
print(public_path)
PY
)"

  mapfile -t parsed_lines <<<"$parsed"
  HISTORY_UUID="${parsed_lines[0]:-}"
  WORK_ID="${parsed_lines[1]:-}"
  ACTOR_USERNAME="${parsed_lines[2]:-}"
  WORKSPACE_MOUNT_PATH="${parsed_lines[3]:-}"
  PUBLIC_MOUNT_PATH="${parsed_lines[4]:-}"

  if [[ -z "$HISTORY_UUID" || -z "$WORK_ID" ]]; then
    return 0
  fi

  if [[ -z "$WORKSPACE_MOUNT_PATH" ]]; then
    WORKSPACE_MOUNT_PATH="${MOUNT_DIR}/${HISTORY_UUID}/work/${WORK_ID}"
  fi
  if [[ -z "$PUBLIC_MOUNT_PATH" ]]; then
    PUBLIC_MOUNT_PATH="${MOUNT_DIR}/${HISTORY_UUID}/public"
  fi

  WORKSPACE_SOURCE_PATH="/${WORK_ID}"
  PUBLIC_SOURCE_PATH="/public"
}

prepare_actor_metadata_file() {
  if [[ -z "$ACTOR_USERNAME" || -z "$HISTORY_UUID" || -z "$WORK_ID" ]]; then
    return 0
  fi

  cat > "$ACTOR_METADATA_FILE" <<EOF
{"username":"$ACTOR_USERNAME","history_uuid":"$HISTORY_UUID","work_id":"$WORK_ID"}
EOF
  chmod 0444 "$ACTOR_METADATA_FILE"

  export WEED_ACTOR_USERNAME="$ACTOR_USERNAME"
  export WEED_ACTOR_HISTORY_UUID="$HISTORY_UUID"
  export WEED_ACTOR_METADATA_FILE="$ACTOR_METADATA_FILE"
}

wait_for_admingate_mount_metadata() {
  for _ in $(seq 1 60); do
    resolve_admingate_mount_paths
    if [[ -n "$HISTORY_UUID" && -n "$WORK_ID" && -n "$WORKSPACE_MOUNT_PATH" && -n "$PUBLIC_MOUNT_PATH" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

prepare_mount_directories() {
  mkdir -p "${MOUNT_DIR}/${HISTORY_UUID}/work"
  mkdir -p "$WORKSPACE_MOUNT_PATH"
  mkdir -p "$PUBLIC_MOUNT_PATH"
}

mkdir -p "$MOUNT_DIR"

start_admingate_mounts() {
  if ! wait_for_admingate_mount_metadata; then
    echo "admingate mount path metadata not found within timeout" >&2
    return 0
  fi

  prepare_mount_directories
  prepare_actor_metadata_file

  /usr/local/bin/weed mount \
    -filer="$FILER_ADDR" \
    -dir="$WORKSPACE_MOUNT_PATH" \
    -dirAutoCreate=true \
    -filer.path="$WORKSPACE_SOURCE_PATH" \
    -map.uid="${LOCAL_UID}:${FILER_UID}" \
    -map.gid="${LOCAL_GID}:${FILER_GID}" \
    -defaultPermissions="${DEFAULT_PERMISSIONS}" \
    -umask="${UMASK_VALUE}" &
  WEED_WORK_PID=$!

  /usr/local/bin/weed mount \
    -filer="$FILER_ADDR" \
    -dir="$PUBLIC_MOUNT_PATH" \
    -dirAutoCreate=true \
    -filer.path="$PUBLIC_SOURCE_PATH" \
    -map.uid="${LOCAL_UID}:${FILER_UID}" \
    -map.gid="${LOCAL_GID}:${FILER_GID}" \
    -defaultPermissions="${DEFAULT_PERMISSIONS}" \
    -umask="${UMASK_VALUE}" &
  WEED_PUBLIC_PID=$!

  for _ in $(seq 1 20); do
    if grep -qs " ${WORKSPACE_MOUNT_PATH} " /proc/mounts && grep -qs " ${PUBLIC_MOUNT_PATH} " /proc/mounts; then
      echo "prepared admingate mount paths: history_uuid=$HISTORY_UUID work_id=$WORK_ID"
      break
    fi
    sleep 1
  done

  if [[ "$FIX_DIR_EXEC" == "true" ]]; then
    chmod u+x,g+x "${MOUNT_DIR}/${HISTORY_UUID}" "${MOUNT_DIR}/${HISTORY_UUID}/work" || true
  fi
}

start_admingate_mounts &

cleanup() {
  if [[ -n "${WEED_WORK_PID:-}" ]]; then
    kill "$WEED_WORK_PID" >/dev/null 2>&1 || true
    wait "$WEED_WORK_PID" 2>/dev/null || true
  fi
  if [[ -n "${WEED_PUBLIC_PID:-}" ]]; then
    kill "$WEED_PUBLIC_PID" >/dev/null 2>&1 || true
    wait "$WEED_PUBLIC_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

exec /opt/bin/entry_point.sh
