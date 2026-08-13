#!/usr/bin/env python3
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT
#
# Prometheus exporter for the LMCache MP coordinator REST API.
#
# The coordinator has no native /metrics endpoint; this script polls its JSON
# REST API (/healthz, /instances, /directory/stats, /quota) and emits
# Prometheus text-format metrics on --listen-port (default 9301).
#
# Metrics exposed:
#   lmcache_coordinator_up                       — 1 if coordinator is reachable
#   lmcache_coordinator_instances_registered     — number of live MP instances
#   lmcache_coordinator_instance_info            — metadata gauge per instance
#   lmcache_coordinator_directory_keys_total     — keys tracked in key directory
#   lmcache_coordinator_directory_placements_total — total placements across all keys
#   lmcache_coordinator_instance_l1_keys         — L1 keys reported by each instance
#   lmcache_coordinator_instance_seq_gap         — 1 if an event-stream gap was detected
#   lmcache_coordinator_quota_usage_bytes        — L2 usage bytes per cache_salt
#   lmcache_coordinator_quota_limit_bytes        — L2 quota limit per cache_salt (-1 = unlimited)
#   lmcache_coordinator_scrape_duration_seconds  — time to collect all metrics

import argparse
import http.server
import logging
import os
import time
import urllib.error
import urllib.request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("coordinator-exporter")


def _fetch_json(base_url: str, path: str) -> object | None:
    url = base_url.rstrip("/") + path
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            import json
            return json.loads(r.read())
    except Exception as exc:
        log.debug("fetch %s failed: %s", url, exc)
        return None


