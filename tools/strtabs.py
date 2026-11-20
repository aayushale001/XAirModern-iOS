import sys, os, json, struct
sys.path.insert(0, os.popen("xcrun lldb -P").read().strip())
import lldb
HERE = os.path.dirname(os.path.abspath(__file__))
dbg = lldb.SBDebugger.Create(); dbg.SetAsync(False)
tgt = dbg.CreateTarget(os.path.join(HERE, "xair")); tgt.BreakpointCreateByName("main", "xair")
err = lldb.SBError(); proc = tgt.Launch(lldb.SBLaunchInfo([]), err)
fr = proc.GetSelectedThread().GetFrameAtIndex(0); assert fr.GetFunctionName() == "main"
SL = tgt.FindModule(lldb.SBFileSpec("xair")).GetObjectFileHeaderAddress().GetLoadAddress(tgt) - 0x100000000
def u64(a):
    e = lldb.SBError(); b = proc.ReadMemory(a, 8, e); return struct.unpack('<Q', b)[0] if e.Success() else 0
def cs(a):
    if a < 0x100000000: return None
    try:
        e = lldb.SBError(); s = proc.ReadCStringFromMemory(a, 80, e); return s if e.Success() else None
    except Exception: return None
tabs = {"inputXR16_txt":0x1006b0cf8,"inputXR12_txt":0x1006b0d90,"input_txt":0x1006b0e08,"routing_txt":0x1006b0ea0,
"mainrout_txt":0x1006b1060,"_rtasrctxt":0x10067e218,"recsrc_txt":0x1006842b8,"src_txt":0x100689260,"sends_txt":0x100687c58,
"_channelname_txt":0x1006895c8,"_busmasterText":0x1006896c8,"keysrc_txt":0x100687358,"_fxsource_txt":0x100687448,
"taps_txt":0x100686580,"row_txt":0x100686110,"row_txt_usblr":0x100686148,"userchn_txt":0x10067d2b8,"_effect_name":0x100688a98,
"scope_txt":0x1006846a8,"preset_txt":0x1006860b0,"button_txt":0x100688220,"clock_rate":0x1006b0cc8,"usb_inter":0x1006b0cd8,
"pfl_afl":0x1006b0ce8,"_eqmode_txt":0x1006b1120}
out = {}
for k, a in tabs.items():
    vals = []; miss = 0
    for i in range(160):
        s = cs(u64(a + SL + 8 * i))
        if s is None:
            miss += 1
            if miss > 1: break
            vals.append(None); continue
        miss = 0; vals.append(s)
    while vals and vals[-1] is None: vals.pop()
    out[k] = vals
e = lldb.SBError(); b = proc.ReadMemory(0x1002d5ad4 + SL, 0x180, e); out["namecolours_raw"] = b.hex() if b else None
json.dump(out, open(os.path.join(HERE, "strtabs.json"), "w"), indent=1)
proc.Kill()
for k, v in out.items():
    if k != "namecolours_raw": print(k, len(v), v[:70])
