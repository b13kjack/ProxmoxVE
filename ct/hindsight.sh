#!/usr/bin/env bash
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: b13kjack
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/vectorize-io/hindsight

APP="Hindsight"
var_tags="${var_tags:-ai;database}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-14}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /opt/hindsight/venv/bin/hindsight-api ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Updating Hindsight API (Python)"
  $STD /opt/hindsight/venv/bin/pip install --upgrade pip
  $STD /opt/hindsight/venv/bin/pip install --upgrade hindsight-api
  msg_ok "Updated Hindsight API"

  msg_info "Updating Hindsight Control Plane (Node.js UI)"
  $STD npm update -g @vectorize-io/hindsight-control-plane
  msg_ok "Updated Hindsight Control Plane"

  msg_info "Restarting Services"
  systemctl restart hindsight-api hindsight-control-plane
  msg_ok "Restarted Services"

  msg_info "Waiting for Hindsight API"
  for ((i = 1; i <= 24; i++)); do
    if curl -sf --max-time 5 http://127.0.0.1:8888/health >/dev/null 2>&1; then
      break
    fi
    sleep 5
    if ((i == 24)); then
      msg_warn "API not healthy yet — check 'journalctl -u hindsight-api'"
    fi
  done
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URLs:${CL}"
echo -e "${GATEWAY}${BGN}API: http://${IP}:8888${CL}"
echo -e "${GATEWAY}${BGN}UI: http://${IP}:9999${CL}"
echo -e "${INFO}${YW}Memory extraction needs an LLM key in:${CL}"
echo -e "${TAB}${BGN}/opt/hindsight/.env${CL} (HINDSIGHT_API_LLM_API_KEY, then 'systemctl restart hindsight-api')"
echo -e "${INFO}${YW}PostgreSQL credentials stored in:${CL}"
echo -e "${TAB}${BGN}/opt/hindsight/postgresql.creds${CL}"
