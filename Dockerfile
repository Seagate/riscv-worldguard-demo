# ==========================================================================
# WorldGuard RISC-V two-world Linux demo
#
#   hart 0 -> World 0 (WID 0): standard boot, OpenSBI fw_jump -> Linux,
#             console on ttyS0 (the container's stdio)
#   hart 1 -> World 1 (WID 1): brought up by patched fw_base.S, isolated
#             RAM 0x88000000-0x8fffffff, minimal DT (memory + ramdisk +
#             virtio-net only), shell via `telnet localhost 2323`
#
# Build:  docker build -t wg-demo .
# Run:    docker run -it --rm -p 2323:2323 wg-demo
# ==========================================================================

FROM ubuntu:22.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive

ARG    QEMU_REV=825a215c003cd028e26c7d19aa5049d957345f43 
ARG QEMU_BRANCH=riscv-wg-v4-alpha 
ARG OPENSBI_REV=332798211e7232da60158b0545b23c61b5338516 
ARG BUSYBOX_REV=5eee8017a827659b6fb9e29ab1241eb4227c56f7 

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ninja-build pkg-config \
    libglib2.0-dev libpixman-1-dev libfdt-dev libslirp-dev \
    python3 python3-pip python3-venv \
    flex bison bc libssl-dev libelf-dev \
    device-tree-compiler cpio unzip rsync wget ca-certificates \
    gcc-riscv64-linux-gnu g++-riscv64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/build

# --------------------------------------------------------------------------
# 1. WorldGuard-enabled QEMU
# --------------------------------------------------------------------------
RUN git clone https://github.com/cwshu/qemu/ --revision ${QEMU_REV} && \
    cd qemu && \
    git checkout ${QEMU_BRANCH} && \
    git submodule update --init --recursive

# Ubuntu 22.04 has Python 3.10, which lacks stdlib tomllib (3.11+);
# QEMU's Meson build needs the tomli fallback package.
RUN pip3 install tomli

RUN cd qemu && mkdir -p build && cd build && \
    ../configure --target-list=riscv64-softmmu --enable-slirp && \
    ninja

# --------------------------------------------------------------------------
# 2. OpenSBI with the World1 bring-up block INJECTED into fw_base.S
#
# Why injection instead of replacing fw_base.S wholesale: master's C code
# references symbols defined in master's fw_base.S (e.g. _trap_rnmi_handler
# for Smrnmi support); replacing the file with an older snapshot causes
# undefined-reference link failures. The injection anchors on the
# `call sbi_init` site, stable across OpenSBI versions, and adds only our
# self-contained block. Pin OPENSBI_REF for reproducible builds.
# --------------------------------------------------------------------------
ARG OPENSBI_REF=master
RUN git clone https://github.com/riscv-software-src/opensbi.git --revision ${OPENSBI_REV} && \
    cd opensbi && git checkout ${OPENSBI_REF}

COPY wg_world1.S.inc apply_wg_patch.py /opt/build/
RUN python3 /opt/build/apply_wg_patch.py \
        /opt/build/opensbi/firmware/fw_base.S \
        /opt/build/wg_world1.S.inc

# fw_jump: hart0 jumps to World0's kernel with World0's DTB. hart1 never
# reaches the jump -- the fw_base.S patch diverts it to World1 first.
RUN cd opensbi && \
    make CROSS_COMPILE=riscv64-linux-gnu- PLATFORM=generic \
         FW_JUMP=y \
         FW_JUMP_ADDR=0x80200000 \
         FW_JUMP_FDT_ADDR=0x87f00000 \
         -j$(nproc)

# --------------------------------------------------------------------------
# 3. Linux kernel (one Image, loaded once per world)
#    defconfig includes VIRTIO_NET/VIRTIO_MMIO and RISCV_SSTC on recent
#    kernels -- both are hard requirements for World1 (network-only
#    interaction; Sstc timers since hart1 has no SBI timer service).
# --------------------------------------------------------------------------
ARG LINUX_VERSION=6.6
RUN wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz && \
    tar xf linux-${LINUX_VERSION}.tar.xz && mv linux-${LINUX_VERSION} linux

