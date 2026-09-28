//! Native-only stock transport. One process owns the Toss token: renewing it revokes its predecessor.
//! Endpoint/schema references: Sources/Widgets/{TossInvestClient,StockQuote,FinnhubClient}.swift.

use chrono::{DateTime, Datelike, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};
#[cfg(test)]
use serde_json::json;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, Mutex, OnceLock,
};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

const TOSS: &str = "https://openapi.tossinvest.com";
const FINNHUB: &str = "https://finnhub.io";
const MAX_BODY: u64 = 2 * 1024 * 1024;
const MAX_CACHE: usize = 512;
static GENERATION: AtomicU64 = AtomicU64::new(0);
static HISTORY_LOCK: Mutex<()> = Mutex::new(());
type Result<T> = std::result::Result<T, String>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Toss,
    Finnhub,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Market {
    Kr,
    Us,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Interval {
    #[serde(rename = "1m")]
    Minute,
    #[serde(rename = "10m")]
    TenMinutes,
    #[serde(rename = "1d")]
    Day,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WatchedStock {
    pub symbol: String,
    pub market: Market,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default = "yes")]
    pub visible: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct StockSettings {
    pub enabled: bool,
    pub provider: Provider,
    pub symbols: Vec<WatchedStock>,
    pub display_interval: u32,
    pub chart_interval: Interval,
    pub candle_count: u32,
    pub moving_averages: Vec<u32>,
    pub show_technical: bool,
    pub forecasts_enabled: bool,
    pub record_forecasts: bool,
    pub account_seq: u64,
}

impl Default for StockSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            provider: Provider::Toss,
            symbols: vec![],
            display_interval: 3,
            chart_interval: Interval::Minute,
            candle_count: 20,
            moving_averages: vec![5, 20],
            show_technical: true,
            forecasts_enabled: false,
            record_forecasts: false,
            account_seq: 0,
        }
    }
}

fn valid_text(text: &str, max: usize) -> bool {
    !text.trim().is_empty() && text.chars().count() <= max && !text.chars().any(char::is_control)
}

fn symbol(raw: &str, market: Option<Market>) -> Result<(String, Market)> {
    if raw.len() > 20 {
        return Err("Invalid stock symbol".into());
    }
    let upper = raw.trim().to_ascii_uppercase();
    let (text, prefix) = if let Some(s) = upper.strip_prefix("KR:") {
        (s, Some(Market::Kr))
    } else if let Some(s) = upper.strip_prefix("US:") {
        (s, Some(Market::Us))
    } else {
        (upper.as_str(), None)
    };
    if prefix.is_some() && market.is_some() && prefix != market {
        return Err("Stock symbol and market disagree".into());
    }
    let kr = text.len() == 6
        && text
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit());
    let chosen = market
        .or(prefix)
        .unwrap_or(if kr && text.bytes().any(|b| b.is_ascii_digit()) {
            Market::Kr
        } else {
            Market::Us
        });
    let us = !text.is_empty()
        && text.len() <= 10
        && text.as_bytes()[0].is_ascii_uppercase()
        && text
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'.' || b == b'-');
    if !match chosen {
        Market::Kr => kr,
        Market::Us => us,
    } {
        return Err("Invalid stock symbol".into());
    }
    Ok((text.to_string(), chosen))
}

impl StockSettings {
    fn validated(mut self) -> Result<Self> {
        if self.symbols.len() > 30
            || !(1..=10).contains(&self.display_interval)
            || !(1..=20).contains(&self.candle_count)
            || self.account_seq > 9_007_199_254_740_991
            || self.moving_averages.len() > 4
            || self
                .moving_averages
                .iter()
                .any(|p| ![5, 20, 60, 120].contains(p))
        {
            return Err("Invalid stock settings".into());
        }
        let mut seen = HashSet::new();
        for stock in &mut self.symbols {
            stock.symbol = symbol(&stock.symbol, Some(stock.market))?.0;
            if !seen.insert(format!("{:?}:{}", stock.market, stock.symbol)) {
                return Err("Duplicate stock symbol".into());
            }
            if let Some(name) = &stock.name {
                if name.trim().is_empty() && !name.chars().any(char::is_control) {
                    stock.name = None;
                } else if !valid_text(name, 200) {
                    return Err("Invalid stock name".into());
                }
            }
            if let Some(color) = &mut stock.color {
                let hex = color.strip_prefix('#').unwrap_or(color);
                if hex.len() != 6 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return Err("Stock color must be six hexadecimal digits".into());
                }
                *color = format!("#{}", hex.to_ascii_lowercase());
            }
        }
        self.moving_averages.sort_unstable();
        self.moving_averages.dedup();
        Ok(self)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Prices,
    Names,
    Candles,
    Accounts,
    Holdings,
    Calendar,
    FinnhubQuote,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StockRequest {
    kind: Kind,
    symbols: Option<Vec<String>>,
    symbol: Option<String>,
    market: Option<Market>,
    interval: Option<Interval>,
    account_seq: Option<u64>,
    before: Option<String>,
    adjusted: Option<bool>,
    count: Option<u32>,
    date: Option<String>,
}

fn iso_millis(text: &str) -> Result<i64> {
    if text.len() > 40 {
        return Err("Invalid ISO8601 timestamp".into());
    }
    DateTime::parse_from_rfc3339(text)
        .map(|d| d.timestamp_millis())
        .map_err(|_| "Invalid ISO8601 timestamp".into())
}

impl StockRequest {
    fn provider(&self) -> Provider {
        if self.kind == Kind::FinnhubQuote {
            Provider::Finnhub
        } else {
            Provider::Toss
        }
    }
    fn private(&self) -> bool {
        matches!(self.kind, Kind::Accounts | Kind::Holdings)
    }
    fn validated(mut self, settings: &StockSettings) -> Result<Self> {
        if !settings.enabled || settings.provider != self.provider() {
            return Err("Stock provider is disabled or has changed".into());
        }
        if self.private() && !settings.forecasts_enabled {
            return Err("Enable forecasts before requesting account data".into());
        }
        let batch = matches!(self.kind, Kind::Prices | Kind::Names);
        let single = matches!(
            self.kind,
            Kind::Candles | Kind::FinnhubQuote | Kind::Holdings
        );
        if (!batch && self.symbols.is_some())
            || (!single && self.symbol.is_some())
            || (self.kind != Kind::Candles
                && (self.interval.is_some()
                    || self.before.is_some()
                    || self.adjusted.is_some()
                    || self.count.is_some()))
            || (self.kind != Kind::Holdings && self.account_seq.is_some())
            || (self.kind != Kind::Calendar && self.date.is_some())
        {
            return Err("Unexpected stock request fields".into());
        }
        if batch {
            let symbols = self.symbols.as_mut().ok_or("symbols is required")?;
            if symbols.is_empty() || symbols.len() > 200 {
                return Err("Use 1 to 200 symbols".into());
            }
            for s in symbols.iter_mut() {
                *s = symbol(s, self.market)?.0;
            }
            symbols.sort_unstable();
            symbols.dedup();
        }
        if let Some(s) = &mut self.symbol {
            let (parsed, market) = symbol(s, self.market)?;
            if self.kind == Kind::FinnhubQuote && market != Market::Us {
                return Err("Finnhub quotes support US symbols only".into());
            }
            *s = parsed;
            self.market = Some(market);
        } else if matches!(self.kind, Kind::Candles | Kind::FinnhubQuote) {
            return Err("symbol is required".into());
        }
        if self.kind == Kind::Candles {
            let interval = self.interval.unwrap_or(Interval::Minute);
            let max = if interval == Interval::TenMinutes {
                1400
            } else {
                200
            };
            let count = self.count.unwrap_or(max);
            if count == 0 || count > max {
                return Err("Candle count is out of range".into());
            }
            self.interval = Some(interval);
            self.count = Some(count);
            self.adjusted = Some(self.adjusted.unwrap_or(true));
            if let Some(before) = &self.before {
                iso_millis(before)?;
            }
        }
        if self.kind == Kind::Holdings {
            let seq = self.account_seq.unwrap_or(settings.account_seq);
            if settings.account_seq == 0
                || seq != settings.account_seq
                || seq > 9_007_199_254_740_991
            {
                return Err("Holdings require the currently selected account".into());
            }
            self.account_seq = Some(seq);
        }
        if self.kind == Kind::Calendar {
            if self.market.is_none() {
                return Err("market is required for calendar".into());
            }
            if let Some(date) = &self.date {
                if date.len() != 10
                    || NaiveDate::parse_from_str(date, "%Y-%m-%d")
                        .map(|d| d.format("%Y-%m-%d").to_string() != *date)
                        .unwrap_or(true)
                {
                    return Err("date must be YYYY-MM-DD".into());
                }
            }
        }
        Ok(self)
    }
    fn ttl(&self) -> Duration {
        Duration::from_secs(match self.kind {
            Kind::Names => 86400,
            Kind::Accounts | Kind::Holdings => 300,
            Kind::Candles => match self.interval {
                Some(Interval::TenMinutes) => 600,
                Some(Interval::Day) => 86400,
                _ => 60,
            },
            _ => 60,
        })
    }
    fn key(&self, now: f64) -> Result<String> {
        let mut key =
            serde_json::to_string(self).map_err(|_| "Could not encode stock cache key")?;
        if self.kind == Kind::Candles
            && self.interval == Some(Interval::Day)
            && self.before.is_none()
        {
            key.push_str(
                &market_day(now, self.market.ok_or("Missing candle market")?)?.to_string(),
            );
        }
        Ok(key)
    }
    fn batch_symbol(&self, symbol: &str) -> Self {
        let mut request = self.clone();
        request.symbols = Some(vec![symbol.to_string()]);
        request.market = None; // Provider batch responses identify each symbol themselves.
        request
    }
    fn path(&self) -> &'static str {
        match self.kind {
            Kind::Prices => "/api/v1/prices",
            Kind::Names => "/api/v1/stocks",
            Kind::Candles => "/api/v1/candles",
            Kind::Accounts => "/api/v1/accounts",
            Kind::Holdings => "/api/v1/holdings",
            Kind::FinnhubQuote => "/api/v1/quote",
            Kind::Calendar => {
                if self.market == Some(Market::Kr) {
                    "/api/v1/market-calendar/KR"
                } else {
                    "/api/v1/market-calendar/US"
                }
            }
        }
    }
    fn query(&self) -> Vec<(String, String)> {
        let mut q = Vec::new();
        if let Some(symbols) = &self.symbols {
            q.push(("symbols".into(), symbols.join(",")));
        }
        if let Some(symbol) = &self.symbol {
            q.push(("symbol".into(), symbol.clone()));
        }
        if let Some(interval) = self.interval {
            q.push((
                "interval".into(),
                if interval == Interval::Day {
                    "1d"
                } else {
                    "1m"
                }
                .into(),
            ));
        }
        if let Some(count) = self.count {
            q.push(("count".into(), count.min(200).to_string()));
        }
        if let Some(before) = &self.before {
            q.push(("before".into(), before.clone()));
        }
        if let Some(adjusted) = self.adjusted {
            q.push(("adjusted".into(), adjusted.to_string()));
        }
        if let Some(date) = &self.date {
            q.push(("date".into(), date.clone()));
        }
        q
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StockReply {
    data: Value,
    fetched_at: i64,
}

struct Cached {
    reply: StockReply,
    expires: Instant,
    inserted: Instant,
}
#[derive(Default)]
struct Cache {
    entries: HashMap<String, Cached>,
}
impl Cache {
    fn get(&self, key: &str, now: Instant) -> Option<StockReply> {
        self.entries
            .get(key)
            .filter(|v| now < v.expires)
            .map(|v| v.reply.clone())
    }
    fn put(&mut self, key: String, reply: StockReply, ttl: Duration, now: Instant) {
        self.entries.retain(|_, v| now < v.expires);
        if self.entries.len() >= MAX_CACHE {
            if let Some(key) = self
                .entries
                .iter()
                .min_by_key(|(_, v)| v.inserted)
                .map(|(k, _)| k.clone())
            {
                self.entries.remove(&key);
            }
        }
        self.entries.insert(
            key,
            Cached {
                reply,
                expires: now + ttl,
                inserted: now,
            },
        );
    }
    fn lookup(
        &self,
        request: &StockRequest,
        now: Instant,
        wall: f64,
    ) -> Result<Option<StockReply>> {
        let Some(symbols) = &request.symbols else {
            return Ok(self.get(&request.key(wall)?, now));
        };
        let mut rows = Vec::new();
        let mut combined: Option<StockReply> = None;
        for symbol in symbols {
            let Some(reply) = self.get(&request.batch_symbol(symbol).key(wall)?, now) else {
                return Ok(None);
            };
            rows.extend(
                reply.data["result"]
                    .as_array()
                    .ok_or("Invalid cached stock batch")?
                    .iter()
                    .cloned(),
            );
            if let Some(combined) = &mut combined {
                combined.fetched_at = combined.fetched_at.min(reply.fetched_at);
            } else {
                combined = Some(reply);
            }
        }
        if let Some(reply) = &mut combined {
            reply.data["result"] = Value::Array(rows);
        }
        Ok(combined)
    }
    fn missing(&self, request: &StockRequest, now: Instant, wall: f64) -> Result<StockRequest> {
        let mut missing = request.clone();
        if let Some(symbols) = &request.symbols {
            let mut new = Vec::new();
            for symbol in symbols {
                if self
                    .get(&request.batch_symbol(symbol).key(wall)?, now)
                    .is_none()
                {
                    new.push(symbol.clone());
                }
            }
            missing.symbols = Some(new);
        }
        Ok(missing)
    }
    fn store(
        &mut self,
        request: &StockRequest,
        reply: StockReply,
        now: Instant,
        wall: f64,
    ) -> Result<()> {
        if let Some(symbols) = &request.symbols {
            let rows = reply.data["result"]
                .as_array()
                .ok_or("Invalid stock batch response")?;
            if rows.len() > 200 {
                return Err("Invalid stock batch size".into());
            }
            for row in rows {
                let raw = row
                    .get("symbol")
                    .and_then(Value::as_str)
                    .ok_or("Invalid stock batch symbol")?;
                if !symbols.contains(&symbol(raw, None)?.0) {
                    return Err("Unexpected stock batch symbol".into());
                }
            }
            for name in symbols {
                let mut item = reply.clone();
                item.data["result"] = Value::Array(
                    rows.iter()
                        .filter(|row| {
                            row["symbol"]
                                .as_str()
                                .is_some_and(|s| s.eq_ignore_ascii_case(name))
                        })
                        .cloned()
                        .collect(),
                );
                self.put(
                    request.batch_symbol(name).key(wall)?,
                    item,
                    request.ttl(),
                    now,
                );
            }
        } else {
            self.put(request.key(wall)?, reply, request.ttl(), now);
        }
        Ok(())
    }
}

// Secrets deliberately have no Debug/Serialize IPC response implementation.
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Credentials {
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    client_secret: String,
    #[serde(default)]
    api_key: String,
}

fn credential_target(provider: Provider) -> &'static str {
    match provider {
        Provider::Toss => "com.pmh10401.penguinnotch.tossinvest",
        Provider::Finnhub => "com.pmh10401.penguinnotch.finnhub",
    }
}

#[cfg(windows)]
fn read_credentials(provider: Provider) -> Result<Option<Credentials>> {
    use windows::core::{HRESULT, PCWSTR};
    use windows::Win32::{
        Foundation::ERROR_NOT_FOUND,
        Security::Credentials::{CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC},
    };
    let target: Vec<u16> = credential_target(provider)
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut pointer: *mut CREDENTIALW = std::ptr::null_mut();
    unsafe {
        if let Err(e) = CredReadW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, 0, &mut pointer) {
            return if e.code() == HRESULT::from_win32(ERROR_NOT_FOUND.0) {
                Ok(None)
            } else {
                Err("Windows Credential Manager read failed".into())
            };
        }
        if pointer.is_null() {
            return Err("Windows Credential Manager returned no credential".into());
        }
        let item = &*pointer;
        let decoded = if item.CredentialBlobSize == 0
            || item.CredentialBlobSize > 2560
            || item.CredentialBlob.is_null()
        {
            Err("Invalid stored stock credential".into())
        } else {
            serde_json::from_slice(std::slice::from_raw_parts(
                item.CredentialBlob,
                item.CredentialBlobSize as usize,
            ))
            .map(Some)
            .map_err(|_| "Invalid stored stock credential".into())
        };
        CredFree(pointer as *const std::ffi::c_void);
        decoded
    }
}

