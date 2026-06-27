#!/usr/bin/env bash
# Roll back what install.sh set up. Idempotent and safe to re-run.
#
#   ./uninstall.sh                    # remove our bits; keep the Executor extension
#   ./uninstall.sh --remove-executor  # also remove the Executor extension itself
#   ./uninstall.sh --dry-run          # print what would happen, change nothing
#
# By design this does NOT:
#   * touch your Codex/Claude logins (~/.codex, ~/.claude),
#   * flip the global `disable-user-extensions` (other extensions may rely on it),
#   * remove the Executor extension unless you pass --remove-executor (it is a
#     generic tool you may use for other panel commands — we only strip OUR
#     command from it by default).
set -euo pipefail

CODEXBAR_UUID="codexbar@inled.es"
EXECUTOR_UUID="executor@raujonas.github.io"
BIN_DIR="$HOME/.local/bin"
EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/codexbar"
CACHE_DIR="$HOME/.cache/panel-usage"
PANEL_CMD_UUID="7f3e1c20-0001-4000-9000-panelusage01"

c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_green"  "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$c_yellow" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$c_red"    "$c_off" "$*" >&2; exit 1; }

DRY=0; REMOVE_EXECUTOR=0
for a in "$@"; do
  case "$a" in
    --dry-run)         DRY=1 ;;
    --remove-executor) REMOVE_EXECUTOR=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $a (try --help)" ;;
  esac
done
run() { if [ "$DRY" = 1 ]; then printf '%s[dry]%s %s\n' "$c_yellow" "$c_off" "$*"; else "$@"; fi; }

# remove given UUIDs from org.gnome.shell enabled-extensions (keeps the rest)
remove_from_enabled() {
  DRY="$DRY" RM_UUIDS="$*" python3 - <<'PY'
import os, ast, subprocess
rm = set(os.environ["RM_UUIDS"].split())
get = subprocess.check_output(["gsettings","get","org.gnome.shell","enabled-extensions"]).decode().strip()
cur = ast.literal_eval(get) if get and get != "@as []" else []
new = [u for u in cur if u not in rm]
if new == cur:
    print("    enabled-extensions: nothing to remove"); raise SystemExit
val = "[" + ", ".join("'" + x + "'" for x in new) + "]"
if os.environ["DRY"] == "1":
    print("    [dry] enabled-extensions -> " + val)
else:
    subprocess.check_call(["gsettings","set","org.gnome.shell","enabled-extensions",val])
    print("    enabled-extensions updated")
PY
}

# 1. strip OUR panel-usage command out of Executor (leave any other commands)
SD_EX="$EXT_DIR/$EXECUTOR_UUID/schemas"
if [ "$REMOVE_EXECUTOR" = 0 ] && [ -d "$SD_EX" ]; then
  DRY="$DRY" SD_EX="$SD_EX" CMD_UUID="$PANEL_CMD_UUID" python3 - <<'PY'
import os, ast, json, subprocess
sd, cmd_uuid, dry = os.environ["SD_EX"], os.environ["CMD_UUID"], os.environ["DRY"]
raw = subprocess.check_output(["gsettings","--schemadir",sd,"get",
    "org.gnome.shell.extensions.executor","right-commands-json"]).decode().strip()
try:
    obj = json.loads(ast.literal_eval(raw))         # GVariant string -> JSON
except Exception:
    obj = {"commands": []}
cmds = obj.get("commands", [])
kept = [c for c in cmds if c.get("uuid") != cmd_uuid and "panel-usage" not in c.get("command","")]
if len(kept) == len(cmds):
    print("    Executor: no panel-usage command found"); raise SystemExit
obj["commands"] = kept
val = json.dumps(obj)
if dry == "1":
    print("    [dry] executor right-commands-json -> " + val)
else:
    subprocess.check_call(["gsettings","--schemadir",sd,"set",
        "org.gnome.shell.extensions.executor","right-commands-json",val])
    print("    Executor: panel-usage command removed (%d command(s) left)" % len(kept))
PY
  log "Executor command stripped"
fi

# 2. CodexBar popover extension: disable, de-list, remove files
run gnome-extensions disable "$CODEXBAR_UUID" 2>/dev/null || true
remove_from_enabled "$CODEXBAR_UUID"
[ -d "$EXT_DIR/$CODEXBAR_UUID" ] && run rm -rf "$EXT_DIR/$CODEXBAR_UUID" && log "removed extension $CODEXBAR_UUID" || true

# 3. optionally remove Executor extension too
if [ "$REMOVE_EXECUTOR" = 1 ]; then
  run gnome-extensions disable "$EXECUTOR_UUID" 2>/dev/null || true
  remove_from_enabled "$EXECUTOR_UUID"
  [ -d "$EXT_DIR/$EXECUTOR_UUID" ] && run rm -rf "$EXT_DIR/$EXECUTOR_UUID" && log "removed extension $EXECUTOR_UUID" || true
else
  warn "kept Executor extension ($EXECUTOR_UUID) — pass --remove-executor to drop it"
fi

# 4. binaries, script, marker, cache, codexbar CLI config
for f in "$BIN_DIR/codexbar-cli" "$BIN_DIR/.codexbar-cli.version" "$BIN_DIR/panel-usage"; do
  [ -e "$f" ] && run rm -f "$f" && log "removed $f" || true
done
[ -d "$CACHE_DIR" ] && run rm -rf "$CACHE_DIR" && log "removed cache $CACHE_DIR" || true
[ -d "$CFG_DIR" ]   && run rm -rf "$CFG_DIR"   && log "removed config $CFG_DIR" || true

echo
log "Rollback complete${DRY:+}."
[ "$DRY" = 1 ] && warn "dry-run: nothing was actually changed"
warn "Log out / back in (Wayland) to fully unload the removed extension(s)."
echo "    Kept on purpose: ~/.codex, ~/.claude logins; global disable-user-extensions."
