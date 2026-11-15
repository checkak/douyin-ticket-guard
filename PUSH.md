# 推送到 GitHub → 让 CI 出 ipa

本机已装好 **便携版 git**（`E:\DATA\Pojia\tools\mingit\cmd\git.exe`，2.56.1，不写注册表），
仓库已 init + 首次 commit 完成（39 个文件），只差一个 remote 和一次 push。

---

## 第 1 步：在 GitHub 建一个空仓库

浏览器打开 <https://github.com/new>：

- **Repository name**：`douyin-ticket-guard`（随意）
- **Public / Private**：建议 **Public**
  （私有仓库的 Actions 走 macOS runner 会 **×10 计费**：8 分钟构建 ≈ 80 分钟额度，免费额度 2000 分钟/月；公开仓库免费无限）
- **不要**勾 "Add a README" / ".gitignore" / "license"（否则和本地 commit 冲突）

---

## 第 2 步：生成一个 PAT（推送用密码）

<https://github.com/settings/tokens> → **Generate new token (classic)**

- 勾 `repo`（私有仓库必需；公开仓库也要，push 需要写权限）
- 有效期选 30 天
- 复制生成的 `ghp_xxx`（只显示一次）

> 用 Fine-grained token 也行：选目标仓库 → `Contents: Read and write`。

---

## 第 3 步：推送（在你自己的 PowerShell 里跑）

```powershell
$env:PATH = "E:\DATA\Pojia\tools\mingit\cmd;" + $env:PATH
cd E:\DATA\Pojia\douyin_ticket_guard

git remote add origin https://github.com/<你的账号>/douyin-ticket-guard.git
git push -u origin main
```

提示输入凭据时：

- `Username`：你的 GitHub 用户名
- `Password`：粘贴 **PAT**（不是账号密码，GitHub 早已停用密码推送）

成功会看到 `main -> main` 和 `Branch 'main' set up to track 'origin/main'`。

---

## 第 4 步：跑流水线

1. 仓库页 → **Actions** 标签
2. 左侧选 **Build unsigned IPA** → 右侧 **Run workflow** → **Run workflow**
3. 等 6~10 分钟（首次装 xcodegen 会慢一点）
4. 进这次 run → 页面底部 **Artifacts**：
   - `DouyinTicketGuard-ipa` ← 这里面是 **`DouyinTicketGuard-unsigned.ipa`** + `ipa.sha256`
   - `build-log` ← 编译日志（失败时先看这个）

---

## 第 5 步：装到 iPhone（Windows）

1. 下载并安装 [Sideloadly](https://sideloadly.io/)
2. iPhone 用数据线连电脑
3. Sideloadly 里：`IPA` 选刚下载的 `DouyinTicketGuard-unsigned.ipa`，
   `Apple ID` 填你的（免费账号即可）→ **Start**
4. 手机上：**设置 → 通用 → VPN与设备管理 → 信任** 你的证书
5. **设置 → 隐私与安全性 → 开发者模式 → 打开**，重启一次
6. 桌面上就有了，打开填 Bark Key 就能用

免费证书 **7 天**有效，到期用 Sideloadly 重签一次（App 数据会保留）。

---

## 如果 push 失败

| 报错 | 处理 |
|---|---|
| `Authentication failed` | 密码位置贴的是 PAT；PAT 需要 `repo` 权限 |
| `remote origin already exists` | `git remote set-url origin https://github.com/<账号>/<仓库>.git` |
| `failed to push some refs` / `fetch first` | 远程仓库建的时候勾了 README → `git pull --rebase origin main` 后再 push |
| `REPOSITORY_NOT_FOUND` | 仓库名/账号拼错，或 PAT 没有该仓库权限 |
| 想换成 SSH | 先把 SSH 公钥加到 GitHub，再 `git remote set-url origin git@github.com:<账号>/<仓库>.git` |

## 如果不想用 git（零工具包方案）

GitHub 网页也能直接上传整个目录：仓库页 → **Add file → Upload files** →
把 `E:\DATA\Pojia\douyin_ticket_guard` 里**所有文件/文件夹**（含 `.github`，要开启显示隐藏文件夹）
拖进浏览器 → Commit。`.github/workflows/ios-ipa.yml` 上传后 Actions 就有了。

> 注意：网页上传**不会**解压 zip，必须拖文件夹本身。

## 改了代码之后

```powershell
$env:PATH = "E:\DATA\Pojia\tools\mingit\cmd;" + $env:PATH
cd E:\DATA\Pojia\douyin_ticket_guard
git add -A
git commit -m "fix: ..."
git push
```

push 到 `main` 且改动命中 `ios/**` 或 workflow 文件时会自动触发构建（不必手动点 Run workflow）。
