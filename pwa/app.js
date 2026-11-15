/* 票档监控 · 纯前端版（PWA）
 * 逻辑与 Python / Swift 版一致：解析 cURL → 轮询 get_show_sku_info → 阈值跃迁 → 通知 + 跳转。
 * 注意：浏览器直连抖音接口会被 CORS 拦，必须配一个代理（见 IPA-README.md 里的 Worker 代码）。
 */
'use strict';

const S = {
  cookies: {},
  headers: {},
  productId: '',
  showName: '',
  session: '',
  sku: '',
  count: 1,
  threshold: 1,
  interval: 1.5,
  autoOpen: true,
  globalWatch: false,
  barkKey: '',
  proxy: '',
  running: false,
};

const KEY = 'dtg.pwa.v1';
const state = { last: {}, lastFire: {}, timer: null, logs: [] };
const COOLDOWN = 20000;

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- 持久化 ---------------- */
function save() {
  const { productId, showName, session, sku, count, threshold, interval,
          autoOpen, globalWatch, barkKey, proxy, cookies, headers } = S;
  localStorage.setItem(KEY, JSON.stringify({
    productId, showName, session, sku, count, threshold, interval,
    autoOpen, globalWatch, barkKey, proxy, cookies, headers,
  }));
}
function load() {
  try {
    const o = JSON.parse(localStorage.getItem(KEY) || '{}');
    Object.assign(S, o);
  } catch (_) { /* 忽略 */ }
}

/* ---------------- 日志 ---------------- */
function log(level, text) {
  const t = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  const line = `[${t}] ${level} ${text}`;
  state.logs.push(line);
  if (state.logs.length > 300) state.logs.shift();
  const box = $('log');
  if (box) {
    const div = document.createElement('div');
    div.className = level === 'HIT' ? 'hit' : level === 'ERR' ? 'err' : level === 'DEBUG' ? 'dbg' : '';
    div.textContent = line;
    box.appendChild(div);
    box.scrollTop = box.scrollHeight;
  }
}

