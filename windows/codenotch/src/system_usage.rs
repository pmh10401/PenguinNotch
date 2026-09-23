//! One-second system meters for the Windows notch.
//!
//! CPU, memory, disk, network and battery come from documented Win32 calls.
//! GPU utilization and wall-socket watts have no equivalent public reading here,
//! so those cells stay empty instead of showing a made-up zero. On battery, the
//! signed discharge rate from `CallNtPowerInformation` (`SystemBatteryState`)
//! is shown as an estimate and is not added to the watt-hour total. A failed
//! counter read keeps the previous baseline. Weather is fetched off the
//! sampling thread so a slow response cannot open a ten-second gap.

use crate::config::{self, Config};
use crate::widgets::{self, History, MeterBaseline, NetRate, TodoItem, WeatherLocation, WeatherView};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Debug)]
struct Live {
    cpu: Option<f64>,
    cpu_user: Option<f64>,
    cpu_system: Option<f64>,
    memory_used: Option<u64>,
    memory_total: Option<u64>,
    disk_used: Option<u64>,
    disk_total: Option<u64>,
    disk_available: Option<u64>,
    net_down: Option<f64>,
    net_up: Option<f64>,
    link: String,
    link_name: String,
    battery: Option<f64>,
    battery_state: String,
    watts: Option<f64>,
    watts_estimated: bool,
    history: widgets::Enrichment,
    weather: Option<WeatherView>,
    weather_failed: bool,
}

impl Default for Live {
    fn default() -> Self {
        Self {
            cpu: None,
            cpu_user: None,
            cpu_system: None,
            memory_used: None,
            memory_total: None,
            disk_used: None,
            disk_total: None,
            disk_available: None,
            net_down: None,
            net_up: None,
            link: "other".into(),
            link_name: String::new(),
            battery: None,
            battery_state: "none".into(),
            watts: None,
            watts_estimated: false,
            history: widgets::Enrichment {
                recent_cpu: None,
                recent_gpu: None,
                recent_power: None,
                energy_wh: None,
                energy_seconds: 0.0,
                received_total: None,
                sent_total: None,
                network_seconds: 0.0,
            },
            weather: None,
            weather_failed: false,
        }
    }
}

struct Runtime {
    baseline: MeterBaseline,
    history: History,
    live: Live,
    monitoring: bool,
    weather_at: Option<Instant>,
    weather_key: String,
    weather_generation: u64,
}

fn runtime() -> &'static Mutex<Runtime> {
    static RUNTIME: OnceLock<Mutex<Runtime>> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        Mutex::new(Runtime {
            baseline: MeterBaseline::default(),
            history: History::default(),
            live: Live::default(),
            monitoring: false,
            weather_at: None,
            weather_key: String::new(),
            weather_generation: 0,
        })
    })
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || loop {
        tick(&app);
        std::thread::sleep(Duration::from_secs(1));
    });
}

fn pin_clock() {
    let offset = chrono::Local::now().offset().local_minus_utc() as i64;
    widgets::LOCAL_OFFSET_SECS.store(offset, std::sync::atomic::Ordering::Relaxed);
}

fn tick(app: &AppHandle) {
    pin_clock();
    let cfg = {
        let st = app.state::<crate::AppState>();
        let cfg = st.cfg.lock().unwrap().clone();
        cfg
    };
    let request = {
        let mut rt = runtime().lock().unwrap();
        if cfg.shows_system_usage {
            if !rt.monitoring {
                rt.baseline = MeterBaseline::default();
                rt.history = History::default();
                rt.monitoring = true;
            }
            sample_into(&mut rt);
        } else if rt.monitoring {
            rt.monitoring = false;
            rt.baseline = MeterBaseline::default();
            rt.history = History::default();
            let weather = rt.live.weather.clone();
            let weather_failed = rt.live.weather_failed;
            rt.live = Live::default();
            rt.live.weather = weather;
            rt.live.weather_failed = weather_failed;
        }
        begin_weather(&cfg, &mut rt)
    };
    if let Some((generation, location)) = request {
        let app = app.clone();
        std::thread::spawn(move || {
            let view = fetch_weather(&location);
            {
                let mut rt = runtime().lock().unwrap();
                finish_weather(&mut rt, generation, &location, view);
            }
            emit(&app);
        });
    }
    emit(app);
}

