#!/usr/bin/env bash
# 在 macOS 上产出 .ipa。默认「未签名」——Windows 端用 Sideloadly / AltStore 重签即可。
#
#   ./build_ipa.sh                # 未签名 ipa
#   TEAM_ID=ABCDE12345 ./build_ipa.sh signed   # 有证书时打开发签名 ipa
#
set -euo pipefail
cd "$(dirname "$0")"

SCHEME="DouyinTicketGuard"
MODE="${1:-unsigned}"
BUILD_DIR="build"
OUT_IPA="${SCHEME}-${MODE}.ipa"

echo "==> 1/5 检查工具链"
command -v xcodebuild >/dev/null || { echo "缺 xcodebuild，请先装 Xcode"; exit 1; }
if [ ! -d "${SCHEME}.xcodeproj" ]; then
  command -v xcodegen >/dev/null || { echo "缺 xcodegen：brew install xcodegen"; exit 1; }
  echo "==> 2/5 xcodegen 生成工程"
  xcodegen generate
else
  echo "==> 2/5 已有工程，跳过生成"
fi

echo "==> 3/5 编译（Release / iphoneos）"
if [ "$MODE" = "signed" ]; then
  : "${TEAM_ID:?signed 模式需要 TEAM_ID=你的团队ID}"
  xcodebuild -project "${SCHEME}.xcodeproj" -scheme "$SCHEME" \
    -configuration Release -sdk iphoneos -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    build
else
  xcodebuild -project "${SCHEME}.xcodeproj" -scheme "$SCHEME" \
    -configuration Release -sdk iphoneos -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build
fi

APP="${BUILD_DIR}/Build/Products/Release-iphoneos/${SCHEME}.app"
[ -d "$APP" ] || { echo "没找到 $APP"; exit 1; }

echo "==> 4/5 组装 Payload/"
rm -rf Payload "$OUT_IPA"
mkdir -p Payload
cp -R "$APP" Payload/

if [ "$MODE" = "signed" ]; then
  echo "    签名校验："
  codesign -dv --verbose=2 "Payload/${SCHEME}.app" 2>&1 | head -5 || true
fi

echo "==> 5/5 打包 $OUT_IPA"
zip -qry "$OUT_IPA" Payload
rm -rf Payload
ls -lh "$OUT_IPA"
echo "完成：$(pwd)/${OUT_IPA}"
echo
echo "安装（Windows）：Sideloadly 选这个 ipa + 你的 Apple ID → 装上后到"
echo "设置-通用-VPN与设备管理 里信任开发者证书。免费证书 7 天有效。"
