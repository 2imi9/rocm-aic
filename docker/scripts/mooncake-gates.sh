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
# Run twice by the build: `wheels` before anything is installed (archive
# membership cannot be faked by an install), `runtime` after the install.
# The script is kept in the image so the same gates can be re-run against a
# built image without rebuilding:
#
#   docker run --rm --entrypoint bash <image> \
#       /usr/local/bin/aic-mooncake-gates.sh runtime
#
# Usage:
#   aic-mooncake-gates.sh wheels <lmcache-wheel> <mooncake-wheel>
#   aic-mooncake-gates.sh runtime
set -euo pipefail

MOONCAKE_PREFIX="${MOONCAKE_PREFIX:-/opt/mooncake-sdk}"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

# --- wheel archive membership (must run BEFORE the wheel is installed) -------
# Validate both archives before either can be masked by an installed package.
gate_wheels() {
	local lmcache_wheel="${1:-}"
	local mooncake_wheel="${2:-}"
	[[ -f "${lmcache_wheel}" ]] || die "LMCache wheel not found: ${lmcache_wheel}"
	[[ -f "${mooncake_wheel}" ]] || die "Mooncake wheel not found: ${mooncake_wheel}"
	python3 - "${lmcache_wheel}" "${mooncake_wheel}" <<'PY'
import sys
import zipfile

lmcache_wheel, mooncake_wheel = sys.argv[1:]

def members(path):
    with zipfile.ZipFile(path) as archive:
        return archive.namelist()

lmcache = members(lmcache_wheel)
for prefix in ("lmcache/c_ops", "lmcache/lmcache_mooncake"):
    if not any(name.startswith(prefix) and name.endswith(".so") for name in lmcache):
        raise SystemExit("ERROR: %s is missing %s*.so" % (lmcache_wheel, prefix))

mooncake = members(mooncake_wheel)
for name in ("mooncake/engine.so", "mooncake/store.so", "mooncake/mooncake_master"):
    if name not in mooncake:
        raise SystemExit("ERROR: %s is missing %s" % (mooncake_wheel, name))

print("  LMCache native members:")
for name in sorted(name for name in lmcache if name.endswith(".so")):
    print("    %s" % name)
print("  Mooncake runtime members:")
for name in ("mooncake/engine.so", "mooncake/store.so", "mooncake/mooncake_master"):
    print("    %s" % name)
PY
	echo "PASS: wheel archives contain both LMCache extensions and Mooncake runtime"
}

# --- imports ----------------------------------------------------------------
gate_imports() {
	python3 <<'PY'
import importlib
from importlib.metadata import version

if version("lmcache") != "0.5.3":
    raise SystemExit("ERROR: expected lmcache 0.5.3, got %s" % version("lmcache"))

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
# so import the external connector and pin the classes it actually selected.
gate_adapter_identity() {
	python3 <<'PY'
import importlib

module = importlib.import_module(
    "lmcache.integration.vllm.lmcache_mp_connector"
)
expected = "lmcache.integration.vllm.vllm_multi_process_adapter"
for attr in ("LMCacheMPSchedulerAdapter", "LMCacheMPWorkerAdapter"):
    cls = getattr(module, attr, None)
    if cls is None:
        raise SystemExit("ERROR: %s missing from %s" % (attr, module.__name__))
    if cls.__module__ != expected:
        raise SystemExit(
            "ERROR: %s resolved to %s, expected %s"
            % (attr, cls.__module__, expected)
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
	local output
	local targets
	targets="$(mktemp)"
	if ! ldd_targets >"${targets}"; then
		rm -f "${targets}"
		die "could not resolve the shared-object target list"
	fi
	while IFS= read -r target; do
		[[ -n "${target}" ]] || continue
		[[ -e "${target}" ]] || die "expected shared object is missing: ${target}"
		if ! output="$(ldd "${target}" 2>&1)"; then
			echo "ldd failed for ${target}:" >&2
			echo "${output}" >&2
			status=1
		elif grep -q "not found" <<<"${output}"; then
			echo "unresolved libraries in ${target}:" >&2
			grep "not found" <<<"${output}" >&2
			status=1
		else
			echo "  resolved: ${target}"
		fi
	done <"${targets}"
	rm -f "${targets}"
	[[ "${status}" -eq 0 ]] || die "unresolved shared libraries, see above"
	echo "PASS: every checked shared object resolves its libraries"
}

ldd_targets() {
	python3 <<'PY' || return 1
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
	local master
	master="$(python3 -c 'import mooncake, pathlib; print(pathlib.Path(mooncake.__path__[0]) / "mooncake_master")')" || return 1
	printf '%s\n' \
		"${MOONCAKE_PREFIX}/lib/libmooncake_store.so" \
		"${MOONCAKE_PREFIX}/lib/libtransfer_engine.so" \
		"${MOONCAKE_PREFIX}/lib/libmooncake_common.so" \
		"${MOONCAKE_PREFIX}/lib/libasio.so" \
		"${MOONCAKE_PREFIX}/lib/libetcd_wrapper.so" \
		"${master}"
}

# --- Mooncake's declared Python dependencies are satisfied -------------------
# AIC intentionally removes CUDA-only packages such as cufile-python on ROCm,
# although LMCache declares them unconditionally. A whole-environment
# `pip check` therefore cannot be a valid gate here. Keep its useful signal,
# but fail only on the distribution introduced by this change; the native
# LMCache and Mooncake imports above cover the two extensions themselves.
gate_pip_check() {
	local report
	report="$(python3 -m pip check 2>&1 || true)"
	if grep -Eqi '^mooncake[-_]transfer[-_]engine[-_]rocm ' <<<"${report}"; then
		echo "Mooncake dependency check failed:" >&2
		grep -Ei '^mooncake[-_]transfer[-_]engine[-_]rocm ' <<<"${report}" >&2
		die "Mooncake package metadata is inconsistent"
	fi
	python3 -c 'import msgpack; from importlib.metadata import version; print("  dependency: msgpack " + version("msgpack"))'
	echo "PASS: Mooncake's declared Python dependencies are installed"
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
	wheels) gate_wheels "$@" ;;
	runtime) gate_runtime ;;
	*) die "usage: $0 {wheels <lmcache-wheel> <mooncake-wheel>|runtime}" ;;
	esac
}

main "$@"
