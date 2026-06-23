#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RSDK_DIR_ARG=""
RSDK_DIR=""
DRY_RUN=0
CHECK_ONLY=0

PRODUCTS_REL="src/share/rsdk/configs/products.json"
SOC_RECOMMENDS_REL="src/share/rsdk/configs/soc_install_recommends.libjsonnet"
CLI_PACKAGES_REL="src/share/rsdk/build/mod/packages/cli.libjsonnet"
BUILD_HELPER_NAME="build-rock5b-bookworm-cli.sh"
DEFAULT_ROOT_HELPER_NAME="set-rock5b-default-root.sh"
DEFAULT_ROOT_HELPER_SOURCE="$SCRIPT_DIR/rock5b_bookworm_default_root.sh"

PRODUCTS_JSON=""
PRODUCTS_BACKUP=""
SOC_RECOMMENDS=""
CLI_PACKAGES=""
BUILD_HELPER=""
DEFAULT_ROOT_HELPER=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Patches an existing host-side RSDK checkout for a ROCK 5B Bookworm CLI build.

Options:
  --rsdk-dir DIR          RSDK checkout directory. Default: current directory
                          when run from an RSDK checkout, then /workspaces/rsdk,
                          then ~/rsdk.
  --check-only            Verify the patch without changing files.
  --dry-run               Print what would change without changing files.
  -h, --help              Show this help.

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --check-only
  ./$SCRIPT_NAME --dry-run --rsdk-dir /tmp/rsdk-test
EOF
}

log() {
  printf '%s\n' "$*"
}

info() {
  log "[INFO] $*"
}

ok() {
  log "[OK] $*"
}

warn() {
  log "[WARN] $*" >&2
}

die() {
  log "[ERROR] $*" >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rsdk-dir)
        [ "${2:-}" != "" ] || die "--rsdk-dir requires a value"
        RSDK_DIR_ARG="$2"
        shift 2
        ;;
      --check-only)
        CHECK_ONLY=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
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

  if [ "$DRY_RUN" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ]; then
    die "--dry-run and --check-only cannot be used together"
  fi
}

