# CodexBar panel — Codex + Claude usage in the GNOME top bar

Shows OpenAI **Codex** and Anthropic **Claude** subscription usage (session 5h +
weekly limits) directly in the GNOME panel, plus a click-popover with details.

```
Cx 40% 1h27m · 18% 4d5h (+22pp)  │  Cl 4% 3h58m · 6% 3d2h (+50pp)
```

- Numbers are **heavy/bold**, no-fluff, and colored by severity:
  `<75` green · `75–84` yellow · `85–94` orange · `≥95` red.
- Reset countdowns are precise for both windows (`1h27m`, `4d22h`).
- Reuses the **already-logged-in** local Codex CLI and Claude CLI credentials.
  No new API keys are created, and credentials are **not** copied between machines.

Tested on Ubuntu 26.04, GNOME Shell 50, Wayland. Supports GNOME Shell 45–50,
x86_64 and aarch64.

---

## Quick start (per machine)

`install.sh` is a **single self-contained file** — `panel-usage` is embedded in
it, so copying just that one script is enough.

```bash
# 1. copy the single file onto the machine (scp / curl / paste):
scp install.sh user@host:~/

# 2. make sure the provider CLIs are logged in (one-time, interactive):
codex login        # https://github.com/openai/codex
claude login       # Claude Code CLI

# 3. run the installer (idempotent — safe to re-run / re-run after updates):
bash ~/install.sh

# 4. Wayland only: log out and back in once so GNOME loads the new extensions.
```

Check it without changing anything:

```bash
~/Apps/codexbar-panel/install.sh --status
panel-usage | sed -E 's/<[^>]+>//g'     # preview the panel line in plain text
```

---

## What gets installed

| Component | Path | Role |
|---|---|---|
| steipete CodexBar CLI | `~/.local/bin/codexbar-cli` | fetches multi-provider usage (static musl build) |
| `panel-usage` | `~/.local/bin/panel-usage` | renders the compact Pango line for the panel |
| CodexBar extension | `codexbar@inled.es` (EGO 9841) | click-popover with per-provider detail |
| Executor extension | `executor@raujonas.github.io` (EGO 2932) | runs `panel-usage` and shows it inline |

The installer also: enables the `codex`+`claude` providers (`config enable`),
`chmod 600` on `~/.config/codexbar/config.json`, writes the extensions'
`gsettings`, sets `disable-user-extensions=false`, and adds both UUIDs to
`org.gnome.shell enabled-extensions`.

Prerequisite tools (the script checks and aborts if missing):
`curl jq python3 gnome-extensions glib-compile-schemas gsettings unzip dconf tar sha256sum`.
On Debian/Ubuntu: `sudo apt install curl jq python3 gnome-shell-extension-prefs jq libglib2.0-bin unzip`.

---

## How it works (and two non-obvious gotchas)

**Inline line.** Executor runs commands on an interval and renders their stdout
in the panel. It only treats output as Pango markup when the output contains the
token `<executor.markup.true>` — note its regex needs *two dots*, so
`<executor.markup>` would be printed literally. `panel-usage` emits that token.

**Popover data and weekly pace.** The `codexbar@inled.es` extension misclassifies
any payload that has `usage.extraRateWindows` as "Antigravity" and then shows
those windows (Codex *Spark* / Claude *Daily Routines*, both 0%) instead of the
real 5h/weekly. The provider commands now run
`panel-usage --provider-json codex` (or `claude`), which removes those fields
and adds weekly pace rows through `usage.details`. Existing detail sections are
preserved. The installer enables `show-provider-details` when supported by the
extension; older versions still get the inline indicator.

**Claude rate-limit resilience.** Anthropic's OAuth usage endpoint rate-limits
easily. `panel-usage` therefore caches the last-good value per provider in
`~/.cache/panel-usage/`, only re-polls Claude every `CLAUDE_TTL` (240s), shows a
fresh-enough cached value in normal color, dims it only after `STALE` (900s), and
falls back to `—` only when there is nothing cached. Codex is local and polled
every run.

## Quota pace and exhaustion forecast

Claude also shows the same indicator immediately after its 5-hour countdown,
with a separate **5h pace** forecast section in the popover. Its duration comes
from `windowMinutes`, falling back to 300 minutes. Codex remains weekly-only.

