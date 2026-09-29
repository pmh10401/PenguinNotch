//! Keeping the Windows app up to date, the way Sparkle keeps the Mac one up to date.
//!
//! Checks look at `latest.json` on the newest GitHub release. What they find is offered — a
//! version, Update, Later — and only Update runs the signed installer. Later hides the offer
//! for this session; Settings and a manual check can still bring it back. Automatic checks
//! never download on their own.
//!
//! A check that fails leaves any current offer in place and says so only as a short Settings
//! line. The Mac's updater was hanging on "Checking…" as recently as 1.14.0; an update check
//! is never worth blocking on.

use serde::Serialize;
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

/// What Settings and the notch read. Extra fields stay additive so an older page still works.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Default)]
pub struct UpdateState {
    /// The version on offer, when one is newer than this build — kept after Later.
    pub available: Option<String>,
    /// True only between a check starting and finishing.
    pub checking: bool,
    /// True while the download and install are running.
    pub installing: bool,
    /// Set when the last check or install failed, for the page to show quietly.
    pub message: Option<String>,
    /// Bytes of the installer written so far, once a download has started.
    pub downloaded: Option<u64>,
    /// Total bytes, once the feed names a size.
    pub total: Option<u64>,
    /// Later hid the notch card for this session; `available` remains for Settings.
    pub deferred: bool,
    /// The current offer is the local preview: nothing is fetched and nothing is installed.
    pub preview: bool,
}

const CHECK_FAILED: &str = "Could not check for updates";
const INSTALL_FAILED: &str = "Could not install the update";
const CHECK_TIMEOUT: Duration = Duration::from_secs(45);
/// The plugin copies the builder timeout onto `download_and_install`; 45s is too short for an installer.
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const PROGRESS_STEP: u64 = 256 * 1024;
const UNSET_PUBKEY: &str = "REPLACE_WITH_TAURI_PUBLIC_KEY";

static STATE: Mutex<Option<UpdateState>> = Mutex::new(None);

/// The status lock guards one small struct. Poisoning it would take the About pane down with
/// `unwrap`, which is a steep price for a version string, so take it back and carry on.
fn state() -> std::sync::MutexGuard<'static, Option<UpdateState>> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

fn snapshot() -> UpdateState {
    state().clone().unwrap_or_default()
}

/// Writes the next status and returns it. The lock is dropped before this returns, so the
/// caller can emit or wait on the network without holding it.
fn store(next: UpdateState) -> UpdateState {
    *state() = Some(next.clone());
    next
}

fn notify(app: &AppHandle, next: &UpdateState) {
    let _ = app.emit("update_state", next);
}

fn publish(app: &AppHandle, next: UpdateState) {
    let next = store(next);
    notify(app, &next);
}

/// Whether a real signing key has been configured.
///
/// A build made before the key was generated would otherwise check a feed it can never
/// verify, and report a failure every time for a reason the user can do nothing about.
/// Silence is the right answer there.
fn configured(app: &AppHandle) -> bool {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|u| u.get("pubkey"))
        .and_then(|k| k.as_str())
        .is_some_and(|k| !k.is_empty() && k != UNSET_PUBKEY)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CheckKind {
    Manual,
    Background,
}

enum BeginInstall {
    Busy,
    Preview,
    Ready(UpdateState),
}

fn busy(s: &UpdateState) -> bool {
    s.checking || s.installing
}

/// One check or install at a time. Sets `checking` under the lock and returns the snapshot.
fn claim_check() -> Option<UpdateState> {
    let mut g = state();
    let mut s = g.clone().unwrap_or_default();
    if busy(&s) {
        return None;
    }
    s.checking = true;
    s.message = None;
    *g = Some(s.clone());
    Some(s)
}

