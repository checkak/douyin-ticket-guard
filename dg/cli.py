"""命令行入口。

典型用法（对齐视频操作顺序）：
  # 1) 把 ProxyPin 抓到的 cURL / HAR 存成 sn.bin，然后
  python -m dg sniff sn.bin --save cookies.json
  # 2) 用商品ID 拉一次票档，确认能拿到库存
  python -m dg dump 1877446712185876 --cookies cookies.json
  # 3) 建任务（等价于 0:44「加入监控」）
  python -m dg add --product-id 1877446712185876 --session "2026-11-28 19:30" \
      --sku "看台 680" --count 2 --threshold 1 --bark KEY
  # 4) 开跑（等价于 1:17「监听并触发监控已启动」）
  python -m dg run
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from . import deeplink
from .api import TicketClient, dump_schema
from .engine import Monitor, Task
from .parse import sniff


def _read_text(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    p = Path(path)
    if p.exists() and p.is_file():
        return p.read_text(encoding="utf-8", errors="ignore")
    # 直接粘一段文本/链接也给过（省得先存文件）
    if any(t in path for t in ("http", "curl", "Cookie", "cookie", "=")):
        return path
    raise SystemExit(f"文件不存在: {path}（想直接粘文本就加 - 走 stdin）")


def _load_cookies(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    p = Path(path)
    if not p.exists():
        return {}
    return json.loads(p.read_text(encoding="utf-8"))


def cmd_sniff(a) -> int:
    text = _read_text(a.file)
    s = sniff(text)
    # 分享短链（v.douyin.com/xxx）不含 product_id，需要展开跳转链
    if getattr(a, "resolve", True) and not s.product_id and s.url.startswith("http"):
        from .parse import resolve_short_link
        final, hops = resolve_short_link(s.url, proxy=getattr(a, "proxy", None))
        print("短链展开:")
        for h in hops:
            print("   ", h)
        if final != s.url:
            s2 = sniff(final)
            s2.cookies.update(s.cookies)
            s2.headers.update(s.headers)
            s = s2
    print(s.summary())
    for n in s.notes:
        print("  note:", n)
    auth = sorted(k for k in s.cookies if k in
                  ("sessionid", "sessionid_ss", "sid_guard", "sid_tt", "uid_tt", "d_ticket"))
    print("  认证相关 cookie:", ", ".join(auth) or "（无，可能抓的不是已登录请求）")
    if s.url:
        print("  url:", s.url[:160] + ("…" if len(s.url) > 160 else ""))
    if a.save and s.cookies:
        Path(a.save).write_text(json.dumps(s.cookies, ensure_ascii=False, indent=2), encoding="utf-8")
        hp = Path(a.save).with_name("headers.json")
        hp.write_text(json.dumps(s.headers, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  已保存 {a.save} 与 {hp.name}")
    return 0 if s.cookies else 2


def cmd_dump(a) -> int:
    cookies = _load_cookies(a.cookies)
    if not cookies:
        print("缺少 cookies：先跑 sniff 生成 cookies.json")
        return 2
    if getattr(a, "api_base", None):
        import dg.api as api_mod
        api_mod.API_HOST = a.api_base.rstrip("/")
    cli = TicketClient(cookies, proxy=a.proxy)
    snap = cli.get_show_sku_info(a.product_id)
    print(f"product={a.product_id} 解析到 {len(snap.skus)} 个票档")
    for s in snap.skus:
        print("  -", s)
    out = Path(a.out or "schema.json")
    dump_schema(snap.raw, str(out))
    print(f"原始 JSON → {out}（schema 若与默认键名不同，用这个文件改 api.STOCK_KEYS）")
    return 0


def cmd_add(a) -> int:
    m = Monitor(_load_cookies(a.cookies)).load()
    t = Task(product_id=a.product_id, name=a.name or "", session=a.session or "",
             sku=a.sku or "", price=a.price, count=a.count, threshold=a.threshold,
             interval=a.interval, task_delay=a.task_delay, auto_open=not a.no_open,
             auto_order=a.auto_order, global_watch=a.global_watch, schedule_at=a.at or "",
             link_kind=a.link_kind, enabled=not getattr(a, "disabled", False))
    m.add(t)
    print(f"已加入监控 id={t.id}  {t.title}  阈值={t.threshold}  自动打开={t.auto_open}")
    return 0


def cmd_list(a) -> int:
    m = Monitor({}).load()
    if not m.tasks:
        print("暂无监控任务")
        return 0
    for i, t in enumerate(m.tasks, 1):
        print(f"{i}. id={t.id} enabled={t.enabled} {t.title} "
              f"阈值={t.threshold} 间隔={t.interval}s 延迟={t.task_delay}s "
              f"自动打开={t.auto_open} 全局={t.global_watch} 定时={t.schedule_at or '-'}")
    return 0


def cmd_rm(a) -> int:
    m = Monitor({}).load()
    print("已删除" if m.remove(a.id) else "没找到该 id")
    return 0


def cmd_run(a) -> int:
    cookies = _load_cookies(a.cookies)
    if not cookies:
        print("缺少 cookies：先跑 sniff 生成 cookies.json")
        return 2
    m = Monitor(cookies, bark_key=a.bark or "", proxy=a.proxy, dry_run=a.dry_run,
                api_base=a.api_base).load()
    if not m.tasks:
        print("暂无监控任务：先 add")
        return 2
    m.start()
    deadline = time.time() + a.seconds if a.seconds else None
    try:
        while any(t.is_alive() for t in m._threads):        # noqa: SLF001
            if deadline and time.time() > deadline:
                m.stop()
                break
            time.sleep(0.3)
    except KeyboardInterrupt:
        m.stop()
    print(f"日志: {m.log.path}")
    return 0


def cmd_probe(a) -> int:
    rows = deeplink.candidates(a.product_id, session=a.session or "", sku=a.sku or "", count=a.count)
    print("候选深链（逐个在手机上试，哪个落到确认订单页就把 link_kind 写进任务）：")
    for name, url in rows:
        print(f"  {name:22s} {url[:120]}")
    if a.open:
        from .notify import open_url
        name, url = rows[0]
        print("拉起:", name, open_url(url))
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser("dg", description="抖音演出票档监控 / 抢票工具")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sniff", help="解析 cURL / HAR / 订单链接 / 分享短链")
    s.add_argument("file", help="文件路径，- 表示 stdin，也可直接粘文本")
    s.add_argument("--save", help="cookies 输出路径，如 cookies.json")
    s.add_argument("--no-resolve", dest="resolve", action="store_false",
                   help="不展开分享短链（默认会展开）")
    s.add_argument("--proxy", help="展开短链时走代理，如 http://127.0.0.1:8080")
    s.set_defaults(func=cmd_sniff)

    d = sub.add_parser("dump", help="拉一次票档并保存原始 JSON")
    d.add_argument("product_id")
    d.add_argument("--cookies", default="cookies.json")
    d.add_argument("--proxy")
    d.add_argument("--out")
    d.add_argument("--api-base", help="自测时指向 mock server")
    d.set_defaults(func=cmd_dump)

    ad = sub.add_parser("add", help="加入监控任务")
    ad.add_argument("--product-id", required=True)
    ad.add_argument("--name", default="")
    ad.add_argument("--session", default="")
    ad.add_argument("--sku", default="")
    ad.add_argument("--price", type=float, default=0.0)
    ad.add_argument("--count", type=int, default=1)
    ad.add_argument("--threshold", type=int, default=1)
    ad.add_argument("--interval", type=float, default=1.0)
    ad.add_argument("--task-delay", type=float, default=5.0)
    ad.add_argument("--no-open", action="store_true", help="仅通知，不跳转")
    ad.add_argument("--auto-order", action="store_true")
    ad.add_argument("--global-watch", action="store_true")
    ad.add_argument("--at", help="定时启动 HH:MM")
    ad.add_argument("--link-kind", default="universal",
                    choices=["universal", "webview", "show", "order"])
    ad.add_argument("--cookies", default="cookies.json")
    ad.add_argument("--disabled", action="store_true", help="先入库不启动（等凭据）")
    ad.set_defaults(func=cmd_add)

    l = sub.add_parser("list", help="列出任务")
    l.set_defaults(func=cmd_list)

    r = sub.add_parser("rm", help="删除任务")
    r.add_argument("id")
    r.set_defaults(func=cmd_rm)

    rn = sub.add_parser("run", help="开始监控")
    rn.add_argument("--cookies", default="cookies.json")
    rn.add_argument("--bark", default="", help="Bark device key")
    rn.add_argument("--proxy")
    rn.add_argument("--dry-run", action="store_true")
    rn.add_argument("--seconds", type=float, default=0, help="跑 N 秒后退出（自测用）")
    rn.add_argument("--api-base", help="自测时指向 mock server")
    rn.set_defaults(func=cmd_run)

    pr = sub.add_parser("probe", help="生成候选深链并可选拉起")
    pr.add_argument("product_id")
    pr.add_argument("--session", default="")
    pr.add_argument("--sku", default="")
    pr.add_argument("--count", type=int, default=1)
    pr.add_argument("--open", action="store_true")
    pr.set_defaults(func=cmd_probe)

    a = p.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    raise SystemExit(main())
