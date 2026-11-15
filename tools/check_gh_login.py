import sys, time, json
sys.path.insert(0, 'tools')
from cdp import CDP

c = CDP(9333, url='https://github.com')
time.sleep(4)

print('url      :', c.js('location.href'))
print('title    :', c.js('document.title'))
meta = c.js("(document.querySelector('meta[name=\"user-login\"]')||{}).content || ''")
print('user-login:', meta or '(未登录)')
csrf = c.js("(document.querySelector('meta[name=\"csrf-token\"]')||{}).content || ''")
print('csrf     :', (csrf[:16] + '...') if csrf else '(无)')
cookies = c.cookies()
print('cookies  :', len(cookies), '个')
print('关键 cookie:', [x['name'] for x in cookies if x['name'] in
      ('user_session', 'logged_in', '_gh_sess', 'dotcom_user', 'gh_sess')])
c.close()
