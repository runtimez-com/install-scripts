#!/usr/bin/env bash
set -euo pipefail

# === Runtimez OTEL Collector Installer (HTTP endpoints per signal) ===

API_KEY=""
BASE_URL="https://ingest.runtimez.io"
OTEL_VER="0.116.0"
INSTALL_DIR="/opt/otelcol-contrib"
CONFIG_PATH="/etc/runtimez/runtimez.yaml"
SERVICE_FILE="/etc/systemd/system/runtimez-otel.service"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)  API_KEY="$2"; shift 2;;
    --base-url) BASE_URL="$2"; shift 2;;
    --version)  OTEL_VER="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "$API_KEY" ]]; then
  echo "❌ Missing required argument: --api-key"
  exit 1
fi

echo "➡️ Installing otelcol-contrib v${OTEL_VER} ..."
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TAG="amd64";;
  aarch64|arm64) ARCH_TAG="arm64";;
  *) echo "Unsupported arch: $ARCH"; exit 1;;
esac

TMP_DIR=$(mktemp -d); cd "$TMP_DIR"
curl --proto '=https' --tlsv1.2 -fOL otelcol.tar.gz \
  "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VER}/otelcol-contrib_${OTEL_VER}_linux_${ARCH_TAG}.tar.gz"
sudo mkdir -p "$INSTALL_DIR"
sudo tar -xzf otelcol.tar.gz -C "$INSTALL_DIR"
sudo ln -sf "$INSTALL_DIR/otelcol-contrib" /usr/local/bin/otelcol-contrib

# --------- Write config (uses otlphttp with per-signal endpoints) ----------
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
  # Optional: receive app traces/logs on localhost and forward to Runtimez
  otlp:
    protocols:
      http:
      grpc:

exporters:
  # Use OTLP over HTTP with dedicated endpoints
  otlphttp:
    # unified headers for all signals
    headers:
      X-Api-Key: "${API_KEY}"
    compression: gzip
    # Per-signal endpoints (your gateway paths)
    traces_endpoint:  "${BASE_URL}/ingest/otlp/traces"
    metrics_endpoint: "${BASE_URL}/ingest/otlp/metrics"
    logs_endpoint:    "${BASE_URL}/ingest/otlp/logs"

processors:
  batch: {}

service:
  pipelines:
    # Host metrics → Runtimez
    metrics:
      receivers: [hostmetrics]
      processors: [batch]
      exporters: [otlphttp]

    # Optional pipelines: enable if this VM will forward app telemetry too
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp]

    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp]
EOF

# --------- systemd unit ----------
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
echo "✅ Runtimez Collector installed"
echo "   Base URL: ${BASE_URL}"
echo "   Traces:   ${BASE_URL}/ingest/otlp/traces"
echo "   Metrics:  ${BASE_URL}/ingest/otlp/metrics"
echo "   Logs:     ${BASE_URL}/ingest/otlp/logs"
echo "   Config:   ${CONFIG_PATH}"
echo ""
echo "View logs:   journalctl -u runtimez-otel -f"
