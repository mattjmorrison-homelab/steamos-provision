Repo for bootstrapping steamos on minipcs

## Install metrics collection

Not a k3s cluster member — metrics-only, scraped directly like `pi1.local`
and `pizero.local` in `pi-provision`, not via the in-cluster DaemonSet.

```bash
bash install-node-exporter.sh
```

Prompts for the machine's SSH target, installs `node_exporter` as a
**per-user** systemd service under `~/.local/bin` (not `/usr/local/bin`,
not a system unit) and enables linger so it starts on boot without a login
session. SteamOS's root filesystem gets replaced wholesale on OS updates —
`/home` is the one thing guaranteed to survive that, so everything here
stays out of `/usr` and `/etc` entirely rather than relying on
`steamos-readonly disable`, which only remounts the current partition and
doesn't persist across the next image swap.

Enables the `filesystem`, `diskstats`, `meminfo`, `cpu`, `netdev`,
`thermal_zone`, and `hwmon` collectors — disk, memory, CPU, network, and
temperature — and nothing else.

After running it, add the machine's `.local` mDNS hostname (not its IP —
DHCP can hand out a different one on every boot; the hostname resolves to
whatever's current, same as `pi1.local`/`pizero.local` already do) as a
new `steamos-node-exporter` scrape job in `homelab-prometheus` — its own
job, not folded into `pi-node-exporter`, since it's a different hardware
class.
