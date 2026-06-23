#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

MESA_PREFIX="${MESA_PREFIX:-/opt/mesa-git}"
SPIRV_PREFIX="${SPIRV_PREFIX:-/opt/spirv-tools}"
MESON_VENV="${MESON_VENV:-/opt/meson-venv}"
CHROMIUM_PROFILE="${CHROMIUM_PROFILE:-/tmp/chromium-vulkan-native}"
CHROMIUM_DEBUG_PORT="${CHROMIUM_DEBUG_PORT:-9222}"
CHROMIUM_WINDOW_SIZE="${CHROMIUM_WINDOW_SIZE:-3840,2160}"
CHROMIUM_URL="${CHROMIUM_URL:-chrome://gpu}"
DISPLAY_NUMBER="${DISPLAY_NUMBER:-0}"
DPI="${DPI:-96}"
MESA_TAG="${MESA_TAG:-mesa-25.3.6}"
SPIRV_TOOLS_TAG="${SPIRV_TOOLS_TAG:-v2024.1}"
SPIRV_HEADERS_TAG="${SPIRV_HEADERS_TAG:-vulkan-sdk-1.3.280.0}"
JOBS="${JOBS:-$(nproc 2>/dev/null || printf '4')}"
MESA_PREBUILT_URL="${MESA_PREBUILT_URL:-}"
MESA_PREBUILT_ARCHIVE="${MESA_PREBUILT_ARCHIVE:-}"
MODE="${MODE:-auto}"
SKIP_CHROMIUM_VERIFY="${SKIP_CHROMIUM_VERIFY:-0}"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Runs on the ROCK 5B itself after first boot. It installs Chromium with native
Vulkan/PanVK on a clean rooted ROCK 5B Bookworm CLI image, starts X on the local
display, opens chrome://gpu, and verifies that Chromium reports Vulkan as
enabled.

Default mode builds Mesa locally. If --mesa-archive or --mesa-url is provided,
the script installs that prebuilt Mesa archive instead.

Options:
  --build-mesa             Force local Mesa build.
  --mesa-archive PATH      Install Mesa from a local tar archive.
  --mesa-url URL           Download and install Mesa from a tar archive URL.
  --mesa-tag TAG           Mesa git tag for local build. Default: $MESA_TAG
  --jobs N                 Parallel build jobs. Default: nproc
  --skip-chromium-verify   Leave Chromium open even if DevTools verification is skipped.
  -h, --help               Show this help.

Environment:
  MESA_PREBUILT_URL        Same as --mesa-url.
  MESA_PREBUILT_ARCHIVE    Same as --mesa-archive.
  CHROMIUM_URL             URL to open. Default: chrome://gpu
  DISPLAY_NUMBER           X display number. Default: 0
  DPI                      X DPI. Default: 96

Minimal first boot flow:
  apt update
  apt install -y git ca-certificates
  git clone <this-repo-url> /root/radxa-images
  cd /root/radxa-images
  scripts/rock_5b/on_device/$SCRIPT_NAME
EOF
}

log() {
  printf '\n== %s ==\n' "$*"
}

info() {
  printf '[INFO] %s\n' "$*"
}

ok() {
  printf '[OK] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --build-mesa)
        MODE="build"
        shift
        ;;
      --mesa-archive)
        [ "${2:-}" != "" ] || die "--mesa-archive requires a value"
        MESA_PREBUILT_ARCHIVE="$2"
        MODE="prebuilt"
        shift 2
        ;;
      --mesa-url)
        [ "${2:-}" != "" ] || die "--mesa-url requires a value"
        MESA_PREBUILT_URL="$2"
        MODE="prebuilt"
        shift 2
        ;;
      --mesa-tag)
        [ "${2:-}" != "" ] || die "--mesa-tag requires a value"
        MESA_TAG="$2"
        shift 2
        ;;
      --jobs)
        [ "${2:-}" != "" ] || die "--jobs requires a value"
        JOBS="$2"
        shift 2
        ;;
      --skip-chromium-verify)
        SKIP_CHROMIUM_VERIFY=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  case "$MODE" in
    auto)
      if [ "$MESA_PREBUILT_ARCHIVE" != "" ] || [ "$MESA_PREBUILT_URL" != "" ]; then
        MODE="prebuilt"
      else
        MODE="build"
      fi
      ;;
    build | prebuilt)
      ;;
    *)
      die "Invalid MODE: $MODE"
      ;;
  esac
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root. On the ROCK 5B image use: sudo -i"
}