RUN cd linux && \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig && \
    ./scripts/config -e VIRTIO_MMIO -e VIRTIO_NET -e RISCV_SSTC || true && \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig && \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) Image

# --------------------------------------------------------------------------
# 4. Busybox (static) + two initramfs images
# --------------------------------------------------------------------------
RUN git clone --depth 1 https://git.busybox.net/busybox  --revision ${BUSYBOX_REV} && \
    cd busybox && \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig && \
    sed -i 's/^# CONFIG_STATIC .*/CONFIG_STATIC=y/' .config && \
    sed -i 's/^# CONFIG_DEVMEM .*/CONFIG_DEVMEM=y/' .config && \
    grep -q '^CONFIG_DEVMEM=y' .config || echo 'CONFIG_DEVMEM=y' >> .config && \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) && \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- install

COPY init-world0 /opt/build/init-world0
COPY init-world1 /opt/build/init-world1
COPY wg-selftest.sh /opt/build/wg-selftest.sh

RUN for w in world0 world1; do \
      mkdir -p /opt/build/rootfs-$w/dev/pts /opt/build/rootfs-$w/proc \
               /opt/build/rootfs-$w/sys /opt/build/rootfs-$w/etc \
               /opt/build/rootfs-$w/var/log && \
      cp -a busybox/_install/* /opt/build/rootfs-$w/ && \
      cp /opt/build/init-$w /opt/build/rootfs-$w/init && \
      cp /opt/build/wg-selftest.sh /opt/build/rootfs-$w/bin/wg-selftest.sh && \
      chmod +x /opt/build/rootfs-$w/bin/wg-selftest.sh && \
      chmod +x /opt/build/rootfs-$w/init && \
      ( cd /opt/build/rootfs-$w && \
        find . | cpio -o -H newc | gzip -9 > /opt/build/initramfs-$w.cpio.gz ); \
    done

# --------------------------------------------------------------------------
# 5. Device trees -- patch initrd end addresses from actual file sizes,
#    then compile. (A stale/oversized initrd-end makes the kernel's
#    initramfs unpacker chew trailing garbage; exact sizes avoid that.)
# --------------------------------------------------------------------------
COPY world0.dts world1.dts /opt/build/
RUN SIZE0=$(stat -c%s /opt/build/initramfs-world0.cpio.gz) && \
    END0=$(printf '0x%x' $((0x84000000 + SIZE0))) && \
    sed -i "s/INITRD0_END/${END0}/" world0.dts && \
    SIZE1=$(stat -c%s /opt/build/initramfs-world1.cpio.gz) && \
    END1=$(printf '0x%x' $((0x8c000000 + SIZE1))) && \
    sed -i "s/INITRD1_END/${END1}/" world1.dts && \
    dtc -I dts -O dtb -o world0.dtb world0.dts && \
    dtc -I dts -O dtb -o world1.dtb world1.dts

# ==========================================================================
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 libpixman-1-0 libfdt1 libslirp0 telnet \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/wg-demo

COPY --from=builder /opt/build/qemu/build/qemu-system-riscv64 /usr/local/bin/
COPY --from=builder /opt/build/opensbi/build/platform/generic/firmware/fw_jump.bin ./
COPY --from=builder /opt/build/linux/arch/riscv/boot/Image ./
COPY --from=builder /opt/build/initramfs-world0.cpio.gz ./
COPY --from=builder /opt/build/initramfs-world1.cpio.gz ./
COPY --from=builder /opt/build/world0.dtb /opt/build/world1.dtb ./
COPY boot.sh ./
RUN chmod +x boot.sh

EXPOSE 2323
ENTRYPOINT ["/opt/wg-demo/boot.sh"]
