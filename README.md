# Omarchy Remote

Remote desktop for [Omarchy](https://omarchy.org) (Hyprland) with a native Mac app.

**Colour is lossless.** The Mac app only speaks lossless encodings (ZRLE, CopyRect, Raw) at full 24-bit colour, so there's no JPEG blocking, no chroma subsampling and no washed-out "satellite feed" look. Frames are tagged sRGB, so macOS colour-manages them correctly on P3/XDR displays, and the window opens at one remote pixel per Mac pixel when it fits. `tests/e2e.sh` checks that a test pattern arrives bit-for-bit identical.

## Install

On the Omarchy machine:

```bash
curl -fsSL https://raw.githubusercontent.com/thesnarkitecht/omarchy-remote-desktop/main/install.sh | bash
```

On the Mac (builds from source; needs Xcode Command Line Tools):

```bash
curl -fsSL https://raw.githubusercontent.com/thesnarkitecht/omarchy-remote-desktop/main/install-mac.sh | bash
```

Then authorise your Mac's SSH key once and connect to `user@host` in the app:

```bash
ssh-copy-id you@omarchy-host
```

## How it works

- **Omarchy:** `install.sh` installs `wayvnc` and runs it as a systemd user service bound to `127.0.0.1:5900`, so it is never reachable from the network. It enables `sshd` and, if ufw is on, allows SSH only from LAN and Tailscale ranges.
- **Mac:** the app opens an SSH tunnel (your keys, your `~/.ssh/config`) and draws the desktop with a small Swift VNC client (`mac/Sources/RFB`).
- **Keys:** Cmd is sent as Super, so Hyprland bindings work. While the window is focused, every shortcut goes to Omarchy; use the menu bar or the window's close button to disconnect. macOS keeps Cmd-Tab and Cmd-Space for itself.
- Clipboard text syncs both ways. The green button gives you full screen.

## Uninstall (Omarchy)

```bash
systemctl --user disable --now omarchy-remote && rm ~/.config/systemd/user/omarchy-remote.service
```
