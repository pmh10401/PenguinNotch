//! One-second system meters for the Windows notch.
//!
//! CPU, memory, disk, network and battery come from documented Win32 calls.
//! PDH supplies logical-processor and driver-supported GPU engine utilization;
//! WLAN supplies connection quality. Missing readings stay empty. On battery, the
//! signed discharge rate from `CallNtPowerInformation` (`SystemBatteryState`)
//! is shown as an estimate and is not added to the watt-hour total. A failed
//! counter read keeps the previous baseline. Weather and disk volumes are read
//! off the sampling thread so a slow response cannot stall the other meters.

use crate::config::{self, Config};
use crate::widgets::{self, History, MeterBaseline, NetRate, TodoItem, WeatherLocation, WeatherView};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct DiskVolume {
    id: String,
    name: String,
    mount_points: Vec<String>,
    used: u64,
    total: u64,
    available: u64,
}

#[derive(Clone, Debug, serde::Serialize)]
struct CpuCore {
    id: String,
    usage: Option<f64>,
}

#[derive(Clone, Debug, serde::Serialize)]
struct GpuEngine {
    id: String,
    name: String,
    usage: Option<f64>,
}

#[derive(Clone, Debug)]
struct Live {
    cpu: Option<f64>,
    cpu_user: Option<f64>,
    cpu_system: Option<f64>,
    cpu_cores: Vec<CpuCore>,
    gpu: Option<f64>,
    gpu_engines: Vec<GpuEngine>,
    memory_used: Option<u64>,
    memory_total: Option<u64>,
    disk_used: Option<u64>,
    disk_total: Option<u64>,
    disk_available: Option<u64>,
    volumes: Vec<DiskVolume>,
    net_down: Option<f64>,
    net_up: Option<f64>,
    link: String,
    link_name: String,
    link_strength: Option<f64>,
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
            cpu_cores: Vec::new(),
            gpu: None,
            gpu_engines: Vec::new(),
            memory_used: None,
            memory_total: None,
            disk_used: None,
            disk_total: None,
            disk_available: None,
            volumes: Vec::new(),
            net_down: None,
            net_up: None,
            link: "other".into(),
            link_name: String::new(),
            link_strength: None,
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
    #[cfg(windows)]
    performance: PerformanceCounters,
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
            #[cfg(windows)]
            performance: PerformanceCounters::default(),
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
            #[cfg(windows)]
            { rt.performance = PerformanceCounters::default(); }
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
    let rate = observed.net_elapsed.filter(|_| raw.link != "other")
        .and_then(|gap| widgets::net_rate(&raw.net_counters, &observed.previous_net, gap));
    let net = rate.map(|rate| NetRate { down: rate.down, up: rate.up });
    #[cfg(windows)]
    let (cpu_cores, gpu_engines) = rt.performance.sample();
    #[cfg(not(windows))]
    let (cpu_cores, gpu_engines) = (Vec::new(), Vec::new());
    let gpu = busiest_gpu_engine(&gpu_engines);
    let history = rt.history.enrich(stamped, cpu, gpu, raw.watts.filter(|_| !raw.watts_estimated), net);
    let (disk_used, disk_total, disk_available) = disk_totals(&raw.volumes);
    rt.live.cpu = cpu;
    rt.live.cpu_user = cpu_user;
    rt.live.cpu_system = cpu_system;
    rt.live.cpu_cores = cpu_cores;
    rt.live.gpu = gpu;
    rt.live.gpu_engines = gpu_engines;
    rt.live.memory_used = raw.memory_used;
    rt.live.memory_total = raw.memory_total;
    rt.live.disk_used = disk_used;
    rt.live.disk_total = disk_total;
    rt.live.disk_available = disk_available;
    rt.live.volumes = raw.volumes;
    rt.live.net_down = rate.map(|rate| rate.down);
    rt.live.net_up = rate.map(|rate| rate.up);
    rt.live.link = raw.link;
    rt.live.link_name = raw.link_name;
    rt.live.link_strength = raw.link_strength;
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
    volumes: Vec<DiskVolume>,
    net_counters: Vec<(u32, u64, u64)>,
    link: String,
    link_name: String,
    link_strength: Option<f64>,
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
    let retry_after = if rt.live.weather_failed { 60 } else { 15 * 60 };
    let due = rt.weather_key != key
        || rt.weather_at.map(|then| then.elapsed() >= Duration::from_secs(retry_after)).unwrap_or(true);
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

pub fn search_cities(name: &str) -> Result<Vec<WeatherLocation>, String> {
    let query = name.trim();
    if !(2..=100).contains(&query.chars().count()) {
        return Ok(Vec::new());
    }
    let korean = query.chars().any(|c| ('가'..='힣').contains(&c));
    let mut rows = geocode(query, if korean { "ko" } else { "en" })?;
    if korean && !query.ends_with('시') && !rows.iter().any(|city| city.name == query) {
        let city_query = format!("{query}시");
        if city_query.chars().count() <= 100 {
            if let Ok(more) = geocode(&city_query, "ko") {
                for city in more {
                    if city.name == city_query && !rows.iter().any(|found| found.id == city.id) {
                        rows.insert(0, city);
                    }
                }
            }
        }
    }
    Ok(rows)
}

fn geocode(query: &str, language: &str) -> Result<Vec<WeatherLocation>, String> {
    let url = format!(
        "https://geocoding-api.open-meteo.com/v1/search?name={}&count=5&language={language}",
        urlencoding_min(query),
    );
    let body = ureq::get(&url).timeout(Duration::from_secs(10)).call()
        .map_err(|e| format!("City search request failed: {e}"))?
        .into_string().map_err(|e| format!("City search response failed: {e}"))?;
    if body.len() > 1_000_000 {
        return Err("City search response is too large".into());
    }
    let root: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| format!("City search response is invalid: {e}"))?;
    Ok(root.get("results")
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
        .unwrap_or_default())
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
        "cpuCores": live.cpu_cores,
        "gpu": live.gpu,
        "gpuEngines": live.gpu_engines,
        "memoryUsed": live.memory_used,
        "memoryTotal": live.memory_total,
        "diskUsed": live.disk_used,
        "diskTotal": live.disk_total,
        "diskAvailable": live.disk_available,
        "volumes": live.volumes,
        "netDown": live.net_down,
        "netUp": live.net_up,
        "link": live.link,
        "linkName": live.link_name,
        "linkStrength": live.link_strength,
        "battery": live.battery,
        "batteryState": live.battery_state,
        "watts": live.watts,
        "wattsEstimated": live.watts_estimated,
        "recentCpu": live.history.recent_cpu,
        "recentGpu": live.history.recent_gpu,
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
pub async fn search_weather_cities(name: String) -> Result<Vec<WeatherLocation>, String> {
    tauri::async_runtime::spawn_blocking(move || search_cities(&name)).await
        .map_err(|e| format!("City search could not finish: {e}"))?
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
    let (net_counters, link, link_name, link_strength) = read_network();
    let (battery, battery_state) = read_battery();
    let watts = read_discharge_watts();
    Raw {
        cpu_ticks: read_cpu_ticks(),
        memory_used,
        memory_total,
        volumes: read_disk(),
        net_counters,
        link,
        link_name,
        link_strength,
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
        volumes: Vec::new(),
        net_counters: Vec::new(),
        link: "other".into(),
        link_name: String::new(),
        link_strength: None,
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

// PDH_CSTATUS_VALID_DATA / PDH_CSTATUS_NEW_DATA are 0 / 1. A successful
// array call does not imply that each individual counter has a valid sample.
fn pdh_percent(status: u32, value: f64) -> Option<f64> {
    ((status == 0 || status == 1) && value.is_finite() && value >= 0.0).then_some(value)
}

fn cpu_core_usage(samples: Vec<(String, Option<f64>)>) -> Vec<CpuCore> {
    let mut cores = std::collections::BTreeMap::new();
    for (name, value) in samples {
        let Some((group, processor)) = name.split_once(',') else { continue };
        let (Ok(group), Ok(processor)) = (group.parse::<u32>(), processor.parse::<u32>()) else { continue };
        cores.insert((group, processor), CpuCore {
            id: format!("{group},{processor}"),
            usage: value.and_then(|value| pdh_percent(0, value)).map(|value| value.min(100.0) / 100.0),
        });
    }
    cores.into_values().collect()
}

fn gpu_engine_identity(instance: &str) -> Option<(String, String)> {
    let (pid, rest) = instance.strip_prefix("pid_")?.split_once("_luid_")?;
    pid.parse::<u32>().ok()?;
    let (luid, rest) = rest.split_once("_phys_")?;
    let (high, low) = luid.split_once('_')?;
    let high = u32::from_str_radix(high.strip_prefix("0x")?, 16).ok()?;
    let low = u32::from_str_radix(low.strip_prefix("0x")?, 16).ok()?;
    let (physical, rest) = rest.split_once("_eng_")?;
    let physical = physical.parse::<u32>().ok()?;
    let (engine, name) = rest.split_once("_engtype_")?;
    let engine = engine.parse::<u32>().ok()?;
    if name.is_empty() { return None; }
    Some((format!("luid_0x{high:08x}_0x{low:08x}_phys_{physical}_eng_{engine}"), name.into()))
}

fn gpu_engine_usage(samples: Vec<(String, Option<f64>)>) -> Vec<GpuEngine> {
    let mut engines = std::collections::BTreeMap::<String, GpuEngine>::new();
    for (instance, value) in samples {
        let Some((id, name)) = gpu_engine_identity(&instance) else { continue };
        let engine = engines.entry(id.clone()).or_insert(GpuEngine { id, name, usage: Some(0.0) });
        // Sum processes sharing one physical engine, never different engines/GPUs.
        // An invalid process counter makes that engine unavailable for this sample.
        engine.usage = engine.usage.zip(value.and_then(|value| pdh_percent(0, value)))
            .map(|(sum, value)| (sum + value / 100.0).min(1.0));
    }
    engines.into_values().collect()
}

fn busiest_gpu_engine(engines: &[GpuEngine]) -> Option<f64> {
    engines.iter().filter_map(|engine| engine.usage).reduce(f64::max)
}

fn connection_strength(link: &str, quality: Option<u32>) -> Option<f64> {
    match link {
        "wired" => Some(1.0),
        "disconnected" => Some(0.0),
        "wifi" => quality.filter(|quality| *quality <= 100).map(|quality| quality as f64 / 100.0),
        _ => None,
    }
}

#[cfg(windows)]
#[derive(Default)]
struct PerformanceCounters {
    cpu: PdhCounter,
    gpu: PdhCounter,
}

#[cfg(windows)]
impl PerformanceCounters {
    fn sample(&mut self) -> (Vec<CpuCore>, Vec<GpuEngine>) {
        (
            cpu_core_usage(self.cpu.read(r"\Processor Information(*)\% Processor Time")),
            gpu_engine_usage(self.gpu.read(r"\GPU Engine(*)\Utilization Percentage")),
        )
    }
}

#[cfg(windows)]
#[derive(Default)]
struct PdhCounter {
    query: isize,
    counter: isize,
    collected_at: Option<Instant>,
    attempted_at: Option<Instant>,
}

#[cfg(windows)]
impl PdhCounter {
    fn close(&mut self) {
        if self.query != 0 {
            unsafe { windows::Win32::System::Performance::PdhCloseQuery(self.query); }
        }
        self.query = 0;
        self.counter = 0;
        self.collected_at = None;
    }

    fn read(&mut self, path: &str) -> Vec<(String, Option<f64>)> {
        use windows::core::PCWSTR;
        use windows::Win32::System::Performance::{PdhAddEnglishCounterW, PdhCollectQueryData, PdhOpenQueryW};
        if self.collected_at.is_some_and(|at| at.elapsed() > Duration::from_secs(10)) {
            self.close();
            self.attempted_at = None; // Re-prime after sleep; do not average over the gap.
        }
        if self.query == 0 {
            if self.attempted_at.is_some_and(|at| at.elapsed() < Duration::from_secs(30)) {
                return Vec::new();
            }
            self.attempted_at = Some(Instant::now());
            if unsafe { PdhOpenQueryW(PCWSTR::null(), 0, &mut self.query) } != 0 {
                self.query = 0;
                return Vec::new();
            }
            let path: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
            if unsafe { PdhAddEnglishCounterW(self.query, PCWSTR(path.as_ptr()), 0, &mut self.counter) } != 0 {
                self.close();
                return Vec::new();
            }
        }
        let primed = self.collected_at.is_some();
        if unsafe { PdhCollectQueryData(self.query) } != 0 {
            self.close();
            self.attempted_at = Some(Instant::now());
            return Vec::new();
        }
        self.collected_at = Some(Instant::now());
        let mut values = pdh_array(self.counter);
        if !primed {
            for (_, value) in &mut values { *value = None; }
        }
        values
    }
}

#[cfg(windows)]
impl Drop for PdhCounter {
    fn drop(&mut self) { self.close(); }
}

#[cfg(windows)]
fn pdh_array(counter: isize) -> Vec<(String, Option<f64>)> {
    use windows::Win32::System::Performance::{PdhGetFormattedCounterArrayW, PDH_FMT_COUNTERVALUE_ITEM_W, PDH_FMT_DOUBLE, PDH_MORE_DATA};
    // GPU process instances can appear between sizing and reading. Re-size from
    // zero on a retry, as PDH does not guarantee the size after a short-buffer read.
    for _ in 0..3 {
        let mut bytes = 0;
        let mut count = 0;
        if unsafe { PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &mut bytes, &mut count, None) } != PDH_MORE_DATA || bytes == 0 {
            return Vec::new();
        }
        let item_size = std::mem::size_of::<PDH_FMT_COUNTERVALUE_ITEM_W>();
        // A typed allocation keeps both the structures and the trailing UTF-16 names aligned.
        let mut buffer = vec![PDH_FMT_COUNTERVALUE_ITEM_W::default(); (bytes as usize).div_ceil(item_size)];
        let status = unsafe { PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &mut bytes, &mut count, Some(buffer.as_mut_ptr())) };
        if status == PDH_MORE_DATA { continue; }
        if status != 0 || count as usize > buffer.len() { return Vec::new(); }
        return buffer[..count as usize].iter().filter_map(|item| {
            if item.szName.is_null() { return None; }
            let name = unsafe { item.szName.to_string().ok()? };
            let value = if item.FmtValue.CStatus <= 1 {
                pdh_percent(item.FmtValue.CStatus, unsafe { item.FmtValue.Anonymous.doubleValue })
            } else { None };
            Some((name, value))
        }).collect();
    }
    Vec::new()
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

fn merge_disk_volumes(volumes: Vec<DiskVolume>) -> Vec<DiskVolume> {
    let mut unique = std::collections::BTreeMap::<String, DiskVolume>::new();
    for mut volume in volumes {
        if volume.id.is_empty() || volume.total == 0 || volume.mount_points.is_empty() {
            continue;
        }
        volume.id.make_ascii_lowercase();
        volume.used = volume.used.min(volume.total);
        volume.available = volume.available.min(volume.total);
        match unique.entry(volume.id.clone()) {
            std::collections::btree_map::Entry::Occupied(mut entry) => {
                entry.get_mut().mount_points.extend(volume.mount_points);
            }
            std::collections::btree_map::Entry::Vacant(entry) => { entry.insert(volume); }
        }
    }
    let mut volumes: Vec<_> = unique.into_values().collect();
    for volume in &mut volumes {
        volume.mount_points.sort_by_cached_key(|path| (path.len(), path.to_ascii_lowercase()));
        volume.mount_points.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
        if volume.name.is_empty() {
            volume.name = volume.mount_points[0].clone();
        }
    }
    volumes.sort_by_cached_key(|volume| (volume.mount_points[0].to_ascii_lowercase(), volume.id.clone()));
    volumes
}

fn disk_totals(volumes: &[DiskVolume]) -> (Option<u64>, Option<u64>, Option<u64>) {
    if volumes.is_empty() {
        return (None, None, None);
    }
    let totals = volumes.iter().try_fold((0u64, 0u64, 0u64), |(used, total, available), volume| {
        Some((used.checked_add(volume.used)?, total.checked_add(volume.total)?, available.checked_add(volume.available)?))
    });
    totals.map(|(used, total, available)| (Some(used), Some(total), Some(available)))
        .unwrap_or((None, None, None))
}

#[cfg(windows)]
fn read_disk() -> Vec<DiskVolume> {
    #[derive(Default)]
    struct Cache {
        volumes: Vec<DiskVolume>,
        pending: bool,
    }
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(Cache::default()));
    let mut state = cache.lock().unwrap();
    if !state.pending {
        state.pending = true;
        // At most one scan can be in flight, even if a storage driver is slow.
        std::thread::spawn(move || {
            let volumes = enumerate_disk_volumes();
            let mut state = cache.lock().unwrap();
            state.volumes = volumes;
            state.pending = false;
        });
    }
    state.volumes.clone()
}

#[cfg(windows)]
fn enumerate_disk_volumes() -> Vec<DiskVolume> {
    use windows::Win32::Foundation::BOOL;
    use windows::Win32::Storage::FileSystem::{FindFirstVolumeW, FindNextVolumeW, FindVolumeClose};
    // These two Kernel32 bindings avoid enabling an unrelated diagnostics feature.
    #[link(name = "kernel32")]
    extern "system" {
        fn GetThreadErrorMode() -> u32;
        fn SetThreadErrorMode(mode: u32, old_mode: *mut u32) -> BOOL;
    }
    const SEM_FAILCRITICALERRORS: u32 = 0x0001;
    let old_mode = unsafe { GetThreadErrorMode() };
    if !unsafe { SetThreadErrorMode(old_mode | SEM_FAILCRITICALERRORS, std::ptr::null_mut()) }.as_bool() {
        return Vec::new();
    }
    let mut volumes = Vec::new();
    let mut guid = [0u16; 50];
    if let Ok(handle) = unsafe { FindFirstVolumeW(&mut guid) } {
        loop {
            if let Some(volume) = read_disk_volume(&guid) {
                volumes.push(volume);
            }
            if unsafe { FindNextVolumeW(handle, &mut guid) }.is_err() {
                break;
            }
        }
        let _ = unsafe { FindVolumeClose(handle) };
    }
    let _ = unsafe { SetThreadErrorMode(old_mode, std::ptr::null_mut()) };
    merge_disk_volumes(volumes)
}

#[cfg(windows)]
fn read_disk_volume(guid: &[u16]) -> Option<DiskVolume> {
    use windows::core::PCWSTR;
    use windows::Win32::Storage::FileSystem::{
        GetDiskFreeSpaceExW, GetDriveTypeW, GetVolumeInformationW, GetVolumeNameForVolumeMountPointW,
    };
    const DRIVE_REMOVABLE: u32 = 2;
    const DRIVE_FIXED: u32 = 3;
    let root = PCWSTR(guid.as_ptr());
    if !matches!(unsafe { GetDriveTypeW(root) }, DRIVE_FIXED | DRIVE_REMOVABLE) {
        return None;
    }
    let mount_points = disk_mount_points(root);
    if mount_points.is_empty() {
        return None; // Hidden system/recovery volumes have no user mount path.
    }
    // The mount manager returns its first GUID even when a volume has GUID aliases.
    let mut canonical = [0u16; 50];
    let id = if unsafe { GetVolumeNameForVolumeMountPointW(root, &mut canonical) }.is_ok() {
        wide_prefix(&canonical)
    } else {
        wide_prefix(guid)
    };
    let mut free = 0u64;
    let mut total = 0u64;
    let mut available = 0u64;
    unsafe { GetDiskFreeSpaceExW(root, Some(&mut available), Some(&mut total), Some(&mut free)).ok()? };
    if total == 0 {
        return None;
    }
    let mut label = [0u16; 261];
    let name = if unsafe { GetVolumeInformationW(root, Some(&mut label), None, None, None, None) }.is_ok() {
        wide_prefix(&label)
    } else {
        String::new()
    };
    Some(DiskVolume { id, name, mount_points, used: total - free.min(total), total, available: available.min(total) })
}

#[cfg(windows)]
fn disk_mount_points(root: windows::core::PCWSTR) -> Vec<String> {
    use windows::Win32::Foundation::ERROR_MORE_DATA;
    use windows::Win32::Storage::FileSystem::GetVolumePathNamesForVolumeNameW;
    let mut paths = vec![0u16; 512];
    // A mount change can grow the list between calls; retry without looping forever.
    for _ in 0..3 {
        let mut needed = 0;
        match unsafe { GetVolumePathNamesForVolumeNameW(root, Some(&mut paths), &mut needed) } {
            Ok(()) => return paths.split(|unit| *unit == 0).take_while(|path| !path.is_empty())
                .map(String::from_utf16_lossy).collect(),
            Err(error) if error.code() == ERROR_MORE_DATA.to_hresult() && needed as usize > paths.len() => {
                paths.resize(needed as usize, 0);
            }
            Err(_) => break,
        }
    }
    Vec::new()
}

#[cfg(windows)]
fn read_network() -> (Vec<(u32, u64, u64)>, String, String, Option<f64>) {
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
        return (Vec::new(), "other".into(), String::new(), None);
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
            rows.push((row.InterfaceIndex, wide_prefix(&row.Alias), kind, row.InterfaceGuid));
        }
        FreeMibTable(table.cast::<core::ffi::c_void>());
    }
    let mut best_index = 0u32;
    let have_best = unsafe { GetBestInterface(0, &mut best_index) } == 0;
    match rows.iter().find(|row| have_best && row.0 == best_index).or_else(|| rows.first()) {
        Some((_, name, kind, guid)) => {
            let quality = if *kind == "wifi" { read_wifi_quality(guid) } else { None };
            (counters, kind.to_string(), name.clone(), connection_strength(kind, quality))
        }
        None => (Vec::new(), "disconnected".into(), String::new(), Some(0.0)),
    }
}

