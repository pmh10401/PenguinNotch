# PenguinNotch for Windows

A Windows port based on [vinzdg's Codenotch](https://github.com/vinzdg/codenotch) — the usage notch that
sits on the edge of your screen with **AI usage, system monitoring, stock quotes,
charts and local forecast history**.

Same design language as the macOS original (inverse-rounded pill, colour-graded rings,
hover card with per-window bars), rebuilt for Windows in Rust + Tauri 2 / WebView2.
The providers and stock calculations follow the macOS app's behaviour and wire
formats, using native Windows storage and system APIs.

**Latest stable release: [1.20.4](https://github.com/pmh10401/PenguinNotch/releases/tag/v1.20.4).**
Overflowing notch items now scroll with the mouse wheel or trackpad on every edge,
in both Circles and Bars. See [Scrolling long lists](#scrolling-long-lists).

## What it shows

| Cell | Source | How it reads it |
|---|---|---|
| **Claude** | `GET https://api.anthropic.com/api/oauth/usage` with the token Claude Code keeps in `~/.claude/.credentials.json` | Session / weekly windows, 429 back-off with a persisted deadline, stale readings dimmed with their age. Renews that token by running the standalone `claude -p` shortly before it expires (Claude Code inside the desktop app never writes this file), and never sends an expired one. A thin arc spins inside the ring while a Claude session is working, and pulses amber when one is waiting on you (Claude Code hooks + transcript watcher, desktop app included). |
| **Codex** | The local Codex sign-in in `~/.codex/auth.json` (read only, never refreshed), falling back to the newest session snapshot | Live primary/secondary windows (5h + weekly on paid plans, a monthly window on free) while Codex is signed in; Spark and Code review appear on the hover card when Codex reports them; otherwise the last snapshot, marked stale by its own timestamp. |
| **Cursor** | The editor's own session from `state.vscdb` → `cursor.com/api/usage-summary` | Included usage / API usage / on-demand, reset at billing-cycle end. Nothing to sign into: it borrows the editor's session, so there is only ever one account. |
| **Grok** | The Grok CLI's own session in `~/.grok/auth.json` (read only, never refreshed) → `cli-chat-proxy.grok.com/v1/billing?format=credits`, the endpoint that CLI's own `/usage` asks | The weekly Grok Build allowance, with the account on the hover card. Only a session minted by `auth.x.ai` is used — the file can also hold a customer IdP token meant for that customer's private proxy. A fresh weekly period reads 0 %, not "unmetered". |
| **Antigravity** | Official `agy` CLI `/usage` print when installed; otherwise the existing local `language_server` bridge, Google Cloud Code API, or transcript model count | Official four quota rows (Gemini & Claude/GPT 5h/weekly) without running the full IDE. When CLI is absent, falls back to legacy local bridge/API. |

Providers that are not installed simply do not get a cell.

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
every 30 seconds on a separate worker so a slow disk does not stall the meters.
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
are in Settings → System. Hiding one meter does not stop the others; turning off
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

Enable **Stock forecasts** to estimate watchlist stocks without account access
or owning them (1.19.1). **Watchlist only** keeps account requests off. To include
actual holdings too, explicitly load accounts and select one; failed account reads
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

Focused checks from `windows/`:

```powershell
node --test scripts/test-stocks.cjs
node scripts/test-widgets.cjs
node scripts/check-ui-scripts.mjs
cargo test --locked
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

PenguinNotch looks for a newer release about twenty seconds after it starts, and again whenever
**Check for updates** is pressed in Settings → General. The feed is `latest.json` on the newest
release, written by the Windows Package workflow beside the installer it describes, so publishing
a release is the whole of shipping an update.

Nothing about this nags. A check that fails — no network, an unreachable feed — leaves the app
as it was and says so only next to the version. There is no dialogue and no badge.

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

The notch pins to one edge of one screen. The arc above the pill carries it: hold it, and the four
places it can go are outlined on the screen; release on one and the notch lands there, centred.
**Appearance → Show move handle** hides that arc. **Appearance → Edge** picks left, right, top or bottom:
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

### Icons

Provider marks are the SVGs from [`@lobehub/icons-static-svg`](https://github.com/lobehub/lobe-icons)
(MIT), embedded unmodified — see `penguinnotch/glyphs/NOTICE.md`. Drop your own
`claude|codex|cursor|gemini.svg` (or `.png`) into `%APPDATA%\penguinnotch\glyphs\` to override.
The marks remain the trademarks of their owners.

### Translations

Three surfaces draw their own text, so each keeps its own table:

| Surface | Table | Languages today |
|---|---|---|
| Tray menu | `penguinnotch/src/i18n.rs` (`tr`), `penguinnotch/src/traymenu.rs` (`label`) | en · ru · zh · ja · ko · uk |
| Hover card | `penguinnotch/ui/notch.html` (`TEXT`, `PATTERNS`, `UI`) | en · ru · zh |
| Settings window | `penguinnotch/ui/settings.html` (`STATIC_TEXT`, `STATUS_TEXT`) | en · ru · zh · ja · ko |

Help is welcome on the gaps, which fall back to English rather than breaking anything:

- the hover card has no Japanese, Korean or Ukrainian;
- the settings window has no Ukrainian, although the tray menu and the language picker have had it
  since Ukrainian was added;
- Korean has none of the window names the Mac's catalog carries — `Current session`, `Weekly limit`,
  `Monthly limit`, `5-hour Limit`, `Included usage`, `API usage` — because the catalog has no Korean
  to take them from.

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

This port follows the upstream design and provider semantics. It is developed at
[Im-Midi/penguinnotch-windows](https://github.com/Im-Midi/penguinnotch-windows) and offered to the
upstream project as its `windows/` tree; the two are kept in sync. Session detection
originated in [Im-Midi/Pac-Man](https://github.com/Im-Midi/Pac-Man) (MIT).

## License

MIT — see `LICENSE`. The PenguinNotch design and name belong to the upstream author.
