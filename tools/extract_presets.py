#!/usr/bin/env python3
"""Extract the routing and EQ presets embedded in X-AIR-Edit 1.8.1 for ARM64."""

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
binary = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT.parent / "X-AIR-Edit.arm64"
destination = ROOT / "Packages/XAirKit/Sources/XAirKit/Resources/builtin-presets.json"
data = binary.read_bytes()

# RoutingPresetSelect passes these strings to Cnode::updateFromStringPos.
offset, end = 0x321D29, 0x323A40
presets = []
while offset < end and len(presets) < 14:
    nul = data.find(b"\0", offset, end)
    if nul < 0:
        break
    value = data[offset:nul].decode("cp1252")
    if value.strip():
        lines = [line.strip() for line in value.splitlines() if line.strip()]
        comment = next((line for line in lines if line.startswith(("//", "#"))), "")
        presets.append({
            "address": hex(0x100000000 + offset),
            "comment": comment.lstrip("/# ").strip(),
            "lines": [line for line in lines if not line.startswith(("//", "#"))],
        })
    offset = nul + 1

if len(presets) != 14:
    sys.exit(f"Expected 14 desktop presets in the 1.8.1 string block, found {len(presets)}")

# The titles are taken from the desktop preset_txt table.
titles = {
    "ultranet": ["Chn 1-16", "Chn 1-8 / Bus / LR", "Ch 1-8 / FX", "USB Return"],
    "usbReturn": ["Off (Analog)", "Chn 1-16", "USB Plugin", "USB 1-2 to Aux"],
    "usbSend": ["Chn 1-18", "Chn 1-16 / LR", "USB Plugin", "Buses / FX"],
}
catalog = {
    "source": "X-AIR-Edit 1.8.1 string block 0x100321d29 (RoutingPresetSelect)",
    "ultranet": presets[:4], "usbReturn": presets[4:8], "usbSend": presets[8:12],
    "eqInit4": presets[12], "eqInit6": presets[13],
}
for group, names in titles.items():
    for preset, name in zip(catalog[group], names):
        preset["title"] = name

output = json.dumps(catalog, indent=1)
if not destination.exists() or destination.read_text(encoding="utf-8") != output:
    destination.write_text(output, encoding="utf-8")
print(f"Extracted 12 routing presets and two EQ curves from {binary.name} into {destination.name}")
