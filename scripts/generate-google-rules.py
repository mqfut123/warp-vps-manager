#!/usr/bin/env python3
"""Generate fixed Google consumer-service CIDR snapshots.

The project intentionally ships static rule files. Maintainers run this script
locally, review the diff, then publish the updated snapshot to GitHub.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import pathlib
import sys
import urllib.request
from datetime import datetime, timezone


GOOG_URL = "https://www.gstatic.com/ipranges/goog.json"
CLOUD_URL = "https://www.gstatic.com/ipranges/cloud.json"


def load_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.loads(response.read())


def collect(prefixes: list[dict], key: str) -> list[ipaddress._BaseNetwork]:
    return [ipaddress.ip_network(item[key]) for item in prefixes if key in item]


def subtract_many(
    base_ranges: list[ipaddress._BaseNetwork],
    excluded_ranges: list[ipaddress._BaseNetwork],
) -> list[ipaddress._BaseNetwork]:
    result: list[ipaddress._BaseNetwork] = []
    for network in base_ranges:
        parts = [network]
        for excluded in excluded_ranges:
            if network.version != excluded.version:
                continue
            next_parts: list[ipaddress._BaseNetwork] = []
            for part in parts:
                if not part.overlaps(excluded):
                    next_parts.append(part)
                    continue
                if excluded.supernet_of(part) or excluded == part:
                    continue
                if part.supernet_of(excluded):
                    next_parts.extend(part.address_exclude(excluded))
                else:
                    next_parts.append(part)
            parts = next_parts
            if not parts:
                break
        result.extend(parts)
    return sorted(result, key=lambda net: (net.version, int(net.network_address), net.prefixlen))


def write_lines(path: pathlib.Path, networks: list[ipaddress._BaseNetwork]) -> None:
    body = "\n".join(str(network) for network in networks) + "\n"
    path.write_text(body, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="rules", help="Output directory")
    args = parser.parse_args()

    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    goog = load_json(GOOG_URL)
    cloud = load_json(CLOUD_URL)

    ipv4 = subtract_many(
        collect(goog["prefixes"], "ipv4Prefix"),
        collect(cloud["prefixes"], "ipv4Prefix"),
    )
    ipv6 = subtract_many(
        collect(goog["prefixes"], "ipv6Prefix"),
        collect(cloud["prefixes"], "ipv6Prefix"),
    )

    write_lines(output / "google_ipv4.txt", ipv4)
    write_lines(output / "google_ipv6.txt", ipv6)
    meta = {
        "source": {
            "goog": GOOG_URL,
            "cloud": CLOUD_URL,
            "goog_creation_time": goog.get("creationTime"),
            "cloud_creation_time": cloud.get("creationTime"),
            "method": "goog.json minus cloud.json",
        },
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "ipv4_count": len(ipv4),
        "ipv6_count": len(ipv6),
    }
    (output / "rules.meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(ipv4)} IPv4 and {len(ipv6)} IPv6 rules to {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