The weekly number is still **used percent**. Its new suffix, e.g. `(-7pp)`,
is the remaining quota minus the percentage of time left in the window.
Negative means spending faster than an even pace; positive means spare quota.
It is a difference in percentage points, not an additional limit.

The popover's **Weekly pace** section also estimates exhaustion using average
usage since the window began: `elapsed * remaining quota / used quota`.
It shows a countdown only when exhaustion is earlier than reset, otherwise
"Lasts until reset at current average pace". Zero usage has no exhaustion
estimate. This is a conditional forecast, not a guarantee or a recent-usage
trend; it changes as usage changes.

Calculations use the provider's `windowMinutes`, falling back to seven days
for the weekly secondary window. Missing/invalid data and reset boundaries
suppress pace. The weekly-only Codex fallback retains the indicator. Older
cache entries simply omit it until refreshed. Stale cached output is dimmed,
marked `[stale]`, and has no pace estimate. Popover data is fetched separately
and is not served from the inline cache.

Development checks (no installation or provider access):

```bash
bash -n install.sh uninstall.sh
python3 -m unittest discover -s tests -v
```

---

## Customizing the look

All knobs are constants at the top of the `panel-usage` body. For a quick
runtime tweak edit `~/.local/bin/panel-usage`; to make it **permanent** (survive
re-installs / roll out to other machines) edit the embedded heredoc inside
`install.sh` and re-run it.

- Colors: `CX`, `CL` (labels), `GREEN/YELLOW/ORANGE/RED` (severity), `DIM`.
- Thresholds: function `sev()` (75 / 85 / 95).
- Number weight: `weight="heavy"` in `num()` (use `bold`/`normal` to soften).
- Poll interval: the `interval` (seconds) in the Executor command — set in
  `install.sh` (default 120). Claude refresh floor: `CLAUDE_TTL`.
- Reset precision: `countdown()` (precise vs `coarse=True`).

After editing the in-place script, changes show within one interval — no relogin
needed (only *installing* a new extension needs a relogin on Wayland).

---

## Uninstall / rollback

```bash
./uninstall.sh                    # remove our bits; keep the Executor extension
./uninstall.sh --remove-executor  # also remove Executor itself
./uninstall.sh --dry-run          # show what would happen, change nothing
```

Removes `codexbar-cli`, `panel-usage`, the cache, `~/.config/codexbar`, the
CodexBar popover extension, and strips the `panel-usage` command from Executor.
On purpose it does **not** touch your `~/.codex` / `~/.claude` logins, the global
`disable-user-extensions` flag, or any other Executor commands. Log out/in once
(Wayland) to fully unload the removed extension.

## Troubleshooting

- **Raw `<span ...>` tags show in the panel** → Executor isn't rendering markup;
  ensure output starts with `<executor.markup.true>` (two dots).
- **Popover shows 0% / "Antigravity User"** → the provider wrapper isn't applied; re-run
  `install.sh` (it rewrites the provider commands).
- **Nothing appears after install** → Wayland needs a logout/login; also check
  `gsettings get org.gnome.shell disable-user-extensions` is `false`.
- **`Cl —` or grey Claude** → Anthropic rate-limit; it self-heals. Hard reset:
  `claude logout && claude login`.
- **Codex/Claude tile empty** → not logged in: `codex login` / `claude login`.
- **Inline line is clipped/overlapped by tray icons** → it must be in the LEFT
  panel box (the installer sets that). If it ever clips there too (long line +
  wide center clock, or briefly right after login while the panel settles), it
  usually resolves on its own; to make it shorter, edit the format in the
  `panel-usage` heredoc (e.g. drop the weekly reset or the `wk` labels).

---

## Rollout to several machines

One self-contained file + idempotent, so the simplest flow is:

```bash
for h in host1 host2 host3; do
  scp install.sh "$h:~/install.sh"
  ssh "$h" 'bash ~/install.sh'
  # then on each: codex login / claude login (if not already), and relogin once
done
```

Credentials are intentionally per-machine. Either run `codex login` / `claude
login` on each host, or copy `~/.codex` and `~/.claude` yourself if your
subscription terms allow sharing a session across machines.
