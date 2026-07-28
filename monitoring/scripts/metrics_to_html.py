#!/usr/bin/env python3
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Generate a self-contained HTML metrics reference page from raw Prometheus
# /metrics text files.
#
# Usage:
#   python3 metrics_to_html.py \
#     --source node_exporter:/tmp/metrics_node.txt \
#     --source vllm:/tmp/metrics_vllm.txt \
#     --sha abc1234 \
#     --title "AIC Prometheus Metrics" \
#     > index.html
#
# Each --source argument is "label:path".  Metrics are grouped by source label
# in the output table.  Sources are listed in the order they appear on the
# command line.

from __future__ import annotations

import argparse
import datetime
import html
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class MetricEntry:
    name: str
    type: str = "untyped"
    help: str = ""
    source: str = ""


def parse_metrics(text: str, source: str) -> list[MetricEntry]:
    """Extract HELP/TYPE pairs from raw Prometheus exposition text."""
    entries: dict[str, MetricEntry] = {}
    for line in text.splitlines():
        m = re.match(r"^# HELP (\S+) (.+)$", line)
        if m:
            name, desc = m.group(1), m.group(2)
            entry = entries.setdefault(name, MetricEntry(name=name, source=source))
            entry.help = desc
        m = re.match(r"^# TYPE (\S+) (\S+)$", line)
        if m:
            name, typ = m.group(1), m.group(2)
            entry = entries.setdefault(name, MetricEntry(name=name, source=source))
            entry.type = typ
    return sorted(entries.values(), key=lambda e: e.name)


def _esc(s: str) -> str:
    return html.escape(s)


def render_html(
    sources: list[tuple[str, list[MetricEntry]]],
    title: str,
    sha: str,
    generated_at: str,
) -> str:
    total = sum(len(entries) for _, entries in sources)

    rows_html = []
    for source_label, entries in sources:
        if not entries:
            continue
        rows_html.append(
            f'<tr class="section-header"><td colspan="4">'
            f'<details open><summary>{_esc(source_label)} '
            f'<span class="count">({len(entries)} metrics)</span></summary></details>'
            f"</td></tr>"
        )
        for e in entries:
            rows_html.append(
                f'<tr data-source="{_esc(source_label)}">'
                f'<td class="metric-name"><code>{_esc(e.name)}</code></td>'
                f'<td class="metric-type">{_esc(e.type)}</td>'
                f'<td class="metric-help">{_esc(e.help)}</td>'
                f'<td class="metric-source">{_esc(source_label)}</td>'
                f"</tr>"
            )

    rows = "\n".join(rows_html)

    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_esc(title)}</title>
