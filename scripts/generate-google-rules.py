#!/usr/bin/env python3
"""Generate Google service CIDRs from the official Google and Cloud ranges."""

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
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=30) as response:
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


def validate_source_ranges(
    source: str,
    ipv4: list[ipaddress._BaseNetwork],
    ipv6: list[ipaddress._BaseNetwork],
) -> None:
    for label, networks, version in (("IPv4", ipv4, 4), ("IPv6", ipv6, 6)):
        if not networks:
            raise ValueError(f"{source} contains no {label} prefixes")
        if any(network.version != version for network in networks):
            raise ValueError(f"{source} contains an invalid {label} prefix")


def validate_output_ranges(
    label: str,
    output_ranges: list[ipaddress._BaseNetwork],
    goog_ranges: list[ipaddress._BaseNetwork],
    cloud_ranges: list[ipaddress._BaseNetwork],
) -> None:
    if not output_ranges:
        raise ValueError(f"Google {label} output is empty")

    for network in output_ranges:
        if not any(network.subnet_of(goog) for goog in goog_ranges):
            raise ValueError(f"Google {label} output {network} is outside goog.json")
        overlap = next((cloud for cloud in cloud_ranges if network.overlaps(cloud)), None)
        if overlap is not None:
            raise ValueError(
                f"Google {label} output {network} overlaps cloud.json prefix {overlap}"
            )


def validate_metadata_counts(
    meta: dict,
    ipv4: list[ipaddress._BaseNetwork],
    ipv6: list[ipaddress._BaseNetwork],
) -> None:
    for key, networks in (("ipv4_count", ipv4), ("ipv6_count", ipv6)):
        if meta.get(key) != len(networks):
            raise ValueError(f"metadata {key} does not match generated output")


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

    goog_ipv4 = collect(goog["prefixes"], "ipv4Prefix")
    goog_ipv6 = collect(goog["prefixes"], "ipv6Prefix")
    cloud_ipv4 = collect(cloud["prefixes"], "ipv4Prefix")
    cloud_ipv6 = collect(cloud["prefixes"], "ipv6Prefix")
    validate_source_ranges("goog.json", goog_ipv4, goog_ipv6)
    validate_source_ranges("cloud.json", cloud_ipv4, cloud_ipv6)

    ipv4 = subtract_many(goog_ipv4, cloud_ipv4)
    ipv6 = subtract_many(goog_ipv6, cloud_ipv6)
    validate_output_ranges("IPv4", ipv4, goog_ipv4, cloud_ipv4)
    validate_output_ranges("IPv6", ipv6, goog_ipv6, cloud_ipv6)

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
    validate_metadata_counts(meta, ipv4, ipv6)

    write_lines(output / "google_ipv4.txt", ipv4)
    write_lines(output / "google_ipv6.txt", ipv6)
    (output / "rules.meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(ipv4)} IPv4 and {len(ipv6)} IPv6 rules to {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
