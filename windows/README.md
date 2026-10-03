# PenguinNotch for Windows

A Windows port based on [vinzdg's Codenotch](https://github.com/vinzdg/codenotch) — the usage notch that
sits on the edge of your screen with **AI usage, system monitoring, stock quotes,
charts and local forecast history**.

Same design language as the macOS original (inverse-rounded pill, colour-graded rings,
hover card with per-window bars), rebuilt for Windows in Rust + Tauri 2 / WebView2.
The providers and stock calculations follow the macOS app's behaviour and wire
formats, using native Windows storage and system APIs.

**Stable release: [1.25.1](../../../releases/tag/v1.25.1) (Windows build r59).** Stock quotes retain
a validated same-session closing baseline through transient request failures;
a new session or trading day still requires a valid new baseline. This integrates upstream 1.19.0
with PenguinNotch's six-section settings, stocks, monitoring and daily widgets.
Overflowing notch items now scroll with the mouse wheel or trackpad on every edge,
in both Circles and Bars. See [Scrolling long lists](#scrolling-long-lists).

**New in 1.25.0 / r58**, matching macOS 1.25.0 / build 66: unified forecast history
and evaluation, plus historical replay over 20, 60 or 120 completed trading days.
Compare daily, 1-minute and 10-minute GBM results against the same-input baseline,
preserve original evidence, pause/resume collection and export matching results to CSV.

1.25.1 matches macOS build 67's release. Windows already stores each provider's
credential pair in one atomic Credential Manager blob; the format is preserved.
The new explicit Keychain access button is specific to macOS.

## What it shows

| Cell | Source | How it reads it |
|---|---|---|
| **Claude** | `GET https://api.anthropic.com/api/oauth/usage` with the token Claude Code keeps in `~/.claude/.credentials.json` | Session / weekly windows, 429 back-off with a persisted deadline, stale readings dimmed with their age. Renews that token by running the standalone `claude -p` shortly before it expires (Claude Code inside the desktop app never writes this file), and never sends an expired one. A thin arc spins inside the ring while a Claude session is working, and pulses amber when one is waiting on you (Claude Code hooks + transcript watcher, desktop app included). |
| **Codex** | The local Codex sign-in in `~/.codex/auth.json` (read only, never refreshed), falling back to the newest session snapshot | Live primary/secondary windows (5h + weekly on paid plans, a monthly window on free) while Codex is signed in; Spark and Code review appear on the hover card when Codex reports them; otherwise the last snapshot, marked stale by its own timestamp. |
| **Cursor** | The editor's own session from `state.vscdb` → `cursor.com/api/usage-summary` | Included usage / API usage / on-demand, reset at billing-cycle end. Nothing to sign into: it borrows the editor's session, so there is only ever one account. |
| **Grok** | The Grok CLI's own session in `~/.grok/auth.json` (read only, never refreshed) → `cli-chat-proxy.grok.com/v1/billing?format=credits`, the endpoint that CLI's own `/usage` asks | The weekly Grok Build allowance, with the account on the hover card. Only a session minted by `auth.x.ai` is used — the file can also hold a customer IdP token meant for that customer's private proxy. A fresh weekly period reads 0 %, not "unmetered". |
| **OpenCode** | OpenCode's own sign-in, read only: the `opencode-go` key in `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage`, or — since OpenCode 1.18 — the OAuth sign-in in `opencode.db` (`credential` table) → `opencode.ai/inference/go/v1/usage` | The Go plan's 5-hour, weekly and monthly windows. A sign-in without a Go plan shows "No OpenCode Go subscription" instead of a ring; Zen pay-as-you-go credit has no balance or usage API, so it is not shown. |
| **Antigravity** | Official `agy` CLI `/usage` print when installed; otherwise the existing local `language_server` bridge, Google Cloud Code API, or transcript model count | Official four quota rows (Gemini & Claude/GPT 5h/weekly) without running the full IDE. When CLI is absent, falls back to legacy local bridge/API. |
| **Z.ai / GLM** | Z.ai's `/api/monitor/usage/quota/limit` | Reads a Z.ai key from `glm.json`, Claude Code configured for Z.ai, ZCode, or OpenCode's Z.ai provider entries. OpenCode Go is a separate subscription; its key is never claimed as a Z.ai credential. |

Providers that are not installed simply do not get a cell.

OpenCode credentials are borrowed read-only from its XDG data directory (normally
`~/.local/share/opencode`). The active database sign-in takes precedence over the
legacy OAuth mirror; the Go API key remains a separate credential type. No tokens
are returned to the web UI or written to the usage cache.

Public usage requests honor explicit proxy environment settings. If none are set,
PenguinNotch adopts an enabled static Windows Internet Options proxy at startup;
PAC scripts and automatic proxy discovery are not evaluated. The local Antigravity
bridge connects directly to loopback, and proxy addresses are not logged.

The same notch also shows **CPU, RAM, GPU, DISK, NET, BAT and PWR**, plus a calendar,
weather and a to-do list. CPU, memory, disk, network and battery use documented
Win32 calls. CPU hover cards include logical-core load from PDH counters. GPU
cards show available driver/PDH engine counters; processes sharing an engine
are combined, and the headline is the busiest engine, not the sum of all GPUs.
Unsupported or failed readings stay `—` rather than a fabricated zero.
DISK covers mounted local fixed/removable volumes, including separate partitions
and folder mount points. Each volume is counted once even if it has several
paths. Its hover card shows each volume's used, total and available space;
unmounted recovery volumes and network drives are excluded. Capacity refreshes
on a separate worker scheduled by the one-second meter loop; at most one scan
runs at a time, so a slow disk does not stall the other meters.
NET fills its ring for a wired connection, uses Windows WLAN signal quality for
Wi-Fi, and offers **Wi-Fi settings…** to open Windows network settings. Unknown
signal remains unmeasured; a filled ring does not guarantee Internet access.
Power is the battery discharge
reported by `CallNtPowerInformation` / `SystemBatteryState` while unplugged and
discharging. The rate is a signed value (negative means discharging); it is
labelled as an estimate and is not added to the watt-hour total. On AC, or when
the reading is missing, the cell stays empty. A failed network or CPU read keeps
the last good counters, and a gap longer than ten seconds is not billed. Weather
is Celsius from Open-Meteo and is fetched off the sampling thread. Refresh asks
again for the saved city and does not clear it. Order, hide and per-cell color
are in Settings → Computer monitoring for hardware and Settings → Daily widgets
for calendar, weather and to-dos. Hiding one meter does not stop the others; turning off
system monitoring does.

### Stocks and local history

Open **Settings → Stocks**, choose one provider, and save its credentials.
**Toss Securities** supports Korean/US quotes, 1-minute/10-minute/daily charts,
SMA 5/20/60/120 and completed-bar volume/breakout analysis. Register this PC's
public IP in Toss WTS → Settings → Open API → Allowed IPs. **Finnhub** supports
US quotes only; its mode does not show an empty chart or call Toss. Credentials
stay in Windows Credential Manager and are never returned to the web UI.

Add up to 30 Korean codes/company names or US tickers. Set visibility and colors,
and drag visible stocks in either the list or notch to reorder them; hidden
stocks keep their positions. Arrow buttons remain available. Alt-drag still
moves the notch. Stocks use the same hollow ring and stroke thickness as other
cells. Their arcs start at twelve o'clock: gains fill clockwise in
green and losses fill counterclockwise in red, matching macOS. An unchanged price
draws no colored sweep. Prices and percentage changes alternate every three seconds
by default. Windows quotes poll once a minute; chart requests are cached per
symbol for 1 minute, 10 minutes or 1 day, with daily cache rollover on the market's
local date. Charts display at most 20 candles and use earlier bars for analysis.

**Stock settings (1.24.1)** use the same four local tabs as macOS: **Watchlist → My account → Analysis → History**. Watchlist opens first; connection and display options start collapsed. Charts and estimates live in Analysis; archives and exports live in History. Detailed methods, investment/total returns and holdings stay collapsed until needed. Windows has no Codex analysis control.

**My Toss account** is the only account discovery/selection surface. Click **Load accounts**, choose a masked account, and use **Refresh** or **Hide account information**. Viewing still works with forecasts and notch stock display off. **Show account in notch** and **Include account holdings in estimates** remain separate opt-ins; opening tabs or loading accounts keeps saved choices, while an explicit new selection moves already-enabled account features to that account. KRW/USD stock values, profit/loss, fractional quantities and costs follow macOS. Cash, bonds and options are excluded; overall ratios are API KRW-converted values. Viewer replies bypass caches. With the account notch off, leaving My account clears its viewer. Provider/credential changes discard old private values. Private information is never persisted, exported or sent to AI.

After explicitly loading an account, enable **Show account in notch**. Its daily return uses the API KRW-converted ratio; gains are green/clockwise and losses red/counterclockwise. Hover shows KRW/USD stock market values and daily profit/loss separately with the refresh time. Cash is excluded. The notch owner polls every 60 seconds independently of stock/forecast visibility and does not store private amounts. Settings remains a manual viewer; closing it does not stop the enabled notch. Disable the notch to stop its private polling. Only its account selector and display choice are saved.

Enable **Stock forecasts** to estimate watchlist stocks without account access
or owning them (1.19.1). **Watchlist only** keeps account requests off. To include
actual holdings too, select an account in **My account** and enable **Include account holdings in estimates**; failed account reads
do not stop watchlist estimates. The selected chart interval controls the volatility
estimate for today's regular close. Daily forecast snapshots, observed minute traces, manual/automatic capture,
next-day scoring and filtered CSV export follow the macOS rules documented in the
[main README](../README.md). Automatic recording needs the app running; missed
predictions are not reconstructed. These are technical/model estimates, with no
automatic orders or validated trading-return claim.

Windows stores public forecast inputs and results in
`%APPDATA%\penguinnotch\stock-history.sqlite3`. Account numbers, quantities,
balances and API secrets are excluded. Traces and snapshots survive restarts,
provider/key changes and disabling the feature. The notch alone writes atomic
deltas; settings loads the archive for filtering/export. No age-based pruning or
omission-based deletion occurs, and unreadable/unknown archives are preserved
with an error. macOS uses its own files; history is not synchronized between PCs.

### Forecast history and historical replay (1.25.0)

Open **Settings → Stocks → History → Forecast history and evaluation**.
**Saved predictions** combines the existing journal and saved-response evaluation;
model, manual/automatic capture and saved/replay cohorts stay separate. Summary
comes first, with detailed metrics, calibration, comparisons and evidence collapsed.
Paired GBM calculations are not Codex requests; saved abstentions count as saved
responses but are not scored. Codex execution remains macOS-only.

Configure the existing watchlist, choose **20, 60 (default), or 120 completed trading
days**, then click **Start replay**. This freezes the **entire configured watchlist,
including hidden symbols**, up to 30. There is no subset selector. Market, stock,
target-day and model filters affect displayed results and CSV only. Cancel preserves
saved data; explicit resume uses the run's frozen manifest after watchlist edits.
Opening/reopening does not start or resume collection. Closing Settings while busy
hides and retains the same WebView/owner until collection settles.

Toss replay targets each official regular close from inputs frozen 60 minutes
before it. The local models are `GBM daily zero drift v1 / replay v1`,
`GBM 1m zero drift v1 / replay v1` and `GBM 10m zero drift v1 / replay v1`.
Daily requires 61 closes / 60 returns; minute models require 10 consecutive
completed returns, with complete 10-minute buckets. Requests are at least 250 ms
apart, capped at 200 candles/page, 8 minute pages / 1,400 raw minute rows/case.
Finnhub cannot provide replay candles.

**Reconstructed from data fetched now; availability at the original time is not guaranteed.**
Inputs and targets use provider-adjusted data fetched now, without claiming the
historical adjustment vintage. Existing saved predictions keep unadjusted actual
settlement. Past minute/target coverage may be missing; acquisition and model skip
reasons remain visible and never become successful zero-error results.

GBM expected close equals input price and its same-case price-hold baseline MAPE.
Probability error and nominal 80% interval coverage/width do not prove better point
predictions or trading returns. MAPE/coverage/width are percentages (MAPE/width may
exceed 100), Brier is a fraction and MAE stays currency-specific. Paired comparisons
require the selected models' identical frozen inputs and targets; available and
paired denominators are separate. No ranking, automatic adoption, replay LLM call
or new account request is added.

In the collapsed comparison panel, use **Comparison models** checkboxes independently
of the display model filter. Select A+B and clear C to retain the A/B intersection;
newly arriving models do not change an explicit selection. Conflict and missing-evidence
exclusion counts remain visible. Replay summaries retain compact verified receipts;
original JSON is read only when explicitly opening a case or exporting. One raw case
is retained at a time, Windows pages show up to 100 cases, and CSV is unavailable until
the selected read generation is complete. Export retains all original evidence and
pending/skipped denominators for the selected filters.

A valid official session of 60 minutes or less remains in the frozen requested dates
as `session_too_short`; its candles are not requested. A short previous session still
supplies its verified calendar identity. Invalid or unproved calendars fail closed.
macOS pauses acquisition on the workspace sleep notification. Windows conservatively
pauses at the next acquisition checkpoint after a gap longer than five seconds,
including a delayed response; explicit **Resume replay** is required. This fallback
can also pause slow requests and cannot detect interruptions of five seconds or less.
Physical sleep/suspend delivery has not been tested. Hiding Settings keeps collection active.

Runs live in `%APPDATA%\penguinnotch\Forecasts\Backtests\<runUUID>\`, separately
from SQLite and earlier history. The manifest binds original case/result bytes by
SHA-256; corruption preserves originals and blocks writes. Evaluation CSV retains
references, raw evidence, times, skip reasons and denominators with spreadsheet-safe
text. See the [main README](../README.md#forecast-history-and-historical-replay)
and [public verification ledger](../docs/wiki/sources.md#s19).

Offline fixture checks, rendered browser mocks and Mac-host Rust/GNU compilation
do not establish native Windows WebView2/Credential Manager or real historical
provider coverage. Onscreen macOS integration also remains unverified. Native
remote CI, Windows installer/doctor/uninstall smoke checks and public update
signatures for 1.25.0 are recorded in the [release verification ledger](../docs/wiki/sources.md#s21).
The optional real-data probe was not performed: safe noninteractive authentication
was not established. Whole-branch independent review and bounded follow-up reviews
are recorded in [S20](../docs/wiki/sources.md#s20).

Focused checks from `windows/`:

```powershell
node --test scripts/test-stocks.cjs
node --test scripts/test-backtests.cjs
node scripts/test-widgets.cjs
node scripts/check-ui-scripts.mjs
node --test test-codex-headline.cjs test-light-surface.cjs scripts/test-ko-i18n.cjs scripts/test-claude-auth-ui.cjs
node scripts/test-settings-browser.cjs
node scripts/test-notch-scroll-browser.cjs
cargo test --locked
```

On macOS, host-side Rust unit tests require the Tauri feature below for its
transparent-window API. The cross-check needs the Windows GNU target and its
build tools installed. Neither command runs Windows itself.

```sh
cargo test --locked --offline --workspace --features tauri/macos-private-api
cargo check --locked --offline --workspace --all-targets --target x86_64-pc-windows-gnu
```

Tests use synthetic market data and a local HTTP server. Cross-compilation and
browser mocks do not verify live Windows Credential Manager, hardware counters,
WebView2 or brokerage access; those need a native Windows run.

### Codex quota recovery

The direct usage endpoint remains the first choice. If it fails, PenguinNotch can
ask an installed **native** `codex.exe` via the documented
[`account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
app-server method before falling back to a rollout snapshot. The desktop's
`%LOCALAPPDATA%\OpenAI\Codex\bin` installation is checked as well as native CLI
candidates. No `.cmd`/Node wrapper is launched. The owned process is hidden,
limited to 20 seconds, and terminated/reaped after the read; no inference or
login command is sent. Existing HTTP 429 backoff and five-minute polling remain.

The main ring/tray selects only core `primary`, never a weekly, Spark or
code-review replacement. If `primary` is absent the headline stays blank;
`secondary` remains available to the separate weekly ring. App-server
multi-bucket replies prefer `codex`. Rollout fallback ignores explicitly different
bucket ids and, like macOS, reads the latest eight non-archived paths from
`state_5.sqlite` using a read-only, WAL-aware connection (50 ms busy timeout).
This finds resumed threads without scanning every session file. If the index
is unavailable, the original three-date-directory scan remains the fallback;
old resumed threads cannot be discovered through that scan alone. Missing data is
not a zero. Percentages retain the existing **used** semantics; this is quota
utilization, not an exact token count or a model-specific allowance.

Why launch a process at all? A borrowed stored-token HTTP read can fail while
the installed Codex client can still authenticate. The native client owns its
managed OAuth lifecycle and can recover live quotas without PenguinNotch copying
its refresh logic. This is not guaranteed for externally managed credentials
that require a host app: if it cannot read the quota, the usual stale/missing
rollout status remains. Unlike the old unconditional wrapper-based path, this
recovery runs only after HTTP failure, directly owns a native executable, and
does not use `taskkill` or launch a Node/cmd tree. PenguinNotch sends no login or
explicit token-refresh request; Codex may perform its own normal managed refresh.

Regression checks: `cargo test --locked` and `node --test test-codex-headline.cjs`
from `windows/`. Tests use synthetic quota fixtures, not account credentials.
The optional `cargo test --release --locked codex::tests::live_native_quota -- --ignored`
checks the actual native transport against an already signed-in local client;
it prints no account credentials or quota values and is not run by CI.

### Claude sign-in

When Claude is signed out, its card offers **Sign in**, which opens the standalone
Claude Code CLI's browser login (`claude auth login --claudeai`). It is offered on
the default `~/.claude` account only, since that is the one the CLI signs in.
Finish in the browser; if it
displays a code, paste it in the opened terminal, not in PenguinNotch. The card
refreshes after the CLI exits without restarting the widget. The native CLI must
already be installed; missing CLI, cancellation and launch errors are shown.

This explicit action shares a busy guard with automatic token renewal. Only the
CLI handles OAuth and writes credentials; PenguinNotch does not receive login codes
or expose tokens through UI IPC. The interactive child has a 15-minute timeout.
To read Claude again, click its ring or choose **Refresh now** from the notch's
right-click menu. HTTP 403 is reported as an access/network refusal rather than claiming
that a still-valid login has expired. Existing automatic renewal is unchanged.

### Antigravity

- **Official CLI (Preferred)**: When the official Antigravity CLI (`agy.exe`) is installed (`%LOCALAPPDATA%\agy\bin\agy.exe` or on `PATH`) and signed in, PenguinNotch reads official quotas directly without keeping the full IDE running.
- **Execution**: Runs the official CLI in a hidden Windows pseudo-console, with a 70-second timeout and cleanup of its process tree. It does not need PowerShell scripts or a separate service.
- **Refresh**: Checks at startup and on hover/explicit request when readings are at least five minutes old; failed attempts are also limited to once per five minutes. It keeps previous readings on failure, without switching to legacy APIs. The CLI is not launched periodically while idle.
- **Fallback**: When the official CLI is not installed, PenguinNotch preserves the legacy local bridge (`language_server`), Credential Manager, and transcript model turn counting to maintain compatibility with existing installations.
- **Official CLI Reference**: Standalone `/usage` printing is described in the [official Antigravity CLI documentation](https://www.antigravity.google/docs/cli/headless). Note: no categorical Terms of Service guarantee is made.

Restart PenguinNotch after installing or removing `agy`: the source is selected at startup.
The CLI's text report is parsed defensively; an unsupported format or failed sign-in
shows an error or the last reading marked stale. PenguinNotch does not automate sign-in.

## Install / build

Download [`PenguinNotch-Setup.exe`](https://github.com/pmh10401/PenguinNotch/releases/latest/download/PenguinNotch-Setup.exe)
from the latest release. It installs for the current user without administrator rights, puts
`penguinnotch-hook.exe` beside the app where **Install hooks** looks for it, and fetches WebView2 if
Windows does not already have it. The installer is not code-signed, so SmartScreen stops it the
first time with *Windows protected your PC*: choose **More info**, then **Run anyway**.

### Updates

With **Automatic updates** enabled, PenguinNotch checks about twenty seconds after launch
and then daily. **Check for updates** in Settings → General works independently of that
switch. The feed is `latest.json` on the newest
release, written by the Windows Package workflow beside the installer it describes, so publishing
a release is the whole of shipping an update.

The notch offers **Update** and **Later**, matching macOS. Only Update downloads and runs
the installer. Later hides that version's offer for this app session; Settings can reopen it.
**Preview update** displays the card without downloading or installing anything. Failed
checks and failed installations have separate messages, and a failed install retains the
available version so it can be retried.

The download is a minisign-signed archive, and the signature is checked against the public key in
`tauri.conf.json` before anything is run. This is what stands in for code signing here: the
installer itself is unsigned, so SmartScreen still warns on a first manual install, but an update
delivered to an already-installed copy is verified.

This fork has its own Tauri signing key. The public key is in
`penguinnotch/tauri.conf.json`; the private key is stored outside the repository
and in the `TAURI_SIGNING_PRIVATE_KEY` repository secret. A signed `v*` release
publishes `latest.json` and the signed updater archive on this fork's GitHub.
Versioned releases include both files; the rolling macOS preview is not a Windows update feed.

Keep the private key. Losing it means no installed copy can be updated again, because every one of
them checks against the public key it shipped with — they would all have to reinstall by hand.

To build from source instead — prerequisites: Rust (MSVC toolchain), WebView2 runtime (ships with Windows 11).

```powershell
# from this directory (the repo root here; `windows/` inside the upstream repo)
cargo build --release
.\target\release\penguinnotch.exe          # pill appears on the right edge of the primary monitor
.\target\release\penguinnotch.exe doctor   # self-diagnosis: credentials, data sources, icons, hooks
```

To build the installer the way the Windows Package workflow does:

```powershell
# the hook gets its own target dir, so the bundler never copies it onto itself
cargo build --release --locked -p penguinnotch-hook --target-dir target/hook
cd penguinnotch
npx @tauri-apps/cli@2 build --config tauri.bundle.conf.json
# → ..\target\release\bundle\nsis\PenguinNotch_<version>_x64-setup.exe
```

### Settings by task

The sidebar follows macOS: **AI subscriptions → Stocks → Computer monitoring →
Daily widgets → Appearance → General**. AI accounts and the weekly ring stay together;
hardware meters have their own page; calendar, weather city and to-do visibility/colors
are under Daily widgets. Appearance controls notch placement, size, theme, folded
pill contrast. **AI subscriptions → Usage display** also contains reading visibility,
the dashed secondary ring, paired readings, weekly headline, reset-time format, usage pace,
Claude daily pace and Codex extra limits. **Usage limits** contains watch/critical thresholds
and colour transition, with the same defaults and calculations as macOS. A missing provider
window duration is not inferred from its label. General holds
language, the tray icon, startup and updates. Existing settings and the last selected
page survive the change. Moving items within a section leaves other categories in place.
Features not implemented on Windows do not get empty settings pages.

The browser regression uses synthetic native responses, with no real credentials or API calls:

```sh
node scripts/test-settings-browser.cjs
```

It requires an already-installed Playwright package (use `NODE_PATH` if needed).

Tray menu: the readings themselves — a line per provider with its headline figure, and under it
one line per limit window — then **Show notch now**, **Refresh all**, **Settings…** and **Quit PenguinNotch**. Clicking a
provider's line re-reads that provider. Everything else is in the settings window: which rings the
notch shows, its size, the weekly ring, which screen edge it sits on and which screen,
start with Windows, the language, Claude Code hooks, reset
position, and the data folder (`%APPDATA%\penguinnotch` — logs, persisted readings, icon overrides).

Notch: clicking a ring re-reads that provider, as on the Mac. Right-clicking the notch or its card
offers **Refresh now**, the provider's usage page (**Open claude.ai**, **Open chatgpt.com**, …), **Keep open**, **Settings…** and
**Quit PenguinNotch**. Neither click, nor the tray, asks Claude again while its rate-limit wait runs.

**Appearance → Show notch now** (also in the tray menu) reveals the saved notch
position, including when hidden. Hover mode stays open for five seconds without
changing its keep-open preference. **Meter style** switches accounts, system
meters and stocks between circles and bars. **Size → Custom** supports **75–150%**;
the custom value, Small/Medium/Large preset and hover text size are stored separately.
Hiding and showing providers preserves their places in the saved cell order.

### Scrolling long lists

When the item list is longer than the display, the notch body and its handles
stay on screen and the items become scrollable automatically. Reveal the notch
with **Show notch now** if needed, place the pointer over its items, and use the
**mouse wheel or trackpad**. Left/right notches scroll vertically; top/bottom
notches scroll horizontally and also accept a vertical mouse wheel.

This works with **Circles** and **Bars**. Hover, click and drag reordering follow
the visible items; scrolling does not change the saved order. Move onto a hover
card to scroll its contents separately. Lists that fit on screen do not scroll.
**Appearance → Hover text size** adjusts cards from **80% to 150%** (default **100%**)
independently of notch size.

### Where the notch sits

The notch pins to one edge of one screen. The six-dot grip carries it: hold it, and the four
places it can go are outlined on the screen; release on one and the notch lands there, centred.
**Appearance → Show move handle** hides the grip and preserves an existing hidden choice.
Alt-drag remains available. **Appearance → Edge** picks left, right, top or bottom:
it stands upright on the left and right edges with the hover card opening sideways, and lies flat
on the top and bottom ones with the card opening below or above. **Appearance → Screen**
can follow the main display or remember a particular monitor.

Dragging does both at once: pick the pill up, drop it anywhere, and it snaps to the nearest edge
of the screen it was dropped on — across monitors, and across a change of DPI between them. The
choice is stored as `notch_edge`, `notch_monitor` (the device name, e.g. `\\.\DISPLAY2`) and
`notch_y` (the position along the edge, 0–1) in `config.json`. A monitor that is no longer
attached falls back to the primary one, so unplugging a screen cannot strand the notch off-screen;
**Recentre** centres only the current edge, keeping other edges' positions and the
saved monitor. When an unavailable monitor reconnects, the notch returns to it.

Folded (**Appearance → Show → Show on hover**), the notch rests as a small pill at the edge, in
**Theme**'s colour, with an edge that shows even against a backdrop of that colour.
**Appearance → Adaptive pill**, off unless switched on, makes it follow what is behind it instead:
light over a dark backdrop, black over a light one, the way the iPhone's home indicator does. To tell
which, PenguinNotch reads a thin strip of the screen beside the pill twice a second while it is folded,
and keeps only its average brightness, which is never stored or sent. With the switch off, the notch
open, or Show set to Always show, nothing is read.

**AI subscriptions → Usage limits → Colour transition** keeps solid bands by default (green below 50%, yellow from
50%, red from 70%). **Colour ramp** blends continuously through yellow at 50%.
The folded pill has a contrasting outline in both Light and Dark themes. A native
topmost watchdog restores the notch after other windows disturb its z-order,
without taking focus or fighting an active drag.

### Icons

Provider marks are the SVGs from [`@lobehub/icons-static-svg`](https://github.com/lobehub/lobe-icons)
(MIT), embedded unmodified — see `penguinnotch/glyphs/NOTICE.md`. Drop your own
`claude|codex|cursor|gemini.svg` (or `.png`) into `%APPDATA%\penguinnotch\glyphs\` to override.
The marks remain the trademarks of their owners.

### Translations

Three surfaces draw their own text, so each keeps its own table:

| Surface | Table | Languages today |
|---|---|---|
| Tray menu | `penguinnotch/src/i18n.rs` (`tr`), `penguinnotch/src/traymenu.rs` (`label`) | en · pt-BR · ru · zh · zh-Hant · ja · ko · uk |
| Hover card | `penguinnotch/ui/notch.html` (`TEXT`, `PATTERNS`, `UI`) | en · pt-BR · ru · zh · zh-Hant · ko · uk |
| Settings window | `penguinnotch/ui/settings.html` (`STATIC_TEXT`, `STATUS_TEXT`) | en · pt-BR · ru · zh · zh-Hant · ja · ko · uk |

Missing strings fall back to English; the provider hover card still has no Japanese
table. Korean includes the quota-window labels and the settings controls exercised
by `scripts/test-ko-i18n.cjs` and the settings browser regression.

Keys are the exact English string. A string the Mac also shows should be taken from
`Sources/Localizable.xcstrings` rather than translated afresh, so both platforms word it the same
way. One catalog feeding all three tables is the intended fix; until then a test in `traymenu.rs`
fails if the menu and the card stop naming the same window.

## Layout

```
.
├── penguinnotch/          the Windows app (pill, hover card, settings, providers)
└── penguinnotch-hook/     tiny helper Claude Code calls to report session events
```

A pull request that touches this tree is built and tested; the check is skipped
inside forks until the pull request is opened here.

## Relationship to upstream

This fork is maintained at [pmh10401/PenguinNotch](https://github.com/pmh10401/PenguinNotch).
The Windows port originated in
[Im-Midi/codenotch-windows](https://github.com/Im-Midi/codenotch-windows) and was offered to
Codenotch as its `windows/` tree. Session detection
originated in [Im-Midi/Pac-Man](https://github.com/Im-Midi/Pac-Man) (MIT).

## License

MIT — see `LICENSE`. The original Codenotch design and name belong to the upstream author.
