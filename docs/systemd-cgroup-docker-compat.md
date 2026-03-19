# systemd + cgroup v2 + Docker Desktop: Compatibility Research

> **Context:** Commit `b4fc140` replaced `systemctl enable/start agent@<user>.service`
> with `nohup su -` because systemd's cgroup-based process spawning is broken
> inside Docker Desktop on macOS with cgroup v2 and systemd v256+.
> This document records the investigation needed to restore full systemd service management.

## The Symptom

Calling `systemctl start agent@alice.service` inside the container produces:

- The service immediately reaches `inactive (dead)`
- Exit code 255, 0B memory consumed
- No journal output — the process was never exec'd
- systemd itself boots cleanly (`basic.target`, `multi-user.target` both reached)
- The same issue affects `smtpd.service` (worked around via a shell wrapper in the Dockerfile)

## Root Cause

A three-way incompatibility between systemd's expectations of the cgroup hierarchy, how Docker mounts that hierarchy, and the constraints imposed by the Docker Desktop LinuxKit VM.

### How systemd spawns services using cgroups

When starting a service, systemd:

1. Creates a child cgroup (e.g., `/sys/fs/cgroup/system.slice/agent@alice.service`)
2. Assigns the new process's PID to that cgroup
3. Enables resource controllers (memory, cpu, etc.) via `cgroup.subtree_control`
4. Enforces resource limits (MemoryMax, CPUQuota) by writing to controller files

Any write failure in this sequence causes systemd to silently drop the service start.

### The two cgroup v2 rules

systemd's [CGROUP_DELEGATION.md](https://systemd.io/CGROUP_DELEGATION/) defines two invariants that container runtimes must respect:

1. **No-processes-in-inner-nodes**: A cgroup v2 node is either a leaf (holds processes) or an inner node (holds child cgroups), never both. systemd must create child cgroups like `init.scope` before it can write to `cgroup.subtree_control`.

2. **Single-writer**: Each cgroup must have exactly one manager. When Docker manages the container's root cgroup and the container's own systemd also tries to manage it, they conflict.

### Why Docker Desktop is harder than native Linux

On **native Linux**, the host's systemd can delegate a cgroup subtree to Docker via a scope/service unit with `Delegate=yes`. The container receives a private cgroup namespace rooted at the delegated path, and systemd inside the container can freely write to that subtree.

On **Docker Desktop for macOS**, Docker runs inside a **LinuxKit VM**:

```
macOS host
  → Docker Desktop
    → LinuxKit VM (kernel ~6.10.x, cgroupfs driver, NO systemd)
      → containerd / dockerd
        → Container (systemd as PID 1)
```

The LinuxKit VM:
- Uses `cgroupfs` as its cgroup driver, not systemd
- Does not run systemd as its own init system
- Cannot perform `Delegate=yes` because there is no host-side systemd to delegate from
- Mounts `/sys/fs/cgroup` read-only inside containers by default

The result: the container's systemd cannot write to the cgroup hierarchy, cannot create child cgroups, and therefore cannot start services.

### systemd v256+ made things worse

