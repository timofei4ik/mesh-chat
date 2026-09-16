#!/usr/bin/env bash
set -euo pipefail

stage=/root/mesh_messenger/.deploy_stage_ui222
root=/var/www/meshchat-web
backup=/root/mesh_messenger/.deploy_backups/ui222-$(date -u +%Y%m%dT%H%M%SZ)
cd "$stage"
sha256sum -c SHA256SUMS
python3 - <<'PY'
import json
from pathlib import Path
new = json.loads(Path('apps.json').read_text())
old = json.loads(Path('/var/www/meshchat-web/downloads/apps.json').read_text())
app = next(a for a in new['apps'] if a['id'] == 'meshchat')
assert (app['version'], app['build']) == ('1.1.6', 222)
assert old['catalogVersion'] == 53, 'Catalog changed since release preparation'
assert [a for a in old['apps'] if a['id'] != 'meshchat'] == [a for a in new['apps'] if a['id'] != 'meshchat']
PY
mkdir -p "$stage/web" "$backup"
unzip -q -o MeshChat-Web.zip -d "$stage/web"
python3 - <<'PY'
import json
from pathlib import Path
version = json.loads(Path('web/version.json').read_text())
assert version['version'] == '1.1.6' and str(version['build_number']) == '222', version
assert 'v=1.1.6-222' in Path('web/index.html').read_text()
assert not Path('web/downloads').exists()
PY
tar -czf "$backup/web.tar.gz" --exclude='./downloads' -C "$root" .
for file in MeshChat-Android.apk MeshChat-Windows.zip MeshChat-Web.zip apps.json; do
  cp -p "$root/downloads/$file" "$backup/$file"
done
if [ -f /root/mesh_messenger/deployment/downloads/apps.json ]; then
  cp -p /root/mesh_messenger/deployment/downloads/apps.json "$backup/source-apps.json"
fi

# Install artifacts before advertising them in the download catalog.
for file in MeshChat-Android.apk MeshChat-Windows.zip MeshChat-Web.zip; do
  install -m 644 "$stage/$file" "$root/downloads/$file.next"
  mv -f "$root/downloads/$file.next" "$root/downloads/$file"
done
rsync -a --chmod=D755,F644 --exclude=index.html --exclude=flutter_bootstrap.js --exclude=version.json "$stage/web/" "$root/"
for file in flutter_bootstrap.js index.html version.json; do
  install -m 644 "$stage/web/$file" "$root/$file.next"
  mv -f "$root/$file.next" "$root/$file"
done
install -m 644 "$stage/apps.json" "$root/downloads/apps.json.next"
mv -f "$root/downloads/apps.json.next" "$root/downloads/apps.json"
install -m 644 "$stage/apps.json" /root/mesh_messenger/deployment/downloads/apps.json.next
mv -f /root/mesh_messenger/deployment/downloads/apps.json.next /root/mesh_messenger/deployment/downloads/apps.json
printf 'Backup: %s\n' "$backup"
cd "$root/downloads"
sha256sum -c "$stage/SHA256SUMS"
cat "$root/version.json"
