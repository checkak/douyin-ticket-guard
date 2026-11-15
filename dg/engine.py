"""监控引擎：把「演出×场次×票档×阈值」变成可并发的轮询任务。

对应视频 1:08–1:17 的监控中心：
  当前监控任务 / 启用 / 阈值 / 自动下单 / 任务延迟(秒) / 全局监控 / 定时 / 实时日志
状态跃迁去抖：只有「上一轮无票 → 这一轮 >= 阈值」才触发，避免每轮都响铃。
"""
from __future__ import annotations

import json
import os
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable

from . import deeplink, notify
from .api import Snapshot, Sku, TicketClient

ROOT = Path(__file__).resolve().parent.parent
STATE_FILE = ROOT / "tasks.json"
LOG_DIR = ROOT / "logs"
REFIRE_COOLDOWN = float(os.environ.get("DG_REFIRE_COOLDOWN", "20"))  # 同票档两次触发最小间隔（秒）


# ------------------------------------------------------------------ 任务模型
@dataclass
class Task:
    product_id: str
    name: str = ""
    session: str = ""            # 2026-11-28 19:30
    sku: str = ""                # 看台 780
    price: float = 0.0
    count: int = 1               # 购票人数
    threshold: int = 1           # 阈值：剩余 >= threshold 才推
    interval: float = 1.0        # 轮询间隔（秒）
    task_delay: float = 5.0      # 「任务延迟(秒)」= 任务间错峰
    auto_open: bool = True       # 「通知并自动打开抖音」
    auto_order: bool = False     # 「自动下单」
    global_watch: bool = False   # 「全局监控」= 盯整场所有票档
    enabled: bool = True
    schedule_at: str = ""        # 「定时」HH:MM 或 HH:MM:SS
    link_kind: str = "universal"
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])

    @property
    def title(self) -> str:
        parts = [self.name or self.product_id]
        if self.session:
            parts.append(self.session)
        if self.sku:
            parts.append(self.sku)
        return " | ".join(parts)


@dataclass
class Event:
    task_id: str
    title: str
    sku: str
    stock: int
    threshold: int
    ts: float
    link: str = ""

    def body(self) -> str:
        sess = ""
        for part in self.title.split("|"):
            p = part.strip()
            if p[:4].isdigit():
                sess = p
                break
        prefix = f"【{sess[5:10]}】" if sess else ""
        return f"{prefix}{self.title}｜{self.sku} 有票{self.stock}张（阈值{self.threshold}）通知打开抖音"


# ------------------------------------------------------------------ 日志
class Logger:
    def __init__(self, name: str = "monitor.log"):
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.path = LOG_DIR / name
        self._lock = threading.Lock()

    def write(self, level: str, msg: str) -> str:
        line = f"[{datetime.now():%H:%M:%S}] {level} {msg}"
        with self._lock:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        return line


