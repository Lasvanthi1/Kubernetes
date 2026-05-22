#!/bin/bash
# =============================================================
# SRE Forensic Lab — Complete Solution
# =============================================================

# ── SETUP ────────────────────────────────────────────────────
mkdir -p /home/user/debug-lab
cd /home/user/debug-lab
docker rm -f legacy-app 2>/dev/null || true   # clean slate

# ── TASK 1: Launch broken container ──────────────────────────
docker run -d \
  --name legacy-app \
  --dns 10.255.255.255 \
  alpine \
  sh -c "while true; do sleep 30; done"

echo '[+] Container launched with broken DNS'
docker ps --filter name=legacy-app

# ── TASK 2: Forensic Analysis ─────────────────────────────────
PID=$(docker inspect --format '{{.State.Pid}}' legacy-app)
echo "[+] Container PID on host: $PID"

# Artifact A: Routing Table
nsenter --net=/proc/$PID/ns/net ip route > route-dump.txt
echo '[+] Artifact A saved: route-dump.txt'
cat route-dump.txt

# Artifact B: DNS Config
nsenter --mount=/proc/$PID/ns/mnt --net=/proc/$PID/ns/net cat /etc/resolv.conf > dns-config.txt
echo '[+] Artifact B saved: dns-config.txt'
cat dns-config.txt

# ── TASK 3: Remediation ───────────────────────────────────────
docker rm -f legacy-app

docker run -d \
  --name legacy-app \
  --dns 8.8.8.8 \
  alpine \
  sh -c "while true; do sleep 30; done"

echo '[+] Healthy container launched with Google DNS'

# Verify fix
docker exec legacy-app nslookup google.com
echo '[+] Connectivity verified. Incident resolved.'
