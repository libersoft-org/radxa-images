# Radxa ZERO 3W / ZERO 3 Bookworm CLI Image via RSDK

Goal: build a Radxa ZERO 3W / ZERO 3 Bookworm CLI image from a clean Debian host using RSDK, optionally customize the rootfs, compress the release asset, and flash the image to an SD card.

No TUI. Console commands only.

RSDK uses the product target `radxa-zero3` for this workflow. That target covers
the tested Radxa ZERO 3W path and builds into:

```text
~/rsdk/out/radxa-zero3_bookworm_cli/output.img
```

---

## Scripted Host Setup for Steps 1-4

For sections 1-4, use the shared RSDK host setup script instead of running each
command manually. This host setup is target-agnostic: it prepares Docker,
clones/updates RSDK, installs the DevContainer CLI, applies generic RSDK
compatibility fixes, and starts the DevContainer. The Radxa ZERO 3W / ZERO 3
specific part is the separate patch script that runs after host setup.

```bash
chmod +x \
  bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh \
  bookworm_complete_install_guide/radxa_zero3w_bookworm_patch_rsdk.sh

bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh

bookworm_complete_install_guide/radxa_zero3w_bookworm_patch_rsdk.sh --rsdk-dir ~/rsdk
```

The script also supports being run directly as `root`; in that case it targets
`/workspaces/rsdk` by default instead of `/root/rsdk`, because the RSDK
DevContainer normally runs as user `vscode`.

The host setup script installs a managed `/usr/local/bin/rsdk` launcher,
prepares the checkout, and starts the DevContainer with `rsdk devcon up`. The
Radxa ZERO 3W / ZERO 3 patch script then patches that checkout and creates the
Zero 3 build helper inside RSDK. After both commands finish, the next
DevContainer command is only `rsdk devcon`.

If the script says Docker group membership needs a reboot or new login, do that before normal manual Docker work. After reboot/login, verify the host setup with:

```bash
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --check-only
```

Useful options:

```bash
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --dry-run
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --yes
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --skip-apt-upgrade
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --skip-docker-hello
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --skip-docker-network-test
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --force-devcontainer-hostnet-workaround
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --no-devcontainer-hostnet-workaround
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --allow-kvm-world-access
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --reboot-if-needed
```

If `/dev/kvm` exists, the setup script reports whether KVM acceleration is
available for libguestfs image assembly and adds the DevContainer to the
device's group id with `--group-add`. On disposable single-user build VMs, use
`--allow-kvm-world-access` to apply `chmod 0666 /dev/kvm` immediately instead
of waiting for group membership to take effect.

## Enter the DevContainer and Build

After the scripted host setup and Radxa ZERO 3W / ZERO 3 RSDK patch have
completed, enter the already-started DevContainer. For a normal user the
checkout is usually `~/rsdk`; for a direct root run it is `/workspaces/rsdk`.

```bash
cd ~/rsdk
rsdk devcon
```

Inside the devcontainer:

```bash
cd /workspaces/rsdk
./build-radxa-zero3-bookworm-cli.sh
```

Do not run `./build-rock5b-bookworm-cli.sh` for this workflow.

The Radxa ZERO 3W / ZERO 3 patch script modifies the host-side RSDK checkout.
Since the checkout is mounted as `/workspaces/rsdk`, the container sees the
patched files and the Zero 3 build helper. The build helper installs required
container dependencies and runs:

```bash
rsdk build radxa-zero3 bookworm cli
```

Flashing SD remains manual and separate.

---

## 0. Prerequisites

```text
Host PC: Debian 12/13 or Debian-based Linux
Host architecture: x86_64
Free space:
  Minimum: 40 GB
  Recommended: 60 GB or more
  Comfortable: 100 GB, especially if keeping Docker layers, intermediate files,
  compressed release artifacts, logs, or multiple builds.
Access: sudo user
Media: SD card + card reader
Internet: stable connection
```

The final build output is much smaller than 100 GB, but temporary build data,
Docker/devcontainer layers, rootfs archives, package caches, and repeated builds
need additional free space.

```text
WARNING:
The SD card will be completely overwritten.
In the commands below, the SD card is shown as /dev/sdX or /dev/mmcblkX.
Never run dd against your system disk.
```

---

## 1. Host Dependencies

On the host PC:

```bash
sudo apt update
sudo apt upgrade -y

sudo apt install -y \
  git \
  curl \
  ca-certificates \
  qemu-user-static \
  binfmt-support \
  npm \
  docker.io \
  xz-utils \
  unzip \
  build-essential \
  util-linux \
  coreutils \
  pv \
  parted
```

