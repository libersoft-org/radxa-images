#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RSDK_REPO_URL="https://github.com/RadxaOS-SDK/rsdk.git"
RSDK_PATCH_SCRIPT_NAME="rock5b_bookworm_patch_rsdk.sh"
RSDK_PATCH_SCRIPT_SOURCE="$SCRIPT_DIR/$RSDK_PATCH_SCRIPT_NAME"
RSDK_DIR_ARG=""
RSDK_WORKSPACE_DIR_ARG="${RSDK_WORKSPACE_DIR:-}"
LOG_DIR_ARG=""
MIN_FREE_GB="${MIN_FREE_GB:-40}"
RECOMMENDED_FREE_GB="${RECOMMENDED_FREE_GB:-60}"
DOCKER_NETWORK_TEST_TIMEOUT="${DOCKER_NETWORK_TEST_TIMEOUT:-15}"
ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND="${ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND:-auto}"
DEVCONTAINER_NODE_OLD_SPACE_MB="${DEVCONTAINER_NODE_OLD_SPACE_MB:-8192}"
ASSUME_YES=0
DRY_RUN=0
CHECK_ONLY=0
SKIP_APT_UPGRADE=0
SKIP_DOCKER_HELLO=0
SKIP_DOCKER_NETWORK_TEST=0
REBOOT_IF_NEEDED=0
NEEDS_RELOGIN=0
ALLOW_KVM_WORLD_ACCESS=0
TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""
RSDK_OWNER_USER=""
RSDK_OWNER_UID=""
RSDK_OWNER_GID=""
RSDK_DIR=""
BASHRC_FILE=""
RSDK_LAUNCHER="/usr/local/bin/rsdk"
LOG_FILE=""
DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED=0
DEVCONTAINER_HOSTNET_WORKAROUND_APPLIED=0
DEVCONTAINER_UID_PATCH_ENABLED=0
DEVCONTAINER_UID_PATCH_APPLIED=0
DEVCONTAINER_KVM_GROUP_ADD=""
RESET_ROOT_DEVCONTAINER_USER=0
ROOT_DEFAULT_RSDK_DIR=0

APT_PACKAGES=(
  git
  curl
  ca-certificates
  qemu-user-static
  binfmt-support
  npm
  python3
  docker.io
  xz-utils
  unzip
  build-essential
  util-linux
  coreutils
  pv
  parted
)

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Runs steps 1-4 from rock5b_bookworm_cli_repo_readme_en.md on the host PC:
  1. Host dependencies
  2. Docker permissions
  3. Clone/update RSDK
  4. RSDK patching, DevContainer CLI, host PATH, and DevContainer startup

Options:
  --rsdk-dir DIR          RSDK checkout directory. Default: ~/rsdk, or /workspaces/rsdk when run as root.
  --rsdk-workspace-dir DIR
                          Alias for --rsdk-dir, also settable with RSDK_WORKSPACE_DIR.
  --rsdk-owner-user USER  Advanced: use USER uid/gid for checkout ownership.
                          Only use when it matches DevContainer vscode ownership requirements.
  --repo-url URL          RSDK git URL. Default: $RSDK_REPO_URL
  --log-dir DIR           Log directory. Default: ~/.local/state/rock5b-bookworm-setup
  --skip-apt-upgrade      Run apt update/install, but skip apt upgrade.
  --skip-docker-hello     Skip 'docker run --rm hello-world'.
  --skip-docker-network-test
                          Skip Docker container egress/DNS tests.
  --no-devcontainer-hostnet-workaround
                          Detect broken bridge networking, but do not patch DevContainer/buildx.
  --force-devcontainer-hostnet-workaround
                          Apply DevContainer/buildx host-network workaround even if bridge networking works.
  --allow-kvm-world-access
                          If /dev/kvm exists, chmod it to 0666 for immediate libguestfs acceleration.
                          Use only on dedicated single-user build VMs/templates.
  --reset-root-devcontainer-user
                          Remove root remoteUser/containerUser overrides from devcontainer.json.
  --reboot-if-needed      Reboot at the end if Docker group membership needs it.
  --no-reboot             Do not reboot automatically. This is the default.
  --yes                   Do not ask interactive confirmation questions.
  --dry-run               Print actions without changing the host.
  --check-only            Verify an already completed setup without changing it.
  -h, --help              Show this help.

Environment:
  MIN_FREE_GB             Required free space in GB. Default: 40.
  RECOMMENDED_FREE_GB     Recommended free space in GB. Default: 60.
  DOCKER_NETWORK_TEST_TIMEOUT
                          Seconds before Docker container egress/DNS tests time out. Default: 15.
  ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND
                          auto, yes, or no. Default: auto.
  DEVCONTAINER_NODE_OLD_SPACE_MB
                          Node/V8 old-space heap limit for DevContainer CLI runs.
                          Default: 8192. Set to 0 to leave NODE_OPTIONS unchanged.
  RSDK_WORKSPACE_DIR      Override target RSDK checkout path.

Examples:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --skip-apt-upgrade
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

quote_cmd() {
  local arg
  printf '%q' "$1"
  shift || true
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
}

node_options_with_devcontainer_heap() {
  local existing="${NODE_OPTIONS:-}"

  if [ "${DEVCONTAINER_NODE_OLD_SPACE_MB:-}" = "" ] || [ "$DEVCONTAINER_NODE_OLD_SPACE_MB" = "0" ]; then
    printf '%s' "$existing"
    return 0
  fi

  case " $existing " in
    *" --max-old-space-size="* | *" --max_old_space_size="*)
      printf '%s' "$existing"
      ;;
    *)
      if [ "$existing" != "" ]; then
        printf '%s --max-old-space-size=%s' "$existing" "$DEVCONTAINER_NODE_OLD_SPACE_MB"
      else
        printf '%s' "--max-old-space-size=$DEVCONTAINER_NODE_OLD_SPACE_MB"
      fi
      ;;
  esac
}

rsdk_devcon_script_path() {
  local candidate

  for candidate in "$RSDK_DIR/src/libexec/rsdk/rsdk-devcon" "$RSDK_DIR/libexec/rsdk/rsdk-devcon"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  printf '%s' "$RSDK_DIR/src/libexec/rsdk/rsdk-devcon"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rsdk-dir)
        [ "${2:-}" != "" ] || die "--rsdk-dir requires a value"
        RSDK_DIR_ARG="$2"
        shift 2
        ;;
      --rsdk-workspace-dir)
        [ "${2:-}" != "" ] || die "--rsdk-workspace-dir requires a value"
        RSDK_WORKSPACE_DIR_ARG="$2"
        shift 2
        ;;
      --rsdk-owner-user)
        [ "${2:-}" != "" ] || die "--rsdk-owner-user requires a value"
        RSDK_OWNER_USER="$2"
        shift 2
        ;;
      --repo-url)
        [ "${2:-}" != "" ] || die "--repo-url requires a value"
        RSDK_REPO_URL="$2"
        shift 2
        ;;
      --log-dir)
        [ "${2:-}" != "" ] || die "--log-dir requires a value"
        LOG_DIR_ARG="$2"
        shift 2
        ;;
      --skip-apt-upgrade)
        SKIP_APT_UPGRADE=1
        shift
        ;;
      --skip-docker-hello)
        SKIP_DOCKER_HELLO=1
        shift
        ;;
      --skip-docker-network-test)
        SKIP_DOCKER_NETWORK_TEST=1
        shift
        ;;
      --no-devcontainer-hostnet-workaround)
        ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND="no"
        shift
        ;;
      --force-devcontainer-hostnet-workaround)
        ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND="yes"
        shift
        ;;
      --allow-kvm-world-access)
        ALLOW_KVM_WORLD_ACCESS=1
        shift
        ;;
      --reset-root-devcontainer-user)
        RESET_ROOT_DEVCONTAINER_USER=1
        shift
        ;;
      --reboot-if-needed)
        REBOOT_IF_NEEDED=1
        shift
        ;;
      --no-reboot)
        REBOOT_IF_NEEDED=0
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --check-only)
        CHECK_ONLY=1
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

  case "$ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND" in
    auto | yes | no)
      ;;
    *)
      die "ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND must be auto, yes, or no."
      ;;
  esac

  case "$DOCKER_NETWORK_TEST_TIMEOUT" in
    '' | *[!0-9]*)
      die "DOCKER_NETWORK_TEST_TIMEOUT must be a positive integer."
      ;;
  esac

  if [ "$RSDK_DIR_ARG" != "" ] && [ "$RSDK_WORKSPACE_DIR_ARG" != "" ]; then
    die "Use only one of --rsdk-dir or --rsdk-workspace-dir/RSDK_WORKSPACE_DIR."
  fi
}

