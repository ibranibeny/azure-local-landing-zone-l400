#!/usr/bin/env bash
# Install a separate, loopback-only NGINX identity demonstration on Ubuntu.
set -euo pipefail
umask 022

if [[ ${EUID} -ne 0 ]]; then
    printf 'Run this reviewed script with sudo bash install-vm-web.sh\n' >&2
    exit 1
fi

. /etc/os-release
if [[ ${ID} != ubuntu || ! ${VERSION_ID} =~ ^(22\.04|24\.04)$ ]]; then
    printf 'Supported guest operating systems: Ubuntu 22.04 and 24.04 LTS.\n' >&2
    exit 1
fi

site=/etc/nginx/conf.d/azure-local-nginx-demo.conf
marker='# Managed by install-vm-web.sh (Azure Local demo).'
if [[ -L ${site} ]]; then
    printf 'Refusing to replace a symbolic link: %s\n' "${site}" >&2
    exit 1
fi
if [[ -e ${site} ]] && ! grep -Fxq "${marker}" "${site}"; then
    printf 'Refusing to overwrite an unmanaged NGINX configuration: %s\n' "${site}" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
existing_nginx=false
if command -v nginx >/dev/null 2>&1; then existing_nginx=true; fi
apt-get update
apt-get install -y --no-install-recommends nginx python3 curl iproute2
if [[ ${existing_nginx} == false && -L /etc/nginx/sites-enabled/default ]] &&
   [[ $(readlink -f /etc/nginx/sites-enabled/default) == /etc/nginx/sites-available/default ]]; then
    rm /etc/nginx/sites-enabled/default
fi

install -d -o root -g root -m 0755 \
    /usr/local/lib/azure-local-nginx-demo \
    /var/www/azure-local-nginx-demo

cat > /usr/local/lib/azure-local-nginx-demo/render-identity.py <<'PY'
#!/usr/bin/env python3
"""Render a guest identity snapshot; this does not discover cluster ownership."""
import datetime
import html
import json
import pathlib
import platform
import socket
import subprocess


def command(*args):
    return subprocess.check_output(args, text=True, timeout=10).strip()


interfaces = json.loads(command("ip", "-j", "-4", "address", "show", "scope", "global"))
addresses = [
    (interface["ifname"], address["local"])
    for interface in interfaces
    for address in interface.get("addr_info", [])
    if address.get("family") == "inet" and address.get("scope") == "global"
]
fqdn_result = subprocess.run(
    ["hostname", "--fqdn"], capture_output=True, text=True, timeout=10, check=False
)
fqdn = fqdn_result.stdout.strip() if fqdn_result.returncode == 0 else socket.getfqdn()
fields = [
    ("Guest hostname", socket.gethostname()),
    ("Guest FQDN (local resolver result)", fqdn),
    ("Guest kernel", platform.release()),
    ("Guest boot ID", pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()),
    ("Snapshot generated (UTC)", datetime.datetime.now(datetime.timezone.utc).isoformat()),
]
fields.extend((f"Guest IPv4 on {interface}", address) for interface, address in addresses)
if not addresses:
    fields.append(("Guest IPv4", "No global IPv4 address at snapshot time"))
rows = "\n".join(
    f"<tr><th scope=\"row\">{html.escape(label)}</th><td>{html.escape(value)}</td></tr>"
    for label, value in fields
)
document = (
    "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    "<title>Azure Local guest identity snapshot</title></head><body>"
    "<h1>Ubuntu VM: NGINX demonstration</h1>"
    "<p>This is a static guest snapshot, regenerated at installation and each boot. "
    "It is not live telemetry and does not identify the owning Hyper-V node.</p>"
    "<table><caption>Guest identity at snapshot time</caption><tbody>"
    + rows
    + "</tbody></table>"
    "<p>For a fresh snapshot, restart azure-local-nginx-demo.service inside this guest. "
    "Verify cluster ownership separately in Failover Cluster Manager.</p>"
    "</body></html>\n"
)
destination = pathlib.Path("/var/www/azure-local-nginx-demo/index.html")
destination.write_text(document, encoding="utf-8")
destination.chmod(0o644)
PY
chmod 0644 /usr/local/lib/azure-local-nginx-demo/render-identity.py

cat > /etc/systemd/system/azure-local-nginx-demo.service <<'UNIT'
[Unit]
Description=Generate the Azure Local NGINX guest identity snapshot
Wants=network-online.target
After=network-online.target
Before=nginx.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/azure-local-nginx-demo/render-identity.py
RemainAfterExit=yes
User=root
Group=root
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/www/azure-local-nginx-demo

[Install]
WantedBy=multi-user.target
UNIT

cat > "${site}" <<'NGINX'
# Managed by install-vm-web.sh (Azure Local demo).
server {
    listen 127.0.0.1:8081;
    server_name _;
    server_tokens off;
    root /var/www/azure-local-nginx-demo;
    index index.html;
    access_log off;
    add_header Cache-Control "no-store" always;
    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX

python3 -m py_compile /usr/local/lib/azure-local-nginx-demo/render-identity.py
nginx -t
systemctl daemon-reload
systemctl enable azure-local-nginx-demo.service
systemctl restart azure-local-nginx-demo.service
systemctl enable nginx.service
if systemctl is-active --quiet nginx.service; then
    systemctl reload nginx.service
else
    systemctl start nginx.service
fi
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:8081/ > /dev/null
printf '%s\n' \
    'Ready: http://127.0.0.1:8081/ (inside this guest only).' \
    'Snapshot refresh: sudo systemctl restart azure-local-nginx-demo.service' \
    'Existing NGINX sites and the Python application on port 8080 are unchanged.' \
    'Review other listeners: sudo ss -ltnp. Existing NGINX sites were not removed.'