---

## 2. Docker Permissions

On the host PC:

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
sudo reboot
```

After reboot:

```bash
docker ps
docker run --rm hello-world
```

---

## 3. Clone RSDK

On the host PC:

```bash
cd ~

git clone --recurse-submodules https://github.com/RadxaOS-SDK/rsdk.git

cd ~/rsdk

git submodule sync --recursive
git submodule update --init --recursive --force
git submodule status --recursive
```

`git submodule update` must finish without interruption.

---

## 4. DevContainer CLI and RSDK PATH on the Host

On the host PC:

```bash
cd ~/rsdk

npm install @devcontainers/cli

export PATH="$PWD/src/bin:$PWD/node_modules/.bin:$PATH"

grep -q 'RSDK PATH' ~/.bashrc || cat >> ~/.bashrc <<'BASHRC_EOF'

# RSDK PATH
if [ -d "$HOME/rsdk" ]; then
  export PATH="$HOME/rsdk/src/bin:$HOME/rsdk/node_modules/.bin:$PATH"
fi
BASHRC_EOF

sudo tee /usr/local/bin/rsdk >/dev/null <<'RSDK_LAUNCHER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
RSDK_DIR="${RSDK_DIR:-$HOME/rsdk}"
TARGET_USER="${SUDO_USER:-$USER}"
export PATH="$RSDK_DIR/src/bin:$RSDK_DIR/node_modules/.bin:$PATH"
if [ "${1:-}" = "devcon" ] && [ "$(id -u)" -ne 0 ] && ! docker ps >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  exec sudo -H -u "$TARGET_USER" env "PATH=$PATH" "$RSDK_DIR/src/bin/rsdk" "$@"
fi
exec "$RSDK_DIR/src/bin/rsdk" "$@"
RSDK_LAUNCHER_EOF
sudo chmod 0755 /usr/local/bin/rsdk

which rsdk

rsdk devcon up
```

Expected output:

```text
/home/YOUR_USER/rsdk/src/bin/rsdk
```

If you use a fresh shell without the exported PATH above, `which rsdk` may
print `/usr/local/bin/rsdk`; that is also correct.

If `rsdk devcon up` prints `Container started` and does not return to the
prompt, press `Ctrl+C`. This usually does not stop the container.

---

## 5. Enter the RSDK DevContainer

On the host PC:

```bash
cd ~/rsdk

rsdk devcon
```

After entering, the prompt should look similar to:

```text
vscode -> /workspaces/rsdk
```

---

## Troubleshooting: Broken Docker bridge networking and root-owned RSDK checkout

Some Debian VM/template environments have a working Docker daemon but broken
default bridge networking. Symptoms include:

```text
rsdk devcon up hangs at Ign: http://deb.debian.org...
Temporary failure resolving 'deb.debian.org'
Permission denied on devenv.yaml, .devenv/gc, src/bin/rsdk, or utils.sh
```

Diagnose the Docker networking case on the host:

```bash
docker run --rm debian:bookworm bash -lc 'apt-get update'
docker run --rm --network host debian:bookworm bash -lc 'apt-get update'
```

If the first command fails or hangs but the second succeeds, Docker image pulls
and host networking work, but Docker bridge/NAT/DNS is broken. The host setup
script tests this with timeouts, disables apt retries for the test, and forcibly
removes timed-out test containers named `radxa-zero3w-nettest-bridge-*` or
`radxa-zero3w-nettest-host-*`.

When the bridge test fails and the host-network test succeeds, the script can
apply the affected-VM workaround:

```bash
bookworm_complete_install_guide/bookworm_rsdk_host_steps_1_4.sh --force-devcontainer-hostnet-workaround
```

In automatic mode, the script applies the workaround only when it detects the
broken bridge / working host-network pattern. It patches
`.devcontainer/devcontainer.json` idempotently so `runArgs` includes
`"--network", "host"` and `updateRemoteUserUID` is `false`, creates the buildx
builder `rsdk-hostnet` with `--driver docker-container --driver-opt network=host`,
and adds this shell block once:

```bash
# RSDK HOSTNET BUILDX WORKAROUND
export BUILDX_BUILDER=rsdk-hostnet
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
```

If the script is run directly as `root`, `/root/rsdk` is unsafe because the
DevContainer uses the `vscode` user by default. The setup script now uses
`/workspaces/rsdk`, creates `/workspaces` with mode `755`, migrates an existing
real `/root/rsdk` there when safe, leaves `/root/rsdk` as a convenience symlink,
and fixes the checkout for the DevContainer uid/gid, normally `1000:1000`.

This workaround is for affected VM/templates only. Do not treat it as normal
Docker configuration. In particular, do not configure the Docker daemon with
`DOCKER_OPTS=--default-network=host`; that can break Docker startup on Debian
`docker.io` 26.1.5. Also do not force `remoteUser=root` by default. The intended
working DevContainer prompt is:

```text
vscode -> /workspaces/rsdk
```

The setup script does not run the final RSDK image build and does not flash SD
cards.

---

## 6. Container PATH

You are now inside the container.

```bash
cd /workspaces/rsdk