def collect(coordinator_url: str) -> str:
    t0 = time.monotonic()
    lines: list[str] = []

    def gauge(name: str, value: float, labels: dict[str, str] | None = None, help_text: str = "", typ: str = "gauge") -> None:
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {typ}")
        label_str = ""
        if labels:
            pairs = ",".join(f'{k}="{v}"' for k, v in labels.items())
            label_str = "{" + pairs + "}"
        lines.append(f"{name}{label_str} {value}")

    # --- coordinator liveness ---
    healthz = _fetch_json(coordinator_url, "/healthz")
    up = 1.0 if (healthz and healthz.get("status") == "healthy") else 0.0
    gauge("lmcache_coordinator_up", up,
          help_text="1 if the LMCache MP coordinator /healthz reports healthy")

    if up < 1.0:
        # Emit scrape duration and bail — everything else would be stale noise.
        gauge("lmcache_coordinator_scrape_duration_seconds",
              time.monotonic() - t0,
              help_text="Time in seconds to scrape the LMCache coordinator")
        return "\n".join(lines) + "\n"

    # --- registered instances ---
    instances_resp = _fetch_json(coordinator_url, "/instances")
    instances = (instances_resp or {}).get("instances", [])
    lines.append("# HELP lmcache_coordinator_instances_registered Number of MP servers currently registered with the coordinator")
    lines.append("# TYPE lmcache_coordinator_instances_registered gauge")
    lines.append(f"lmcache_coordinator_instances_registered {len(instances)}")

    if instances:
        lines.append("# HELP lmcache_coordinator_instance_info Non-zero for each registered instance; labels carry metadata")
        lines.append("# TYPE lmcache_coordinator_instance_info gauge")
        for inst in instances:
            iid = inst.get("instance_id", "")
            ip = inst.get("ip", "")
            http_port = str(inst.get("http_port", ""))
            lines.append(
                f'lmcache_coordinator_instance_info{{instance_id="{iid}",ip="{ip}",http_port="{http_port}"}} 1'
            )

    # --- key directory stats ---
    dir_stats = _fetch_json(coordinator_url, "/directory/stats")
    if dir_stats is not None:
        gauge("lmcache_coordinator_directory_keys_total",
              dir_stats.get("num_keys", 0),
              help_text="Keys with at least one placement tracked in the key directory")
        gauge("lmcache_coordinator_directory_placements_total",
              dir_stats.get("num_placements", 0),
              help_text="Total placements (instance×tier×backend entries) across all tracked keys")

        inst_stats = dir_stats.get("instances", {})
        if inst_stats:
            lines.append("# HELP lmcache_coordinator_instance_l1_keys L1 keys reported by each instance's event stream")
            lines.append("# TYPE lmcache_coordinator_instance_l1_keys gauge")
            lines.append("# HELP lmcache_coordinator_instance_seq_gap 1 if a sequence gap was detected in this instance's event stream")
            lines.append("# TYPE lmcache_coordinator_instance_seq_gap gauge")
            for iid, s in inst_stats.items():
                lines.append(
                    f'lmcache_coordinator_instance_l1_keys{{instance_id="{iid}"}} {s.get("num_l1_keys", 0)}'
                )
                lines.append(
                    f'lmcache_coordinator_instance_seq_gap{{instance_id="{iid}"}} {1 if s.get("gap_detected") else 0}'
                )

    # --- quota / L2 usage ---
    # API: {total_gb, by_cache_salt: [{cache_salt, usage_gb, quota_limit_gb, quota_exists}]}
    quota_list = _fetch_json(coordinator_url, "/quota?tier=l2")
    if quota_list is not None:
        GB = 1024 ** 3
        total_gb = quota_list.get("total_gb", 0)
        lines.append("# HELP lmcache_coordinator_quota_usage_bytes_total Total L2 usage bytes tracked by coordinator")
        lines.append("# TYPE lmcache_coordinator_quota_usage_bytes_total gauge")
        lines.append(f"lmcache_coordinator_quota_usage_bytes_total {total_gb * GB:.0f}")
        entries = quota_list.get("by_cache_salt", [])
        if entries:
            lines.append("# HELP lmcache_coordinator_quota_usage_bytes L2 byte usage tracked by the coordinator per cache_salt")
            lines.append("# TYPE lmcache_coordinator_quota_usage_bytes gauge")
            lines.append("# HELP lmcache_coordinator_quota_limit_bytes L2 quota limit per cache_salt; -1 means no limit set")
            lines.append("# TYPE lmcache_coordinator_quota_limit_bytes gauge")
            for entry in entries:
                salt = entry.get("cache_salt", "")
                usage = entry.get("usage_gb", 0) * GB
                limit = entry.get("quota_limit_gb", -1)
                limit_bytes = limit * GB if (limit and limit > 0) else -1
                lines.append(f'lmcache_coordinator_quota_usage_bytes{{cache_salt="{salt}"}} {usage:.0f}')
                lines.append(f'lmcache_coordinator_quota_limit_bytes{{cache_salt="{salt}"}} {limit_bytes:.0f}')

    gauge("lmcache_coordinator_scrape_duration_seconds",
          time.monotonic() - t0,
          help_text="Time in seconds to scrape the LMCache coordinator REST API")

    return "\n".join(lines) + "\n"


class Handler(http.server.BaseHTTPRequestHandler):
    coordinator_url: str = ""

    def do_GET(self):  # noqa: N802
        if self.path in ("/metrics", "/metrics/"):
            body = collect(self.coordinator_url).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path in ("/healthz", "/health"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # suppress access log noise


def main():
    parser = argparse.ArgumentParser(
        description="Prometheus exporter for the LMCache MP coordinator REST API"
    )
    parser.add_argument(
        "--coordinator-url",
        default=os.environ.get("LMCACHE_COORDINATOR_URL", "http://aic-lmcache-coordinator:9300"),
        help="Base URL of the LMCache coordinator (default: %(default)s)",
    )
    parser.add_argument(
        "--listen-port",
        type=int,
        default=int(os.environ.get("COORDINATOR_EXPORTER_PORT", "9301")),
        help="Port to serve /metrics on (default: %(default)s)",
    )
    args = parser.parse_args()

    Handler.coordinator_url = args.coordinator_url
    log.info("Exporting coordinator metrics from %s on :%d/metrics", args.coordinator_url, args.listen_port)
    server = http.server.HTTPServer(("0.0.0.0", args.listen_port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
