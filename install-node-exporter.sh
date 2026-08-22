#!/usr/bin/env bash
# Installs node_exporter on a SteamOS mini PC, run over SSH from anywhere.
#
# SteamOS (Holo) images ship a read-only root filesystem that gets replaced
# wholesale on OS updates -- anything written to /usr or /etc can vanish on
# the next update, even after `steamos-readonly disable`, which only
# remounts the *current* partition writable, it doesn't persist across the
# A/B image swap. /home is the one thing SteamOS guarantees survives
# updates, so everything here lives there: the binary under
# ~/.local/bin, the unit as a per-user systemd service (not a system one),
# with `loginctl enable-linger` so it starts on boot without a login
# session. No sudo needed except for the linger call.
#
# Enables only the collectors asked for: cpu, memory, disk, network, and
# temperature (thermal_zone + hwmon, covering both ACPI-reported and
# chip-specific sensors -- SteamOS mini PCs are typically AMD APUs, which
# report via hwmon/k10temp).
#
# The filesystem collector excludes SteamOS's known persistent-storage
# bind-mount targets -- /nix, /opt, /root, /srv, and everything under
# /var/{cache/pacman,lib/docker,lib/flatpak,lib/steamos-log-submitter,
# lib/systemd/coredump,log,tmp} all bind-mount onto the same /home-backed
# partition, so without this they'd report as a dozen "different"
# filesystems all showing the exact same numbers. Only /, /home, and /var
# are genuinely distinct partitions on this hardware.
set -euo pipefail

VERSION="${VERSION:-1.12.1}"

read -rp "SteamOS SSH target (e.g. deck@steamos-minipc.local): " TARGET

if [[ -z "$TARGET" ]]; then
  echo "No target given."
  exit 1
fi

REMOTE_USER="${TARGET%@*}"

echo ""
echo "Target node:   $TARGET"
echo "Remote user:   $REMOTE_USER"
echo "Version:       $VERSION"
read -rp "Continue? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo "Installing node_exporter on $TARGET..."
ssh -t "$TARGET" "VERSION='${VERSION}' bash -s" <<'EOF'
set -euo pipefail

case "$(uname -m)" in
  x86_64) ARCH="amd64" ;;
  *)
    echo "Unrecognized architecture: $(uname -m)"
    exit 1
    ;;
esac

TARBALL="node_exporter-${VERSION}.linux-${ARCH}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${TARBALL}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Downloading ${URL}..."
curl -sfL "$URL" -o "${WORKDIR}/${TARBALL}"
tar -xzf "${WORKDIR}/${TARBALL}" -C "$WORKDIR"

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m 755 \
  "${WORKDIR}/node_exporter-${VERSION}.linux-${ARCH}/node_exporter" \
  "$HOME/.local/bin/node_exporter"

cat >"$HOME/.config/systemd/user/node_exporter.service" <<UNIT
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/node_exporter \\
  --web.listen-address=:9100 \\
  --collector.disable-defaults \\
  --collector.filesystem \\
  --collector.filesystem.mount-points-exclude='^/(nix|opt|root|srv|esp|efi|var/cache/pacman|var/lib/docker|var/lib/flatpak|var/lib/steamos-log-submitter|var/lib/systemd/coredump|var/log|var/tmp)(\$|/)' \\
  --collector.diskstats \\
  --collector.meminfo \\
  --collector.cpu \\
  --collector.netdev \\
  --collector.thermal_zone \\
  --collector.hwmon
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now node_exporter
systemctl --user restart node_exporter

echo "node_exporter installed and running on :9100 (user service)."
EOF

echo ""
echo "Enabling linger so the service survives logout/reboot without an active session..."
ssh -t "$TARGET" "sudo loginctl enable-linger '${REMOTE_USER}'"

echo ""
echo "Done. Verify with:"
echo "  curl http://<steamos-ip>:9100/metrics | grep -E 'node_(filesystem|memory|cpu|netdev|thermal_zone|hwmon)'"
echo ""
echo "Then add a static target for this machine to homelab-prometheus's"
echo "scrape_configs, as its own job (e.g. 'steamos-node-exporter') rather"
echo "than folding into 'pi-node-exporter' -- different hardware class."