expand_path() {
  local input="$1"

  case "$input" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${input#~/}"
      ;;
    /*)
      printf '%s\n' "$input"
      ;;
    *)
      printf '%s/%s\n' "$(pwd)" "$input"
      ;;
  esac
}

resolve_paths() {
  if [ "$RSDK_DIR_ARG" != "" ]; then
    RSDK_DIR="$(expand_path "$RSDK_DIR_ARG")"
  elif [ -f "$(pwd)/$PRODUCTS_REL" ] && [ -f "$(pwd)/$SOC_RECOMMENDS_REL" ]; then
    RSDK_DIR="$(pwd)"
  elif [ -f "/workspaces/rsdk/$PRODUCTS_REL" ] && [ -f "/workspaces/rsdk/$SOC_RECOMMENDS_REL" ]; then
    RSDK_DIR="/workspaces/rsdk"
  else
    RSDK_DIR="$HOME/rsdk"
  fi

  PRODUCTS_JSON="$RSDK_DIR/$PRODUCTS_REL"
  PRODUCTS_BACKUP="$PRODUCTS_JSON.bak"
  SOC_RECOMMENDS="$RSDK_DIR/$SOC_RECOMMENDS_REL"
  CLI_PACKAGES="$RSDK_DIR/$CLI_PACKAGES_REL"
  BUILD_HELPER="$RSDK_DIR/$BUILD_HELPER_NAME"
  DEFAULT_ROOT_HELPER="$RSDK_DIR/$DEFAULT_ROOT_HELPER_NAME"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

git_rsdk() {
  git -c "safe.directory=$RSDK_DIR" -C "$RSDK_DIR" "$@"
}

validate_rsdk_dir() {
  info "RSDK dir: $RSDK_DIR"

  [ -d "$RSDK_DIR" ] || die "RSDK directory does not exist: $RSDK_DIR"
  [ -f "$PRODUCTS_JSON" ] || die "Missing RSDK products config: $PRODUCTS_JSON"
  [ -f "$SOC_RECOMMENDS" ] || die "Missing RSDK Jsonnet config: $SOC_RECOMMENDS"
  [ -f "$CLI_PACKAGES" ] || die "Missing RSDK CLI package config: $CLI_PACKAGES"

  ok "RSDK checkout looks valid."
}

backup_products_once() {
  if [ -f "$PRODUCTS_BACKUP" ]; then
    ok "Backup already exists: $PRODUCTS_BACKUP"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Would create backup: $PRODUCTS_BACKUP"
    return 0
  fi

  cp "$PRODUCTS_JSON" "$PRODUCTS_BACKUP"
  ok "Created backup: $PRODUCTS_BACKUP"
}

patch_products_json() {
  local mode="$1"

  python3 - "$PRODUCTS_JSON" "$mode" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
mode = sys.argv[2]

try:
    original_text = path.read_text()
    data = json.loads(original_text)
except Exception as exc:
    print(f"[ERROR] Failed to read JSON from {path}: {exc}", file=sys.stderr)
    sys.exit(1)

matches = []

def walk(value):
    if isinstance(value, dict):
        if value.get("product") == "rock-5b":
            matches.append(value)
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(data)

if not matches:
    print('[ERROR] Could not find product object where "product" is "rock-5b".', file=sys.stderr)
    sys.exit(1)

if len(matches) > 1:
    print('[ERROR] Found multiple "rock-5b" product objects; refusing to guess.', file=sys.stderr)
    sys.exit(1)

product = matches[0]
editions = product.get("supported_edition")

if mode == "check":
    if not isinstance(editions, list):
        print('[ERROR] rock-5b supported_edition is missing or is not a JSON array.', file=sys.stderr)
        sys.exit(1)
    if "cli" not in editions:
        print('[ERROR] rock-5b supported_edition does not contain "cli".', file=sys.stderr)
        sys.exit(1)
    print('[OK] products.json contains "cli" in rock-5b supported_edition.')
    sys.exit(0)

changed = False

if "supported_edition" not in product:
    product["supported_edition"] = []
    changed = True

editions = product["supported_edition"]
if not isinstance(editions, list):
    print('[ERROR] rock-5b supported_edition exists but is not a JSON array.', file=sys.stderr)
    sys.exit(1)

cleaned_editions = []
seen_cli = False
for edition in editions:
    if edition == "cli":
        if seen_cli:
            changed = True
            continue
        seen_cli = True
    cleaned_editions.append(edition)

if not seen_cli:
    cleaned_editions.append("cli")
    changed = True

if cleaned_editions != editions:
    product["supported_edition"] = cleaned_editions
    changed = True

rendered = json.dumps(data, indent=4) + "\n"
format_changed = rendered != original_text

if mode == "dry-run":
    if changed:
        print('[INFO] Would patch products.json so rock-5b supports "cli".')
    else:
        print('[OK] products.json already has "cli" for rock-5b.')
    if format_changed:
        print('[INFO] Would write products.json as pretty JSON with indent=4.')
    print("[INFO] Resulting rock-5b product object:")
    print(json.dumps(product, indent=4))
    sys.exit(0)

if mode != "write":
    print(f"[ERROR] Unknown products.json mode: {mode}", file=sys.stderr)
    sys.exit(1)

tmp_path = path.with_name(path.name + ".tmp")
try:
    tmp_path.write_text(rendered)
    os.replace(tmp_path, path)
except Exception as exc:
    try:
        tmp_path.unlink()
    except FileNotFoundError:
        pass
    print(f"[ERROR] Failed to write patched products.json: {exc}", file=sys.stderr)
    sys.exit(1)

if changed:
    print('[OK] Patched products.json so rock-5b supports "cli".')
else:
    print('[OK] products.json already had "cli" for rock-5b.')
if format_changed:
    print('[OK] Wrote products.json as pretty JSON with indent=4.')
print("[INFO] Resulting rock-5b product object:")
print(json.dumps(product, indent=4))
PY
}

expected_soc_recommends() {
  cat <<'EOF'
local soc_family_list = import "soc_family_list.libjsonnet";

function(soc_array, suite)
  local check_recommends(soc) = (
    local family = soc_family_list(soc);

    std.objectHas(family, "soc_install_recommends") &&
    std.member(family.soc_install_recommends, suite)
  );

  std.length(std.filter(check_recommends, soc_array)) == std.length(soc_array)
EOF
}

patch_soc_recommends() {
  local expected
  expected="$(expected_soc_recommends)"

  if [ "$(<"$SOC_RECOMMENDS")" = "$expected" ]; then
    ok "soc_install_recommends.libjsonnet already matches the required patch."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Would replace: $SOC_RECOMMENDS"
    return 0
  fi

  printf '%s\n' "$expected" > "$SOC_RECOMMENDS"
  ok "Replaced soc_install_recommends.libjsonnet without std.all."
}

expected_cli_packages() {
  cat <<'EOF'
local base_packages = import "categories/base.libjsonnet";

function(suite,
         product,
         temp_dir,
         vendor_packages,
         linux_override,
         firmware_override,
) base_packages(suite,
                product,
                temp_dir,
                false,
                linux_override,
                firmware_override,
)
EOF
}

patch_cli_packages() {
  local expected
  expected="$(expected_cli_packages)"

  if [ "$(<"$CLI_PACKAGES")" = "$expected" ]; then
    ok "cli.libjsonnet already forces --no-install-recommends for CLI builds."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Would replace: $CLI_PACKAGES"
    return 0
  fi

  printf '%s\n' "$expected" > "$CLI_PACKAGES"
  ok "Patched cli.libjsonnet so CLI builds skip vendor package recommends."
}

expected_build_helper() {
  cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

cd /workspaces/rsdk

export PATH="/usr/sbin:/sbin:/workspaces/rsdk/src/bin:/workspaces/rsdk/node_modules/.bin:$PATH"

echo "Installing required container dependencies..."
sudo apt update
sudo apt install -y \
  jsonnet \
  bdebstrap \
  mmdebstrap \
  debian-archive-keyring \
  qemu-user-static \
  binfmt-support \
  jq \
  rsync \
  file \
  xz-utils \
  zstd \
  pigz \
  parted \
  fdisk \
  gdisk \
  dosfstools \
  e2fsprogs \
  libguestfs-tools \
  ca-certificates \
  curl

echo "Verifying required tools..."
for tool in rsdk jsonnet bdebstrap mmdebstrap guestfish sgdisk parted mkfs.vfat mkfs.ext4; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
  command -v "$tool"
done

OUT="out/rock-5b_bookworm_cli"

if [ -d "$OUT" ]; then
  echo "Output directory already exists: $OUT"
  echo "Type DELETE to remove it and rebuild:"
  read -r answer
  if [ "$answer" != "DELETE" ]; then
    echo "Aborted."
    exit 1
  fi
  rm -rf "$OUT"
fi

echo "Building ROCK 5B Bookworm CLI image..."
rsdk build rock-5b bookworm cli

if [ ! -f "$OUT/output.img" ]; then
  echo "Build finished but output image was not found: $OUT/output.img" >&2
  exit 1
fi

echo
echo "Build output:"
ls -lh "$OUT"
ls -lh "$OUT/output.img"

echo
echo "Done."
echo "Image:"
echo "  /workspaces/rsdk/$OUT/output.img"
EOF
}

patch_build_helper() {
  local expected
  expected="$(expected_build_helper)"

  if [ -f "$BUILD_HELPER" ] && [ "$(<"$BUILD_HELPER")" = "$expected" ] && [ -x "$BUILD_HELPER" ]; then
    ok "Build helper already exists and is executable: $BUILD_HELPER"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$BUILD_HELPER" ]; then
      info "Would update build helper: $BUILD_HELPER"
    else
      info "Would create build helper: $BUILD_HELPER"
    fi
    info "Would chmod +x: $BUILD_HELPER"
    return 0
  fi

  printf '%s\n' "$expected" > "$BUILD_HELPER"
  chmod +x "$BUILD_HELPER"
  ok "Created executable build helper: $BUILD_HELPER"
}

patch_default_root_helper() {
  if [ ! -f "$DEFAULT_ROOT_HELPER_SOURCE" ]; then
    die "Default-root helper source is missing: $DEFAULT_ROOT_HELPER_SOURCE"
  fi

  if [ -f "$DEFAULT_ROOT_HELPER" ] &&
    cmp -s "$DEFAULT_ROOT_HELPER_SOURCE" "$DEFAULT_ROOT_HELPER" &&
    [ -x "$DEFAULT_ROOT_HELPER" ]; then
    ok "Default-root helper already exists and is executable: $DEFAULT_ROOT_HELPER"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$DEFAULT_ROOT_HELPER" ]; then
      info "Would update default-root helper: $DEFAULT_ROOT_HELPER"
    else
      info "Would create default-root helper: $DEFAULT_ROOT_HELPER"
    fi
    info "Would chmod +x: $DEFAULT_ROOT_HELPER"
    return 0
  fi

  cp "$DEFAULT_ROOT_HELPER_SOURCE" "$DEFAULT_ROOT_HELPER"
  chmod +x "$DEFAULT_ROOT_HELPER"
  ok "Created executable default-root helper: $DEFAULT_ROOT_HELPER"
}

check_soc_recommends() {
  if grep -q 'std\.all' "$SOC_RECOMMENDS"; then
    die "soc_install_recommends.libjsonnet still contains std.all: $SOC_RECOMMENDS"
  fi

  ok "soc_install_recommends.libjsonnet does not contain std.all."
}

check_cli_packages() {
  local expected
  expected="$(expected_cli_packages)"

  if [ "$(<"$CLI_PACKAGES")" != "$expected" ]; then
    die "cli.libjsonnet does not force --no-install-recommends for CLI builds: $CLI_PACKAGES"
  fi

  ok "cli.libjsonnet forces --no-install-recommends for CLI builds."
}

check_build_helper() {
  [ -f "$BUILD_HELPER" ] || die "Build helper is missing: $BUILD_HELPER"
  [ -x "$BUILD_HELPER" ] || die "Build helper exists but is not executable: $BUILD_HELPER"

  ok "Build helper exists and is executable: $BUILD_HELPER"
}

check_default_root_helper() {
  [ -f "$DEFAULT_ROOT_HELPER" ] || die "Default-root helper is missing: $DEFAULT_ROOT_HELPER"
  [ -x "$DEFAULT_ROOT_HELPER" ] || die "Default-root helper exists but is not executable: $DEFAULT_ROOT_HELPER"

  ok "Default-root helper exists and is executable: $DEFAULT_ROOT_HELPER"
}

run_check_only() {
  info "Check-only mode: no files will be changed."
  patch_products_json check
  check_soc_recommends
  check_cli_packages
  check_build_helper
  check_default_root_helper
  ok "RSDK patch check passed."
}

print_git_diff() {
  info "Git diff for patched RSDK files:"

  if ! command -v git >/dev/null 2>&1; then
    warn "git is not available; cannot print diff."
    return 0
  fi

  if ! git_rsdk rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "RSDK directory is not a git work tree; cannot print diff."
    return 0
  fi

  if git_rsdk diff --quiet -- "$PRODUCTS_REL" "$SOC_RECOMMENDS_REL" "$CLI_PACKAGES_REL"; then
    ok "No git diff for patched RSDK config files."
    return 0
  fi

  git_rsdk diff -- "$PRODUCTS_REL" "$SOC_RECOMMENDS_REL" "$CLI_PACKAGES_REL"
}

print_final_instructions() {
  local next_dir="~/rsdk"

  if [ "$RSDK_DIR" != "$HOME/rsdk" ]; then
    next_dir="$RSDK_DIR"
  fi

  cat <<EOF

RSDK is patched.

Next:
  cd $next_dir
  rsdk devcon

Inside the devcontainer:
  cd /workspaces/rsdk
  ./build-rock5b-bookworm-cli.sh

Optional, after the image build finishes:
  ./set-rock5b-default-root.sh
EOF
}

main() {
  parse_args "$@"
  resolve_paths
  require_command python3
  validate_rsdk_dir

  if [ "$CHECK_ONLY" -eq 1 ]; then
    run_check_only
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run mode: no files will be changed."
  fi

  backup_products_once
  patch_products_json "$([ "$DRY_RUN" -eq 1 ] && printf 'dry-run' || printf 'write')"
  patch_soc_recommends
  patch_cli_packages
  patch_build_helper
  patch_default_root_helper

  if [ "$DRY_RUN" -eq 1 ]; then
    ok "Dry run complete. No files were changed."
    return 0
  fi

  print_git_diff
  print_final_instructions
}

main "$@"
