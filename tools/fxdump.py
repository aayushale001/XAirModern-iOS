#!/usr/bin/env python3
# Stop the scratch copy at main (before any socket exists), build a Croot,
# then for every FX type call Cfxunit::update(fx/1, 100) and dump fx/1/par.
# Also dumps static path tables. Kills the process at the end.
import sys, os, time, json, struct
sys.path.insert(0, os.popen("xcrun lldb -P").read().strip())
import lldb

HERE = os.path.dirname(os.path.abspath(__file__))
dbg = lldb.SBDebugger.Create(); dbg.SetAsync(False)
tgt = dbg.CreateTarget(os.path.join(HERE, "xair"))
tgt.BreakpointCreateByName("main", "xair")
li = lldb.SBLaunchInfo([]); li.SetLaunchFlags(lldb.eLaunchFlagDisableASLR)
err = lldb.SBError(); proc = tgt.Launch(li, err)
th = proc.GetSelectedThread(); fr = th.GetFrameAtIndex(0)
print("stopped in", fr.GetFunctionName(), flush=True)
assert fr.GetFunctionName() == "main"
mod = tgt.FindModule(lldb.SBFileSpec("xair"))
SL = mod.GetObjectFileHeaderAddress().GetLoadAddress(tgt) - 0x100000000
opts = lldb.SBExpressionOptions(); opts.SetTimeoutInMicroSeconds(30_000_000)
opts.SetTryAllThreads(False); opts.SetUnwindOnError(True); opts.SetIgnoreBreakpoints(True)

def ev(expr):
    v = fr.EvaluateExpression(expr, opts)
    if v.GetError().Fail(): print("EXPR FAIL", expr, v.GetError()); return None
    return v.GetValueAsUnsigned()
def rd(a, n):
    e = lldb.SBError(); b = proc.ReadMemory(a, n, e); return b if e.Success() else None
def u64(a): b = rd(a, 8); return struct.unpack('<Q', b)[0] if b else 0
def i32(a): b = rd(a, 4); return struct.unpack('<i', b)[0] if b else 0
def f32(a): b = rd(a, 4); return struct.unpack('<f', b)[0] if b else 0.0
def cs(a, n=128):
    if not a or a < 0x1000: return None
    try:
        e = lldb.SBError(); s = proc.ReadCStringFromMemory(a, n, e)
        return s if e.Success() else None
    except Exception: return None
def wr32(a, v): e = lldb.SBError(); proc.WriteMemory(a, struct.pack('<i', v), e); return e.Success()
def wr64(a, v): e = lldb.SBError(); proc.WriteMemory(a, struct.pack('<Q', v), e); return e.Success()

root = ev("(void*)calloc(1, 0x1b0)")
ev("((void*(*)(void*))%d)((void*)%d)" % (0x100023e84 + SL, root))
wr64(0x1006c2b68 + SL, root)          # _root global
oscc = ev("(void*)calloc(1, 0x1000)")  # dummy OscCom: +0x260 online flag = 0
wr64(0x1006c2b80 + SL, oscc)           # _osc_comm global

def child(node, name):
    c = u64(node + 0x10)
    while c and c != node:
        if cs(u64(c + 0x38)) == name: return c
        c = u64(c + 0x08)
    return 0
def children(node):
    out = []; c = u64(node + 0x10)
    while c and c != node and len(out) < 300:
        out.append(c); c = u64(c + 0x08)
    return out
def param(p):
    t = i32(p + 0x20)
    r = {"name": cs(u64(p + 0x38)), "type": t, "imin": i32(p + 0x4c), "imax": i32(p + 0x50),
         "fmin": f32(p + 0x54), "fmax": f32(p + 0x58), "val": i32(p + 0x5c), "w6c": f32(p + 0x6c)}
    q = u64(p + 0x60)
    if t == 0xc2:
        r["enum"] = [cs(u64(q + 8 * k), 64) for k in range(r["imax"] + 1)] if 0 <= r["imax"] < 300 else []
    elif t == 0xc5: r["str"] = cs(q, 64)
    else: r["fmt"] = cs(q, 32)
    return r

fx = child(child(root, "fx"), "1")
typ = child(fx, "type"); par = child(fx, "par")
print("fx1", hex(fx), "type", hex(typ), "par", hex(par), flush=True)
ntypes = i32(typ + 0x50) + 1
tnames = [cs(u64(u64(typ + 0x60) + 8 * k)) for k in range(ntypes)]
fxalg = list(rd(0x1002d4c48 + SL, ntypes))
out = {"types": tnames, "fxalg": fxalg, "fx": {}}
for t in range(ntypes):
    wr32(typ + 0x5c, t)
    ok = ev("((void(*)(void*,int))%d)((void*)%d, 100)" % (0x10001d794 + SL, fx))
    ps = [param(p) for p in children(par)]
    out["fx"][tnames[t]] = ps
    nreal = sum(1 for p in ps if not (p["type"] == 0xc3 and p["imax"] == 0))
    print(t, tnames[t], "alg", fxalg[t], "params", nreal, "ok" if ok is not None else "FAIL", flush=True)
# raw fxdefs (32-byte entries) to recover names/counts
defs = []
for a in range(64):
    base = 0x10067b818 + SL + 32 * a
    raw = rd(base, 32)
    if raw is None: break
    q0, q1, cnt, q3 = struct.unpack('<QQQQ', raw)
    defs.append({"alg": a, "p0": cs(q0, 64), "p1": cs(q1, 64), "count": cnt & 0xffffffff, "cfg": hex(q3)})
out["fxdefs"] = defs
# parameter names: look at fxparcfg entries' remaining pointer fields
def cfgdump(ptr, n):
    ents = []
    for k in range(n):
        raw = rd(ptr + 40 * k, 40)
        if raw is None: break
        fmin, fmax, steps, w3 = struct.unpack('<fffI', raw[:16])
        fmtp, = struct.unpack('<Q', raw[16:24]); f6, f7 = struct.unpack('<ff', raw[24:32]); last, = struct.unpack('<Q', raw[32:40])
        ents.append({"min": fmin, "max": fmax, "steps": steps, "w3": w3, "fmt": cs(fmtp, 32), "f6": f6, "dflt": f7, "last": cs(last, 64) or hex(last)})
    return ents
for d in defs:
    try:
        if d["count"] and d["count"] < 100: d["cfgents"] = cfgdump(int(d["cfg"], 16), d["count"])
    except Exception as e: d["err"] = str(e)
tables = {}
for name, addr, n in [("allpaths", 0x100689ec8, 693), ("subscription_id", 0x10068bf50, 10),
                      ("meter_id", 0x10068bfa0, 10), ("recpaths", 0x10068b778, 300),
                      ("prefstatsnap", 0x10068b4e8, 82), ("meterbatchsize", None, 0)]:
    if addr is None: continue
    vals = []
    for k in range(n):
        s = cs(u64(addr + SL + 8 * k), 200)
        if s is None and name in ("recpaths",): break
        vals.append(s)
    tables[name] = vals
mb = rd(0x1002d5c54 + SL, 40); tables["meterbatchsize"] = list(struct.unpack('<10i', mb)) if mb else None
out["tables"] = tables
json.dump(out, open(os.path.join(HERE, "fx.json"), "w"), indent=1)
print("tables", {k: (len(v) if v else v) for k, v in tables.items()}, flush=True)
proc.Kill()
