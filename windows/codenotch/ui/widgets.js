/* System meters, calendar, weather and to-dos. The page and the node tests both load this file. */
(function (root) {
  const TEXT = {
    en: {
      'Sampling…':'Sampling…', 'All cores':'All cores', 'Physical memory':'Physical memory',
      'Busiest GPU':'Busiest GPU', 'GPU utilization is unavailable on this computer.':'GPU utilization is unavailable on this computer.',
      'Home volume':'Home volume', 'No reading':'No reading', 'Last 60s avg / peak':'Last 60s avg / peak',
      'User / System':'User / System', 'Per-core load':'Per-core load', 'Unavailable':'Unavailable',
      'Free space':'Free space', 'Available for files':'Available for files', 'Primary connection':'Primary connection',
      'Download':'Download', 'Upload':'Upload', 'Received while monitoring':'Received while monitoring',
      'Sent while monitoring':'Sent while monitoring', 'Measured for':'Measured for',
      'Battery remaining':'Battery remaining', 'Charging':'Charging', 'Fully charged':'Fully charged',
      'External power · Not charging':'External power · Not charging', 'On battery':'On battery',
      'Battery information is unavailable on this computer.':'Battery information is unavailable on this computer.',
      'System consumption':'System consumption', 'Power consumption is unavailable. A discharge rate is shown only while on battery.':'Power consumption is unavailable. A discharge rate is shown only while on battery.',
      'Estimated discharge':'Estimated discharge', 'Ethernet / Wi-Fi':'Ethernet / Wi-Fi',
      'Wired connection':'Wired connection', 'Wi-Fi':'Wi-Fi', 'No primary connection':'No primary connection',
      'Other connection':'Other connection', 'Sampling network…':'Sampling network…', 'Sampling CPU…':'Sampling CPU…',
      'Calendar':'Calendar', 'Today':'Today', 'Weather':'Weather', 'Loading weather…':'Loading weather…',
      'Choose a weather city in Settings.':'Choose a weather city in Settings.',
      'Weather is unavailable. It will retry automatically.':'Weather is unavailable. It will retry automatically.',
      "Today's to-do":"Today's to-do", 'Add your first task for today.':'Add your first task for today.',
      'Add to-do':'Add to-do', 'Unfinished tasks carry over · Saved on this PC':'Unfinished tasks carry over · Saved on this PC',
      'Previous month':'Previous month', 'Next month':'Next month', 'Copy date':'Copy date', 'Copied':'Copied',
      'In 1 day':'In 1 day', '1 day ago':'1 day ago', 'Clear':'Clear', 'Partly cloudy':'Partly cloudy',
      'Overcast':'Overcast', 'Fog':'Fog', 'Drizzle':'Drizzle', 'Rain':'Rain', 'Snow':'Snow',
      'Thunderstorm':'Thunderstorm', 'Unknown conditions':'Unknown conditions', 'Feels like':'Feels like',
      'Daily low / high':'Daily low / high', 'Chance of rain today':'Chance of rain today',
      'Humidity / Wind':'Humidity / Wind', 'UV peak today':'UV peak today', 'Refresh':'Refresh'
    },
    ko: {
      'Sampling…':'측정 중…', 'All cores':'모든 코어', 'Physical memory':'실제 메모리',
      'Busiest GPU':'가장 바쁜 GPU', 'GPU utilization is unavailable on this computer.':'이 컴퓨터에서는 GPU 사용률을 알 수 없습니다.',
      'Home volume':'홈 볼륨', 'No reading':'측정값 없음', 'Last 60s avg / peak':'최근 60초 평균 / 최고',
      'User / System':'사용자 / 시스템', 'Per-core load':'코어별 사용률', 'Unavailable':'사용할 수 없음',
      'Free space':'남은 공간', 'Available for files':'파일에 쓸 수 있는 공간', 'Primary connection':'기본 연결',
      'Download':'다운로드', 'Upload':'업로드', 'Received while monitoring':'측정 중 받은 양',
      'Sent while monitoring':'측정 중 보낸 양', 'Measured for':'측정 시간',
      'Battery remaining':'남은 배터리', 'Charging':'충전 중', 'Fully charged':'충전 완료',
      'External power · Not charging':'외부 전원 · 충전하지 않음', 'On battery':'배터리 사용 중',
      'Battery information is unavailable on this computer.':'이 컴퓨터에서는 배터리 정보를 알 수 없습니다.',
      'System consumption':'시스템 소비 전력', 'Power consumption is unavailable. A discharge rate is shown only while on battery.':'소비 전력을 알 수 없습니다. 배터리로 동작할 때만 방전 속도를 추정합니다.',
      'Estimated discharge':'추정 방전', 'Ethernet / Wi-Fi':'이더넷 / Wi-Fi',
      'Wired connection':'유선 연결', 'Wi-Fi':'Wi-Fi', 'No primary connection':'기본 연결 없음',
      'Other connection':'다른 연결', 'Sampling network…':'네트워크 측정 중…', 'Sampling CPU…':'CPU 측정 중…',
      'Calendar':'달력', 'Today':'오늘', 'Weather':'날씨', 'Loading weather…':'날씨를 불러오는 중…',
      'Choose a weather city in Settings.':'설정에서 날씨 도시를 고르세요.',
      'Weather is unavailable. It will retry automatically.':'날씨를 가져오지 못했습니다. 자동으로 다시 시도합니다.',
      "Today's to-do":'오늘의 할 일', 'Add your first task for today.':'오늘 첫 할 일을 추가하세요.',
      'Add to-do':'할 일 추가', 'Unfinished tasks carry over · Saved on this PC':'끝내지 못한 일은 다음 날로 넘어갑니다 · 이 PC에 저장됨',
      'Previous month':'이전 달', 'Next month':'다음 달', 'Copy date':'날짜 복사', 'Copied':'복사됨',
      'In 1 day':'1일 후', '1 day ago':'1일 전', 'Clear':'맑음', 'Partly cloudy':'구름 조금',
      'Overcast':'흐림', 'Fog':'안개', 'Drizzle':'이슬비', 'Rain':'비', 'Snow':'눈',
      'Thunderstorm':'뇌우', 'Unknown conditions':'알 수 없는 날씨', 'Feels like':'체감',
      'Daily low / high':'하루 최저 / 최고', 'Chance of rain today':'오늘 강수 확률',
      'Humidity / Wind':'습도 / 바람', 'UV peak today':'오늘 자외선 최고', 'Refresh':'새로고침'
    }
  };
  TEXT.ja = TEXT.ja || {
    'Sampling…':'計測中…', 'All cores':'全コア', 'Physical memory':'物理メモリ', 'Busiest GPU':'最も忙しい GPU',
    'Home volume':'ホームのボリューム', 'No reading':'測定値なし', 'Calendar':'カレンダー', 'Today':'今日',
    'Weather':'天気', 'Loading weather…':'天気を読み込み中…', "Today's to-do":'今日のタスク',
    'Add to-do':'タスクを追加', 'Charging':'充電中', 'On battery':'バッテリー駆動', 'Download':'ダウンロード', 'Upload':'アップロード', 'Refresh':'更新'
  };
  TEXT.zh = {
    'Sampling…':'正在采样…', 'All cores':'全部核心', 'Physical memory':'物理内存', 'Busiest GPU':'最忙的 GPU',
    'Home volume':'主文件夹所在卷', 'No reading':'没有读数', 'Calendar':'日历', 'Today':'今天',
    'Weather':'天气', 'Loading weather…':'正在加载天气…', "Today's to-do":'今天的待办',
    'Add to-do':'添加待办', 'Charging':'正在充电', 'On battery':'使用电池', 'Download':'下载', 'Upload':'上传', 'Refresh':'刷新',
    'Clear':'晴', 'Rain':'雨', 'Snow':'雪'
  };
  TEXT['zh-Hant'] = {
    'Sampling…':'正在取樣…', 'All cores':'全部核心', 'Physical memory':'實體記憶體', 'Calendar':'日曆',
    'Today':'今天', 'Weather':'天氣', "Today's to-do":'今天的待辦', 'Add to-do':'新增待辦', 'Refresh':'重新整理',
    'Charging':'充電中', 'On battery':'使用電池', 'Download':'下載', 'Upload':'上傳', 'Clear':'晴', 'Rain':'雨'
  };
  TEXT.ru = {
    'Sampling…':'Измерение…', 'All cores':'Все ядра', 'Physical memory':'Физическая память',
    'Calendar':'Календарь', 'Today':'Сегодня', 'Weather':'Погода', "Today's to-do":'Дела на сегодня',
    'Add to-do':'Добавить дело', 'Charging':'Заряжается', 'On battery':'От батареи', 'Refresh':'Обновить',
    'Download':'Загрузка', 'Upload':'Отдача', 'No reading':'Нет данных', 'Clear':'Ясно', 'Rain':'Дождь'
  };
  TEXT.uk = {
    'Sampling…':'Вимірювання…', 'All cores':'Усі ядра', 'Physical memory':'Фізична памʼять',
    'Calendar':'Календар', 'Today':'Сьогодні', 'Weather':'Погода', "Today's to-do":'Справи на сьогодні',
    'Add to-do':'Додати справу', 'Charging':'Заряджається', 'On battery':'Від батареї', 'Refresh':'Оновити',
    'Download':'Завантаження', 'Upload':'Відвантаження', 'No reading':'Немає даних', 'Clear':'Ясно', 'Rain':'Дощ'
  };

  function t(lang, key) {
    const table = TEXT[lang] || TEXT.en;
    return table[key] || TEXT.en[key] || key;
  }
  function formatRate(bytes, compact) {
    const units = compact ? ['B/s', 'K/s', 'M/s', 'G/s', 'T/s'] : ['B/s', 'KB/s', 'MB/s', 'GB/s', 'TB/s'];
    let value = Number.isFinite(bytes) ? Math.max(0, bytes) : 0;
    let unit = 0;
    while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
    const text = unit === 0 || value >= 100 ? value.toFixed(0) : value.toFixed(1);
    return text + units[unit];
  }
  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes < 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value = bytes, unit = 0;
    while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
    return (unit === 0 || value >= 100 ? value.toFixed(0) : value.toFixed(1)) + ' ' + units[unit];
  }
  function percent(fraction) {
    if (!Number.isFinite(fraction)) return '—';
    return Math.round(Math.min(1, Math.max(0, fraction)) * 100) + '%';
  }
  function colorOf(payload, id) {
    const raw = payload.colors && payload.colors[id];
    return raw ? '#' + String(raw).replace('#', '') : null;
  }
  function hidden(payload, id) {
    return Array.isArray(payload.hidden) && payload.hidden.indexOf(id) >= 0;
  }
  function duration(seconds) {
    seconds = Math.max(0, Math.floor(seconds || 0));
    if (seconds >= 86400) return Math.floor(seconds / 86400) + 'd ' + Math.floor((seconds % 86400) / 3600) + 'h';
    if (seconds >= 3600) return Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm';
    if (seconds >= 60) return Math.floor(seconds / 60) + 'm ' + (seconds % 60) + 's';
    return seconds + 's';
  }
  function meter(payload, id, name, glyph, fraction, text, invert, steady, rows) {
    return {
      id: id, base: id, name: name, glyph: glyph,
      meter: { text: text, fraction: fraction, invert: !!invert, steady: !!steady, color: colorOf(payload, id), rows: rows, kind: 'meter' },
      snap: { status: 'ok', windows: [], fetched_at: 0, note: '' }
    };
  }
  function row(label, detail, fraction) {
    return { label: label, detail: detail, fraction: fraction };
  }
  function extraCells(payload, lang) {
    payload = payload || {};
    const cells = [];
    if (payload.system) {
      const cpu = Number.isFinite(payload.cpu) ? payload.cpu : null;
      if (!hidden(payload, 'system-cpu')) {
        const rows = [row(t(lang, 'All cores'), cpu == null ? t(lang, 'Sampling CPU…') : percent(cpu) + ' active', cpu)];
        if (payload.cpuUser != null && payload.cpuSystem != null) rows.push(row(t(lang, 'User / System'), percent(payload.cpuUser) + ' / ' + percent(payload.cpuSystem)));
        if (payload.recentCpu) rows.push(row(t(lang, 'Last 60s avg / peak'), percent(payload.recentCpu.average) + ' / ' + percent(payload.recentCpu.peak)));
        rows.push(row(t(lang, 'Per-core load'), t(lang, 'Unavailable')));
        cells.push(meter(payload, 'system-cpu', 'CPU', 'CPU', cpu, cpu == null ? '—' : percent(cpu), false, false, rows));
      }
      if (!hidden(payload, 'system-memory') && payload.memoryTotal) {
        const fraction = payload.memoryUsed / payload.memoryTotal;
        cells.push(meter(payload, 'system-memory', 'RAM', 'RAM', fraction, percent(fraction), false, false, [
          row(t(lang, 'Physical memory'), formatBytes(payload.memoryUsed) + ' / ' + formatBytes(payload.memoryTotal), fraction)
        ]));
      } else if (!hidden(payload, 'system-memory')) {
        cells.push(meter(payload, 'system-memory', 'RAM', 'RAM', null, '—', false, false, [row(t(lang, 'Physical memory'), t(lang, 'No reading'))]));
      }
      if (!hidden(payload, 'system-gpu')) {
        cells.push(meter(payload, 'system-gpu', 'GPU', 'GPU', null, '—', false, false, [
          row(t(lang, 'Busiest GPU'), t(lang, 'GPU utilization is unavailable on this computer.'))
        ]));
      }
      if (!hidden(payload, 'system-disk') && payload.diskTotal) {
        const fraction = payload.diskUsed / payload.diskTotal;
        const rows = [row(t(lang, 'Home volume'), formatBytes(payload.diskUsed) + ' / ' + formatBytes(payload.diskTotal), fraction)];
        if (payload.diskAvailable != null) rows.push(row(t(lang, 'Available for files'), formatBytes(payload.diskAvailable)));
        cells.push(meter(payload, 'system-disk', 'DISK', 'DISK', fraction, percent(fraction), false, false, rows));
      } else if (!hidden(payload, 'system-disk')) {
        cells.push(meter(payload, 'system-disk', 'DISK', 'DISK', null, '—', false, false, [row(t(lang, 'Home volume'), t(lang, 'No reading'))]));
      }
      if (!hidden(payload, 'system-network')) {
        const hasNet = payload.netDown != null && payload.netUp != null;
        const total = hasNet ? payload.netDown + payload.netUp : null;
        let fraction = null, invert = false;
        if (payload.link === 'wired') { fraction = 1; invert = true; }
        else if (payload.link === 'disconnected') { fraction = 0; invert = true; }
        const rows = [row(t(lang, 'Primary connection'), linkTitle(payload, lang))];
        if (hasNet) {
          rows.push(row(t(lang, 'Download'), formatRate(payload.netDown, false)));
          rows.push(row(t(lang, 'Upload'), formatRate(payload.netUp, false)));
        }
        if (payload.receivedTotal != null) {
          rows.push(row(t(lang, 'Received while monitoring'), formatBytes(payload.receivedTotal)));
          rows.push(row(t(lang, 'Sent while monitoring'), formatBytes(payload.sentTotal)));
          rows.push(row(t(lang, 'Measured for'), duration(payload.networkSeconds)));
        }
        cells.push(meter(payload, 'system-network', 'NET', 'NET', fraction, hasNet ? formatRate(total, true) : '—', invert, false, rows));
      }
      if (!hidden(payload, 'system-battery')) {
        if (payload.battery == null) {
          cells.push(meter(payload, 'system-battery', 'BAT', 'BAT', null, '—', true, false, [
            row(t(lang, 'Battery remaining'), t(lang, 'Battery information is unavailable on this computer.'))
          ]));
        } else {
          const state = { charging: 'Charging', charged: 'Fully charged', ac: 'External power · Not charging', battery: 'On battery' }[payload.batteryState] || 'On battery';
          const mark = payload.batteryState === 'charging' ? ' ⚡' : '';
          cells.push(meter(payload, 'system-battery', 'BAT', 'BAT', payload.battery, percent(payload.battery) + mark, true, false, [
            row(t(lang, 'Battery remaining'), percent(payload.battery), payload.battery),
            row(t(lang, state), '')
          ]));
        }
      }
      if (!hidden(payload, 'system-power')) {
        const watts = Number.isFinite(payload.watts) ? payload.watts : null;
        const rows = [];
        if (watts == null) rows.push(row(t(lang, 'System consumption'), t(lang, 'Power consumption is unavailable. A discharge rate is shown only while on battery.')));
        else rows.push(row(t(lang, payload.wattsEstimated ? 'Estimated discharge' : 'System consumption'), watts.toFixed(1) + 'W'));
        if (payload.energyWh != null) rows.push(row(t(lang, 'Measured for'), payload.energyWh.toFixed(2) + ' Wh · ' + duration(payload.energySeconds)));
        cells.push(meter(payload, 'system-power', 'PWR', 'PWR', null, watts == null ? '—' : watts.toFixed(1) + 'W', false, false, rows));
      }
    }
    if (payload.calendar && !hidden(payload, 'widget-calendar')) {
      const now = new Date();
      cells.push({
        id: 'widget-calendar', base: 'widget-calendar', name: t(lang, 'Calendar'), glyph: 'CAL',
        meter: { text: (now.getMonth() + 1) + '/' + now.getDate(), fraction: null, color: colorOf(payload, 'widget-calendar'), rows: [], kind: 'calendar' },
        snap: { status: 'ok', windows: [], fetched_at: 0, note: '' }
      });
    }
    if (payload.weatherOn && !hidden(payload, 'widget-weather')) {
      const weather = payload.weather;
      const text = weather ? Math.round(weather.temperature) + '°' : '—';
      const name = weather ? weather.name : (payload.weatherCity ? payload.weatherCity.name : t(lang, 'Weather'));
      cells.push({
        id: 'widget-weather', base: 'widget-weather', name: name, glyph: 'WX',
        meter: { text: text, fraction: null, color: colorOf(payload, 'widget-weather'), rows: weatherRows(payload, lang), kind: 'weather', stale: !!(weather && weather.stale) },
        snap: { status: weather && weather.stale ? 'stale' : 'ok', windows: [], fetched_at: 0, note: '' }
      });
    }
    if (payload.todoOn && !hidden(payload, 'widget-todo')) {
      const items = Array.isArray(payload.todos) ? payload.todos : [];
      const done = items.filter(item => item.done).length;
      const fraction = items.length ? done / items.length : 0;
      cells.push({
        id: 'widget-todo', base: 'widget-todo', name: 'TODO', glyph: 'TODO',
        meter: { text: done + '/' + items.length, fraction: fraction, steady: true, color: colorOf(payload, 'widget-todo'), rows: [], kind: 'todo', items: items },
        snap: { status: 'ok', windows: [], fetched_at: 0, note: '' }
      });
    }
    return cells;
  }
  function linkTitle(payload, lang) {
    if (payload.link === 'wired') return t(lang, 'Wired connection') + (payload.linkName ? ' · ' + payload.linkName : '');
    if (payload.link === 'wifi') return 'Wi-Fi' + (payload.linkName ? ' · ' + payload.linkName : '');
    if (payload.link === 'disconnected') return t(lang, 'No primary connection');
    return t(lang, 'Other connection');
  }
  function condition(code) {
    if (code === 0 || code === 1) return 'Clear';
    if (code === 2) return 'Partly cloudy';
    if (code === 3) return 'Overcast';
    if (code === 45 || code === 48) return 'Fog';
    if ([51, 53, 55, 56, 57].indexOf(code) >= 0) return 'Drizzle';
    if ([61, 63, 65, 66, 67, 80, 81, 82].indexOf(code) >= 0) return 'Rain';
    if ([71, 73, 75, 77, 85, 86].indexOf(code) >= 0) return 'Snow';
    if ([95, 96, 99].indexOf(code) >= 0) return 'Thunderstorm';
    return 'Unknown conditions';
  }
  function weatherRows(payload, lang) {
    if (!payload.weather) {
      const message = payload.weatherCity ? 'Weather is unavailable. It will retry automatically.' : 'Choose a weather city in Settings.';
      if (payload.weatherFailed || payload.weatherCity) return [row(t(lang, 'Weather'), t(lang, message))];
      return [row(t(lang, 'Weather'), t(lang, 'Loading weather…'))];
    }
    const weather = payload.weather;
    const rows = [row(t(lang, condition(weather.code)), weather.temperature.toFixed(1) + '°C')];
    if (weather.feelsLike != null) rows.push(row(t(lang, 'Feels like'), weather.feelsLike.toFixed(1) + '°C'));
    if (weather.low != null && weather.high != null) rows.push(row(t(lang, 'Daily low / high'), Math.round(weather.low) + '° / ' + Math.round(weather.high) + '°C'));
    if (weather.rain != null) rows.push(row(t(lang, 'Chance of rain today'), Math.round(weather.rain) + '%'));
    if (weather.humidity != null && weather.wind != null) rows.push(row(t(lang, 'Humidity / Wind'), Math.round(weather.humidity) + '% · ' + weather.wind.toFixed(1) + ' m/s'));
    if (weather.uv != null) rows.push(row(t(lang, 'UV peak today'), weather.uv.toFixed(1)));
    return rows;
  }
  function arrange(list, order) {
    if (!order || !order.length) return list;
    const remaining = list.slice();
    const arranged = [];
    order.forEach(id => {
      const index = remaining.findIndex(item => item.id === id);
      if (index >= 0) arranged.push(remaining.splice(index, 1)[0]);
    });
    return arranged.concat(remaining);
  }
  function dayDistance(offset) {
    if (offset === 0) return 'Today';
    if (offset === 1) return 'In 1 day';
    if (offset === -1) return '1 day ago';
    if (offset > 1) return 'In ' + offset + ' days';
    return (-offset) + ' days ago';
  }
  function calendarMonth(now, offset, weekStartsOn) {
    const start = new Date(now.getFullYear(), now.getMonth() + (offset || 0), 1);
    const first = (start.getDay() - (weekStartsOn || 0) + 7) % 7;
    const days = [];
    for (let index = 0; index < 42; index++) days.push(new Date(start.getFullYear(), start.getMonth(), index - first + 1));
    return { start: start, days: days };
  }
  root.CodenotchWidgets = {
    t: t, formatRate: formatRate, formatBytes: formatBytes, extraCells: extraCells, arrange: arrange,
    dayDistance: dayDistance, calendarMonth: calendarMonth, condition: condition
  };
})(typeof window !== 'undefined' ? window : globalThis);
