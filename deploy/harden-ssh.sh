#!/usr/bin/env bash
# SSH exposure on the VM (2026-09-05). Root with one ed25519 key is the only login there is
# (702 accepted logins in a week, all publickey, all from one address), yet sshd still
# accepted password attempts: 4,700 guesses and 2,100 invalid usernames a day from ~285
# addresses. This turns password auth off for good, rate-limits port 22, bans repeat
# offenders, and stops the firewall from logging every dropped packet to the kernel log.
# Idempotent; validates sshd config before reloading so a typo cannot lock the door.
set -euo pipefail

# --- 1. sshd: keys only, root only, short grace ---------------------------------------
# Drop-in sorts before cloud-init's (none present today) and the main file; sshd takes
# the first value it sees, so this wins.
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-nocturnal-hardening.conf <<'CONF'
# Managed by everquest-observability/deploy/harden-ssh.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin prohibit-password
AllowUsers root
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
CONF
chmod 644 /etc/ssh/sshd_config.d/00-nocturnal-hardening.conf
sshd -t
systemctl reload ssh
echo "sshd: $(sshd -T | grep -E '^(passwordauthentication|authenticationmethods|maxauthtries|logingracetime) ' | tr '\n' ' ')"

# --- 2. ufw: rate-limit 22 (6 new connections / 30 s per source), stop logging drops ---
ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
ufw --force delete allow 22/tcp  >/dev/null 2>&1 || true
ufw limit 22/tcp comment 'ssh, rate-limited' >/dev/null
ufw logging off >/dev/null
echo "ufw: $(ufw status | grep -E '^22/tcp' | head -1)"

# --- 3. fail2ban: sshd jail on the journal, 1 h ban after 4 failures in 10 min --------
export DEBIAN_FRONTEND=noninteractive
dpkg -s fail2ban >/dev/null 2>&1 || apt-get install -y -qq fail2ban >/dev/null
cat > /etc/fail2ban/jail.d/sshd.local <<'JAIL'
# Managed by everquest-observability/deploy/harden-ssh.sh
[DEFAULT]
backend = systemd
banaction = ufw
bantime = 1h
findtime = 10m
maxretry = 4
# Repeat offenders stay out longer each time, up to a week.
bantime.increment = true
bantime.maxtime = 1w

[sshd]
enabled = true
mode = aggressive
JAIL
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban
sleep 2
echo "fail2ban: $(fail2ban-client status sshd | grep -E 'Currently banned|Total banned' | tr -s ' ' | tr '\n' ';')"
