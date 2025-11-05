# wsl2-bridge-rs

Small Rust utility that bridges Windows named pipes and TCP sockets into WSL2, allowing OpenSSH and GnuPG agent traffic to flow transparently between environments. The relay executable always targets Windows (producing a `.exe`) because it must access Windows named pipes, but it can be invoked from WSL using the mounted Windows filesystem.

## Docs

### Build
- Install a recent Rust toolchain (stable works fine) on Windows, or install cross-compilation targets if you are building from WSL/Linux.
- Build the Windows binary with release optimizations:
  - From Windows: `cargo build --release`.
  - From WSL/Linux: `cargo build --release --target x86_64-pc-windows-gnu` (or your preferred Windows target).
- The resulting executable is always placed under `target/<windows-target-triplet>/release/wsl2-bridge-rs.exe`. When building from Windows without an explicit target, the triplet defaults to `x86_64-pc-windows-msvc`.

### Use
- SSH agent pipe relay: `wsl2-bridge-rs.exe pipe --name //./pipe/openssh-ssh-agent --poll`
  - `--name` is the Windows named pipe exposed by the host OpenSSH agent.
  - Add `--poll` if you want the relay to wait until the pipe becomes available.
- GnuPG TCP relay: `wsl2-bridge-rs.exe gpg --socket extra_socket`
  - Looks for `%LOCALAPPDATA%\gnupg\extra_socket`, reads the forwarded port and nonce, then mirrors stdin/stdout to that TCP endpoint.
  - Works with the standard `gpg-agent --extra-socket` forwarding setup on Windows.
- When starting the relay from inside WSL, reference the Windows binary via the mounted path (e.g. `/mnt/c/path/to/wsl2-bridge-rs.exe ...`) or call it through `wsl.exe -- /mnt/c/.../wsl2-bridge-rs.exe`.

### Install
- Copy the systemd user units from `systemd/` with the helper script: `bash scripts/systemd-manage.sh install`.
- For global availability (e.g. in `/etc/systemd/user`), escalate: `sudo bash scripts/systemd-manage.sh install --scope system`, then log in to each user session and run `systemctl --user daemon-reload`.
- Ensure systemd is enabled for your WSL distro (WSL systemd support must be active) and that `socat` is available since the units rely on it.

### Uninstall
- Remove per-user units: `bash scripts/systemd-manage.sh uninstall`.
- Remove global units: `sudo bash scripts/systemd-manage.sh uninstall --scope system`, followed by `systemctl --user daemon-reload` in active sessions.
- After uninstalling you may stop any running relays manually with `systemctl --user stop ssh-agent-relay.service` (and similar) if they continue to run in existing sessions.
