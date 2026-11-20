import sys, os, json, struct
sys.path.insert(0, os.popen("xcrun lldb -P").read().strip())
import lldb
HERE = os.path.dirname(os.path.abspath(__file__))
dbg = lldb.SBDebugger.Create(); dbg.SetAsync(False)
tgt = dbg.CreateTarget(os.path.join(HERE, "xair")); tgt.BreakpointCreateByName("main", "xair")
li = lldb.SBLaunchInfo([]); err = lldb.SBError(); proc = tgt.Launch(li, err)
fr = proc.GetSelectedThread().GetFrameAtIndex(0); assert fr.GetFunctionName() == "main"
SL = tgt.FindModule(lldb.SBFileSpec("xair")).GetObjectFileHeaderAddress().GetLoadAddress(tgt) - 0x100000000
o = lldb.SBExpressionOptions(); o.SetTimeoutInMicroSeconds(30_000_000); o.SetTryAllThreads(False)
root = fr.EvaluateExpression("(void*)calloc(1, 0x1b0)", o).GetValueAsUnsigned()
fr.EvaluateExpression("((void*(*)(void*))%d)((void*)%d)" % (0x100023e84 + SL, root), o)
def u64(a):
    e = lldb.SBError(); b = proc.ReadMemory(a, 8, e); return struct.unpack('<Q', b)[0] if e.Success() else 0
def cs(a):
    if a < 0x1000: return None
    try:
        e = lldb.SBError(); s = proc.ReadCStringFromMemory(a, 64, e); return s if e.Success() else None
    except Exception: return None
paths = {}
def walk(n, p, d=0):
    if d > 12: return
    paths[n] = p
    c = u64(n + 0x10)
    while c and c != n:
        walk(c, p + "/" + (cs(u64(c + 0x38)) or "?"), d + 1); c = u64(c + 0x08)
walk(root, "")
res = {}
for target in ["", "/-localprefs", "/-prefs", "/-stat", "/config/solo", "/-snap", "/-action", "/ch/01", "/ch/01/mix", "/fx/1"]:
    node = [k for k, v in paths.items() if v == target][0]
    m = {}
    for off in range(0x40, 0x400, 8):
        v = u64(node + off)
        if v in paths and v != node: m[hex(off)] = paths[v]
    res[target or "/"] = m
json.dump(res, open(os.path.join(HERE, "memmap.json"), "w"), indent=1)
proc.Kill()