fn sample_into(rt: &mut Runtime) {
    let stamped = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let raw = read_counters();
    let observed = rt.baseline.take(stamped, raw.cpu_ticks, &raw.net_counters);
    let (cpu, cpu_user, cpu_system) = match (raw.cpu_ticks, observed.previous_cpu, observed.cpu_elapsed) {
        (Some(ticks), Some(before), Some(gap)) if gap > 0.0 && gap <= 10.0 => {
            widgets::cpu_fraction(ticks.0, ticks.1, ticks.2, before)
                .map(|(user, system)| (Some(user + system), Some(user), Some(system)))
                .unwrap_or((None, None, None))
        }
        _ => (None, None, None),
    };
    let rate = observed.net_elapsed.and_then(|gap| widgets::net_rate(&raw.net_counters, &observed.previous_net, gap));
    let net = rate.map(|rate| NetRate { down: rate.down, up: rate.up });
    let history = rt.history.enrich(stamped, cpu, None, raw.watts.filter(|_| !raw.watts_estimated), net);
    rt.live.cpu = cpu;
    rt.live.cpu_user = cpu_user;
    rt.live.cpu_system = cpu_system;
    rt.live.memory_used = raw.memory_used;
    rt.live.memory_total = raw.memory_total;
    rt.live.disk_used = raw.disk_used;
    rt.live.disk_total = raw.disk_total;
    rt.live.disk_available = raw.disk_available;
    rt.live.net_down = rate.map(|rate| rate.down);
    rt.live.net_up = rate.map(|rate| rate.up);
    rt.live.link = raw.link;
    rt.live.link_name = raw.link_name;
    rt.live.battery = raw.battery;
    rt.live.battery_state = raw.battery_state;
    rt.live.watts = raw.watts;
    rt.live.watts_estimated = raw.watts_estimated;
    rt.live.history = history;
}

struct Raw {
    cpu_ticks: Option<(u64, u64, u64)>,
    memory_used: Option<u64>,
    memory_total: Option<u64>,
    disk_used: Option<u64>,
    disk_total: Option<u64>,
    disk_available: Option<u64>,
    net_counters: Vec<(u32, u64, u64)>,
    link: String,
    link_name: String,
    battery: Option<f64>,
    battery_state: String,
    watts: Option<f64>,
    watts_estimated: bool,
}

fn begin_weather(cfg: &Config, rt: &mut Runtime) -> Option<(u64, WeatherLocation)> {
    let Some(location) = cfg.weather_location.clone().filter(|location| location.is_valid()) else {
        rt.live.weather = None;
        rt.live.weather_failed = false;
        rt.weather_key.clear();
        return None;
    };
    if !cfg.shows_weather {
        return None;
    }
    let key = format!("{}:{}:{}", location.id, location.latitude, location.longitude);
    let due = rt.weather_key != key
        || rt.weather_at.map(|then| then.elapsed() >= Duration::from_secs(15 * 60)).unwrap_or(true);
    if !due {
        return None;
    }
    rt.weather_key = key;
    rt.weather_at = Some(Instant::now());
    rt.weather_generation = rt.weather_generation.wrapping_add(1);
    Some((rt.weather_generation, location))
}

fn finish_weather(rt: &mut Runtime, generation: u64, location: &WeatherLocation, view: Option<WeatherView>) {
    if rt.weather_generation != generation {
        return;
    }
    match view {
        Some(mut view) => {
            view.name = location.name.clone();
            rt.live.weather_failed = false;
            rt.live.weather = Some(view);
        }
        None => {
            rt.live.weather_failed = true;
            if let Some(view) = rt.live.weather.as_mut() {
                view.stale = true;
                view.name = location.name.clone();
            }
        }
    }
}

