# Radxa Images - installation

## 1.

Download the latest version of this repository and install required tools.

**On Linux (Debian / Ubuntu):**

Log in as a user with `sudo` access and then run in terminal:

```sh
sudo apt update
sudo apt -y upgrade
sudo apt -y install git curl ca-certificates

git clone https://github.com/libersoft-org/radxa-images.git
cd radxa-images
```

This repository is intended for a Debian-based build host. The build itself uses
RSDK and Docker, so make sure you have enough free space before continuing.

```text
Minimum free space: 40 GB
Recommended free space: 60 GB or more
Comfortable free space: 100 GB for repeated builds and cached layers
```

## 2.

Prepare the build host and start the RSDK DevContainer.

The shared setup script handles the host-side work: required packages, Docker,
RSDK checkout, DevContainer CLI, host PATH/launcher configuration, compatibility
settings, and `rsdk devcon up`.

```sh
chmod +x scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh

scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh
```

If the script says Docker group membership needs a reboot or a new login, do
that before continuing. After reboot/login, verify the setup:

```sh
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --check-only
```

Useful options:

```sh
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --dry-run
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --yes
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --skip-apt-upgrade
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --skip-docker-hello
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --skip-docker-network-test
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --force-devcontainer-hostnet-workaround
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --no-devcontainer-hostnet-workaround
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --allow-kvm-world-access
scripts/rsdk_setup/bookworm_rsdk_host_steps_1_4.sh --reboot-if-needed
```

## 3.

Patch RSDK for the selected board and build the image.

### a) ROCK 5B Bookworm CLI

Patch the host-side RSDK checkout:

```sh
chmod +x scripts/rock_5b/rock5b_bookworm_patch_rsdk.sh

scripts/rock_5b/rock5b_bookworm_patch_rsdk.sh --rsdk-dir ~/rsdk
```

Enter the already-started DevContainer:

```sh
cd ~/rsdk
rsdk devcon
```

Inside the DevContainer:

```sh
cd /workspaces/rsdk
./build-rock5b-bookworm-cli.sh
```

Optional, enable default root access in the built image:

```sh
./set-rock5b-default-root.sh
```

This sets:

```text
root password: root
SSH root login: enabled
tty1 root autologin: enabled
```

The output image is created here:

```text
~/rsdk/out/rock-5b_bookworm_cli/output.img
```

### b) Radxa ZERO 3W / ZERO 3 Bookworm CLI

Patch the host-side RSDK checkout:

```sh
chmod +x scripts/zero_3w/radxa_zero3w_bookworm_patch_rsdk.sh

scripts/zero_3w/radxa_zero3w_bookworm_patch_rsdk.sh --rsdk-dir ~/rsdk
```

Enter the already-started DevContainer:

```sh
cd ~/rsdk
rsdk devcon
```

Inside the DevContainer:

```sh
cd /workspaces/rsdk
./build-radxa-zero3-bookworm-cli.sh
```

The output image is created here:

```text
~/rsdk/out/radxa-zero3_bookworm_cli/output.img
```

## 4.

Flash the image manually.

The setup and patch scripts do not flash SD cards. Check the target-specific
guide before writing to removable media.

```text
WARNING:
The SD card will be completely overwritten.
In examples, the SD card is usually shown as /dev/sdX or /dev/mmcblkX.
Never run dd against your system disk.
```

Detailed build, customization, compression, checksum, and flashing notes:

- [**ROCK 5B Bookworm CLI image guide**](./scripts/rock_5b/rock5b_bookworm_cli_repo_readme_en.md)
- [**Radxa ZERO 3W / ZERO 3 Bookworm CLI image guide**](./scripts/zero_3w/radxa_zero3w_bookworm_cli_repo_readme_en.md)