<style>
  :root {{
    --bg: #ffffff; --fg: #1a1a1a; --border: #d0d0d0;
    --accent: #e05d00; --code-bg: #f5f5f5; --section-bg: #f0f4ff;
    --hover: #fafafa;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #1e1e1e; --fg: #e0e0e0; --border: #444; --accent: #ff8c42;
      --code-bg: #2a2a2a; --section-bg: #252535; --hover: #2e2e2e;
    }}
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: system-ui, sans-serif; background: var(--bg); color: var(--fg);
          font-size: 14px; padding: 1.5rem; }}
  h1 {{ font-size: 1.4rem; margin-bottom: 0.25rem; color: var(--accent); }}
  .meta {{ color: #888; font-size: 0.8rem; margin-bottom: 1rem; }}
  .search-bar {{ width: 100%; max-width: 480px; padding: 0.45rem 0.75rem;
                 border: 1px solid var(--border); border-radius: 4px;
                 background: var(--bg); color: var(--fg); font-size: 0.9rem;
                 margin-bottom: 1rem; }}
  .stats {{ font-size: 0.8rem; color: #888; margin-bottom: 0.75rem; }}
  table {{ width: 100%; border-collapse: collapse; table-layout: fixed; }}
  thead th {{ background: var(--section-bg); font-weight: 600; text-align: left;
              padding: 0.5rem 0.75rem; border-bottom: 2px solid var(--border);
              position: sticky; top: 0; z-index: 1; }}
  th:nth-child(1) {{ width: 32%; }}
  th:nth-child(2) {{ width: 9%; }}
  th:nth-child(3) {{ width: 48%; }}
  th:nth-child(4) {{ width: 11%; }}
  td {{ padding: 0.35rem 0.75rem; border-bottom: 1px solid var(--border);
        vertical-align: top; word-break: break-word; }}
  tr:hover td {{ background: var(--hover); }}
  tr.section-header td {{ background: var(--section-bg); font-weight: 600;
                          padding: 0.4rem 0.75rem; border-top: 2px solid var(--border); }}
  tr.section-header details summary {{ cursor: pointer; list-style: none; }}
  tr.section-header details summary::-webkit-details-marker {{ display: none; }}
  .count {{ font-weight: normal; color: #888; font-size: 0.85em; }}
  code {{ font-family: monospace; background: var(--code-bg); padding: 0 3px;
          border-radius: 3px; font-size: 0.92em; }}
  .metric-type {{ font-family: monospace; font-size: 0.85em; color: var(--accent); }}
  .metric-source {{ font-size: 0.8em; color: #888; }}
  tr[hidden] {{ display: none; }}
</style>
</head>
<body>
<h1>{_esc(title)}</h1>
<p class="meta">
  Generated {_esc(generated_at)}
  {f'&nbsp;·&nbsp; commit <code>{_esc(sha[:7])}</code>' if sha else ''}
</p>
<input class="search-bar" type="search" id="search"
       placeholder="Filter metrics (name, description, or source)&hellip;"
       aria-label="Filter metrics">
<p class="stats" id="stats">{total} metrics from {len(sources)} sources</p>
<table>
  <thead>
    <tr>
      <th>Metric Name</th>
      <th>Type</th>
      <th>Description</th>
      <th>Source</th>
    </tr>
  </thead>
  <tbody id="tbody">
{rows}
  </tbody>
</table>
<script>
(function () {{
  var input = document.getElementById('search');
  var stats = document.getElementById('stats');
  var rows  = Array.from(document.querySelectorAll('#tbody tr:not(.section-header)'));
  var sections = Array.from(document.querySelectorAll('#tbody tr.section-header'));

  function filter() {{
    var q = input.value.trim().toLowerCase();
    var visible = 0;
    rows.forEach(function (r) {{
      var match = !q || r.textContent.toLowerCase().includes(q);
      r.hidden = !match;
      if (match) visible++;
    }});
    // Hide section headers when all their rows are hidden
    sections.forEach(function (sec) {{
      var src = sec.querySelector('[data-source]') ||
                sec.nextElementSibling;
      // find next section boundary
      var anyVisible = false;
      var el = sec.nextElementSibling;
      while (el && !el.classList.contains('section-header')) {{
        if (!el.hidden) {{ anyVisible = true; break; }}
        el = el.nextElementSibling;
      }}
      sec.hidden = !anyVisible && !!q;
    }});
    stats.textContent = q
      ? (visible + ' of {total} metrics match')
      : ('{total} metrics from {len(sources)} sources');
  }}
  input.addEventListener('input', filter);
}})();
</script>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a Prometheus metrics HTML reference page"
    )
    parser.add_argument(
        "--source",
        action="append",
        metavar="LABEL:PATH",
        default=[],
        help="Source label and path to raw /metrics text (repeatable)",
    )
    parser.add_argument("--sha", default="", help="Git commit SHA to embed in the page")
    parser.add_argument(
        "--title",
        default="AIC Prometheus Metrics Reference",
        help="Page title",
    )
    args = parser.parse_args()

    if not args.source:
        parser.error("Provide at least one --source LABEL:PATH argument")

    sources: list[tuple[str, list[MetricEntry]]] = []
    for spec in args.source:
        if ":" not in spec:
            parser.error(f"--source must be LABEL:PATH, got: {spec!r}")
        label, _, path_str = spec.partition(":")
        path = Path(path_str)
        if not path.exists():
            print(f"WARNING: {path} not found, skipping source {label!r}", file=sys.stderr)
            continue
        text = path.read_text(errors="replace")
        entries = parse_metrics(text, label)
        sources.append((label, entries))
        print(f"Parsed {len(entries)} metrics from {label} ({path})", file=sys.stderr)

    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%d %H:%M UTC"
    )
    print(render_html(sources, args.title, args.sha, generated_at))


if __name__ == "__main__":
    main()