#[cfg(windows)]
fn write_credentials(provider: Provider, credentials: Option<&Credentials>) -> Result<()> {
    use windows::core::{HRESULT, PCWSTR, PWSTR};
    use windows::Win32::{
        Foundation::ERROR_NOT_FOUND,
        Security::Credentials::{
            CredDeleteW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
        },
    };
    let mut target: Vec<u16> = credential_target(provider)
        .encode_utf16()
        .chain(Some(0))
        .collect();
    if let Some(credentials) = credentials {
        let mut blob =
            serde_json::to_vec(credentials).map_err(|_| "Could not encode stock credential")?;
        if blob.len() > 2560 {
            return Err("Stock credential is too long".into());
        }
        let mut user: Vec<u16> = "PenguinNotch Stocks"
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: PWSTR(target.as_mut_ptr()),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: PWSTR(user.as_mut_ptr()),
            ..Default::default()
        };
        let result = unsafe { CredWriteW(&credential, 0) }
            .map_err(|_| "Windows Credential Manager save failed".into());
        blob.fill(0);
        result
    } else {
        match unsafe { CredDeleteW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, 0) } {
            Ok(()) => Ok(()),
            Err(e) if e.code() == HRESULT::from_win32(ERROR_NOT_FOUND.0) => Ok(()),
            Err(_) => Err("Windows Credential Manager deletion failed".into()),
        }
    }
}

#[cfg(not(windows))]
fn read_credentials(_: Provider) -> Result<Option<Credentials>> {
    Ok(None)
}
#[cfg(not(windows))]
fn write_credentials(_: Provider, _: Option<&Credentials>) -> Result<()> {
    Err("Stock credentials require Windows Credential Manager".into())
}

#[derive(Serialize)]
pub struct CredentialStatus {
    toss: bool,
    finnhub: bool,
}
fn credential_status() -> Result<CredentialStatus> {
    let toss = read_credentials(Provider::Toss)?
        .is_some_and(|c| !c.client_id.is_empty() && !c.client_secret.is_empty());
    let finnhub = read_credentials(Provider::Finnhub)?.is_some_and(|c| !c.api_key.is_empty());
    Ok(CredentialStatus { toss, finnhub })
}

struct Token {
    value: String,
    expires: Instant,
}
fn parse_token(value: &Value, now: Instant) -> Result<Token> {
    let token = value
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= 16384 && s.bytes().all(|b| (33..=126).contains(&b)))
        .ok_or("Invalid stock authorization response")?;
    let seconds = value
        .get("expires_in")
        .map_or(Some(3600), Value::as_u64)
        .filter(|s| *s > 0 && *s <= 604800)
        .ok_or("Invalid stock token lifetime")?;
    Ok(Token {
        value: token.into(),
        expires: now + Duration::from_secs(seconds.saturating_sub(60).max(1)),
    })
}

struct Transport {
    agent: ureq::Agent,
    token: Option<Token>,
    cache: Cache,
    generation: u64,
    next_request: [Option<Instant>; 2],
    #[cfg(test)]
    test_base: Option<String>,
}

fn transport() -> Result<&'static Mutex<Transport>> {
    static TRANSPORT: OnceLock<std::result::Result<Mutex<Transport>, String>> = OnceLock::new();
    TRANSPORT
        .get_or_init(|| {
            let tls = native_tls::TlsConnector::new()
                .map_err(|_| "Could not initialize native stock TLS")?;
            let agent = ureq::AgentBuilder::new()
                .tls_connector(Arc::new(tls))
                .redirects(0)
                .timeout_connect(Duration::from_secs(5))
                .timeout_read(Duration::from_secs(10))
                .timeout_write(Duration::from_secs(10))
                .timeout(Duration::from_secs(15))
                .build();
            Ok(Mutex::new(Transport {
                agent,
                token: None,
                cache: Cache::default(),
                generation: 0,
                next_request: [None, None],
                #[cfg(test)]
                test_base: None,
            }))
        })
        .as_ref()
        .map_err(Clone::clone)
}