require_rock5b_shape() {
  local machine=""
  machine="$(uname -m)"
  [ "$machine" = "aarch64" ] || warn "Expected aarch64, got: $machine"

  if [ -r /proc/device-tree/compatible ]; then
    if tr '\0' '\n' </proc/device-tree/compatible | grep -Eiq 'radxa.*rock.*5b|rock-5b|rk3588'; then
      ok "Device tree looks like ROCK 5B/RK3588."
    else
      warn "Device tree does not obviously look like ROCK 5B/RK3588."
    fi
  fi
}

apt_update_once() {
  if [ "${APT_UPDATED:-0}" != "1" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    APT_UPDATED=1
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt_update_once
  apt install -y "$@"
}

apt_install_if_available() {
  local available=()
  local package

  apt_update_once
  for package in "$@"; do
    if apt-cache show "$package" >/dev/null 2>&1; then
      available+=("$package")
    else
      warn "Optional package not available: $package"
    fi
  done

  if [ "${#available[@]}" -gt 0 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt install -y "${available[@]}"
  fi
}

install_runtime_packages() {
  log "Install runtime packages"

  apt_update_once
  if dpkg -s luit >/dev/null 2>&1; then
    apt remove -y luit
  fi

  apt_install \
    ca-certificates curl git xz-utils zstd tar procps psmisc \
    chromium \
    python3 python3-websocket \
    vulkan-tools mesa-utils mesa-utils-bin mesa-vulkan-drivers \
    xinit xterm x11-xserver-utils dbus-x11 \
    libdrm2 libexpat1 libelf1 libzstd1 zlib1g libglvnd0 \
    libx11-6 libx11-xcb1 libxext6 libxfixes3 libxcb1 libxcb-dri2-0 libxcb-dri3-0 \
    libxcb-glx0 libxcb-present0 libxcb-randr0 libxcb-shm0 libxcb-keysyms1 \
    libxshmfence1 libxxf86vm1 libxrandr2 libwayland-client0 libwayland-server0
}

install_build_packages() {
  log "Install Mesa build dependencies"

  apt_install \
    build-essential ninja-build cmake pkg-config bison flex gettext gdb strace \
    python3-venv python3-mako python3-yaml python3-ply python3-pip \
    glslang-tools spirv-tools \
    libdrm-dev libexpat1-dev libelf-dev libzstd-dev zlib1g-dev libglvnd-dev \
    libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev \
    libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev libxcb-glx0-dev \
    libxcb-present-dev libxcb-randr0-dev libxcb-shm0-dev libxcb-keysyms1-dev \
    libxshmfence-dev libxxf86vm-dev libxrandr-dev \
    libwayland-dev wayland-protocols libwayland-egl-backend-dev \
    llvm-15 llvm-15-dev llvm-15-tools llvm-15-runtime \
    clang-15 libclang-15-dev libclang-cpp15-dev

  apt_install_if_available \
    meson llvm-dev clang libclang-dev libclang-cpp-dev \
    libclc-15-dev libclc-19-dev llvm-spirv-15 libllvmspirvlib-15-dev
}

configure_xwrapper() {
  log "Allow root to start Xorg"
  mkdir -p /etc/X11
  cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF
}

install_recent_meson() {
  log "Install recent Meson"
  rm -rf "$MESON_VENV"
  python3 -m venv "$MESON_VENV" --without-pip
  "$MESON_VENV/bin/python" -m ensurepip --upgrade
  "$MESON_VENV/bin/python" -m pip install --upgrade pip meson
  "$MESON_VENV/bin/python" -m mesonbuild.mesonmain --version
}

build_spirv_tools() {
  log "Build SPIRV-Tools $SPIRV_TOOLS_TAG"

  cd /root
  rm -rf SPIRV-Tools SPIRV-Headers
  git clone --depth=1 --branch "$SPIRV_TOOLS_TAG" https://github.com/KhronosGroup/SPIRV-Tools.git SPIRV-Tools
  git clone --depth=1 --branch "$SPIRV_HEADERS_TAG" https://github.com/KhronosGroup/SPIRV-Headers.git SPIRV-Headers
  rm -rf /root/SPIRV-Tools/external/spirv-headers
  ln -s /root/SPIRV-Headers /root/SPIRV-Tools/external/spirv-headers

  cmake -S /root/SPIRV-Tools -B /root/SPIRV-Tools/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SPIRV_PREFIX" \
    -DSPIRV_SKIP_TESTS=ON \
    -DSPIRV_WERROR=OFF
  cmake --build /root/SPIRV-Tools/build -j"$JOBS"
  cmake --install /root/SPIRV-Tools/build
  PKG_CONFIG_PATH="$SPIRV_PREFIX/lib/pkgconfig" pkg-config --modversion SPIRV-Tools
}

build_mesa() {
  log "Build Mesa $MESA_TAG with PanVK"

  cd /root
  rm -rf mesa-git
  git clone --depth=1 https://gitlab.freedesktop.org/mesa/mesa.git mesa-git
  cd /root/mesa-git
  git fetch --depth=1 origin tag "$MESA_TAG"
  git checkout -f "$MESA_TAG"
  git describe --tags --always
  rm -rf build

  PKG_CONFIG_PATH="$SPIRV_PREFIX/lib/pkgconfig" \
  LLVM_CONFIG=/usr/bin/llvm-config-15 \
  "$MESON_VENV/bin/python" -m mesonbuild.mesonmain setup build \
    --prefix="$MESA_PREFIX" \
    --libdir=lib/aarch64-linux-gnu \
    -Dbuildtype=release \
    -Dplatforms=x11,wayland \
    -Dgallium-drivers=panfrost \
    -Dvulkan-drivers=panfrost \
    -Dllvm=enabled \
    -Dgallium-rusticl=false \
    -Dmicrosoft-clc=disabled \
    -Dglx=dri \
    -Degl=enabled \
    -Dgles1=disabled \
    -Dgles2=enabled \
    -Dopengl=true \
    -Dgbm=enabled \
    -Dvideo-codecs=""
  ninja -C build -j"$JOBS"
  ninja -C build install
}

install_prebuilt_mesa() {
  local archive="$MESA_PREBUILT_ARCHIVE"

  log "Install prebuilt Mesa"

  if [ "$archive" = "" ]; then
    [ "$MESA_PREBUILT_URL" != "" ] || die "Set MESA_PREBUILT_URL or pass --mesa-url/--mesa-archive."
    archive="/tmp/rock5b-mesa-prebuilt.tar.zst"
    curl -L --fail --retry 3 -o "$archive" "$MESA_PREBUILT_URL"
  fi

  [ -f "$archive" ] || die "Mesa archive not found: $archive"

  rm -rf /tmp/mesa-prebuilt-extract
  mkdir -p /tmp/mesa-prebuilt-extract
  case "$archive" in
    *.tar.zst | *.tzst) tar --zstd -xf "$archive" -C /tmp/mesa-prebuilt-extract ;;
    *.tar.xz) tar -xJf "$archive" -C /tmp/mesa-prebuilt-extract ;;
    *.tar.gz | *.tgz) tar -xzf "$archive" -C /tmp/mesa-prebuilt-extract ;;
    *.tar) tar -xf "$archive" -C /tmp/mesa-prebuilt-extract ;;
    *) die "Unsupported archive type: $archive" ;;
  esac

  rm -rf "$MESA_PREFIX"
  if [ -d /tmp/mesa-prebuilt-extract/opt/mesa-git ]; then
    mkdir -p /opt
    cp -a /tmp/mesa-prebuilt-extract/opt/mesa-git "$MESA_PREFIX"
  elif [ -d /tmp/mesa-prebuilt-extract/mesa-git ]; then
    mkdir -p /opt
    cp -a /tmp/mesa-prebuilt-extract/mesa-git "$MESA_PREFIX"
  elif [ -f /tmp/mesa-prebuilt-extract/lib/aarch64-linux-gnu/libvulkan_panfrost.so ]; then
    mkdir -p "$MESA_PREFIX"
    cp -a /tmp/mesa-prebuilt-extract/. "$MESA_PREFIX/"
  else
    find /tmp/mesa-prebuilt-extract -maxdepth 3 -type f | head -80 >&2
    die "Archive does not look like a Mesa /opt/mesa-git prebuilt."
  fi

  if [ -d /tmp/mesa-prebuilt-extract/opt/spirv-tools ]; then
    rm -rf "$SPIRV_PREFIX"
    mkdir -p /opt
    cp -a /tmp/mesa-prebuilt-extract/opt/spirv-tools "$SPIRV_PREFIX"
  elif [ -d /tmp/mesa-prebuilt-extract/spirv-tools ]; then
    rm -rf "$SPIRV_PREFIX"
    mkdir -p /opt
    cp -a /tmp/mesa-prebuilt-extract/spirv-tools "$SPIRV_PREFIX"
  fi
}