# ------------------------------------------------------------------ 引擎
class Monitor:
    def __init__(self, cookies: dict[str, str], *, bark_key: str = "",
                 proxy: str | None = None, on_event: Callable[[Event], None] | None = None,
                 dry_run: bool = False, sign_hook=None, api_base: str | None = None):
        self.cookies = cookies
        self.bark_key = bark_key
        self.proxy = proxy
        self.on_event = on_event
        self.dry_run = dry_run
        self.sign_hook = sign_hook
        self.api_base = api_base
        self.log = Logger()
        self.tasks: list[Task] = []
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._state: dict[str, dict] = {}      # task_id -> {sku_name: last_stock}
        self._last_fire: dict[str, float] = {}

    # ---------------- 任务持久化 ----------------
    def load(self) -> "Monitor":
        if STATE_FILE.exists():
            raw = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            self.tasks = [Task(**t) for t in raw.get("tasks", [])]
        return self

    def save(self) -> None:
        STATE_FILE.write_text(json.dumps({"tasks": [asdict(t) for t in self.tasks]},
                                         ensure_ascii=False, indent=2), encoding="utf-8")

    def add(self, task: Task) -> Task:
        task.task_delay = task.task_delay or 5.0
        self.tasks.append(task)
        self.save()
        return task

    def remove(self, task_id: str) -> bool:
        before = len(self.tasks)
        self.tasks = [t for t in self.tasks if t.id != task_id]
        self.save()
        return len(self.tasks) < before

    # ---------------- 运行 ----------------
    def start(self) -> None:
        active = [t for t in self.tasks if t.enabled]
        if not active:
            self.log.write("WARN", "暂无监控任务")
            return
        self._stop.clear()
        for i, task in enumerate(active):
            th = threading.Thread(target=self._loop, args=(task, i * task.task_delay),
                                  name=f"task-{task.id}", daemon=True)
            th.start()
            self._threads.append(th)
            self.log.write("INFO", f"✅ 监听并触发监控已启动 {task.title} 阈值={task.threshold} 间隔={task.interval}s")

    def stop(self) -> None:
        self._stop.set()
        for t in self._threads:
            t.join(timeout=2)
        self._threads.clear()

    def run_forever(self) -> None:
        self.start()
        try:
            while any(t.is_alive() for t in self._threads):
                time.sleep(0.5)
        except KeyboardInterrupt:
            self.log.write("WARN", "收到中断，停止监控")
            self.stop()

    # ---------------- 单任务循环 ----------------
    def _loop(self, task: Task, initial_delay: float) -> None:
        if initial_delay:
            time.sleep(initial_delay)
        if task.schedule_at:
            self._wait_until(task.schedule_at)
        client = TicketClient(self.cookies, timeout=6.0, sign_hook=self.sign_hook, proxy=self.proxy)
        if self.api_base:
            import dg.api as api_mod
            api_mod.API_HOST = self.api_base.rstrip("/")
        self._state[task.id] = {}
        fail = 0
        while not self._stop.is_set():
            t0 = time.time()
            try:
                snap: Snapshot = client.get_show_sku_info(task.product_id)
                self._evaluate(task, snap)
                fail = 0
            except Exception as e:                            # noqa: BLE001
                fail += 1
                self.log.write("ERROR", f"{task.title} 拉库存失败({fail}): {type(e).__name__}: {e}")
                if fail in (3, 10):
                    self.log.write("WARN", f"{task.title} 连续失败{fail}次，退避 {min(fail, 30)}s")
                if fail >= 3:
                    time.sleep(min(fail, 30))
            # 固定节拍 + 抖动，避免被风控认出等间隔轮询
            jitter = (time.time() % 1) * 0.15
            sleep = max(0.2, task.interval + jitter - (time.time() - t0))
            self._stop.wait(sleep)

    def _wait_until(self, hhmm: str) -> None:
        try:
            today = datetime.now().strftime("%Y-%m-%d")
            fmt = "%Y-%m-%d %H:%M:%S" if hhmm.count(":") == 2 else "%Y-%m-%d %H:%M"
            target = datetime.strptime(f"{today} {hhmm}", fmt)
        except ValueError:
            self.log.write("WARN", f"定时格式无法识别: {hhmm}")
            return
        delta = (target - datetime.now()).total_seconds()
        if delta > 0:
            self.log.write("INFO", f"⏰ 定时等待 {delta:.0f}s → {hhmm}")
            self._stop.wait(delta)

    # ---------------- 判定 ----------------
    def _evaluate(self, task: Task, snap: Snapshot) -> None:
        """状态跃迁判定：
        首次观测到 >= 阈值 → 推（对应视频 1:12 启动、1:18 立刻收到 168 张通知）
        之后只有「上一轮 < 阈值 ≤ 这一轮」才再推，附 re-fire 冷却，避免每轮都响。
        """
        prev_map = self._state.setdefault(task.id, {})
        threshold = task.threshold
        now = time.time()

        watch: list[Sku]
        if task.global_watch:
            watch = list(snap.skus)
        else:
            target = snap.by_name(task.sku) if task.sku else None
            if target is None and task.price:
                target = snap.by_price(task.price)
            if target is None and snap.skus:
                target = snap.skus[0]
            watch = [target] if target else []

        hits: list[Sku] = []
        for s in watch:
            prev = prev_map.get(s.name)
            fire = False
            if s.stock >= threshold:
                if prev is None:                     # 首次观测即满足
                    fire = True
                elif prev < threshold:               # 由无到有
                    fire = True
            if fire and now - self._last_fire.get(f"{task.id}:{s.name}", 0) < REFIRE_COOLDOWN:
                fire = False
            if fire:
                hits.append(s)

        for s in snap.skus:
            prev_map[s.name] = s.stock

        if not hits:
            stock_txt = " / ".join(f"{s.name}:{s.stock}" for s in (watch or snap.skus)[:8]) or "空"
            # 只在库存文本变化时落日志，避免 0.5s 轮询把日志刷爆
            last_txt = self._state.setdefault("__log__", {}).get(task.id)
            if last_txt != stock_txt:
                self._state["__log__"][task.id] = stock_txt
                self.log.write("DEBUG", f"{task.title} → {stock_txt}")
            return

        for s in hits:
            self._last_fire[f"{task.id}:{s.name}"] = now
            link = deeplink.build(task.link_kind, task.product_id, session=task.session,
                                  sku=s.name, count=task.count)
            ev = Event(task_id=task.id, title=task.title, sku=s.name, stock=s.stock,
                       threshold=task.threshold, ts=now, link=link)
            self.log.write("HIT", ev.body())
            self._fire(ev, task)

    def _fire(self, ev: Event, task: Task) -> None:
        if self.dry_run:
            self.log.write("INFO", f"[dry-run] 跳过推送/跳转 {ev.link}")
        else:
            ok, info, ring_info = notify.bark_full(
                self.bark_key, "发现库存", ev.body(), url=ev.link)
            self.log.write("PUSH" if ok else "WARN", f"bark={info} ring={ring_info}")
            if task.auto_open:
                how = notify.open_url(ev.link)
                self.log.write("INFO", f"唤起抖音: {how} {ev.link}")
            if task.auto_order:
                self.log.write("WARN", "自动下单需绑定下单链（见 README『自动下单』）")
        if self.on_event:
            self.on_event(ev)
