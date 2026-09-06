#!/usr/bin/env bash
set -euo pipefail

VERSION="${LIVEKIT_VERSION:-1.13.6}"
DOMAIN="${LIVEKIT_DOMAIN:-meshchat-losa.ru}"
ARCHIVE="livekit_${VERSION}_linux_amd64.tar.gz"
RELEASE_URL="https://github.com/livekit/livekit/releases/download/v${VERSION}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
curl -fsSL --retry 3 "$RELEASE_URL/$ARCHIVE" -o "$work_dir/$ARCHIVE"
curl -fsSL --retry 3 "$RELEASE_URL/checksums.txt" -o "$work_dir/checksums.txt"
(cd "$work_dir" && grep " $ARCHIVE$" checksums.txt | sha256sum -c -)
tar -xzf "$work_dir/$ARCHIVE" -C "$work_dir"
install -m 0755 "$work_dir/livekit-server" /usr/local/bin/livekit-server

id livekit >/dev/null 2>&1 || useradd --system --home /var/lib/livekit --shell /usr/sbin/nologin livekit
install -d -m 0750 -o livekit -g livekit /etc/livekit /var/lib/livekit
install -d -m 0750 /etc/mesh-messenger

api_key="$(openssl rand -hex 16)"
api_secret="$(openssl rand -hex 32)"
if [[ -f /etc/mesh-messenger/livekit.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/mesh-messenger/livekit.env
  set +a
  api_key="${MESH_CALL_SFU_API_KEY:-$api_key}"
  api_secret="${MESH_CALL_SFU_API_SECRET:-$api_secret}"
fi

umask 077
printf '%s\n' \
  'MESH_CALL_SFU_ENABLED=0' \
  "MESH_CALL_SFU_URL=wss://$DOMAIN" \
  "MESH_CALL_SFU_API_KEY=$api_key" \
  "MESH_CALL_SFU_API_SECRET=$api_secret" \
  'MESH_CALL_SFU_TOKEN_TTL_SECONDS=300' \
  'MESH_CALL_SFU_REQUIRE_E2EE=1' \
  > /etc/mesh-messenger/livekit.env

printf '%s\n' \
  'port: 7880' \
  'rtc:' \
  '  tcp_port: 7881' \
  '  port_range_start: 50000' \
  '  port_range_end: 50100' \
  '  use_external_ip: true' \
  'redis:' \
  '  address: 127.0.0.1:6379' \
  'keys:' \
  "  $api_key: $api_secret" \
  'room:' \
  '  auto_create: true' \
  '  empty_timeout: 300' \
  '  departure_timeout: 20' \
  'logging:' \
  '  level: info' \
  > /etc/livekit/livekit.yaml
chown livekit:livekit /etc/livekit/livekit.yaml
chmod 0600 /etc/livekit/livekit.yaml /etc/mesh-messenger/livekit.env

install -m 0644 server/ops/systemd/mesh-livekit.service /etc/systemd/system/mesh-livekit.service
install -m 0644 server/ops/nginx/meshchat-livekit-location.conf /etc/nginx/snippets/meshchat-livekit-location.conf
install -d -m 0755 /etc/systemd/system/mesh-chat-worker@.service.d
printf '%s\n' '[Service]' 'EnvironmentFile=/etc/mesh-messenger/livekit.env' \
  > /etc/systemd/system/mesh-chat-worker@.service.d/livekit.conf

for site in \
  /etc/nginx/sites-available/meshchat-web \
  /etc/nginx/sites-enabled/meshchat-web; do
  if [[ -f "$site" ]] && ! grep -q 'meshchat-livekit-location.conf' "$site"; then
    sed -i '/include \/etc\/nginx\/snippets\/meshchat-realtime-location.conf;/i\    include /etc/nginx/snippets/meshchat-livekit-location.conf;\n' "$site"
  fi
done

if command -v ufw >/dev/null 2>&1; then
  ufw allow 7881/tcp
  ufw allow 50000:50100/udp
fi
nginx -t
systemctl daemon-reload
systemctl enable --now mesh-livekit.service
systemctl --no-pager --full status mesh-livekit.service