install_chromium_helpers() {
  log "Install Chromium Vulkan helper commands"

  cat >/usr/local/bin/run-chromium-vulkan <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export MESA_OPT="${MESA_OPT:-/opt/mesa-git}"
export LD_LIBRARY_PATH="/usr/lib/chromium:/usr/lib/chromium/lib:$MESA_OPT/lib/aarch64-linux-gnu:/opt/spirv-tools/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$MESA_OPT/lib/aarch64-linux-gnu/dri"
export VK_ICD_FILENAMES="$MESA_OPT/share/vulkan/icd.d/panfrost_icd.aarch64.json"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

if [ -x /usr/lib/chromium/chromium-bin ]; then
  CHROMIUM_BIN=/usr/lib/chromium/chromium-bin
elif [ -x /usr/lib/chromium/chromium ]; then
  CHROMIUM_BIN=/usr/lib/chromium/chromium
elif command -v chromium >/dev/null 2>&1; then
  CHROMIUM_BIN="$(command -v chromium)"
else
  echo "ERROR: Chromium binary not found. Install it with: apt install -y chromium" >&2
  exit 127
fi

echo "Using Chromium binary: $CHROMIUM_BIN" >&2

exec "$CHROMIUM_BIN" \
  --no-sandbox \
  --user-data-dir="${CHROMIUM_PROFILE:-/tmp/chromium-vulkan-native}" \
  --no-first-run \
  --no-default-browser-check \
  --ozone-platform=x11 \
  --enable-gpu \
  --ignore-gpu-blocklist \
  --disable-gpu-driver-bug-workarounds \
  --enable-gpu-rasterization \
  --enable-features=Vulkan,UseSkiaRenderer,CanvasOopRasterization \
  --use-vulkan=native \
  --enable-logging=stderr \
  --v=1 \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="${CHROMIUM_DEBUG_PORT:-9222}" \
  --remote-allow-origins="*" \
  --disable-background-networking \
  --disable-sync \
  --disable-component-update \
  --disable-domain-reliability \
  --disable-client-side-phishing-detection \
  --metrics-recording-only \
  --window-position=0,0 \
  --window-size="${CHROMIUM_WINDOW_SIZE:-3840,2160}" \
  --start-maximized \
  "${CHROMIUM_URL:-chrome://gpu}"
EOF

  cat >/usr/local/bin/start-chromium-vulkan <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DISPLAY_NUMBER="${DISPLAY_NUMBER:-0}"
DPI="${DPI:-96}"
LOG_FILE="${LOG_FILE:-/tmp/chromium-vulkan-startx.log}"

pkill -f chromium-bin 2>/dev/null || true
pkill -f /usr/lib/chromium/chromium 2>/dev/null || true
pkill -x chromium 2>/dev/null || true
pkill -x Xorg 2>/dev/null || true
sleep 3

rm -f "/tmp/.X${DISPLAY_NUMBER}-lock" "/tmp/.X11-unix/X${DISPLAY_NUMBER}"
rm -rf /tmp/runtime-root
mkdir -p /tmp/runtime-root
chmod 700 /tmp/runtime-root

nohup env -u __EGL_VENDOR_LIBRARY_FILENAMES \
  DISPLAY_NUMBER="$DISPLAY_NUMBER" \
  DPI="$DPI" \
  CHROMIUM_PROFILE="${CHROMIUM_PROFILE:-/tmp/chromium-vulkan-native}" \
  CHROMIUM_DEBUG_PORT="${CHROMIUM_DEBUG_PORT:-9222}" \
  CHROMIUM_WINDOW_SIZE="${CHROMIUM_WINDOW_SIZE:-3840,2160}" \
  CHROMIUM_URL="${CHROMIUM_URL:-chrome://gpu}" \
  startx /usr/local/bin/run-chromium-vulkan -- ":${DISPLAY_NUMBER}" -dpi "$DPI" \
  >"$LOG_FILE" 2>&1 &

sleep 12
ps aux | grep -E 'Xorg|chromium|chromium-bin' | grep -v grep || true
echo "Log: $LOG_FILE"
EOF

  cat >/usr/local/bin/stop-chromium-vulkan <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DISPLAY_NUMBER="${DISPLAY_NUMBER:-0}"

pkill -f chromium-bin 2>/dev/null || true
pkill -f /usr/lib/chromium/chromium 2>/dev/null || true
pkill -x chromium 2>/dev/null || true
pkill -x Xorg 2>/dev/null || true
sleep 2
rm -f "/tmp/.X${DISPLAY_NUMBER}-lock" "/tmp/.X11-unix/X${DISPLAY_NUMBER}"
EOF

  cat >/usr/local/bin/verify-chromium-vulkan <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${CHROMIUM_DEBUG_PORT:-9222}"

python3 - <<PY
import json
import time
import urllib.request
import itertools
import websocket

port = int("${PORT}")

def http_json(url):
    with urllib.request.urlopen(url, timeout=8) as response:
        return json.loads(response.read().decode())

deadline = time.time() + 45
last_exc = None
while time.time() < deadline:
    try:
        pages = http_json(f"http://127.0.0.1:{port}/json/list")
        break
    except Exception as exc:
        last_exc = exc
        time.sleep(1)
else:
    raise SystemExit(f"ERROR: Chromium DevTools did not answer on port {port}: {last_exc}")

page = next((p for p in pages if p.get("type") == "page"), None)
if not page:
    raise SystemExit("ERROR: No Chromium page target found.")

ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=8)
ids = itertools.count(1)