fn begin_install() -> BeginInstall {
    let mut g = state();
    let mut s = g.clone().unwrap_or_default();
    if busy(&s) {
        return BeginInstall::Busy;
    }
    if s.preview {
        return BeginInstall::Preview;
    }
    s.installing = true;
    s.checking = false;
    s.deferred = false;
    s.message = None;
    s.downloaded = None;
    s.total = None;
    *g = Some(s.clone());
    BeginInstall::Ready(s)
}

fn apply_check(mut s: UpdateState, kind: CheckKind, result: Result<Option<String>, ()>) -> UpdateState {
    s.checking = false;
    s.installing = false;
    s.downloaded = None;
    s.total = None;
    match result {
        Ok(Some(version)) => {
            let same = s.available.as_ref() == Some(&version);
            let keep_deferred = kind == CheckKind::Background && s.deferred && same;
            s.available = Some(version);
            s.preview = false;
            s.message = None;
            if !keep_deferred {
                s.deferred = false;
            }
            s
        }
        Ok(None) => {
            s.message = None;
            if s.preview {
                s
            } else {
                s.available = None;
                s.deferred = false;
                s
            }
        }
        Err(()) => {
            s.message = Some(CHECK_FAILED.into());
            s
        }
    }
}

fn apply_install_failure(mut s: UpdateState) -> UpdateState {
    s.checking = false;
    s.installing = false;
    s.downloaded = None;
    s.total = None;
    s.message = Some(INSTALL_FAILED.into());
    s
}

fn apply_install_gone(mut s: UpdateState) -> UpdateState {
    s.checking = false;
    s.installing = false;
    s.downloaded = None;
    s.total = None;
    s.available = None;
    s.deferred = false;
    s.preview = false;
    s.message = None;
    s
}

fn dismiss_offer(mut s: UpdateState) -> Option<UpdateState> {
    if busy(&s) || s.available.is_none() {
        return None;
    }
    s.deferred = true;
    Some(s)
}

/// The version after this one, for the preview to name — same rule as the Mac.
fn next_version(after: &str) -> String {
    let mut parts: Vec<i32> = after.split('.').map(|p| p.parse().unwrap_or(0)).collect();
    while parts.len() < 3 {
        parts.push(0);
    }
    parts[1] += 1;
    parts[2] = 0;
    parts.into_iter().map(|n| n.to_string()).collect::<Vec<_>>().join(".")
}

fn preview_offer(current: &str, s: UpdateState) -> UpdateState {
    if busy(&s) {
        return s;
    }
    UpdateState {
        available: Some(next_version(current)),
        preview: true,
        deferred: false,
        checking: false,
        installing: false,
        message: None,
        downloaded: None,
        total: None,
    }
}

/// Emit the first chunk, completion, and otherwise about every 2% or 256 KiB.
fn progress_should_emit(downloaded: u64, total: Option<u64>, last: u64) -> bool {
    if downloaded <= last {
        return false;
    }
    if last == 0 {
        return true;
    }
    let step = match total {
        Some(t) if t > 0 => (t / 50).max(PROGRESS_STEP),
        _ => PROGRESS_STEP,
    };
    downloaded >= last.saturating_add(step) || total.is_some_and(|t| t > 0 && downloaded >= t)
}

fn automatic_enabled(app: &AppHandle) -> bool {
    app.state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .automatic_updates
}

async fn check_feed(
    app: &AppHandle,
    timeout: Duration,
) -> Result<Option<tauri_plugin_updater::Update>, tauri_plugin_updater::Error> {
    app.updater_builder().timeout(timeout).build()?.check().await
}

fn fetch_update(app: &AppHandle) -> Result<Option<tauri_plugin_updater::Update>, tauri_plugin_updater::Error> {
    tauri::async_runtime::block_on(check_feed(app, CHECK_TIMEOUT))
}

