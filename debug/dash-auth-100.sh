#!/bin/bash
# Run INSIDE CT100 as root: bash /tmp/dash-auth-100.sh "<base64-password>"
set -e
DPB="$1"
cd /home/hermes
plug=$(find /home/hermes /home/hermes/.hermes /home/hermes/.local -maxdepth 7 -path "*dashboard_auth*" -name "basic*.py" 2>/dev/null | head -n 1)
[ -n "$plug" ] || { echo "PLUGIN-NOT-FOUND"; exit 3; }
root="${plug%%/plugins/dashboard_auth*}"
PYBIN=$(ls -d /home/hermes/.hermes/tools/python-*/bin/python3 2>/dev/null | head -n 1)
[ -x "$PYBIN" ] || { echo "PYBIN-NOT-FOUND"; exit 4; }
export DPASS=$(echo "$DPB" | base64 -d)
HASH=$(PYTHONPATH="$root" "$PYBIN" -c 'import os; from plugins.dashboard_auth.basic import hash_password; print(hash_password(os.environ["DPASS"]))')
[ -n "$HASH" ] || { echo "HASH-EMPTY"; exit 5; }
SECRET=$(openssl rand -hex 32)
cp /home/hermes/.hermes/config.yaml /home/hermes/.hermes/config.yaml.bak-dashboard
cat >> /home/hermes/.hermes/config.yaml <<YAML
dashboard:
  basic_auth:
    username: b13kjack
    password_hash: "$HASH"
    secret: $SECRET
YAML
chown hermes:hermes /home/hermes/.hermes/config.yaml /home/hermes/.hermes/config.yaml.bak-dashboard
sed -i 's/--host 127.0.0.1/--host 0.0.0.0/' /etc/systemd/system/hermes-dashboard.service
systemctl daemon-reload
systemctl restart hermes-dashboard
sleep 6
systemctl is-active hermes-dashboard
ss -ltn | grep 9119
BAD=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:9119/auth/password-login -H 'Content-Type: application/json' -d '{"username":"b13kjack","password":"wrong","provider":"basic"}')
echo "bad-probe:$BAD (want 401)"
GOOD=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:9119/auth/password-login -H 'Content-Type: application/json' -d "{\"username\":\"b13kjack\",\"password\":\"$DPASS\",\"provider\":\"basic\"}")
echo "good-probe:$GOOD (want 200)"
unset DPASS
echo DONE