expand_for_target_user() {
  local input="$1"

  case "$input" in
    "~")
      printf '%s\n' "$TARGET_HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$TARGET_HOME" "${input#~/}"
      ;;
    /*)
      printf '%s\n' "$input"
      ;;
    *)
      printf '%s/%s\n' "$(pwd)" "$input"
      ;;
  esac
}

resolve_target_user() {
  if [ "$(id -u)" -eq 0 ]; then
    TARGET_USER="${SUDO_USER:-root}"
    if [ "$TARGET_USER" = "root" ]; then
      warn "Running directly as root; RSDK will default to /workspaces/rsdk for DevContainer compatibility."
    else
      warn "Running with root privileges; target user is '$TARGET_USER'."
    fi
  else
    TARGET_USER="$(id -un)"
  fi

  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [ "$TARGET_HOME" != "" ] || die "Cannot resolve home directory for user '$TARGET_USER'."

  TARGET_GROUP="$(id -gn "$TARGET_USER")"
  [ "$TARGET_GROUP" != "" ] || die "Cannot resolve primary group for user '$TARGET_USER'."

  if [ "$RSDK_DIR_ARG" = "" ] && [ "$RSDK_WORKSPACE_DIR_ARG" != "" ]; then
    RSDK_DIR_ARG="$RSDK_WORKSPACE_DIR_ARG"
  fi

  if [ "$RSDK_DIR_ARG" = "" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      RSDK_DIR="/workspaces/rsdk"
      ROOT_DEFAULT_RSDK_DIR=1
    else
      RSDK_DIR="$TARGET_HOME/rsdk"
    fi
  else
    RSDK_DIR="$(expand_for_target_user "$RSDK_DIR_ARG")"
  fi

  if [ "$LOG_DIR_ARG" = "" ]; then
    LOG_DIR_ARG="$TARGET_HOME/.local/state/rock5b-bookworm-setup"
  else
    LOG_DIR_ARG="$(expand_for_target_user "$LOG_DIR_ARG")"
  fi

  BASHRC_FILE="$TARGET_HOME/.bashrc"
}

resolve_rsdk_owner() {
  if [ "$RSDK_OWNER_USER" != "" ]; then
    RSDK_OWNER_UID="$(id -u "$RSDK_OWNER_USER" 2>/dev/null || true)"
    RSDK_OWNER_GID="$(id -g "$RSDK_OWNER_USER" 2>/dev/null || true)"
    [ "$RSDK_OWNER_UID" != "" ] && [ "$RSDK_OWNER_GID" != "" ] || die "Cannot resolve --rsdk-owner-user '$RSDK_OWNER_USER'."
    return 0
  fi

  RSDK_OWNER_UID="1000"
  RSDK_OWNER_GID="1000"
}

setup_logging() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  LOG_FILE="$LOG_DIR_ARG/host-steps-1-4-$stamp.log"

  if [ "$DRY_RUN" -eq 1 ]; then
    LOG_FILE="/tmp/host-steps-1-4-$stamp.dry-run.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    return 0
  fi

  mkdir -p "$LOG_DIR_ARG"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$TARGET_USER:$TARGET_GROUP" "$LOG_DIR_ARG"
  fi

  exec > >(tee -a "$LOG_FILE") 2>&1
}

print_config() {
  info "Target user: $TARGET_USER"
  info "Target home: $TARGET_HOME"
  info "RSDK dir: $RSDK_DIR"
  info "RSDK checkout owner uid/gid: ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}"
  info "Log file: $LOG_FILE"
  info "Required free space: ${MIN_FREE_GB} GB"
  info "Recommended free space: ${RECOMMENDED_FREE_GB} GB"
  info "Docker network test timeout: ${DOCKER_NETWORK_TEST_TIMEOUT} seconds"
  info "DevContainer host-network workaround: $ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND"
  if [ "$ALLOW_KVM_WORLD_ACCESS" -eq 1 ]; then
    warn "KVM immediate access fix: /dev/kvm will be chmod 0666 if present."
  fi
  if [ "$DEVCONTAINER_UID_PATCH_ENABLED" -eq 1 ]; then
    info "DevContainer UID patch: updateRemoteUserUID=false will be enforced."
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    warn "Dry run mode: no host changes will be made."
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    info "Check-only mode: no host changes will be made."
  fi
}

evaluate_devcontainer_uid_patch() {
  if [ "$(id -u)" -eq 0 ] && [ "$RSDK_DIR" = "/workspaces/rsdk" ]; then
    DEVCONTAINER_UID_PATCH_ENABLED=1
  else
    DEVCONTAINER_UID_PATCH_ENABLED=0
  fi
}

finalize_devcontainer_uid_patch_after_network() {
  if [ "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" -eq 1 ] && [ "$DEVCONTAINER_UID_PATCH_ENABLED" -ne 1 ]; then
    DEVCONTAINER_UID_PATCH_ENABLED=1
    warn "Host-network buildx workaround requires updateRemoteUserUID=false; DevContainer UID patch will be applied."
  fi
}

run_cmd() {
  info "+ $(quote_cmd "$@")"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  "$@"
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    run_cmd "$@"
  else
    run_cmd sudo "$@"
  fi
}

run_user() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ "$TARGET_USER" = "root" ]; then
      run_cmd "$@"
    else
      run_cmd sudo -H -u "$TARGET_USER" "$@"
    fi
  else
    run_cmd "$@"
  fi
}

run_user_in_dir() {
  local dir="$1"
  shift

  info "+ cd $(printf '%q' "$dir") && $(quote_cmd "$@")"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    if [ "$TARGET_USER" = "root" ]; then
      (
        cd "$dir"
        "$@"
      )
    else
      (
        cd "$dir"
        sudo -H -u "$TARGET_USER" "$@"
      )
    fi
  else
    (
      cd "$dir"
      "$@"
    )
  fi
}

run_target_with_fresh_groups_in_dir() {
  local dir="$1"
  shift

  info "+ cd $(printf '%q' "$dir") && $(quote_cmd "$@")"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    if [ "$TARGET_USER" = "root" ]; then
      (
        cd "$dir"
        "$@"
      )
    else
      (
        cd "$dir"
        sudo -H -u "$TARGET_USER" "$@"
      )
    fi
  elif current_shell_has_group docker; then
    (
      cd "$dir"
      "$@"
    )
  else
    (
      cd "$dir"
      sudo -H -u "$TARGET_USER" "$@"
    )
  fi
}

confirm_or_die() {
  local prompt="$1"

  if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    die "$prompt Use --yes for non-interactive runs."
  fi

  local answer
  read -r -p "$prompt [y/N] " answer
  case "$answer" in
    y | Y | yes | YES)
      ;;
    *)
      die "Cancelled."
      ;;
  esac
}

require_command_now() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command is missing: $cmd"
}

is_container() {
  [ -f /.dockerenv ] || grep -qaE '(docker|container|kubepods)' /proc/1/cgroup 2>/dev/null
}

check_host_basics() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64 | amd64)
      ok "Host architecture is $arch."
      ;;
    *)
      if [ "$DRY_RUN" -eq 1 ]; then
        warn "Host architecture is $arch, expected x86_64. Dry run continues."
      else
        die "Host architecture is $arch, expected x86_64."
      fi
      ;;
  esac

  if is_container; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "Container-like environment detected. Dry run continues."
    else
      die "This setup must run on the host PC, not inside a container."
    fi
  fi

  if command -v apt-get >/dev/null 2>&1; then
    ok "apt-get is available."
  elif [ "$DRY_RUN" -eq 1 ]; then
    warn "apt-get is missing. Dry run continues."
  else
    die "apt-get is missing. Use Debian 12/13 or a Debian-based host."
  fi

  if [ "$(id -u)" -ne 0 ] || [ "$TARGET_USER" != "root" ]; then
    require_command_now sudo
  fi
  require_command_now getent
  require_command_now df
  require_command_now awk
}

check_free_space() {
  local path="$TARGET_HOME"
  local avail_kb
  local avail_gb

  if [ -d "$RSDK_DIR" ]; then
    path="$RSDK_DIR"
  elif [ -d "$(dirname "$RSDK_DIR")" ]; then
    path="$(dirname "$RSDK_DIR")"
  fi

  avail_kb="$(df -Pk "$path" | awk 'NR == 2 {print $4}')"
  [ "$avail_kb" != "" ] || die "Cannot determine free space for $path."

  avail_gb="$((avail_kb / 1024 / 1024))"
  if [ "$avail_gb" -lt "$MIN_FREE_GB" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "Only ${avail_gb} GB free at $path; ${MIN_FREE_GB} GB required. Dry run continues."
    else
      die "Only ${avail_gb} GB free at $path; ${MIN_FREE_GB} GB required."
    fi
  elif [ "$avail_gb" -lt "$RECOMMENDED_FREE_GB" ]; then
    warn "Free space at $path: ${avail_gb} GB. Minimum is ${MIN_FREE_GB} GB, but ${RECOMMENDED_FREE_GB} GB or more is recommended."
  else
    ok "Free space at $path: ${avail_gb} GB."
  fi
}

install_host_dependencies() {
  info "Step 1/4: Installing host dependencies."

  run_root apt-get update

  if [ "$SKIP_APT_UPGRADE" -eq 1 ]; then
    warn "Skipping apt upgrade because --skip-apt-upgrade was used."
  else
    confirm_or_die "About to run apt upgrade on this host."
    run_root env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi

  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
}

user_in_group_db() {
  local user="$1"
  local group="$2"
  id -nG "$user" | tr ' ' '\n' | grep -qx "$group"
}

current_shell_has_group() {
  local group="$1"
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  id -nG | tr ' ' '\n' | grep -qx "$group"
}

configure_docker() {
  info "Step 2/4: Enabling Docker and adding '$TARGET_USER' to the docker group."

  run_root systemctl enable --now docker

  if [ "$TARGET_USER" = "root" ]; then
    ok "Running as root; docker group membership is not required."
  elif user_in_group_db "$TARGET_USER" docker; then
    ok "User '$TARGET_USER' is already listed in the docker group."
  else
    run_root usermod -aG docker "$TARGET_USER"
    NEEDS_RELOGIN=1
    warn "Docker group membership was added. It becomes active after logout/login or reboot."
  fi

  if [ "$TARGET_USER" = "root" ]; then
    ok "Current root shell can use Docker without a group reload."
  elif current_shell_has_group docker; then
    ok "Current shell already has the docker group."
  else
    NEEDS_RELOGIN=1
    warn "Current shell does not have the docker group yet."
  fi
}

configure_kvm_access() {
  local kvm_gid=""
  local kvm_mode=""
  local kvm_group_gid=""
  local kvm_listing=""
  local target_can_access=1

  info "Checking /dev/kvm access for libguestfs image-build acceleration."

  if [ ! -e /dev/kvm ]; then
    warn "/dev/kvm is absent. Nested virtualization/KVM acceleration is unavailable; libguestfs will fall back to slower emulation."
    return 0
  fi

  if [ ! -c /dev/kvm ]; then
    warn "/dev/kvm exists but is not a character device. Leaving it unchanged."
    return 0
  fi

  kvm_gid="$(stat -c '%g' /dev/kvm)"
  kvm_mode="$(stat -c '%a' /dev/kvm)"
  kvm_listing="$(ls -l /dev/kvm)"
  info "/dev/kvm: $kvm_listing"

  DEVCONTAINER_KVM_GROUP_ADD="$kvm_gid"
  info "DevContainer will be started with '--group-add $kvm_gid' so the vscode user can access /dev/kvm when group permissions allow it."

  if getent group kvm >/dev/null 2>&1; then
    kvm_group_gid="$(getent group kvm | cut -d: -f3)"
    if [ "$kvm_group_gid" != "$kvm_gid" ]; then
      warn "Host group 'kvm' has gid $kvm_group_gid, but /dev/kvm is owned by gid $kvm_gid. DevContainer group-add will use the device gid."
    fi

    if [ "$TARGET_USER" = "root" ]; then
      ok "Target user is root; host-side /dev/kvm group membership is not required."
    elif user_in_group_db "$TARGET_USER" kvm; then
      ok "User '$TARGET_USER' is already listed in the kvm group."
    elif [ "$CHECK_ONLY" -eq 1 ]; then
      warn "User '$TARGET_USER' is not listed in the kvm group. Rerun without --check-only to add it, or use --allow-kvm-world-access on a dedicated VM."
    else
      run_root usermod -aG kvm "$TARGET_USER"
      NEEDS_RELOGIN=1
      warn "Added '$TARGET_USER' to the kvm group. A logout/login or reboot is needed for ordinary host shells."
    fi
  else
    warn "Host group 'kvm' does not exist. DevContainer will still use '--group-add $kvm_gid' based on /dev/kvm ownership."
  fi

  if [ "$ALLOW_KVM_WORLD_ACCESS" -eq 1 ]; then
    warn "Applying immediate /dev/kvm world access because --allow-kvm-world-access was used."
    if [ "$DRY_RUN" -eq 1 ] || [ "$CHECK_ONLY" -eq 1 ]; then
      info "+ chmod 0666 /dev/kvm"
    else
      run_root chmod 0666 /dev/kvm
      kvm_mode="$(stat -c '%a' /dev/kvm)"
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    warn "Dry run: /dev/kvm access test skipped."
    return 0
  fi

  if [ "$TARGET_USER" = "root" ]; then
    [ -r /dev/kvm ] && [ -w /dev/kvm ] && target_can_access=0
  elif [ "$(id -u)" -eq 0 ]; then
    sudo -H -u "$TARGET_USER" test -r /dev/kvm -a -w /dev/kvm && target_can_access=0
  else
    test -r /dev/kvm -a -w /dev/kvm && target_can_access=0
  fi

  if [ "$target_can_access" -eq 0 ]; then
    ok "Host user '$TARGET_USER' can access /dev/kvm; libguestfs can use KVM acceleration when the DevContainer also has the matching group."
  else
    warn "Host user '$TARGET_USER' cannot currently read/write /dev/kvm (mode $kvm_mode)."
    warn "For immediate performance on a disposable single-user build VM, rerun with --allow-kvm-world-access."
    warn "Otherwise reboot or log out/in after kvm group changes, then rerun --check-only."
  fi
}

git_as_target() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ "$TARGET_USER" = "root" ]; then
      git "$@"
    else
      sudo -H -u "$TARGET_USER" git "$@"
    fi
  else
    git "$@"
  fi
}

git_rsdk_as_target() {
  if [ "$RSDK_DIR" != "" ]; then
    git_as_target -c "safe.directory=$RSDK_DIR" "$@"
  else
    git_as_target "$@"
  fi
}

rsdk_dir_is_git_repo() {
  [ "$DRY_RUN" -eq 0 ] || return 1
  git_rsdk_as_target -C "$RSDK_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

prepare_root_workspace_dir() {
  [ "$(id -u)" -eq 0 ] || return 0

  if [ "$RSDK_DIR" = "/root/rsdk" ]; then
    die "/root/rsdk is unsafe for the RSDK DevContainer because it runs as user vscode. Use /workspaces/rsdk or pass --rsdk-dir explicitly."
  fi

  if [ "$RSDK_DIR" = "/workspaces/rsdk" ]; then
    if [ -d /root/rsdk ] && [ ! -L /root/rsdk ] && [ ! -e "$RSDK_DIR" ]; then
      warn "Existing /root/rsdk real directory will be moved to /workspaces/rsdk for DevContainer access."
      if [ "$DRY_RUN" -eq 1 ]; then
        info "+ mkdir -p /workspaces"
        info "+ mv /root/rsdk /workspaces/rsdk"
        info "+ ln -s /workspaces/rsdk /root/rsdk"
      else
        mkdir -p /workspaces
        mv /root/rsdk "$RSDK_DIR"
        ln -s "$RSDK_DIR" /root/rsdk
      fi
    elif [ -d /root/rsdk ] && [ ! -L /root/rsdk ] && [ -e "$RSDK_DIR" ]; then
      die "Both /root/rsdk and $RSDK_DIR exist. Move or merge one manually, then rerun."
    elif [ ! -e /root/rsdk ] && [ -e "$RSDK_DIR" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        info "+ ln -s /workspaces/rsdk /root/rsdk"
      else
        ln -s "$RSDK_DIR" /root/rsdk
      fi
    fi
  fi

  if [ "$RSDK_DIR" = /workspaces/* ] || [ "$RSDK_DIR" = "/workspaces" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "+ mkdir -p /workspaces"
      info "+ chmod 755 /workspaces"
    else
      mkdir -p /workspaces
      chmod 755 /workspaces
    fi
  fi

  if [ "$(id -u)" -eq 0 ] && [ ! -e "$RSDK_DIR" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "+ mkdir -p $(printf '%q' "$(dirname "$RSDK_DIR")")"
      info "+ chown $(printf '%q' "$TARGET_USER:$TARGET_GROUP") $(printf '%q' "$(dirname "$RSDK_DIR")")"
    else
      mkdir -p "$(dirname "$RSDK_DIR")"
      chown "$TARGET_USER:$TARGET_GROUP" "$(dirname "$RSDK_DIR")"
    fi
  fi
}

ensure_root_rsdk_symlink() {
  [ "$(id -u)" -eq 0 ] || return 0
  [ "$RSDK_DIR" = "/workspaces/rsdk" ] || return 0

  if [ -L /root/rsdk ]; then
    return 0
  fi

  if [ -e /root/rsdk ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ ln -s /workspaces/rsdk /root/rsdk"
  else
    ln -s "$RSDK_DIR" /root/rsdk
  fi
}

clone_or_update_rsdk() {
  info "Step 3/4: Cloning or refreshing RSDK."

  prepare_root_workspace_dir

  if [ -e "$RSDK_DIR" ] && ! rsdk_dir_is_git_repo; then
    die "$RSDK_DIR exists but is not a git repository. Move it away or pass --rsdk-dir DIR."
  fi

  if rsdk_dir_is_git_repo; then
    ok "$RSDK_DIR already exists as a git repository; preserving checkout and refreshing submodules."
  else
    run_user mkdir -p "$(dirname "$RSDK_DIR")"
    run_user git clone --recurse-submodules "$RSDK_REPO_URL" "$RSDK_DIR"
  fi

  run_user_in_dir "$RSDK_DIR" git -c "safe.directory=$RSDK_DIR" submodule sync --recursive
  run_user_in_dir "$RSDK_DIR" git -c "safe.directory=$RSDK_DIR" submodule update --init --recursive --force
  run_user_in_dir "$RSDK_DIR" git -c "safe.directory=$RSDK_DIR" submodule status --recursive
  ensure_root_rsdk_symlink
}

detect_devcontainer_owner_from_image() {
  [ "$RSDK_OWNER_USER" = "" ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0

  local image="mcr.microsoft.com/devcontainers/base:bookworm"
  local uid=""
  local gid=""

  if command -v docker >/dev/null 2>&1 && docker_as_target info >/dev/null 2>&1; then
    uid="$(docker_as_target run --rm "$image" id -u vscode 2>/dev/null || true)"
    gid="$(docker_as_target run --rm "$image" id -g vscode 2>/dev/null || true)"
  fi

  if [ "$uid" != "" ] && [ "$gid" != "" ]; then
    RSDK_OWNER_UID="$uid"
    RSDK_OWNER_GID="$gid"
    ok "Detected DevContainer vscode uid/gid as ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}."
  else
    warn "Could not detect DevContainer vscode uid/gid; using fallback ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}."
  fi
}

fix_rsdk_checkout_ownership() {
  [ "$DEVCONTAINER_UID_PATCH_ENABLED" -eq 1 ] || return 0

  info "Fixing RSDK checkout ownership for DevContainer user ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}."

  if [ "$(id -u)" -ne 0 ]; then
    if [ "$(id -u)" != "$RSDK_OWNER_UID" ] || [ "$(id -g)" != "$RSDK_OWNER_GID" ]; then
      die "updateRemoteUserUID=false requires checkout ownership compatible with the DevContainer user vscode (${RSDK_OWNER_UID}:${RSDK_OWNER_GID}). Current user is $(id -u):$(id -g). Rerun the host setup with sudo/root so it can chown $RSDK_DIR, or use a checkout owned by ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}."
    fi
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ chown -R ${RSDK_OWNER_UID}:${RSDK_OWNER_GID} $(printf '%q' "$RSDK_DIR")"
    info "+ chmod 755 /workspaces"
    info "+ chmod -R u+rwX,go+rX $(printf '%q' "$RSDK_DIR")"
    info "+ chmod +x $(printf '%q' "$RSDK_DIR/src/bin/rsdk") || true"
    return 0
  fi

  [ -d "$RSDK_DIR" ] || die "$RSDK_DIR does not exist; cannot fix ownership."
  if [ "$RSDK_DIR" = /workspaces/* ] || [ "$RSDK_DIR" = "/workspaces" ]; then
    chmod 755 /workspaces
  fi
  chown -R "${RSDK_OWNER_UID}:${RSDK_OWNER_GID}" "$RSDK_DIR"
  chmod -R u+rwX,go+rX "$RSDK_DIR"
  chmod +x "$RSDK_DIR/src/bin/rsdk" 2>/dev/null || true
}

bashrc_contains_rsdk_path() {
  [ -f "$BASHRC_FILE" ] && grep -q 'RSDK PATH' "$BASHRC_FILE"
}

append_rsdk_path_to_bashrc() {
  local quoted_dir

  if bashrc_contains_rsdk_path; then
    ok "$BASHRC_FILE already contains an RSDK PATH block."
    return 0
  fi

  info "Adding RSDK PATH block to $BASHRC_FILE."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ append RSDK PATH block to $(printf '%q' "$BASHRC_FILE")"
    return 0
  fi

  if [ ! -e "$BASHRC_FILE" ]; then
    : >"$BASHRC_FILE"
    chown "$TARGET_USER:$TARGET_GROUP" "$BASHRC_FILE"
  fi

  {
    printf '\n# RSDK PATH\n'
    if [ "$RSDK_DIR" = "$TARGET_HOME/rsdk" ]; then
      printf 'if [ -d "$HOME/rsdk" ]; then\n'
      printf '  export PATH="$HOME/rsdk/src/bin:$HOME/rsdk/node_modules/.bin:$PATH"\n'
      printf 'fi\n'
    else
      printf -v quoted_dir '%q' "$RSDK_DIR"
      printf 'if [ -d %s ]; then\n' "$quoted_dir"
      printf '  export PATH=%s/src/bin:%s/node_modules/.bin:$PATH\n' "$quoted_dir" "$quoted_dir"
      printf 'fi\n'
    fi
  } >>"$BASHRC_FILE"

  chown "$TARGET_USER:$TARGET_GROUP" "$BASHRC_FILE"
}

rsdk_launcher_is_managed() {
  [ -f "$RSDK_LAUNCHER" ] && grep -Eq 'Managed by (rock5b_bookworm_host_steps_1_4|bookworm_rsdk_host_steps_1_4)\.sh' "$RSDK_LAUNCHER"
}

install_rsdk_launcher() {
  local tmp_launcher
  local quoted_dir
  local quoted_user

  info "Installing host rsdk launcher at $RSDK_LAUNCHER."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ install managed rsdk launcher to $(printf '%q' "$RSDK_LAUNCHER")"
    return 0
  fi

  if [ -e "$RSDK_LAUNCHER" ] && ! rsdk_launcher_is_managed; then
    die "$RSDK_LAUNCHER already exists and is not managed by this script. Move it away or add $RSDK_DIR/src/bin to PATH manually."
  fi

  tmp_launcher="$(mktemp)"
  printf -v quoted_dir '%q' "$RSDK_DIR"
  printf -v quoted_user '%q' "$TARGET_USER"

  {
    printf '#!/usr/bin/env bash\n'
    printf '# Managed by bookworm_rsdk_host_steps_1_4.sh\n'
    printf 'set -Eeuo pipefail\n'
    printf 'RSDK_DIR=%s\n' "$quoted_dir"
    printf 'TARGET_USER=%s\n' "$quoted_user"
    printf 'if [ ! -x "$RSDK_DIR/src/bin/rsdk" ]; then\n'
    printf '  printf '\''[ERROR] %%s/src/bin/rsdk is missing or not executable. Re-run the host setup script.\\n'\'' "$RSDK_DIR" >&2\n'
    printf '  exit 127\n'
    printf 'fi\n'
    printf 'export PATH="$RSDK_DIR/src/bin:$RSDK_DIR/node_modules/.bin:$PATH"\n'
    printf 'if [ "${DEVCONTAINER_NODE_OLD_SPACE_MB:-8192}" != "0" ]; then\n'
    printf '  case " ${NODE_OPTIONS:-} " in\n'
    printf '    *" --max-old-space-size="* | *" --max_old_space_size="*) ;;\n'
    printf '    *) NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=${DEVCONTAINER_NODE_OLD_SPACE_MB:-8192}" ;;\n'
    printf '  esac\n'
    printf '  export NODE_OPTIONS\n'
    printf 'fi\n'
    printf 'if [ "${1:-}" = "devcon" ] && [ "$(id -u)" -ne 0 ] && ! docker ps >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then\n'
    printf '  exec sudo -H -u "$TARGET_USER" env "PATH=$PATH" "NODE_OPTIONS=${NODE_OPTIONS:-}" "DEVCONTAINER_NODE_OLD_SPACE_MB=${DEVCONTAINER_NODE_OLD_SPACE_MB:-8192}" "$RSDK_DIR/src/bin/rsdk" "$@"\n'
    printf 'fi\n'
    printf 'exec "$RSDK_DIR/src/bin/rsdk" "$@"\n'
  } >"$tmp_launcher"

  run_root install -m 0755 "$tmp_launcher" "$RSDK_LAUNCHER"
  rm -f "$tmp_launcher"
}

install_devcontainer_cli_and_path() {
  info "Step 4/4: Installing DevContainer CLI, configuring RSDK PATH, and preparing DevContainer startup."

  if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$RSDK_DIR" ]; then
    die "$RSDK_DIR does not exist; cannot install @devcontainers/cli."
  fi

  run_user_in_dir "$RSDK_DIR" npm install @devcontainers/cli
  export PATH="$RSDK_DIR/src/bin:$RSDK_DIR/node_modules/.bin:$PATH"
  append_rsdk_path_to_bashrc
  install_rsdk_launcher
}

patch_rsdk_devcon_node_heap_guard() {
  local file
  local backup

  file="$(rsdk_devcon_script_path)"
  backup="$file.bak-node-heap-guard"

  info "Patching RSDK devcontainer launcher to set a safe Node heap limit."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ patch $(printf '%q' "$file") with NODE_OPTIONS old-space guard"
    return 0
  fi

  [ -f "$file" ] || die "$file is missing; cannot patch rsdk devcontainer launcher."
  command -v node >/dev/null 2>&1 || die "node is required to patch rsdk devcontainer launcher."

  if [ ! -e "$backup" ]; then
    cp "$file" "$backup"
  fi

  node - "$file" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const start = "\t# BEGIN rock5b host setup Node heap guard";
const end = "\t# END rock5b host setup Node heap guard";
const block = [
  "",
  start,
  '\tif [[ "${DEVCONTAINER_NODE_OLD_SPACE_MB:-8192}" != "0" ]]; then',
  '\t\tcase " ${NODE_OPTIONS:-} " in',
  '\t\t*" --max-old-space-size="* | *" --max_old_space_size="*) ;;',
  '\t\t*) NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=${DEVCONTAINER_NODE_OLD_SPACE_MB:-8192}" ;;',
  "\t\tesac",
  "\t\texport NODE_OPTIONS",
  "\tfi",
  end,
  "",
].join("\n");

let text = fs.readFileSync(file, "utf8");
text = text.replace(/\n\t# BEGIN rock5b host setup Node heap guard[\s\S]*?\n\t# END rock5b host setup Node heap guard\n?/g, "\n");

if (!text.includes(start)) {
  const sourceLine = '\tsource "$SCRIPT_DIR/../../lib/rsdk/utils.sh"';
  if (!text.includes(sourceLine)) {
    throw new Error("expected rsdk-devcon utils source line not found");
  }
  text = text.replace(sourceLine, `${sourceLine}${block}`);
}

fs.writeFileSync(file, text);
NODE

  ok "RSDK devcontainer launcher exports NODE_OPTIONS for devcontainer CLI runs."
}

patch_devcontainer_json_with_node() {
  local file="$1"
  local set_update_remote_uid="$2"
  local add_host_network="$3"
  local kvm_group_add="$4"

  node - "$file" "$set_update_remote_uid" "$add_host_network" "$kvm_group_add" "$RESET_ROOT_DEVCONTAINER_USER" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const setUpdateRemoteUid = process.argv[3] === "1";
const addHostNetwork = process.argv[4] === "1";
const kvmGroupAdd = process.argv[5];
const resetRootUser = process.argv[6] === "1";

function stripJsonc(input) {
  let out = "";
  let inString = false;
  let quote = "";
  let escaped = false;
  for (let i = 0; i < input.length; i++) {
    const ch = input[i];
    const next = input[i + 1];
    if (inString) {
      out += ch;
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === quote) {
        inString = false;
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      inString = true;
      quote = ch;
      out += ch;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (i < input.length && input[i] !== "\n") i++;
      out += "\n";
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      while (i < input.length && !(input[i] === "*" && input[i + 1] === "/")) i++;
      i++;
      continue;
    }
    out += ch;
  }
  return out.replace(/,\s*([}\]])/g, "$1");
}

const original = fs.readFileSync(path, "utf8");
const data = JSON.parse(stripJsonc(original));
if (setUpdateRemoteUid) {
  data.updateRemoteUserUID = false;
}
if (addHostNetwork) {
  if (!Array.isArray(data.runArgs)) data.runArgs = [];
  const hasNetworkHostPair = data.runArgs.some((value, index) => value === "--network" && data.runArgs[index + 1] === "host");
  const hasNetworkHostEquals = data.runArgs.includes("--network=host");
  if (!hasNetworkHostPair && !hasNetworkHostEquals) {
    data.runArgs.push("--network", "host");
  }
}
if (kvmGroupAdd) {
  if (!Array.isArray(data.runArgs)) data.runArgs = [];
  const hasGroupAddPair = data.runArgs.some((value, index) => value === "--group-add" && String(data.runArgs[index + 1]) === kvmGroupAdd);
  const hasGroupAddEquals = data.runArgs.includes(`--group-add=${kvmGroupAdd}`);
  if (!hasGroupAddPair && !hasGroupAddEquals) {
    data.runArgs.push("--group-add", kvmGroupAdd);
  }
}
if (resetRootUser || data["x-rock5b-host-setup-root-user-override"] === true) {
  if (data.remoteUser === "root") delete data.remoteUser;
  if (data.containerUser === "root") delete data.containerUser;
  delete data["x-rock5b-host-setup-root-user-override"];
}
data.updateContentCommand = "command -v devenv >/dev/null || true";
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
NODE
}

apply_devcontainer_json_patches() {
  local file="$RSDK_DIR/.devcontainer/devcontainer.json"
  local backup="$file.bak-host-setup"

  info "Applying DevContainer JSON patches."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ validate $(printf '%q' "$file") exists"
    info "+ backup once to $(printf '%q' "$backup")"
    info "+ set updateContentCommand='command -v devenv >/dev/null || true'"
    if [ "$DEVCONTAINER_UID_PATCH_ENABLED" -eq 1 ]; then
      info "+ set updateRemoteUserUID=false"
    fi
    if [ "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" -eq 1 ]; then
      info "+ add runArgs [--network, host]"
    fi
    if [ "$DEVCONTAINER_KVM_GROUP_ADD" != "" ]; then
      info "+ add runArgs [--group-add, $DEVCONTAINER_KVM_GROUP_ADD]"
    fi
    return 0
  fi

  [ -f "$file" ] || die "$file is missing; cannot patch DevContainer configuration."
  command -v node >/dev/null 2>&1 || die "node is required to patch JSONC-like devcontainer.json."

  if [ ! -e "$backup" ]; then
    cp "$file" "$backup"
  fi

  patch_devcontainer_json_with_node "$file" "$DEVCONTAINER_UID_PATCH_ENABLED" "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" "$DEVCONTAINER_KVM_GROUP_ADD"
  DEVCONTAINER_UID_PATCH_APPLIED="$DEVCONTAINER_UID_PATCH_ENABLED"
  DEVCONTAINER_HOSTNET_WORKAROUND_APPLIED="$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED"
  ok "Patched $file without forcing remoteUser=root."
}

append_hostnet_buildx_env_to_bashrc() {
  [ "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" -eq 1 ] || return 0

  if [ -f "$BASHRC_FILE" ] && grep -q 'RSDK HOSTNET BUILDX WORKAROUND' "$BASHRC_FILE"; then
    ok "$BASHRC_FILE already contains the hostnet buildx block."
    return 0
  fi

  info "Adding hostnet buildx environment block to $BASHRC_FILE."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ append RSDK HOSTNET BUILDX WORKAROUND block to $(printf '%q' "$BASHRC_FILE")"
    return 0
  fi

  if [ ! -e "$BASHRC_FILE" ]; then
    : >"$BASHRC_FILE"
    chown "$TARGET_USER:$TARGET_GROUP" "$BASHRC_FILE"
  fi

  {
    printf '\n# RSDK HOSTNET BUILDX WORKAROUND\n'
    printf 'export BUILDX_BUILDER=rsdk-hostnet\n'
    printf 'export DOCKER_BUILDKIT=1\n'
    printf 'export BUILDKIT_PROGRESS=plain\n'
  } >>"$BASHRC_FILE"

  chown "$TARGET_USER:$TARGET_GROUP" "$BASHRC_FILE"
}

docker_as_target() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ "$TARGET_USER" = "root" ]; then
      docker "$@"
    else
      sudo -H -u "$TARGET_USER" docker "$@"
    fi
  elif current_shell_has_group docker; then
    docker "$@"
  else
    sudo -H -u "$TARGET_USER" docker "$@"
  fi
}

docker_target_cmd_prefix() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ "$TARGET_USER" = "root" ]; then
      printf 'docker'
    else
      printf 'sudo -H -u %q docker' "$TARGET_USER"
    fi
  elif current_shell_has_group docker; then
    printf 'docker'
  else
    printf 'sudo -H -u %q docker' "$TARGET_USER"
  fi
}

docker_apt_test() {
  local mode="$1"
  local cname="rock5b-nettest-${mode}-$$"
  local network_arg=()
  local status=0
  local prefix

  case "$mode" in
    bridge)
      ;;
    host)
      network_arg=(--network host)
      ;;
    *)
      die "docker_apt_test mode must be bridge or host."
      ;;
  esac

  if [ "$DRY_RUN" -eq 1 ]; then
    prefix="$(docker_target_cmd_prefix)"
    info "+ timeout $DOCKER_NETWORK_TEST_TIMEOUT $prefix run --name $cname --rm ${network_arg[*]} debian:bookworm bash -lc 'apt-get -o Acquire::Retries=0 update'"
    return 0
  fi

  docker_as_target rm -f "$cname" >/dev/null 2>&1 || true
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    timeout "$DOCKER_NETWORK_TEST_TIMEOUT" sudo -H -u "$TARGET_USER" docker run --name "$cname" --rm "${network_arg[@]}" debian:bookworm bash -lc 'apt-get -o Acquire::Retries=0 update' >/dev/null 2>&1 || status=$?
  elif [ "$(id -u)" -ne 0 ] && ! current_shell_has_group docker; then
    timeout "$DOCKER_NETWORK_TEST_TIMEOUT" sudo -H -u "$TARGET_USER" docker run --name "$cname" --rm "${network_arg[@]}" debian:bookworm bash -lc 'apt-get -o Acquire::Retries=0 update' >/dev/null 2>&1 || status=$?
  else
    timeout "$DOCKER_NETWORK_TEST_TIMEOUT" docker run --name "$cname" --rm "${network_arg[@]}" debian:bookworm bash -lc 'apt-get -o Acquire::Retries=0 update' >/dev/null 2>&1 || status=$?
  fi
  docker_as_target rm -f "$cname" >/dev/null 2>&1 || true

  return "$status"
}

evaluate_docker_network() {
  local bridge_ok=1
  local host_ok=1

  if [ "$SKIP_DOCKER_NETWORK_TEST" -eq 1 ]; then
    warn "Skipping Docker container egress/DNS tests."
    if [ "$ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND" = "yes" ]; then
      DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED=1
    fi
    return 0
  fi

  info "Testing container egress/DNS with 'docker run debian apt-get update' and a ${DOCKER_NETWORK_TEST_TIMEOUT}s timeout."

  if [ "$DRY_RUN" -eq 1 ]; then
    docker_apt_test bridge
    docker_apt_test host
    if [ "$ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND" = "yes" ]; then
      DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED=1
    else
      warn "Dry run: Docker network test results are not known."
    fi
    return 0
  fi

  if docker_apt_test bridge; then
    bridge_ok=0
    ok "Docker default bridge container egress/DNS works."
  else
    warn "Docker default bridge container egress/DNS failed or timed out."
  fi

  if docker_apt_test host; then
    host_ok=0
    ok "Docker host container egress/DNS works."
  else
    warn "Docker host container egress/DNS failed or timed out."
  fi

  if [ "$bridge_ok" -eq 0 ] && [ "$ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND" != "yes" ]; then
    DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED=0
    return 0
  fi

  if [ "$bridge_ok" -ne 0 ] && [ "$host_ok" -ne 0 ]; then
    die "Container egress/DNS failed with both bridge and host networking. Fix Docker/container networking before continuing."
  fi

  case "$ENABLE_DEVCONTAINER_HOSTNET_WORKAROUND" in
    yes)
      DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED=1
      ;;
    auto)
      if [ "$bridge_ok" -ne 0 ] && [ "$host_ok" -eq 0 ]; then
        DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED=1
        warn "Docker bridge networking appears broken; host-network DevContainer workaround will be applied."
      fi
      ;;
    no)
      if [ "$bridge_ok" -ne 0 ] && [ "$host_ok" -eq 0 ]; then
        warn "Docker bridge networking appears broken, but DevContainer host-network workaround is disabled."
      fi
      DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED=0
      ;;
  esac
}

setup_hostnet_buildx_builder() {
  [ "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" -eq 1 ] || return 0

  info "Creating Docker buildx host-network builder 'rsdk-hostnet'."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ docker buildx rm rsdk-hostnet 2>/dev/null || true"
    info "+ docker buildx create --name rsdk-hostnet --driver docker-container --driver-opt network=host --use"
    info "+ docker buildx inspect --bootstrap"
    return 0
  fi

  docker_as_target buildx rm rsdk-hostnet >/dev/null 2>&1 || true
  docker_as_target buildx create --name rsdk-hostnet --driver docker-container --driver-opt network=host --use
  docker_as_target buildx inspect --bootstrap
}

check_command_after_install() {
  local cmd="$1"
  local found

  found="$(PATH="/usr/sbin:/sbin:$PATH" command -v "$cmd" 2>/dev/null || true)"
  if [ "$found" != "" ]; then
    ok "$cmd is available."
  else
    die "$cmd is not available after install."
  fi
}

verify_docker() {
  info "Verifying Docker."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run: Docker verification skipped."
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet docker || die "Docker service is not active."
    ok "Docker service is active."
  fi

  if current_shell_has_group docker; then
    run_user docker ps
    if [ "$SKIP_DOCKER_HELLO" -eq 1 ]; then
      warn "Skipping docker hello-world basic execution check because --skip-docker-hello was used."
    else
      info "Running docker hello-world basic execution check. Container egress/DNS is tested separately with debian apt-get update."
      run_user docker run --rm hello-world
    fi
  else
    warn "Skipping unprivileged 'docker ps' because this shell has not picked up the docker group yet."
    warn "Reboot or log out/in, then run: $SCRIPT_NAME --check-only"
  fi
}

verify_rsdk() {
  info "Verifying RSDK and DevContainer CLI."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run: RSDK verification skipped."
    return 0
  fi

  [ -d "$RSDK_DIR/.git" ] || die "$RSDK_DIR is not a git repository."
  [ -x "$RSDK_DIR/src/bin/rsdk" ] || die "$RSDK_DIR/src/bin/rsdk is missing or not executable."

  export PATH="$RSDK_DIR/src/bin:$RSDK_DIR/node_modules/.bin:$PATH"

  local rsdk_path
  rsdk_path="$(command -v rsdk || true)"
  [ "$rsdk_path" = "$RSDK_DIR/src/bin/rsdk" ] || die "rsdk resolves to '$rsdk_path', expected '$RSDK_DIR/src/bin/rsdk'."
  ok "rsdk resolves to $rsdk_path."

  local devcontainer_path
  devcontainer_path="$(command -v devcontainer || true)"
  [ "$devcontainer_path" != "" ] || die "devcontainer CLI is not on PATH."
  ok "devcontainer resolves to $devcontainer_path."

  run_user_in_dir "$RSDK_DIR" git -c "safe.directory=$RSDK_DIR" submodule status --recursive

  if bashrc_contains_rsdk_path; then
    ok "$BASHRC_FILE contains an RSDK PATH block."
  else
    die "$BASHRC_FILE does not contain an RSDK PATH block."
  fi

  if rsdk_launcher_is_managed; then
    ok "$RSDK_LAUNCHER contains the managed RSDK launcher."
  else
    die "$RSDK_LAUNCHER does not contain the managed RSDK launcher."
  fi
}

verify_rsdk_devcon_node_heap_guard() {
  local file

  file="$(rsdk_devcon_script_path)"

  info "Verifying RSDK devcontainer launcher Node heap guard."

  [ -f "$file" ] || die "$file is missing."
  grep -q 'BEGIN rock5b host setup Node heap guard' "$file" || die "$file is missing the Node heap guard patch."
  grep -q 'max-old-space-size=${DEVCONTAINER_NODE_OLD_SPACE_MB:-8192}' "$file" || die "$file does not set the DevContainer Node heap limit."
  ok "$file sets NODE_OPTIONS before running devcontainer."
}

verify_devcontainer_json_config() {
  local file="$RSDK_DIR/.devcontainer/devcontainer.json"

  info "Verifying DevContainer JSON configuration."

  [ -f "$file" ] || die "$file is missing."
  command -v node >/dev/null 2>&1 || die "node is required to verify JSONC-like devcontainer.json."

  node - "$file" "$DEVCONTAINER_UID_PATCH_ENABLED" "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" "$DEVCONTAINER_KVM_GROUP_ADD" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const expectUpdateRemoteUidFalse = process.argv[3] === "1";
const expectHostNetwork = process.argv[4] === "1";
const expectKvmGroupAdd = process.argv[5];
function stripJsonc(input) {
  let out = "";
  let inString = false;
  let quote = "";
  let escaped = false;
  for (let i = 0; i < input.length; i++) {
    const ch = input[i];
    const next = input[i + 1];
    if (inString) {
      out += ch;
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === quote) inString = false;
      continue;
    }
    if (ch === '"' || ch === "'") {
      inString = true;
      quote = ch;
      out += ch;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (i < input.length && input[i] !== "\n") i++;
      out += "\n";
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      while (i < input.length && !(input[i] === "*" && input[i + 1] === "/")) i++;
      i++;
      continue;
    }
    out += ch;
  }
  return out.replace(/,\s*([}\]])/g, "$1");
}
const data = JSON.parse(stripJsonc(fs.readFileSync(path, "utf8")));
const runArgs = Array.isArray(data.runArgs) ? data.runArgs : [];
const hasHostNet = runArgs.some((value, index) => value === "--network" && runArgs[index + 1] === "host") || runArgs.includes("--network=host");
const hasKvmGroupAdd = expectKvmGroupAdd === "" || runArgs.some((value, index) => value === "--group-add" && String(runArgs[index + 1]) === expectKvmGroupAdd) || runArgs.includes(`--group-add=${expectKvmGroupAdd}`);
if (data.updateContentCommand !== "command -v devenv >/dev/null || true") {
  throw new Error("updateContentCommand is not the non-fatal devenv availability check");
}
if (expectUpdateRemoteUidFalse && data.updateRemoteUserUID !== false) {
  throw new Error("updateRemoteUserUID is not false");
}
if (expectHostNetwork && !hasHostNet) {
  throw new Error("runArgs does not include --network host");
}
if (!hasKvmGroupAdd) {
  throw new Error(`runArgs does not include --group-add ${expectKvmGroupAdd} for /dev/kvm`);
}
NODE
  ok "$file matches expected DevContainer updateContentCommand, UID, host-network, and KVM group settings."
}

verify_hostnet_buildx_builder() {
  [ "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" -eq 1 ] || return 0

  info "Verifying buildx builder rsdk-hostnet."
  docker_as_target buildx inspect rsdk-hostnet >/dev/null
  ok "buildx builder rsdk-hostnet exists."
}

verify_rsdk_patch_artifacts() {
  info "Verifying RSDK patch script and build helper."

  [ -x "$RSDK_DIR/$RSDK_PATCH_SCRIPT_NAME" ] || die "RSDK patch script is missing or not executable: $RSDK_DIR/$RSDK_PATCH_SCRIPT_NAME"
  [ -x "$RSDK_DIR/build-rock5b-bookworm-cli.sh" ] || die "Build helper is missing or not executable: $RSDK_DIR/build-rock5b-bookworm-cli.sh"

  run_user_in_dir "$RSDK_DIR" "./$RSDK_PATCH_SCRIPT_NAME" --rsdk-dir "$RSDK_DIR" --check-only
  ok "RSDK patch script and build helper are ready."
}

verify_rsdk_workspace_and_ownership() {
  if [ "$(id -u)" -eq 0 ]; then
    info "Verifying root-run RSDK workspace path."

    if [ "$ROOT_DEFAULT_RSDK_DIR" -eq 1 ] && [ -d /root/rsdk ] && [ ! -L /root/rsdk ] && [ ! -e "$RSDK_DIR" ]; then
      die "Unsafe root-owned RSDK checkout found at /root/rsdk. Rerun without --check-only to migrate it to /workspaces/rsdk, or move it manually."
    fi
    [ "$RSDK_DIR" != "/root/rsdk" ] || die "/root/rsdk is unsafe for RSDK DevContainer use; use /workspaces/rsdk."
  fi

  [ "$DEVCONTAINER_UID_PATCH_ENABLED" -eq 1 ] || return 0

  info "Verifying RSDK checkout access for DevContainer uid/gid ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}."

  [ -d "$RSDK_DIR" ] || die "$RSDK_DIR does not exist."
  [ -r "$RSDK_DIR/devenv.yaml" ] || warn "$RSDK_DIR/devenv.yaml is not readable or is absent."
  [ -x "$RSDK_DIR/src/bin/rsdk" ] || die "$RSDK_DIR/src/bin/rsdk is not executable."

  local owner
  owner="$(stat -c '%u:%g' "$RSDK_DIR")"
  if [ "$owner" != "${RSDK_OWNER_UID}:${RSDK_OWNER_GID}" ]; then
    die "$RSDK_DIR is owned by $owner, expected ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}."
  fi
  ok "$RSDK_DIR ownership matches DevContainer user ${RSDK_OWNER_UID}:${RSDK_OWNER_GID}."
}

verify_final_state() {
  info "Final verification."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run complete."
    return 0
  fi

  for cmd in git curl npm docker xz unzip make parted; do
    check_command_after_install "$cmd"
  done

  verify_docker
  verify_rsdk_workspace_and_ownership
  verify_rsdk
  verify_rsdk_devcon_node_heap_guard
  verify_devcontainer_json_config
  verify_hostnet_buildx_builder
  verify_rsdk_patch_artifacts
}

patch_rsdk_image_cmdline_fallback() {
  info "Patching RSDK image generation fallback for missing /etc/kernel/cmdline."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ patch RSDK image templates to derive cmdline from /boot/extlinux/extlinux.conf when /etc/kernel/cmdline is absent"
    return 0
  fi

  [ -d "$RSDK_DIR" ] || die "$RSDK_DIR does not exist; cannot patch RSDK image templates."
  command -v node >/dev/null 2>&1 || die "node is required to patch RSDK image templates."

  node - "$RSDK_DIR" <<'NODE'
const fs = require("fs");
const path = require("path");

const root = process.argv[2];
const files = [
  "src/share/rsdk/build/image.jsonnet",
  "src/share/rsdk/build/lib/image/deploy_rootfs.jsonnet",
];

const oldBlock = `copy-out /etc/kernel/cmdline "%(temp_dir)s"
    copy-out /boot/extlinux/extlinux.conf "%(temp_dir)s"`;

const newBlock = `copy-out /boot/extlinux/extlinux.conf "%(temp_dir)s"
    !awk '/^[[:space:]]*[Aa][Pp][Pp][Ee][Nn][Dd][[:space:]]+/ {sub(/^[[:space:]]*[Aa][Pp][Pp][Ee][Nn][Dd][[:space:]]+/, ""); print; found=1; exit} END{if (!found) exit 1}' "%(temp_dir)s/extlinux.conf" > "%(temp_dir)s/cmdline" || printf "rw rootwait console=ttyFIQ0,1500000 console=tty1\\n" > "%(temp_dir)s/cmdline"`;

let patched = 0;

for (const rel of files) {
  const file = path.join(root, rel);
  if (!fs.existsSync(file)) {
    throw new Error(`${rel} is missing`);
  }

  const original = fs.readFileSync(file, "utf8");
  const hasCmdlineFallback =
    original.includes(`copy-out /boot/extlinux/extlinux.conf "%(temp_dir)s"`) &&
    original.includes(`> "%(temp_dir)s/cmdline" || printf "rw rootwait console=ttyFIQ0,1500000 console=tty1`);

  if (original.includes(newBlock) || hasCmdlineFallback) {
    console.log(`already patched ${rel}`);
    continue;
  }

  if (!original.includes(oldBlock)) {
    throw new Error(`expected cmdline copy block not found in ${rel}`);
  }

  const backup = `${file}.bak-cmdline-fallback`;
  if (!fs.existsSync(backup)) {
    fs.copyFileSync(file, backup);
  }

  fs.writeFileSync(file, original.replace(oldBlock, newBlock));
  console.log(`patched ${rel}`);
  patched += 1;
}

console.log(`cmdline fallback patch complete; changed ${patched} file(s)`);
NODE

  ok "RSDK image templates will derive cmdline from extlinux.conf when /etc/kernel/cmdline is absent."
}

install_and_run_rsdk_patch_script() {
  local target="$RSDK_DIR/$RSDK_PATCH_SCRIPT_NAME"

  info "Installing and running RSDK ROCK 5B Bookworm patch script."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ install $(printf '%q' "$RSDK_PATCH_SCRIPT_SOURCE") $(printf '%q' "$target")"
    info "+ cd $(printf '%q' "$RSDK_DIR") && ./$(printf '%q' "$RSDK_PATCH_SCRIPT_NAME") --rsdk-dir $(printf '%q' "$RSDK_DIR")"
    return 0
  fi

  [ -f "$RSDK_PATCH_SCRIPT_SOURCE" ] || die "Missing patch script next to host setup script: $RSDK_PATCH_SCRIPT_SOURCE"
  [ -d "$RSDK_DIR" ] || die "$RSDK_DIR does not exist; cannot install RSDK patch script."

  install -m 0755 "$RSDK_PATCH_SCRIPT_SOURCE" "$target"
  run_user_in_dir "$RSDK_DIR" "./$RSDK_PATCH_SCRIPT_NAME" --rsdk-dir "$RSDK_DIR"
  [ -x "$RSDK_DIR/build-rock5b-bookworm-cli.sh" ] || die "RSDK patch script did not create executable build-rock5b-bookworm-cli.sh."

  ok "RSDK patch script and build helper are installed in $RSDK_DIR."
}

start_rsdk_devcontainer() {
  local env_args=(
    "PATH=$RSDK_DIR/src/bin:$RSDK_DIR/node_modules/.bin:$PATH"
  )
  local env_display=""
  local arg
  local node_options

  info "Starting the RSDK DevContainer with 'rsdk devcon up'."

  node_options="$(node_options_with_devcontainer_heap)"
  if [ "$node_options" != "" ]; then
    env_args+=("NODE_OPTIONS=$node_options")
  fi

  if [ "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" -eq 1 ]; then
    env_args+=(
      "BUILDX_BUILDER=rsdk-hostnet"
      "DOCKER_BUILDKIT=1"
      "BUILDKIT_PROGRESS=plain"
    )
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "+ cd $(printf '%q' "$RSDK_DIR") && env ${env_args[*]} rsdk devcon up"
    return 0
  fi

  for arg in "${env_args[@]}"; do
    env_display="${env_display} $(printf '%q' "$arg")"
  done
  info "+ cd $(printf '%q' "$RSDK_DIR") && env${env_display} rsdk devcon up"

  if [ "$(id -u)" -eq 0 ]; then
    if [ "$TARGET_USER" = "root" ]; then
      (
        cd "$RSDK_DIR"
        env "${env_args[@]}" rsdk devcon up
      )
    else
      (
        cd "$RSDK_DIR"
        sudo -H -u "$TARGET_USER" env "${env_args[@]}" rsdk devcon up
      )
    fi
  elif current_shell_has_group docker; then
    (
      cd "$RSDK_DIR"
      env "${env_args[@]}" rsdk devcon up
    )
  else
    (
      cd "$RSDK_DIR"
      sudo -H -u "$TARGET_USER" env "${env_args[@]}" rsdk devcon up
    )
  fi
  ok "RSDK DevContainer startup completed successfully."
}

maybe_reboot() {
  if [ "$CHECK_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if [ "$NEEDS_RELOGIN" -eq 0 ]; then
    return 0
  fi

  warn "A reboot or logout/login is still needed before normal Docker commands work without sudo."
  warn "The managed rsdk launcher can still use fresh group membership for 'rsdk devcon'."

  if [ "$REBOOT_IF_NEEDED" -eq 1 ]; then
    warn "Rebooting now will stop the DevContainer that was just started."
    confirm_or_die "Reboot now to activate Docker group membership?"
    run_root systemctl reboot
  else
    info "After a later reboot/login, you can verify the host setup with:"
    info "  $SCRIPT_NAME --check-only"
  fi
}

print_next_commands() {
  info "Next command:"
  info "  cd $RSDK_DIR"
  if [ "$DEVCONTAINER_HOSTNET_WORKAROUND_ENABLED" -eq 1 ]; then
    info "  export BUILDX_BUILDER=rsdk-hostnet"
    info "  export DOCKER_BUILDKIT=1"
    info "  export BUILDKIT_PROGRESS=plain"
  fi
  info "  rsdk devcon"
  info "The DevContainer has already been started by this script."
}

main() {
  parse_args "$@"
  resolve_target_user
  evaluate_devcontainer_uid_patch
  resolve_rsdk_owner
  setup_logging
  print_config
  check_host_basics
  check_free_space

  if [ "$CHECK_ONLY" -eq 1 ]; then
    export PATH="$RSDK_DIR/src/bin:$RSDK_DIR/node_modules/.bin:$PATH"
    detect_devcontainer_owner_from_image
    configure_kvm_access
    evaluate_docker_network
    finalize_devcontainer_uid_patch_after_network
    verify_final_state
    ok "Check-only verification finished."
    exit 0
  fi

  install_host_dependencies
  configure_docker
  detect_devcontainer_owner_from_image
  configure_kvm_access
  evaluate_docker_network
  finalize_devcontainer_uid_patch_after_network
  clone_or_update_rsdk
  patch_rsdk_image_cmdline_fallback
  install_and_run_rsdk_patch_script
  install_devcontainer_cli_and_path
  apply_devcontainer_json_patches
  patch_rsdk_devcon_node_heap_guard
  setup_hostnet_buildx_builder
  append_hostnet_buildx_env_to_bashrc
  fix_rsdk_checkout_ownership
  verify_final_state
  maybe_reboot
  start_rsdk_devcontainer
  print_next_commands

  ok "Steps 1-4 are complete. The RSDK DevContainer is up; enter it with 'rsdk devcon'."
}

main "$@"