fn start_check(app: AppHandle, kind: CheckKind) {
    if !configured(&app) {
        return;
    }
    let Some(next) = claim_check() else {
        return;
    };
    notify(&app, &next);
    std::thread::spawn(move || {
        let result = match fetch_update(&app) {
            Ok(Some(update)) => {
                crate::applog(&format!("updater: {} is available", update.version));
                Ok(Some(update.version))
            }
            Ok(None) => {
                crate::applog("updater: this is the newest release");
                Ok(None)
            }
            Err(e) => {
                crate::applog(&format!("updater: check failed ({e})"));
                Err(())
            }
        };
        let next = {
            let mut g = state();
            let next = apply_check(g.clone().unwrap_or_default(), kind, result);
            *g = Some(next.clone());
            next
        };
        notify(&app, &next);
    });
}

#[tauri::command]
pub fn get_update_state() -> UpdateState {
    snapshot()
}

/// Looks for a newer release. Answers immediately; the result arrives as `update_state`.
///
/// A press in Settings is always allowed, even with automatic checks off. Nothing here
/// touches the notch itself.
#[tauri::command]
pub fn check_for_update(app: AppHandle) {
    start_check(app, CheckKind::Manual);
}

/// Downloads the newer installer and runs it. The app is replaced and restarted by NSIS.
/// Preview offers never reach the plugin.
#[tauri::command]
pub fn install_update(app: AppHandle) {
    if !configured(&app) {
        return;
    }
    match begin_install() {
        BeginInstall::Busy | BeginInstall::Preview => return,
        BeginInstall::Ready(next) => notify(&app, &next),
    }
    std::thread::spawn(move || {
        let outcome = tauri::async_runtime::block_on(async {
            // Same 45s feed bound as a check. `?` keeps a transport failure as an install
            // error; only `Ok(None)` means there is nothing to install. The plugin copies
            // this timeout onto the download, so stretch it before `download_and_install`.
            let Some(mut update) = check_feed(&app, CHECK_TIMEOUT).await? else {
                return Ok::<bool, tauri_plugin_updater::Error>(false);
            };
            update.timeout = Some(DOWNLOAD_TIMEOUT);
            let mut downloaded = 0_u64;
            let mut last_emit = 0_u64;
            // The signature is checked against the public key in tauri.conf.json before a
            // single byte is run: an unsigned or altered installer never reaches the disk.
            update
                .download_and_install(
                    |chunk, total| {
                        downloaded = downloaded.saturating_add(chunk as u64);
                        if !progress_should_emit(downloaded, total, last_emit) {
                            return;
                        }
                        last_emit = downloaded;
                        let next = {
                            let mut g = state();
                            let mut s = g.clone().unwrap_or_default();
                            if !s.installing {
                                return;
                            }
                            s.downloaded = Some(downloaded);
                            s.total = total;
                            *g = Some(s.clone());
                            s
                        };
                        notify(&app, &next);
                    },
                    || {},
                )
                .await?;
            Ok(true)
        });
        match outcome {
            Ok(true) => crate::applog("updater: installed, restarting"),
            Ok(false) => {
                let next = apply_install_gone(snapshot());
                publish(&app, next);
            }
            Err(e) => {
                crate::applog(&format!("updater: install failed ({e})"));
                let next = apply_install_failure(snapshot());
                publish(&app, next);
            }
        }
    });
}

/// Later: hide the notch card for this session. The version stays for Settings and reoffer.
#[tauri::command]
pub fn dismiss_update(app: AppHandle) {
    let next = {
        let mut g = state();
        match dismiss_offer(g.clone().unwrap_or_default()) {
            Some(next) => {
                *g = Some(next.clone());
                next
            }
            None => return,
        }
    };
    notify(&app, &next);
}

/// Put the current offer back in the notch. A preview is local; a real pending version re-checks.
#[tauri::command]
pub fn reoffer_update(app: AppHandle) {
    if snapshot().preview {
        preview_update(app);
    } else {
        check_for_update(app);
    }
}

