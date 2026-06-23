#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
RSDK_DIR_ARG=""
OUT_DIR_ARG=""
RSDK_DIR=""
OUT_DIR=""
ROOTFS_EDIT="rootfs-edit"
ROOTFS_BACKUP_BASE="rootfs.tar.before-root-default"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Sets default root/root access in an already built ROCK 5B Bookworm CLI rootfs
and regenerates output.img.

Run this inside the RSDK DevContainer after:
  ./build-rock5b-bookworm-cli.sh

Options:
  --rsdk-dir DIR          RSDK checkout directory. Default: current directory
                          when run from an RSDK checkout, then /workspaces/rsdk.
  --out-dir DIR           ROCK 5B output directory. Default:
                          <rsdk-dir>/out/rock-5b_bookworm_cli
  -h, --help              Show this help.

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --rsdk-dir /workspaces/rsdk
  ./$SCRIPT_NAME --out-dir /workspaces/rsdk/out/rock-5b_bookworm_cli
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
      --out-dir)
        [ "${2:-}" != "" ] || die "--out-dir requires a value"
        OUT_DIR_ARG="$2"
        shift 2
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
  if [ "$OUT_DIR_ARG" != "" ]; then
    OUT_DIR="$(expand_path "$OUT_DIR_ARG")"
    RSDK_DIR="$(dirname "$(dirname "$OUT_DIR")")"
    if [ -d "$RSDK_DIR" ]; then
      RSDK_DIR="$(cd "$RSDK_DIR" && pwd -P)"
    fi
    return 0
  fi

  if [ "$RSDK_DIR_ARG" != "" ]; then
    RSDK_DIR="$(expand_path "$RSDK_DIR_ARG")"
  elif [ -d "$(pwd)/src/share/rsdk" ] && [ -d "$(pwd)/out/rock-5b_bookworm_cli" ]; then
    RSDK_DIR="$(pwd -P)"
  elif [ -d "/workspaces/rsdk/src/share/rsdk" ]; then
    RSDK_DIR="/workspaces/rsdk"
  else
    RSDK_DIR="$(pwd -P)"
  fi

  OUT_DIR="$RSDK_DIR/out/rock-5b_bookworm_cli"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return 0
  fi

  sudo "$@"
}

validate_output_dir() {
  info "RSDK dir: $RSDK_DIR"
  info "ROCK 5B output dir: $OUT_DIR"

  [ -d "$RSDK_DIR" ] || die "RSDK directory does not exist: $RSDK_DIR"
  [ -d "$OUT_DIR" ] || die "Output directory does not exist: $OUT_DIR"
  [ -f "$OUT_DIR/rootfs.tar" ] || die "Missing rootfs.tar: $OUT_DIR/rootfs.tar"
  [ -x "$OUT_DIR/build-image" ] || die "Missing executable build-image: $OUT_DIR/build-image"

  ok "ROCK 5B build output looks valid."
}

next_backup_path() {
  local backup="$ROOTFS_BACKUP_BASE"
  local stamp

  if [ ! -e "$backup" ]; then
    printf '%s\n' "$backup"
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$ROOTFS_BACKUP_BASE.$stamp"

  if [ ! -e "$backup" ]; then
    printf '%s\n' "$backup"
    return 0
  fi

  backup="$ROOTFS_BACKUP_BASE.$stamp.$$"
  printf '%s\n' "$backup"
}

write_file_as_root() {
  local path="$1"
  as_root tee "$path" >/dev/null
}

ensure_openssh_server_in_rootfs() {
  if as_root chroot "$ROOTFS_EDIT" /bin/bash -c 'dpkg-query -W -f="${Status}" openssh-server 2>/dev/null | grep -q "install ok installed"'; then
    ok "openssh-server is installed."
    return 0
  fi

  info "openssh-server is missing; installing it into the rootfs."
  as_root chroot "$ROOTFS_EDIT" /bin/bash -c 'apt-get update'
  as_root chroot "$ROOTFS_EDIT" /bin/bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server'
}

