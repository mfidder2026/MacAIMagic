#!/usr/bin/env python3
"""Read a GGUF header (metadata + tensor table) from a local file or an HTTP URL, without numpy."""
import struct, sys, urllib.request, collections

class Src:
    def __init__(self, path):
        self.path, self.pos, self.buf, self.base = path, 0, b"", 0
    def _fill(self, need):
        if self.path.startswith("http"):
            start = self.base + len(self.buf)
            n = max(need, 8 << 20)
            req = urllib.request.Request(self.path, headers={"Range": f"bytes={start}-{start+n-1}"})
            self.buf += urllib.request.urlopen(req).read()
        else:
            with open(self.path, "rb") as f:
                f.seek(self.base + len(self.buf)); self.buf += f.read(max(need, 8 << 20))
    def read(self, n):
        while self.pos + n > len(self.buf): self._fill(self.pos + n - len(self.buf))
        b = self.buf[self.pos:self.pos+n]; self.pos += n; return b
    def u(self, fmt): return struct.unpack("<"+fmt, self.read(struct.calcsize(fmt)))[0]

SC = {0:"B",1:"b",2:"H",3:"h",4:"I",5:"i",6:"f",7:"?",10:"Q",11:"q",12:"d"}
TYPES = {0:"F32",1:"F16",2:"Q4_0",3:"Q4_1",6:"Q5_0",7:"Q5_1",8:"Q8_0",9:"Q8_1",10:"Q2_K",11:"Q3_K",12:"Q4_K",13:"Q5_K",14:"Q6_K",15:"Q8_K",16:"IQ2_XXS",17:"IQ2_XS",18:"IQ3_XXS",19:"IQ1_S",20:"IQ4_NL",21:"IQ3_S",22:"IQ2_S",23:"IQ4_XS",24:"I8",25:"I16",26:"I32",27:"I64",28:"F64",29:"IQ1_M",30:"BF16",34:"TQ1_0",35:"TQ2_0",39:"MXFP4"}

def val(s, t):
    if t in SC: return s.u(SC[t])
    if t == 8: return s.read(s.u("Q")).decode("utf-8", "replace")
    if t == 9:
        et, n = s.u("I"), s.u("Q")
        items = [val(s, et) for _ in range(n)]
        return items if n <= 16 else f"[{n} x type{et}] first={items[:4]}"
    raise ValueError(t)

def peek(path):
    s = Src(path)
    assert s.read(4) == b"GGUF", "not a GGUF"
    ver, nt, nkv = s.u("I"), s.u("Q"), s.u("Q")
    kv = {}
    for _ in range(nkv):
        k = s.read(s.u("Q")).decode(); kv[k] = val(s, s.u("I"))
    tensors = []
    for _ in range(nt):
        name = s.read(s.u("Q")).decode(); nd = s.u("I")
        dims = [s.u("Q") for _ in range(nd)]; t = s.u("I"); off = s.u("Q")
        tensors.append((name, dims, TYPES.get(t, t), off))
    return ver, kv, tensors

if __name__ == "__main__":
    ver, kv, tensors = peek(sys.argv[1])
    full = "-v" in sys.argv
    print(f"GGUF v{ver}: {len(kv)} keys, {len(tensors)} tensors")
    for k, v in kv.items():
        if full or not k.startswith("tokenizer.ggml."): print(f"  {k} = {str(v)[:160]}")
    pat = collections.Counter()
    for n, d, t, _ in tensors:
        g = ".".join("N" if p.isdigit() else p for p in n.split("."))
        pat[(g, t)] += 1
    for (g, t), c in sorted(pat.items()): print(f"  {c:4d} x {g:40s} {t}")
