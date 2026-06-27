#!/usr/bin/env bash
# Idempotent installer for the CodexBar GNOME panel setup (Codex + Claude usage).
# Safe to re-run: it converges to the desired state and skips unchanged work.
#
#   ./install.sh            # install / update everything
#   ./install.sh --status   # just print what's installed, change nothing
#
# What it sets up:
#   * steipete CodexBar CLI  -> ~/.local/bin/codexbar-cli   (multi-provider usage)
#   * panel-usage script     -> ~/.local/bin/panel-usage    (compact Pango line)
#   * GNOME extension CodexBar (codexbar@inled.es)          -> click popover
#   * GNOME extension Executor (executor@raujonas.github.io)-> inline panel text
#   * gsettings for both extensions + enables them in dconf
#
# Auth is NOT copied between machines: you must run `codex login` and
# `claude login` on each machine yourself (the script only checks + warns).
set -euo pipefail

# ---------------------------------------------------------------- constants
CLI_REPO="steipete/CodexBar"
CODEXBAR_UUID="codexbar@inled.es"
EXECUTOR_UUID="executor@raujonas.github.io"
BIN_DIR="$HOME/.local/bin"
EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/codexbar/config.json"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fixed id so re-runs produce identical Executor config (true idempotency).
PANEL_CMD_UUID="7f3e1c20-0001-4000-9000-panelusage01"
# jq filter that strips the windows which confuse the inled extension's
# antigravity-detection (it would otherwise show 0% Spark/Daily-Routines).
JQ_FILTER='map(.usage |= (del(.extraRateWindows) | del(.tertiary) | del(.quaternary)))'

c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_green"  "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$c_yellow" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$c_red"    "$c_off" "$*" >&2; exit 1; }

STATUS_ONLY=0
[ "${1:-}" = "--status" ] && STATUS_ONLY=1

# ---------------------------------------------------------------- 1. tools
for t in curl jq python3 gnome-extensions glib-compile-schemas gsettings unzip dconf uname tar sha256sum install; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t (e.g. sudo apt install $t)"
done

# ---------------------------------------------------------------- 2. arch / shell
case "$(uname -m)" in
  x86_64)        ARCH_TAG="linux-musl-x86_64" ;;
  aarch64|arm64) ARCH_TAG="linux-musl-aarch64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
SHELL_VER="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
[ -n "$SHELL_VER" ] || die "could not determine GNOME Shell version (is GNOME installed?)"
log "GNOME Shell $SHELL_VER, arch $(uname -m), session ${XDG_SESSION_TYPE:-unknown}"

# ---------------------------------------------------------------- 3. auth (warn only)
[ -f "$HOME/.codex/auth.json" ]        || warn "Codex not logged in -> run: codex login"
[ -f "$HOME/.claude/.credentials.json" ] || warn "Claude not logged in -> run: claude login"

if [ "$STATUS_ONLY" = 1 ]; then
  echo "---- status ----"
  printf 'codexbar-cli : %s\n' "$([ -x "$BIN_DIR/codexbar-cli" ] && echo "v$(cat "$BIN_DIR/.codexbar-cli.version" 2>/dev/null || echo '?')" || echo 'not installed')"
  printf 'panel-usage  : %s\n' "$([ -x "$BIN_DIR/panel-usage" ] && echo present || echo missing)"
  for u in "$CODEXBAR_UUID" "$EXECUTOR_UUID"; do
    printf 'ext %-28s : %s\n' "$u" "$([ -d "$EXT_DIR/$u" ] && echo "v$(jq -r .version "$EXT_DIR/$u/metadata.json" 2>/dev/null)" || echo missing)"
  done
  printf 'enabled-extensions : %s\n' "$(gsettings get org.gnome.shell enabled-extensions)"
  exit 0
fi

mkdir -p "$BIN_DIR"

# ---------------------------------------------------------------- 4. codexbar-cli
LATEST="$(curl -fsSL "https://api.github.com/repos/$CLI_REPO/releases/latest")"
TAG="$(echo "$LATEST" | jq -r .tag_name)"          # e.g. v0.37.2
VER="${TAG#v}"
ASSET="CodexBarCLI-${TAG}-${ARCH_TAG}.tar.gz"
URL="$(echo "$LATEST" | jq -r --arg a "$ASSET" '.assets[]|select(.name==$a)|.browser_download_url')"
[ -n "$URL" ] && [ "$URL" != "null" ] || die "release asset not found: $ASSET"

# `codexbar-cli --version` output is unreliable, so track the installed version
# with a sidecar marker file we write ourselves.
VER_MARK="$BIN_DIR/.codexbar-cli.version"
CUR_VER="$(cat "$VER_MARK" 2>/dev/null || true)"
if [ -x "$BIN_DIR/codexbar-cli" ] && [ "$CUR_VER" = "$VER" ]; then
  log "codexbar-cli $VER already installed"
else
  log "installing codexbar-cli $VER ($ARCH_TAG)"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/cli.tgz" "$URL"
  curl -fsSL -o "$TMP/cli.sha" "$URL.sha256"
  exp="$(awk '{print $1}' "$TMP/cli.sha")"; act="$(sha256sum "$TMP/cli.tgz" | awk '{print $1}')"
  [ "$exp" = "$act" ] || die "sha256 mismatch for $ASSET"
  tar -xzf "$TMP/cli.tgz" -C "$TMP"
  install -Dm755 "$TMP/CodexBarCLI" "$BIN_DIR/codexbar-cli"
  printf '%s' "$VER" > "$VER_MARK"
  log "codexbar-cli installed -> $BIN_DIR/codexbar-cli"
