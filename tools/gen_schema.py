#!/usr/bin/env python3 -I
"""Generate Packages/XAirKit/Sources/XAirKit/Resources/xair-schema.json.

Inputs (all produced from the original X-AIR-Edit 1.8.1 binary, see PROTOCOL.md):
  research/runtime-dumps/tree.jsonl   - Croot::Croot() parameter tree walked in a scratch,
                                        ad-hoc re-signed copy stopped at main (tools/drive.py)
  research/runtime-dumps/fx.json      - Cfxunit::update(fx,100) run for every FX type,
                                        fxdefs/fxparcfg tables, allpaths/prefstatsnap/... tables
  research/runtime-dumps/strtabs.json - UI string tables (_effect_name, input_txt, ...)

Param encoding in the output (one list per parameter, child order preserved):
  [name, "s", maxLen]                 string      (Cparam type 0xc5)
  [name, "i", min, max, fmt]          integer     (0xc1)
  [name, "e", enumIndex]              enum        (0xc2) -> "enums"[enumIndex]
  [name, "l", steps, min, max, fmt]   linear      (0xc3) value = min + (max-min)*i/steps
  [name, "g", steps, min, k, fmt]     log         (0xc4) value = min * exp(k*i)
  [name, "f", steps]                  fader level (0xc6) 4-segment dB law
  [name, "v", steps]                  send level  (0xc7) same law, '#l' display
Optional trailing object {"x":1} = Cparam+0x69 set (not copied by channel-link copy).
"""
import json, os, sys, math, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RD = os.path.join(ROOT, "research", "runtime-dumps")
OUT = os.path.join(ROOT, "Packages", "XAirKit", "Sources", "XAirKit", "Resources", "xair-schema.json")

def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]

recs = [json.loads(l) for l in open(os.path.join(RD, "tree.jsonl"))]
fx = json.load(open(os.path.join(RD, "fx.json")))
st = json.load(open(os.path.join(RD, "strtabs.json")))

enums, enum_index = [], {}
def enum_id(items):
    key = tuple(items)
    if key not in enum_index:
        enum_index[key] = len(enums)
        enums.append(list(items))
    return enum_index[key]

def encode_param(r, name=None):
    t = r["type"]; n = name or r["name"]
    if t == 0xc5:
        p = [n, "s", r["imax"]]
    elif t == 0xc1:
        p = [n, "i", r["imin"], r["imax"], r.get("fmt") or "%d"]
    elif t == 0xc2:
        p = [n, "e", enum_id(r.get("enum") or [])]
    elif t == 0xc3:
        p = [n, "l", r["imax"], f32(r["fmin"]), f32(r["fmax"]), r.get("fmt") or "%f"]
    elif t == 0xc4:
        p = [n, "g", r["imax"], f32(r["fmin"]), f32(r["fmax"]), r.get("fmt") or "%f"]
    elif t == 0xc6:
        p = [n, "f", r["imax"]]
    elif t == 0xc7:
        p = [n, "v", r["imax"]]
    else:
        raise SystemExit("unknown type %r at %s" % (t, r.get("path")))
    if r.get("b69"):
        p.append({"x": 1})
    return p

# Build node list: every non-param record becomes a node; its direct param
# children (in order) become its params; child node names are listed too.
by_parent = {}
order = []
for r in recs:
    path = r["path"] or "/"
    parent = path.rsplit("/", 1)[0] or "/" if path != "/" else None
    r["_path"] = path
    if parent is not None:
        by_parent.setdefault(parent, []).append(r)
    order.append(r)

nodes = []
for r in order:
    if 0xc1 <= r["type"] <= 0xc7:
        continue
    path = r["_path"]
    kids = by_parent.get(path, [])
    params, subs = [], []
    for k in kids:
        if 0xc1 <= k["type"] <= 0xc7:
            if subs:
                # params after a sub-node are not part of the node's arg list
                params.append(encode_param(k) + [{"late": 1}])
            else:
                params.append(encode_param(k))
        else:
            subs.append(k["name"])
    nodes.append({"p": path, "t": r["type"], "c": params, "n": subs})

# FX parameter definitions per FX type.
defs = {d["alg"]: d for d in fx["fxdefs"]}
fxtypes = fx["types"]
fxdefs = {}
for ti, tname in enumerate(fxtypes):
    alg = fx["fxalg"][ti]
    names = [e.get("last") for e in defs.get(alg, {}).get("cfgents", [])]
    plist = []
    for pi, r in enumerate(fx["fx"][tname]):
        if r["type"] == 0xc3 and r["imax"] == 0 and r.get("fmt") == "0":
            continue  # unused slot
        rr = dict(r)
        if r["type"] == 0xc2:
            rr["enum"] = [e for e in (r.get("enum") or [])]
        disp = names[pi] if pi < len(names) and names[pi] and not str(names[pi]).startswith("0x") else None
        p = encode_param(rr, name="%02d" % (pi + 1))
        p.append({"label": disp or "Param %d" % (pi + 1), "def": r["val"]})
        plist.append(p)
    fxdefs[tname] = plist

def cut(lst, n):
    return [x for x in lst[:n]]

schema = {
    "schemaVersion": 1,
    "source": {
        "app": "X-AIR-Edit 1.8.1 (CFBundleVersion 1.8.0)",
        "binarySha256": "fe5581370f2b8e9f1069e1e966530f366e2c05de7c5730ed5d98148db97232c2",
        "method": "Croot::Croot() and Cfxunit::update() executed in a scratch copy stopped at main; tree walked read-only via lldb (no network code reached).",
    },
    "enums": enums,
    "nodes": nodes,
    "fxTypes": fxtypes,
    "fxLongNames": cut(st["_effect_name"], 61),
    "fxAlgorithm": fx["fxalg"],
    "fx": fxdefs,
    "syncPaths": fx["tables"]["allpaths"],
    "prefStatSnapPaths": fx["tables"]["prefstatsnap"],
    "usbDirPaths": fx["tables"]["recpaths"],
    "meterIds": fx["tables"]["subscription_id"],
    "meterPaths": fx["tables"]["meter_id"],
    "meterBatchSize": fx["tables"]["meterbatchsize"],
    "labels": {
        "inputX18": cut(st["input_txt"], 19),
        "inputXR16": cut(st["inputXR16_txt"], 19),
        "inputXR12": cut(st["inputXR12_txt"], 15),
        "rtaSource": cut(st["_rtasrctxt"], 33),
        "recorderSource": cut(st["recsrc_txt"], 38),
        "userChannel": cut(st["userchn_txt"], 37),
        "routingTaps": cut(st["taps_txt"], 11),
        "routingPresets": cut(st["preset_txt"], 12),
        "snapshotScope": cut(st["scope_txt"], 59),
        "eqBandButtons": cut(st["button_txt"], 6),
        "keySource": cut(st["keysrc_txt"], 23),
        "fxSource": cut(st["_fxsource_txt"], 24),
        "sends": cut(st["sends_txt"], 10),
    },
}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as fh:
    json.dump(schema, fh, separators=(",", ":"))
nparams = sum(len(n["c"]) for n in nodes)
late = sum(1 for n in nodes for c in n["c"] if isinstance(c[-1], dict) and c[-1].get("late"))
print("nodes", len(nodes), "params", nparams, "late", late, "enums", len(enums), "fx", len(fxdefs),
      "bytes", os.path.getsize(OUT))
