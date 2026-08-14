#!/usr/bin/env bash
set -euo pipefail

# Runs on the self-hosted runner; SSHes to the SPUR head node (AIC_SPUR_HOST) and runs tiny-test
# against the tarball produced by spur-dist-build.sh for the same SHA (the stage
# after spur-smoke-test.sh).  tiny-test brings up the compose MP stack
# (standalone lmcache server + vLLM LMCacheMPConnector) with a tiny model and
# asserts one non-empty chat completion.
#
# Cleanup ownership depends on whether a cliff stage follows:
#   * PR flow (dist-build -> smoke-test -> tiny-test): tiny-test is terminal, so
#     it owns the final cleanup (removes the clone + tarball on exit).
#   * Nightly (dist-build -> smoke -> tiny -> cliff): cliff runs next and needs
#     the artifacts, so the nightly tiny-test step sets KEEP_ARTIFACTS=1 and this
#     script only cleans up on failure (spur-cliff.sh does the final cleanup).
# The tiny model uses the cluster-wide HF cache so it is downloaded once and
# reused across CI workflows and SPUR accounts.

SHA="${1:?usage: $0 <full-sha> [tiny-test|tiny-test-fast]}"
AIC_TINY_TEST_TARGET="${2:-tiny-test}"
case "${AIC_TINY_TEST_TARGET}" in
    tiny-test | tiny-test-fast) ;;
    *)
        echo "ERROR: unsupported tiny-test target: ${AIC_TINY_TEST_TARGET}" >&2
        exit 2
        ;;
esac
SHORT="${SHA:0:7}"
AIC_IMAGE_NAME="rocm-aic-ci-${SHORT}"
AIC_SPUR_HOST="${AIC_SPUR_HOST:?AIC_SPUR_HOST must be set (e.g. via GitHub repo variable)}"
AIC_SPUR_HOST="${AIC_SPUR_HOST//[$'\t\r\n ']}"
AIC_SHARED_NFS="${AIC_SHARED_NFS:?AIC_SHARED_NFS must be set (e.g. via GitHub repo variable)}"
AIC_SPUR_CONTROLLER="${AIC_SPUR_CONTROLLER:?AIC_SPUR_CONTROLLER must be set (e.g. via GitHub repo variable)}"
AIC_CI_STORAGE_ROOT="${AIC_CI_STORAGE_ROOT:-}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
REPO="https://github.com/ROCm/rocm-aic.git"

ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "${AIC_SPUR_HOST}" env \
    SHA="${SHA}" \
    REPO="${REPO}" \
    AIC_IMAGE_NAME="${AIC_IMAGE_NAME}" \
    AIC_TINY_TEST_TARGET="${AIC_TINY_TEST_TARGET}" \
    AIC_SHARED_NFS="${AIC_SHARED_NFS}" \
    AIC_CI_STORAGE_ROOT="${AIC_CI_STORAGE_ROOT}" \
    KEEP_ARTIFACTS="${KEEP_ARTIFACTS}" \
    AIC_SPUR_CONTROLLER="${AIC_SPUR_CONTROLLER}" \
    SPUR_CONTROLLER_ADDR="${AIC_SPUR_CONTROLLER}" \
    HF_TOKEN="${HF_TOKEN:-}" \
    bash << 'REMOTE'
set -euo pipefail

SHORT="${SHA:0:7}"
WORKDIR="$HOME/Projects/rocm-aic.${SHORT}"
CI_STORAGE_ROOT="${AIC_CI_STORAGE_ROOT:-$HOME/Projects/rocm-aic-ci}"
TARBALL_DIR="${CI_STORAGE_ROOT}/images/aic-ci-${SHORT}"

_cleanup() {
    echo "=== Cleaning up ==="
    rm -rf "${WORKDIR}" "${TARBALL_DIR}"
}
if [[ "${KEEP_ARTIFACTS}" == "1" ]]; then
    # A cliff stage follows and reuses the artifacts; only clean up on failure.
    cleanup_on_fail() { echo "=== Tiny test failed — cleaning up ==="; _cleanup; }
    trap cleanup_on_fail ERR
else
    # Terminal stage: always clean up.
    trap _cleanup EXIT
fi

# Re-clone if WORKDIR is missing or checked out at the wrong SHA (e.g. stale
# leftover from a prior failed run at a different commit with the same prefix).
ACTUAL_SHA="$(git -C "${WORKDIR}" rev-parse HEAD 2>/dev/null || true)"
if [[ ! -d "${WORKDIR}" || "${ACTUAL_SHA}" != "${SHA}" ]]; then
    echo "=== (Re-)cloning ${REPO} at ${SHA} ==="
    rm -rf "${WORKDIR}"
    git clone --filter=blob:none --no-single-branch "${REPO}" "${WORKDIR}"
    git -C "${WORKDIR}" checkout "${SHA}"
fi

echo "=== Running ${AIC_TINY_TEST_TARGET} (AIC_IMAGE_NAME=${AIC_IMAGE_NAME}) ==="
AIC_SPUR_CLUSTER=1 \
    AIC_IMAGE_NAME="${AIC_IMAGE_NAME}" \
    AIC_IMAGE_DIR="${TARBALL_DIR}" \
    HF_TOKEN="${HF_TOKEN:-}" \
    make -C "${WORKDIR}" "${AIC_TINY_TEST_TARGET}"

echo "=== ${AIC_TINY_TEST_TARGET} complete ==="
REMOTE

echo "Tiny test passed for ${SHORT}"