struct Context<'a> {
    app: &'a AppHandle,
    generation: u64,
    request: &'a StockRequest,
}
impl Context<'_> {
    fn check(&self) -> Result<()> {
        if GENERATION.load(Ordering::SeqCst) != self.generation {
            return Err(
                "Stock settings or credentials changed; retry with current settings".into(),
            );
        }
        let state = self.app.state::<crate::AppState>();
        let cfg = state.cfg.lock().map_err(|_| "Stock settings lock failed")?;
        let s = &cfg.stock_settings;
        if !s.enabled
            || s.provider != self.request.provider()
            || (self.request.private() && !s.forecasts_enabled)
        {
            return Err("Stock provider is disabled or has changed".into());
        }
        Ok(())
    }
}

#[derive(Default)]
struct Retries {
    authorization: bool,
    rate_limit: bool,
}
enum HttpFailure {
    Status(u16, Duration),
    Other(String),
}

fn retry_delay(header: Option<&str>, now: DateTime<Utc>) -> Duration {
    let seconds = header
        .and_then(|s| {
            s.parse::<u64>().ok().or_else(|| {
                DateTime::parse_from_rfc2822(s)
                    .ok()
                    .map(|d| (d.timestamp() - now.timestamp()).max(1) as u64)
            })
        })
        .unwrap_or(2)
        .clamp(1, 300);
    Duration::from_secs(seconds)
}

fn http_json(
    response: std::result::Result<ureq::Response, ureq::Error>,
) -> std::result::Result<Value, HttpFailure> {
    let response = match response {
        Ok(r) if (200..300).contains(&r.status()) => r,
        Ok(r) | Err(ureq::Error::Status(_, r)) => {
            return Err(HttpFailure::Status(
                r.status(),
                retry_delay(r.header("Retry-After"), Utc::now()),
            ))
        }
        Err(_) => {
            return Err(HttpFailure::Other(
                "Stock network request failed; retry later".into(),
            ))
        }
    };
    let mut body = Vec::new();
    response
        .into_reader()
        .take(MAX_BODY + 1)
        .read_to_end(&mut body)
        .map_err(|_| HttpFailure::Other("Could not read stock response".into()))?;
    if body.len() as u64 > MAX_BODY {
        return Err(HttpFailure::Other("Stock response is too large".into()));
    }
    serde_json::from_slice(&body)
        .map_err(|_| HttpFailure::Other("Invalid stock JSON response".into()))
}

fn sensitive_key(key: &str) -> bool {
    let key: String = key
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    [
        "token",
        "secret",
        "credential",
        "password",
        "authorization",
        "apikey",
        "clientid",
    ]
    .iter()
    .any(|word| key.contains(word))
}

fn scrub(value: &mut Value, secrets: &[&str]) {
    match value {
        Value::Object(map) => {
            map.retain(|key, _| !sensitive_key(key));
            for value in map.values_mut() {
                scrub(value, secrets);
            }
        }
        Value::Array(rows) => {
            for value in rows {
                scrub(value, secrets);
            }
        }
        Value::String(s)
            if secrets
                .iter()
                .any(|secret| !secret.is_empty() && s.contains(secret)) =>
        {
            *s = "[redacted]".into()
        }
        _ => (),
    }
}

impl Transport {
    fn endpoint(&self, provider: Provider, path: &str) -> String {
        #[cfg(test)]
        if let Some(base) = &self.test_base {
            return format!("{base}{path}");
        }
        format!(
            "{}{}",
            if provider == Provider::Toss {
                TOSS
            } else {
                FINNHUB
            },
            path
        )
    }
    fn perform(
        &mut self,
        request: &StockRequest,
        credentials: impl FnOnce() -> Result<Credentials>,
        check: &impl Fn() -> Result<()>,
    ) -> Result<StockReply> {
        check()?;
        let wall = Utc::now().timestamp_millis() as f64;
        if let Some(reply) = self.cache.lookup(request, Instant::now(), wall)? {
            return Ok(reply);
        }
        let missing = self.cache.missing(request, Instant::now(), wall)?;
        let data = self.fetch(&missing, &credentials()?, check)?;
        check()?;
        let reply = StockReply {
            data,
            fetched_at: Utc::now().timestamp_millis(),
        };
        self.cache.store(&missing, reply, Instant::now(), wall)?;
        self.cache
            .lookup(request, Instant::now(), wall)?
            .ok_or_else(|| "Stock cache expired while fetching; retry".into())
    }
    fn pace(&mut self, provider: Provider, check: &impl Fn() -> Result<()>) -> Result<()> {
        check()?;
        let index = provider as usize;
        if let Some(at) = self.next_request[index] {
            let delay = at.saturating_duration_since(Instant::now());
            if delay > Duration::from_secs(2) {
                return Err(format!(
                    "Stock rate limit; retry after {} seconds",
                    delay.as_secs() + 1
                ));
            }
            if !delay.is_zero() {
                std::thread::sleep(delay);
            }
        }
        check()?;
        self.next_request[index] = Some(
            Instant::now()
                + Duration::from_millis(if provider == Provider::Toss {
                    400
                } else {
                    1100
                }),
        );
        Ok(())
    }
    fn failure(
        &mut self,
        provider: Provider,
        failure: HttpFailure,
        retries: &mut Retries,
    ) -> Result<()> {
        let (code, delay) = match failure {
            HttpFailure::Other(error) => {
                self.next_request[provider as usize] =
                    Some(Instant::now() + Duration::from_secs(5));
                return Err(error);
            }
            HttpFailure::Status(code, delay) => (code, delay),
        };
        if code == 429 {
            self.next_request[provider as usize] = Some(Instant::now() + delay);
            if !retries.rate_limit && delay <= Duration::from_secs(2) {
                retries.rate_limit = true;
                return Ok(());
            }
            return Err(format!(
                "Stock HTTP 429; retry after {} seconds",
                delay.as_secs()
            ));
        }
        self.next_request[provider as usize] = Some(
            Instant::now() + Duration::from_secs(if code == 401 || code == 403 { 30 } else { 5 }),
        );
        Err(format!(
            "Stock HTTP {code}; check provider access or retry later"
        ))
    }
    fn token(
        &mut self,
        credentials: &Credentials,
        check: &impl Fn() -> Result<()>,
        retries: &mut Retries,
    ) -> Result<String> {
        if let Some(token) = &self.token {
            if token.expires > Instant::now() {
                return Ok(token.value.clone());
            }
        }
        self.token = None;
        if credentials.client_id.is_empty() || credentials.client_secret.is_empty() {
            return Err("Save Toss credentials in Windows Credential Manager first".into());
        }
        loop {
            self.pace(Provider::Toss, check)?;
            let result = http_json(
                self.agent
                    .post(&self.endpoint(Provider::Toss, "/oauth2/token"))
                    .send_form(&[
                        ("grant_type", "client_credentials"),
                        ("client_id", &credentials.client_id),
                        ("client_secret", &credentials.client_secret),
                    ]),
            );
            check()?;
            match result {
                Ok(value) => {
                    let token = parse_token(&value, Instant::now())?;
                    let text = token.value.clone();
                    self.token = Some(token);
                    return Ok(text);
                }
                Err(error) => self.failure(Provider::Toss, error, retries)?,
            }
        }
    }
    fn get(
        &mut self,
        request: &StockRequest,
        credentials: &Credentials,
        check: &impl Fn() -> Result<()>,
        retries: &mut Retries,
    ) -> Result<Value> {
        loop {
            check()?;
            let provider = request.provider();
            let authorization = if provider == Provider::Toss {
                self.token(credentials, check, retries)?
            } else if credentials.api_key.is_empty() {
                return Err("Save a Finnhub key in Windows Credential Manager first".into());
            } else {
                credentials.api_key.clone()
            };
            self.pace(provider, check)?;
            let mut http = self
                .agent
                .get(&self.endpoint(provider, request.path()))
                .set("Accept", "application/json");
            http = if provider == Provider::Toss {
                http.set("Authorization", &format!("Bearer {authorization}"))
            } else {
                http.set("X-Finnhub-Token", &authorization)
            };
            for (key, value) in request.query() {
                http = http.query(&key, &value);
            }
            if let Some(account) = request.account_seq {
                http = http.set("X-Tossinvest-Account", &account.to_string());
            }
            let response = http_json(http.call());
            check()?;
            match response {
                Ok(mut value) => {
                    if !value.is_object()
                        || value.get("error").is_some_and(|v| !v.is_null())
                        || (provider == Provider::Toss && value.get("result").is_none())
                    {
                        return Err("Invalid stock provider response".into());
                    }
                    scrub(
                        &mut value,
                        &[
                            &authorization,
                            &credentials.client_id,
                            &credentials.client_secret,
                            &credentials.api_key,
                        ],
                    );
                    return Ok(value);
                }
                Err(HttpFailure::Status(401, _))
                    if provider == Provider::Toss && !retries.authorization =>
                {
                    self.token = None;
                    retries.authorization = true;
                }
                Err(error) => {
                    if matches!(error, HttpFailure::Status(401, _)) && provider == Provider::Toss {
                        self.token = None;
                    }
                    self.failure(provider, error, retries)?;
                }
            }
        }
    }
    fn fetch(
        &mut self,
        request: &StockRequest,
        credentials: &Credentials,
        check: &impl Fn() -> Result<()>,
    ) -> Result<Value> {
        let mut retries = Retries::default();
        if request.kind != Kind::Candles {
            return self.get(request, credentials, check, &mut retries);
        }
        let mut page_request = request.clone();
        let mut merged = BTreeMap::new();
        let mut envelope = None;
        let target = request.count.unwrap_or(200) as usize;
        for _ in 0..if request.interval == Some(Interval::TenMinutes) {
            8
        } else {
            1
        } {
            page_request.count =
                Some((target - merged.len() + usize::from(!merged.is_empty())).min(200) as u32);
            let page = self.get(&page_request, credentials, check, &mut retries)?;
            let (rows, next) = candle_page(&page, page_request.before.as_deref())?;
            let old_count = merged.len();
            for (timestamp, row) in rows {
                merged.entry(timestamp).or_insert(row);
            }
            let next_owned = next.map(str::to_string);
            envelope = Some(page);
            if merged.len() >= target || next_owned.is_none() {
                break;
            }
            if merged.len() == old_count {
                return Err("Stock candle pagination made no progress".into());
            }
            page_request.before = next_owned;
        }
        let mut result = envelope.ok_or("Missing stock candle response")?;
        let rows: Vec<Value> = merged
            .into_iter()
            .rev()
            .take(target)
            .map(|(_, row)| row)
            .collect();
        // An inclusive cursor points to the oldest returned row, including when a page was capped.
        if result["result"]["nextBefore"].is_string() {
            result["result"]["nextBefore"] = rows
                .last()
                .map(|v| v["timestamp"].clone())
                .unwrap_or(Value::Null);
        }
        result["result"]["candles"] = Value::Array(rows);
        Ok(result)
    }
}

