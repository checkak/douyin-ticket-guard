const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..', 'pwa');
const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
const js = fs.readFileSync(path.join(dir, 'app.js'), 'utf8');

const open = (html.match(/<div\b/g) || []).length;
const close = (html.match(/<\/div>/g) || []).length;
console.log(`div  <${open}  </${close}  ${open === close ? 'balanced' : 'MISMATCH'}`);

const ids = [...html.matchAll(/id="([^"]+)"/g)].map((m) => m[1]);
console.log('html ids:', ids.join(', '));

const used = new Set();
for (const m of js.matchAll(/\$\('([^']+)'\)/g)) used.add(m[1]);
for (const m of js.matchAll(/getElementById\('([^']+)'\)/g)) used.add(m[1]);
const missing = [...used].filter((x) => !ids.includes(x));
console.log('app.js 引用的 id 不存在:', missing.length ? missing.join(', ') : '无');

const unused = ids.filter((x) => !used.has(x));
console.log('html 里没被 js 用到的 id:', unused.length ? unused.join(', ') : '无');