export PATH="/usr/sbin:/sbin:/workspaces/rsdk/src/bin:/workspaces/rsdk/node_modules/.bin:$PATH"

grep -q 'RSDK CONTAINER PATH' ~/.bashrc || cat >> ~/.bashrc <<'BASHRC_EOF'

# RSDK CONTAINER PATH
if [ -d "/workspaces/rsdk" ]; then
  export PATH="/usr/sbin:/sbin:/workspaces/rsdk/src/bin:/workspaces/rsdk/node_modules/.bin:$PATH"
fi
BASHRC_EOF

which rsdk
```

Expected output:

```text
/workspaces/rsdk/src/bin/rsdk
```

Important: `/usr/sbin:/sbin` is required for tools such as `sgdisk`.

---

## 7. Container Dependencies

Inside the container:

```bash
cd /workspaces/rsdk

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
```

Verify:

```bash
cd /workspaces/rsdk

export PATH="/usr/sbin:/sbin:/workspaces/rsdk/src/bin:/workspaces/rsdk/node_modules/.bin:$PATH"

which jsonnet
which bdebstrap
which mmdebstrap
which guestfish
which sgdisk
which parted
which mkfs.vfat
which mkfs.ext4
```

---

## 8. RSDK Patch: Enable CLI for Radxa ZERO 3W / ZERO 3

The actual RSDK product target is `radxa-zero3`, covering Radxa ZERO 3W / ZERO
3. The current RSDK `main` branch may not include `cli` for `radxa-zero3` in
`products.json`. Add it locally.

Inside the container:

```bash
cd /workspaces/rsdk

python3 - <<'PY'
import json
from pathlib import Path

p = Path("src/share/rsdk/configs/products.json")
data = json.loads(p.read_text())

for x in data:
    if x.get("product") == "radxa-zero3":
        ed = x.setdefault("supported_edition", [])
        if "cli" not in ed:
            ed.append("cli")
        print(json.dumps(x, indent=2))

p.write_text(json.dumps(data, indent=4) + "\n")
PY
```

---

## 9. RSDK Patch: Fix `soc_install_recommends`

Without this patch, the build may fail on older Jsonnet with:

```text
RUNTIME ERROR: field does not exist: all
```

The CLI build must also install the product task without recommended vendor
packages. This avoids vendor recommends pulling DKMS packages into the
mmdebstrap rootfs chroot.

Inside the container:

```bash
cd /workspaces/rsdk

cat > src/share/rsdk/configs/soc_install_recommends.libjsonnet <<'EOF'
local soc_family_list = import "soc_family_list.libjsonnet";

function(soc_array, suite)
  local check_recommends(soc) = (
    local family = soc_family_list(soc);

    std.objectHas(family, "soc_install_recommends") &&
    std.member(family.soc_install_recommends, suite)
  );

  std.length(std.filter(check_recommends, soc_array)) == std.length(soc_array)
EOF

cat > src/share/rsdk/build/mod/packages/cli.libjsonnet <<'EOF'
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
```

---

## 10. Build the Radxa ZERO 3W / ZERO 3 Bookworm CLI Image

Inside the container:

```bash
cd /workspaces/rsdk

export PATH="/usr/sbin:/sbin:/workspaces/rsdk/src/bin:/workspaces/rsdk/node_modules/.bin:$PATH"

rm -rf out/radxa-zero3_bookworm_cli

rsdk build radxa-zero3 bookworm cli
```

Output:

```text
/workspaces/rsdk/out/radxa-zero3_bookworm_cli/output.img
/workspaces/rsdk/out/radxa-zero3_bookworm_cli/rootfs.tar
/workspaces/rsdk/out/radxa-zero3_bookworm_cli/seed.tar.xz
/workspaces/rsdk/out/radxa-zero3_bookworm_cli/build-image
```

Verify:

```bash
cd /workspaces/rsdk