fn candle_page<'a>(
    page: &'a Value,
    before: Option<&str>,
) -> Result<(Vec<(i64, Value)>, Option<&'a str>)> {
    let result = page
        .get("result")
        .and_then(Value::as_object)
        .ok_or("Invalid candle result")?;
    let rows = result
        .get("candles")
        .and_then(Value::as_array)
        .filter(|rows| rows.len() <= 200)
        .ok_or("Invalid candle array")?;
    let mut parsed = Vec::with_capacity(rows.len());
    let bound = before.map(iso_millis).transpose()?;
    for row in rows {
        let at = iso_millis(
            row.get("timestamp")
                .and_then(Value::as_str)
                .ok_or("Invalid candle timestamp")?,
        )?;
        if bound.is_some_and(|b| at > b) {
            return Err("Candle exceeds its requested cursor".into());
        }
        for field in ["openPrice", "highPrice", "lowPrice", "closePrice", "volume"] {
            let number = row
                .get(field)
                .and_then(|v| v.as_f64().or_else(|| v.as_str()?.parse::<f64>().ok()))
                .filter(|v| v.is_finite() && *v >= 0.0)
                .ok_or("Invalid candle number")?;
            if field != "volume" && number <= 0.0 {
                return Err("Invalid candle price".into());
            }
        }
        parsed.push((at, row.clone()));
    }
    let next = match result.get("nextBefore") {
        None | Some(Value::Null) => None,
        Some(Value::String(next)) => {
            let at = iso_millis(next)?;
            if bound.is_some_and(|b| at >= b)
                || parsed
                    .iter()
                    .map(|(at, _)| *at)
                    .min()
                    .is_some_and(|oldest| at > oldest)
            {
                return Err("Invalid candle pagination cursor".into());
            }
            Some(next.as_str())
        }
        _ => return Err("Invalid candle pagination cursor".into()),
    };
    Ok((parsed, next))
}

#[tauri::command]
pub async fn get_stock_settings(app: AppHandle) -> Result<StockSettings> {
    let state = app.state::<crate::AppState>();
    let settings = state
        .cfg
        .lock()
        .map_err(|_| "Stock settings lock failed")?
        .stock_settings
        .clone();
    settings.validated()
}

// Config saves share AppState.cfg with existing settings writers. A failed write never changes memory.
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or("Missing stock data directory")?;
    std::fs::create_dir_all(parent).map_err(|_| "Could not create stock data directory")?;
    static SERIAL: AtomicU64 = AtomicU64::new(0);
    let temp = parent.join(format!(
        ".stock-config-{}-{}.tmp",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|_| "Could not create stock settings temporary file")?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "Could not save stock settings")?;
        drop(file);
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows::core::PCWSTR;
            use windows::Win32::Storage::FileSystem::{
                MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
            };
            let from: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
            let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            unsafe {
                MoveFileExW(
                    PCWSTR(from.as_ptr()),
                    PCWSTR(to.as_ptr()),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                )
            }
            .map_err(|_| "Could not replace stock settings")?;
        }
        #[cfg(not(windows))]
        std::fs::rename(&temp, path).map_err(|_| "Could not replace stock settings")?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result
}

#[tauri::command]
pub async fn set_stock_settings(app: AppHandle, settings: StockSettings) -> Result<StockSettings> {
    let settings = settings.validated()?;
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<crate::AppState>();
        let mut cfg = state.cfg.lock().map_err(|_| "Stock settings lock failed")?;
        let mut next = cfg.clone();
        next.stock_settings = settings.clone();
        let bytes =
            serde_json::to_vec_pretty(&next).map_err(|_| "Could not encode stock settings")?;
        atomic_write(&crate::config::config_path(), &bytes)?;
        cfg.stock_settings = settings.clone();
        GENERATION.fetch_add(1, Ordering::SeqCst);
        drop(cfg);
        app.emit("stock-settings", &settings)
            .map_err(|_| "Settings saved, but notification failed")?;
        Ok(settings)
    })
    .await
    .map_err(|_| "Stock settings task failed")?
}

#[tauri::command]
pub async fn get_stock_credential_status() -> Result<CredentialStatus> {
    tauri::async_runtime::spawn_blocking(credential_status)
        .await
        .map_err(|_| "Stock credential task failed")?
}

fn update_credentials(
    provider: Provider,
    client_id: Option<String>,
    client_secret: Option<String>,
    api_key: Option<String>,
) -> Result<CredentialStatus> {
    let mut transport = transport()?
        .lock()
        .map_err(|_| "Stock transport lock failed")?;
    if (provider == Provider::Toss && api_key.is_some())
        || (provider == Provider::Finnhub && (client_id.is_some() || client_secret.is_some()))
    {
        return Err("Credentials do not match the selected provider".into());
    }
    let mut credentials = read_credentials(provider)?.unwrap_or_default();
    for (input, field) in [
        (client_id, &mut credentials.client_id),
        (client_secret, &mut credentials.client_secret),
        (api_key, &mut credentials.api_key),
    ] {
        if let Some(input) = input {
            let text = input.trim();
            // Blank masked fields retain their saved value, matching the Swift credential editor.
            if text.is_empty() {
                continue;
            }
            if text.len() > 1024 || !text.bytes().all(|b| (33..=126).contains(&b)) {
                return Err("Invalid stock credential input".into());
            }
            *field = text.into();
        }
    }
    if (provider == Provider::Toss
        && (credentials.client_id.is_empty() || credentials.client_secret.is_empty()))
        || (provider == Provider::Finnhub && credentials.api_key.is_empty())
    {
        return Err("Supply the required stock credentials".into());
    }
    write_credentials(provider, Some(&credentials))?;
    if provider == Provider::Toss {
        transport.token = None;
    }
    transport.cache.entries.clear();
    GENERATION.fetch_add(1, Ordering::SeqCst);
    credential_status()
}

#[tauri::command]
pub async fn save_stock_credentials(
    provider: Provider,
    client_id: Option<String>,
    client_secret: Option<String>,
    api_key: Option<String>,
) -> Result<CredentialStatus> {
    tauri::async_runtime::spawn_blocking(move || {
        update_credentials(provider, client_id, client_secret, api_key)
    })
    .await
    .map_err(|_| "Stock credential task failed")?
}

#[tauri::command]
pub async fn delete_stock_credentials(provider: Provider) -> Result<CredentialStatus> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut transport = transport()?
            .lock()
            .map_err(|_| "Stock transport lock failed")?;
        write_credentials(provider, None)?;
        if provider == Provider::Toss {
            transport.token = None;
        }
        transport.cache.entries.clear();
        GENERATION.fetch_add(1, Ordering::SeqCst);
        credential_status()
    })
    .await
    .map_err(|_| "Stock credential task failed")?
}

#[tauri::command]
pub async fn stock_request(app: AppHandle, request: StockRequest) -> Result<StockReply> {
    let (request, generation) = {
        let state = app.state::<crate::AppState>();
        let cfg = state.cfg.lock().map_err(|_| "Stock settings lock failed")?;
        (
            request.validated(&cfg.stock_settings)?,
            GENERATION.load(Ordering::SeqCst),
        )
    };
    tauri::async_runtime::spawn_blocking(move || {
        let context = Context {
            app: &app,
            generation,
            request: &request,
        };
        context.check()?;
        // ponytail: one blocking-worker queue keeps token renewal safe; add independent lanes only if latency requires them.
        let mut transport = transport()?
            .lock()
            .map_err(|_| "Stock transport lock failed")?;
        context.check()?;
        if transport.generation != generation {
            transport.cache.entries.clear();
            transport.generation = generation;
        }
        transport.perform(
            &request,
            || {
                read_credentials(request.provider())?
                    .ok_or_else(|| "Stock credentials are not configured".into())
            },
            &|| context.check(),
        )
    })
    .await
    .map_err(|_| "Stock request task failed")?
}

// This whitelist is the shared frontend contract, not a generic JSON archive. In particular,
// traces cannot carry forecast evidence, and neither table can carry account/credential fields.
const TREND_FIELDS: &[&str] = &[
    "stockID",
    "name",
    "market",
    "currency",
    "model",
    "createdAt",
    "quoteAt",
    "sessionStart",
    "sessionEnd",
    "inputPrice",
    "expectedClose",
];
const FORECAST_FIELDS: &[&str] = &[
    "previousClose",
    "lowerClose",
    "upperClose",
    "riseProbability",
    "observations",
    "capture",
    "evidence",
    "actualClose",
    "evaluatedAt",
];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StockHistory {
    version: u32,
    trends: Vec<Value>,
    forecasts: Vec<Value>,
}

impl Default for StockHistory {
    fn default() -> Self {
        Self {
            version: 1,
            trends: vec![],
            forecasts: vec![],
        }
    }
}

fn exact_fields(value: &Value, fields: &[&str]) -> Result<()> {
    let object = value.as_object().ok_or("History row must be an object")?;
    if object.len() != fields.len() || fields.iter().any(|key| !object.contains_key(*key)) {
        return Err("Stock history contains missing or disallowed fields".into());
    }
    Ok(())
}

fn number(value: &Value) -> Result<f64> {
    value
        .as_f64()
        .filter(|n| n.is_finite())
        .ok_or_else(|| "History numbers must be finite JSON numbers".into())
}

fn positive(value: &Value) -> Result<f64> {
    let number = number(value)?;
    if number <= 0.0 {
        return Err("History prices must be positive".into());
    }
    Ok(number)
}

fn history_time(value: &Value) -> Result<f64> {
    let number = number(value)?;
    if !(0.0..=253_402_300_799_000.0).contains(&number) {
        return Err("History timestamps must be epoch milliseconds from 1970 through 9999".into());
    }
    Ok(number)
}

fn nth_sunday(year: i32, month: u32, nth: u32) -> NaiveDate {
    let first = NaiveDate::from_ymd_opt(year, month, 1).expect("valid calendar month");
    let first_sunday = 1 + (7 - first.weekday().num_days_from_sunday()) % 7;
    first
        .with_day(first_sunday + (nth - 1) * 7)
        .expect("valid Sunday")
}

