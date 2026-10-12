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

# LLM backend (mirrors the local hermes-hindsight container: openai-codex /
# gpt-6-luna, keyless). Override with var_hindsight_llm_provider / _model / _key.
LLM_PROVIDER="${var_hindsight_llm_provider:-openai-codex}"
LLM_MODEL="${var_hindsight_llm_model:-gpt-6-luna}"
# Providers that authenticate without a static API key (OAuth logins, local
# servers, cloud roles). Everything else fails fast below when the key is empty.
case "$LLM_PROVIDER" in
  openai-codex|claude-code|cursor|github-copilot|nous|xai-oauth|ollama|lmstudio|llamacpp|bedrock|vertexai|none)
    LLM_NEEDS_KEY=0 ;;
  *) LLM_NEEDS_KEY=1 ;;
esac

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

# Codex CLI is only needed for the one-time OAuth login when the keyless
# openai-codex provider is selected.
if [[ "$LLM_PROVIDER" == "openai-codex" ]]; then
  msg_info "Installing Codex CLI (for one-time OAuth login)"
  $STD npm install -g @openai/codex
  mkdir -p /var/lib/hindsight/codex
  chmod 700 /var/lib/hindsight/codex
  msg_ok "Installed Codex CLI"
fi

msg_info "Installing Hindsight API (Python, ~2GB with local embedding model)"
$STD python3 -m venv /opt/hindsight/venv
$STD /opt/hindsight/venv/bin/pip install --upgrade pip
$STD /opt/hindsight/venv/bin/pip install hindsight-api
msg_ok "Installed Hindsight API"

msg_info "Installing Hindsight Control Plane (Node.js UI)"
$STD npm install -g @vectorize-io/hindsight-control-plane
msg_ok "Installed Hindsight Control Plane"

prompt="${var_hindsight_llm_key:-}"
if [[ "$LLM_NEEDS_KEY" == "1" && -z "$prompt" ]]; then
  read -r -p "${TAB3}Enter LLM API key for memory extraction (required by provider '${LLM_PROVIDER}'): " prompt
fi
if [[ "$LLM_NEEDS_KEY" == "1" && -z "$prompt" ]]; then
  msg_error "HINDSIGHT_API_LLM_API_KEY is empty and provider '${LLM_PROVIDER}' needs one — hindsight-api would exit with 'LLM API key is required'. Re-run with var_hindsight_llm_key=<key>, or switch to a keyless provider (var_hindsight_llm_provider=openai-codex)."
  exit 1
fi

msg_info "Configuring Hindsight (provider: ${LLM_PROVIDER}, model: ${LLM_MODEL:-default})"
{
  echo "HINDSIGHT_API_HOST=0.0.0.0"
  echo "HINDSIGHT_API_PORT=8888"
  echo "HINDSIGHT_API_LOG_LEVEL=info"
  echo "HINDSIGHT_API_DATABASE_URL=postgresql://${PG_DB_USER}:${PG_DB_PASS}@127.0.0.1:5432/${PG_DB_NAME}"
  echo "HINDSIGHT_API_LLM_PROVIDER=${LLM_PROVIDER}"
  [[ -n "$LLM_MODEL" ]] && echo "HINDSIGHT_API_LLM_MODEL=${LLM_MODEL}"
  [[ -n "$prompt" ]] && echo "HINDSIGHT_API_LLM_API_KEY=${prompt}"
  if [[ "$LLM_PROVIDER" == "openai-codex" ]]; then
    echo "HINDSIGHT_API_LLM_CODEX_HOME=/var/lib/hindsight/codex"
  fi
  # Concurrency/reasoning tuning mirrored from the working local hermes-hindsight
  # container (subscription lane: low effort, limited parallelism).
  echo "HINDSIGHT_API_LLM_MAX_CONCURRENT=4"
  echo "HINDSIGHT_API_LLM_TIMEOUT=180"
  echo "HINDSIGHT_API_LLM_REASONING_EFFORT=low"
  echo "HINDSIGHT_API_RETAIN_LLM_MAX_CONCURRENT=3"
  echo "HINDSIGHT_API_RETAIN_LLM_REASONING_EFFORT=low"
  echo "HINDSIGHT_API_REFLECT_LLM_REASONING_EFFORT=low"
  echo "HINDSIGHT_API_CONSOLIDATION_LLM_MAX_CONCURRENT=1"
  echo "HINDSIGHT_API_CONSOLIDATION_LLM_REASONING_EFFORT=low"
  echo "HINDSIGHT_CP_DATAPLANE_API_URL=http://localhost:8888"
  echo "PORT=9999"
  echo "HOSTNAME=0.0.0.0"
} >/opt/hindsight/.env
chmod 600 /opt/hindsight/.env
msg_ok "Configured Hindsight"

msg_info "Creating Hindsight API Service"
# Dedicated Codex auth home for the service (never shares refresh tokens with
# an interactive Codex session — see "Isolating Codex auth for long-running
# services" in the Hindsight Models docs).
if [[ "$LLM_PROVIDER" == "openai-codex" ]]; then
  CODEX_ENV="Environment=CODEX_HOME=/var/lib/hindsight/codex"
else
  CODEX_ENV=""
fi
cat <<EOF >/etc/systemd/system/hindsight-api.service
[Unit]
Description=Hindsight API (agent memory)
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
EnvironmentFile=/opt/hindsight/.env
${CODEX_ENV}
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

# Codex OAuth is interactive — the API crash-loops until the one-time login
# exists, so don't fail the install over it; print the exact recovery instead.
if [[ "$LLM_PROVIDER" == "openai-codex" && ! -f /var/lib/hindsight/codex/auth.json ]]; then
  msg_warn "Codex OAuth login still needed — the API will restart-loop until then."
  echo -e "${TAB3}On the Proxmox host, run (headless device flow, no browser needed):"
  echo -e "${TAB3}  pct exec <ctid> -- bash -c 'export CODEX_HOME=/var/lib/hindsight/codex; codex login --device-auth'"
  echo -e "${TAB3}Enter the one-time code at https://auth.openai.com/codex/device, then:"
  echo -e "${TAB3}  pct exec <ctid> -- systemctl restart hindsight-api"
  motd_ssh
  customize
  cleanup_lxc
  exit 0
fi

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
