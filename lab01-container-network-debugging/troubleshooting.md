# 🛠️ Troubleshooting & Learnings — SRE Forensic Lab

> Real errors hit during the lab, root cause analysis, and fixes.
> These are not failures — they are the actual learning.

---

## Issue 01 — `nsenter --net` Showed Host DNS Instead of Container DNS

### ❌ What Happened

After getting the container PID, the following command was run to capture the container's DNS config:

```bash
nsenter --net=/proc/8561/ns/net cat /etc/resolv.conf
```

**Expected output:**
```
nameserver 10.255.255.255
```

**Actual output received:**
```
# This is /run/systemd/resolve/resolv.conf managed by man:systemd-resolved(8).
# Do not edit.
...
nameserver 8.8.8.8
nameserver 1.1.1.1
search .
```

This was the **host machine's** `/etc/resolv.conf` — not the container's.

---

### 🔍 Root Cause

Linux containers are isolated using **6 independent namespaces**. Each namespace controls a different resource:

| Namespace | Flag | Isolates |
|---|---|---|
| Network | `--net` | interfaces, routing, DNS config |
| Mount | `--mount` | filesystem, files, directories |
| PID | `--pid` | process IDs |
| UTS | `--uts` | hostname |
| IPC | `--ipc` | interprocess communication |
| User | `--user` | user/group IDs |

The mistake: `--net` only enters the container's **network namespace**.  
But `cat /etc/resolv.conf` reads a **file** — files belong to the **mount namespace**.

Since `--mount` was not specified, `cat` fell back to the **host's mount namespace** and read the **host's** `/etc/resolv.conf`.

```
HOST MACHINE
├── Mount Namespace (filesystem)
│     └── /etc/resolv.conf → nameserver 8.8.8.8    ← cat read THIS (wrong)
│
└── Network Namespace
      └── routing, interfaces

CONTAINER
├── Mount Namespace (filesystem)
│     └── /etc/resolv.conf → nameserver 10.255.255.255  ← wanted THIS
│
└── Network Namespace ← nsenter --net entered only THIS
      └── eth0, routing table
```

---

### ✅ Fix — Two Options

**Option 1 — Enter both namespaces with nsenter:**
```bash
nsenter --net=/proc/8561/ns/net \
        --mount=/proc/8561/ns/mnt \
        cat /etc/resolv.conf

# Output: nameserver 10.255.255.255 ✅
```

**Option 2 — Use docker exec (simpler, enters all namespaces automatically):**
```bash
docker exec legacy-app cat /etc/resolv.conf > dns-config.txt
cat dns-config.txt

# Output:
# nameserver 10.255.255.255  ✅
```

`docker exec` automatically enters **all 6 namespaces** at once.  
`nsenter` gives **surgical control** — you choose exactly which namespaces to enter.

---

### 📌 When to Use Which

| Situation | Command to Use |
|---|---|
| Read a file inside container | `docker exec` or `nsenter --net --mount` |
| Test network routing only | `nsenter --net` alone |
| Container has no shell at all | `nsenter --net --mount` |
| Quick debugging, shell available | `docker exec` |

---

### 💡 Key Takeaway

> `nsenter --net` enters the network namespace only.
> The filesystem is a completely separate namespace (`--mount`).
> Using `--net` alone and then running `cat` will always read the HOST's files — not the container's.

---

## Issue 02 — Host `/etc/resolv.conf` Showed 8.8.8.8 Even Though Container Had 10.255.255.255

### ❌ What Happened

While verifying the lab setup, the host file was checked:

```bash
cat /run/systemd/resolve/resolv.conf
```

Output showed:
```
nameserver 8.8.8.8
nameserver 1.1.1.1
```

This created confusion — the container was supposed to have `10.255.255.255` as its DNS. Was the `--dns` flag working or not?

---

### 🔍 Root Cause

The host machine runs `systemd-resolved` — a system DNS manager that maintains its own `/etc/resolv.conf`. This is **completely separate** from what Docker writes inside the container.

Docker's `--dns` flag writes **only to the container's** `/etc/resolv.conf` at container start time. It does not touch the host's DNS configuration at all.

```
HOST /etc/resolv.conf          → managed by systemd-resolved → 8.8.8.8
CONTAINER /etc/resolv.conf     → written by Docker --dns flag → 10.255.255.255
```

These are two completely independent files in two different mount namespaces.

---

### ✅ Fix — Verify the Right File

Always verify the **container's** resolv.conf, not the host's:

```bash
# ✅ Correct — reads CONTAINER's resolv.conf
docker exec legacy-app cat /etc/resolv.conf

# ❌ Wrong — reads HOST's resolv.conf
cat /etc/resolv.conf
cat /run/systemd/resolve/resolv.conf
```

Also verify via Docker inspect to confirm the `--dns` flag was applied:

```bash
docker inspect legacy-app | grep -A5 "Dns"

# Expected:
# "Dns": [
#     "10.255.255.255"
# ],
```

---

### 💡 Key Takeaway

> The host's `/etc/resolv.conf` and the container's `/etc/resolv.conf` are completely independent files.
> Docker's `--dns` flag only affects the container.
> Always use `docker exec <container> cat /etc/resolv.conf` to check the container's actual DNS — never the host file.

---

## Issue 03 — Confusion: Is `--dns-search ""` Required?

### ❌ What Happened

During troubleshooting, this command was suggested as a fix:

```bash
docker run -d \
  --name legacy-app \
  --dns 10.255.255.255 \
  --dns-search "" \
  alpine \
  sh -c "while true; do sleep 30; done"
```

The question was: is `--dns-search ""` actually needed?

---

### 🔍 Root Cause

`--dns-search` controls the **search domain** appended to hostnames.  
For example, if search is set to `internal`, then `ping db` becomes `ping db.internal`.

On some systems, Docker inherits the host's search domain. The `--dns-search ""` flag was suggested as a precaution to clear it. But after inspection:

```bash
docker inspect legacy-app | grep -A5 "Dns"

# Output:
# "Dns": ["10.255.255.255"],
# "DnsOptions": [],
# "DnsSearch": [],       ← already empty without --dns-search ""
```

The search domain was already empty. The `--dns 10.255.255.255` flag alone was sufficient.

---

### ✅ Fix

No fix needed. The original command worked correctly:

```bash
docker run -d \
  --name legacy-app \
  --dns 10.255.255.255 \
  alpine \
  sh -c "while true; do sleep 30; done"
```

---

### 💡 Key Takeaway

> Always verify with `docker inspect` before assuming a flag is needed.
> `--dns-search ""` is only required if Docker is inheriting unwanted search domains from the host.
> `docker inspect` is your ground truth for what flags actually took effect.

---

## 🧠 Overall Learnings from These Errors

| Error Hit | What It Taught |
|---|---|
| `nsenter --net` read host DNS | Linux has 6 independent namespaces — network and mount are separate |
| Host showed 8.8.8.8, container showed 10.255.255.255 | Host and container `/etc/resolv.conf` are completely independent files |
| Unsure if `--dns-search ""` was needed | `docker inspect` is the ground truth — always verify, never assume |

---

> 💬 These errors were not mistakes — they revealed exactly how Linux namespaces,
> Docker DNS injection, and systemd-resolved interact at a deep level.
> Hitting them live is worth more than reading 10 theory articles.