fn last_sunday(year: i32, month: u32) -> NaiveDate {
    let day = if month == 4 { 30 } else { 31 };
    let last = NaiveDate::from_ymd_opt(year, month, day).expect("valid calendar month");
    last.with_day(day - last.weekday().num_days_from_sunday())
        .expect("valid Sunday")
}

// No timezone dependency: US/Eastern federal rules and Seoul's two post-1970 DST summers.
// Rules: https://data.iana.org/time-zones/tzdb/{northamerica,asia}.
fn market_day(timestamp: f64, market: Market) -> Result<NaiveDate> {
    let utc = Utc
        .timestamp_millis_opt(timestamp as i64)
        .single()
        .ok_or("Invalid history timestamp")?;
    let offset = if market == Market::Kr {
        let daylight = (1987..=1988).contains(&utc.year()) && {
            let start = nth_sunday(utc.year(), 5, 2)
                .pred_opt()
                .unwrap()
                .and_hms_opt(17, 0, 0)
                .unwrap();
            let end = nth_sunday(utc.year(), 10, 2)
                .pred_opt()
                .unwrap()
                .and_hms_opt(17, 0, 0)
                .unwrap();
            utc.naive_utc() >= start && utc.naive_utc() < end
        };
        if daylight {
            10 * 3600
        } else {
            9 * 3600
        }
    } else {
        let year = utc.year();
        let start = if year >= 2007 {
            nth_sunday(year, 3, 2)
        } else if year == 1974 {
            NaiveDate::from_ymd_opt(year, 1, 6).unwrap()
        } else if year == 1975 {
            NaiveDate::from_ymd_opt(year, 2, 23).unwrap()
        } else if year >= 1987 {
            nth_sunday(year, 4, 1)
        } else {
            last_sunday(year, 4)
        };
        let end = if year >= 2007 {
            nth_sunday(year, 11, 1)
        } else {
            last_sunday(year, 10)
        };
        let daylight = utc.naive_utc() >= start.and_hms_opt(7, 0, 0).unwrap()
            && utc.naive_utc() < end.and_hms_opt(6, 0, 0).unwrap();
        if daylight {
            -4 * 3600
        } else {
            -5 * 3600
        }
    };
    utc.checked_add_signed(chrono::Duration::seconds(offset))
        .map(|d| d.date_naive())
        .ok_or_else(|| "Invalid market date".into())
}

fn history_id(row: &Value, forecast: bool) -> String {
    let suffix = if forecast {
        row["capture"].as_str().unwrap().to_string()
    } else {
        (row["createdAt"].as_f64().unwrap() / 60_000.0)
            .floor()
            .to_string()
    };
    format!(
        "{}|{}|{}|{}",
        row["stockID"].as_str().unwrap(),
        row["sessionStart"].as_f64().unwrap(),
        row["model"].as_str().unwrap(),
        suffix
    )
}

fn validate_row(row: &Value, forecast: bool) -> Result<()> {
    let fields: Vec<&str> = TREND_FIELDS
        .iter()
        .copied()
        .chain(if forecast {
            FORECAST_FIELDS.iter().copied()
        } else {
            [].iter().copied()
        })
        .collect();
    exact_fields(row, &fields)?;
    let market = match row["market"].as_str() {
        Some("kr") => Market::Kr,
        Some("us") => Market::Us,
        _ => return Err("Invalid history market".into()),
    };
    let stock_id = row["stockID"].as_str().ok_or("Invalid history stockID")?;
    let parsed = symbol(stock_id, Some(market))?;
    let prefix = if market == Market::Kr { "kr" } else { "us" };
    if stock_id != format!("{prefix}:{}", parsed.0)
        || row["currency"].as_str() != Some(if market == Market::Kr { "KRW" } else { "USD" })
    {
        return Err("History stockID/market/currency disagree".into());
    }
    for (key, limit) in [("name", 200), ("model", 100)] {
        if !row[key]
            .as_str()
            .is_some_and(|s| valid_text(s, limit) && !s.contains('|'))
        {
            return Err("Invalid history public text".into());
        }
    }
    let created = history_time(&row["createdAt"])?;
    let quoted = history_time(&row["quoteAt"])?;
    let start = history_time(&row["sessionStart"])?;
    let end = history_time(&row["sessionEnd"])?;
    if !(start <= quoted && quoted <= created && created < end && created - quoted <= 120_000.0) {
        return Err("History quote must be fresh and within its session".into());
    }
    positive(&row["inputPrice"])?;
    positive(&row["expectedClose"])?;
    if !forecast {
        return Ok(());
    }
    let previous = positive(&row["previousClose"])?;
    if positive(&row["lowerClose"])? > positive(&row["upperClose"])?
        || !(0.0..=1.0).contains(&number(&row["riseProbability"])?)
    {
        return Err("Invalid forecast price range or probability".into());
    }
    let observations = number(&row["observations"])?;
    if observations.fract() != 0.0 || !(20.0..=60.0).contains(&observations) {
        return Err("Forecast observations must be an integer from 20 to 60".into());
    }
    match row["capture"].as_str() {
        Some("manual") => (),
        Some("scheduled") if (3_300_000.0..=3_600_000.0).contains(&(end - created)) => (),
        _ => return Err("Invalid forecast capture time".into()),
    }
    let evidence = &row["evidence"];
    exact_fields(evidence, &["adjusted", "closes"])?;
    if evidence["adjusted"] != true {
        return Err("Forecast evidence must use adjusted completed closes".into());
    }
    let closes = evidence["closes"]
        .as_array()
        .ok_or("Invalid forecast evidence")?;
    if closes.len() != observations as usize + 1 {
        return Err("Forecast evidence does not match observations".into());
    }
    let day = market_day(start, market)?;
    let mut prior_day = day;
    let mut last_price: Option<f64> = None;
    let mut returns = Vec::new();
    for close in closes {
        exact_fields(close, &["date", "price"])?;
        let at = market_day(history_time(&close["date"])?, market)?;
        let price = positive(&close["price"])?;
        if at >= prior_day {
            return Err("Forecast evidence must contain descending completed market days".into());
        }
        if let Some(prior) = last_price {
            returns.push((prior / price).ln());
        } else if price != previous {
            return Err("Forecast previous close disagrees with evidence".into());
        }
        last_price = Some(price);
        prior_day = at;
    }
    let mean = returns.iter().sum::<f64>() / returns.len() as f64;
    let variance = returns
        .iter()
        .map(|value| (value - mean).powi(2))
        .sum::<f64>()
        / (returns.len() - 1) as f64;
    if !variance.is_finite() || variance <= 0.0 {
        return Err("Forecast evidence has no usable return variance".into());
    }
    match (row["actualClose"].is_null(), row["evaluatedAt"].is_null()) {
        (true, true) => (),
        (false, false) => {
            positive(&row["actualClose"])?;
            let evaluated = history_time(&row["evaluatedAt"])?;
            if evaluated < end || market_day(evaluated, market)? <= day {
                return Err("A forecast can be scored only on the next market local date".into());
            }
        }
        _ => return Err("Forecast actualClose and evaluatedAt must be paired".into()),
    }
    Ok(())
}

impl StockHistory {
    fn validate(&self) -> Result<()> {
        if self.version != 1 {
            return Err("Unsupported stock history version; archive preserved".into());
        }
        for (forecast, rows) in [(false, &self.trends), (true, &self.forecasts)] {
            let mut ids = HashSet::new();
            for row in rows {
                validate_row(row, forecast)?;
                if !ids.insert(history_id(row, forecast)) {
                    return Err("Duplicate stock history record".into());
                }
            }
        }
        validate_traces(&self.trends)
    }
}

fn validate_traces(rows: &[Value]) -> Result<()> {
    let mut groups: HashMap<String, Vec<&Value>> = HashMap::new();
    for row in rows {
        groups
            .entry(format!(
                "{}|{}|{}",
                row["stockID"],
                row["sessionStart"].as_f64().unwrap(),
                row["model"]
            ))
            .or_default()
            .push(row);
    }
    for rows in groups.values_mut() {
        rows.sort_by(|a, b| {
            a["createdAt"]
                .as_f64()
                .unwrap()
                .total_cmp(&b["createdAt"].as_f64().unwrap())
        });
        for pair in rows.windows(2) {
            if pair[0]["quoteAt"].as_f64().unwrap() >= pair[1]["quoteAt"].as_f64().unwrap()
                || (pair[0]["createdAt"].as_f64().unwrap() / 60000.0).floor()
                    >= (pair[1]["createdAt"].as_f64().unwrap() / 60000.0).floor()
            {
                return Err("Trace quotes must advance, at most one point per minute".into());
            }
        }
    }
    Ok(())
}

fn merge_history(mut stored: StockHistory, incoming: StockHistory) -> Result<StockHistory> {
    stored.validate()?;
    incoming.validate()?;
    for (forecast, previous, new) in [
        (false, &mut stored.trends, incoming.trends),
        (true, &mut stored.forecasts, incoming.forecasts),
    ] {
        let mut ids: HashMap<String, usize> = previous
            .iter()
            .enumerate()
            .map(|(i, row)| (history_id(row, forecast), i))
            .collect();
        for row in new {
            let id = history_id(&row, forecast);
            if let Some(index) = ids.get(&id) {
                let old = &previous[*index];
                if old == &row {
                    continue;
                }
                if !forecast {
                    return Err("An observed trace point cannot be rewritten".into());
                }
                let mut inputs = old.clone();
                inputs["actualClose"] = row["actualClose"].clone();
                inputs["evaluatedAt"] = row["evaluatedAt"].clone();
                if inputs != row {
                    return Err("Recorded forecast inputs cannot be rewritten".into());
                }
                if !old["actualClose"].is_null() {
                    // A stale sole-writer snapshot may still contain an unresolved copy.
                    if row["actualClose"].is_null() {
                        continue;
                    }
                    return Err("A scored forecast cannot be rewritten".into());
                }
                previous[*index] = row;
            } else {
                ids.insert(id, previous.len());
                previous.push(row);
            }
        }
    }
    stored.validate()?;
    Ok(stored)
}

const HISTORY_ERROR: &str =
    "Stock history is unreadable or has an unknown schema; original archive preserved";