enable_systemd_unit_in_rootfs() {
  local unit="$1"
  local unit_file="$unit"

  if as_root chroot "$ROOTFS_EDIT" /bin/bash -c "systemctl enable '$unit' && systemctl is-enabled --quiet '$unit'"; then
    return 0
  fi

  warn "systemctl enable $unit did not leave the unit enabled in chroot; creating wants symlink directly."
  if [ ! -e "$ROOTFS_EDIT/lib/systemd/system/$unit_file" ] && [ ! -e "$ROOTFS_EDIT/usr/lib/systemd/system/$unit_file" ] && [[ "$unit_file" == *@*.service ]]; then
    unit_file="${unit_file%@*}@.service"
  fi

  [ -e "$ROOTFS_EDIT/lib/systemd/system/$unit_file" ] || [ -e "$ROOTFS_EDIT/usr/lib/systemd/system/$unit_file" ] || die "Missing systemd unit in rootfs: $unit"
  as_root mkdir -p "$ROOTFS_EDIT/etc/systemd/system/multi-user.target.wants"

  if [ -e "$ROOTFS_EDIT/lib/systemd/system/$unit_file" ]; then
    as_root ln -sf "/lib/systemd/system/$unit_file" "$ROOTFS_EDIT/etc/systemd/system/multi-user.target.wants/$unit"
  else
    as_root ln -sf "/usr/lib/systemd/system/$unit_file" "$ROOTFS_EDIT/etc/systemd/system/multi-user.target.wants/$unit"
  fi

  as_root chroot "$ROOTFS_EDIT" /bin/bash -c "systemctl is-enabled --quiet '$unit'" || die "Failed to enable systemd unit in rootfs: $unit"
}

set_default_root_in_rootfs() {
  local backup

  cd "$OUT_DIR"
  backup="$(next_backup_path)"

  info "Extracting rootfs.tar into $ROOTFS_EDIT."
  as_root rm -rf "$ROOTFS_EDIT"
  as_root mkdir -p "$ROOTFS_EDIT"
  as_root tar -xf rootfs.tar -C "$ROOTFS_EDIT"

  info "Setting root password to root and enabling root shell."
  as_root chroot "$ROOTFS_EDIT" /bin/bash -c 'echo "root:root" | chpasswd'
  as_root chroot "$ROOTFS_EDIT" /bin/bash -c 'passwd -u root || true'
  as_root chroot "$ROOTFS_EDIT" /bin/bash -c 'usermod -s /bin/bash root'

  info "Enabling SSH server and root login."
  ensure_openssh_server_in_rootfs
  as_root mkdir -p "$ROOTFS_EDIT/etc/ssh/sshd_config.d"
  write_file_as_root "$ROOTFS_EDIT/etc/ssh/sshd_config.d/99-root-login.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
  as_root chroot "$ROOTFS_EDIT" /bin/bash -c 'ssh-keygen -A'
  enable_systemd_unit_in_rootfs ssh.service

  info "Enabling tty1 root autologin."
  as_root mkdir -p "$ROOTFS_EDIT/etc/systemd/system/getty@tty1.service.d"
  write_file_as_root "$ROOTFS_EDIT/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF
  enable_systemd_unit_in_rootfs getty@tty1.service

  info "Writing login notice."
  write_file_as_root "$ROOTFS_EDIT/etc/issue" <<'EOF'
ROCK 5B Bookworm CLI

Default login:
  user: root
  pass: root

CHANGE THIS PASSWORD IMMEDIATELY.

EOF

  info "Backing up rootfs.tar to $backup."
  as_root mv rootfs.tar "$backup"

  info "Packing modified rootfs.tar."
  as_root tar --numeric-owner -cpf rootfs.tar -C "$ROOTFS_EDIT" .

  info "Cleaning temporary rootfs edit directory."
  as_root rm -rf "$ROOTFS_EDIT"

  ok "Rootfs updated."
  ls -lh rootfs.tar "$backup"
}

ensure_kvm_access() {
  if [ ! -e /dev/kvm ]; then
    warn "/dev/kvm does not exist; libguestfs will run without KVM acceleration."
    return 0
  fi

  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "/dev/kvm is accessible to the current user."
    return 0
  fi

  info "/dev/kvm is not accessible to the current user; applying immediate chmod 0666 workaround."
  as_root chmod 0666 /dev/kvm

  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "/dev/kvm is accessible now."
    return 0
  fi

  warn "Could not make /dev/kvm accessible; libguestfs may run slowly."
}

rebuild_output_image() {
  cd "$OUT_DIR"

  export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

  ensure_kvm_access

  info "Regenerating output.img from modified rootfs.tar."
  as_root rm -f output.img
  ./build-image

  [ -f output.img ] || die "build-image finished but output.img was not created."

  ok "Image regenerated."
  ls -lh output.img
}

main() {
  parse_args "$@"
  resolve_paths

  require_command date
  require_command dirname
  require_command tar
  require_command tee
  require_command chroot
  require_command chmod
  if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
  fi

  validate_output_dir
  set_default_root_in_rootfs
  rebuild_output_image

  cat <<EOF

Done.
Default access enabled:
  root password: root
  SSH root login: enabled
  tty1 root autologin: enabled

Image:
  $OUT_DIR/output.img
EOF
}

main "$@"
