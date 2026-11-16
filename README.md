# WorldGuard Demo

**Two isolated Linux instances, each in its own "world", on one RISC-V processor.**

This project is a self-contained demo of the RISC-V **WorldGuard** extension. It boots a
dual-hart RISC-V machine in QEMU and runs a separate Linux kernel on each hart. Each kernel
runs in its own world. The hardware keeps the worlds apart:

| | World 0 | World 1 |
|---|---|---|
| **Hart** | hart 0 | hart 1 |
| **Role** | Trusted, unrestricted | Restricted, isolated |
| **RAM** | `0x80000000 – 0x87ffffff` (128 MB) | `0x88000000 – 0x8fffffff` (128 MB) |
| **Devices** | Standard `virt` platform (UART, CLINT, PLIC, …) | Memory, ramdisk, and virtio-net only |
| **Console** | Serial `ttyS0`, in the terminal running the container | None. Reached over the network with `telnet localhost 2323` |
| **Can access the other world?** | Yes (trusted world) | No. Access to World 0 RAM is blocked |

Both worlds use the same kernel image. Each world has its own initramfs, which holds a userland
built from one statically linked [BusyBox](https://busybox.net/) binary. Every utility is a
symlink to that binary.

Everything is built and run inside Docker, so a single command builds the whole demo on almost
any host.

---

## Table of Contents

- [Quick Start](#quick-start)
- [What You'll See](#what-youll-see)
- [Upstream Sources](#upstream-sources)
- [How It Works](#how-it-works)
  - [Boot Flow](#boot-flow)
  - [Memory Map](#memory-map)
  - [QEMU Configuration](#qemu-configuration)
- [Build Process](#build-process)
- [Repository Layout](#repository-layout)
- [Authors and Acknowledgment](#authors-and-acknowledgment)
- [License](#license)
- [Releases](#releases)

---

## Quick Start

**Prerequisites:** Docker. The build compiles QEMU, OpenSBI, Linux, and BusyBox from source,
so the first build takes a while.

```sh
# Build the image (tagged wg-demo)
sh buildit.sh        # same as: docker build -t wg-demo .

# Run the demo (World 0 console appears in this terminal)
sh runit.sh          # same as: docker run -it --rm -p 2323:2323 wg-demo
```

Then, in a **second terminal** on the host, connect to World 1:

```sh
telnet localhost 2323
```

| Key | Action |
|---|---|
| `Ctrl-A c` | Switch the World 0 terminal between the Linux console and the QEMU monitor |
| `Ctrl-A x` | Quit QEMU (this also stops the container) |

---

## What You'll See

Each world runs `wg-selftest.sh` at boot. The script uses `devmem` to read one address in its
own RAM and one in the other world's RAM:

- **World 0** prints its results on the console. It can read its own RAM *and* World 1's RAM.
  This is expected, because World 0 is the trusted world.
- **World 1** runs the test once at boot and saves the output to `/var/log/wg-selftest.txt`.
  Every telnet login prints that saved result before giving you a shell. World 1 can read
  its own RAM, but its read of World 0 RAM **faults**. That fault shows the isolation is
  working.

Example result from World 1:

```
---------- WorldGuard isolation self-test ----------
  [ ok ] World1 can read its own RAM (0x88200000 = ...)
  [ ok ] World1 (WID1) BLOCKED from World0 RAM at
         0x80200000 -- isolation holds.
----------------------------------------------------
```

You can run the test again from either shell with `/bin/wg-selftest.sh 0` (World 0) or
`/bin/wg-selftest.sh 1` (World 1).

---

## Upstream Sources

Every component is fetched from its upstream source during the Docker build. None of them is
stored in this repository.

| Component | Source | Version / Branch | Notes |
|---|---|---|---|
| **QEMU** (WorldGuard fork) | <https://github.com/cwshu/qemu> | branch `riscv-wg-v4-alpha` | Jim Shu's repository (SiFive). It adds WorldGuard support to QEMU's RISC-V `virt` machine. Submodules are initialized recursively. Built with target list `riscv64-softmmu`. |
| **OpenSBI** | <https://github.com/riscv-software-src/opensbi.git> | `master` (change with `--build-arg OPENSBI_REF=<ref>`) | The RISC-V Supervisor Binary Interface firmware. Patched at build time with `apply_wg_patch.py`. |
| **Linux kernel** | <https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz> | `6.6` (change with `--build-arg LINUX_VERSION=<ver>`) | Official kernel.org release tarball, downloaded with `wget` |
| **BusyBox** | <https://git.busybox.net/busybox> | latest (`--depth 1` clone) | Provides the whole userland for both worlds |
| **Base image** | `ubuntu:22.04` (Docker Hub) | 22.04 | Used for both the builder and the runtime stages |
| **Cross toolchain** | Ubuntu packages `gcc-riscv64-linux-gnu`, `g++-riscv64-linux-gnu` | Ubuntu 22.04 package versions | `CROSS_COMPILE=riscv64-linux-gnu-` for OpenSBI, Linux, and BusyBox |

> **Reproducibility:** OpenSBI tracks `master`, and BusyBox uses the latest commit. Their
> upstream code can change from one build to the next. For a repeatable build, pin OpenSBI
> with `OPENSBI_REF`. For BusyBox, use a tag.

---

## How It Works

### Boot Flow

1. QEMU starts a `virt` machine with WorldGuard turned on (`worlds=on`) and two harts.
2. Both harts start in a patched **OpenSBI** (`fw_jump.bin`). M-mode runs as the trusted
   world ID (WID 3) on every hart.
3. **Hart 1** runs the injected World 1 block from `wg_world1.S.inc` before `sbi_init`:
   - It programs the DRAM **wgChecker** at `0x06000000`:
     - slot 1: `0x80000000–0x87ffffff`, WID 0 read/write only (World 0)
     - slot 2: `0x88000000–0x8fffffff`, WID 1 read/write only (World 1)
   - It sets the WID CSRs (`MWIDDELEG`, `MLWID = 1`, `SLWID = 1`), so everything hart 1
     runs below M-mode has WID 1.
   - It then continues into the normal `sbi_init()` path.
4. OpenSBI reads the **domain** defined in `world0.dts` (`/chosen/opensbi-domains`). That
   domain starts World 1 Linux on hart 1 in S-mode at `0x88200000`, with its DTB at
   `0x8e000000`. Because OpenSBI starts World 1, World 1 gets full SBI runtime services.
5. **Hart 0** follows the standard `fw_jump` path to World 0 Linux at `0x80200000`.
   `maxcpus=1` in World 0's bootargs stops World 0 from trying to bring hart 1 online.

### Memory Map

256 MB of RAM total:

| Address | World | Contents |
|---|---|---|
| `0x80000000` | 0 | OpenSBI (`fw_jump.bin`) |
| `0x80200000` | 0 | Linux `Image` |
| `0x84000000` | 0 | `initramfs-world0.cpio.gz` |
| `0x87f00000` | 0 | World 0 DTB (moved here by `fw_jump`) |
| `0x88200000` | 1 | Linux `Image` (same image as World 0) |
| `0x8c000000` | 1 | `initramfs-world1.cpio.gz` |
| `0x8e000000` | 1 | World 1 DTB |

### QEMU Configuration

The full command line is in [`boot.sh`](boot.sh), which is the container's entrypoint. Key
options:

| Option | Purpose |
|---|---|
| `-M virt,worlds=on` | Turns on the WorldGuard hardware. **Required:** without it, hart 1's first wgChecker write faults and hart 1 hangs in OpenSBI. |
| `-smp 2 -m 256M` | Two harts, 256 MB RAM |
| `-bios fw_jump.bin` | Patched OpenSBI firmware |
| `-device loader,...` | Loads both copies of the kernel (`/opt/wg-demo/Image`), both initramfs images, and the World 1 DTB at fixed addresses |
| `-dtb world0.dtb` | World 0's device tree. It is passed with `-dtb`, not with a loader, so that `fw_jump`'s relocation to `0x87f00000` doesn't overwrite it. |
| `-netdev user,hostfwd=tcp::2323-:23` + `-device virtio-net-device` | Network for World 1. Host port 2323 forwards to World 1's `telnetd`. |
| `-serial mon:stdio` | Connects World 0's console and the QEMU monitor to the terminal |
| `-trace "wg_*" -D /tmp/wg-trace.log` | Writes WorldGuard trace events to `/tmp/wg-trace.log` |

Inside World 1, QEMU user-mode networking gives these addresses: guest `10.0.2.15`, gateway
`10.0.2.2`.

---

## Build Process

The [`Dockerfile`](Dockerfile) is a two-stage build. Both stages use **Ubuntu 22.04**. The
sources for each component are listed under [Upstream Sources](#upstream-sources).

### Stage 1: `builder`

All build packages are installed first, including the `riscv64-linux-gnu-` cross toolchain,
`device-tree-compiler`, and `cpio`.

1. **QEMU:** clones the `cwshu/qemu` fork and checks out `riscv-wg-v4-alpha`. Installs
   `tomli`, because Ubuntu 22.04's Python 3.10 lacks `tomllib` and QEMU's Meson build needs
   it. Builds `qemu-system-riscv64` for `riscv64-softmmu` with slirp networking enabled.
2. **OpenSBI:** clones upstream OpenSBI. `apply_wg_patch.py` inserts `wg_world1.S.inc` into
   `firmware/fw_base.S`, right before `call sbi_init`. Then builds `fw_jump.bin` for
   `PLATFORM=generic`, with `FW_JUMP_ADDR=0x80200000` and `FW_JUMP_FDT_ADDR=0x87f00000`.
3. **Linux:** downloads and unpacks the kernel.org 6.6 tarball. Cross-compiles `Image` from
   `defconfig` with `VIRTIO_MMIO`, `VIRTIO_NET`, and `RISCV_SSTC` turned on. World 1 needs
   virtio-net for its network-only console and Sstc for its timers.
4. **BusyBox:** clones BusyBox. Cross-compiles it as a static binary with `devmem` turned on,
   because the self-test uses `devmem`.
5. **initramfs:** builds one rootfs per world. Each one contains BusyBox, that world's
   `init-worldN` script as `/init`, and `/bin/wg-selftest.sh`. Each rootfs is packed with
   `cpio` (newc format) and `gzip`.
6. **Device trees:** fills in the initrd end addresses in `world0.dts` and `world1.dts` from
   the actual initramfs file sizes. Then compiles both with `dtc`.

> **Why inject instead of replacing `fw_base.S`?** Upstream OpenSBI's C code refers to
> symbols defined in its own `fw_base.S` (for example `_trap_rnmi_handler`). Replacing the
> whole file with an older copy causes link errors. The `call sbi_init` anchor has stayed
> the same across OpenSBI versions.

### Stage 2: runtime

A minimal Ubuntu 22.04 image with only the runtime libraries QEMU needs, plus `telnet`. It
copies these from the builder into `/opt/wg-demo`:

- `qemu-system-riscv64` (copied to `/usr/local/bin`)
- `fw_jump.bin`
- the Linux `Image`
- both initramfs images
- both DTBs
- `boot.sh`, which is the entrypoint

Port **2323** is exposed for the World 1 console.

---

## Repository Layout

| File | Description |
|---|---|
| `Dockerfile` | Two-stage build of the complete demo |
| `buildit.sh` | Builds the `wg-demo` image |
| `runit.sh` | Runs the `wg-demo` container with port 2323 published |
| `boot.sh` | Container entrypoint that starts QEMU with both worlds |
| `wg_world1.S.inc` | Hart 1 assembly that programs the wgChecker and sets the WID CSRs |
| `apply_wg_patch.py` | Inserts `wg_world1.S.inc` into OpenSBI's `fw_base.S` |
| `world0.dts` | World 0 device tree, including the OpenSBI domain that starts World 1 |
| `world1.dts` | Minimal World 1 device tree (memory, ramdisk, virtio-net) |
| `init-world0` | World 0 `/init`: mounts filesystems, runs the self-test, opens a shell |
| `init-world1` | World 1 `/init`: sets up networking, runs the self-test, runs `telnetd` |
| `wg-selftest.sh` | Cross-world memory access self-test |
| `fw_base.S` | Reference copy of OpenSBI's `fw_base.S` (not used by the build) |
| `wg-reference.dts`, `wg.dtb` | Reference device tree for the WorldGuard `virt` machine (not used by the build) |

---

## Authors and Acknowledgment

Created by **Paul Heath** of the Seagate Security Research group. Several AI models provided
examples and helped with parts of the code.



The WorldGuard-enabled QEMU used here is the
[`riscv-wg-v4-alpha`](https://github.com/cwshu/qemu/tree/riscv-wg-v4-alpha) branch from
**Jim Shu** (SiFive).

---

## License

This project is released under the Gnu Public License v 2.0. 

## Releases

| Version | Notes |
|---|---|
| **1.01** | Added `wg-selftest.sh`, which runs in both worlds and checks cross-world memory access. World 0 (trusted, unrestricted) can see both address spaces. World 1 (restricted) can see its own memory but not World 0's. |
| **1.00** | Initial release. The container builds and runs, and the system boots. |
