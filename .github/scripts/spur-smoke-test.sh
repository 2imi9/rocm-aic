#!/usr/bin/env bash
set -euo pipefail

# Runs on the self-hosted runner; SSHes to the SPUR head node (AIC_SPUR_HOST) and
# runs the requested smoke-test target against the tarball produced by
# spur-dist-build.sh for the same SHA. The clone and tarball are left in place
# for spur-tiny-test.sh (the next stage) to use; spur-tiny-test.sh owns the final
# cleanup. On failure, cleans up immediately so no stale state is left behind.

SHA="${1:?usage: $0 <full-sha> [smoke-test|smoke-test-fast]}"
AIC_SMOKE_TEST_TARGET="${2:-smoke-test}"
case "${AIC_SMOKE_TEST_TARGET}" in
    smoke-test | smoke-test-fast) ;;
    *)
        echo "ERROR: unsupported smoke-test target: ${AIC_SMOKE_TEST_TARGET}" >&2
        exit 2
        ;;
esac
SHORT="${SHA:0:7}"
AIC_IMAGE="rocm-aic-ci-${SHORT}:latest"
AIC_SPUR_HOST="${AIC_SPUR_HOST:?AIC_SPUR_HOST must be set (e.g. via GitHub repo variable)}"
AIC_SPUR_HOST="${AIC_SPUR_HOST//[$'\t\r\n ']}"
AIC_SHARED_NFS="${AIC_SHARED_NFS:?AIC_SHARED_NFS must be set (e.g. via GitHub repo variable)}"
AIC_SPUR_CONTROLLER="${AIC_SPUR_CONTROLLER:?AIC_SPUR_CONTROLLER must be set (e.g. via GitHub repo variable)}"
REPO="https://github.com/ROCm/rocm-aic.git"

ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "${AIC_SPUR_HOST}" env \
    SHA="${SHA}" \
    REPO="${REPO}" \
    AIC_IMAGE="${AIC_IMAGE}" \
    AIC_SMOKE_TEST_TARGET="${AIC_SMOKE_TEST_TARGET}" \
    AIC_SHARED_NFS="${AIC_SHARED_NFS}" \
    AIC_SPUR_CONTROLLER="${AIC_SPUR_CONTROLLER}" \
    SPUR_CONTROLLER_ADDR="${AIC_SPUR_CONTROLLER}" \
    bash << 'REMOTE'
set -euo pipefail

SHORT="${SHA:0:7}"
WORKDIR="$HOME/Projects/rocm-aic.${SHORT}"
TARBALL_DIR="${AIC_SHARED_NFS}/rocm-aic/images/aic-ci-${SHORT}"

cleanup_on_fail() {
    echo "=== Smoke test failed — cleaning up ==="
    rm -rf "${TARBALL_DIR}"
    find "${WORKDIR}" -mindepth 1 -maxdepth 1 -not -name logs -exec rm -rf {} +
}
# On success: preserve TARBALL_DIR so the following tiny-test stage can use it.
# On failure: clean up immediately so no stale state is left behind.
trap cleanup_on_fail ERR

# Re-clone if WORKDIR is missing or checked out at the wrong SHA.
ACTUAL_SHA="$(git -C "${WORKDIR}" rev-parse HEAD 2>/dev/null || true)"
if [[ ! -d "${WORKDIR}" || "${ACTUAL_SHA}" != "${SHA}" ]]; then
    echo "=== (Re-)cloning ${REPO} at ${SHA} ==="
    rm -rf "${WORKDIR}"
    git clone --filter=blob:none --no-single-branch "${REPO}" "${WORKDIR}"
    git -C "${WORKDIR}" checkout "${SHA}"
fi

echo "=== Running ${AIC_SMOKE_TEST_TARGET} (AIC_IMAGE=${AIC_IMAGE}) ==="
AIC_SPUR_CLUSTER=1 \
    AIC_IMAGE="${AIC_IMAGE}" \
    AIC_IMAGE_DIR="${TARBALL_DIR}" \
    make -C "${WORKDIR}" "${AIC_SMOKE_TEST_TARGET}"

echo "=== ${AIC_SMOKE_TEST_TARGET} complete ==="
REMOTE

echo "Smoke test passed for ${SHORT}"
