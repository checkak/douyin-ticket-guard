"""GitHub 设备码授权 + 自动建仓库 + 推送 + 触发 Actions + 盯构建。

为什么不用浏览器 Cookie：Chrome 136+ 用 App-Bound Encryption 加密 cookie，
复制 profile 后无法解密（实测数据库被清空），且默认 profile 禁用了 remote debugging。
设备码授权是唯一「零输入、只需点两下」的路径。

用法：
    python tools/gh_device_login.py --repo douyin-ticket-guard
    python tools/gh_device_login.py --repo xxx --watch      # 推送后盯 Actions
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse as up
import urllib.request

CLIENT_ID = "178c6fc778ccc68e1d6a"          # GitHub CLI 的公开 OAuth client id
SCOPE = "repo workflow"
UA = "dtg-push/1.0"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN_FILE = os.path.join(ROOT, ".gh_token")
GIT = r"E:\DATA\Pojia\tools\mingit\cmd\git.exe"


def api(method: str, path: str, token: str | None = None, body: dict | None = None,
        base: str = "https://api.github.com", raw: bool = False):
    url = base + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", UA)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            text = r.read().decode("utf-8", "ignore")
            return r.status, (text if raw else (json.loads(text) if text else {}))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore")[:400]


def device_flow() -> str:
    """返回 access_token。期间会在控制台打印用户需要点的两个东西。"""
    st, body = api("POST", "/login/device/code",
                   body={"client_id": CLIENT_ID, "scope": SCOPE},
                   base="https://github.com")
    if st != 200 or "device_code" not in body:
        print("设备码申请失败:", st, body)
        sys.exit(1)

    dc = body["device_code"]
    code = body["user_code"]
    verify = body["verification_uri"]
    interval = int(body.get("interval", 5)) + 1
    expires = int(body.get("expires_in", 900))

    short = verify.replace("https://github.com/login/device", "")
    print("=" * 62)
    print(" 请在浏览器里完成授权（你的账号已登录，点两下即可）")
    print(f" 地址： {verify}?user_code={up.quote(code)}")
    print(f" 代码： {code}")
    print(f" 有效期 {expires // 60} 分钟")
    print("=" * 62, flush=True)

    end = time.time() + expires
    while time.time() < end:
        time.sleep(interval)
        st, body = api("POST", "/login/oauth/access_token",
                       body={"client_id": CLIENT_ID, "device_code": dc,
                             "grant_type": "urn:ietf:params:oauth:grant-type:device_code"},
                       base="https://github.com")
        if st == 200 and body.get("access_token"):
            tok = body["access_token"]
            with open(TOKEN_FILE, "w", encoding="utf-8") as f:
                f.write(tok)
            try:
                os.chmod(TOKEN_FILE, 0o600)
            except OSError:
                pass
            print("✅ 授权成功，token 已保存到", TOKEN_FILE, flush=True)
            return tok
        err = body.get("error") if isinstance(body, dict) else str(body)
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval += 5
            continue
        print("授权流失败:", err, body if isinstance(body, dict) else "")
        sys.exit(1)
    print("设备码过期")
    sys.exit(1)


def load_token() -> str | None:
    if os.path.exists(TOKEN_FILE):
        t = open(TOKEN_FILE, encoding="utf-8").read().strip()
        if t:
            return t
    return None


def git(*args: str, cwd: str = ROOT, check: bool = True) -> subprocess.CompletedProcess:
    p = subprocess.run([GIT, *args], cwd=cwd, capture_output=True, text=True)
    if check and p.returncode != 0:
        print("git", " ".join(args), "失败:", (p.stderr or p.stdout).strip()[:500])
    return p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="douyin-ticket-guard")
    ap.add_argument("--private", action="store_true")
    ap.add_argument("--watch", action="store_true", help="推送后盯 Actions 直到结束")
    a = ap.parse_args()

    tok = load_token()
    if tok:
        st, me = api("GET", "/user", tok)
        if st == 200:
            print("复用已保存 token：", me.get("login"))
        else:
            print("旧 token 失效，重新授权")
            tok = None
    if not tok:
        tok = device_flow()

    st, me = api("GET", "/user", tok)
    if st != 200:
        print("取用户信息失败:", st, me)
        return 1
    login = me["login"]
    print("账号:", login, "| 已用额度仓库数:", me.get("total_private_repos"))

    st, repo = api("GET", f"/repos/{login}/{a.repo}", tok)
    if st == 200:
        print("仓库已存在:", repo["html_url"])
    else:
        st, repo = api("POST", "/user/repos", tok, {
            "name": a.repo,
            "description": "抖音演出票档监控（视频复刻）+ iOS SwiftUI + PWA",
            "private": bool(a.private),
            "has_issues": False, "has_wiki": False, "auto_init": False,
        })
        if st not in (200, 201):
            print("建仓库失败:", st, repo)
            return 1
        print("已创建仓库:", repo["html_url"])

    remote = f"https://x-access-token:{tok}@github.com/{login}/{a.repo}.git"
    git("remote", "remove", "origin", check=False)
    git("remote", "add", "origin", remote)
    p = git("push", "-u", "origin", "main")
    if p.returncode != 0:
        return 1
    print("✅ 已推送:", p.stdout.strip().splitlines()[-1] if p.stdout.strip() else "")
    # 把带 token 的 URL 换成普通 URL，避免明文躺在 .git/config 里
    git("remote", "set-url", "origin", f"https://github.com/{login}/{a.repo}.git")

    if a.watch:
        watch_actions(tok, login, a.repo)
    else:
        print("触发构建：https://github.com/%s/%s/actions" % (login, a.repo))
    return 0


def watch_actions(tok: str, login: str, repo: str, limit_min: int = 25) -> None:
    print("\n触发 workflow_dispatch ...")
    st, body = api("POST", f"/repos/{login}/{repo}/actions/workflows/ios-ipa.yml/dispatches",
                   tok, {"ref": "main"})
    print("  dispatch:", st, "" if st in (201, 204) else body)

    end = time.time() + limit_min * 60
    seen = None
    while time.time() < end:
        time.sleep(10)
        st, runs = api("GET", f"/repos/{login}/{repo}/actions/runs?per_page=3", tok)
        if st != 200 or not isinstance(runs, dict):
            print("查 runs 失败:", st, runs)
            continue
        items = runs.get("workflow_runs", [])
        if not items:
            print("  等 run 出现...")
            continue
        run = items[0]
        rid = run["id"]
        if seen != rid:
            seen = rid
            print(f"  run #{run['run_number']} id={rid} status={run['status']}")
        if run["status"] == "completed":
            print("  结论:", run["conclusion"], run["html_url"])
            if run["conclusion"] == "success":
                st, arts = api("GET", f"/repos/{login}/{repo}/actions/runs/{rid}/artifacts", tok)
                for art in arts.get("artifacts", []):
                    print("  产物:", art["name"], f"{art['size_in_bytes'] / 1024:.0f} KB",
                          art["archive_download_url"])
                print("\n下载命令（需要 token）：")
                print(f'  curl -L -H "Authorization: Bearer <TOKEN>" '
                      f'-o ipa.zip "{arts["artifacts"][0]["archive_download_url"]}"')
            else:
                jobs(st, tok, login, repo, rid)
            return
        print(f"  ...{run['status']}")
    print("超时未完成，去 Actions 页面看")


def jobs(st: int, tok: str, login: str, repo: str, rid: int) -> None:
    st, data = api("GET", f"/repos/{login}/{repo}/actions/runs/{rid}/jobs", tok)
    for j in data.get("jobs", []):
        print(f"  job {j['name']}: {j['conclusion']}")
        for s in j.get("steps", []):
            if s.get("conclusion") not in (None, "success"):
                print(f"    失败步骤: {s['name']} → {s['conclusion']}")


if __name__ == "__main__":
    raise SystemExit(main())
