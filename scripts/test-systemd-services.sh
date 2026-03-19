#!/bin/bash
# test-systemd-services.sh — Confirm systemd service management is functional in this container
#
# Usage: test-systemd-services.sh [--verbose]
#
# Verifies:
#   1. cgroup v2 is present and writable
#   2. systemd has fully booted and is operational
#   3. A test agent can be created and driven via systemctl
#   4. Resource constraints (MemoryMax, CPUQuota) take effect
#   5. Service lifecycle (start/stop/restart) works end-to-end
#   6. Boot-time reconciliation (agent-manager) ran successfully
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
#
# Run inside the container. From the host: make test-systemd

set -euo pipefail

# --- Environment check ---
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

# --- Flags ---
LOUD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) LOUD=true; shift ;;
        *) shift ;;
    esac
done

# --- Minimal test framework ---
TALLY_PASS=0
TALLY_FAIL=0
RESULTS=()

readonly CLR_RED='\033[0;31m'
readonly CLR_GRN='\033[0;32m'
readonly CLR_YLW='\033[0;33m'
readonly CLR_BLD='\033[1m'
readonly CLR_OFF='\033[0m'

say()  { echo -e "$*"; }
note() { [[ "$LOUD" == "true" ]] && echo -e "  ${CLR_YLW}-> $*${CLR_OFF}" || true; }

ok() {
    local label="$1"
    ((TALLY_PASS++)) || true
    RESULTS+=("PASS: $label")
    say "  ${CLR_GRN}✓${CLR_OFF} $label"
}

fail() {
    local label="$1"
    local hint="${2:-}"
    ((TALLY_FAIL++)) || true
    RESULTS+=("FAIL: $label")
    say "  ${CLR_RED}✗${CLR_OFF} $label"
    [[ -n "$hint" ]] && say "    ${CLR_RED}$hint${CLR_OFF}"
}

heading() {
    say ""
    say "${CLR_BLD}$1${CLR_OFF}"
}

# --- Cleanup for the ephemeral test account ---
DUMMY_ACCOUNT="__test_systemd__"

purge_test_account() {
    note "Removing test account $DUMMY_ACCOUNT"
    if id "$DUMMY_ACCOUNT" &>/dev/null; then
        systemctl stop "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true
        systemctl disable "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true
        userdel -r "$DUMMY_ACCOUNT" 2>/dev/null || true
    fi
    rmdir /sys/fs/cgroup/test_harness.scope 2>/dev/null || true
}
trap purge_test_account EXIT

say ""
say "${CLR_BLD}systemd Service Management Test Harness${CLR_OFF}"
say "Platform: $(uname -srm)"
say "systemd:  $(systemctl --version | head -1)"
say "Docker:   container=$(cat /proc/1/cgroup 2>/dev/null | head -1 || echo 'unknown')"
say ""

# =====================================================
# Section 1: cgroup v2 infrastructure
# =====================================================
heading "Phase 1: cgroup v2 infrastructure"

FS_KIND=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo "unknown")
if [[ "$FS_KIND" == "cgroup2fs" ]]; then
    ok "cgroup v2 filesystem detected ($FS_KIND)"
else
    fail "cgroup v2 filesystem not detected (got: $FS_KIND)" \
         "Expected cgroup2fs. Verify the host kernel uses cgroup v2."
fi

if touch /sys/fs/cgroup/.test_harness 2>/dev/null; then
    rm -f /sys/fs/cgroup/.test_harness
    ok "cgroup hierarchy is writable"
else
    fail "cgroup hierarchy is read-only" \
         "Add 'cgroup: host' and '/sys/fs/cgroup:/sys/fs/cgroup:rw' to docker-compose.yml"
fi

if mkdir /sys/fs/cgroup/test_harness.scope 2>/dev/null; then
    rmdir /sys/fs/cgroup/test_harness.scope
    ok "Child cgroup creation works"
else
    fail "Cannot create child cgroups" \
         "systemd requires cgroup creation for services. Check delegation settings."
fi

AVAIL_CONTROLLERS=$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || echo "")
note "Available cgroup controllers: $AVAIL_CONTROLLERS"

if echo "$AVAIL_CONTROLLERS" | grep -q "memory"; then
    ok "Memory controller is available"
else
    fail "Memory controller unavailable" \
         "MemoryMax=512M in agent@.service requires the memory controller"
fi

if echo "$AVAIL_CONTROLLERS" | grep -q "cpu"; then
    ok "CPU controller is available"
else
    fail "CPU controller unavailable" \
         "CPUQuota=50% in agent@.service requires the cpu controller"
fi

# =====================================================
# Section 2: systemd operational health
# =====================================================
heading "Phase 2: systemd health"

INIT_NAME=$(cat /proc/1/comm 2>/dev/null || echo "unknown")
if [[ "$INIT_NAME" == "systemd" ]]; then
    ok "systemd is PID 1"
else
    fail "systemd is not PID 1 (found: $INIT_NAME)"
