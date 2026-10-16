	/*
	 * ------------------------------------------------------------
	 * World1 (WID 1) hardware setup -- hart 1 only.
	 *
	 * ARCHITECTURE (v2): hart 1 no longer skips sbi_init() and mrets
	 * into Linux directly. That approach died by a thousand cuts: it
	 * required hand-reimplementing delegation, PMP, and Sstc enable,
	 * and finally hit unfixable ground when World1 Linux's first SBI
	 * ecall made OpenSBI dereference hart1's never-initialized per-hart
	 * scratch data (M-mode load fault at ~NULL, mcause=5 mtval=0x20).
	 *
	 * Instead, hart 1 now: programs the wgChecker, sets its WID CSRs,
	 * then falls through to the NORMAL sbi_init() path. An OpenSBI
	 * domain (declared in world0.dts under /chosen/opensbi-domains)
	 * assigns hart 1 next-addr=0x88200000 next-arg1=0x8e000000
	 * next-mode=S, so OpenSBI itself launches World1 Linux with fully
	 * functional SBI runtime services. This block now contains ONLY
	 * what OpenSBI cannot do: WorldGuard hardware programming.
	 * ------------------------------------------------------------
	 */
	csrr	t0, CSR_MHARTID
	li	t1, 1
	bne	t0, t1, _normal_sbi_init

	/*
	 * ------------------------------------------------------------
	 * Program the DRAM wgChecker.
	 * Verified against the fork (hw/riscv/virt.c):
	 *   VIRT_WGC_DRAM = 0x6000000 (0x6001000=flash, 0x6002000=uart),
	 *   16 slots. Machine DTB: nworlds=4, trustedwid=3 -- M-mode runs
	 *   as WID 3 (trusted) on every hart, which is what authorizes
	 *   these config writes and keeps M-mode immune to slot perms.
	 *
	 * Slot layout (per original demo notes; slot regs at base+0x20,
	 * stride 0x20: addr/perm/cfg at +0x00/+0x08/+0x10):
	 *   slot1 TOR 0x80000000-0x87ffffff perm 0x03 (WID0 RW) = World0
	 *   slot2 TOR 0x88000000-0x8fffffff perm 0x0C (WID1 RW) = World1
	 * ------------------------------------------------------------
	 */
        li      t5, 0x06000000          /* DRAM wgChecker base */

        /*
         * slot0.addr = 0x80000000 >> 2
         *
         * slot0 is the lower bound for the first TOR region.
         * Do not depend on slot0.A; QEMU masks A for slot0.
         */
        li      t0, 0x80000000
        srli    t0, t0, 2
        sd      t0, 0x020(t5)           /* slot0.addr */

        /*
         * slot1:
         *   TOR range = slot0.addr .. slot1.addr
         *             = 0x80000000 .. 0x87ffffff
         *   perm      = WID0 RW only
         *   cfg       = A_TOR
         */
        li      t0, 0x88000000
        srli    t0, t0, 2
        sd      t0, 0x040(t5)           /* slot1.addr */

        li      t0, 0x3                 /* WID0 RW */
        sd      t0, 0x048(t5)           /* slot1.perm */

        li      t0, 0x1                 /* A_TOR */
        sw      t0, 0x050(t5)           /* slot1.cfg */

        /*
         * slot2:
         *   TOR range = slot1.addr .. slot2.addr
         *             = 0x88000000 .. 0x8fffffff
         *   perm      = WID1 RW only
         *   cfg       = A_TOR
         */
        li      t0, 0x90000000
        srli    t0, t0, 2
        sd      t0, 0x060(t5)           /* slot2.addr */

        li      t0, 0xC                 /* WID1 RW */
        sd      t0, 0x068(t5)           /* slot2.perm */

        li      t0, 0x1                 /* A_TOR */
        sw      t0, 0x070(t5)           /* slot2.cfg */

        /*
         * Ensure wgChecker MMIO writes are visible before we enter World1.
         */
        fence   iorw, iorw

	/*
	 * WID assignment (CSR numbers verified in fork's cpu_bits.h):
	 *   MWIDDELEG=0x748, MLWID=0x390, SLWID=0x190.
	 * mlwid=1 makes all <M-mode execution on this hart WID 1: OpenSBI
	 * (M-mode, fixed WID 3) continues sbi_init() unaffected, and when
	 * it launches the domain's next stage in S-mode, World1 Linux runs
	 * as WID 1 from its first instruction.
	 */
	li	t0, 2			/* bit 1: delegate WID1 */
	csrw	0x748, t0		/* MWIDDELEG */
	li	t0, 1
	csrw	0x390, t0		/* MLWID = 1 */
	csrw	0x190, t0		/* SLWID = 1 */

_normal_sbi_init:
