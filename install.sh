#!/usr/bin/env bash
# curl -fsSL https://raw.githubusercontent.com/thesnarkitecht/omarchy-remote-desktop/main/install.sh | bash
# Omarchy side: wayvnc on 127.0.0.1 only (never exposed), reached from the Mac over SSH.
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo "Run as your normal user; it calls sudo when needed."; exit 1; }
command -v pacman >/dev/null || { echo "This installer is for Omarchy (Arch Linux)."; exit 1; }

sudo pacman -S --needed --noconfirm wayvnc openssh
# The Mac app logs in with your normal username and password.
sudo mkdir -p /etc/ssh/sshd_config.d
echo "PasswordAuthentication yes" | sudo tee /etc/ssh/sshd_config.d/10-omarchy-remote.conf >/dev/null
# sshd uses the first value it sees, so the Include must come before any other setting.
grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config || sudo sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
sudo systemctl enable sshd
sudo systemctl restart sshd

# Omarchy's ufw blocks inbound by default: allow SSH from LAN and Tailscale ranges only.
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
    sudo ufw allow from "$net" to any port 22 proto tcp comment omarchy-remote >/dev/null
  done
fi

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/omarchy-remote.service <<'UNIT'
[Unit]
Description=Omarchy Remote (wayvnc on localhost; connect over SSH)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/wayvnc --render-cursor --max-fps=60 127.0.0.1 5900
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
UNIT
systemctl --user daemon-reload
systemctl --user enable omarchy-remote.service >/dev/null
if systemctl --user is-active --quiet graphical-session.target; then
  systemctl --user restart omarchy-remote.service
  status="running"
else
  status="installed; starts with your next Hyprland login"
fi

ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
cat <<MSG

Omarchy Remote is $status.

On your Mac, install the app from
  https://github.com/thesnarkitecht/omarchy-remote-desktop/releases/latest/download/Omarchy-Remote.dmg
and connect with:
  Computer: ${ip:-<this-machine-ip>}
  Username: $USER
  Password: your Omarchy login password
MSG
