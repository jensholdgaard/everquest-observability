#!/usr/bin/env bash
# Privilege separation + secret hardening. Root on the box is still game-over (it must be),
# but this closes the realistic vector: an arbitrary-file-read bug in one internet-facing
# service leaking another service's secrets. Each service gets its own user; file ownership
# is the access matrix; the bot token is systemd-encrypted (plaintext never at rest in /etc).
set -euo pipefail

# --- 1. Service users --------------------------------------------------------
for u in prometheus perses eqgw eqbot; do
  id -u "$u" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$u"
done

# --- 2. Ownership matrix -----------------------------------------------------
chown -R prometheus:prometheus /var/lib/prometheus
chown root:prometheus /etc/prometheus/prometheus.yml && chmod 640 /etc/prometheus/prometheus.yml

chown -R perses:perses /var/lib/perses
chown perses:perses /etc/perses/perses.yaml && chmod 400 /etc/perses/perses.yaml
# Provisioning: bot writes member files, Perses reads. setgid keeps group=perses on new files.
chown -R eqbot:perses /etc/perses/provisioning
chmod 2750 /etc/perses/provisioning
chmod 640 /etc/perses/provisioning/*.yaml 2>/dev/null || true

chown root:eqgw /etc/eq-otel/gateway.yaml && chmod 640 /etc/eq-otel/gateway.yaml
touch /etc/eq-otel/tokens.txt
chown eqbot:eqgw /etc/eq-otel/tokens.txt && chmod 640 /etc/eq-otel/tokens.txt

# --- 3. Bot token: encrypt at rest via systemd-creds -------------------------
if [ -f /etc/eq-otel/bot.env ]; then
  tok=$(sed -n 's/^DISCORD_BOT_TOKEN=//p' /etc/eq-otel/bot.env)
  printf '%s' "$tok" | systemd-creds encrypt --name=bot_token - /etc/eq-otel/bot_token.cred
  rm -f /etc/eq-otel/bot.env
fi

# --- 4. Hardened unit drop-ins ----------------------------------------------
mkharden() { mkdir -p "/etc/systemd/system/$1.service.d"; cat > "/etc/systemd/system/$1.service.d/harden.conf"; }

mkharden prometheus <<'EOF'
[Service]
User=prometheus
Group=prometheus
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/prometheus
EOF

mkharden perses <<'EOF'
[Service]
User=perses
Group=perses
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/perses
EOF

mkharden eq-gateway <<'EOF'
[Service]
User=eqgw
Group=eqgw
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
EOF

mkharden eq-bot <<'EOF'
[Service]
User=eqbot
Group=eqbot
# Clear the old plaintext EnvironmentFile; token now arrives via encrypted credential.
EnvironmentFile=
LoadCredentialEncrypted=bot_token:/etc/eq-otel/bot_token.cred
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/etc/eq-otel /etc/perses/provisioning
EOF

# --- 5. Root-owned path units: react to bot's file changes -------------------
cat > /etc/systemd/system/eq-gateway-reload.path <<'EOF'
[Unit]
Description=Restart gateway when member tokens change
[Path]
PathModified=/etc/eq-otel/tokens.txt
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/eq-gateway-reload.service <<'EOF'
[Unit]
Description=Restart eq-gateway (tokens changed)
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart eq-gateway
EOF
cat > /etc/systemd/system/perses-reload.path <<'EOF'
[Unit]
Description=Restart Perses when provisioning changes
[Path]
PathModified=/etc/perses/provisioning
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/perses-reload.service <<'EOF'
[Unit]
Description=Restart perses (provisioning changed)
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart perses
EOF

# --- 6. Apply ----------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now eq-gateway-reload.path perses-reload.path
systemctl restart prometheus eq-gateway perses eq-bot
sleep 5
echo "--- services ---"
systemctl is-active prometheus perses eq-gateway eq-bot caddy
echo "--- running as ---"
ps -eo user,comm | grep -E 'prometheus|perses|otelcol|python' | sort -u