#[cfg(windows)]
fn read_wifi_quality(guid: &windows::core::GUID) -> Option<u32> {
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::NetworkManagement::WiFi::{
        WlanCloseHandle, WlanFreeMemory, WlanOpenHandle, WlanQueryInterface,
        wlan_interface_state_connected, wlan_intf_opcode_current_connection, WLAN_CONNECTION_ATTRIBUTES,
    };
    let mut handle = HANDLE::default();
    let mut version = 0;
    if unsafe { WlanOpenHandle(2, None, &mut version, &mut handle) } != 0 {
        return None;
    }
    let mut data: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut bytes = 0;
    let status = unsafe { WlanQueryInterface(handle, guid, wlan_intf_opcode_current_connection, None, &mut bytes, &mut data, None) };
    let quality = if status == 0 && !data.is_null() && bytes as usize >= std::mem::size_of::<WLAN_CONNECTION_ATTRIBUTES>() {
        let connection = unsafe { &*data.cast::<WLAN_CONNECTION_ATTRIBUTES>() };
        (connection.isState == wlan_interface_state_connected)
            .then_some(connection.wlanAssociationAttributes.wlanSignalQuality)
            .filter(|quality| *quality <= 100)
    } else { None };
    if !data.is_null() { unsafe { WlanFreeMemory(data); } }
    unsafe { WlanCloseHandle(handle, None); }
    quality
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
mod monitoring_tests {
    use super::*;

    #[test]
    fn logical_processors_exclude_totals_sort_numerically_and_keep_missing_samples() {
        let cores = cpu_core_usage(vec![
            ("_Total".into(), Some(90.0)), ("0,_Total".into(), Some(90.0)),
            ("1,0".into(), Some(25.0)), ("0,10".into(), None), ("0,2".into(), Some(0.0)),
            ("0,1".into(), Some(110.0)), ("not-a-core".into(), Some(50.0)),
        ]);
        assert_eq!(cores.iter().map(|core| core.id.as_str()).collect::<Vec<_>>(), ["0,1", "0,2", "0,10", "1,0"]);
        assert_eq!(cores.iter().map(|core| core.usage).collect::<Vec<_>>(), [Some(1.0), Some(0.0), None, Some(0.25)]);
        assert_eq!(pdh_percent(0, 0.0), Some(0.0));
        assert_eq!(pdh_percent(1, 30.0), Some(30.0));
        assert_eq!(pdh_percent(0xc0000bba, 0.0), None);
        assert_eq!(pdh_percent(0, f64::NAN), None);
        assert_eq!(pdh_percent(0, f64::INFINITY), None);
        assert_eq!(pdh_percent(0, -1.0), None);
    }

    #[test]
    fn gpu_processes_share_an_engine_but_other_engines_and_adapters_do_not_add_to_it() {
        let engines = gpu_engine_usage(vec![
            ("pid_1_luid_0x00000000_0x000000aa_phys_0_eng_0_engtype_3D".into(), Some(25.0)),
            ("pid_2_luid_0x00000000_0x000000aa_phys_0_eng_0_engtype_3D".into(), Some(50.0)),
            ("pid_1_luid_0x00000000_0x000000aa_phys_0_eng_1_engtype_Copy".into(), Some(60.0)),
            ("pid_1_luid_0x00000000_0x000000aa_phys_1_eng_0_engtype_3D".into(), Some(20.0)),
            ("pid_1_luid_0x00000000_0x000000bb_phys_0_eng_0_engtype_3D".into(), Some(80.0)),
            ("_Total".into(), Some(100.0)), ("pid_bad_luid_0x0_0xaa_phys_0_eng_0_engtype_3D".into(), Some(100.0)),
        ]);
        assert_eq!(engines.len(), 4);
        assert_eq!(engines[0].usage, Some(0.75));
        assert_eq!(busiest_gpu_engine(&engines), Some(0.8), "headline is the busiest engine, not the sum or mean");
        assert_eq!(busiest_gpu_engine(&[]), None);
        let instance = "pid_1_luid_0x0_0xaa_phys_0_eng_0_engtype_3D".to_string();
        assert_eq!(busiest_gpu_engine(&gpu_engine_usage(vec![(instance.clone(), Some(0.0))])), Some(0.0));
        assert_eq!(busiest_gpu_engine(&gpu_engine_usage(vec![(instance.clone(), None)])), None);
        let partial = gpu_engine_usage(vec![
            (instance.clone(), Some(90.0)), (instance.replace("pid_1", "pid_2"), None),
        ]);
        assert_eq!(partial[0].usage, None, "missing process data must not become a partial zero");
        assert_eq!(busiest_gpu_engine(&gpu_engine_usage(vec![(instance, Some(140.0))])), Some(1.0));
    }

    #[test]
    fn connection_quality_keeps_unknown_distinct_from_a_real_zero() {
        assert_eq!(connection_strength("wired", None), Some(1.0));
        assert_eq!(connection_strength("disconnected", None), Some(0.0));
        assert_eq!(connection_strength("wifi", Some(0)), Some(0.0));
        assert_eq!(connection_strength("wifi", Some(64)), Some(0.64));
        assert_eq!(connection_strength("wifi", Some(100)), Some(1.0));
        assert_eq!(connection_strength("wifi", Some(101)), None);
        assert_eq!(connection_strength("wifi", None), None);
        assert_eq!(connection_strength("other", Some(100)), None);
    }
}

#[cfg(test)]
mod disk_tests {
    use super::*;

    #[test]
    fn partitions_are_summed_once_per_volume_and_keep_mount_aliases() {
        let system = DiskVolume {
            id: r"\\?\Volume{AAAA}\".into(), name: "Local disk".into(), mount_points: vec![r"C:\".into()],
            used: 200_000_000_000, total: 500_000_000_000, available: 250_000_000_000,
        };
        let data = DiskVolume {
            id: r"\\?\Volume{BBBB}\".into(), mount_points: vec![r"D:\".into()],
            used: 800_000_000_000, total: 1_000_000_000_000, available: 200_000_000_000,
            ..system.clone()
        };
        let alias = DiskVolume {
            id: data.id.to_ascii_lowercase(),
            mount_points: vec![r"d:\".into(), r"E:\".into(), r"C:\Mount\자료\".into()],
            ..data.clone()
        };
        let hidden = DiskVolume { id: "recovery".into(), mount_points: Vec::new(), ..system.clone() };
        let empty = DiskVolume { id: "empty-media".into(), total: 0, ..system.clone() };
        let volumes = merge_disk_volumes(vec![data, alias, hidden, empty, system]);
        assert_eq!(volumes.len(), 2, "same labels do not collapse distinct partitions");
        assert_eq!(volumes[0].id, r"\\?\volume{aaaa}\");
        assert_eq!(volumes[1].mount_points, [r"D:\", r"E:\", r"C:\Mount\자료\"]);
        assert_eq!(disk_totals(&volumes), (Some(1_000_000_000_000), Some(1_500_000_000_000), Some(450_000_000_000)));
        let json = serde_json::to_value(&volumes).unwrap();
        assert_eq!(json[1]["mountPoints"][2], r"C:\Mount\자료\");
        assert_eq!(json[0]["available"], 250_000_000_000u64);
        assert!(json[0].get("mount_points").is_none());
    }

    #[test]
    fn empty_or_overflowing_totals_are_unavailable_and_unlabelled_volumes_use_the_mount() {
        assert_eq!(disk_totals(&[]), (None, None, None));
        let volumes = merge_disk_volumes(vec![DiskVolume {
            id: "volume".into(), name: String::new(), mount_points: vec![r"C:\Mount\Data\".into()],
            used: 101, total: 100, available: 200,
        }]);
        assert_eq!(volumes[0].name, r"C:\Mount\Data\");
        assert_eq!(disk_totals(&volumes), (Some(100), Some(100), Some(100)));
        let large = DiskVolume { total: u64::MAX, ..volumes[0].clone() };
        assert_eq!(disk_totals(&[large, volumes[0].clone()]), (None, None, None));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_city_search_rejects_a_one_letter_name() {
        assert!(search_cities("a").unwrap().is_empty());
        assert!(search_cities("  ").unwrap().is_empty());
    }
}
