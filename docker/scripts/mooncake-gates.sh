#!/bin/bash
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Fail-closed gates for the canonical LMCache wheel (the HIP c_ops extension
# and the host-only Mooncake backend in ONE wheel) and for the source-built
# Mooncake ROCm package.  Every gate exits non-zero on failure, so a failing
# gate stops the image build.
#
# Run twice by the build: `wheel` before anything is installed (archive
# membership cannot be faked by an install), `runtime` after the install.
# The script is kept in the image so the same gates can be re-run against a
# built image without rebuilding:
#
#   docker run --rm --entrypoint bash <image> \
#       /usr/local/bin/aic-mooncake-gates.sh runtime
#
# Usage:
#   aic-mooncake-gates.sh wheel <wheel-path>
#   aic-mooncake-gates.sh runtime
set -euo pipefail

MOONCAKE_PREFIX="${MOONCAKE_PREFIX:-/opt/mooncake-sdk}"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

# --- wheel archive membership (must run BEFORE the wheel is installed) -------
gate_wheel() {
	local wheel="${1:-}"
	[[ -n "${wheel}" ]] || die "usage: $0 wheel <wheel-path>"
	[[ -f "${wheel}" ]] || die "wheel not found: ${wheel}"
	python3 - "${wheel}" <<'PY'
import sys
import zipfile

wheel = sys.argv[1]
names = zipfile.ZipFile(wheel).namelist()
wanted = ("lmcache/c_ops", "lmcache/lmcache_mooncake")
missing = [
    prefix
    for prefix in wanted
    if not any(n.startswith(prefix) and n.endswith(".so") for n in names)
]
for name in sorted(n for n in names if n.endswith(".so")):
    print("  member: %s" % name)
if missing:
    raise SystemExit(
        "ERROR: %s is missing: %s" % (wheel, ", ".join(missing))
    )
PY
	echo "PASS: a single wheel carries both c_ops and lmcache_mooncake"
}

# --- imports ----------------------------------------------------------------
gate_imports() {
	python3 <<'PY'
import importlib

for name in (
    "lmcache.c_ops",
    "lmcache.lmcache_mooncake",
    "mooncake.engine",
    "mooncake.store",
):
    importlib.import_module(name)
    print("  import: %s" % name)
PY
	echo "PASS: c_ops, lmcache_mooncake, mooncake.engine and mooncake.store import"
}

# --- the MP adapters come from lmcache, not from a bundled fallback ----------
# lmcache_mp_connector imports its adapters from LMCache and silently falls
# back to the copy vendored inside the serving engine when that import fails.
# A wheel that lost its own adapters would still "work" through the fallback,
# so pin the module identity.  The adapter module is imported directly: it is
# the module the fallback replaces, and it does not drag the serving engine's
# device probing into a build layer that has no GPU.
gate_adapter_identity() {
	python3 <<'PY'
import importlib

module = importlib.import_module(
    "lmcache.integration.vllm.vllm_multi_process_adapter"
)
for attr in ("LMCacheMPSchedulerAdapter", "LMCacheMPWorkerAdapter"):
    cls = getattr(module, attr, None)
    if cls is None:
        raise SystemExit("ERROR: %s missing from %s" % (attr, module.__name__))
    if not cls.__module__.startswith("lmcache."):
        raise SystemExit(
            "ERROR: %s resolved to %s, not to an lmcache module"
            % (attr, cls.__module__)
        )
    print("  adapter: %s -> %s" % (attr, cls.__module__))
PY
	echo "PASS: MP adapters resolve to lmcache modules"
}

# --- the packaged master binary runs ----------------------------------------
gate_master() {
	local master
	master="$(python3 -c 'import mooncake, pathlib; print(pathlib.Path(mooncake.__path__[0]) / "mooncake_master")')"
	[[ -x "${master}" ]] || die "packaged mooncake_master not found at ${master}"
	"${master}" --version
	echo "PASS: packaged mooncake_master reports its version"
}

# --- no unresolved shared libraries -----------------------------------------
gate_ldd() {
	local target
	local status=0
	while IFS= read -r target; do
		[[ -n "${target}" ]] || continue
		[[ -e "${target}" ]] || die "expected shared object is missing: ${target}"
		if ldd "${target}" | grep -q "not found"; then
			echo "unresolved libraries in ${target}:" >&2
			ldd "${target}" | grep "not found" >&2
			status=1
		else
			echo "  resolved: ${target}"
		fi
	done < <(ldd_targets)
	[[ "${status}" -eq 0 ]] || die "unresolved shared libraries, see above"
	echo "PASS: every checked shared object resolves its libraries"
}

ldd_targets() {
	python3 <<'PY'
import pathlib

import lmcache
import mooncake

for package, patterns in (
    (lmcache, ("c_ops*.so", "lmcache_mooncake*.so")),
    (mooncake, ("engine*.so", "store*.so")),
):
    root = pathlib.Path(package.__path__[0])
    for pattern in patterns:
        matches = sorted(root.glob(pattern))
        if not matches:
            raise SystemExit("ERROR: no %s under %s" % (pattern, root))
        for match in matches:
            print(match)
PY
	printf '%s\n' \
		"${MOONCAKE_PREFIX}/lib/libmooncake_store.so" \
		"${MOONCAKE_PREFIX}/lib/libtransfer_engine.so"
}

# --- dependency metadata is consistent for the packages we ship -------------
# `pip check` is environment wide.  Only findings that name lmcache or mooncake
# are treated as failures here: unrelated pre-existing findings in this image
# are not introduced by this packaging and must not silently gate it.
gate_pip_check() {
	local report
	report="$(python3 -m pip check 2>&1 || true)"
	if [[ -n "${report}" ]]; then
		echo "pip check output:"
		while IFS= read -r line; do
			echo "  ${line}"
		done <<<"${report}"
	fi
	if echo "${report}" | grep -Eqi 'lmcache|mooncake'; then
		die "pip check reports a problem with an lmcache or mooncake package"
	fi
	echo "PASS: pip check reports no lmcache or mooncake dependency problem"
}

gate_runtime() {
	gate_imports
	gate_adapter_identity
	gate_master
	gate_ldd
	gate_pip_check
	echo "PASS: runtime gates complete"
}

main() {
	local command="${1:-}"
	shift || true
	case "${command}" in
	wheel) gate_wheel "$@" ;;
	runtime) gate_runtime ;;
	*) die "usage: $0 {wheel <wheel-path>|runtime}" ;;
	esac
}

main "$@"
