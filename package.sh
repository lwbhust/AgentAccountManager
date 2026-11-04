#!/usr/bin/env bash
# 打包为标准 macOS .app Bundle
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AgentAccountManager"
WIDGET_NAME="AgentAccountManagerWidget"
BUILD_DIR=".build"
APP_DIR="dist"
APP_BUNDLE="$APP_DIR/$APP_NAME.app"
WIDGET_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$WIDGET_NAME.appex"
WIDGET_ENTITLEMENTS="assets/Widget.entitlements"

echo "==> Release 构建..."
swift build -c release

echo "==> 清理旧包..."
rm -rf "$APP_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "==> 复制二进制..."
cp "$BUILD_DIR/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> 复制图标资源..."
cp "assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> 复制背景资源..."
for bg in starlight aurora dawn nebula forest rainy coast; do
  cp "assets/backgrounds/$bg.jpg" "$APP_BUNDLE/Contents/Resources/Background-$bg.jpg"
done

echo "==> 复制 WidgetKit 扩展..."
mkdir -p "$WIDGET_BUNDLE/Contents/MacOS"
mkdir -p "$WIDGET_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/release/$WIDGET_NAME" "$WIDGET_BUNDLE/Contents/MacOS/$WIDGET_NAME"

cat > "$WIDGET_BUNDLE/Contents/Info.plist" <<WIDGET_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$WIDGET_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.agentaccountmanager.app.widget</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Agent 快速切换</string>
    <key>CFBundleDisplayName</key>
    <string>Agent 快速切换</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
WIDGET_PLIST

echo "==> 写入 Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.agentaccountmanager.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Agent 账号管理器</string>
    <key>CFBundleDisplayName</key>
    <string>Agent 账号管理器</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Agent Account Manager</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.agentaccountmanager.app</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>agentaccountmanager</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc 签名..."
if [ -f "$WIDGET_ENTITLEMENTS" ]; then
    codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET_BUNDLE" 2>/dev/null \
        || echo "（Widget 签名跳过，可在已签名环境中重新签名）"
fi
# 先签扩展、再签外层 App，保留扩展的沙盒与只读文件权限。
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || echo "（签名跳过，可在已签名环境中重新签名）"

echo "==> 打包完成: $APP_BUNDLE"

# ===== 可选安装（./package.sh --install）=====
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    *)
      echo "未知参数: $arg"
      echo "用法: ./package.sh [--install]"
      exit 1
      ;;
  esac
done

if $INSTALL; then
  echo "==> 安装到应用程序目录..."

  if [ -w /Applications ]; then
    INSTALL_DIR="/Applications"
  else
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    echo "    /Applications 不可写，改安装到 $INSTALL_DIR"
  fi
  TARGET="$INSTALL_DIR/$APP_NAME.app"

  if pgrep -f "$TARGET/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "    应用正在运行，请先退出后重试"
    exit 1
  fi

  rm -rf "$TARGET"
  ditto "$APP_BUNDLE" "$TARGET"
  xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

  echo "==> 注册到 LaunchServices..."
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREGISTER" -f "$TARGET"
  pluginkit -a "$TARGET/Contents/PlugIns/$WIDGET_NAME.appex" 2>/dev/null || true

  echo "==> 清理 dist 副本（避免 Spotlight 出现两个同名应用）..."
  "$LSREGISTER" -u "$APP_BUNDLE" 2>/dev/null || true
  rm -rf "$APP_BUNDLE"

  echo "==> 刷新 Dock / 应用程序列表..."
  killall Dock 2>/dev/null || true
  killall iconservicesagent 2>/dev/null || true

  echo "==> 安装完成: $TARGET"
  echo "    如仍显示旧图标，执行: sudo rm -rf /Library/Caches/com.apple.iconservices.store && sudo killall iconservicesagent Finder Dock"
fi
