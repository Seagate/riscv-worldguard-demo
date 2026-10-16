#!/bin/bash
set -e

# ==========================================================================
# Two-world WorldGuard demo boot
#
#   hart 0 / WID 0:  OpenSBI fw_jump -> Linux @ 0x80200000, console ttyS0
#   hart 1 / WID 1:  patched fw_base.S -> Linux @ 0x88200000, no console,
#                    telnet over virtio-net (host port 2323)
#
# Memory map (256 MB total, wgChecker @ 0x06000000 programmed by fw_base.S):
#   0x80000000-0x87ffffff  World0 (WID0 RW)   fw_jump / Image / initrd / dtb
#   0x88000000-0x8fffffff  World1 (WID1 RW)   Image / initrd / dtb
#
# wg=on is REQUIRED: without it the fork's virt machine does not
# instantiate the WorldGuard hardware, and hart 1's first wgChecker MMIO
# write (0x06000020) store-faults, leaving hart 1 hung in OpenSBI.
#
# World0's DTB goes in via -dtb (NOT loader): fw_jump copies the DTB it
# receives from QEMU to FW_JUMP_FDT_ADDR=0x87f00000, which would overwrite
# a loader-placed file there. World1's DTB is untouched by that relocation
# and stays a plain loader blob at 0x8e000000. No -kernel/-initrd/-append
# anywhere (single-instance mechanisms).
# ==========================================================================

QEMU=${QEMU:-qemu-system-riscv64}

exec ${QEMU} \
  -M virt,worlds=on \
  -smp 2 \
  -m 256M \
  -nographic \
  -bios /opt/wg-demo/fw_jump.bin \
  \
  -device loader,file=/opt/wg-demo/Image,addr=0x80200000 \
  -device loader,file=/opt/wg-demo/initramfs-world0.cpio.gz,addr=0x84000000 \
  -dtb /opt/wg-demo/world0.dtb \
  \
  -device loader,file=/opt/wg-demo/Image,addr=0x88200000 \
  -device loader,file=/opt/wg-demo/initramfs-world1.cpio.gz,addr=0x8c000000 \
  -device loader,file=/opt/wg-demo/world1.dtb,addr=0x8e000000 \
  \
  -netdev user,id=n1,hostfwd=tcp::2323-:23 \
  -device virtio-net-device,netdev=n1 \
  \
  -serial mon:stdio
  -trace "wg_*" -D /out/wg-trace.log

# Interaction:
#   World0: this terminal (ttyS0). Ctrl-A c toggles QEMU monitor.
#   World1: from the host:  telnet localhost 2323
#           (docker run -p 2323:2323 ... to expose it)