ls -lh out/radxa-zero3_bookworm_cli
ls -lh out/radxa-zero3_bookworm_cli/output.img
```

---

## 11. Optional: Set Default root/root in the rootfs

This step is optional. Use it only for development or provisioning images.

Result:

```text
root password: root
SSH root login: enabled
tty1 root autologin: enabled
```

Inside the container:

```bash
cd /workspaces/rsdk/out/radxa-zero3_bookworm_cli

rm -rf rootfs-edit

mkdir -p rootfs-edit

sudo tar -xf rootfs.tar -C rootfs-edit

sudo chroot rootfs-edit /bin/bash -c 'echo "root:root" | chpasswd'
sudo chroot rootfs-edit /bin/bash -c 'passwd -u root || true'
sudo chroot rootfs-edit /bin/bash -c 'usermod -s /bin/bash root'

sudo mkdir -p rootfs-edit/etc/ssh/sshd_config.d

sudo tee rootfs-edit/etc/ssh/sshd_config.d/99-root-login.conf >/dev/null <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

sudo chroot rootfs-edit /bin/bash -c 'systemctl enable ssh || true'

sudo mkdir -p rootfs-edit/etc/systemd/system/getty@tty1.service.d

sudo tee rootfs-edit/etc/systemd/system/getty@tty1.service.d/override.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

sudo chroot rootfs-edit /bin/bash -c 'systemctl enable getty@tty1.service || true'

sudo tee rootfs-edit/etc/issue >/dev/null <<'EOF'
Radxa ZERO 3W / ZERO 3 Bookworm CLI

Default login:
  user: root
  pass: root

CHANGE THIS PASSWORD IMMEDIATELY.

EOF

mv rootfs.tar rootfs.tar.before-root-default

sudo tar --numeric-owner -cpf rootfs.tar -C rootfs-edit .

sudo rm -rf rootfs-edit

ls -lh rootfs.tar rootfs.tar.before-root-default
```

Generate a new `output.img` from the modified `rootfs.tar`:

```bash
cd /workspaces/rsdk/out/radxa-zero3_bookworm_cli

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

rm -f output.img

./build-image

ls -lh output.img
```

## 12. Leave the Container

Inside the container:

```bash
exit
```

You are now back on the host PC.

---

## 13. Set the Image Path on the Host

On the host PC:

```bash
cd ~/rsdk

IMG="$HOME/rsdk/out/radxa-zero3_bookworm_cli/output.img"

ls -lh "$IMG"
```

---

## 14. Find the SD Card

On the host PC, before inserting the SD card:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINTS
```

Insert the SD card.

After inserting it:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINTS
```

Set `SD` to the new disk.

Example for a USB card reader:

```bash
SD=/dev/sdb
```

Example for an internal SD card reader:

```bash
SD=/dev/mmcblk0
```

Verify:

```bash
echo "IMG=$IMG"
echo "SD=$SD"

lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINTS "$SD"
```

`SD` must be the whole disk, not a partition.

Correct:

```text
/dev/sdb
/dev/mmcblk0
```

Wrong:

```text
/dev/sdb1
/dev/mmcblk0p1
```

---

## 15. Unmount the SD Card

On the host PC:

```bash
lsblk -ln -o NAME "$SD" | tail -n +2 | while read p; do
  sudo umount "/dev/$p" 2>/dev/null || true
done

lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINTS "$SD"
```

---

## 17. Flash the Image to the SD Card

On the host PC:

```bash
echo "FLASHING:"
echo "  IMG=$IMG"
echo "  SD=$SD"

lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINTS "$SD"

sudo dd if="$IMG" of="$SD" bs=16M status=progress conv=fsync

sync

sudo blockdev --flushbufs "$SD" || true

sync
```

Alternative using `pv`:

```bash
sudo sh -c "pv '$IMG' > '$SD'"

sync

sudo blockdev --flushbufs "$SD" || true

sync
```

Use only one method.

---

## 18. Check the SD Card After Flashing

On the host PC:

```bash
sudo partprobe "$SD" || true

sleep 2

lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINTS "$SD"

sudo fdisk -l "$SD" | head -80
```

---

## 19. Safely Eject the SD Card

On the host PC:

```bash
sync

sudo eject "$SD" 2>/dev/null || true
```

Then remove the SD card.

---

## 20. Done

Result:

```text
RSDK build output:
  ~/rsdk/out/radxa-zero3_bookworm_cli/output.img
  ~/rsdk/out/radxa-zero3_bookworm_cli/output.img.xz
  ~/rsdk/out/radxa-zero3_bookworm_cli/SHA256SUMS

SD card:
  contains the Radxa ZERO 3W / ZERO 3 Bookworm CLI image
  is unmounted
  has been safely ejected
```
