"""下载 Git for Windows 的 MinGit 便携包（不安装、不写注册表），解压后直接可用。

输出：E:\\DATA\\Pojia\\tools\\mingit\\cmd\\git.exe
"""
import io
import json
import os
import sys
import urllib.request
import zipfile

DEST_ROOT = os.path.join("E:\\", "DATA", "Pojia", "tools")
DEST = os.path.join(DEST_ROOT, "mingit")


def get(url: str, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "dtg-setup/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


MIRRORS = [
    "https://registry.npmmirror.com/-/binary/git-for-windows/{tag}/{name}",
    "https://mirrors.tuna.tsinghua.edu.cn/github-release/git-for-windows/git/LatestRelease/{name}",
    "https://github.com/git-for-windows/git/releases/download/{tag}/{name}",
]


def main() -> int:
    os.makedirs(DEST_ROOT, exist_ok=True)
    print("查询最新 release ...")
    rel = json.loads(get("https://api.github.com/repos/git-for-windows/git/releases/latest"))
    tag = rel["tag_name"]
    print("最新版本:", tag)

    asset = None
    for a in rel["assets"]:
        n = a["name"]
        if n.startswith("MinGit-") and "64-bit" in n and n.endswith(".zip") and "busybox" not in n:
            asset = a
            break
    if not asset:
        print("没找到 MinGit 压缩包，资产列表：")
        for a in rel["assets"][:12]:
            print("  -", a["name"])
        return 1

    name = asset["name"]
    print(f"目标: {name} ({asset['size']/1e6:.1f} MB)")
    blob = None
    for tpl in MIRRORS:
        url = tpl.format(tag=tag, name=name)
        try:
            print("尝试:", url)
            blob = get(url, timeout=180)
            if len(blob) > 5_000_000:
                print("下载成功", len(blob), "bytes")
                break
            print("  体积异常:", len(blob))
            blob = None
        except Exception as e:                               # noqa: BLE001
            print("  失败:", type(e).__name__, str(e)[:100])
    if blob is None:
        print("所有源都失败")
        return 1

    os.makedirs(DEST, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        z.extractall(DEST)

    git = os.path.join(DEST, "cmd", "git.exe")
    print("git.exe:", git, "exists:", os.path.exists(git))
    if os.path.exists(git):
        import subprocess
        out = subprocess.run([git, "--version"], capture_output=True, text=True)
        print("版本:", out.stdout.strip() or out.stderr.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