fi

if systemctl is-active basic.target &>/dev/null; then
    ok "basic.target is active"
else
    fail "basic.target is not active" \
         "systemd boot sequence has not completed"
fi

if systemctl is-active multi-user.target &>/dev/null; then
    ok "multi-user.target is active"
else
    fail "multi-user.target is not active"
fi

HEALTH=$(systemctl is-system-running 2>/dev/null || echo "unknown")
note "System running state: $HEALTH"
if [[ "$HEALTH" == "running" || "$HEALTH" == "degraded" ]]; then
    ok "systemd running state: $HEALTH"
    if [[ "$HEALTH" == "degraded" ]]; then
        note "Failed units: $(systemctl --failed --no-legend 2>/dev/null | head -5)"
    fi
else
    fail "systemd running state: $HEALTH"
fi

if journalctl --no-pager -n 1 &>/dev/null; then
    ok "journald is reachable"
else
    fail "journald is unreachable"
fi

# =====================================================
# Section 3: Agent service template
# =====================================================
heading "Phase 3: Agent service template"

if [[ -f /etc/systemd/system/agent@.service ]]; then
    ok "agent@.service template is in place"
else
    fail "agent@.service template missing at /etc/systemd/system/agent@.service"
fi

if [[ -x /usr/local/bin/run-agent.sh ]]; then
    ok "run-agent.sh is present and executable"
else
    fail "run-agent.sh missing or not executable"
fi

# =====================================================
# Section 4: Service lifecycle
# =====================================================
heading "Phase 4: Service lifecycle (create/start/stop/restart)"

# Ensure a clean slate before creating the test account
purge_test_account

note "Setting up test account: $DUMMY_ACCOUNT"
groupadd -f agents 2>/dev/null || true
useradd -M -s /bin/bash -G agents -d "/home/$DUMMY_ACCOUNT" "$DUMMY_ACCOUNT" 2>/dev/null
mkdir -p "/home/$DUMMY_ACCOUNT"
cp -a /etc/skel/. "/home/$DUMMY_ACCOUNT/" 2>/dev/null || true
chown -R "$DUMMY_ACCOUNT:$DUMMY_ACCOUNT" "/home/$DUMMY_ACCOUNT"
chmod 700 "/home/$DUMMY_ACCOUNT"

mkdir -p "/home/$DUMMY_ACCOUNT/.claude"
echo '{"agent":{"enabled":true,"persona":"base"}}' > "/home/$DUMMY_ACCOUNT/.claude/config.json"
chown -R "$DUMMY_ACCOUNT:$DUMMY_ACCOUNT" "/home/$DUMMY_ACCOUNT/.claude"

ok "Test account created: $DUMMY_ACCOUNT"

if systemctl daemon-reload 2>/dev/null; then
    ok "systemctl daemon-reload completed"
else
    fail "systemctl daemon-reload failed"
fi

if systemctl enable "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null; then
    ok "systemctl enable agent@${DUMMY_ACCOUNT}.service"
else
    fail "systemctl enable agent@${DUMMY_ACCOUNT}.service"
fi

# The service will likely exit quickly (no API key) but systemd must still be able to fork it
if timeout --kill-after=5 10 systemctl start "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null; then
    ok "systemctl start agent@${DUMMY_ACCOUNT}.service"