fn read_history(connection: &rusqlite::Connection) -> Result<StockHistory> {
    let version: u32 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|_| HISTORY_ERROR)?;
    if version != 1 {
        return Err(HISTORY_ERROR.into());
    }
    let mut statement = connection
        .prepare("SELECT kind, id, record FROM stock_history ORDER BY day, id")
        .map_err(|_| HISTORY_ERROR)?;
    let records = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|_| HISTORY_ERROR)?;
    let mut history = StockHistory::default();
    for record in records {
        let (kind, id, text) = record.map_err(|_| HISTORY_ERROR)?;
        let value: Value = serde_json::from_str(&text).map_err(|_| HISTORY_ERROR)?;
        let forecast = match kind.as_str() {
            "trend" => false,
            "forecast" => true,
            _ => return Err(HISTORY_ERROR.into()),
        };
        validate_row(&value, forecast).map_err(|_| HISTORY_ERROR)?;
        if history_id(&value, forecast) != id {
            return Err(HISTORY_ERROR.into());
        }
        if forecast {
            history.forecasts.push(value);
        } else {
            history.trends.push(value);
        }
    }
    history.validate().map_err(|_| HISTORY_ERROR)?;
    Ok(history)
}

fn load_history_at(path: &Path) -> Result<StockHistory> {
    if !path.try_exists().map_err(|_| HISTORY_ERROR)? {
        return Ok(StockHistory::default());
    }
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|_| HISTORY_ERROR)?;
    read_history(&connection)
}

fn save_history_at(path: &Path, incoming: StockHistory) -> Result<()> {
    use rusqlite::OptionalExtension;
    incoming.validate()?;
    let existing = path.try_exists().map_err(|_| HISTORY_ERROR)?;
    // Full integrity and semantic verification once on first access. Later writes read only
    // conflicting forecast IDs and the affected trace groups; explicit load still returns all days.
    static VERIFIED: OnceLock<Mutex<HashSet<std::path::PathBuf>>> = OnceLock::new();
    let verified = VERIFIED.get_or_init(|| Mutex::new(HashSet::new()));
    if existing {
        let read =
            rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|_| HISTORY_ERROR)?;
        let version: u32 = read
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(|_| HISTORY_ERROR)?;
        if version != 1 {
            return Err(HISTORY_ERROR.into());
        }
        if !verified.lock().map_err(|_| HISTORY_ERROR)?.contains(path) {
            let integrity: String = read
                .query_row("PRAGMA quick_check", [], |row| row.get(0))
                .map_err(|_| HISTORY_ERROR)?;
            if integrity != "ok" {
                return Err(HISTORY_ERROR.into());
            }
            read_history(&read)?;
        }
    }
    let parent = path.parent().ok_or("Missing stock history directory")?;
    std::fs::create_dir_all(parent).map_err(|_| "Could not create stock history directory")?;
    let mut connection =
        rusqlite::Connection::open(path).map_err(|_| "Could not open stock history")?;
    connection
        .busy_timeout(Duration::from_secs(5))
        .map_err(|_| "Could not set stock history timeout")?;
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "Stock history is busy; retry later")?;
    if !existing {
        transaction.execute_batch("CREATE TABLE stock_history (kind TEXT NOT NULL, id TEXT NOT NULL, day TEXT NOT NULL, record TEXT NOT NULL, PRIMARY KEY(kind,id)); PRAGMA user_version=1;")
            .map_err(|_| "Could not initialize stock history; original file preserved")?;
    }
    let version: u32 = transaction
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|_| HISTORY_ERROR)?;
    if version != 1 {
        return Err(HISTORY_ERROR.into());
    }
    let mut previous = StockHistory::default();
    let mut groups = HashSet::new();
    for row in &incoming.trends {
        let prefix = format!(
            "{}|{}|{}",
            row["stockID"].as_str().unwrap(),
            row["sessionStart"].as_f64().unwrap(),
            row["model"].as_str().unwrap()
        );
        if !groups.insert(prefix.clone()) {
            continue;
        }
        let mut query = transaction
            .prepare("SELECT id,record FROM stock_history WHERE kind='trend' AND id>=?1 AND id<?2")
            .map_err(|_| HISTORY_ERROR)?;
        let stored = query
            .query_map(
                rusqlite::params![format!("{prefix}|"), format!("{prefix}}}")],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .map_err(|_| HISTORY_ERROR)?;
        for record in stored {
            let (id, text) = record.map_err(|_| HISTORY_ERROR)?;
            let row: Value = serde_json::from_str(&text).map_err(|_| HISTORY_ERROR)?;
            validate_row(&row, false).map_err(|_| HISTORY_ERROR)?;
            if id != history_id(&row, false) {
                return Err(HISTORY_ERROR.into());
            }
            previous.trends.push(row);
        }
    }
    for row in &incoming.forecasts {
        let text: Option<String> = transaction
            .query_row(
                "SELECT record FROM stock_history WHERE kind='forecast' AND id=?1",
                [history_id(row, true)],
                |row| row.get(0),
            )
            .optional()
            .map_err(|_| HISTORY_ERROR)?;
        if let Some(text) = text {
            previous
                .forecasts
                .push(serde_json::from_str(&text).map_err(|_| HISTORY_ERROR)?);
        }
    }
    previous.validate().map_err(|_| HISTORY_ERROR)?;
    let merged = merge_history(previous.clone(), incoming)?;
    {
        let mut statement = transaction.prepare("INSERT INTO stock_history(kind,id,day,record) VALUES (?1,?2,?3,?4) ON CONFLICT(kind,id) DO UPDATE SET record=excluded.record")
            .map_err(|_| "Could not prepare stock history write")?;
        for (forecast, rows, old) in [
            (false, &merged.trends, &previous.trends),
            (true, &merged.forecasts, &previous.forecasts),
        ] {
            let old: HashMap<String, &Value> = old
                .iter()
                .map(|row| (history_id(row, forecast), row))
                .collect();
            for row in rows {
                let id = history_id(row, forecast);
                if old.get(&id).is_some_and(|old| *old == row) {
                    continue;
                }
                let market = if row["market"] == "kr" {
                    Market::Kr
                } else {
                    Market::Us
                };
                let day = market_day(row["sessionStart"].as_f64().unwrap(), market)?.to_string();
                let encoded =
                    serde_json::to_string(row).map_err(|_| "Could not encode stock history")?;
                statement
                    .execute(rusqlite::params![
                        if forecast { "forecast" } else { "trend" },
                        id,
                        day,
                        encoded
                    ])
                    .map_err(|_| "Could not save stock history; existing records retained")?;
            }
        }
    }
    transaction
        .commit()
        .map_err(|_| "Could not commit stock history; existing records retained")?;
    verified
        .lock()
        .map_err(|_| HISTORY_ERROR)?
        .insert(path.to_path_buf());
    Ok(())
}

fn history_path() -> Result<std::path::PathBuf> {
    // Match config::config_path, but refuse its relative fallback for persistent history.
    dirs::config_dir()
        .map(|dir| dir.join("penguinnotch").join("stock-history.sqlite3"))
        .ok_or_else(|| "Windows configuration data directory is unavailable".into())
}

#[tauri::command]
pub async fn load_stock_history() -> Result<StockHistory> {
    tauri::async_runtime::spawn_blocking(|| {
        let _lock = HISTORY_LOCK
            .lock()
            .map_err(|_| "Stock history lock failed")?;
        load_history_at(&history_path()?)
    })
    .await
    .map_err(|_| "Stock history task failed")?
}

