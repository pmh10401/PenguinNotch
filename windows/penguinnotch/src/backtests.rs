//! Public replay archive only. No transport, credentials, model calls or legacy history writes.
use chrono::{Datelike, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::File;
#[cfg(windows)]
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

type Result<T> = std::result::Result<T, String>;
const LIMIT: usize = 2 * 1024 * 1024;
const BASIS: &str = "provider-adjusted-as-fetched";
const MODELS: [&str; 3] = [
    "GBM daily zero drift v1 / replay v1",
    "GBM 1m zero drift v1 / replay v1",
    "GBM 10m zero drift v1 / replay v1",
];
static LOCK: Mutex<()> = Mutex::new(());
static TEMP: AtomicU64 = AtomicU64::new(0);
fn check(ok: bool) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err("Invalid replay archive".into())
    }
}
fn io<T>(r: std::io::Result<T>) -> Result<T> {
    r.map_err(|e| format!("Replay archive IO: {e}"))
}
// Option fields must be present as JSON null or a value; serde's ordinary Option also accepts missing keys.
fn nullable<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    d: D,
) -> std::result::Result<Option<T>, D::Error> {
    Option::deserialize(d)
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RunID(String);
impl<'de> Deserialize<'de> for RunID {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        if !uuid(&s) {
            return Err(serde::de::Error::custom("Invalid runID"));
        }
        Ok(Self(s.to_ascii_lowercase()))
    }
}
fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
fn case_id<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<String, D::Error> {
    let s = String::deserialize(d)?;
    if !safe_case(&s) {
        return Err(serde::de::Error::custom("Invalid caseID"));
    }
    Ok(s)
}
#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum ArchiveRequest {
    List {},
    Create {
        manifest: Manifest,
    },
    LoadManifest {
        #[serde(rename = "runID")]
        run_id: RunID,
    },
    SaveCase {
        #[serde(rename = "runID")]
        run_id: RunID,
        body: String,
    },
    LoadCase {
        #[serde(rename = "runID")]
        run_id: RunID,
        #[serde(rename = "caseID", deserialize_with = "case_id")]
        case_id: String,
    },
    SaveResult {
        #[serde(rename = "runID")]
        run_id: RunID,
        body: String,
    },
    LoadResult {
        #[serde(rename = "runID")]
        run_id: RunID,
        #[serde(rename = "caseID", deserialize_with = "case_id")]
        case_id: String,
    },
    UpdateProgress {
        #[serde(rename = "runID")]
        run_id: RunID,
        entries: Vec<Entry>,
        status: Status,
    },
}
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ArchiveReply {
    Manifests {
        manifests: Vec<Manifest>,
    },
    Manifest {
        manifest: Manifest,
    },
    Body {
        body: Option<String>,
        sha256: Option<String>,
    },
    Receipt {
        sha256: String,
    },
    Empty,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Ready,
    Running,
    Paused,
    Completed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryStatus {
    Pending,
    Saved,
    Skipped,
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    version: u32,
    #[serde(rename = "runID")]
    run_id: RunID,
    created_at: i64,
    collection_started_at: i64,
    #[serde(deserialize_with = "nullable")]
    collection_completed_at: Option<i64>,
    protocol_version: String,
    code_version: String,
    price_basis: String,
    cutoff_minutes: u32,
    sessions: usize,
    symbols: Vec<String>,
    models: Vec<String>,
    status: Status,
    cases: Vec<Entry>,
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Entry {
    #[serde(rename = "caseID")]
    case_id: String,
    #[serde(rename = "stockID")]
    stock_id: String,
    trading_day: String,
    status: EntryStatus,
    #[serde(rename = "inputSHA256", deserialize_with = "nullable")]
    input_sha256: Option<String>,
    #[serde(rename = "resultSHA256", deserialize_with = "nullable")]
    result_sha256: Option<String>,
    #[serde(deserialize_with = "nullable")]
    reason: Option<String>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    version: u32,
    #[serde(rename = "caseID")]
    case_id: String,
    #[serde(rename = "stockID")]
    stock_id: String,
    market: String,
    currency: String,
    trading_day: String,
    session_start: i64,
    session_end: i64,
    cutoff: i64,
    input_bar_end: i64,
    input_price: f64,
    previous_close: f64,
    price_basis: String,
    daily_closes: Vec<Close>,
    minutes: Vec<Minute>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Close {
    date: i64,
    price: f64,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Minute {
    end: i64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    version: u32,
    input: Input,
    target: Target,
    source: Source,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Target {
    actual_close: f64,
    candle_at: i64,
    fetched_at: i64,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Source {
    provider: String,
    calendar_fetched_at: i64,
    daily_fetched_at: i64,
    minute_pages: Vec<Page>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Page {
    before: String,
    #[serde(deserialize_with = "nullable")]
    next_before: Option<String>,
    fetched_at: i64,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Calculation {
    version: u32,
    #[serde(rename = "caseID")]
    case_id: String,
    #[serde(rename = "inputSHA256")]
    input_sha256: String,
    calculation_version: String,
    computed_at: i64,
    outcomes: Vec<Outcome>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Outcome {
    model: String,
    status: String,
    #[serde(deserialize_with = "nullable")]
    reason: Option<String>,
    #[serde(deserialize_with = "nullable")]
    forecast: Option<Forecast>,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Forecast {
    expected_close: f64,
    lower_close: f64,
    upper_close: f64,
    rise_probability: f64,
    observations: usize,
}
fn decode<T: for<'de> Deserialize<'de>>(body: &[u8]) -> Result<T> {
    check(body.len() <= LIMIT)?;
    serde_json::from_slice(body).map_err(|_| "Invalid replay JSON".into())
}
fn hash(body: &[u8]) -> String {
    format!("{:x}", Sha256::digest(body))
}
fn time(t: i64) -> bool {
    (0..=253_402_300_799_000).contains(&t)
}
fn positive(n: f64) -> bool {
    n.is_finite() && n > 0.0
}
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn stock(id: &str) -> bool {
    if let Some(s) = id.strip_prefix("kr:") {
        s.len() == 6
            && s.bytes()
                .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase())
    } else if let Some(s) = id.strip_prefix("us:") {
        !s.is_empty()
            && s.len() <= 10
            && s.as_bytes()[0].is_ascii_uppercase()
            && !s.contains("..")
            && s.bytes()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || b".-".contains(&c))
    } else {
        false
    }
}
fn day(s: &str) -> bool {
    s.len() == 10
        && NaiveDate::parse_from_str(s, "%Y-%m-%d")
            .map(|d| d.to_string() == s)
            .unwrap_or(false)
}
fn identity(id: &str, sid: &str, d: &str) -> bool {
    stock(sid) && day(d) && id == format!("{}_{}", sid.replace(':', "_"), d)
}
fn safe_case(id: &str) -> bool {
    let parts: Vec<_> = id.split('_').collect();
    parts.len() == 3 && identity(id, &format!("{}:{}", parts[0], parts[1]), parts[2])
}
fn cursor(s: &str) -> bool {
    s.bytes()
        .all(|b| b.is_ascii_digit() || b"T:.+-Z".contains(&b))
        && s.as_bytes().get(10) == Some(&b'T')
        && s.as_bytes().get(13) == Some(&b':')
        && s.as_bytes().get(16) == Some(&b':')
        && chrono::DateTime::parse_from_rfc3339(s)
            .map(|d| d.timestamp_subsec_nanos() < 1_000_000_000)
            .unwrap_or(false)
}
// Same post-1970 Eastern/Seoul rules as stocks::market_day (private to that module).
fn market_day(t: i64, market: &str) -> Result<String> {
    let utc = Utc
        .timestamp_millis_opt(t)
        .single()
        .ok_or("Invalid replay time")?;
    let year = utc.year();
    let sunday = |m: u32, n: u32| {
        let first = NaiveDate::from_ymd_opt(year, m, 1).unwrap();
        first
            .with_day(1 + (7 - first.weekday().num_days_from_sunday()) % 7 + (n - 1) * 7)
            .unwrap()
    };
    let last_sunday = |m: u32| {
        let last = NaiveDate::from_ymd_opt(year, m, if m == 4 { 30 } else { 31 }).unwrap();
        last.with_day(last.day() - last.weekday().num_days_from_sunday())
            .unwrap()
    };
    let offset = if market == "kr" {
        let dst = (1987..=1988).contains(&year)
            && utc.naive_utc()
                >= sunday(5, 2)
                    .pred_opt()
                    .unwrap()
                    .and_hms_opt(17, 0, 0)
                    .unwrap()
            && utc.naive_utc()
                < sunday(10, 2)
                    .pred_opt()
                    .unwrap()
                    .and_hms_opt(17, 0, 0)
                    .unwrap();
        if dst {
            36000
        } else {
            32400
        }
    } else {
        let start = if year >= 2007 {
            sunday(3, 2)
        } else if year == 1974 {
            NaiveDate::from_ymd_opt(year, 1, 6).unwrap()
        } else if year == 1975 {
            NaiveDate::from_ymd_opt(year, 2, 23).unwrap()
        } else if year >= 1987 {
            sunday(4, 1)
        } else {
            last_sunday(4)
        };
        let end = if year >= 2007 {
            sunday(11, 1)
        } else {
            last_sunday(10)
        };
        if utc.naive_utc() >= start.and_hms_opt(7, 0, 0).unwrap()
            && utc.naive_utc() < end.and_hms_opt(6, 0, 0).unwrap()
        {
            -14400
        } else {
            -18000
        }
    };
    utc.checked_add_signed(chrono::Duration::seconds(offset))
        .map(|d| d.date_naive().to_string())
        .ok_or("Invalid replay date".into())
}
impl Manifest {
    fn validate(&self) -> Result<()> {
        check(
            self.version == 1
                && uuid(&self.run_id.0)
                && self.protocol_version == "replay-v1"
                && self.price_basis == BASIS
                && self.cutoff_minutes == 60
                && [20, 60, 120].contains(&self.sessions)
                && time(self.created_at)
                && time(self.collection_started_at)
                && self.created_at <= self.collection_started_at
                && self
                    .collection_completed_at
                    .is_none_or(|t| time(t) && t >= self.collection_started_at)
                && (self.status == Status::Completed) == self.collection_completed_at.is_some()
                && !self.code_version.is_empty()
                && self.code_version.len() <= 128
                && !self.symbols.is_empty()
                && self.symbols.len() <= 30
                && self.symbols.iter().all(|s| stock(s))
                && unique(&self.symbols)
                && !self.models.is_empty()
                && unique(&self.models)
                && self.models.iter().all(|m| MODELS.contains(&m.as_str()))
                && self.cases.len() <= self.symbols.len() * self.sessions
                && unique(
                    &self
                        .cases
                        .iter()
                        .map(|e| e.case_id.clone())
                        .collect::<Vec<_>>(),
                )
                && self
                    .cases
                    .iter()
                    .map(|e| &e.trading_day)
                    .collect::<HashSet<_>>()
                    .len()
                    <= self.sessions,
        )?;
        for e in &self.cases {
            check(
                identity(&e.case_id, &e.stock_id, &e.trading_day)
                    && self.symbols.contains(&e.stock_id)
                    && e.input_sha256.as_deref().is_none_or(digest)
                    && e.result_sha256.as_deref().is_none_or(digest)
                    && e.reason
                        .as_ref()
                        .is_none_or(|s| !s.is_empty() && s.len() <= 256),
            )?;
            check(match e.status {
                EntryStatus::Pending => {
                    e.input_sha256.is_none() && e.result_sha256.is_none() && e.reason.is_none()
                }
                EntryStatus::Saved => e.input_sha256.is_some() && e.reason.is_none(),
                EntryStatus::Skipped => {
                    e.input_sha256.is_none() && e.result_sha256.is_none() && e.reason.is_some()
                }
            })?;
        }
        check(
            self.status != Status::Completed
                || self.cases.iter().all(|e| e.status != EntryStatus::Pending),
        )
    }
}
fn unique(values: &[String]) -> bool {
    values.iter().collect::<HashSet<_>>().len() == values.len()
}
impl Case {
    fn validate(&self) -> Result<()> {
        let i = &self.input;
        check(
            self.version == 1
                && i.version == 1
                && identity(&i.case_id, &i.stock_id, &i.trading_day)
                && i.stock_id.starts_with(&format!("{}:", i.market))
                && i.currency == if i.market == "kr" { "KRW" } else { "USD" }
                && i.price_basis == BASIS
                && [i.session_start, i.session_end, i.cutoff, i.input_bar_end]
                    .into_iter()
                    .all(time)
                && i.session_end - i.session_start > 3_600_000
                && i.cutoff == i.session_end - 3_600_000
                && i.input_bar_end <= i.cutoff
                && i.cutoff - i.input_bar_end <= 120_000
                && positive(i.input_price)
                && positive(i.previous_close)
                && i.daily_closes.len() <= 61
                && !i.minutes.is_empty()
                && i.minutes.len() <= 1400,
        )?;
        check(
            market_day(i.session_start, &i.market)? == i.trading_day
                && market_day(i.session_end - 1, &i.market)? == i.trading_day,
        )?;
        let mut previous: Option<String> = None;
        for c in &i.daily_closes {
            check(time(c.date) && positive(c.price))?;
            let date = market_day(c.date, &i.market)?;
            check(date < i.trading_day && previous.as_ref().is_none_or(|p| p > &date))?;
            previous = Some(date);
        }
        check(
            i.daily_closes
                .first()
                .is_none_or(|c| c.price == i.previous_close),
        )?;
        for (n, b) in i.minutes.iter().enumerate() {
            check(
                time(b.end)
                    && b.end - 60_000 >= i.session_start
                    && b.end <= i.cutoff
                    && (n == 0 || i.minutes[n - 1].end < b.end)
                    && [b.open, b.high, b.low, b.close].into_iter().all(positive)
                    && b.volume.is_finite()
                    && b.volume >= 0.0
                    && b.high >= b.open.max(b.close)
                    && b.low <= b.open.min(b.close),
            )?;
        }
        let last = i.minutes.last().unwrap();
        let t = &self.target;
        let s = &self.source;
        check(
            last.end == i.input_bar_end
                && last.close == i.input_price
                && positive(t.actual_close)
                && [
                    t.candle_at,
                    t.fetched_at,
                    s.calendar_fetched_at,
                    s.daily_fetched_at,
                ]
                .into_iter()
                .all(time)
                && t.fetched_at >= i.session_end
                && market_day(t.candle_at, &i.market)? == i.trading_day
                && s.provider == "toss"
                && s.minute_pages.len() <= 8
                && s.minute_pages.iter().all(|p| {
                    cursor(&p.before)
                        && p.next_before.as_deref().is_none_or(cursor)
                        && time(p.fetched_at)
                }),
        )
    }
}
impl Calculation {
    fn validate(&self) -> Result<()> {
        check(
            self.version == 1
                && safe_case(&self.case_id)
                && digest(&self.input_sha256)
                && self.calculation_version == "replay-v1"
                && time(self.computed_at)
                && !self.outcomes.is_empty()
                && self.outcomes.len() <= 3
                && unique(
                    &self
                        .outcomes
                        .iter()
                        .map(|o| o.model.clone())
                        .collect::<Vec<_>>(),
                ),
        )?;
        for o in &self.outcomes {
            check(MODELS.contains(&o.model.as_str()))?;
            if o.status == "forecast" {
                let f = o.forecast.as_ref().ok_or("Missing replay forecast")?;
                check(
                    o.reason.is_none()
                        && [f.expected_close, f.lower_close, f.upper_close]
                            .into_iter()
                            .all(positive)
                        && f.lower_close <= f.expected_close
                        && f.expected_close <= f.upper_close
                        && f.rise_probability.is_finite()
                        && (0.0..=1.0).contains(&f.rise_probability)
                        && (10..=1399).contains(&f.observations)
                        && (!o.model.contains("daily") || f.observations == 60),
                )?;
            } else {
                check(
                    o.status == "skipped"
                        && o.forecast.is_none()
                        && o.reason.as_deref()
                            == Some(if o.model.contains("daily") {
                                "insufficient_daily_history"
                            } else {
                                "insufficient_intraday_history"
                            }),
                )?;
            }
        }
        Ok(())
    }
}

// Native directory handles keep every child operation anchored when a path is swapped.
struct Directory {
    file: File,
    path: PathBuf,
    #[cfg(windows)]
    _parents: Vec<File>,
}
#[cfg(unix)]
mod posix {
    use super::*;
    use std::ffi::{c_char, c_int, c_void, CStr, CString};
    use std::os::fd::{AsRawFd, FromRawFd};
    #[cfg(target_os = "macos")]
    pub const DIRECTORY: i32 = 0x100000;
    #[cfg(not(target_os = "macos"))]
    pub const DIRECTORY: i32 = 0x10000;
    #[cfg(target_os = "macos")]
    const NOFOLLOW: i32 = 0x100;
    #[cfg(not(target_os = "macos"))]
    const NOFOLLOW: i32 = 0x20000;
    #[cfg(target_os = "macos")]
    const CREATE: i32 = 0x200;
    #[cfg(not(target_os = "macos"))]
    const CREATE: i32 = 0x40;
    #[cfg(target_os = "macos")]
    const EXCL: i32 = 0x800;
    #[cfg(not(target_os = "macos"))]
    const EXCL: i32 = 0x80;
    #[cfg(target_os = "macos")]
    const NONBLOCK: i32 = 4;
    #[cfg(not(target_os = "macos"))]
    const NONBLOCK: i32 = 0x800;
    #[cfg(target_os = "macos")]
    const CLOEXEC: i32 = 0x1000000;
    #[cfg(not(target_os = "macos"))]
    const CLOEXEC: i32 = 0x80000;
    unsafe extern "C" {
        fn openat(fd: c_int, name: *const c_char, flags: c_int, ...) -> c_int;
        fn mkdirat(fd: c_int, name: *const c_char, mode: u32) -> c_int;
        #[cfg(target_os = "macos")]
        fn renameatx_np(
            from: c_int,
            source: *const c_char,
            to: c_int,
            target: *const c_char,
            flags: u32,
        ) -> c_int;
        #[cfg(not(target_os = "macos"))]
        fn renameat2(
            from: c_int,
            source: *const c_char,
            to: c_int,
            target: *const c_char,
            flags: u32,
        ) -> c_int;
        fn renameat(from: c_int, source: *const c_char, to: c_int, target: *const c_char) -> c_int;
        fn unlinkat(fd: c_int, name: *const c_char, flags: c_int) -> c_int;
        fn fdopendir(fd: c_int) -> *mut c_void;
        fn readdir(dir: *mut c_void) -> *mut Dirent;
        fn closedir(dir: *mut c_void) -> c_int;
        #[cfg(target_os = "macos")]
        fn __error() -> *mut c_int;
        #[cfg(not(target_os = "macos"))]
        fn __errno_location() -> *mut c_int;
    }
    #[repr(C)]
    struct Dirent {
        ino: u64,
        seek: i64,
        reclen: u16,
        #[cfg(target_os = "macos")]
        namlen: u16,
        kind: u8,
        #[cfg(target_os = "macos")]
        name: [c_char; 1024],
        #[cfg(not(target_os = "macos"))]
        name: [c_char; 256],
    }
    fn c(s: &str) -> Result<CString> {
        CString::new(s).map_err(|_| "Invalid archive path".into())
    }
    fn ret(r: i32) -> Result<()> {
        if r == 0 {
            Ok(())
        } else {
            io(Err(std::io::Error::last_os_error()))
        }
    }
    pub fn open(dir: &File, name: &str, folder: bool, create: bool) -> Result<File> {
        let name = c(name)?;
        if folder && create {
            let r = unsafe { mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o700) };
            if r != 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists
            {
                ret(r)?;
            }
        }
        let flags = NOFOLLOW
            | CLOEXEC
            | if folder { DIRECTORY } else { NONBLOCK }
            | if create && !folder {
                1 | CREATE | EXCL
            } else {
                0
            };
        let fd = unsafe { openat(dir.as_raw_fd(), name.as_ptr(), flags, 0o600u32) };
        if fd < 0 {
            return io(Err(std::io::Error::last_os_error()));
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    pub fn lock_file(dir: &File) -> Result<File> {
        let fd = unsafe {
            openat(
                dir.as_raw_fd(),
                c(".archive.lock")?.as_ptr(),
                2 | CREATE | NOFOLLOW | CLOEXEC | NONBLOCK,
                0o600u32,
            )
        };
        if fd < 0 {
            return io(Err(std::io::Error::last_os_error()));
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    pub fn place(dir: &File, temp: &str, name: &str, replace: bool) -> Result<()> {
        let source = c(temp)?;
        let target = c(name)?;
        ret(unsafe {
            if replace {
                renameat(
                    dir.as_raw_fd(),
                    source.as_ptr(),
                    dir.as_raw_fd(),
                    target.as_ptr(),
                )
            } else {
                #[cfg(target_os = "macos")]
                {
                    renameatx_np(
                        dir.as_raw_fd(),
                        source.as_ptr(),
                        dir.as_raw_fd(),
                        target.as_ptr(),
                        4,
                    )
                } // RENAME_EXCL
                #[cfg(not(target_os = "macos"))]
                {
                    renameat2(
                        dir.as_raw_fd(),
                        source.as_ptr(),
                        dir.as_raw_fd(),
                        target.as_ptr(),
                        1,
                    )
                } // RENAME_NOREPLACE
            }
        })?;
        io(dir.sync_all())
    }
    pub fn remove(dir: &File, name: &str) -> Result<()> {
        ret(unsafe { unlinkat(dir.as_raw_fd(), c(name)?.as_ptr(), 0) })
    }
    pub fn names(dir: &File) -> Result<Vec<String>> {
        let copy = open(dir, ".", true, false)?;
        let stream = unsafe { fdopendir(copy.as_raw_fd()) };
        check(!stream.is_null())?;
        std::mem::forget(copy); // fdopendir owns the descriptor after success.
        let mut names = Vec::new();
        loop {
            #[cfg(target_os = "macos")]
            let error = unsafe { __error() };
            #[cfg(not(target_os = "macos"))]
            let error = unsafe { __errno_location() };
            unsafe {
                *error = 0;
            }
            let p = unsafe { readdir(stream) };
            if p.is_null() {
                if unsafe { *error != 0 } {
                    let failure = std::io::Error::last_os_error();
                    unsafe { closedir(stream) };
                    return io(Err(failure));
                }
                break;
            }
            let s = unsafe { CStr::from_ptr((*p).name.as_ptr()) }
                .to_str()
                .map(str::to_owned);
            match s {
                Ok(s) if s != "." && s != ".." => names.push(s),
                Ok(_) => {}
                Err(_) => {
                    unsafe { closedir(stream) };
                    return Err("Invalid archive filename".into());
                }
            }
        }
        unsafe { closedir(stream) };
        Ok(names)
    }
}
#[cfg(windows)]
fn single_link(file: &File) -> Result<()> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::Storage::FileSystem::{
        GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
    };
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe { GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info) }
        .map_err(|_| "Replay file information unavailable")?;
    check(info.nNumberOfLinks == 1)
}
#[cfg(windows)]
fn windows_open(path: &Path, directory: bool, create: bool) -> Result<File> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    use windows::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    };
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(create && !directory)
        .share_mode(3)
        .custom_flags(
            FILE_FLAG_OPEN_REPARSE_POINT.0
                | if directory {
                    FILE_FLAG_BACKUP_SEMANTICS.0
                } else {
                    0
                },
        );
    if create && !directory {
        options.create_new(true);
    }
    let f = io(options.open(path))?;
    let m = io(f.metadata())?;
    check(m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 == 0 && m.is_dir() == directory)?;
    if !directory {
        single_link(&f)?;
    }
    Ok(f)
}
impl Directory {
    fn root(path: &Path, create: bool) -> Result<Self> {
        check(
            path.is_absolute()
                && !path
                    .components()
                    .any(|c| matches!(c, Component::ParentDir | Component::CurDir)),
        )?;
        #[cfg(unix)]
        {
            let file = io(File::open("/"))?;
            let mut current = Self {
                file,
                path: PathBuf::from("/"),
            };
            for part in path.components() {
                if let Component::Normal(name) = part {
                    current =
                        current.child(name.to_str().ok_or("Invalid archive path")?, create)?;
                }
            }
            Ok(current)
        }
        #[cfg(windows)]
        {
            let mut partial = PathBuf::new();
            let mut parents = Vec::new();
            for part in path.components() {
                partial.push(part);
                if matches!(part, Component::Normal(_)) {
                    if create {
                        match fs::create_dir(&partial) {
                            Ok(()) => {}
                            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                            Err(e) => return io(Err(e)),
                        }
                    }
                    parents.push(windows_open(&partial, true, false)?);
                }
            }
            let file = windows_open(path, true, false)?;
            Ok(Self {
                file,
                path: path.to_owned(),
                _parents: parents,
            })
        }
    }
    fn child(&self, name: &str, create: bool) -> Result<Self> {
        check(!name.is_empty() && !name.contains(['/', '\\']) && name != "..")?;
        let path = self.path.join(name);
        #[cfg(unix)]
        {
            let file = posix::open(&self.file, name, true, create)?;
            Ok(Self { file, path })
        }
        #[cfg(windows)]
        {
            if create {
                match fs::create_dir(&path) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(e) => return io(Err(e)),
                }
            }
            let mut parents = Vec::new();
            for f in &self._parents {
                parents.push(io(f.try_clone())?);
            }
            parents.push(io(self.file.try_clone())?);
            Ok(Self {
                file: windows_open(&path, true, false)?,
                path,
                _parents: parents,
            })
        }
    }
    fn names(&self) -> Result<Vec<String>> {
        #[cfg(unix)]
        {
            posix::names(&self.file)
        }
        #[cfg(windows)]
        {
            io(fs::read_dir(&self.path))?
                .map(|e| {
                    let e = io(e)?;
                    e.file_name()
                        .into_string()
                        .map_err(|_| "Invalid archive filename".into())
                })
                .collect()
        }
    }
    // ponytail: scan for absent files; preserve typed native open errors instead if large runs make scans costly.
    fn read(&self, name: &str) -> Result<Option<Vec<u8>>> {
        if !self.names()?.iter().any(|n| n == name) {
            return Ok(None);
        }
        #[cfg(unix)]
        let f = posix::open(&self.file, name, false, false)?;
        #[cfg(windows)]
        let f = windows_open(&self.path.join(name), false, false)?;
        let m = io(f.metadata())?;
        check(m.is_file() && m.len() <= LIMIT as u64)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            check(m.nlink() == 1)?;
        }
        let mut data = Vec::new();
        io(f.take((LIMIT + 1) as u64).read_to_end(&mut data))?;
        check(data.len() <= LIMIT)?;
        Ok(Some(data))
    }
    fn write(&self, name: &str, body: &[u8], replace: bool) -> Result<()> {
        check(body.len() <= LIMIT)?;
        if let Some(old) = self.read(name)? {
            if !replace {
                return check(old == body);
            }
        }
        #[cfg(test)]
        tests::fail_at("write")?;
        let temp = format!(
            ".tmp-{}-{}",
            std::process::id(),
            TEMP.fetch_add(1, Ordering::Relaxed)
        );
        #[cfg(unix)]
        let mut f = posix::open(&self.file, &temp, false, true)?;
        #[cfg(windows)]
        let mut f = windows_open(&self.path.join(&temp), false, true)?;
        let result = (|| {
            io(f.write_all(body))?;
            io(f.sync_all())?;
            drop(f);
            #[cfg(test)]
            tests::fail_at("place")?;
            #[cfg(unix)]
            {
                posix::place(&self.file, &temp, name, replace)
            }
            #[cfg(windows)]
            {
                use std::os::windows::ffi::OsStrExt;
                use windows::core::PCWSTR;
                use windows::Win32::Storage::FileSystem::{
                    MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
                };
                let source: Vec<u16> = self
                    .path
                    .join(&temp)
                    .as_os_str()
                    .encode_wide()
                    .chain(Some(0))
                    .collect();
                let target: Vec<u16> = self
                    .path
                    .join(name)
                    .as_os_str()
                    .encode_wide()
                    .chain(Some(0))
                    .collect();
                let flags = if replace {
                    MOVEFILE_WRITE_THROUGH | MOVEFILE_REPLACE_EXISTING
                } else {
                    MOVEFILE_WRITE_THROUGH
                };
                unsafe { MoveFileExW(PCWSTR(source.as_ptr()), PCWSTR(target.as_ptr()), flags) }
                    .map_err(|_| "Replay atomic placement failed".into())
            }
        })();
        #[cfg(unix)]
        let _ = posix::remove(&self.file, &temp);
        #[cfg(windows)]
        let _ = fs::remove_file(self.path.join(&temp));
        result
    }
    fn lock(&self) -> Result<File> {
        #[cfg(unix)]
        {
            let f = posix::lock_file(&self.file)?;
            use std::os::unix::fs::MetadataExt;
            let m = io(f.metadata())?;
            check(m.is_file() && m.nlink() == 1)?;
            io(f.lock())?;
            Ok(f)
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
            use windows::Win32::Storage::FileSystem::{
                FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
            };
            let f = io(OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .share_mode(3)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
                .open(self.path.join(".archive.lock")))?;
            let m = io(f.metadata())?;
            check(m.is_file() && m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 == 0)?;
            single_link(&f)?;
            io(f.lock())?;
            Ok(f)
        }
    }
}
fn manifest(dir: &Directory, id: &RunID) -> Result<Manifest> {
    let body = dir
        .read("manifest.json")?
        .ok_or("Missing replay manifest")?;
    let m: Manifest = decode(&body)?;
    m.validate()?;
    check(m.run_id == *id)?;
    integrity(dir, &m)?;
    Ok(m)
}
fn integrity(dir: &Directory, m: &Manifest) -> Result<()> {
    for name in dir.names()? {
        if name.starts_with(".tmp-") {
            dir.read(&name)?.ok_or("Missing replay temp")?;
        } else {
            check(["manifest.json", "cases", "results"].contains(&name.as_str()))?;
        }
    }
    let mut cases = HashMap::new();
    let mut results = HashMap::new();
    for kind in ["cases", "results"] {
        let sub = dir.child(kind, false)?;
        for name in sub.names()? {
            let body = sub.read(&name)?.ok_or("Missing replay file")?;
            if name.starts_with(".tmp-") {
                continue;
            }
            let id = name.strip_suffix(".json").ok_or("Unexpected replay file")?;
            let entry = m
                .cases
                .iter()
                .find(|e| e.case_id == id)
                .ok_or("Unknown replay case")?;
            check(entry.status != EntryStatus::Skipped)?;
            if kind == "cases" {
                let c: Case = decode(&body)?;
                c.validate()?;
                check(
                    c.input.case_id == id
                        && c.input.stock_id == entry.stock_id
                        && c.input.trading_day == entry.trading_day,
                )?;
                cases.insert(id.to_owned(), hash(&body));
            } else {
                let r: Calculation = decode(&body)?;
                r.validate()?;
                check(
                    r.case_id == id
                        && cases.get(id) == Some(&r.input_sha256)
                        && r.outcomes.iter().map(|o| &o.model).collect::<HashSet<_>>()
                            == m.models.iter().collect::<HashSet<_>>(),
                )?;
                results.insert(id.to_owned(), hash(&body));
            }
        }
    }
    for e in &m.cases {
        check(
            e.input_sha256
                .as_ref()
                .is_none_or(|h| cases.get(&e.case_id) == Some(h))
                && e.result_sha256
                    .as_ref()
                    .is_none_or(|h| results.get(&e.case_id) == Some(h)),
        )?;
    }
    Ok(())
}
fn string(body: Vec<u8>) -> Result<String> {
    String::from_utf8(body).map_err(|_| "Invalid replay UTF-8".into())
}
fn handle_at(path: &Path, request: ArchiveRequest) -> Result<ArchiveReply> {
    // ponytail: serialize this small archive; use per-run locks only if throughput matters.
    let _guard = LOCK.lock().map_err(|_| "Replay archive lock failed")?;
    let create = matches!(&request, ArchiveRequest::Create { .. });
    // Validate the supplied manifest before any directory or lock file is created.
    if let ArchiveRequest::Create { manifest: m } = &request {
        m.validate()?;
    }
    if matches!(request, ArchiveRequest::List { .. }) {
        match std::fs::symlink_metadata(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Ok(ArchiveReply::Manifests { manifests: vec![] })
            }
            Err(e) => return io(Err(e)),
            Ok(_) => {}
        }
    }
    let root = Directory::root(path, create)?;
    let _file_lock = root.lock()?;
    if let ArchiveRequest::List {} = request {
        let mut manifests = Vec::new();
        for name in root.names()? {
            if name == ".archive.lock" {
                continue;
            }
            check(uuid(&name) && name == name.to_ascii_lowercase())?;
            manifests.push(manifest(&root.child(&name, false)?, &RunID(name))?);
        }
        manifests.sort_by_key(|m| m.created_at);
        return Ok(ArchiveReply::Manifests { manifests });
    }
    if let ArchiveRequest::Create { manifest: m } = request {
        if root.names()?.contains(&m.run_id.0) {
            check(manifest(&root.child(&m.run_id.0, false)?, &m.run_id)? == m)?;
        } else {
            check(
                m.status == Status::Ready
                    && m.cases.iter().all(|e| e.status == EntryStatus::Pending),
            )?;
            let dir = root.child(&m.run_id.0, true)?;
            dir.child("cases", true)?;
            dir.child("results", true)?;
            let body = serde_json::to_vec(&m).map_err(|_| "Replay manifest encoding failed")?;
            dir.write("manifest.json", &body, false)?;
            #[cfg(unix)]
            io(root.file.sync_all())?;
        }
        return Ok(ArchiveReply::Empty);
    }
    let id = match &request {
        ArchiveRequest::LoadManifest { run_id }
        | ArchiveRequest::SaveCase { run_id, .. }
        | ArchiveRequest::LoadCase { run_id, .. }
        | ArchiveRequest::SaveResult { run_id, .. }
        | ArchiveRequest::LoadResult { run_id, .. }
        | ArchiveRequest::UpdateProgress { run_id, .. } => run_id,
        _ => unreachable!(),
    };
    let dir = root.child(&id.0, false)?;
    let old = manifest(&dir, id)?;
    let loading_case = matches!(&request, ArchiveRequest::LoadCase { .. });
    match request {
        ArchiveRequest::LoadManifest { .. } => Ok(ArchiveReply::Manifest { manifest: old }),
        ArchiveRequest::SaveCase { body, .. } => {
            let c: Case = decode(body.as_bytes())?;
            c.validate()?;
            let e = old
                .cases
                .iter()
                .find(|e| e.case_id == c.input.case_id)
                .ok_or("Unknown replay case")?;
            check(
                e.stock_id == c.input.stock_id
                    && e.trading_day == c.input.trading_day
                    && e.status != EntryStatus::Skipped,
            )?;
            let sub = dir.child("cases", false)?;
            let name = format!("{}.json", c.input.case_id);
            check(
                old.status != Status::Completed
                    || sub.read(&name)?.as_deref() == Some(body.as_bytes()),
            )?;
            sub.write(&name, body.as_bytes(), false)?;
            Ok(ArchiveReply::Receipt {
                sha256: hash(body.as_bytes()),
            })
        }
        ArchiveRequest::SaveResult { body, .. } => {
            let r: Calculation = decode(body.as_bytes())?;
            r.validate()?;
            check(
                old.cases
                    .iter()
                    .any(|e| e.case_id == r.case_id && e.status != EntryStatus::Skipped)
                    && r.outcomes.iter().map(|o| &o.model).collect::<HashSet<_>>()
                        == old.models.iter().collect::<HashSet<_>>(),
            )?;
            let input = dir
                .child("cases", false)?
                .read(&format!("{}.json", r.case_id))?
                .ok_or("Missing replay input")?;
            check(hash(&input) == r.input_sha256)?;
            let sub = dir.child("results", false)?;
            let name = format!("{}.json", r.case_id);
            check(
                old.status != Status::Completed
                    || sub.read(&name)?.as_deref() == Some(body.as_bytes()),
            )?;
            sub.write(&name, body.as_bytes(), false)?;
            Ok(ArchiveReply::Receipt {
                sha256: hash(body.as_bytes()),
            })
        }
        ArchiveRequest::LoadCase { case_id, .. } | ArchiveRequest::LoadResult { case_id, .. } => {
            check(safe_case(&case_id) && old.cases.iter().any(|e| e.case_id == case_id))?;
            let is_case = loading_case;
            let body = dir
                .child(if is_case { "cases" } else { "results" }, false)?
                .read(&format!("{case_id}.json"))?;
            check(!is_case || body.is_some())?;
            let sha256 = body.as_ref().map(|b| hash(b));
            Ok(ArchiveReply::Body {
                body: body.map(string).transpose()?,
                sha256,
            })
        }
        ArchiveRequest::UpdateProgress {
            entries, status, ..
        } => {
            check(entries.len() == old.cases.len())?;
            for (a, b) in old.cases.iter().zip(&entries) {
                check(
                    a.case_id == b.case_id
                        && a.stock_id == b.stock_id
                        && a.trading_day == b.trading_day
                        && (a.status == EntryStatus::Pending || a == b),
                )?;
            }
            let mut next = old.clone();
            next.cases = entries;
            next.status = status;
            if status == Status::Completed && next.collection_completed_at.is_none() {
                next.collection_completed_at = Some(Utc::now().timestamp_millis());
            }
            check(old.status != Status::Completed || next == old)?;
            next.validate()?;
            integrity(&dir, &next)?;
            if next != old {
                dir.write(
                    "manifest.json",
                    &serde_json::to_vec(&next).map_err(|_| "Replay manifest encoding failed")?,
                    true,
                )?;
            }
            Ok(ArchiveReply::Empty)
        }
        _ => unreachable!(),
    }
}
#[tauri::command]
pub async fn stock_backtest_archive(request: ArchiveRequest) -> Result<ArchiveReply> {
    // Native computes this fixed path. No fallback to the current working directory.
    let root = dirs::config_dir()
        .ok_or("Configuration directory unavailable")?
        .join("penguinnotch")
        .join("Forecasts")
        .join("Backtests");
    tauri::async_runtime::spawn_blocking(move || handle_at(&root, request))
        .await
        .map_err(|_| "Replay archive worker failed")?
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use std::fs;
    const BODY: &str = r#"{"version":1,"input":{"version":1,"caseID":"us_TEST_2026-09-25","stockID":"us:TEST","market":"us","currency":"USD","tradingDay":"2026-09-25","sessionStart":1790343000000,"sessionEnd":1790366400000,"cutoff":1790362800000,"inputBarEnd":1790362800000,"inputPrice":100.1,"previousClose":100,"priceBasis":"provider-adjusted-as-fetched","dailyCloses":[],"minutes":[{"end":1790362800000,"open":100.1,"high":100.3,"low":99.89999999999999,"close":100.1,"volume":0}]},"target":{"actualClose":101,"candleAt":1790308800000,"fetchedAt":1790366460000},"source":{"provider":"toss","calendarFetchedAt":1790366460000,"dailyFetchedAt":1790366460000,"minutePages":[{"before":"2026-09-25T19:00:00Z","nextBefore":null,"fetchedAt":1790366460000}]}}"#;
    const HASH: &str = "b7a648b33e2d8b7fefa8d21668c29a70425477b8c2d7ddbdfacab73fcdfa406a";
    #[test]
    fn rejects_unknown_ipc_fields_and_bad_run_id() {
        for request in [
            r#"{"action":"list","path":"../history"}"#,
            r#"{"action":"loadManifest","runID":"../bad"}"#,
        ] {
            assert!(serde_json::from_str::<ArchiveRequest>(request).is_err());
        }
    }
    thread_local! {static FAIL:std::cell::Cell<&'static str>=const{std::cell::Cell::new("")};}
    pub(super) fn fail_at(stage: &str) -> Result<()> {
        check(!FAIL.with(|s| s.get() == stage))
    }
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let p = fs::canonicalize(std::env::temp_dir())
                .unwrap()
                .join(format!(
                    "penguin-task3-{}-{}",
                    std::process::id(),
                    TEMP.fetch_add(1, Ordering::Relaxed)
                ));
            fs::create_dir(&p).unwrap();
            Self(p)
        }
        fn root(&self) -> PathBuf {
            self.0.join("Forecasts").join("Backtests")
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn m() -> Manifest {
        let c: Case = decode(BODY.as_bytes()).unwrap();
        decode(serde_json::to_string(&json!({"version":1,"runID":"12345678-1234-1234-1234-123456789abc",
            "createdAt":1790366460000i64,"collectionStartedAt":1790366460000i64,"collectionCompletedAt":null,
            "protocolVersion":"replay-v1","codeVersion":"test-task3","priceBasis":BASIS,"cutoffMinutes":60,"sessions":20,
            "symbols":[c.input.stock_id],"models":[MODELS[0]],"status":"ready","cases":[{
                "caseID":c.input.case_id,"stockID":c.input.stock_id,"tradingDay":c.input.trading_day,
                "status":"pending","inputSHA256":null,"resultSHA256":null,"reason":null}]})).unwrap().as_bytes()).unwrap()
    }
    fn create(root: &Path) -> Manifest {
        let m = m();
        handle_at(
            root,
            ArchiveRequest::Create {
                manifest: m.clone(),
            },
        )
        .unwrap();
        m
    }
    fn save(root: &Path, m: &Manifest, body: &str) -> Result<ArchiveReply> {
        handle_at(
            root,
            ArchiveRequest::SaveCase {
                run_id: m.run_id.clone(),
                body: body.into(),
            },
        )
    }
    fn result(m: &Manifest, h: &str) -> String {
        serde_json::to_string(&json!({"version":1,"caseID":m.cases[0].case_id,"inputSHA256":h,"calculationVersion":"replay-v1",
            "computedAt":1790366460000i64,"outcomes":[{"model":MODELS[0],"status":"skipped","reason":"insufficient_daily_history","forecast":null}]})).unwrap()
    }
    fn save_result(root: &Path, m: &Manifest, body: String) -> Result<ArchiveReply> {
        handle_at(
            root,
            ArchiveRequest::SaveResult {
                run_id: m.run_id.clone(),
                body,
            },
        )
    }
    #[test]
    fn crash_after_case_save_resumes_without_overwrite_and_common_hash() {
        let t = Temp::new();
        let root = t.root();
        let m = create(&root);
        assert_eq!(hash(BODY.as_bytes()), HASH);
        assert!(
            matches!(save(&root,&m,BODY).unwrap(),ArchiveReply::Receipt{sha256} if sha256==HASH)
        );
        assert!(
            matches!(handle_at(&root,ArchiveRequest::LoadManifest{run_id:m.run_id.clone()}).unwrap(),ArchiveReply::Manifest{manifest} if manifest==m)
        );
        assert!(
            matches!(handle_at(&root,ArchiveRequest::LoadCase{run_id:m.run_id.clone(),case_id:m.cases[0].case_id.clone()}).unwrap(),ArchiveReply::Body{body:Some(body),sha256:Some(sha256)} if body==BODY&&sha256==HASH)
        );
        let mut entries = m.cases.clone();
        entries[0].status = EntryStatus::Saved;
        entries[0].input_sha256 = Some(HASH.into());
        handle_at(
            &root,
            ArchiveRequest::UpdateProgress {
                run_id: m.run_id.clone(),
                entries: entries.clone(),
                status: Status::Paused,
            },
        )
        .unwrap();
        save(&root, &m, BODY).unwrap();
        assert!(save(&root, &m, &format!("{BODY} ")).is_err());
        assert_eq!(
            fs::read(
                root.join(&m.run_id.0)
                    .join("cases")
                    .join(format!("{}.json", m.cases[0].case_id))
            )
            .unwrap(),
            BODY.as_bytes()
        );
        assert!(handle_at(
            &root,
            ArchiveRequest::UpdateProgress {
                run_id: m.run_id.clone(),
                entries: m.cases.clone(),
                status: Status::Running
            }
        )
        .is_err());
        assert!(handle_at(&root, ArchiveRequest::Create { manifest: m }).is_err());
    }
    #[test]
    fn concurrent_same_case_saves_and_atomic_no_overwrite() {
        let t = Temp::new();
        let root = t.root();
        let m = create(&root);
        std::thread::scope(|scope| {
            for _ in 0..12 {
                let root = &root;
                let m = &m;
                scope.spawn(move || {
                    save(root, m, BODY).unwrap();
                });
            }
        });
        let dir = Directory::root(&root, false)
            .unwrap()
            .child(&m.run_id.0, false)
            .unwrap()
            .child("cases", false)
            .unwrap();
        let name = format!("{}.json", m.cases[0].case_id);
        assert_eq!(dir.read(&name).unwrap().unwrap(), BODY.as_bytes());
        assert!(dir.write(&name, b"different", false).is_err());
        assert_eq!(dir.read(&name).unwrap().unwrap(), BODY.as_bytes());
        assert_eq!(dir.names().unwrap(), vec![name]);
    }
    #[test]
    fn results_require_exact_input_hash_and_terminal_entries_are_frozen() {
        let t = Temp::new();
        let root = t.root();
        let m = create(&root);
        let body = result(&m, HASH);
        assert!(matches!(
            handle_at(
                &root,
                ArchiveRequest::LoadResult {
                    run_id: m.run_id.clone(),
                    case_id: m.cases[0].case_id.clone()
                }
            )
            .unwrap(),
            ArchiveReply::Body {
                body: None,
                sha256: None
            }
        ));
        assert!(save_result(&root, &m, body.clone()).is_err());
        save(&root, &m, BODY).unwrap();
        assert!(save_result(&root, &m, result(&m, &"0".repeat(64))).is_err());
        save_result(&root, &m, body.clone()).unwrap();
        save_result(&root, &m, body.clone()).unwrap();
        assert!(save_result(&root, &m, format!("{body} ")).is_err());
        let mut entries = m.cases.clone();
        entries[0].status = EntryStatus::Saved;
        entries[0].input_sha256 = Some(HASH.into());
        entries[0].result_sha256 = Some(hash(body.as_bytes()));
        handle_at(
            &root,
            ArchiveRequest::UpdateProgress {
                run_id: m.run_id.clone(),
                entries: entries.clone(),
                status: Status::Completed,
            },
        )
        .unwrap();
        assert!(
            matches!(handle_at(&root,ArchiveRequest::LoadResult{run_id:m.run_id.clone(),case_id:m.cases[0].case_id.clone()}).unwrap(),ArchiveReply::Body{body:Some(b),..} if b==body)
        );
        assert!(handle_at(
            &root,
            ArchiveRequest::UpdateProgress {
                run_id: m.run_id.clone(),
                entries,
                status: Status::Paused
            }
        )
        .is_err());
    }
    #[test]
    fn write_and_placement_failures_preserve_originals_and_crash_leftovers() {
        let t = Temp::new();
        let root = t.root();
        let m = create(&root);
        let run = root.join(&m.run_id.0);
        let before = fs::read(run.join("manifest.json")).unwrap();
        for stage in ["write", "place"] {
            FAIL.with(|s| s.set(stage));
            assert!(save(&root, &m, BODY).is_err());
            assert!(handle_at(
                &root,
                ArchiveRequest::UpdateProgress {
                    run_id: m.run_id.clone(),
                    entries: m.cases.clone(),
                    status: Status::Paused
                }
            )
            .is_err());
            FAIL.with(|s| s.set(""));
            assert_eq!(fs::read(run.join("manifest.json")).unwrap(), before);
            assert_eq!(fs::read_dir(run.join("cases")).unwrap().count(), 0);
            assert!(!fs::read_dir(&run).unwrap().any(|e| e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".tmp-")));
        }
        save(&root, &m, BODY).unwrap();
        fs::write(
            run.join(".tmp-interrupted-manifest"),
            b"synthetic crash leftover",
        )
        .unwrap();
        handle_at(
            &root,
            ArchiveRequest::LoadManifest {
                run_id: m.run_id.clone(),
            },
        )
        .unwrap();
        assert_eq!(
            fs::read(run.join(".tmp-interrupted-manifest")).unwrap(),
            b"synthetic crash leftover"
        );
    }
    // Mutate one representative object at each nested schema level, not just top-level fields.
    fn inject(base: &Value, path: &str, field: &str) -> String {
        let mut v = base.clone();
        v.pointer_mut(path)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert(field.into(), json!("synthetic"));
        v.to_string()
    }
    #[test]
    fn unknown_nested_fields_traversal_versions_and_bounds_reject_without_writing() {
        let t = Temp::new();
        let root = t.root();
        let m = create(&root);
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../Tests/Fixtures/stock-forecast-evaluation-v1.json"
        ))
        .unwrap();
        let base = &fixture["replayCases"][0]["caseData"];
        for field in ["accountSeq", "token", "quantity"] {
            for path in [
                "",
                "/input",
                "/input/dailyCloses/0",
                "/input/minutes/0",
                "/target",
                "/source",
                "/source/minutePages/0",
            ] {
                assert!(
                    save(&root, &m, &inject(base, path, field)).is_err(),
                    "{path}/{field}"
                );
            }
            let manifest = serde_json::to_value(&m).unwrap();
            for path in ["", "/cases/0"] {
                assert!(decode::<Manifest>(inject(&manifest, path, field).as_bytes()).is_err());
            }
            let mut r: Value = serde_json::from_str(&result(&m, HASH)).unwrap();
            r["outcomes"][0]["status"] = json!("forecast");
            r["outcomes"][0]["reason"] = Value::Null;
            r["outcomes"][0]["forecast"] = json!({"expectedClose":100,"lowerClose":90,"upperClose":110,"riseProbability":0.5,"observations":60});
            for path in ["", "/outcomes/0", "/outcomes/0/forecast"] {
                assert!(save_result(&root, &m, inject(&r, path, field)).is_err());
            }
        }
        for path in [
            "../history",
            "/tmp/history",
            "us_TEST_2026-02-30",
            "us_TEST_2026-09-25\\foo",
        ] {
            assert!(serde_json::from_value::<ArchiveRequest>(
                json!({"action":"loadCase","runID":m.run_id,"caseID":path})
            )
            .is_err());
        }
        for (field, value) in [
            ("version", json!(2)),
            ("models", json!(["unknown"])),
            ("runID", json!("../bad")),
        ] {
            let mut v = serde_json::to_value(&m).unwrap();
            v[field] = value;
            assert!(decode::<Manifest>(v.to_string().as_bytes())
                .and_then(|m| m.validate())
                .is_err());
        }
        for (pointer, value) in [
            ("/version", json!(2)),
            ("/input/version", json!(2)),
            ("/input/inputPrice", json!(0)),
            ("/input/minutes/0/high", json!(1)),
            ("/input/minutes/0/volume", json!(-1)),
            ("/input/sessionStart", json!(9_007_199_254_740_992u64)),
            ("/input/minutes/0/end", json!(0.5)),
            ("/source/provider", json!("private")),
            ("/source/minutePages/0/nextBefore", json!("junk")),
            ("/target/actualClose", json!(0)),
        ] {
            let mut v = base.clone();
            *v.pointer_mut(pointer).unwrap() = value;
            assert!(save(&root, &m, &v.to_string()).is_err(), "{pointer}");
        }
        for pointer in [
            "/source/minutePages/0/nextBefore",
            "/target/fetchedAt",
            "/input/minutes/0/volume",
        ] {
            let mut v = base.clone();
            let (parent, key) = pointer.rsplit_once('/').unwrap();
            v.pointer_mut(parent)
                .unwrap()
                .as_object_mut()
                .unwrap()
                .remove(key);
            assert!(
                save(&root, &m, &v.to_string()).is_err(),
                "missing {pointer}"
            );
        }
        let mut v = base.clone();
        let pages = v["source"]["minutePages"].as_array_mut().unwrap();
        pages.push(json!({"before":"2026-09-25T20:00:00Z","nextBefore":"2026-09-25T19:59:00Z","fetchedAt":1790366460000i64}));
        decode::<Case>(v.to_string().as_bytes())
            .unwrap()
            .validate()
            .unwrap();
        v["source"]["minutePages"] = json!(vec![v["source"]["minutePages"][0].clone(); 9]);
        assert!(save(&root, &m, &v.to_string()).is_err());
        assert!(save(&root, &m, &format!("{BODY}{}", " ".repeat(LIMIT))).is_err());
        assert_eq!(
            fs::read_dir(root.join(&m.run_id.0).join("cases"))
                .unwrap()
                .count(),
            0
        );
        assert_eq!(
            fs::read_dir(root.join(&m.run_id.0).join("results"))
                .unwrap()
                .count(),
            0
        );
        // The IPC root is fixed by native code, and tests touch only their fresh synthetic folder.
        for name in [
            "Forecasts/history.json",
            "Forecasts/AIAnalyses/history.json",
            "Forecasts/CloseEstimates/public-test.json",
            "stock-history.sqlite3",
        ] {
            let file = t.0.join(name);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, b"legacy sentinel").unwrap();
        }
        save(&root, &m, BODY).unwrap();
        for name in [
            "Forecasts/history.json",
            "Forecasts/AIAnalyses/history.json",
            "Forecasts/CloseEstimates/public-test.json",
            "stock-history.sqlite3",
        ] {
            assert_eq!(fs::read(t.0.join(name)).unwrap(), b"legacy sentinel");
        }
    }
    #[test]
    fn corrupt_or_unsupported_files_and_hash_mismatch_block_all_writes() {
        for kind in ["manifest", "case", "result", "hash", "version"] {
            let t = Temp::new();
            let root = t.root();
            let m = create(&root);
            save(&root, &m, BODY).unwrap();
            let run = root.join(&m.run_id.0);
            let case = run
                .join("cases")
                .join(format!("{}.json", m.cases[0].case_id));
            let protected = match kind {
                "manifest" | "version" => run.join("manifest.json"),
                "result" => run
                    .join("results")
                    .join(format!("{}.json", m.cases[0].case_id)),
                _ => case.clone(),
            };
            if kind == "hash" {
                let mut entries = m.cases.clone();
                entries[0].status = EntryStatus::Saved;
                entries[0].input_sha256 = Some(HASH.into());
                handle_at(
                    &root,
                    ArchiveRequest::UpdateProgress {
                        run_id: m.run_id.clone(),
                        entries,
                        status: Status::Paused,
                    },
                )
                .unwrap();
                fs::write(&protected, format!("{BODY} ")).unwrap();
            } else if kind == "version" {
                let mut value = serde_json::to_value(&m).unwrap();
                value["version"] = json!(2);
                fs::write(&protected, value.to_string()).unwrap();
            } else {
                fs::write(&protected, b"{broken").unwrap();
            }
            let bytes = fs::read(&protected).unwrap();
            let manifest = fs::read(run.join("manifest.json")).unwrap();
            assert!(
                handle_at(
                    &root,
                    ArchiveRequest::LoadManifest {
                        run_id: m.run_id.clone()
                    }
                )
                .is_err(),
                "{kind}"
            );
            assert!(save(&root, &m, BODY).is_err(), "{kind}");
            assert!(handle_at(
                &root,
                ArchiveRequest::UpdateProgress {
                    run_id: m.run_id.clone(),
                    entries: m.cases.clone(),
                    status: Status::Running
                }
            )
            .is_err());
            assert_eq!(fs::read(&protected).unwrap(), bytes);
            assert_eq!(fs::read(run.join("manifest.json")).unwrap(), manifest);
        }
    }
    #[cfg(unix)]
    #[test]
    fn symlink_escape_and_hardlinks_are_rejected_without_touching_external_bytes() {
        use std::os::unix::fs::symlink;
        for kind in [
            "root", "ancestor", "run", "cases", "file", "hardlink", "lock", "dangling",
        ] {
            let t = Temp::new();
            let root = t.root();
            let m = create(&root);
            let outside = t.0.join("outside");
            fs::create_dir(&outside).unwrap();
            let external = outside.join(format!("{}.json", m.cases[0].case_id));
            fs::write(&external, BODY).unwrap();
            let run = root.join(&m.run_id.0);
            let cases = run.join("cases");
            let file = cases.join(format!("{}.json", m.cases[0].case_id));
            match kind {
                "root" | "dangling" => {
                    fs::rename(&root, t.0.join("preserved")).unwrap();
                    symlink(
                        if kind == "root" {
                            outside.clone()
                        } else {
                            t.0.join("missing")
                        },
                        &root,
                    )
                    .unwrap();
                }
                "ancestor" => {
                    let forecasts = root.parent().unwrap();
                    fs::rename(forecasts, t.0.join("preserved")).unwrap();
                    symlink(&outside, forecasts).unwrap();
                }
                "run" => {
                    fs::rename(&run, root.join("preserved")).unwrap();
                    symlink(&outside, &run).unwrap();
                }
                "cases" => {
                    fs::remove_dir(&cases).unwrap();
                    symlink(&outside, &cases).unwrap();
                }
                "file" => symlink(&external, &file).unwrap(),
                "hardlink" => fs::hard_link(&external, &file).unwrap(),
                "lock" => {
                    fs::remove_file(root.join(".archive.lock")).unwrap();
                    symlink(&external, root.join(".archive.lock")).unwrap();
                }
                _ => unreachable!(),
            }
            assert!(save(&root, &m, BODY).is_err(), "{kind}");
            if kind == "dangling" {
                assert!(handle_at(&root, ArchiveRequest::List {}).is_err());
            }
            assert_eq!(fs::read(&external).unwrap(), BODY.as_bytes());
        }
    }

    #[cfg(unix)]
    #[test]
    fn kernel_write_and_rename_failures_preserve_original_files() {
        use std::os::unix::fs::PermissionsExt;
        let t = Temp::new();
        let root = t.root();
        let m = create(&root);
        let run = root.join(&m.run_id.0);
        let cases = run.join("cases");
        let before = fs::read(run.join("manifest.json")).unwrap();
        fs::set_permissions(&cases, fs::Permissions::from_mode(0o500)).unwrap();
        let denied = save(&root, &m, BODY);
        fs::set_permissions(&cases, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(denied.is_err());
        save(&root, &m, BODY).unwrap();
        let dir = Directory::root(&run, false).unwrap();
        let mut temp = posix::open(&dir.file, ".tmp-kernel", false, true).unwrap();
        temp.write_all(b"replacement").unwrap();
        temp.sync_all().unwrap();
        drop(temp);
        fs::set_permissions(&run, fs::Permissions::from_mode(0o500)).unwrap();
        let denied = posix::place(&dir.file, ".tmp-kernel", "manifest.json", true);
        fs::set_permissions(&run, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(denied.is_err());
        assert_eq!(fs::read(run.join("manifest.json")).unwrap(), before);
        assert_eq!(
            fs::read(cases.join(format!("{}.json", m.cases[0].case_id))).unwrap(),
            BODY.as_bytes()
        );
    }
    #[test]
    fn all_public_replay_fixtures_validate_in_native_without_cursor_chain_assumptions() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../Tests/Fixtures/stock-forecast-evaluation-v1.json"
        ))
        .unwrap();
        for sample in fixture["replayCases"].as_array().unwrap() {
            decode::<Case>(sample["caseData"].to_string().as_bytes())
                .unwrap()
                .validate()
                .unwrap();
        }
        assert!(!cursor("2026-02-30T19:00:00Z"));
        assert!(!cursor("2026-09-25T19:00:00z"));
    }
}