| Version | Change |
|---------|--------|
| **v248** (2021) | Read-only `/sys/fs/cgroup` inside containers began causing failures ([systemd#19245](https://github.com/systemd/systemd/issues/19245)) |
| **v256** (June 2024) | cgroup v1 formally deprecated; systemd refuses to boot under cgroup v1 by default |
| **v258** (Sept 2025) | cgroup v1 support **removed entirely** |

Because the container runs `FROM archlinux:latest`, it always carries the newest systemd. Falling back to cgroup v1 is not an option.

## What the Container Currently Does

From `docker-compose.yml`:

```yaml
privileged: true
tmpfs:
  - /run
  - /run/lock
```

`privileged: true` is set, but neither `cgroup: host` (or `--cgroupns=host`) nor an explicit read-write `/sys/fs/cgroup` volume mount is present.

Without those additions, Docker uses its default cgroup namespace mode. On cgroup v2 hosts the default is `private`, which gives the container a private namespace that may be read-only.

## Fix Options

### Option 1: `cgroup: host` + rw cgroup mount (recommended first attempt)

Add to `docker-compose.yml`:

```yaml
services:
  gaslite:
    privileged: true
    cgroup: host          # Compose spec key; older versions may need cgroupns_mode: host
    tmpfs:
      - /run
      - /run/lock
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      # ... existing mounts
```

> **Note:** The Compose spec uses `cgroup: host`. Older Docker Compose versions (pre-2.x)
> may need `cgroupns_mode: host` instead. With `docker run`, pass `--cgroupns=host`.

This is the "Jeff Geerling pattern" — the most widely tested approach for running systemd inside Docker. It gives the container's systemd access to the host (or VM) cgroup hierarchy.

**Pros:**
- Most compatible approach; works on native Linux and Docker Desktop
- Enables full `systemctl` functionality including resource limits
- Well-documented, widely used in Ansible/Molecule testing workflows

**Cons:**
- The container can see and potentially affect the host cgroup hierarchy
- The security delta is small given that `privileged: true` is already set
- On Docker Desktop, "host" refers to the LinuxKit VM, not macOS itself

**Testing:**
```bash
# Rebuild, start, and enter the container
make build && make up && make shell

# Confirm cgroup v2 is writable
ls -la /sys/fs/cgroup/
cat /proc/self/cgroup  # should show the container's cgroup path
mkdir /sys/fs/cgroup/test.scope 2>/dev/null \
  && rmdir /sys/fs/cgroup/test.scope && echo "cgroup writable" \
  || echo "cgroup NOT writable"

# Test service management
systemctl start agent-manager.service
systemctl status agent-manager.service

# Create a test agent and confirm systemd starts it
# (after restoring systemctl in create-agent.sh)
create-agent.sh testuser
systemctl status agent@testuser.service
journalctl -u agent@testuser.service --no-pager -n 20
```

### Option 2: Entrypoint cgroup remount (more targeted)

Instead of exposing the host cgroup namespace, remount the cgroup filesystem read-write inside the container before handing off to systemd:

```bash
#!/bin/bash
# /usr/local/bin/container-init.sh — runs before systemd
umount /sys/fs/cgroup 2>/dev/null || true
mount -t cgroup2 -o rw,relatime,nsdelegate,memory_recursiveprot cgroup2 /sys/fs/cgroup
exec /usr/lib/systemd/systemd "$@"
```

Then in the Dockerfile:
```dockerfile
ENTRYPOINT ["/usr/local/bin/container-init.sh"]
```

**Pros:**
- Keeps the cgroup namespace private (container-scoped)
- Provides more isolation than sharing the host cgroup namespace
- The fix lives entirely inside the image — no docker-compose changes needed

**Cons:**
- Compatibility with all Docker Desktop versions is less certain
- Requires `CAP_SYS_ADMIN` (already granted by `privileged: true`)
- Less battle-tested in the community than Option 1

### Option 3: Shell wrapper pattern (per-service workaround)

This is what is already done for `smtpd.service` — wrapping the ExecStart in a shell script:

```ini
[Service]
Type=simple
ExecStart=
ExecStart=/bin/sh -c 'exec /usr/local/bin/run-agent.sh'
```

The theory: systemd's cgroup write failure occurs during its internal fork+exec path. If the shell is already running (forked by systemd before the failure), the `exec` inside the shell may succeed.

**Pros:**
- Requires no infrastructure changes
- Already proven to work for smtpd in this environment

**Cons:**
- Relies on a race condition / implementation detail — fragile
- Likely does not work for resource limit directives (MemoryMax, CPUQuota)
- Does not fix the underlying cause

### Option 4: Hybrid approach (recommended path)

Combine Options 1 and 3:

1. Add `cgroup: host` and the rw cgroup mount to `docker-compose.yml` (Option 1)
2. If that resolves service spawning, keep it as-is
3. If individual security directives still fail, re-enable them one at a time
4. For any directive that cannot work inside Docker, document the reason and leave it commented out

## Security Hardening Re-enablement Plan

Once systemd service management is working, re-enable `agent@.service` security directives in tiers from safest to most risky:

### Tier 1: Safe in Docker (re-enable immediately)
```ini
NoNewPrivileges=true          # Kernel no_new_privs flag (prctl) — no mount/cgroup interaction
RestrictSUIDSGID=true         # Blocks setuid/setgid file creation — no mount/cgroup interaction
```

### Tier 2: Likely safe with cgroup host access (test carefully)
```ini
MemoryMax=512M                # Requires write access to the cgroup hierarchy
CPUQuota=50%                  # Requires write access to the cgroup hierarchy
```

### Tier 3: May conflict with Docker overlay2 (test on both platforms)
```ini
ProtectSystem=full            # Remounts /usr, /boot read-only — may conflict with overlay
PrivateTmp=true               # Creates a private /tmp mount namespace
RestrictNamespaces=true       # May conflict with the container's namespace setup
```

### Tier 4: Likely incompatible with Docker (leave disabled)
```ini
ProtectKernelTunables=true    # Mounts /proc/sys read-only — conflicts with privileged
ProtectKernelModules=true     # Blocks module loading — conflicts with privileged
ProtectControlGroups=true     # Mounts /sys/fs/cgroup read-only — directly contradicts Option 1
ProtectKernelLogs=true        # Blocks /dev/kmsg access
CapabilityBoundingSet=        # Drops all capabilities — conflicts with privileged
AmbientCapabilities=          # No capabilities to pass to children
RestrictAddressFamilies=...   # May conflict with the container's seccomp profile
```

## Platform Test Matrix

Any fix should be verified on all four configurations:

| Platform | cgroup version | Docker cgroup driver | Expected behavior |
|----------|---------------|---------------------|-------------------|
| Docker Desktop macOS (Apple Silicon) | v2 | cgroupfs (LinuxKit) | Primary target — where the bug was found |
| Docker Desktop macOS (Intel) | v2 | cgroupfs (LinuxKit) | Should behave identically to Apple Silicon |
| Native Linux (Ubuntu 22.04+) | v2 | systemd | Should work with proper cgroup delegation |
| Native Linux (older, cgroup v1) | v1 | cgroupfs | Not supported — systemd v256+ requires cgroup v2 |

## Diagnostic Commands

Run these inside the container to understand the current cgroup state:

```bash
# Which cgroup version is active?
stat -fc %T /sys/fs/cgroup/
# "cgroup2fs" = v2, "tmpfs" = v1

# Is the cgroup hierarchy writable?
touch /sys/fs/cgroup/.test 2>&1 && rm /sys/fs/cgroup/.test && echo "writable" || echo "read-only"

# Which cgroup is PID 1 in?
cat /proc/1/cgroup

# Which controllers are available?
cat /sys/fs/cgroup/cgroup.controllers

# Which controllers are delegated to child cgroups?
cat /sys/fs/cgroup/cgroup.subtree_control

# Can systemd create child cgroups at all?
mkdir /sys/fs/cgroup/test.scope 2>&1 && rmdir /sys/fs/cgroup/test.scope && echo "yes" || echo "no"

# systemd's view of a service's cgroup state:
systemctl show --property=ControlGroup --property=MemoryCurrent --property=CPUUsageNSec agent@testuser.service

# Is systemd reporting a degraded state?
systemctl --failed
systemd-analyze blame
```

## Key References

- [systemd CGROUP_DELEGATION.md](https://systemd.io/CGROUP_DELEGATION/) — the canonical guide to cgroup delegation
- [systemd v256 NEWS](https://github.com/systemd/systemd/blob/v256-stable/NEWS) — cgroup v1 deprecation announcement
- [moby/moby#42275](https://github.com/moby/moby/issues/42275) — systemd + read-only cgroup mount
- [docker/for-mac#6073](https://github.com/docker/for-mac/issues/6073) — Docker Desktop systemd issues
- [Jeff Geerling — Docker and systemd](https://www.jeffgeerling.com/blog/2022/docker-and-systemd-getting-rid-dreaded-failed-connect-bus-error/) — the `--privileged --cgroupns=host` pattern
- [pinkeen's gist](https://gist.github.com/pinkeen/bba0a6790fec96d6c8de84bd824ad933) — entrypoint remount approach
- [moby/moby#51111](https://github.com/moby/moby/issues/51111) — Docker's own cgroup v1 deprecation timeline