/// The update card as a real offer would bring it up, for a version that is not there.
#[tauri::command]
pub fn preview_update(app: AppHandle) {
    let current = app.package_info().version.to_string();
    let next = {
        let mut g = state();
        let s = g.clone().unwrap_or_default();
        if busy(&s) {
            return;
        }
        let next = preview_offer(&current, s);
        *g = Some(next.clone());
        next
    };
    notify(&app, &next);
}

#[tauri::command]
pub fn get_automatic_updates(app: AppHandle) -> bool {
    automatic_enabled(&app)
}

/// Persist the preference first; only then keep it in memory. A failed write leaves the
/// previous value, and a manual check still works either way.
#[tauri::command]
pub fn set_automatic_updates(app: AppHandle, enabled: bool) -> Result<bool, String> {
    {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap_or_else(|e| e.into_inner());
        let mut next = cfg.clone();
        next.automatic_updates = enabled;
        crate::config::try_save(&next)?;
        *cfg = next;
    }
    let _ = app.emit("automatic_updates", enabled);
    Ok(enabled)
}

/// First check twenty seconds after launch, then once a day, only while automatic checks
/// are on. Delayed rather than immediate: the first seconds belong to reading usage and
/// drawing the notch, and an update that has waited since the last release can wait twenty
/// more seconds.
pub fn check_on_launch(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(20));
        loop {
            if automatic_enabled(&app) {
                start_check(app.clone(), CheckKind::Background);
            }
            std::thread::sleep(Duration::from_secs(24 * 60 * 60));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST: Mutex<()> = Mutex::new(());

    fn hold() -> std::sync::MutexGuard<'static, ()> {
        TEST.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn reset() {
        *state() = None;
    }

    #[test]
    fn claim_rejects_concurrent_work() {
        let _t = hold();
        reset();
        let barrier = std::sync::Barrier::new(8);
        let claimed = std::sync::atomic::AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..8 {
                scope.spawn(|| {
                    barrier.wait();
                    if claim_check().is_some() {
                        claimed.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    }
                });
            }
        });
        assert_eq!(claimed.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(snapshot().checking);
        assert!(matches!(begin_install(), BeginInstall::Busy));
        reset();
        assert!(matches!(begin_install(), BeginInstall::Ready(_)));
        assert!(claim_check().is_none());
        assert!(matches!(begin_install(), BeginInstall::Busy));
    }

    #[test]
    fn check_outcomes_keep_or_clear_the_offer() {
        let found = apply_check(UpdateState::default(), CheckKind::Manual, Ok(Some("1.22.0".into())));
        assert_eq!(found.available.as_deref(), Some("1.22.0"));
        assert!(!found.checking);
        assert!(!found.deferred);
        assert!(found.message.is_none());

        let mut offered = found.clone();
        offered.checking = true;
        let up_to_date = apply_check(offered, CheckKind::Manual, Ok(None));
        assert!(up_to_date.available.is_none());
        assert!(!up_to_date.checking);

        let mut known = found.clone();
        known.checking = true;
        let failed = apply_check(known, CheckKind::Background, Err(()));
        assert_eq!(failed.available.as_deref(), Some("1.22.0"));
        assert!(!failed.checking);
        assert!(!failed.installing);
        assert_eq!(failed.message.as_deref(), Some(CHECK_FAILED));
    }

    #[test]
    fn later_hides_the_same_version_until_manual_or_newer() {
        let offered = apply_check(UpdateState::default(), CheckKind::Background, Ok(Some("1.22.0".into())));
        let later = dismiss_offer(offered).expect("an available offer can be put off");
        assert!(later.deferred);
        assert_eq!(later.available.as_deref(), Some("1.22.0"));

        let again = apply_check(later.clone(), CheckKind::Background, Ok(Some("1.22.0".into())));
        assert!(again.deferred);
        assert_eq!(again.available.as_deref(), Some("1.22.0"));

        let manual = apply_check(later.clone(), CheckKind::Manual, Ok(Some("1.22.0".into())));
        assert!(!manual.deferred);
        assert_eq!(manual.available.as_deref(), Some("1.22.0"));

        let newer = apply_check(later, CheckKind::Background, Ok(Some("1.23.0".into())));
        assert!(!newer.deferred);
        assert_eq!(newer.available.as_deref(), Some("1.23.0"));
    }

    #[test]
    fn preview_cannot_begin_a_download() {
        let _t = hold();
        reset();
        let preview = preview_offer("1.21.2", UpdateState::default());
        assert_eq!(preview.available.as_deref(), Some("1.22.0"));
        assert!(preview.preview);
        assert!(!preview.installing);
        store(preview);
        assert!(matches!(begin_install(), BeginInstall::Preview));
        let s = snapshot();
        assert!(s.preview);
        assert!(!s.installing);
        assert!(!s.checking);
        assert_eq!(s.available.as_deref(), Some("1.22.0"));
    }

    #[test]
    fn preview_survives_a_check_that_finds_nothing() {
        let preview = preview_offer("1.18.3", UpdateState::default());
        let still = apply_check(preview, CheckKind::Background, Ok(None));
        assert!(still.preview);
        assert_eq!(still.available.as_deref(), Some("1.19.0"));
    }

    #[test]
    fn install_failure_keeps_the_version_and_clears_busy() {
        let failed = apply_install_failure(UpdateState {
            available: Some("1.22.0".into()),
            installing: true,
            downloaded: Some(12),
            total: Some(100),
            ..Default::default()
        });
        assert_eq!(failed.available.as_deref(), Some("1.22.0"));
        assert!(!failed.installing);
        assert!(!failed.checking);
        assert_eq!(failed.downloaded, None);
        assert_eq!(failed.total, None);
        assert_eq!(failed.message.as_deref(), Some(INSTALL_FAILED));
        assert_ne!(failed.message.as_deref(), Some(CHECK_FAILED));
    }

    #[test]
    fn install_failure_path_snapshots_then_stores_without_reentry() {
        let _t = hold();
        reset();
        store(UpdateState {
            available: Some("1.22.0".into()),
            installing: true,
            ..Default::default()
        });
        let next = apply_install_failure(snapshot());
        store(next);
        let s = snapshot();
        assert_eq!(s.available.as_deref(), Some("1.22.0"));
        assert!(!s.installing);
        let _g = state();
        assert_eq!(_g.as_ref().and_then(|s| s.available.as_deref()), Some("1.22.0"));
    }

    #[test]
    fn store_releases_the_lock_before_notify() {
        let _t = hold();
        reset();
        let published = store(UpdateState { checking: true, ..Default::default() });
        assert!(published.checking);
        let again = state();
        assert!(again.as_ref().is_some_and(|s| s.checking));
    }

    #[test]
    fn dismiss_is_ignored_while_busy_or_empty() {
        assert!(dismiss_offer(UpdateState::default()).is_none());
        assert!(dismiss_offer(UpdateState { checking: true, available: Some("1.0.0".into()), ..Default::default() }).is_none());
        assert!(dismiss_offer(UpdateState { installing: true, available: Some("1.0.0".into()), ..Default::default() }).is_none());
    }

    #[test]
    fn progress_emits_sparsely() {
        assert!(progress_should_emit(1, Some(10_000_000), 0));
        assert!(!progress_should_emit(100, Some(10_000_000), 1));
        assert!(progress_should_emit(256 * 1024 + 1, Some(10_000_000), 1));
        assert!(progress_should_emit(10_000_000, Some(10_000_000), 256 * 1024));
        assert!(!progress_should_emit(100, None, 1));
        assert!(progress_should_emit(256 * 1024 + 1, None, 1));
        assert!(!progress_should_emit(10, Some(100), 10));
    }

    #[test]
    fn next_version_matches_the_mac() {
        assert_eq!(next_version("1.18.0"), "1.19.0");
        assert_eq!(next_version("1.18.3"), "1.19.0");
        assert_eq!(next_version("2"), "2.1.0");
    }
}
