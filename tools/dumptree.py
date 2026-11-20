# lldb script: walk the X-AIR-Edit Cnode/Cparam tree from the Croot* in x0
# and write one JSON object per node/param. Read-only memory access.
import lldb, json, struct
from pathlib import Path

OUT = Path(__file__).with_name("tree.jsonl")

def rd(proc, addr, n):
    err = lldb.SBError()
    b = proc.ReadMemory(addr, n, err)
    if not err.Success():
        return None
    return b

def u64(p, a):
    b = rd(p, a, 8); return struct.unpack('<Q', b)[0] if b else 0
def i32(p, a):
    b = rd(p, a, 4); return struct.unpack('<i', b)[0] if b else 0
def f32(p, a):
    b = rd(p, a, 4); return struct.unpack('<f', b)[0] if b else 0.0
def u8(p, a):
    b = rd(p, a, 1); return b[0] if b else 0
def cstr(p, a, maxn=128):
    if a == 0: return None
    err = lldb.SBError()
    s = p.ReadCStringFromMemory(a, maxn, err)
    return s if err.Success() else None

def symname(target, addr):
    sa = target.ResolveLoadAddress(addr)
    sym = sa.GetSymbol()
    if sym and sym.IsValid():
        return sym.GetName() + ("+%d" % (addr - sym.GetStartAddress().GetLoadAddress(target)))
    return hex(addr)

def walk(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    proc = target.GetProcess()
    frame = proc.GetSelectedThread().GetFrameAtIndex(0)
    root = int(command, 0) if command.strip() else frame.FindRegister("x0").GetValueAsUnsigned()
    out = open(OUT, "w")
    seen = set()
    count = [0]
    def visit(node, path, depth):
        if node in seen or depth > 12:
            return
        seen.add(node)
        typ = i32(proc, node + 0x20)
        idx = i32(proc, node + 0x24)
        name = cstr(proc, u64(proc, node + 0x38))
        vt = u64(proc, node)
        rec = {"addr": hex(node), "path": path, "name": name, "type": typ, "index": idx,
               "vt": symname(target, vt), "depth": depth}
        if 0xc1 <= typ <= 0xc7:
            rec["imin"] = i32(proc, node + 0x4c)
            rec["imax"] = i32(proc, node + 0x50)
            rec["fmin"] = f32(proc, node + 0x54)
            rec["fmax"] = f32(proc, node + 0x58)
            rec["val"] = i32(proc, node + 0x5c)
            p60 = u64(proc, node + 0x60)
            rec["b68"] = u8(proc, node + 0x68)
            rec["b69"] = u8(proc, node + 0x69)
            rec["i6c"] = i32(proc, node + 0x6c)
            rec["w48"] = i32(proc, node + 0x48)
            if typ == 0xc2:
                n = rec["imax"] + 1
                items = []
                if p60 and 0 < n < 400:
                    for k in range(n):
                        items.append(cstr(proc, u64(proc, p60 + 8 * k), 64))
                rec["enum"] = items
            elif typ == 0xc5:
                rec["str"] = cstr(proc, p60, 64)
            else:
                rec["fmt"] = cstr(proc, p60, 32)
        out.write(json.dumps(rec) + "\n")
        count[0] += 1
        child = u64(proc, node + 0x10)
        guard = 0
        while child and child != node and guard < 5000:
            cname = cstr(proc, u64(proc, child + 0x38)) or "?"
            visit(child, path + "/" + cname, depth + 1)
            child = u64(proc, child + 0x08)
            guard += 1
    visit(root, "", 0)
    out.close()
    print("dumped %d records from root %s" % (count[0], hex(root)))

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f dumptree.walk dumptree")