/* ---------------- 解析 cURL / HAR / 链接 ---------------- */
function parseCookieString(raw) {
  const out = {};
  String(raw).split(';').forEach((p) => {
    const i = p.indexOf('=');
    if (i < 0) return;
    const k = p.slice(0, i).trim();
    const v = p.slice(i + 1).trim().replace(/^["']|["']$/g, '');
    if (!k || !v) return;
    if (['path', 'domain', 'expires', 'max-age', 'samesite'].includes(k.toLowerCase())) return;
    out[k] = v;
  });
  return out;
}

function parseAny(text) {
  const t = String(text || '').trim();
  const res = { kind: 'text', cookies: {}, headers: {}, productId: '', session: '', price: 0 };

  if (t.startsWith('{') && (t.includes('"log"') || t.includes('"entries"'))) {
    res.kind = 'har';
    try {
      const root = JSON.parse(t);
      const entries = (((root.log || {}).entries) || []);
      let best = null; let score = -1;
      for (const e of entries) {
        const req = e.request || {};
        const url = req.url || '';
        let s = 0;
        if (url.includes('get_show_sku_info') || url.includes('product/info')) s += 100;
        if (url.includes('product_id')) s += 10;
        if ((req.headers || []).some((h) => (h.name || '').toLowerCase() === 'cookie')) s += 5;
        if (s > score) { score = s; best = req; }
      }
      if (best) {
        for (const h of best.headers || []) {
          if ((h.name || '').toLowerCase() === 'cookie') {
            Object.assign(res.cookies, parseCookieString(h.value));
          } else if (h.name) {
            res.headers[h.name] = h.value;
          }
        }
      }
    } catch (e) { log('ERR', 'HAR 解析失败: ' + e.message); }
  } else if (t.toLowerCase().includes('curl')) {
    res.kind = 'curl';
    const re = /-H\s+['"]([^'"]+)['"]|-b\s+['"]([^'"]+)['"]/g;
    let m;
    while ((m = re.exec(t)) !== null) {
      if (m[1]) {
        const idx = m[1].indexOf(':');
        const k = m[1].slice(0, idx).trim();
        const v = m[1].slice(idx + 1).trim();
        if (k.toLowerCase() === 'cookie') Object.assign(res.cookies, parseCookieString(v));
        else if (k) res.headers[k] = v;
      } else if (m[2]) {
        Object.assign(res.cookies, parseCookieString(m[2]));
      }
    }
  } else if (t.includes('http')) {
    res.kind = 'link';
  } else if (t.includes('=')) {
    res.kind = 'cookie';
    Object.assign(res.cookies, parseCookieString(t));
  }

  const pid = t.match(/(?:product_id|show_id|spu_id|activity_id)=?(\d{15,19})/);
  if (pid) res.productId = pid[1];
  const d = t.match(/(20\d{2}-\d{2}-\d{2})/);
  const hm = t.match(/([01]\d|2[0-3]):[0-5]\d/);
  if (d) res.session = d[1] + (hm ? ' ' + hm[0] : '');
  const pr = t.match(/(?:¥|￥)?\s*(\d{2,5}(?:\.\d{1,2})?)\s*元/);
  if (pr) res.price = parseFloat(pr[1]);
  return res;
}

/* ---------------- 接口 ---------------- */
const BASE_PARAMS = {
  in_sp_time: '0', need_personal_recommend: '1', version_code: '32.9.0',
  js_sdk_version: '3.56.0.8', tma_jssdk_version: '3.56.0.8', app_name: 'douyin_lite',
  app_version: '32.9.0', channel: 'App Store', mcc_mnc: '46001', aid: '2329',
  minor_status: '0', screen_width: '1242', os_api: '18', ac: '4G', os_version: '15.1',
  package: 'com.ss.android.ugc.aweme.lite',
};

const STOCK_KEYS = ['stock', 'stock_num', 'remain_stock', 'remain', 'left_stock',
  'inventory', 'stock_count', 'surplus', 'available_num', 'remain_num'];
const PRICE_KEYS = ['price', 'sale_price', 'origin_price', 'market_price', 'discount_price'];
const NAME_KEYS = ['sku_name', 'name', 'title', 'ticket_name', 'sku_title', 'seat_name'];
const ID_KEYS = ['sku_id', 'id', 'spu_id', 'product_id'];

function pick(d, keys) {
  for (const k of keys) if (d[k] !== undefined && d[k] !== null && d[k] !== '') return d[k];
  return null;
}

function extractSkus(node, out) {
  out = out || [];
  if (Array.isArray(node)) { node.forEach((n) => extractSkus(n, out)); return out; }
  if (node && typeof node === 'object') {
    const stock = pick(node, STOCK_KEYS);
    const price = pick(node, PRICE_KEYS);
    if (stock !== null && price !== null) {
      const s = parseFloat(stock); const p = parseFloat(price);
      if (!Number.isNaN(s) && !Number.isNaN(p)) {
        out.push({
          id: String(pick(node, ID_KEYS) || out.length),
          name: String(pick(node, NAME_KEYS) || 'sku-' + out.length),
          price: p, stock: Math.round(s),
        });
      }
    }
    Object.values(node).forEach((v) => extractSkus(v, out));
  }
  const seen = new Set();
  return out.filter((s) => {
    const k = s.name + '#' + s.price;
    if (seen.has(k)) return false;
    seen.add(k); return true;
  });
}

async function fetchSkus(productId) {
  const qs = new URLSearchParams({ ...BASE_PARAMS, product_id: productId, show_id: productId,
    device_id: String(Math.floor(Math.random() * 9e17) + 1e17), cdid: crypto.randomUUID() });
  const target = 'https://life5-normal-m-zb.amemv.com/data/v1/life/general/facade/get_show_sku_info?' + qs;
  const url = S.proxy ? S.proxy + (S.proxy.includes('?') ? '&' : '?') + 'url=' + encodeURIComponent(target) : target;
  const r = await fetch(url, { headers: { 'x-dtg-cookie': cookieHeader() } });
  const text = await r.text();
  if (!text.trim()) throw new Error(`HTTP ${r.status} 空响应体（缺签名/Cookie）`);
  const data = JSON.parse(text);
  const skus = extractSkus(data);
  if (!skus.length) throw new Error('响应里没解析出票档');
  return skus;
}

function cookieHeader() {
  return Object.entries(S.cookies).map(([k, v]) => `${k}=${v}`).join('; ');
}

/* ---------------- 通知 / 跳转 ---------------- */
async function notify(title, body) {
  if ('Notification' in window && Notification.permission === 'granted') {
    try {
      new Notification(title, { body, tag: 'dtg-hit', renotify: true });
    } catch (_) { /* iOS 需已安装为 PWA */ }
  }
  if (S.barkKey) {
    try {
      // Bark 支持 GET，绕过 CORS 的最简做法
      const u = `https://api.day.app/${S.barkKey}/${encodeURIComponent(title)}/${encodeURIComponent(body)}?group=${encodeURIComponent('抢票监控')}&level=timeSensitive&sound=alarm`;
      await fetch(u, { mode: 'no-cors' });
      log('INFO', 'Bark 已发送');
    } catch (e) { log('ERR', 'Bark 失败: ' + e.message); }
  }
  if (navigator.vibrate) navigator.vibrate([200, 100, 200]);
}

function deepLink(sku) {
  const inner = 'https://life.douyin.com/p/show/detail?product_id=' + S.productId +
    '&session_time=' + encodeURIComponent(S.session) +
    '&sku_name=' + encodeURIComponent(sku) + '&buy_count=' + S.count;
  return inner;
}

function openDouyin(sku) {
  const link = deepLink(sku);
  log('INFO', '跳转: ' + link.slice(0, 80));
  window.location.href = link;     // Universal Link，装了抖音会直接接管
}

/* ---------------- 引擎 ---------------- */
function evaluate(skus) {
  const watch = S.globalWatch ? skus
    : [skus.find((s) => s.name.replace(/\s/g, '').includes(S.sku.replace(/\s/g, ''))) || skus[0]];
  const hits = [];
  const now = Date.now();

  for (const s of watch) {
    if (!s || s.stock < S.threshold) continue;
    const before = state.last[s.name];
    const first = before === undefined;
    const crossed = (before || 0) < S.threshold;
    if (!(first || crossed)) continue;
    const k = s.name;
    if (state.lastFire[k] && now - state.lastFire[k] < COOLDOWN) continue;
    hits.push(s);
  }
  skus.forEach((s) => { state.last[s.name] = s.stock; });

  if (!hits.length) {
    log('DEBUG', watch.map((s) => `${s.name}:${s.stock}`).join(' / ') || '空');
    return;
  }
  for (const s of hits) {
    state.lastFire[s.name] = now;
    const body = `${S.session.slice(5, 10)} ${S.showName}｜${s.name} 有票${s.stock}张（阈值${S.threshold}）`;
    log('HIT', body);
    notify('发现库存', body);
    if (S.autoOpen) openDouyin(s.name);
  }
}

async function tick() {
  if (!S.running || !S.productId) return;
  try {
    const skus = await fetchSkus(S.productId);
    evaluate(skus);
    renderSkus(skus);
  } catch (e) {
    log('ERR', e.message);
  }
  if (S.running) {
    const jitter = Math.random() * 200;
    state.timer = setTimeout(tick, S.interval * 1000 + jitter);
  }
}

function start() {
  if (!S.productId) { log('ERR', '先填商品ID'); return; }
  if ('Notification' in window && Notification.permission === 'default') {
    Notification.requestPermission();
  }
  S.running = true;
  log('INFO', `✅ 监听并触发监控已启动（阈值 ${S.threshold}，间隔 ${S.interval}s）`);
  tick();
  sync();
}
function stop() {
  S.running = false;
  clearTimeout(state.timer);
  state.timer = null;
  log('INFO', '监控已停止');
  sync();
}

/* ---------------- UI ---------------- */
function renderSkus(skus) {
  const box = $('skus');
  if (!box) return;
  box.innerHTML = '';
  skus.forEach((s) => {
    const row = document.createElement('div');
    row.className = 'sku' + (s.stock >= S.threshold ? ' ok' : '');
    row.innerHTML = `<div><b>${s.name}</b><span class="price">¥${s.price >= 1000 ? s.price / 100 : s.price}</span></div>
      <div class="stock">${s.stock > 0 ? '剩余 ' + s.stock + ' 张' : '无票'}</div>`;
    row.onclick = () => {
      S.sku = s.name;
      $('sku').value = s.name;
      sync();
      log('INFO', '选中票档: ' + s.name);
    };
    box.appendChild(row);
  });
}

function sync() {
  const set = (id, val) => { const el = $(id); if (el) el.value = val; };
  const chk = (id, val) => { const el = $(id); if (el) el.checked = val; };
  set('productId', S.productId); set('showName', S.showName); set('session', S.session);
  set('sku', S.sku); set('count', S.count); set('threshold', S.threshold);
  set('interval', S.interval); set('bark', S.barkKey); set('proxy', S.proxy);
  chk('autoOpen', S.autoOpen); chk('global', S.globalWatch);
  const btn = $('toggle');
  if (btn) { btn.textContent = S.running ? '停止监控' : '开始监控'; btn.className = S.running ? 'red' : 'green'; }
  const badge = $('badge');
  if (badge) { badge.textContent = S.running ? '监控运行中' : '监控已停止'; }
}

function bind() {
  const on = (id, ev, fn) => { const el = $(id); if (el) el.addEventListener(ev, fn); };
  on('parse', 'click', () => {
    const r = parseAny($('paste').value);
    Object.assign(S.cookies, r.cookies);
    Object.assign(S.headers, r.headers);
    if (r.productId) S.productId = r.productId;
    if (r.session) S.session = r.session;
    log('INFO', `解析: ${r.kind} · cookie ${Object.keys(r.cookies).length} 个 · 商品ID ${r.productId || '未识别'}`);
    $('result').textContent = JSON.stringify({
      来源: r.kind, cookie数: Object.keys(r.cookies).length,
      商品ID: r.productId || null, 场次: r.session || null, 价格: r.price || null,
    }, null, 2);
    sync(); save();
  });
  on('pasteFromClip', 'click', async () => {
    try { $('paste').value = await navigator.clipboard.readText(); } catch (e) { log('ERR', '读剪贴板失败: ' + e.message); }
  });
  on('toggle', 'click', () => (S.running ? stop() : start()));
  ['productId', 'showName', 'session', 'sku', 'bark', 'proxy'].forEach((id) => {
    on(id, 'input', (e) => {
      const map = { productId: 'productId', showName: 'showName', session: 'session',
        sku: 'sku', bark: 'barkKey', proxy: 'proxy' };
      S[map[id]] = e.target.value.trim(); save();
    });
  });
  ['count', 'threshold', 'interval'].forEach((id) => {
    on(id, 'input', (e) => { S[id] = parseFloat(e.target.value) || 1; save(); });
  });
  on('autoOpen', 'change', (e) => { S.autoOpen = e.target.checked; save(); });
  on('global', 'change', (e) => { S.globalWatch = e.target.checked; save(); });
}

load();
bind();
sync();
log('INFO', `PWA 就绪 · cookie ${Object.keys(S.cookies).length} 个 · 商品 ${S.productId || '-'}`);
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('./sw.js').catch(() => {});
}

/* 便于 Node 侧单测：浏览器里 module 未定义，不会执行 */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { S, state, parseAny, extractSkus, evaluate, deepLink, fetchSkus, COOLDOWN };
}
