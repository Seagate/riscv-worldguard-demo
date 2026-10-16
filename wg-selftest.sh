#!/bin/sh
# WorldGuard isolation self-test.
#
# Usage: wg-selftest.sh <own_world>
#   own_world = 0  -> we are World0 (trusted, WID3): reading World1 RAM
#                     is EXPECTED TO SUCCEED (trusted world bypasses
#                     checker perms). Reading our own RAM also succeeds.
#   own_world = 1  -> we are World1 (WID1): reading World0 RAM is
#                     EXPECTED TO FAIL (checker slot1 = WID0 only, and
#                     our PMP doesn't cover it either). Reading our own
#                     RAM succeeds.
#
# A cross-world read that is blocked usually delivers SIGBUS/SIGSEGV to
# the reader, so each probe runs in a subshell whose DEATH is the signal.
# We can't capture the (never-produced) value, so we distinguish
# pass/fail purely by whether the probe process survived.

OWN="$1"
OWN0_ADDR=0x80200000     # somewhere inside World0 RAM (kernel image)
OWN1_ADDR=0x88200000     # somewhere inside World1 RAM (kernel image)

# probe ADDR  -> prints value and returns 0 if the read completed,
#                returns non-zero if the reading subshell was killed.
probe() {
	# Run devmem in a child shell; its stdout is the value on success.
	# If the access faults, the child dies and $? reflects the signal.
	val=$( devmem "$1" 2>/dev/null )
	rc=$?
	if [ $rc -eq 0 ] && [ -n "$val" ]; then
		echo "$val"
		return 0
	fi
	return 1
}

echo ""
echo "---------- WorldGuard isolation self-test ----------"

if [ "$OWN" = "0" ]; then
	if v=$(probe "$OWN0_ADDR"); then
		echo "  [ ok ] World0 can read its own RAM ($OWN0_ADDR = $v)"
	else
		echo "  [WARN] World0 could NOT read its own RAM -- unexpected"
	fi
	if v=$(probe "$OWN1_ADDR"); then
		echo "  [ ok ] World0 (trusted WID3) can read World1 RAM"
		echo "         ($OWN1_ADDR = $v) -- expected: trusted world"
		echo "         bypasses checker perms."
	else
		echo "  [note] World0 could not read World1 RAM. Not a failure"
		echo "         of the demo, but unexpected for a trusted world;"
		echo "         check mwid/mlwid == trustedwid (3)."
	fi
	echo ""
	echo "  The meaningful isolation test runs from World1:"
	echo "    telnet localhost 2323   ->   it self-tests on boot"
else
	if v=$(probe "$OWN1_ADDR"); then
		echo "  [ ok ] World1 can read its own RAM ($OWN1_ADDR = $v)"
	else
		echo "  [WARN] World1 could NOT read its own RAM -- unexpected"
	fi
	if probe "$OWN0_ADDR" >/dev/null 2>&1; then
		echo "  [FAIL] World1 (WID1) READ World0 RAM at $OWN0_ADDR --"
		echo "         ISOLATION BREACH. Expected the access to be"
		echo "         denied by the DRAM wgChecker / PMP."
	else
		echo "  [ ok ] World1 (WID1) BLOCKED from World0 RAM at"
		echo "         $OWN0_ADDR -- isolation holds. (Access faulted,"
		echo "         as intended: checker slot1 grants WID0 only, and"
		echo "         World1's PMP does not cover this region.)"
	fi
fi
echo "----------------------------------------------------"
echo ""
