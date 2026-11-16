# Out-of-order backend

`ooo_core.sv` is a separate RV32IM + Zicsr backend with the project's custom
three-source MAC instruction. `core.sv` remains the in-order baseline. Both
provide the same retirement observation ports; neither requires a debugger or
testbench to infer architectural behavior from pipeline stage registers.

The default capacities are a 32-entry reorder buffer, 64 physical integer
registers, and integer/multiply/divide/memory issue queues of 8/4/2/4 entries.
Each capacity is a top-level parameter. The fetch FIFO retains four entries.
Each cycle can dispatch, issue and retire at most one instruction. Issue picks
the oldest ready instruction whose execution unit can accept work, using ROB
age relative to its head. Issue entries remain stationary until issue or squash.

Renaming reads all three source mappings before changing the destination map.
Physical zero is permanently reserved. An instruction writing architectural
zero executes without allocating a physical destination; loads and CSR accesses
still check for faults. Source readiness is captured at dispatch and woken by
the shared writeback port. The physical register array has three asynchronous
read ports and one synchronous write port.

Integer and branch results occupy a one-entry registered completion buffer.
Multiplication and MAC share a single multiplier in a three-stage elastic
pipeline. The existing 32-stage elastic divider carries ROB/physical tags.
One registered memory transaction may be outstanding. Each unit retains its
completion until accepted; writeback accepts the oldest live completion.

Memory instructions and CSR/MRET/FENCE instructions issue only at the ROB head.
Memory requests remain stable until acknowledgment. No speculative memory
accesses, store forwarding, branch checkpoints or interrupts are implemented.
Other arithmetic units continue while memory or division waits. Stores commit
only after their transaction completes.

On a misprediction, dispatch stops and younger ROB/issue entries become invalid
immediately. Older work continues to retirement. When the resolving branch
retires, its committed mapping is included in the restored rename map, the
free bitmap is rebuilt, speculative execution state is synchronously cleared,
and fetch redirects. No ROB tag or physical register can be reallocated during
recovery. Clearing every divider valid bit before restart prevents stale tagged
results from reaching a reused destination. An older misprediction can replace
a younger pending redirect; a trap at the head takes priority over either.

## Machine subset

Supported synchronous causes are instruction-address misalignment (0), illegal
instruction (2), breakpoint (3), load-address misalignment (4), store-address
misalignment (6), and machine ECALL (11). Exceptions are recorded in the ROB
and delivered only at its head. Faulting register writes and memory requests
are suppressed. With no compressed instructions, instruction alignment is four
bytes; an untaken conditional branch does not fault for its unused target.

The supported CSRs are `mstatus` (0x300), `misa` (0x301), `mie` (0x304),
`mtvec` (0x305), `mscratch` (0x340), `mepc` (0x341), `mcause` (0x342),
`mtval` (0x343), `mip` (0x344), and read-only `mvendorid`/`marchid`/`mimpid`/
`mhartid` (0xf11–0xf14). Identification values are zero. Unsupported addresses,
including counter and supervisor CSRs, and writes to read-only CSRs trap.

`misa` is fixed at 0x40001100 (RV32 I+M). Zicsr and custom MAC support are
documented here because `misa` has no corresponding standard extension bits.
Writing `misa` is a legal WARL operation that preserves the fixed value.
`mtvec` supports direct mode only; writes clear its low two bits. `mepc` also
clears its low two bits. `mstatus.MPP` is fixed to machine mode; MIE and MPIE
are writable and trap/MRET update their stack as specified. `mie` and `mip`
always read zero, so no interrupt can become enabled or pending. Other
`mstatus` fields read zero. `mcause` writes retain supported exception codes
and map other values to zero. `mscratch` and `mtval` retain all 32 bits.

CSRRS/CSRRC write suppression depends on the encoded source register being x0,
not its runtime value. Immediate variants use the encoded five-bit immediate.
CSRRW/CSRRWI always attempt a write, including when that source is zero.
An illegal instruction places its encoding in `mtval`; address misalignment
places the target/effective address there; EBREAK uses the instruction PC and
ECALL uses zero. Trap entry records the faulting PC in `mepc` and redirects
through `mtvec`; MRET serializes and redirects through `mepc`.

Instruction/data access faults cannot be detected by the existing memory
interface, which has no error response. User/supervisor modes, interrupts,
counters and other extensions are outside this machine subset. This is not a
claim of implementing every optional or mandatory CSR of a privileged profile.

Semantics were checked against the official
[machine ISA specification](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
and [Zicsr specification](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html).

## Verification

Use `python3 test/cpu/run_core.py --backend both --suite all` from the repository
root to compare program retirement, register values and stores with the
independent instruction model. The runner separates generated artifacts by
backend. `--sweep` exercises reservation-station and ROB/physical-register
capacities after correctness checks. `test/cpu/run_ooo_units.py` checks the
elastic multiplier and machine CSRs separately. The in-order directed target
and its original programs remain available.

ASIC reports use the existing 10 ns constraints and four-core Nangate45 flow.
Post-CTS timing is estimated timing, not routed signoff. Timing failures must
be reported and fixed in the implementation or flow, without adding path
exceptions to hide them.