fi

# ---------------------------------------------------------------- 5. providers + secure config
"$BIN_DIR/codexbar-cli" config enable --provider codex  >/dev/null 2>&1 || true
"$BIN_DIR/codexbar-cli" config enable --provider claude >/dev/null 2>&1 || true
[ -f "$CFG" ] && chmod 600 "$CFG" && log "providers codex+claude enabled, config chmod 600"

# ---------------------------------------------------------------- 6. panel-usage
install -Dm755 "$SRC_DIR/panel-usage" "$BIN_DIR/panel-usage"
log "panel-usage -> $BIN_DIR/panel-usage"

# ---------------------------------------------------------------- 7. GNOME extensions
install_ext() {
  local uuid="$1" info want have dl tmp
  info="$(curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=${uuid}&shell_version=${SHELL_VER}")" \
    || die "EGO query failed for $uuid"
  want="$(echo "$info" | jq -r '.version // empty')"
  have="$(jq -r '.version // empty' "$EXT_DIR/$uuid/metadata.json" 2>/dev/null || true)"
  if [ -n "$want" ] && [ "$want" = "$have" ]; then
    log "extension $uuid v$have already installed"
  else
    dl="$(echo "$info" | jq -r '.download_url // empty')"
    [ -n "$dl" ] || die "$uuid not available for GNOME Shell $SHELL_VER"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/ext.zip" "https://extensions.gnome.org${dl}"
    gnome-extensions install --force "$tmp/ext.zip"
    rm -rf "$tmp"
    log "extension $uuid installed (v$want)"
  fi
  [ -d "$EXT_DIR/$uuid/schemas" ] && glib-compile-schemas "$EXT_DIR/$uuid/schemas" 2>/dev/null || true
}
install_ext "$CODEXBAR_UUID"
install_ext "$EXECUTOR_UUID"

SD_CB="$EXT_DIR/$CODEXBAR_UUID/schemas"
SD_EX="$EXT_DIR/$EXECUTOR_UUID/schemas"

# ---------------------------------------------------------------- 8. gsettings: codexbar popover
CB_PROVIDERS="$(BIN_DIR="$BIN_DIR" JQ_FILTER="$JQ_FILTER" python3 - <<'PY'
import json, os
b, flt = os.environ["BIN_DIR"], os.environ["JQ_FILTER"]
cmd = lambda p: f"{b}/codexbar-cli --provider {p} --source oauth --format json | jq -c '{flt}'"
print(json.dumps([{"name": "Codex", "command": cmd("codex")},
                  {"name": "Claude", "command": cmd("claude")}]))
PY
)"
gsettings --schemadir "$SD_CB" set org.gnome.shell.extensions.codexbar providers "$CB_PROVIDERS"
gsettings --schemadir "$SD_CB" set org.gnome.shell.extensions.codexbar first-run false
log "codexbar popover providers configured"

# ---------------------------------------------------------------- 9. gsettings: executor inline
EX_CMDS="$(BIN_DIR="$BIN_DIR" CMD_UUID="$PANEL_CMD_UUID" python3 - <<'PY'
import json, os
print(json.dumps({"commands": [{
    "isActive": True,
    "command": f'{os.environ["BIN_DIR"]}/panel-usage',
    "interval": 120,
    "uuid": os.environ["CMD_UUID"],
}]}))
PY
)"
gsettings --schemadir "$SD_EX" set org.gnome.shell.extensions.executor right-commands-json "$EX_CMDS"
gsettings --schemadir "$SD_EX" set org.gnome.shell.extensions.executor right-active true
log "executor inline command configured (right slot, 120s)"

# ---------------------------------------------------------------- 10. enable extensions
gsettings set org.gnome.shell disable-user-extensions false
CODEXBAR_UUID="$CODEXBAR_UUID" EXECUTOR_UUID="$EXECUTOR_UUID" python3 - <<'PY'
import os, ast, subprocess
get = subprocess.check_output(["gsettings", "get", "org.gnome.shell", "enabled-extensions"]).decode().strip()
cur = ast.literal_eval(get) if get and get != "@as []" else []
for u in (os.environ["CODEXBAR_UUID"], os.environ["EXECUTOR_UUID"]):
    if u not in cur:
        cur.append(u)
val = "[" + ", ".join("'" + x + "'" for x in cur) + "]"
subprocess.check_call(["gsettings", "set", "org.gnome.shell", "enabled-extensions", val])
PY
# best-effort: enable live (only works if the running shell already knows them)
gnome-extensions enable "$CODEXBAR_UUID" 2>/dev/null || true
gnome-extensions enable "$EXECUTOR_UUID" 2>/dev/null || true
log "extensions enabled in dconf"

# ---------------------------------------------------------------- done
echo
log "Done."
echo "    Inline panel  : Cx <s>% <reset> · wk <w>% <reset>  │  Cl ..."
echo "    Quick check   : panel-usage | sed -E 's/<[^>]+>//g'"
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  warn "Wayland: log out and back in once so GNOME Shell loads the new extensions."
else
  warn "Restart GNOME Shell (Alt+F2 -> r) or re-login to load the new extensions."
fi
[ -f "$HOME/.claude/.credentials.json" ] || warn "Reminder: run 'claude login' for the Claude tile."
[ -f "$HOME/.codex/auth.json" ]          || warn "Reminder: run 'codex login' for the Codex tile."
