#!/usr/bin/env python3
# Drive lldb via its Python API: launch the scratch copy, stop after Croot::Croot
# returns, dump the parameter tree plus selected static tables, then kill.
import sys, os, time, json, struct
sys.path.insert(0, os.popen("xcrun lldb -P").read().strip())
import lldb

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
EXE = os.path.join(HERE, "xair")
BP = 0x10010cb10  # _main

dbg = lldb.SBDebugger.Create()
dbg.SetAsync(True)
tgt = dbg.CreateTarget(EXE)
bp = tgt.BreakpointCreateByName("main", "xair")
print("bp locations", bp.GetNumLocations(), flush=True)
li = lldb.SBLaunchInfo([])
li.SetLaunchFlags(lldb.eLaunchFlagDisableASLR)
err = lldb.SBError()
proc = tgt.Launch(li, err)
print("launch:", err.Success(), err.GetCString(), flush=True)
listener = dbg.GetListener()
ev = lldb.SBEvent()
deadline = time.time() + 600
stopped = False
while time.time() < deadline:
    if listener.WaitForEvent(1, ev):
        st = lldb.SBProcess.GetStateFromEvent(ev)
        if st == lldb.eStateStopped:
            th = proc.GetSelectedThread()
            pc = th.GetFrameAtIndex(0).GetPC()
            print("stopped at", hex(pc), th.GetStopReason(), flush=True)
            fn = th.GetFrameAtIndex(0).GetFunctionName()
            print("fn", fn, flush=True)
            if fn == "main":
                stopped = True
                break
            proc.Continue()
        elif st in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
            print("process ended", st, proc.GetExitStatus(), proc.GetExitDescription(), flush=True)
            break
if not stopped:
    print("did not reach breakpoint; state", proc.GetState(), flush=True)
    proc.SendAsyncInterrupt()
    time.sleep(1)
    for t in proc:
        print("thread", t.GetIndexID())
        for i, f in enumerate(t):
            if i > 12: break
            print("   ", f)
    proc.Kill()
    sys.exit(1)

import dumptree
class R: pass
opts = lldb.SBExpressionOptions(); opts.SetTimeoutInMicroSeconds(60*1000*1000); opts.SetTryAllThreads(False); opts.SetUnwindOnError(True)
fr = proc.GetSelectedThread().GetFrameAtIndex(0)
mod = tgt.FindModule(lldb.SBFileSpec("xair"))
SLIDE = mod.GetObjectFileHeaderAddress().GetLoadAddress(tgt) - 0x100000000
print("slide", hex(SLIDE), flush=True)
v = fr.EvaluateExpression("(void*)calloc(1, 0x1b0)", opts)
mem = v.GetValueAsUnsigned(); print("alloc", hex(mem), v.GetError(), flush=True)
v2 = fr.EvaluateExpression("((void*(*)(void*))%d)((void*)%d)" % (0x100023e84 + SLIDE, mem), opts)
print("ctor", v2.GetValue(), v2.GetError(), flush=True)
v3 = fr.EvaluateExpression("((void(*)(void*))%d)((void*)%d)" % (0x10001e1f4 + SLIDE, mem), opts)
print("createPath", v3.GetError(), flush=True)
res = lldb.SBCommandReturnObject()
dumptree.walk(dbg, hex(mem), res, {})

# static tables: allpaths (693 char*), _subscription_id, _meter_id, recpaths, prefstatsnap
def u64(a):
    e = lldb.SBError(); b = proc.ReadMemory(a, 8, e); return struct.unpack('<Q', b)[0]
def cs(a):
    if not a: return None
    e = lldb.SBError(); return proc.ReadCStringFromMemory(a, 200, e)
tables = {}
for name, addr, n in [("allpaths", 0x100689ec8, 693), ("subscription_id", 0x10068bf50, 10),
                      ("meter_id", 0x10068bfa0, 10), ("recpaths", 0x10068b778, 300),
                      ("prefstatsnap", 0x10068b4e8, 80)]:
    vals = []
    for k in range(n):
        p = u64(addr + SLIDE + 8 * k)
        s = cs(p) if p > 0x100000000 else None
        if s is None and name in ("recpaths", "prefstatsnap"):
            break
        vals.append(s)
    tables[name] = vals
json.dump(tables, open(os.path.join(HERE, "tables.json"), "w"), indent=1)
print("tables:", {k: len(v) for k, v in tables.items()}, flush=True)
proc.Kill()
