#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/pepyledgerIOS.xcodeproj"
SCHEME="pepyledgerIOS"
BUNDLE_ID="com.pepyledger.ios"
DEVICE_NAME="${IOS_SIM_DEVICE:-iPhone 17}"
DERIVED_DATA_PATH="${IOS_DERIVED_DATA_PATH:-$ROOT_DIR/.build/ios-sim}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/pepyledgerIOS.app"

echo "[ios] booting simulator: $DEVICE_NAME"
xcrun simctl boot "$DEVICE_NAME" >/dev/null 2>&1 || true

echo "[ios] building app (derived data: $DERIVED_DATA_PATH)"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app not found at $APP_PATH"
  exit 1
fi

echo "[ios] reinstalling app: $BUNDLE_ID"
xcrun simctl uninstall booted "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install booted "$APP_PATH"

echo "[ios] launching app"
xcrun simctl launch booted "$BUNDLE_ID"