def call(method, params=None):
    message_id = next(ids)
    ws.send(json.dumps({"id": message_id, "method": method, "params": params or {}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == message_id:
            return msg

call("Page.enable")
call("Page.navigate", {"url": "chrome://gpu"})
time.sleep(5)
res = call("Runtime.evaluate", {
    "expression": "JSON.stringify(browserBridge.gpuInfo_)",
    "returnByValue": True,
})
raw = res.get("result", {}).get("result", {}).get("value")
if not raw:
    print(json.dumps(res, indent=2)[:4000])
    raise SystemExit("ERROR: Could not read browserBridge.gpuInfo_ from chrome://gpu.")

info = json.loads(raw)
open("/tmp/chrome-gpu-info-direct.json", "w").write(json.dumps(info, indent=2))
feature_status = info.get("featureStatus", {}).get("featureStatus", {})

print("saved=/tmp/chrome-gpu-info-direct.json")
for key in [
    "vulkan",
    "gpu_compositing",
    "rasterization",
    "opengl",
    "webgl",
    "webgl2",
    "canvas_oop_rasterization",
    "multiple_raster_threads",
]:
    print(f"{key}: {feature_status.get(key)}")

for item in info.get("basicInfo", []):
    desc = str(item.get("description", ""))
    value = str(item.get("value", "")).replace("\\n", " ")
    if desc in {
        "Skia Backend",
        "GPU0",
        "GL implementation parts",
        "Display type",
        "GL_VENDOR",
        "GL_RENDERER",
        "GL_VERSION",
    }:
        print(f"{desc}: {value[:900]}")

if feature_status.get("vulkan") != "enabled_on":
    raise SystemExit("ERROR: chrome://gpu does not report vulkan: enabled_on")
PY
EOF

  chmod +x \
    /usr/local/bin/run-chromium-vulkan \
    /usr/local/bin/start-chromium-vulkan \
    /usr/local/bin/stop-chromium-vulkan \
    /usr/local/bin/verify-chromium-vulkan
}

verify_mesa_files() {
  log "Verify Mesa Vulkan files"
  [ -f "$MESA_PREFIX/lib/aarch64-linux-gnu/libvulkan_panfrost.so" ] || die "Missing libvulkan_panfrost.so in $MESA_PREFIX"
  [ -f "$MESA_PREFIX/share/vulkan/icd.d/panfrost_icd.aarch64.json" ] || die "Missing panfrost ICD JSON in $MESA_PREFIX"
}

verify_vulkaninfo() {
  log "Verify Vulkan outside Chromium"
  env \
    MESA_OPT="$MESA_PREFIX" \
    LD_LIBRARY_PATH="$MESA_PREFIX/lib/aarch64-linux-gnu:$SPIRV_PREFIX/lib" \
    LIBGL_DRIVERS_PATH="$MESA_PREFIX/lib/aarch64-linux-gnu/dri" \
    VK_ICD_FILENAMES="$MESA_PREFIX/share/vulkan/icd.d/panfrost_icd.aarch64.json" \
    vulkaninfo --summary
}

start_and_verify_chromium() {
  log "Start Chromium on display :$DISPLAY_NUMBER"
  DISPLAY_NUMBER="$DISPLAY_NUMBER" \
    DPI="$DPI" \
    CHROMIUM_PROFILE="$CHROMIUM_PROFILE" \
    CHROMIUM_DEBUG_PORT="$CHROMIUM_DEBUG_PORT" \
    CHROMIUM_WINDOW_SIZE="$CHROMIUM_WINDOW_SIZE" \
    CHROMIUM_URL="$CHROMIUM_URL" \
    start-chromium-vulkan

  if [ "$SKIP_CHROMIUM_VERIFY" = "1" ]; then
    warn "Skipping Chromium DevTools verification."
    return 0
  fi

  log "Verify Chromium reports Vulkan enabled"
  CHROMIUM_DEBUG_PORT="$CHROMIUM_DEBUG_PORT" verify-chromium-vulkan
}

main() {
  parse_args "$@"
  require_root
  require_rock5b_shape

  log "Selected Mesa mode: $MODE"
  install_runtime_packages
  configure_xwrapper

  if [ "$MODE" = "prebuilt" ]; then
    install_prebuilt_mesa
  else
    install_build_packages
    install_recent_meson
    build_spirv_tools
    build_mesa
  fi

  install_chromium_helpers
  verify_mesa_files
  verify_vulkaninfo
  start_and_verify_chromium

  log "Done"
  ok "Chromium should now be open on the local display at chrome://gpu."
  ok "Useful commands: start-chromium-vulkan, stop-chromium-vulkan, verify-chromium-vulkan"
}

main "$@"
