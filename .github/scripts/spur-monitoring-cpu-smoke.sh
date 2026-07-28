#!/usr/bin/env bash
set -euo pipefail

# Runs on the self-hosted runner; SSHes to the SPUR head node (AIC_SPUR_HOST),
# submits a CPU-only srun job (no --gres=gpu), and:
#   1. Launches node-exporter, nvme-exporter, rdma-exporter, and Prometheus
#   2. Runs the vLLM emulator (backed by the existing rocm-aic image)
#   3. Issues 3 LLM prompts and asserts non-empty completions
#   4. Scrapes all active /metrics endpoints and generates a metrics HTML page
#
# The generated metrics-page/index.html is copied back to the runner working
# directory so the workflow can upload it as an artifact and deploy to gh-pages.
#
# Uses the rocm-aic image tarball left by spur-dist-build.sh for the same SHA
# (same TARBALL_DIR convention).  Set AIC_SMOKE_USE_REGISTRY=1 to pull from
# Docker Hub instead.

SHA="${1:?usage: $0 <full-sha>}"
SHORT="${SHA:0:7}"
AIC_IMAGE="rocm-aic-ci-${SHORT}:latest"
AIC_SPUR_HOST="${AIC_SPUR_HOST:?AIC_SPUR_HOST must be set}"
AIC_SPUR_HOST="${AIC_SPUR_HOST//[$'\t\r\n ']}"
AIC_SHARED_NFS="${AIC_SHARED_NFS:?AIC_SHARED_NFS must be set}"
AIC_SPUR_CONTROLLER="${AIC_SPUR_CONTROLLER:?AIC_SPUR_CONTROLLER must be set}"
AIC_SMOKE_USE_REGISTRY="${AIC_SMOKE_USE_REGISTRY:-0}"
TARBALL_DIR="${AIC_SHARED_NFS}/${USER}/images/aic-ci-${SHORT}"
METRICS_PAGE_DIR="${AIC_SHARED_NFS}/${USER}/metrics-page-${SHORT}"

ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "${AIC_SPUR_HOST}" env \
    SHA="${SHA}" \
    AIC_IMAGE="${AIC_IMAGE}" \
    TARBALL_DIR="${TARBALL_DIR}" \
    METRICS_PAGE_DIR="${METRICS_PAGE_DIR}" \
    AIC_SPUR_CONTROLLER="${AIC_SPUR_CONTROLLER}" \
    SPUR_CONTROLLER_ADDR="${AIC_SPUR_CONTROLLER}" \
    AIC_SMOKE_USE_REGISTRY="${AIC_SMOKE_USE_REGISTRY}" \
    bash << 'REMOTE'
set -euo pipefail

SHORT="${SHA:0:7}"
WORKDIR="$HOME/Projects/rocm-aic.${SHORT}"

