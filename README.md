# wsl2-bridge-rs

Small Rust utility that bridges Windows named pipes and TCP sockets into WSL2, allowing OpenSSH and GnuPG agent traffic to flow transparently between environments. The relay executable always targets Windows (producing a `.exe`) because it must access Windows named pipes, but it is invoked from WSL2 via the mounted Windows filesystem.

## Bootstrap

The quickest way to get started from inside WSL2:

```bash
curl -fsSL https://raw.githubusercontent.com/ArturoGuerra/wsl2-bridge-rs/main/scripts/bootstrap.sh | bash
```

To pass options, use `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/ArturoGuerra/wsl2-bridge-rs/main/scripts/bootstrap.sh | bash -s -- --bin-dir /mnt/d/tools --scope user
```

Or if you've already cloned the repo:

```bash
bash scripts/bootstrap.sh
```

This downloads the latest release binary to `/mnt/c/tools/` and installs the systemd user services. Options:

```
--bin-dir /mnt/c/tools   Directory to place the binary (default: /mnt/c/tools)
--scope   user|system    Systemd install scope (default: user)
```

After installing, add this to your `~/.bashrc` or `~/.zshrc` if `SSH_AUTH_SOCK` is not already set:

```bash
export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent.sock
```

## Releases

Pre-built binaries are published automatically via GitHub Actions on version tags. To download manually, grab `wsl2-bridge-rs.exe` from the [latest release](../../releases/latest).

## Manual setup

### Build

- From WSL/Linux: `cargo build --release --target x86_64-pc-windows-gnu`
- From Windows: `cargo build --release`

The binary is placed at `target/<target-triplet>/release/wsl2-bridge-rs.exe`.

### Use

- **SSH agent relay:** `wsl2-bridge-rs.exe pipe --name //./pipe/openssh-ssh-agent [--poll]`
  - `--poll` makes the relay wait until the pipe is available rather than failing immediately.
- **GnuPG relay:** `wsl2-bridge-rs.exe gpg --socket S.gpg-agent`
  - Reads `%LOCALAPPDATA%\gnupg\<socket>`, parses the port and nonce, then mirrors stdin/stdout to that TCP endpoint.

Reference the binary from WSL via its mount path, e.g. `/mnt/c/tools/wsl2-bridge-rs.exe`.

### Install services

```bash
# Current user only
bash scripts/systemd-manage.sh install

# System-wide (all users)
sudo bash scripts/systemd-manage.sh install --scope system

# Custom binary location
bash scripts/systemd-manage.sh install --bin-path /mnt/d/tools/wsl2-bridge-rs.exe
```

Requires systemd to be enabled in WSL2 and `socat` to be installed.

### Uninstall services

```bash
bash scripts/systemd-manage.sh uninstall
sudo bash scripts/systemd-manage.sh uninstall --scope system
```