#[tauri::command]
pub async fn save_stock_history(history: StockHistory) -> Result<()> {
    tauri::async_runtime::spawn_blocking(move || {
        let _lock = HISTORY_LOCK
            .lock()
            .map_err(|_| "Stock history lock failed")?;
        save_history_at(&history_path()?, history)
    })
    .await
    .map_err(|_| "Stock history task failed")?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::sync::{atomic::AtomicBool, Barrier};

    fn settings(provider: Provider) -> StockSettings {
        StockSettings {
            enabled: true,
            provider,
            ..Default::default()
        }
    }
    fn request(value: Value) -> StockRequest {
        let raw: StockRequest = serde_json::from_value(value).unwrap();
        let mut settings = settings(raw.provider());
        settings.forecasts_enabled = true;
        settings.account_seq = 7;
        raw.validated(&settings).unwrap()
    }
    fn ms(text: &str) -> f64 {
        iso_millis(text).unwrap() as f64
    }
    fn trace(at: f64) -> Value {
        json!({"stockID":"us:AAPL","name":"Apple","market":"us","currency":"USD",
            "model":"GBM zero drift v1", "createdAt":at,"quoteAt":at,"sessionStart":ms("2026-09-25T13:30:00Z"),
            "sessionEnd":ms("2026-09-25T20:00:00Z"),"inputPrice":100.0,"expectedClose":100.0})
    }
    fn forecast() -> Value {
        let mut row = trace(ms("2026-09-25T19:00:00Z"));
        let closes: Vec<Value> = (0..21)
            .map(|i| {
                json!({"date":ms("2026-09-24T04:00:00Z")-i as f64*86400000.0,
            "price":100.0 + (i%3) as f64})
            })
            .collect();
        let object = row.as_object_mut().unwrap();
        for (key, value) in json!({"previousClose":100.0,"lowerClose":90.0,"upperClose":110.0,
            "riseProbability":0.5,"observations":20,"capture":"scheduled",
            "evidence":{"adjusted":true,"closes":closes},"actualClose":null,"evaluatedAt":null})
        .as_object()
        .unwrap()
        {
            object.insert(key.clone(), value.clone());
        }
        row
    }
    fn archive(trends: Vec<Value>, forecasts: Vec<Value>) -> StockHistory {
        StockHistory {
            version: 1,
            trends,
            forecasts,
        }
    }
    fn temp_path(name: &str) -> std::path::PathBuf {
        static ID: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "penguinnotch-stock-test-{}-{}-{}",
            std::process::id(),
            Utc::now().timestamp_nanos_opt().unwrap(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&directory).unwrap();
        directory.join(name)
    }
    fn candle(index: i64) -> Value {
        json!({"timestamp":Utc.timestamp_millis_opt(ms("2026-09-25T19:00:00Z") as i64-index*60_000).unwrap().to_rfc3339(),
            "openPrice":"100","highPrice":"102","lowPrice":"98","closePrice":"101","volume":"0","currency":"USD"})
    }

    // Only tests can replace fixed endpoints. This local server contains synthetic values only.
    fn server(
        replies: Vec<(u16, Value)>,
        cancel: Option<Arc<AtomicBool>>,
    ) -> (String, std::thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = std::thread::spawn(move || {
            let mut calls = Vec::new();
            for (status, body) in replies {
                let until = Instant::now() + Duration::from_secs(12);
                let mut stream = loop {
                    match listener.accept() {
                        Ok((stream, _)) => break stream,
                        Err(e)
                            if e.kind() == std::io::ErrorKind::WouldBlock
                                && Instant::now() < until =>
                        {
                            std::thread::sleep(Duration::from_millis(5))
                        }
                        Err(e) => panic!("mock stock server accept: {e}"),
                    }
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut bytes = Vec::new();
                loop {
                    let mut part = [0; 1024];
                    let n = stream.read(&mut part).unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&part[..n]);
                    if let Some(end) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
                        let header = String::from_utf8_lossy(&bytes[..end]).to_ascii_lowercase();
                        let size = header
                            .lines()
                            .find_map(|line| {
                                line.strip_prefix("content-length:")
                                    .and_then(|n| n.trim().parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        if bytes.len() >= end + 4 + size {
                            break;
                        }
                    }
                }
                calls.push(String::from_utf8(bytes).unwrap());
                if let Some(cancel) = &cancel {
                    cancel.store(true, Ordering::SeqCst);
                }
                let body = body.to_string();
                write!(stream,"HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nRetry-After: 1\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
            }
            calls
        });
        (url, task)
    }
    fn fake_credentials() -> Result<Credentials> {
        Ok(Credentials {
            client_id: "test-client".into(),
            client_secret: "test-secret".into(),
            api_key: "test-key".into(),
        })
    }
    fn test_transport(url: String) -> Transport {
        Transport {
            agent: ureq::AgentBuilder::new()
                .redirects(0)
                .timeout(Duration::from_secs(5))
                .build(),
            token: None,
            cache: Cache::default(),
            generation: 0,
            next_request: [None, None],
            test_base: Some(url),
        }
    }
    fn auth(token: &str) -> (u16, Value) {
        (200, json!({"access_token":token,"expires_in":86400}))
    }
    fn prices() -> (u16, Value) {
        (
            200,
            json!({"result":[{"symbol":"AAPL","lastPrice":"100","currency":"USD"}],"error":null}),
        )
    }

    #[test]
    fn ticker_add_roundtrip_and_settings_limits() {
        for ticker in ["TQQQ", "AAPL"] {
            let s: StockSettings = serde_json::from_value(
                json!({"symbols":[{"symbol":ticker,"market":"us","name":"","visible":true}]}),
            )
            .unwrap();
            let normalized = s.validated().unwrap();
            assert_eq!(normalized.symbols[0].symbol, ticker);
            assert_eq!(normalized.symbols[0].name, None);
            let encoded = serde_json::to_value(&normalized).unwrap();
            assert!(encoded["symbols"][0].get("name").is_none());
            assert_eq!(
                serde_json::from_value::<StockSettings>(encoded)
                    .unwrap()
                    .validated()
                    .unwrap(),
                normalized
            );
        }
        assert!(symbol("0101N0", Some(Market::Kr)).is_ok());
        assert!(symbol("BRK.B", Some(Market::Us)).is_ok());
        for bad in ["https://host", "AAPL?token=x", "US:005930", "../A", "A\nB"] {
            assert!(symbol(bad, None).is_err());
        }
        let mut s = settings(Provider::Toss);
        s.symbols = (0..31)
            .map(|i| WatchedStock {
                symbol: format!("A{i}"),
                market: Market::Us,
                name: None,
                visible: true,
                color: None,
            })
            .collect();
        assert!(s.validated().is_err());
        assert!(serde_json::from_value::<StockSettings>(json!({"apiKey":"hidden"})).is_err());
        assert!(serde_json::from_value::<StockSettings>(json!({"displayInterval":"3"})).is_err());
    }

    #[test]
    fn requests_are_typed_bounded_and_provider_opt_in_gated() {
        for value in [
            json!({"kind":"other"}),
            json!({"kind":"prices","url":"https://evil"}),
            json!({"kind":"candles","count":"20"}),
            json!({"kind":"calendar","market":"KR"}),
            json!({"kind":"holdings","accountSeq":1.5}),
        ] {
            assert!(serde_json::from_value::<StockRequest>(value).is_err());
        }
        let raw: StockRequest =
            serde_json::from_value(json!({"kind":"prices","symbols":["AAPL"]})).unwrap();
        assert!(raw.clone().validated(&StockSettings::default()).is_err());
        assert!(raw.validated(&settings(Provider::Finnhub)).is_err());
        let raw: StockRequest = serde_json::from_value(json!({"kind":"accounts"})).unwrap();
        assert!(raw.validated(&settings(Provider::Toss)).is_err());
        let symbols: Vec<String> = (0..200).map(|i| format!("A{i}")).collect();
        assert_eq!(
            request(json!({"kind":"prices","symbols":symbols}))
                .symbols
                .unwrap()
                .len(),
            200
        );
        let raw: StockRequest =
            serde_json::from_value(json!({"kind":"prices","symbols":vec!["AAPL";201]})).unwrap();
        assert!(raw.validated(&settings(Provider::Toss)).is_err());
        let r = request(json!({"kind":"calendar","market":"us","date":"2026-09-25"}));
        assert_eq!(r.path(), "/api/v1/market-calendar/US");
        assert_eq!(r.query(), vec![("date".into(), "2026-09-25".into())]);
        let r = request(
            json!({"kind":"candles","symbol":"AAPL","interval":"10m","count":1400,"before":"2026-09-25T09:00:00+09:00","adjusted":false}),
        );
        assert!(r.query().contains(&("interval".into(), "1m".into())));
        assert!(r.query().contains(&("count".into(), "200".into())));
        assert!(r.query().contains(&("adjusted".into(), "false".into())));
    }

    #[test]
    fn watchlist_forecasts_need_no_account_but_holdings_require_the_saved_selection() {
        let mut settings = settings(Provider::Toss);
        settings.forecasts_enabled = true;
        assert_eq!(settings.account_seq, 0);
        for value in [
            json!({"kind":"candles","symbol":"AAPL","interval":"1d","count":64}),
            json!({"kind":"accounts"}),
        ] {
            let raw: StockRequest = serde_json::from_value(value).unwrap();
            assert!(raw.validated(&settings).is_ok());
        }
        for value in [
            json!({"kind":"holdings"}),
            json!({"kind":"holdings","accountSeq":0}),
            json!({"kind":"holdings","accountSeq":7}),
        ] {
            let raw: StockRequest = serde_json::from_value(value).unwrap();
            assert!(raw.validated(&settings).is_err());
        }
        settings.account_seq = 7;
        for account in [0, 8] {
            let raw: StockRequest =
                serde_json::from_value(json!({"kind":"holdings","accountSeq":account})).unwrap();
            assert!(raw.validated(&settings).is_err());
        }
        for value in [
            json!({"kind":"holdings"}),
            json!({"kind":"holdings","accountSeq":7}),
        ] {
            let raw: StockRequest = serde_json::from_value(value).unwrap();
            assert_eq!(raw.validated(&settings).unwrap().account_seq, Some(7));
        }
    }

    #[test]
    fn cache_keys_cover_cursor_adjustment_and_market_midnight() {
        let base = request(json!({"kind":"candles","symbol":"AAPL","interval":"1d","count":3}));
        let before_midnight = ms("2026-09-26T03:59:59Z");
        let after_midnight = ms("2026-09-26T04:00:00Z");
        assert_ne!(
            base.key(before_midnight).unwrap(),
            base.key(after_midnight).unwrap()
        );
        let mut historical = base.clone();
        historical.before = Some("2026-09-25T20:00:00Z".into());
        assert_eq!(
            historical.key(before_midnight).unwrap(),
            historical.key(after_midnight).unwrap()
        );
        let mut unadjusted = historical.clone();
        unadjusted.adjusted = Some(false);
        assert_ne!(
            historical.key(before_midnight).unwrap(),
            unadjusted.key(before_midnight).unwrap()
        );
        let kr = request(json!({"kind":"candles","symbol":"005930","interval":"1d"}));
        assert_ne!(
            kr.key(ms("2026-09-25T14:59:59Z")).unwrap(),
            kr.key(ms("2026-09-25T15:00:00Z")).unwrap()
        );
        assert_eq!(base.ttl(), Duration::from_secs(86400));
        let mut cache = Cache::default();
        let now = Instant::now();
        cache.put(
            "price".into(),
            StockReply {
                data: json!({}),
                fetched_at: 1,
            },
            Duration::from_secs(60),
            now,
        );
        assert!(cache.get("price", now + Duration::from_secs(59)).is_some());
        assert!(cache.get("price", now + Duration::from_secs(60)).is_none());
    }

    #[test]
    fn overlapping_batches_reuse_symbol_cache() {
        let mut cache = Cache::default();
        let now = Instant::now();
        let wall = ms("2026-09-25T15:00:00Z");
        let one = request(json!({"kind":"prices","symbols":["AAPL"]}));
        cache
            .store(
                &one,
                StockReply {
                    data: prices().1,
                    fetched_at: 5,
                },
                now,
                wall,
            )
            .unwrap();
        let batch = request(json!({"kind":"prices","symbols":["MSFT","AAPL"]}));
        assert_eq!(
            cache.missing(&batch, now, wall).unwrap().symbols.unwrap(),
            ["MSFT"]
        );
        let missing = cache.missing(&batch, now, wall).unwrap();
        cache
            .store(
                &missing,
                StockReply {
                    data: json!({"result":[{"symbol":"MSFT","lastPrice":"200"}]}),
                    fetched_at: 9,
                },
                now,
                wall,
            )
            .unwrap();
        let reply = cache.lookup(&batch, now, wall).unwrap().unwrap();
        assert_eq!(reply.data["result"].as_array().unwrap().len(), 2);
        assert_eq!(reply.fetched_at, 5);
    }

    #[test]
    fn concurrent_requests_share_one_token_and_cached_get() {
        let (url, server) = server(vec![auth("test-token"), prices()], None);
        let transport = Arc::new(Mutex::new(test_transport(url)));
        let barrier = Arc::new(Barrier::new(8));
        let workers: Vec<_> = (0..8)
            .map(|_| {
                let transport = transport.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    transport
                        .lock()
                        .unwrap()
                        .perform(
                            &request(json!({"kind":"prices","symbols":["AAPL"]})),
                            fake_credentials,
                            &|| Ok(()),
                        )
                        .unwrap()
                        .data
                })
            })
            .collect();
        for worker in workers {
            assert_eq!(worker.join().unwrap()["result"][0]["lastPrice"], "100");
        }
        let calls = server.join().unwrap();
        assert_eq!(calls.len(), 2);
        assert!(calls[0].starts_with("POST /oauth2/token"));
        assert!(calls[1].contains("Bearer test-token"));
    }

    #[test]
    fn unauthorized_refreshes_once_and_never_exposes_secrets() {
        let mut reply = prices();
        reply.1["access_token"] = json!("test-new-token");
        reply.1["meta"] = json!({"nestedSecret":"test-secret","text":"test-new-token"});
        let (url, server) = server(
            vec![
                auth("test-old-token"),
                (401, json!({"error":"denied"})),
                auth("test-new-token"),
                reply,
            ],
            None,
        );
        let mut transport = test_transport(url);
        let reply = transport
            .perform(
                &request(json!({"kind":"prices","symbols":["AAPL"]})),
                fake_credentials,
                &|| Ok(()),
            )
            .unwrap();
        let encoded = serde_json::to_string(&reply).unwrap();
        for secret in [
            "test-secret",
            "test-old-token",
            "test-new-token",
            "access_token",
            "nestedSecret",
        ] {
            assert!(!encoded.contains(secret));
        }
        let calls = server.join().unwrap();
        assert_eq!(calls.len(), 4);
        assert!(calls[1].contains("Bearer test-old-token"));
        assert!(calls[3].contains("Bearer test-new-token"));
        assert_eq!(transport.token.unwrap().value, "test-new-token");
    }

    #[test]
    fn repeated_401_and_429_are_bounded_and_failures_are_not_cached() {
        for status in [401, 429] {
            let replies = if status == 401 {
                vec![
                    auth("token-one"),
                    (401, json!({})),
                    auth("token-two"),
                    (401, json!({})),
                ]
            } else {
                vec![auth("token-one"), (429, json!({})), (429, json!({}))]
            };
            let expected = replies.len();
            let (url, server) = server(replies, None);
            let mut transport = test_transport(url);
            let result = transport.perform(
                &request(json!({"kind":"prices","symbols":["AAPL"]})),
                fake_credentials,
                &|| Ok(()),
            );
            assert!(result.is_err());
            assert!(transport.cache.entries.is_empty());
            assert_eq!(server.join().unwrap().len(), expected);
        }
        assert_eq!(
            retry_delay(Some("999999"), Utc::now()),
            Duration::from_secs(300)
        );
    }

    #[test]
    fn provider_change_during_authorization_stops_followup_get() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let (url, server) = server(vec![auth("test-token")], Some(cancelled.clone()));
        let mut transport = test_transport(url);
        let result = transport.perform(
            &request(json!({"kind":"prices","symbols":["AAPL"]})),
            fake_credentials,
            &|| {
                if cancelled.load(Ordering::SeqCst) {
                    Err("Stock provider changed".into())
                } else {
                    Ok(())
                }
            },
        );
        assert!(result.is_err());
        assert!(transport.token.is_none());
        assert!(transport.cache.entries.is_empty());
        assert_eq!(server.join().unwrap().len(), 1);
    }

    #[test]
    fn finnhub_key_is_a_header_not_a_query() {
        let (url, server) = server(vec![(200, json!({"c":100,"t":1790362800,"pc":99}))], None);
        let mut transport = test_transport(url);
        transport
            .perform(
                &request(json!({"kind":"finnhubQuote","symbol":"AAPL"})),
                fake_credentials,
                &|| Ok(()),
            )
            .unwrap();
        let calls = server.join().unwrap();
        assert!(calls[0].starts_with("GET /api/v1/quote?symbol=AAPL HTTP/1.1"));
        assert!(calls[0].contains("X-Finnhub-Token: test-key"));
        assert!(!calls[0].lines().next().unwrap().contains("test-key"));
    }

    #[test]
    fn ten_minute_backfill_is_eight_pages_1400_native_rows_descending() {
        let mut replies = vec![auth("test-token")];
        for page in 0..8 {
            let start = page * 199;
            let count = if page == 7 { 8 } else { 200 };
            let rows: Vec<_> = (start..start + count).map(candle).collect();
            replies.push((
                200,
                json!({"result":{"nextBefore":rows.last().unwrap()["timestamp"],"candles":rows}}),
            ));
        }
        let (url, server) = server(replies, None);
        let mut transport = test_transport(url);
        let reply = transport
            .perform(
                &request(json!({"kind":"candles","symbol":"AAPL","interval":"10m","count":1400})),
                fake_credentials,
                &|| Ok(()),
            )
            .unwrap();
        let rows = reply.data["result"]["candles"].as_array().unwrap();
        assert_eq!(rows.len(), 1400);
        assert_eq!(rows[0], candle(0));
        assert_eq!(rows[1399], candle(1399));
        let calls = server.join().unwrap();
        assert_eq!(calls.len(), 9);
        assert!(calls[1].contains("interval=1m"));
        assert!(calls[2].contains("before="));
        assert!(calls
            .iter()
            .skip(1)
            .all(|call| call.contains("Bearer test-token")));
        assert!(calls[2].contains("%3A"));
        let mut malformed = candle(0);
        malformed["volume"] = Value::Null;
        assert!(candle_page(&json!({"result":{"candles":[malformed]}}), None).is_err());
    }

    #[test]
    fn history_whitelist_numbers_and_trace_order_are_strict() {
        let point = trace(ms("2026-09-25T19:00:00Z"));
        let forecast = forecast();
        archive(vec![point.clone()], vec![forecast.clone()])
            .validate()
            .unwrap();
        for key in [
            "accountSeq",
            "quantity",
            "balance",
            "clientSecret",
            "evidence",
            "actualClose",
        ] {
            let mut bad = point.clone();
            bad[key] = json!(1);
            assert!(validate_row(&bad, false).is_err());
        }
        let mut bad = forecast.clone();
        bad["evidence"]["closes"][0]["token"] = json!("hidden");
        assert!(validate_row(&bad, true).is_err());
        for key in ["createdAt", "inputPrice"] {
            let mut bad = point.clone();
            bad[key] = json!("100");
            assert!(validate_row(&bad, false).is_err());
        }
        let mut second = point.clone();
        second["createdAt"] = json!(point["createdAt"].as_f64().unwrap() + 60000.0);
        assert!(archive(vec![point.clone(), second.clone()], vec![])
            .validate()
            .is_err());
        second["quoteAt"] = second["createdAt"].clone();
        archive(vec![point, second], vec![]).validate().unwrap();
        let mut bad = forecast;
        bad["actualClose"] = json!(101);
        assert!(validate_row(&bad, true).is_err());
        bad["evaluatedAt"] = json!(ms("2026-09-26T03:59:59Z"));
        assert!(validate_row(&bad, true).is_err());
        bad["evaluatedAt"] = json!(ms("2026-09-26T04:00:00Z"));
        validate_row(&bad, true).unwrap();
    }

    #[test]
    fn market_dates_observe_us_dst_and_korean_midnight() {
        for (at, day) in [
            ("2026-03-08T04:59:59Z", "2026-03-07"),
            ("2026-03-08T05:00:00Z", "2026-03-08"),
            ("2026-03-09T04:00:00Z", "2026-03-09"),
            ("2026-11-02T04:59:59Z", "2026-11-01"),
            ("2026-11-02T05:00:00Z", "2026-11-02"),
        ] {
            assert_eq!(market_day(ms(at), Market::Us).unwrap().to_string(), day);
        }
        assert_eq!(
            market_day(ms("2026-09-25T15:00:00Z"), Market::Kr)
                .unwrap()
                .to_string(),
            "2026-09-26"
        );
    }

    #[test]
    fn sqlite_delta_merge_is_atomic_preserves_omissions_and_only_resolves_scores() {
        let path = temp_path("history.sqlite3");
        let point = trace(ms("2026-09-25T19:00:00Z"));
        let prediction = forecast();
        save_history_at(
            &path,
            archive(vec![point.clone()], vec![prediction.clone()]),
        )
        .unwrap();
        let second = trace(ms("2026-09-25T19:01:00Z"));
        save_history_at(&path, archive(vec![second.clone()], vec![])).unwrap();
        let loaded = load_history_at(&path).unwrap();
        assert_eq!(loaded.trends.len(), 2);
        assert_eq!(loaded.forecasts.len(), 1);
        let mut resolved = prediction.clone();
        resolved["actualClose"] = json!(102.0);
        resolved["evaluatedAt"] = json!(ms("2026-09-26T04:00:00Z"));
        save_history_at(&path, archive(vec![], vec![resolved.clone()])).unwrap();
        save_history_at(&path, archive(vec![], vec![prediction])).unwrap(); // stale unresolved input cannot erase a score
        assert_eq!(load_history_at(&path).unwrap().forecasts[0], resolved);
        let mut conflict = resolved;
        conflict["expectedClose"] = json!(120.0);
        assert!(save_history_at(
            &path,
            archive(vec![trace(ms("2026-09-25T19:02:00Z"))], vec![conflict])
        )
        .is_err());
        assert_eq!(
            load_history_at(&path).unwrap().trends.len(),
            2,
            "the transaction wrote no partial trace"
        );
        save_history_at(&path, StockHistory::default()).unwrap();
        assert_eq!(load_history_at(&path).unwrap().trends.len(), 2);
        let data = std::fs::read(&path).unwrap();
        assert!(!String::from_utf8_lossy(&data).contains("accountSeq"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn corrupt_and_unknown_archives_are_preserved_byte_for_byte() {
        let path = temp_path("history.sqlite3");
        std::fs::write(&path, b"unreadable original archive").unwrap();
        let original = std::fs::read(&path).unwrap();
        assert!(load_history_at(&path).is_err());
        assert!(save_history_at(&path, StockHistory::default()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_file(&path).unwrap();
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute_batch("PRAGMA user_version=99; CREATE TABLE keep_me(value TEXT); INSERT INTO keep_me VALUES('public original');").unwrap();
        drop(db);
        let original = std::fs::read(&path).unwrap();
        assert!(load_history_at(&path).is_err());
        assert!(save_history_at(&path, StockHistory::default()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn atomic_settings_replace_keeps_complete_files_and_status_has_no_secret_fields() {
        let path = temp_path("config.json");
        atomic_write(&path, b"old").unwrap();
        atomic_write(&path, b"new").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        assert_eq!(
            std::fs::read_dir(path.parent().unwrap()).unwrap().count(),
            1
        );
        assert_eq!(
            serde_json::to_value(CredentialStatus {
                toss: true,
                finnhub: false
            })
            .unwrap(),
            json!({"toss":true,"finnhub":false})
        );
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