else
    SVC_STATE=$(systemctl show -p ActiveState "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
    SVC_RESULT=$(systemctl show -p Result "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
    MAIN_PID=$(systemctl show -p ExecMainPID "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
    note "ActiveState=$SVC_STATE Result=$SVC_RESULT ExecMainPID=$MAIN_PID"

    if [[ "$MAIN_PID" != "0" ]]; then
        ok "systemctl start spawned a process (PID $MAIN_PID, exited: $SVC_RESULT)"
    else
        fail "systemctl start did not spawn any process" \
             "Core cgroup v2 issue: ExecMainPID=0 means systemd could not fork."
        note "Journal tail:"
        journalctl -u "agent@${DUMMY_ACCOUNT}.service" --no-pager -n 10 2>/dev/null | while read -r ln; do
            note "  $ln"
        done
    fi
fi

if systemctl list-units "agent@${DUMMY_ACCOUNT}.service" --no-legend 2>/dev/null | grep -q "agent@"; then
    ok "Service appears in systemctl list-units"
else
    if systemctl list-unit-files "agent@${DUMMY_ACCOUNT}.service" --no-legend 2>/dev/null | grep -q "agent@"; then
        ok "Service appears in systemctl list-unit-files"
    else
        fail "Service not visible in systemctl"
    fi
fi

if timeout --kill-after=5 10 systemctl stop "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null; then
    ok "systemctl stop agent@${DUMMY_ACCOUNT}.service"
else
    fail "systemctl stop agent@${DUMMY_ACCOUNT}.service"
fi

systemctl reset-failed "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true
if timeout --kill-after=5 10 systemctl start "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null; then
    ok "Service restart (stop then start) succeeded"
    systemctl stop "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true
else
    MAIN_PID=$(systemctl show -p ExecMainPID "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
    if [[ "$MAIN_PID" != "0" ]]; then
        ok "Service restart spawned a process (exited — expected without API key)"
    else
        fail "Service restart did not spawn a process"
    fi
fi

if systemctl disable "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null; then
    ok "systemctl disable agent@${DUMMY_ACCOUNT}.service"
else
    fail "systemctl disable agent@${DUMMY_ACCOUNT}.service"
fi

# =====================================================
# Section 5: Resource constraint verification
# =====================================================
heading "Phase 5: Resource limits (cgroup controllers)"

systemctl reset-failed "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true
systemctl enable "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true
systemctl start "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true
sleep 1

MEM_CAP=$(systemctl show -p MemoryMax "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
note "MemoryMax reported as: $MEM_CAP"
if [[ "$MEM_CAP" == "536870912" ]]; then
    ok "MemoryMax=512M is enforced (536870912 bytes)"
elif [[ "$MEM_CAP" == "infinity" || -z "$MEM_CAP" ]]; then
    fail "MemoryMax not enforced (got: ${MEM_CAP:-empty})" \
         "cgroup memory controller may not be delegated to this container"
else
    ok "MemoryMax is configured ($MEM_CAP)"
fi

CPU_CAP=$(systemctl show -p CPUQuotaPerSecUSec "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
note "CPUQuotaPerSecUSec reported as: $CPU_CAP"
if [[ "$CPU_CAP" == "500ms" ]]; then
    ok "CPUQuota=50% is enforced (500ms per second)"
elif [[ "$CPU_CAP" == "infinity" || -z "$CPU_CAP" ]]; then
    fail "CPUQuota not enforced (got: ${CPU_CAP:-empty})" \
         "cgroup cpu controller may not be delegated to this container"
else
    ok "CPUQuota is configured ($CPU_CAP)"
fi

NNP_VAL=$(systemctl show -p NoNewPrivileges "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
if [[ "$NNP_VAL" == "yes" ]]; then
    ok "NoNewPrivileges=true is enforced"
else
    fail "NoNewPrivileges not enforced (got: ${NNP_VAL:-empty})"
fi

SUID_RESTRICT=$(systemctl show -p RestrictSUIDSGID "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null | cut -d= -f2)
if [[ "$SUID_RESTRICT" == "yes" ]]; then
    ok "RestrictSUIDSGID=true is enforced"
else
    fail "RestrictSUIDSGID not enforced (got: ${SUID_RESTRICT:-empty})"
fi

systemctl stop "agent@${DUMMY_ACCOUNT}.service" 2>/dev/null || true

# =====================================================
# Section 6: Journal logging
# =====================================================
heading "Phase 6: Journal logging"

LOG_LINES=$(journalctl -u "agent@${DUMMY_ACCOUNT}.service" --no-pager 2>/dev/null | wc -l)
note "Journal entries for test service: $LOG_LINES"
if (( LOG_LINES > 0 )); then
    ok "Journal captured $LOG_LINES lines for the test service"
else
    fail "No journal entries found for the test service"
fi

# =====================================================
# Section 7: Boot-time services
# =====================================================
heading "Phase 7: Boot services"

if systemctl list-unit-files agent-manager.service --no-legend 2>/dev/null | grep -q "agent-manager"; then
    ok "agent-manager.service is installed"
    MGR_RESULT=$(systemctl show -p Result agent-manager.service 2>/dev/null | cut -d= -f2)
    note "agent-manager result: $MGR_RESULT"
    if [[ "$MGR_RESULT" == "success" ]]; then
        ok "agent-manager.service ran successfully"
    else
        fail "agent-manager.service result: $MGR_RESULT"
    fi
else
    fail "agent-manager.service not found"
fi

if systemctl list-unit-files api-keys-sync.service --no-legend 2>/dev/null | grep -q "api-keys-sync"; then
    ok "api-keys-sync.service is installed"
else
    fail "api-keys-sync.service not found"
fi

# =====================================================
# Summary
# =====================================================
heading "Summary"

GRAND_TOTAL=$((TALLY_PASS + TALLY_FAIL))
say ""
say "  Total:  $GRAND_TOTAL tests"
say "  ${CLR_GRN}Passed: $TALLY_PASS${CLR_OFF}"
if (( TALLY_FAIL > 0 )); then
    say "  ${CLR_RED}Failed: $TALLY_FAIL${CLR_OFF}"
    say ""
    say "${CLR_RED}${CLR_BLD}FAIL${CLR_OFF} — $TALLY_FAIL test(s) did not pass. See docs/systemd-cgroup-docker-compat.md for guidance."
    exit 1
else
    say ""
    say "${CLR_GRN}${CLR_BLD}PASS${CLR_OFF} — All checks passed. systemd service management is working correctly."
    exit 0
fi
