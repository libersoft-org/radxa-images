# Radxa Images

## Table of contents

- [**About**](#about)
- [**Supported images**](#supported-images)
- [**Key features**](#key-features)
- [**Documentation**](#documentation)
- [**Installation**](#installation)
- [**License**](#license)
- [**Contribution**](#contribution)

## About

**Radxa Images** is a small collection of scripts for building Debian Bookworm
CLI images for selected Radxa boards using [**RSDK**](https://github.com/RadxaOS-SDK/rsdk).

The goal is simple: start from a clean Debian-based build host, prepare RSDK in
a repeatable way, apply the board-specific patches needed for CLI builds, and
produce an image that can be flashed to an SD card.

No TUI. Console commands only.

## Supported images

- **ROCK 5B Bookworm CLI**
- **Radxa ZERO 3W / ZERO 3 Bookworm CLI** using the RSDK target `radxa-zero3`

## Key features

**Radxa Images** keeps the build flow boring in the best possible way.

### Shared RSDK host setup

- Installs host dependencies on Debian-based systems.
- Configures Docker access and verifies the basic Docker environment.
- Clones or updates RSDK with submodules.
- Installs the DevContainer CLI and prepares the host-side `rsdk` launcher.
- Starts the RSDK DevContainer.

### Board-specific RSDK patches

- Enables CLI builds for supported Radxa targets when the upstream RSDK checkout
  does not expose them directly.
- Applies the Jsonnet/package fixes needed for the current CLI image workflow.
- Creates board-specific build helper scripts inside the RSDK checkout.

### Reproducible command-line workflow

- Supports `--dry-run` and `--check-only` modes where useful.
- Keeps flashing separate from building, so the SD card is never touched by the
  setup scripts.
- Includes detailed per-board notes for build output, optional rootfs changes,
  compression, checksums, and flashing.

## Documentation

- [**Installation**](./INSTALL.md) - Short installation and build flow
- [**ROCK 5B Bookworm CLI image guide**](./scripts/rock_5b/rock5b_bookworm_cli_repo_readme_en.md)
- [**Radxa ZERO 3W / ZERO 3 Bookworm CLI image guide**](./scripts/zero_3w/radxa_zero3w_bookworm_cli_repo_readme_en.md)

## Installation

- For installation instructions follow [**this document**](./INSTALL.md).

## License

- This repository does not include a license file yet.

## Contribution

If you are interested in improving these scripts, issues and pull requests are
welcome once the public repository is available.
