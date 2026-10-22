# Which Triton-CPU kernels die with SIGILL on this host? Run as: python triton_probe.py [add|exp]
import sys
import torch
import triton
import triton.language as tl
from triton._C.libtriton import cpu


@triton.jit
def add_one(x, y, n, B: tl.constexpr):
    o = tl.arange(0, B)
    m = o < n
    tl.store(y + o, tl.load(x + o, mask=m) + 1, mask=m)


@triton.jit
def exp(x, y, n, B: tl.constexpr):
    o = tl.arange(0, B)
    m = o < n
    tl.store(y + o, tl.exp(tl.load(x + o, mask=m)), mask=m)


if len(sys.argv) == 1:
    print("LLVM host CPU:", cpu.llvm.get_cpu_name())
    print("LLVM AVX-512 features:", sorted(f for f in cpu.llvm.get_cpu_features() if "avx512" in f) or "none")
else:
    x = torch.rand(1000)
    y = torch.empty_like(x)
    {"add": add_one, "exp": exp}[sys.argv[1]][(1,)](x, y, 1000, B=1024)
    ref = x + 1 if sys.argv[1] == "add" else torch.exp(x)
    print(sys.argv[1], "ok" if torch.allclose(y, ref) else "WRONG")