cleanup() {
    echo "=== Cleaning up ==="
    rm -rf "${WORKDIR}" "${METRICS_PAGE_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Clone the repo at this SHA so we have monitoring/ and docker/ locally
# ---------------------------------------------------------------------------
if [[ ! -d "${WORKDIR}" ]]; then
    git clone --filter=blob:none \
        git@github.com:ROCm/rocm-aic.git "${WORKDIR}"
fi
cd "${WORKDIR}"
git fetch origin "${SHA}"
git checkout "${SHA}"

# ---------------------------------------------------------------------------
# Load or pull the rocm-aic image
# ---------------------------------------------------------------------------
if [[ "${AIC_SMOKE_USE_REGISTRY}" == "1" ]]; then
    docker pull "${AIC_IMAGE}"
else
    echo "=== Loading image from ${TARBALL_DIR} ==="
    docker load -i "${TARBALL_DIR}/rocm-aic.tar"
    docker tag rocm-aic:latest "${AIC_IMAGE}"
fi

export IMAGE_NAME="${AIC_IMAGE}"

# ---------------------------------------------------------------------------
# Submit a CPU-only srun job
# ---------------------------------------------------------------------------
SRUN_SCRIPT="$(mktemp /tmp/aic-cpu-smoke-XXXXXX.sh)"
trap 'rm -f "${SRUN_SCRIPT}"' EXIT

cat > "${SRUN_SCRIPT}" << 'SRUN_BODY'
#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${1}"
AIC_IMAGE="${2}"
METRICS_PAGE_DIR="${3}"
SHA="${4}"
SHORT="${SHA:0:7}"

MON_DIR="${WORKDIR}/monitoring"
METRICS_DIR="/tmp/aic-prom-tsdb-${SHORT}"
mkdir -p "${METRICS_DIR}" "${METRICS_PAGE_DIR}"

export AIC_IMAGE MON_DIR AIC_METRICS_DIR="${METRICS_DIR}"

# Source shared monitoring helpers
# shellcheck source=monitoring/monitoring-lib.sh
source "${MON_DIR}/monitoring-lib.sh"

# GPU exporters are not available on CPU-only nodes; skip them.
export AIC_EXPORTERS=1
export AIC_AMDGPU_EXPORTER=0   # custom flag read in start_monitoring below

cleanup_containers() {
    echo "=== Stopping all containers ==="
    docker rm -f aic-prometheus aic-node-exporter aic-nvme-exporter \
                 aic-rdma-exporter aic-vllm-emulator 2>/dev/null || true
    rm -rf "${METRICS_DIR}"
}
trap cleanup_containers EXIT

# ---------------------------------------------------------------------------
# 1. Start exporters (no GPU)
# ---------------------------------------------------------------------------
echo "=== Starting node-exporter (9100) ==="
if ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/9100" 2>/dev/null; then
    docker run -d --name aic-node-exporter \
        --network host --pid host \
        -v /:/host:ro,rslave \
        quay.io/prometheus/node-exporter:v1.8.2 \
        --path.rootfs=/host \
        --collector.diskstats \
        --collector.nvme \
        --web.listen-address=:9100
fi

echo "=== Building and starting nvme-exporter (9998) ==="
if ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/9998" 2>/dev/null; then
    docker build -q -t aic-nvme-exporter:local "${MON_DIR}/nvme-exporter"
    docker run -d --name aic-nvme-exporter \
        --network host --pid host --privileged \
        -v /dev:/dev -v /sys:/sys:ro \
        aic-nvme-exporter:local
fi

echo "=== Building and starting rdma-exporter (9879) ==="
if ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/9879" 2>/dev/null; then
    docker build -q -t aic-rdma-exporter:local "${MON_DIR}/rdma-exporter"
    docker run -d --name aic-rdma-exporter \
        --network host \
        -v /sys:/sys:ro \
        aic-rdma-exporter:local
fi

# ---------------------------------------------------------------------------
# 2. Start Prometheus
# ---------------------------------------------------------------------------
echo "=== Starting Prometheus (9090) ==="
docker run -d --name aic-prometheus \
    --network host \
    --user "$(id -u):$(id -g)" \
    -v "${MON_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    -v "${MON_DIR}/prometheus/rules:/etc/prometheus/rules:ro" \
    -v "${METRICS_DIR}:/prometheus" \
    prom/prometheus:v2.55.1 \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=1h \
    --web.listen-address=:9090

# ---------------------------------------------------------------------------
# 3. Start vLLM emulator
# ---------------------------------------------------------------------------
echo "=== Starting vLLM emulator (8000) ==="
docker run -d --name aic-vllm-emulator \
    --network host \
    -v "${WORKDIR}/monitoring/scripts/vllm_emulator_server.py:/app/vllm_emulator_server.py:ro" \
    -e VLLM_MODEL="${VLLM_CPU_MODEL:-facebook/opt-125m}" \
    -e PYTHONUNBUFFERED=1 \
    "${AIC_IMAGE}" \
    python3 /app/vllm_emulator_server.py

# ---------------------------------------------------------------------------
# 4. Wait for vLLM emulator to be healthy (up to 3 min)
# ---------------------------------------------------------------------------
echo "=== Waiting for vLLM emulator /health ==="
for i in $(seq 1 24); do
    if curl -sf http://localhost:8000/health >/dev/null 2>&1; then
        echo "vLLM emulator healthy after ~$((i * 8))s"
        break
    fi
    if [[ "${i}" -eq 24 ]]; then
        echo "ERROR: vLLM emulator did not become healthy in time" >&2
        docker logs aic-vllm-emulator >&2
        exit 1
    fi
    sleep 8
done

# ---------------------------------------------------------------------------
# 5. Issue 3 LLM prompts; assert non-empty completions
# ---------------------------------------------------------------------------
echo "=== Running LLM prompt smoke tests ==="
PROMPTS=(
    "The capital of France is"
    "In machine learning, a tensor is"
    "ROCm stands for"
)
for prompt in "${PROMPTS[@]}"; do
    response=$(curl -sf http://localhost:8000/v1/completions \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${VLLM_CPU_MODEL:-facebook/opt-125m}\",\"prompt\":\"${prompt}\",\"max_tokens\":20}" \
    )
    text=$(echo "${response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['text'])" 2>/dev/null || true)
    if [[ -z "${text}" ]]; then
        echo "ERROR: empty completion for prompt: ${prompt}" >&2
        echo "Response: ${response}" >&2
        exit 1
    fi
    echo "  OK: '${prompt}' -> '${text}'"
done

# ---------------------------------------------------------------------------
# 6. Wait one Prometheus scrape cycle, then health-check exporters
# ---------------------------------------------------------------------------
echo "=== Waiting for first scrape cycle ==="
sleep 12

echo "=== Exporter health check ==="
declare -A EXPORTER_PORTS=(
    [node_exporter]=9100
    [nvme_exporter]=9998
    [rdma_exporter]=9879
    [vllm]=8000
    [prometheus]=9090
)
declare -A EXPORTER_PREFIXES=(
    [node_exporter]="^node_"
    [nvme_exporter]="^nvme_"
    [rdma_exporter]="^rdma_"
    [vllm]="^vllm_"
    [prometheus]="^prometheus_"
)
all_ok=1
for name in "${!EXPORTER_PORTS[@]}"; do
    port="${EXPORTER_PORTS[$name]}"
    prefix="${EXPORTER_PREFIXES[$name]}"
    if curl -sf "http://localhost:${port}/metrics" 2>/dev/null | grep -qE "${prefix}"; then
        echo "  OK:   ${name} (:${port}) — ${prefix} metrics present"
    else
        echo "  WARN: ${name} (:${port}) — ${prefix} metrics absent (may be expected on CPU node)"
        all_ok=0
    fi
done
# Non-fatal: GPU exporters expected to be absent on CPU nodes.
[[ "${all_ok}" -eq 0 ]] && echo "Some exporters WARN (GPU exporters absent on CPU-only node is expected)"

# ---------------------------------------------------------------------------
# 7. Scrape all metric endpoints; generate HTML reference page
# ---------------------------------------------------------------------------
echo "=== Scraping metrics endpoints ==="
METRICS_ARGS=()
for name in "${!EXPORTER_PORTS[@]}"; do
    port="${EXPORTER_PORTS[$name]}"
    outfile="/tmp/metrics_${name}.txt"
    curl -sf "http://localhost:${port}/metrics" > "${outfile}" 2>/dev/null || true
    if [[ -s "${outfile}" ]]; then
        METRICS_ARGS+=("--source" "${name}:${outfile}")
    fi
done

echo "=== Generating metrics HTML ==="
python3 "${WORKDIR}/monitoring/scripts/metrics_to_html.py" \
    "${METRICS_ARGS[@]}" \
    --sha "${SHA}" \
    --title "AIC Prometheus Metrics Reference" \
    > "${METRICS_PAGE_DIR}/index.html"

echo "=== Metrics page written to ${METRICS_PAGE_DIR}/index.html ==="
wc -l "${METRICS_PAGE_DIR}/index.html"

SRUN_BODY

chmod +x "${SRUN_SCRIPT}"

echo "=== Submitting CPU-only srun job ==="
srun \
    --nodes=1 \
    --ntasks=1 \
    --cpus-per-task=8 \
    --mem=16G \
    --time=00:30:00 \
    --partition=amd-spur \
    bash "${SRUN_SCRIPT}" \
        "${WORKDIR}" \
        "${AIC_IMAGE}" \
        "${METRICS_PAGE_DIR}" \
        "${SHA}"

echo "=== srun job completed ==="
REMOTE

# ---------------------------------------------------------------------------
# Copy metrics page artifact back to the runner working directory
# ---------------------------------------------------------------------------
echo "=== Copying metrics page to runner ==="
mkdir -p metrics-page
scp -o ServerAliveInterval=30 \
    "${AIC_SPUR_HOST}:${METRICS_PAGE_DIR}/index.html" \
    metrics-page/index.html

echo "CPU monitoring smoke test passed for ${SHORT}"
