#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: b13kjack
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/vectorize-io/hindsight

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  curl \
  python3 \
  python3-dev \
  python3-pip \
  python3-venv
msg_ok "Installed Dependencies"

PG_VERSION="18" PG_MODULES="pgvector" setup_postgresql
mkdir -p /opt/hindsight
PG_DB_NAME="hindsight" PG_DB_USER="hindsight" PG_DB_EXTENSIONS="vector" PG_DB_CREDS_FILE="/opt/hindsight/postgresql.creds" setup_postgresql_db

NODE_VERSION="24" setup_nodejs

msg_info "Installing Hindsight API (Python, ~2GB with local embedding model)"
$STD python3 -m venv /opt/hindsight/venv
$STD /opt/hindsight/venv/bin/pip install --upgrade pip
$STD /opt/hindsight/venv/bin/pip install hindsight-api
msg_ok "Installed Hindsight API"

msg_info "Installing Hindsight Control Plane (Node.js UI)"
$STD npm install -g @vectorize-io/hindsight-control-plane
msg_ok "Installed Hindsight Control Plane"

prompt="${var_hindsight_llm_key:-}"
if [[ -z "$prompt" ]]; then
  read -r -p "${TAB3}Enter OpenAI API key for memory extraction (leave empty to add later in /opt/hindsight/.env): " prompt
fi

msg_info "Configuring Hindsight"
cat <<EOF >/opt/hindsight/.env
HINDSIGHT_API_HOST=0.0.0.0
HINDSIGHT_API_PORT=8888
HINDSIGHT_API_LOG_LEVEL=info
HINDSIGHT_API_DATABASE_URL=postgresql://${PG_DB_USER}:${PG_DB_PASS}@127.0.0.1:5432/${PG_DB_NAME}
HINDSIGHT_API_LLM_API_KEY=${prompt}
HINDSIGHT_CP_DATAPLANE_API_URL=http://localhost:8888
PORT=9999
HOSTNAME=0.0.0.0
EOF
chmod 600 /opt/hindsight/.env
msg_ok "Configured Hindsight"

msg_info "Creating Hindsight API Service"
cat <<EOF >/etc/systemd/system/hindsight-api.service
[Unit]
Description=Hindsight API (agent memory)
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
EnvironmentFile=/opt/hindsight/.env
ExecStart=/opt/hindsight/venv/bin/hindsight-api
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Created Hindsight API Service"

msg_info "Creating Hindsight Control Plane Service"
cat <<EOF >/etc/systemd/system/hindsight-control-plane.service
[Unit]
Description=Hindsight Control Plane (memory UI)
After=network-online.target hindsight-api.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/hindsight/.env
ExecStart=/usr/local/bin/hindsight-control-plane
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q --now hindsight-api
systemctl enable -q --now hindsight-control-plane
msg_ok "Created Hindsight Control Plane Service"

msg_info "Waiting for Hindsight API (first boot downloads the embedding model, may take several minutes)"
for ((i = 1; i <= 120; i++)); do
  if curl -sf --max-time 5 http://127.0.0.1:8888/health >/dev/null 2>&1; then
    break
  fi
  if ! systemctl is-active -q hindsight-api; then
    msg_error "Hindsight API service failed to stay running — dumping logs:"
    journalctl -u hindsight-api -n 50 --no-pager || true
    exit 1
  fi
  sleep 5
  if ((i == 120)); then
    msg_warn "API not healthy yet — it may still be downloading the embedding model; check 'curl http://127.0.0.1:8888/health' later"
  fi
done
msg_ok "Hindsight API is responding"

motd_ssh
customize
cleanup_lxc
