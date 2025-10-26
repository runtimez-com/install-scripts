#!/usr/bin/env bash
set -euo pipefail

# === Runtimez OpenTelemetry Collector Installer ===
# Supports: Ubuntu, Debian, RHEL, Amazon Linux, CentOS

# --- Parse arguments ---
TENANT_ID=""
API_KEY=""
ENDPOINT="https://ingest.runtimez.io:4317"
OTEL_VER="0.116.0"
INSTALL_DIR="/opt/otelcol-contrib"
CONFIG_PATH="/etc/runtimez/runtimez.yaml"
SERVICE_FILE="/etc/systemd/system/runtimez-otel.service"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) TENANT_ID="$2"; shift 2;;
    --api-key) API_KEY="$2"; shift 2;;
    --endpoint) ENDPOINT="$2"; shift 2;;
    --version) OTEL_VER="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "$TENANT_ID" || -z "$API_KEY" ]]; then
  echo "❌ Missing required arguments --tenant and --api-key"
  exit 1
fi

echo "➡️ Installing Runtimez OpenTelemetry Collector..."
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH_TAG="amd64";;
  aarch64|arm64) ARCH_TAG="arm64";;
  *) echo "Unsupported architecture: $ARCH"; exit 1;;
esac

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

echo "📦 Downloading otelcol-contrib v${OTEL_VER} for ${ARCH_TAG}..."
curl -sSL -o otelcol.tar.gz \
  "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VER}/otelcol-contrib_${OTEL_VER}_linux_${ARCH_TAG}.tar.gz"

sudo mkdir -p "$INSTALL_DIR"
sudo tar -xzf otelcol.tar.gz -C "$INSTALL_DIR"
sudo ln -sf "$INSTALL_DIR/otelcol-contrib" /usr/local/bin/otelcol-contrib

# --- Config ---
echo "⚙️ Writing Runtimez collector config to $CONFIG_PATH..."
sudo mkdir -p /etc/runtimez
sudo tee "$CONFIG_PATH" > /dev/null <<EOF
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu: {}
      memory: {}
      filesystem: {}
      network: {}
      load: {}
      paging: {}

exporters:
  otlp:
    endpoint: ${ENDPOINT}
    headers:
      X-Tenant-Id: "${TENANT_ID}"
      X-Api-Key: "${API_KEY}"
    compression: gzip
    tls:
      insecure: false

processors:
  batch: {}

service:
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [batch]
      exporters: [otlp]
EOF

# --- Systemd unit ---
echo "🧩 Installing systemd service..."
sudo tee "$SERVICE_FILE" > /dev/null <<'EOF'
[Unit]
Description=Runtimez OpenTelemetry Collector
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/otelcol-contrib --config /etc/runtimez/runtimez.yaml
Restart=on-failure
User=root
LimitNOFILE=65535
Environment=GODEBUG=x509sha1=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now runtimez-otel

sleep 2
sudo systemctl status runtimez-otel --no-pager || true

echo ""
echo "✅ Runtimez Collector installation complete!"
echo "   Tenant: $TENANT_ID"
echo "   Endpoint: $ENDPOINT"
echo "   Config: $CONFIG_PATH"
echo ""
echo "Use 'journalctl -u runtimez-otel -f' to view live logs."
echo "Use 'systemctl restart runtimez-otel' to restart the collector."
