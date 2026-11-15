/* 在 Node 里把 PWA 的核心逻辑（解析 / 提取 / 跃迁判定）跑一遍，
 * 不需要浏览器：给 app.js 喂一套最小 DOM/Notification 桩，然后调用它导出的函数。
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const APP = path.join(__dirname, '..', 'pwa', 'app.js');
const src = fs.readFileSync(APP, 'utf8');

const stubEl = () => ({
  value: '', textContent: '', className: '', innerHTML: '',
  appendChild() {}, addEventListener() {}, scrollTop: 0, scrollHeight: 0,
});

const sandbox = {
  console,
  localStorage: { getItem: () => null, setItem: () => {} },
  navigator: { vibrate: () => {}, serviceWorker: { register: () => Promise.resolve() } },
  crypto: { randomUUID: () => 'uuid-0000' },
  Notification: function () {},
  fetch: async () => ({ status: 200, text: async () => '{}' }),
  document: {
    getElementById: () => stubEl(),
    createElement: () => stubEl(),
  },
  window: { location: { href: '' } },
  setTimeout: () => 0,
  clearTimeout: () => {},
  URLSearchParams, encodeURIComponent, decodeURIComponent,
  Date, Math, JSON, String, Number, Array, Object, Set,
  isNaN, parseFloat, parseInt,
  module: { exports: {} },
};
sandbox.Notification.permission = 'granted';
sandbox.Notification.requestPermission = () => Promise.resolve('granted');
sandbox.globalThis = sandbox;

const ctx = vm.createContext(sandbox);
vm.runInContext(src, ctx, { filename: 'app.js' });

const api = sandbox.module.exports;
const S = api.S;
const state = api.state;

let pass = 0;
let fail = 0;
function check(name, cond, extra) {
  if (cond) { pass += 1; console.log(`  [ok] ${name}`); }
  else { fail += 1; console.log(`  [FAIL] ${name}${extra !== undefined ? '  -> ' + extra : ''}`); }
}

console.log('\n[1] cURL 解析（视频 0:26 那条）');
const curl = fs.readFileSync(path.join(__dirname, '..', 'samples', 'curl_sniff.txt'), 'utf8');
const r1 = api.parseAny(curl);
check('kind = curl', r1.kind === 'curl', r1.kind);
check('cookie >= 9 个', Object.keys(r1.cookies).length >= 9, Object.keys(r1.cookies).length);
check('抓到 sessionid', !!r1.cookies.sessionid);
check('抓到 sid_guard', !!r1.cookies.sid_guard);
check('product_id 正确', r1.productId === '1877446712185876', r1.productId);

console.log('\n[2] 分享链接文本解析（薛之谦无锡站）');
const share = '7- 【11月27日】薛之谦“万兽之王”巡回演唱会-无锡站，戳链接得团购优惠 https://v.douyin.com/nQc94SXlb_Q/ 3@1.com :9pm';
const r2 = api.parseAny(share);
check('kind = link', r2.kind === 'link', r2.kind);
check('没有误抓成 cookie', Object.keys(r2.cookies).length === 0, Object.keys(r2.cookies).length);

console.log('\n[3] 真实落地页 URL（含 activity_id）解析');
const landed = 'https://life.scsjsd.com/falcon/poi_mwa/trade_detail?app=aweme&activity_id=1881078666742800&poi_id=7700588591658829887';
const r3 = api.parseAny(landed);
check('activity_id 当商品ID', r3.productId === '1881078666742800', r3.productId);

console.log('\n[4] 容错库存抽取（模拟 get_show_sku_info 响应）');
const payload = {
  status_code: 0,
  data: {
    show_info: { product_id: '1877446712185876', show_name: '张栋梁·佛山站' },
    sku_list: [
      { sku_id: '1', sku_name: '看台 480', price: 48000, stock_num: 0 },
      { sku_id: '2', sku_name: '看台 680', price: 68000, stock_num: 94 },
      { sku_id: '3', sku_name: '看台 780', price: 78000, stock_num: 168 },
      { sku_id: '4', sku_name: '内场 980', price: 98000, stock_num: 0 },
    ],
  },
};
const skus = api.extractSkus(payload);
check('抽到 4 个票档', skus.length === 4, skus.length);
check('780 档库存 168', skus.find((s) => s.name === '看台 780').stock === 168);
check('价格保持分为单位', skus.find((s) => s.name === '看台 780').price === 78000);

console.log('\n[5] 跃迁判定（0 -> 168 只触发一次；冷却期内不重复）');
S.sku = '看台 780';
S.threshold = 1;
S.autoOpen = false;
S.globalWatch = false;

const before = skus.find((s) => s.name === '看台 780');
const zeroState = skus.map((s) => ({ ...s, stock: s.name === '看台 780' ? 0 : s.stock }));
api.evaluate(zeroState);                       // 建立「上一轮无票」基线
const hits0 = state.logs.filter((l) => l.includes('HIT')).length;

api.evaluate(skus);                            // 0 -> 168，应命中
const hits1 = state.logs.filter((l) => l.includes('HIT')).length;

api.evaluate(skus);                            // 再轮询，冷却期内不应重复
const hits2 = state.logs.filter((l) => l.includes('HIT')).length;

check('跃迁时触发 1 次', hits1 === hits0 + 1, `${hits0} -> ${hits1}`);
check('去抖生效（第二轮不触发）', hits2 === hits1, `${hits1} -> ${hits2}`);
check('票档名解析正确', before.name === '看台 780', before.name);

console.log('\n[6] 深链构造');
const link = api.deepLink('看台 780');
check('含 product_id', link.includes('product_id='));
check('含 sku_name 与 buy_count', link.includes('sku_name=') && link.includes('buy_count='));
check('是 https Universal Link', link.startsWith('https://'));

console.log(`\n结果: ${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
