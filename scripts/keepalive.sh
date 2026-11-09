#!/usr/bin/env bash
# Run ONCE on the VM: sudo bash keepalive.sh
# Keeps CPU around 25% so Oracle doesn't reclaim the "idle" Always Free VM.
set -e
apt-get update -y && apt-get install -y stress-ng
CORES=$(nproc)
cat > /etc/systemd/system/keepalive.service <<UNIT
[Unit]
Description=Oracle idle-reclaim keepalive
After=network.target

[Service]
ExecStart=/usr/bin/stress-ng --cpu ${CORES} --cpu-load 25 --timeout 0
Nice=19
CPUSchedulingPolicy=idle
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now keepalive
echo "Keepalive running."
