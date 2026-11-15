"""通知通道：Bark 推送 / 本地铃响 / 深链拉起抖音。

视频里的行为（1:18）在这里一一对应：
  - 通知卡标题「发现库存」+ 正文「【11.28】演出名｜看台780 有票168张（阈值1）」
  - Bark 的「时效性」= level=timeSensitive
  - 铃响「永远执行」，跳转可选
"""
from __future__ import annotations

import os
import platform
import subprocess
import sys
import time
import urllib.parse as up

import requests


# ---------------------------------------------------------------- Bark
def bark(device_key: str, title: str, body: str, *, url: str | None = None,
         group: str = "抢票监控", sound: str = "alarm", level: str = "timeSensitive",
         server: str = "https://api.day.app", timeout: float = 5.0) -> tuple[bool, str]:
    if not device_key:
        return False, "no device_key"
    payload = {"title": title, "body": body, "group": group, "sound": sound,
               "level": level, "autoCopy": "1", "icon": ""}
    if url:
        payload["url"] = url
    endpoint = f"{server.rstrip('/')}/{device_key}"
    try:
        r = requests.post(endpoint, json=payload, timeout=timeout)
        return r.status_code == 200, f"{r.status_code} {r.text[:120]}"
    except Exception as e:                                    # noqa: BLE001
        return False, f"{type(e).__name__}: {e}"


# ---------------------------------------------------------------- 铃响
def ring(times: int = 3, freq: int = 1400, dur: int = 350) -> str:
    """响铃以便人不看屏幕也能被叫起来。平台差异全在这里吸收。"""
    try:
        if platform.system() == "Windows":
            import winsound
            for _ in range(times):
                winsound.Beep(freq, dur)
            return "winsound.Beep x%d" % times
        if platform.system() == "Darwin":
            for _ in range(times):
                subprocess.Popen(["afplay", "/System/Library/Sounds/Sosumi.aiff"]).wait()
            return "afplay x%d" % times
        # Linux / Termux
        for _ in range(times):
            sys.stdout.write("\a")
            sys.stdout.flush()
            time.sleep(dur / 1000)
        return "bell x%d" % times
    except Exception as e:                                    # noqa: BLE001
        return f"ring-failed: {type(e).__name__}: {e}"


# ---------------------------------------------------------------- 深链
def open_url(url: str) -> str:
    """用系统默认处理器打开深链；返回实际动作，便于日志留痕。"""
    if not url:
        return "no-url"
    try:
        if platform.system() == "Windows":
            os.startfile(url)                                 # type: ignore[attr-defined]
            return "startfile"
        if platform.system() == "Darwin":
            subprocess.Popen(["open", url])
            return "open"
        subprocess.Popen(["xdg-open", url])
        return "xdg-open"
    except Exception as e:                                    # noqa: BLE001
        return f"open-failed: {type(e).__name__}: {e}"


def adb_open(serial: str, url: str, package: str = "com.ss.android.ugc.aweme.lite") -> str:
    """安卓侧用 adb 拉起（比 shell open 可靠，可控停靠哪一个包）。"""
    try:
        subprocess.run(["adb", "-s", serial, "shell", "am", "start", "-n",
                        f"{package}/com.ss.android.ugc.aweme.main.MainActivity",
                        "-a", "android.intent.action.VIEW", "-d", url],
                       check=False, capture_output=True, timeout=10)
        return "adb am start"
    except Exception as e:                                    # noqa: BLE001
        return f"adb-failed: {type(e).__name__}: {e}"


def bark_full(device_key: str, title: str, body: str, *, url: str | None = None, **kw):
    """便捷：推送 + 铃响（视频里「Bark推送 + 铃响永远执行」）。"""
    ok, info = bark(device_key, title, body, url=url, **kw)
    r = ring()
    return ok, info, r


def encode(s: str) -> str:
    return up.quote(s, safe="")
