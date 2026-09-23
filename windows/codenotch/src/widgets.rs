//! Shared rules for the system meters, calendar, weather and to-dos.
//!
//! The numbers follow the macOS sampler: a gap is not billed, a counter that
//! runs backwards is dropped, and a missing sensor stays missing.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Recent {
    pub average: f64,
    pub peak: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetRate {
    pub down: f64,
    pub up: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Enrichment {
    pub recent_cpu: Option<Recent>,
    pub recent_gpu: Option<Recent>,
    pub recent_power: Option<Recent>,
    pub energy_wh: Option<f64>,
    pub energy_seconds: f64,
    pub received_total: Option<f64>,
    pub sent_total: Option<f64>,
    pub network_seconds: f64,
}

/// In-memory totals for one monitoring period. Sleep and other gaps are holes.
#[derive(Debug, Default)]
pub struct History {
    samples: Vec<(f64, [Option<f64>; 3])>,
    previous_time: Option<f64>,
    previous_watts: Option<f64>,
    received: f64,
    sent: f64,
    network_seconds: f64,
    watt_hours: f64,
    power_seconds: f64,
}

impl History {
    pub fn enrich(
        &mut self,
        time: f64,
        cpu: Option<f64>,
        gpu: Option<f64>,
        watts: Option<f64>,
        net: Option<NetRate>,
    ) -> Enrichment {
        if !time.is_finite() {
            return self.view([None, None, None]);
        }
        let elapsed = self.previous_time.map(|previous| time - previous);
        let continuous = elapsed.is_some_and(|gap| gap > 0.0 && gap <= 10.0);
        let watts = watts.filter(|value| value.is_finite() && *value >= 0.0);
        if let (true, Some(gap)) = (continuous, elapsed) {
            if let Some(net) = net {
                if net.down.is_finite() && net.up.is_finite() && net.down >= 0.0 && net.up >= 0.0 {
                    self.received += net.down * gap;
                    self.sent += net.up * gap;
                    self.network_seconds += gap;
                }
            }
            if let (Some(watts), Some(previous)) = (watts, self.previous_watts) {
                self.watt_hours += (watts + previous) / 2.0 * gap / 3600.0;
                self.power_seconds += gap;
            }
        } else {
            self.samples.clear();
        }
        self.previous_time = Some(time);
        self.previous_watts = watts;
        let values = [finite_nonneg(cpu), finite_nonneg(gpu), watts];
        self.samples.push((time, values));
        self.samples.retain(|(stamp, _)| time - stamp < 60.0);
        if self.samples.len() > 61 {
            let drop = self.samples.len() - 61;
            self.samples.drain(0..drop);
        }
        self.view(values)
    }

    fn view(&self, values: [Option<f64>; 3]) -> Enrichment {
        let recent = |index: usize| -> Option<Recent> {
            if values[index].is_none() {
                return None;
            }
            let series: Vec<f64> = self.samples.iter().filter_map(|(_, row)| row[index]).collect();
            if series.len() < 2 {
                return None;
            }
            let sum: f64 = series.iter().sum();
            let peak = series.iter().copied().fold(f64::MIN, f64::max);
            Some(Recent { average: sum / series.len() as f64, peak })
        };
        Enrichment {
            recent_cpu: recent(0),
            recent_gpu: recent(1),
            recent_power: recent(2),
            energy_wh: (self.power_seconds > 0.0).then_some(self.watt_hours),
            energy_seconds: self.power_seconds,
            received_total: (self.network_seconds > 0.0).then_some(self.received),
            sent_total: (self.network_seconds > 0.0).then_some(self.sent),
            network_seconds: self.network_seconds,
        }
    }
}

fn finite_nonneg(value: Option<f64>) -> Option<f64> {
    value.filter(|value| value.is_finite() && *value >= 0.0)
}

/// Decimal units, matching the macOS compact label (`1.5M/s`) or the card (`1.5MB/s`).
pub fn format_rate(bytes: f64, compact: bool) -> String {
    let units: &[&str] = if compact {
        &["B/s", "K/s", "M/s", "G/s", "T/s"]
    } else {
        &["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    };
    let mut value = if bytes.is_finite() { bytes.max(0.0) } else { 0.0 };
    let mut unit = 0;
    while value >= 1000.0 && unit < units.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 || value >= 100.0 {
        format!("{value:.0}{}", units[unit])
    } else {
        format!("{value:.1}{}", units[unit])
    }
}

pub fn net_rate(current: &[(u32, u64, u64)], previous: &[(u32, u64, u64)], elapsed: f64) -> Option<NetRate> {
    if !elapsed.is_finite() || elapsed <= 0.0 || elapsed > 10.0 {
        return None;
    }
    let mut down = 0.0;
    let mut up = 0.0;
    let mut comparable = current.is_empty() && previous.is_empty();
    for (index, received, sent) in current {
        let Some((_, old_in, old_out)) = previous.iter().find(|(id, _, _)| id == index) else {
            continue;
        };
        if received < old_in || sent < old_out {
            continue;
        }
        comparable = true;
        down += (*received - *old_in) as f64;
        up += (*sent - *old_out) as f64;
    }
    comparable.then_some(NetRate { down: down / elapsed, up: up / elapsed })
}

/// Relative Wi-Fi arc. -90 dBm is empty and -50 dBm is full. Zero means "no reading".
pub fn signal_fraction(rssi: i32) -> Option<f64> {
    if !(-120..=-1).contains(&rssi) {
        return None;
    }
    Some(((rssi + 90) as f64 / 40.0).clamp(0.0, 1.0))
}

pub fn cpu_fraction(user: u64, kernel: u64, idle: u64, previous: (u64, u64, u64)) -> Option<(f64, f64)> {
    let user_d = user.wrapping_sub(previous.0);
    let kernel_d = kernel.wrapping_sub(previous.1);
    let idle_d = idle.wrapping_sub(previous.2);
    let total = user_d + kernel_d;
    if total == 0 || idle_d > kernel_d {
        return None;
    }
    let system = kernel_d - idle_d;
    Some((user_d as f64 / total as f64, system as f64 / total as f64))
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TodoItem {
    pub id: String,
    pub title: String,
    pub created_at: i64,
    pub completed_at: Option<i64>,
}

pub fn clean_todo_title(title: &str) -> Option<String> {
    let title = title.trim();
    if title.is_empty() || title.chars().count() > 200 {
        None
    } else {
        Some(title.to_string())
    }
}

/// Unfinished items carry over. A completion stays on the list only for the local day it was finished.
pub fn todo_today(items: &[TodoItem], now_ms: i64) -> Vec<TodoItem> {
    let mut open = Vec::new();
    let mut done = Vec::new();
    for item in items {
        match item.completed_at {
            None => open.push(item.clone()),
            Some(done_at) if same_local_day(done_at, now_ms) => done.push(item.clone()),
            Some(_) => {}
        }
    }
    open.extend(done);
    open
}

fn same_local_day(a: i64, b: i64) -> bool {
    local_day(a) == local_day(b)
}

fn local_day(ms: i64) -> i64 {
    day_index(ms, LOCAL_OFFSET_SECS.load(std::sync::atomic::Ordering::Relaxed))
}

/// Seconds east of UTC used by `todo_today`. Tests set it; the sampler sets it from the OS clock.
pub static LOCAL_OFFSET_SECS: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);

pub fn day_index(ms: i64, offset_secs: i64) -> i64 {
    let secs = ms.div_euclid(1000) + offset_secs;
    secs.div_euclid(86_400)
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WeatherLocation {
    pub id: i64,
    pub name: String,
    pub latitude: f64,
    pub longitude: f64,
    #[serde(default)]
    pub admin1: Option<String>,
    #[serde(default)]
    pub country: Option<String>,
}

impl WeatherLocation {
    pub fn is_valid(&self) -> bool {
        !self.name.trim().is_empty()
            && self.latitude.is_finite()
            && self.longitude.is_finite()
            && (-90.0..=90.0).contains(&self.latitude)
            && (-180.0..=180.0).contains(&self.longitude)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WeatherView {
    pub name: String,
    pub temperature: f64,
    pub code: i32,
    pub is_day: bool,
    pub humidity: Option<f64>,
    pub wind: Option<f64>,
    pub low: Option<f64>,
    pub high: Option<f64>,
    pub rain: Option<f64>,
    pub feels_like: Option<f64>,
    pub uv: Option<f64>,
    pub measured_at: f64,
    pub timezone: String,
    pub stale: bool,
}

pub fn decode_weather(body: &str, now: f64, failed: bool) -> Option<WeatherView> {
    let root: serde_json::Value = serde_json::from_str(body).ok()?;
    let current = root.get("current")?;
    let time = current.get("time")?.as_f64()?;
    let temperature = current.get("temperature_2m")?.as_f64()?;
    let code = current.get("weather_code")?.as_i64()? as i32;
    let is_day = current.get("is_day")?.as_i64()?;
    if !time.is_finite() || !(0.0..4_102_444_800.0).contains(&time) || !temperature.is_finite()
        || !(-100.0..=70.0).contains(&temperature) || !(0..=1).contains(&is_day)
    {
        return None;
    }
    let bounded = |value: Option<f64>, range: std::ops::RangeInclusive<f64>| {
        value.filter(|value| value.is_finite() && range.contains(value))
    };
    let daily = root.get("daily");
    let first = |key: &str| daily.and_then(|daily| daily.get(key)).and_then(|value| value.get(0)).and_then(|value| value.as_f64());
    let low = bounded(first("temperature_2m_min"), -100.0..=70.0);
    let high = bounded(first("temperature_2m_max"), -100.0..=70.0);
    let ordered = match (low, high) {
        (Some(low), Some(high)) if low <= high => Some((low, high)),
        _ => None,
    };
    let timezone = root.get("timezone").and_then(|value| value.as_str()).unwrap_or("GMT").to_string();
    Some(WeatherView {
        name: String::new(),
        temperature,
        code,
        is_day: is_day == 1,
        humidity: bounded(current.get("relative_humidity_2m").and_then(|value| value.as_f64()), 0.0..=100.0),
        wind: bounded(current.get("wind_speed_10m").and_then(|value| value.as_f64()), 0.0..=150.0),
        low: ordered.map(|pair| pair.0),
        high: ordered.map(|pair| pair.1),
        rain: bounded(first("precipitation_probability_max"), 0.0..=100.0),
        feels_like: bounded(current.get("apparent_temperature").and_then(|value| value.as_f64()), -120.0..=80.0),
        uv: bounded(first("uv_index_max"), 0.0..=40.0),
        measured_at: time,
        timezone,
        stale: failed || now - time > 30.0 * 60.0,
    })
}

/// Ids the user is dragging replace the slots of ids that are on screen.
/// An id that is remembered but not in `visible` keeps its place.
pub fn keeping_hidden_slots(visible: &[String], remembered: &[String]) -> Vec<String> {
    let mut remaining = visible.iter();
    let mut replaced = Vec::new();
    for id in remembered {
        if visible.iter().any(|item| item == id) {
            replaced.push(remaining.next().cloned().unwrap_or_else(|| id.clone()));
        } else {
            replaced.push(id.clone());
        }
    }
    replaced.extend(remaining.cloned());
    replaced
}

/// Last good CPU ticks and interface counters, each with its own clock.
/// A failed read must not erase them: the next success would otherwise look
/// like a one-second spike, or like a brand-new baseline.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeterBaseline {
    pub cpu: Option<(u64, u64, u64)>,
    pub cpu_at: Option<f64>,
    pub net: Vec<(u32, u64, u64)>,
    pub net_at: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeterObservation {
    pub cpu_elapsed: Option<f64>,
    pub previous_cpu: Option<(u64, u64, u64)>,
    pub net_elapsed: Option<f64>,
    pub previous_net: Vec<(u32, u64, u64)>,
}

impl MeterBaseline {
    /// `now` is Unix seconds. A gap above ten seconds still advances the clock;
    /// callers reject that gap when they turn the counters into a rate.
    pub fn take(&mut self, now: f64, cpu: Option<(u64, u64, u64)>, net: &[(u32, u64, u64)]) -> MeterObservation {
        let previous_cpu = self.cpu;
        let cpu_elapsed = if now.is_finite() && cpu.is_some() {
            let elapsed = self.cpu_at.map(|then| now - then);
            self.cpu = cpu;
            self.cpu_at = Some(now);
            elapsed
        } else {
            None
        };
        let (net_elapsed, previous_net) = if now.is_finite() && !net.is_empty() {
            let elapsed = self.net_at.map(|then| now - then);
            let previous = std::mem::replace(&mut self.net, net.to_vec());
            self.net_at = Some(now);
            (elapsed, previous)
        } else {
            (None, Vec::new())
        };
        MeterObservation { cpu_elapsed, previous_cpu, net_elapsed, previous_net }
    }
}

/// Battery discharge in watts.
///
/// `SYSTEM_BATTERY_STATE.Rate` is stored as a `DWORD` and has to be read as a
/// signed `LONG`. Microsoft's note is: a positive value charges, a negative
/// value discharges. Some packs only publish a positive magnitude while the
/// discharging flag is set, so that magnitude counts once the caller has
/// already required "on battery" and "discharging". Anything outside
/// 1 mW…500 W is withheld rather than shown as a huge or zero load.
pub fn discharge_watts(ac_online: bool, discharging: bool, rate_bits: u32) -> Option<f64> {
    if ac_online || !discharging {
        return None;
    }
    let milliwatts = match rate_bits as i32 {
        0 | i32::MIN => return None,
        value if value < 0 => -value,
        value => value,
    };
    if !(1..=500_000).contains(&milliwatts) {
        return None;
    }
    Some(milliwatts as f64 / 1000.0)
}

pub fn arrange<T, F>(items: Vec<T>, order: &[String], mut id: F) -> Vec<T>
where
    F: FnMut(&T) -> String,
{
    if order.is_empty() {
        return items;
    }
    let mut remaining = items;
    let mut arranged = Vec::new();
    for wanted in order {
        if let Some(index) = remaining.iter().position(|item| id(item) == *wanted) {
            arranged.push(remaining.remove(index));
        }
    }
    arranged.extend(remaining);
    arranged
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rates_match_the_mac_labels() {
        assert_eq!(format_rate(0.0, false), "0B/s");
        assert_eq!(format_rate(1_500_000.0, true), "1.5M/s");
        assert_eq!(format_rate(1_200_000.0, false), "1.2MB/s");
        assert_eq!(format_rate(300_000.0, false), "300KB/s");
    }

    #[test]
    fn signal_scale_matches_the_mac() {
        assert_eq!(signal_fraction(-65), Some(0.625));
        assert_eq!(signal_fraction(-100), Some(0.0));
        assert_eq!(signal_fraction(-40), Some(1.0));
        assert_eq!(signal_fraction(0), None);
    }

    #[test]
    fn history_ignores_a_gap_and_keeps_the_total() {
        let mut history = History::default();
        let first = history.enrich(100.0, Some(0.0), None, Some(25.0), Some(NetRate { down: 1_200_000.0, up: 300_000.0 }));
        assert!(first.energy_wh.is_none());
        let next = history.enrich(102.0, Some(0.5), None, Some(25.0), Some(NetRate { down: 1_200_000.0, up: 300_000.0 }));
        assert!((next.energy_wh.unwrap() - 50.0 / 3600.0).abs() < 1e-9);
        assert_eq!(next.received_total, Some(2_400_000.0));
        assert!((next.recent_cpu.unwrap().average - 0.25).abs() < 1e-9);
        let after = history.enrich(200.0, Some(0.0), None, Some(25.0), Some(NetRate { down: 1_200_000.0, up: 300_000.0 }));
        assert!(after.recent_cpu.is_none());
        assert_eq!(after.energy_wh, next.energy_wh);
        assert_eq!(after.received_total, next.received_total);
    }

    #[test]
    fn a_rewound_counter_is_not_a_spike() {
        let old = [(1, 5_000_000_000, 100)];
        let new = [(1, 5_000_004_000, 700), (2, 900_000_000, 900_000_000)];
        let rate = net_rate(&new, &old, 2.0).unwrap();
        assert_eq!(rate.down, 2000.0);
        assert_eq!(rate.up, 300.0);
        assert!(net_rate(&old, &new, 1.0).is_none());
        assert!(net_rate(&new, &old, 60.0).is_none());
    }

    #[test]
    fn cpu_deltas_separate_user_and_system() {
        let (user, system) = cpu_fraction(30, 20, 10, (0, 0, 0)).unwrap();
        assert!((user - 0.6).abs() < 1e-9);
        assert!((system - 0.2).abs() < 1e-9);
        assert!(cpu_fraction(1, 1, 5, (0, 0, 0)).is_none(), "idle cannot exceed kernel time");
    }

    #[test]
    fn hidden_slots_stay_put() {
        let remembered = ["codex", "widget-calendar", "system-cpu", "widget-weather"]
            .into_iter().map(str::to_string).collect::<Vec<_>>();
        let visible = ["system-cpu", "codex", "widget-weather"].into_iter().map(str::to_string).collect::<Vec<_>>();
        let next = keeping_hidden_slots(&visible, &remembered);
        assert_eq!(next, vec!["system-cpu", "widget-calendar", "codex", "widget-weather"]);
    }

    #[test]
    fn weather_rejects_an_impossible_temperature() {
        let body = r#"{"timezone":"Asia/Seoul","current":{"time":1790035200,"temperature_2m":23.4,"weather_code":61,"is_day":1,"relative_humidity_2m":65,"wind_speed_10m":2.3},"daily":{"time":[1790002800],"temperature_2m_min":[18],"temperature_2m_max":[26],"precipitation_probability_max":[75]}}"#;
        let view = decode_weather(body, 1790035200.0, false).unwrap();
        assert_eq!(view.temperature, 23.4);
        assert_eq!(view.wind, Some(2.3));
        assert_eq!(view.low, Some(18.0));
        assert!(!view.stale);
        assert!(decode_weather(body, 1790035200.0 + 1801.0, false).unwrap().stale);
        let hot = body.replace("23.4", "234");
        assert!(decode_weather(&hot, 1790035200.0, false).is_none());
    }

    #[test]
    fn unfinished_todos_carry_and_titles_are_bounded() {
        assert!(clean_todo_title("  ").is_none());
        assert!(clean_todo_title(&"a".repeat(201)).is_none());
        assert_eq!(clean_todo_title("  keep  ").as_deref(), Some("keep"));
        LOCAL_OFFSET_SECS.store(0, std::sync::atomic::Ordering::Relaxed);
        let items = vec![
            TodoItem { id: "a".into(), title: "open".into(), created_at: 0, completed_at: None },
            TodoItem { id: "b".into(), title: "done".into(), created_at: 0, completed_at: Some(1_000) },
        ];
        assert_eq!(todo_today(&items, 2_000).len(), 2);
        assert_eq!(todo_today(&items, 86_400_000 + 2_000).iter().map(|item| item.title.as_str()).collect::<Vec<_>>(), vec!["open"]);
    }

    #[test]
    fn a_failed_read_keeps_the_last_counters() {
        let mut baseline = MeterBaseline::default();
        let first = baseline.take(1_000.0, Some((1, 2, 3)), &[(7, 1_000, 100)]);
        assert_eq!(first.cpu_elapsed, None);
        assert_eq!(first.net_elapsed, None);
        let missed = baseline.take(1_001.0, None, &[]);
        assert_eq!(missed.net_elapsed, None);
        assert_eq!(baseline.cpu, Some((1, 2, 3)));
        assert_eq!(baseline.cpu_at, Some(1_000.0));
        assert_eq!(baseline.net, vec![(7, 1_000, 100)]);
        let poisoned = baseline.take(f64::NAN, Some((9, 9, 9)), &[(7, 9_999, 9_999)]);
        assert_eq!(poisoned.cpu_elapsed, None);
        assert_eq!(baseline.net, vec![(7, 1_000, 100)]);
        let next = baseline.take(1_003.0, Some((31, 22, 13)), &[(7, 4_000, 700)]);
        assert_eq!(next.cpu_elapsed, Some(3.0));
        assert_eq!(next.previous_cpu, Some((1, 2, 3)));
        assert_eq!(next.previous_net, vec![(7, 1_000, 100)]);
        let rate = net_rate(&[(7, 4_000, 700)], &next.previous_net, next.net_elapsed.unwrap()).unwrap();
        assert_eq!(rate.down, 1_000.0);
        assert_eq!(rate.up, 200.0);
        let slept = baseline.take(1_030.0, Some((40, 30, 20)), &[(7, 8_000, 900)]);
        assert!(net_rate(&[(7, 8_000, 900)], &slept.previous_net, slept.net_elapsed.unwrap()).is_none());
        assert_eq!(baseline.net_at, Some(1_030.0));
    }

    #[test]
    fn discharge_watts_follow_the_signed_rate() {
        let discharging = (-15_000i32) as u32;
        assert_eq!(discharge_watts(false, true, discharging), Some(15.0));
        assert_eq!(discharge_watts(true, true, discharging), None, "external power is not system load");
        assert_eq!(discharge_watts(false, false, discharging), None);
        assert_eq!(discharge_watts(false, true, 15_000), Some(15.0), "magnitude reported while discharging");
        assert_eq!(discharge_watts(false, true, 0), None);
        assert_eq!(discharge_watts(false, true, 2_000_000), None);
        assert_eq!(discharge_watts(false, true, i32::MIN as u32), None);
    }
}
