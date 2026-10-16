#!/usr/bin/env python3
"""
Inject the WorldGuard World1 bring-up block into an upstream OpenSBI
firmware/fw_base.S, immediately before the `call sbi_init` at the end of
the warm-boot path (i.e. after mscratch/stack/mtvec are set up for the
hart -- the placement that earlier debugging established as correct).

Anchoring on this call site rather than replacing the whole file keeps the
build tolerant of upstream drift (e.g. the RNMI handler master's C code
now requires, which a wholesale file replacement clobbered).

Usage: apply_wg_patch.py <fw_base.S path> <snippet path>
"""
import sys

fw_path, snip_path = sys.argv[1], sys.argv[2]

with open(fw_path) as f:
    src = f.read()
with open(snip_path) as f:
    snippet = f.read()

if "_normal_sbi_init" in src:
    print("fw_base.S already patched; leaving as-is")
    sys.exit(0)

# Preferred, precise anchor: the csrr+call pair.
anchor = "\tcsrr\ta0, CSR_MSCRATCH\n\tcall\tsbi_init"
n = src.count(anchor)
if n != 1:
    # Fallback: the call alone. Inserting between the csrr and the call is
    # also safe: the hart0 fall-through path does not touch a0, and the
    # hart1 path never returns (mret).
    anchor = "\tcall\tsbi_init"
    n = src.count(anchor)
    if n != 1:
        sys.exit(
            f"ERROR: anchor 'call sbi_init' found {n} times in {fw_path} "
            "(expected exactly 1). Upstream layout has changed more than "
            "expected -- inspect fw_base.S manually and adjust this script."
        )

src = src.replace(anchor, snippet + "\n" + anchor)

with open(fw_path, "w") as f:
    f.write(src)
print(f"Injected World1 block into {fw_path} (anchor: {anchor.strip()!r})")