fn fetch_weather(location: &WeatherLocation) -> Option<WeatherView> {
    let url = format!(
        "https://api.open-meteo.com/v1/forecast?latitude={}&longitude={}&current=temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m&daily=temperature_2m_min,temperature_2m_max,precipitation_probability_max,uv_index_max&forecast_days=2&timezone=auto&timeformat=unixtime&temperature_unit=celsius&wind_speed_unit=ms",
        location.latitude, location.longitude
    );
    let body = ureq::get(&url).timeout(Duration::from_secs(20)).call().ok()?.into_string().ok()?;
    if body.len() > 1_000_000 {
        return None;
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    widgets::decode_weather(&body, now, false)
}

pub fn search_cities(name: &str) -> Vec<WeatherLocation> {
    let query = name.trim();
    if !(2..=100).contains(&query.chars().count()) {
        return Vec::new();
    }
    let url = format!(
        "https://geocoding-api.open-meteo.com/v1/search?name={}&count=5&language=en",
        urlencoding_min(query)
    );
    let Ok(body) = ureq::get(&url).timeout(Duration::from_secs(20)).call() else {
        return Vec::new();
    };
    let Ok(body) = body.into_string() else { return Vec::new() };
    let Ok(root) = serde_json::from_str::<serde_json::Value>(&body) else {
        return Vec::new();
    };
    root.get("results")
        .and_then(|value| value.as_array())
        .map(|rows| {
            rows.iter().filter_map(|row| {
                let location = WeatherLocation {
                    id: row.get("id")?.as_i64()?,
                    name: row.get("name")?.as_str()?.to_string(),
                    latitude: row.get("latitude")?.as_f64()?,
                    longitude: row.get("longitude")?.as_f64()?,
                    admin1: row.get("admin1").and_then(|value| value.as_str()).map(str::to_string),
                    country: row.get("country")?.as_str().map(str::to_string),
                };
                location.is_valid().then_some(location)
            }).collect()
        })
        .unwrap_or_default()
}

fn urlencoding_min(text: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(byte as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn weather_json(live: &Live) -> Option<serde_json::Value> {
    live.weather.as_ref().map(|view| {
        json!({
            "name": view.name,
            "temperature": view.temperature,
            "code": view.code,
            "isDay": view.is_day,
            "humidity": view.humidity,
            "wind": view.wind,
            "low": view.low,
            "high": view.high,
            "rain": view.rain,
            "feelsLike": view.feels_like,
            "uv": view.uv,
            "stale": view.stale || live.weather_failed,
        })
    })
}

fn payload(cfg: &Config, live: &Live) -> serde_json::Value {
    let today = if cfg.shows_todo {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
        widgets::todo_today(&cfg.todos, now)
    } else {
        Vec::new()
    };
    json!({
        "system": cfg.shows_system_usage,
        "calendar": cfg.shows_calendar,
        "weatherOn": cfg.shows_weather,
        "todoOn": cfg.shows_todo,
        "hidden": cfg.hidden_notch_items,
        "order": cfg.cell_order,
        "colors": cfg.notch_colors,
        "cpu": live.cpu,
        "cpuUser": live.cpu_user,
        "cpuSystem": live.cpu_system,
        "memoryUsed": live.memory_used,
        "memoryTotal": live.memory_total,
        "diskUsed": live.disk_used,
        "diskTotal": live.disk_total,
        "diskAvailable": live.disk_available,
        "netDown": live.net_down,
        "netUp": live.net_up,
        "link": live.link,
        "linkName": live.link_name,
        "battery": live.battery,
        "batteryState": live.battery_state,
        "watts": live.watts,
        "wattsEstimated": live.watts_estimated,
        "recentCpu": live.history.recent_cpu,
        "recentPower": live.history.recent_power,
        "energyWh": live.history.energy_wh,
        "energySeconds": live.history.energy_seconds,
        "receivedTotal": live.history.received_total,
        "sentTotal": live.history.sent_total,
        "networkSeconds": live.history.network_seconds,
        "weather": weather_json(live),
        "weatherFailed": live.weather_failed && live.weather.is_none(),
        "weatherCity": cfg.weather_location.as_ref().map(|location| json!({
            "id": location.id, "name": location.name, "latitude": location.latitude,
            "longitude": location.longitude, "admin1": location.admin1, "country": location.country,
        })),
        "todos": today.iter().map(|item| json!({
            "id": item.id, "title": item.title, "done": item.completed_at.is_some(),
        })).collect::<Vec<_>>(),
        "todoCount": cfg.todos.len(),
    })
}

fn emit(app: &AppHandle) {
    pin_clock();
    let cfg = {
        let st = app.state::<crate::AppState>();
        let cfg = st.cfg.lock().unwrap().clone();
        cfg
    };
    let live = runtime().lock().unwrap().live.clone();
    let _ = app.emit("system-usage", payload(&cfg, &live));
}

#[derive(serde::Deserialize)]
pub struct WidgetPrefs {
    pub system: bool,
    pub calendar: bool,
    pub weather: bool,
    pub todo: bool,
    pub hidden: Vec<String>,
    pub order: Vec<String>,
    pub colors: HashMap<String, String>,
}

#[tauri::command]
pub fn get_widget_prefs(app: AppHandle) -> serde_json::Value {
    pin_clock();
    let cfg = {
        let st = app.state::<crate::AppState>();
        let cfg = st.cfg.lock().unwrap().clone();
        cfg
    };
    let live = runtime().lock().unwrap().live.clone();
    payload(&cfg, &live)
}

#[tauri::command]
pub fn set_widget_prefs(app: AppHandle, prefs: WidgetPrefs) -> serde_json::Value {
    let allowed = [
        "ff33e1", "eb4236", "eb8436", "ffd400", "00ff88", "00e5cc", "36a8eb", "6c5ce7", "b026ff", "f7f6f5",
    ];
    {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        cfg.shows_system_usage = prefs.system;
        cfg.shows_calendar = prefs.calendar;
        cfg.shows_weather = prefs.weather;
        cfg.shows_todo = prefs.todo;
        cfg.hidden_notch_items = prefs.hidden;
        cfg.cell_order = prefs.order;
        cfg.notch_colors = prefs
            .colors
            .into_iter()
            .filter(|(_, color)| allowed.contains(&color.to_ascii_lowercase().as_str()))
            .collect();
        config::save(&cfg);
    }
    pin_clock();
    let cfg = {
        let st = app.state::<crate::AppState>();
        let cfg = st.cfg.lock().unwrap().clone();
        cfg
    };
    let live = runtime().lock().unwrap().live.clone();
    let body = payload(&cfg, &live);
    let _ = app.emit("system-usage", body.clone());
    body
}

#[tauri::command]
pub fn search_weather_cities(name: String) -> Vec<WeatherLocation> {
    search_cities(&name)
}

#[tauri::command]
pub fn set_weather_city(app: AppHandle, city: Option<WeatherLocation>) {
    let cleared = {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        cfg.weather_location = city.filter(|city| city.is_valid());
        cfg.shows_weather = cfg.weather_location.is_some() || cfg.shows_weather;
        let cleared = cfg.weather_location.is_none();
        config::save(&cfg);
        cleared
    };
    {
        let mut rt = runtime().lock().unwrap();
        rt.weather_at = None;
        rt.weather_key.clear();
        rt.weather_generation = rt.weather_generation.wrapping_add(1);
        if cleared {
            rt.live.weather = None;
            rt.live.weather_failed = false;
        } else if let Some(view) = rt.live.weather.as_mut() {
            view.stale = true;
        }
    }
    emit(&app);
}

#[tauri::command]
pub fn add_todo(app: AppHandle, title: String) -> bool {
    let Some(title) = widgets::clean_todo_title(&title) else { return false };
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        let id = format!("{now}-{}", cfg.todos.len());
        cfg.todos.push(TodoItem {
            id,
            title,
            created_at: now,
            completed_at: None,
        });
        config::save(&cfg);
    }
    emit(&app);
    true
}

#[tauri::command]
pub fn toggle_todo(app: AppHandle, id: String) {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        if let Some(item) = cfg.todos.iter_mut().find(|item| item.id == id) {
            item.completed_at = if item.completed_at.is_none() { Some(now) } else { None };
            config::save(&cfg);
        }
    }
    emit(&app);
}

#[tauri::command]
pub fn remove_todo(app: AppHandle, id: String) {
    {
        let st = app.state::<crate::AppState>();
        let mut cfg = st.cfg.lock().unwrap();
        cfg.todos.retain(|item| item.id != id);
        config::save(&cfg);
    }
    emit(&app);
}

#[cfg(windows)]
fn read_counters() -> Raw {
    let (memory_used, memory_total) = read_memory();
    let (disk_used, disk_total, disk_available) = read_disk();
    let (net_counters, link, link_name) = read_network();
    let (battery, battery_state) = read_battery();
    let watts = read_discharge_watts();
    Raw {
        cpu_ticks: read_cpu_ticks(),
        memory_used,
        memory_total,
        disk_used,
        disk_total,
        disk_available,
        net_counters,
        link,
        link_name,
        battery,
        battery_state,
        watts,
        watts_estimated: watts.is_some(),
    }
}

#[cfg(not(windows))]
fn read_counters() -> Raw {
    Raw {
        cpu_ticks: None,
        memory_used: None,
        memory_total: None,
        disk_used: None,
        disk_total: None,
        disk_available: None,
        net_counters: Vec::new(),
        link: "other".into(),
        link_name: String::new(),
        battery: None,
        battery_state: "none".into(),
        watts: None,
        watts_estimated: false,
    }
}

#[cfg(windows)]
fn filetime(value: windows::Win32::Foundation::FILETIME) -> u64 {
    ((value.dwHighDateTime as u64) << 32) | value.dwLowDateTime as u64
}

#[cfg(windows)]
fn read_cpu_ticks() -> Option<(u64, u64, u64)> {
    use windows::Win32::Foundation::FILETIME;
    use windows::Win32::System::Threading::GetSystemTimes;
    let mut idle = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    unsafe { GetSystemTimes(Some(&mut idle), Some(&mut kernel), Some(&mut user)).ok()? };
    Some((filetime(user), filetime(kernel), filetime(idle)))
}

#[cfg(windows)]
fn read_memory() -> (Option<u64>, Option<u64>) {
    use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    let mut status = MEMORYSTATUSEX::default();
    status.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
    if unsafe { GlobalMemoryStatusEx(&mut status) }.is_err() || status.ullTotalPhys == 0 {
        return (None, None);
    }
    let total = status.ullTotalPhys;
    let used = total.saturating_sub(status.ullAvailPhys).min(total);
    (Some(used), Some(total))
}

#[cfg(windows)]
fn read_disk() -> (Option<u64>, Option<u64>, Option<u64>) {
    use std::os::windows::ffi::OsStrExt;
    use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let mut free = 0u64;
    let mut total = 0u64;
    let mut available = 0u64;
    let home = dirs::home_dir().unwrap_or_else(|| std::path::PathBuf::from("."));
    let wide: Vec<u16> = home.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let ok = unsafe {
        GetDiskFreeSpaceExW(
            windows::core::PCWSTR(wide.as_ptr()),
            Some(&mut available),
            Some(&mut total),
            Some(&mut free),
        )
    };
    if ok.is_err() || total == 0 {
        return (None, None, None);
    }
    (Some(total.saturating_sub(free.min(total))), Some(total), Some(available.min(total)))
}

#[cfg(windows)]
fn read_network() -> (Vec<(u32, u64, u64)>, String, String) {
    use windows::Win32::NetworkManagement::IpHelper::{
        FreeMibTable, GetBestInterface, GetIfTable2, MIB_IF_TABLE2,
    };
    use windows::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    let mut table: *mut MIB_IF_TABLE2 = std::ptr::null_mut();
    let status = unsafe { GetIfTable2(&mut table) };
    if status.is_err() || table.is_null() {
        if !table.is_null() {
            unsafe { FreeMibTable(table.cast::<core::ffi::c_void>()) };
        }
        return (Vec::new(), "disconnected".into(), String::new());
    }
    let mut counters = Vec::new();
    let mut rows = Vec::new();
    unsafe {
        let header = &*table;
        for index in 0..header.NumEntries {
            let row = &*header.Table.as_ptr().add(index as usize);
            let Some(kind) = interface_kind(row.Type) else { continue };
            if row.OperStatus != IfOperStatusUp {
                continue;
            }
            counters.push((row.InterfaceIndex, row.InOctets, row.OutOctets));
            rows.push((row.InterfaceIndex, wide_prefix(&row.Alias), kind));
        }
        FreeMibTable(table.cast::<core::ffi::c_void>());
    }
    let mut best_index = 0u32;
    let have_best = unsafe { GetBestInterface(0, &mut best_index) } == 0;
    match rows.iter().find(|row| have_best && row.0 == best_index).or_else(|| rows.first()) {
        Some((_, name, kind)) => (counters, kind.to_string(), name.clone()),
        None => (Vec::new(), "disconnected".into(), String::new()),
    }
}

#[cfg(windows)]
fn interface_kind(kind: u32) -> Option<&'static str> {
    use windows::Win32::NetworkManagement::IpHelper::{IF_TYPE_ETHERNET_CSMACD, IF_TYPE_IEEE80211};
    match kind {
        IF_TYPE_ETHERNET_CSMACD => Some("wired"),
        IF_TYPE_IEEE80211 => Some("wifi"),
        _ => None,
    }
}

