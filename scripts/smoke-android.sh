#!/bin/bash
# smoke-android.sh - Run the glTF viewer smoke test on Android
# Usage: ./smoke-android.sh [install|run|logs|screenshot|rotation]
#   install: Build and install APK (default)
#   run: Launch the app
#   logs: Show app logs
#   screenshot: Take a screenshot
#   rotation: Test orientation changes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Configuration
ANDROID_HOME="${ANDROID_HOME:-/home/autark/android/sdk}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/home/autark/android/android-ndk-r27c}"
ADB="${ADB:-/mnt/c/Users/requi/Downloads/platform-tools/adb.exe}"
PKG="com.threez.gltfviewer"
# Assets are now automatically staged by the build system to android-assets/

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
check_deps() {
    if [ ! -d "$ANDROID_HOME" ]; then
        log_error "ANDROID_HOME not found at $ANDROID_HOME"
        exit 1
    fi
    if [ ! -d "$ANDROID_NDK_HOME" ]; then
        log_error "ANDROID_NDK_HOME not found at $ANDROID_NDK_HOME"
        exit 1
    fi
    if ! command -v zig &> /dev/null; then
        log_error "zig not found in PATH"
        exit 1
    fi
    if [ ! -f "$ADB" ]; then
        log_error "adb not found at $ADB"
        exit 1
    fi
}

# Build APK
build_apk() {
    log_info "Building Android APK..."
    ANDROID_HOME="$ANDROID_HOME" \
    ANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
    zig build apk -Dtarget=aarch64-linux-android
    log_info "APK built successfully: zig-out/threez.apk"
}

# Install APK
install_apk() {
    log_info "Installing APK on device..."
    "$ADB" install -r zig-out/threez.apk
    log_info "APK installed successfully"
}

# Launch app
launch_app() {
    log_info "Launching app..."
    "$ADB" shell am force-stop "$PKG"
    "$ADB" shell monkey -p "$PKG" 1
    log_info "App launched"
}

# Show logs
show_logs() {
    log_info "Showing app logs (Ctrl+C to exit)..."
    "$ADB" logcat -v time -s threez:D threez.zig:D threez.js:D Dawn:W AndroidRuntime:E DEBUG:E
}

# Take screenshot
take_screenshot() {
    local screenshot_path="${1:-/tmp/threezig-android-smoke.png}"
    log_info "Taking screenshot to $screenshot_path..."
    "$ADB" exec-out screencap -p > "$screenshot_path"
    log_info "Screenshot saved to $screenshot_path"
}

# Test rotation
test_rotation() {
    log_info "Testing orientation changes..."
    local ACCEL=$("$ADB" shell settings get system accelerometer_rotation | tr -d '\r')
    local ROT=$("$ADB" shell settings get system user_rotation | tr -d '\r')

    "$ADB" logcat -c
    log_info "Forcing landscape..."
    "$ADB" shell settings put system accelerometer_rotation 0
    "$ADB" shell settings put system user_rotation 1
    sleep 3
    local PID1=$("$ADB" shell pidof "$PKG")
    log_info "App PID after landscape: $PID1"

    log_info "Forcing portrait..."
    "$ADB" shell settings put system user_rotation 0
    sleep 3
    local PID2=$("$ADB" shell pidof "$PKG")
    log_info "App PID after portrait: $PID2"

    # Restore settings
    if [ "$ACCEL" = "null" ]; then
        "$ADB" shell settings delete system accelerometer_rotation >/dev/null 2>&1 || true
    else
        "$ADB" shell settings put system accelerometer_rotation "$ACCEL"
    fi
    if [ "$ROT" = "null" ]; then
        "$ADB" shell settings delete system user_rotation >/dev/null 2>&1 || true
    else
        "$ADB" shell settings put system user_rotation "$ROT"
    fi

    log_info "Restored rotation settings"

    if [ -n "$PID1" ] && [ "$PID1" = "$PID2" ]; then
        log_info "✓ Rotation test passed (PID stayed consistent: $PID1)"
    else
        log_error "✗ Rotation test failed (PID changed: $PID1 -> $PID2)"
    fi

    log_info "App logs after rotation test:"
    "$ADB" logcat -d -v time -s threez:D threez.zig:D threez.js:D Dawn:W AndroidRuntime:E DEBUG:E
}

# Main command dispatcher
COMMAND="${1:-install}"

case "$COMMAND" in
    install)
        check_deps
        build_apk
        install_apk
        log_info "✓ Android smoke install complete"
        log_info "Run: $0 run    # to launch the app"
        log_info "Run: $0 logs   # to view logs"
        ;;
    run)
        launch_app
        ;;
    logs)
        show_logs
        ;;
    screenshot)
        take_screenshot "$2"
        ;;
    rotation)
        check_deps
        test_rotation
        ;;
    full)
        check_deps
        build_apk
        install_apk
        launch_app
        log_info "Waiting for app to start..."
        sleep 5
        take_screenshot "/tmp/threezig-android-smoke.png"
        log_info "✓ Full Android smoke complete"
        log_info "Screenshot saved to /tmp/threezig-android-smoke.png"
        log_info "Run: $0 logs to view logs"
        ;;
    *)
        echo "Usage: $0 [install|run|logs|screenshot|rotation|full]"
        echo ""
        echo "Commands:"
        echo "  install     Build and install APK (default)"
        echo "  run         Launch the app"
        echo "  logs        Show app logs"
        echo "  screenshot  Take a screenshot [path]"
        echo "  rotation    Test orientation changes"
        echo "  full        Run complete smoke test (install + run + screenshot)"
        exit 1
        ;;
esac