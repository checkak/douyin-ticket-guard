import sqlite3, shutil, os, sys

db = os.path.join(os.environ['TEMP'], 'cdp_prof', 'Default', 'Network', 'Cookies')
print('db:', db, os.path.getsize(db), 'bytes')
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute("select name from sqlite_master where type='table'")
print('tables:', [r[0] for r in cur.fetchall()])

try:
    cur.execute("select host_key, name, length(encrypted_value), length(value), expires_utc "
                "from cookies where host_key like '%github%' order by name")
    rows = cur.fetchall()
    print(f'github cookies: {len(rows)} 行')
    for h, n, el, vl, exp in rows:
        cur2 = con.execute("select hex(encrypted_value) from cookies where host_key=? and name=?", (h, n))
        hexv = cur2.fetchone()[0] or ''
        prefix = bytes.fromhex(hexv[:6]).decode('ascii', 'replace') if hexv else '-'
        print(f'  {h:24s} {n:28s} enc={el:4d}B plain={vl}B prefix={prefix}')
except Exception as e:
    print('query err:', e)

# 看看 v20 / v10 分布
cur.execute("select substr(hex(encrypted_value),1,6) p, count(*) from cookies group by p")
print('前缀分布:', cur.fetchall())
con.close()