#[cfg(windows)]
fn wide_prefix(words: &[u16]) -> String {
    let end = words.iter().position(|unit| *unit == 0).unwrap_or(words.len());
    String::from_utf16_lossy(&words[..end])
}

#[cfg(windows)]
fn read_battery() -> (Option<f64>, String) {
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    let mut status = SYSTEM_POWER_STATUS::default();
    if unsafe { GetSystemPowerStatus(&mut status) }.is_err() {
        return (None, "none".into());
    }
    if status.BatteryFlag & 128 != 0 || status.BatteryLifePercent == 255 {
        return (None, "none".into());
    }
    let fraction = (status.BatteryLifePercent as f64 / 100.0).clamp(0.0, 1.0);
    let state = if status.ACLineStatus == 0 {
        "battery"
    } else if status.BatteryFlag & 8 != 0 {
        "charging"
    } else if status.BatteryLifePercent >= 100 {
        "charged"
    } else if status.ACLineStatus == 1 {
        "ac"
    } else {
        "none"
    };
    (Some(fraction), state.into())
}

/// Battery discharge while unplugged, in watts. Charging current is not system load.
#[cfg(windows)]
fn read_discharge_watts() -> Option<f64> {
    use windows::Win32::System::Power::{CallNtPowerInformation, SystemBatteryState, SYSTEM_BATTERY_STATE};
    const _: () = assert!(std::mem::size_of::<SYSTEM_BATTERY_STATE>() == 32);
    let mut state = SYSTEM_BATTERY_STATE::default();
    let status = unsafe {
        CallNtPowerInformation(
            SystemBatteryState,
            None,
            0,
            Some((&mut state as *mut SYSTEM_BATTERY_STATE).cast()),
            std::mem::size_of::<SYSTEM_BATTERY_STATE>() as u32,
        )
    };
    if status.is_err() {
        return None;
    }
    widgets::discharge_watts(state.AcOnLine.0 != 0, state.Discharging.0 != 0, state.Rate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_city_search_rejects_a_one_letter_name() {
        assert!(search_cities("a").is_empty());
        assert!(search_cities("  ").is_empty());
    }
}
