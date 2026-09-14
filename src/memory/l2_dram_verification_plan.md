# L2 Cache + DRAM Verification Plan

## 1. Scope

This verification plan covers both the standalone DRAM module and the L2 cache connected to DRAM.

Current L2 characteristics:

- 256 KB cache
- 64 B cache line
- 4-way set associative
- 32-bit data width
- Blocking cache
- Write-through policy
- Write-allocate policy
- Shared by L1I and L1D
- L1I performs read-only traffic
- L1D performs reads and writes
- AXI-Lite-style interface toward DRAM
- Full-line refill implemented as 16 × 32-bit reads
- LRU replacement policy
- Fixed L2 access latency
- No `WSTRB` / partial-write testing for now

Verification is split into three layers:

```text
Layer 1 — DRAM Unit Test
AXI Driver -> DRAM RTL

Layer 2 — L2 Protocol Test
L1I/L1D Drivers -> L2 -> Controllable DRAM Model

Layer 3 — Integration Test
L1I/L1D Drivers -> L2 -> Real DRAM RTL
```

This separation makes debugging much easier:

- Layer 1 verifies DRAM independently.
- Layer 2 stresses L2 and AXI corner cases.
- Layer 3 verifies the actual memory subsystem.

---

# 2. Overall Testbench Architecture

## 2.1 DRAM Standalone Testbench

```text
AXI Test Driver
      |
      v
+-----------+
|   DRAM    |
+-----------+
```

Components:

- Clock/reset generator
- AXI read driver
- AXI write driver
- Reference memory model
- Assertions
- Transaction counters

---

## 2.2 L2 Protocol Testbench

```text
L1I Driver ----\
                \
                 >---- L2 Cache ----> Controllable DRAM Model
                /
L1D Driver ----/
```

The controllable DRAM model should allow the testbench to deliberately delay:

- `ARREADY`
- `RVALID`
- `AWREADY`
- `WREADY`
- `BVALID`

This testbench is used primarily for handshake and backpressure testing.

---

## 2.3 L2 + Real DRAM Integration Testbench

```text
L1I Driver ----\
                \
                 >---- L2 Cache ----> Real DRAM RTL
                /
L1D Driver ----/
```

This testbench verifies that the actual L2 and DRAM modules operate correctly together.

---

# 3. Verification Philosophy

Each test should check:

1. Externally visible behavior.
2. Internal state when useful for debugging.
3. Number and type of DRAM transactions.
4. Correct AXI handshakes.
5. Cache/DRAM consistency.

External checks include:

- `rdata`
- read/write response timing
- AXI addresses
- AXI write data
- transaction counts
- correct request owner

Internal L2 checks may include:

```systemverilog
dut.valid_array[set][way]
dut.tag_array[set][way]
dut.data_array[set][way]
dut.lru_rank[set][way]
dut.state
dut.refill_count
dut.miss_way
```

Hierarchical internal checks are acceptable during development.

---

# 4. Layer 1 — Standalone DRAM Tests

The DRAM should pass these tests before being connected to the L2.

---

## DRAM Test 0 — Reset

### Goal

Verify correct reset state.

### Procedure

1. Assert reset.
2. Hold for multiple cycles.
3. Deassert reset.

### Expected Results

- DRAM FSM returns to idle.
- Handshake state is cleared.
- No unexpected `RVALID` or `BVALID`.
- Internal counters are reset.

---

## DRAM Test 1 — Basic Write

### Procedure

Write:

```text
Address = 0x00001000
Data    = 0xDEADBEEF
```

### Expected Results

- AW handshake completes.
- W handshake completes.
- DRAM eventually asserts `BVALID`.
- Internal memory location contains `0xDEADBEEF`.

---

## DRAM Test 2 — Basic Read

Preload memory:

```text
memory[0x1000] = 0x12345678
```

Issue a read to `0x1000`.

### Expected Results

- AR handshake completes.
- DRAM waits configured latency.
- `RVALID` is asserted.
- `RDATA == 0x12345678`.

---

## DRAM Test 3 — Write Then Read Back

### Procedure

```text
write 0x1000 = 0xDEADBEEF
read  0x1000
```

### Expected Result

```text
read data == 0xDEADBEEF
```

---

## DRAM Test 4 — Multiple Addresses

Write and read multiple addresses:

```text
0x1000
0x1004
0x1008
0x2000
0x4000
```

### Expected Results

Each location retains independent data.

---

## DRAM Test 5 — AW Arrives Before W

### Procedure

Send write address first.

Delay write data.

### Expected Results

- AW is accepted independently.
- DRAM waits for W.
- No write completes until both are received.

---

## DRAM Test 6 — W Arrives Before AW

Repeat the previous test in reverse order.

### Expected Results

- W is accepted independently.
- DRAM waits for AW.
- Transaction completes correctly once both exist.

---

## DRAM Test 7 — Delayed RREADY

### Procedure

Perform a read, but keep:

```text
RREADY = 0
```

after DRAM asserts `RVALID`.

### Expected Results

- `RVALID` remains asserted.
- `RDATA` remains stable.
- DRAM does not discard the response.

---

## DRAM Test 8 — Delayed BREADY

### Procedure

Perform a write but keep:

```text
BREADY = 0
```

after `BVALID`.

### Expected Results

- `BVALID` stays asserted.
- DRAM does not start incorrectly clearing the response before handshake.

---

## DRAM Test 9 — Consecutive Transactions

Perform multiple read/write transactions back-to-back.

### Goal

Ensure DRAM correctly returns to idle and accepts the next transaction.

---

## DRAM Definition of Done

DRAM unit testing passes when:

- Reads return correct values.
- Writes modify correct addresses.
- AW/W ordering is independent.
- Responses remain stable under backpressure.
- Latency counters behave correctly.
- No transaction is duplicated or lost.

---

# 5. Layer 2 — L2 Protocol Test with Controllable DRAM Model

These tests focus on the L2 itself and intentionally manipulate AXI timing.

---

## L2 Test 0 — Reset

### Expected Results

- `state == IDLE`
- `owner == OWNER_NONE`
- `latency_count == 0`
- `refill_count == 0`
- handshake tracking signals cleared
- every cache valid bit is `0`
- LRU state initialized deterministically

---

## L2 Test 1 — L1D Read Miss

### Procedure

1. Choose an uncached address.
2. Issue L1D read.
3. Allow lookup latency.
4. Verify entry into `READ_MISS`.
5. Service refill.

### Expected Results

Exactly 16 DRAM reads:

```text
line_base + 0
line_base + 4
line_base + 8
...
line_base + 60
```

Also verify:

- correct cache line data
- correct tag
- valid bit set
- requested word returned
- filled way becomes MRU
- FSM returns to `IDLE`

---

## L2 Test 2 — L1D Read Hit

Read the same address again.

### Expected Results

- Cache hit.
- No DRAM access.
- Correct data returned.
- LRU updated.

---

## L2 Test 3 — Different Word in Same Cache Line

Read another word in the same 64 B line.

### Expected Results

- Hit.
- No refill.
- Correct word offset selected.

---

## L2 Test 4 — L1I Read Miss

### Expected Results

- `owner == OWNER_I`
- full refill occurs
- response returns only to L1I

---

## L2 Test 5 — L1I Read Hit

### Expected Results

- no DRAM refill
- correct L1I response
- owner cleared after handshake

---

# 6. L2 Write Tests

## L2 Test 6 — Write Hit

### Setup

First load the line.

### Procedure

Write to a cached word.

### Expected Results

- cache word updated
- no refill
- `WRITE_THROUGH` entered
- correct `AWADDR`
- correct `WDATA`
- one DRAM write
- L1D receives B response
- LRU updated

---

## L2 Test 7 — AW Accepted Before W

Force:

```text
AWREADY = 1
WREADY  = 0
```

then later:

```text
WREADY = 1
```

### Expected Results

- `aw_sent == 1`
- AW is not repeated
- W remains pending
- transaction completes correctly

---

## L2 Test 8 — W Accepted Before AW

Reverse Test 7.

### Expected Results

- `w_sent == 1`
- W is not repeated
- AW remains pending
- write completes correctly

---

## L2 Test 9 — Write Miss

### Procedure

1. Write to an uncached address.
2. Verify `WRITE_MISS`.
3. Refill all 16 words.
4. Replace requested word with `writedata`.
5. Verify transition to `WRITE_THROUGH`.

### Expected Results

- 16 refill reads
- target word in L2 equals `writedata`
- other 15 words equal DRAM refill data
- correct tag/valid bit
- filled way becomes MRU
- one write-through transaction occurs
- L1D receives B response

---

## L2 Test 10 — Read After Write

After a write hit or write miss, read the same address.

### Expected Result

```text
returned value == most recent written value
```

---

# 7. Associativity and LRU Tests

## L2 Test 11 — Fill Four Ways of One Set

Generate four addresses with:

- same set index
- different tags

Example:

```text
A -> set X, tag A
B -> set X, tag B
C -> set X, tag C
D -> set X, tag D
```

### Expected Results

- all four ways become valid
- no valid line evicted early

Expected LRU order after A, B, C, D:

```text
D = MRU
C
B
A = LRU
```

---

## L2 Test 12 — LRU Hit Update

Access A again.

### Expected Results

```text
A = MRU
D
C
B = LRU
```

according to the implemented rank-update algorithm.

---

## L2 Test 13 — LRU Eviction

Access a fifth address E mapping to the same set.

### Expected Results

- current LRU way selected
- only that way replaced
- E becomes MRU

---

## L2 Test 14 — Invalid Way Preferred

Reset and partially fill one set.

Issue another miss.

### Expected Results

- invalid way selected before any valid line is evicted

---

# 8. Arbitration Tests

## L2 Test 15 — Simultaneous L1D and L1I Reads

Assert both `ARVALID`s simultaneously.

### Expected Results

- L1D gets priority
- only one request is accepted
- L1I remains pending
- L1I proceeds after L2 returns to idle

---

## L2 Test 16 — L1D Write Versus L1D Read

Present write and read requests simultaneously.

### Expected Results

- write wins according to current arbitration logic
- read waits

---

## L2 Test 17 — L1D Write Versus L1I Read

### Expected Results

- write accepted first
- instruction read waits

---

# 9. Blocking Behavior Tests

## L2 Test 18 — New Request During Read Miss

Start a read miss.

While refill is active, present another request.

### Expected Results

- new request is not accepted
- ready stays low
- original refill completes correctly

---

## L2 Test 19 — New Request During Write Miss

Repeat during:

```text
WRITE_MISS
```

and:

```text
WRITE_THROUGH
```

### Expected Results

No second transaction is accepted.

---

# 10. AXI Backpressure Tests

These should primarily use the controllable DRAM model.

---

## L2 Test 20 — Delayed ARREADY

Keep:

```text
ARREADY = 0
```

for several cycles.

### Expected Results

- `ARVALID` stays high
- `ARADDR` stays stable
- `refill_count` does not change
- no request is lost

---

## L2 Test 21 — Delayed RVALID

Accept AR but delay response.

### Expected Results

- `ar_sent == 1`
- no second read starts
- `refill_count` remains unchanged
- returned word stored exactly once

---

## L2 Test 22 — Delayed L1 RREADY

Keep L1 `RREADY = 0`.

### Expected Results

- L2 keeps `RVALID` asserted
- `RDATA` remains stable
- state remains `READ_RESP`

---

## L2 Test 23 — Delayed L1 BREADY

Keep L1D `BREADY = 0`.

### Expected Results

- `BVALID` remains asserted
- state remains `WRITE_RESP`
- write state is not prematurely cleared

---

# 11. Address Mapping Tests

## L2 Test 24 — Cache-Line Boundary

Access:

```text
line_base + 60
```

then:

```text
line_base + 64
```

### Expected Results

- first access uses final word of current line
- second belongs to next cache line

---

## L2 Test 25 — Same Set, Different Tag

Verify that addresses with the same index but different tags occupy different ways.

---

## L2 Test 26 — Different Sets

Verify addresses with different index fields do not interfere.

---

# 12. Layer 3 — L2 + Real DRAM Integration Tests

After standalone DRAM and L2 protocol tests pass, connect:

```text
L1I/L1D Drivers -> L2 -> Real DRAM RTL
```

Do not replace the DRAM with a behavioral model for these tests.

---

## Integration Test 1 — Read Miss

### Goal

Verify a complete refill using the real DRAM.

### Expected Results

- L2 generates 16 reads
- DRAM services all 16
- complete cache line is installed
- requested word returned correctly

---

## Integration Test 2 — Read Hit After Refill

Repeat the previous read.

### Expected Results

- L2 hit
- no new DRAM access

---

## Integration Test 3 — Write Hit

### Expected Results

- L2 cached word updated
- real DRAM receives write-through
- DRAM memory contains new value
- subsequent read returns new value

---

## Integration Test 4 — Write Miss

### Expected Sequence

```text
L1D write
    ↓
L2 write miss
    ↓
16 real DRAM reads
    ↓
cache line refill
    ↓
requested word replaced with writedata
    ↓
L2 write-through
    ↓
real DRAM updated
    ↓
L1D write response
```

### Checks

After completion:

```text
L2[address]   == written value
DRAM[address] == written value
```

---

## Integration Test 5 — Fill Four Ways and Evict

Use five lines mapping to one set.

### Expected Results

- first four occupy four ways
- fifth causes correct LRU replacement
- DRAM remains unchanged by read-only eviction because L2 is write-through

---

## Integration Test 6 — L1I Read Miss/Hit

Verify the instruction path using the real DRAM.

---

## Integration Test 7 — Mixed L1I/L1D Traffic

Example:

```text
L1I read A
L1D read B
L1D write C
L1I read D
L1D read C
L1I read A
```

### Expected Results

All responses match architectural memory state.

---

## Integration Test 8 — Sequential Line Access

Read across several cache lines.

### Goal

Exercise:

- DRAM reads
- refills
- hits
- index progression
- cache line boundaries

---

## Integration Test 9 — Mixed Read/Write Regression

Example:

```text
read A
read B
write A
read A
write C
read C
read B
write D
read D
```

Maintain a reference memory model.

Every read result should match the reference.

---

# 13. Cache / DRAM Consistency Checks

Because L2 is write-through:

After every completed write:

```text
L2 cached value == DRAM value == latest written value
```

when the line is present in L2.

After a write miss:

```text
target cache word = writedata
target DRAM word  = writedata
```

All non-written refill words should remain equal to DRAM.

---

# 14. Recommended Assertions

## Assertion 1 — Refill Count Range

```text
refill_count < WORDS_PER_LINE
```

---

## Assertion 2 — Response State

```text
L1D/L1I RVALID -> state == READ_RESP
L1D BVALID     -> state == WRITE_RESP
```

---

## Assertion 3 — Refill Address Alignment

```text
ARADDR[1:0] == 2'b00
```

for the current 32-bit data width.

---

## Assertion 4 — Refill Address Sequence

```text
ARADDR == line_base + refill_count * 4
```

---

## Assertion 5 — No Double Request Acceptance

L2 must never accept two new L1 requests in the same cycle.

---

## Assertion 6 — Stable AXI Request Under Backpressure

If:

```text
ARVALID == 1 && ARREADY == 0
```

then `ARADDR` must remain stable.

Similarly for:

```text
AWVALID/AWADDR
WVALID/WDATA
```

---

## Assertion 7 — Stable Response Under Backpressure

If:

```text
RVALID == 1 && RREADY == 0
```

then `RDATA` remains stable.

If:

```text
BVALID == 1 && BREADY == 0
```

then `BVALID` remains asserted.

---

## Assertion 8 — Write Response Ordering

L1D must not receive a completed write response before the DRAM write response has completed.

---

# 15. Functional Coverage

Recommended coverage points:

```text
dram_read
dram_write

l1i_read
l1d_read
l1d_write

read_hit
read_miss
write_hit
write_miss

invalid_way_replacement
lru_replacement

AW_before_W
W_before_AW

AR_backpressure
R_backpressure
AW_backpressure
W_backpressure
B_backpressure

L1_RREADY_backpressure
L1_BREADY_backpressure
```

Useful crosses:

```text
request_type x hit/miss
owner x hit/miss
replacement_type x request_type
```

---

# 16. Randomized Testing

Only begin randomized testing after all directed tests pass.

Generate random:

- L1I reads
- L1D reads
- L1D writes
- addresses
- request ordering
- DRAM ready delays
- response delays

Maintain a reference memory model.

For reads:

```text
DUT response == reference_memory[address]
```

For writes:

```text
reference_memory[address] = writedata
```

---

# 17. Recommended Development Order

## Phase 1 — DRAM Unit Testing

Implement and pass:

```text
reset
basic read
basic write
write -> read
AW before W
W before AW
RREADY backpressure
BREADY backpressure
```

Do not proceed until standalone DRAM behavior is trusted.

---

## Phase 2 — L2 Basic Testbench

Use controllable DRAM model.

Implement:

```text
L1D read miss
L1D read hit
L1I read miss
L1I read hit
write hit
write miss
```

---

## Phase 3 — L2 Replacement

Verify:

```text
4-way fill
LRU hit update
LRU eviction
invalid-way selection
```

---

## Phase 4 — AXI Stress

Use controllable DRAM model to test:

```text
ARREADY delay
RVALID delay
AWREADY delay
WREADY delay
BVALID delay
```

---

## Phase 5 — Arbitration

Verify L1I/L1D contention.

---

## Phase 6 — Real DRAM Integration

Replace the DRAM model with your actual DRAM RTL.

Repeat:

```text
read miss
read hit
write hit
write miss
read-after-write
LRU eviction
mixed traffic
```

---

## Phase 7 — Random Regression

Run randomized L1I/L1D traffic against the full:

```text
L1I/L1D -> L2 -> Real DRAM
```

memory subsystem.

---

# 18. Minimum Required Test Set

Before moving upward to L1/CPU integration, the following should pass.

## DRAM

1. Reset
2. Basic write
3. Basic read
4. Write then read
5. AW before W
6. W before AW
7. Delayed RREADY
8. Delayed BREADY
9. Consecutive transactions

## L2 with Controllable DRAM Model

10. L1D read miss
11. L1D read hit
12. Same-line different-word read
13. L1I read miss
14. L1I read hit
15. Write hit
16. AW-before-W
17. W-before-AW
18. Write miss
19. Read-after-write
20. Fill all four ways
21. LRU update
22. LRU eviction
23. Invalid-way preference
24. L1D/L1I arbitration
25. New request during active miss
26. ARREADY backpressure
27. RVALID delay
28. L1 RREADY delay
29. L1 BREADY delay

## L2 + Real DRAM

30. Read miss
31. Read hit
32. Write hit
33. Write miss
34. Read-after-write
35. Cache/DRAM consistency
36. LRU eviction
37. L1I read path
38. Mixed L1I/L1D traffic

---

# 19. Definition of Done

The memory backend can be considered ready for L1/CPU integration when:

### DRAM

- Standalone DRAM tests pass.
- Read/write latency behaves as expected.
- AW/W independence is handled correctly.
- Responses survive backpressure.
- No DRAM transaction is duplicated or lost.

### L2

- Read hits never access DRAM.
- Read misses refill exactly one 64 B line.
- All 16 refill words use correct addresses.
- Write hits update L2 and write through to DRAM.
- Write misses perform refill + allocation + write-through correctly.
- LRU selection is correct.
- Invalid ways are preferred over eviction.
- L1I/L1D arbitration is deterministic.
- Blocking behavior prevents overlapping requests.
- AXI requests remain stable under backpressure.

### L2 + Real DRAM

- Full-line refills work against the real DRAM.
- Write-through updates real DRAM.
- Cache and DRAM remain consistent.
- Read-after-write returns correct values.
- Replacement behavior works with the real backend.
- Mixed L1I/L1D traffic completes without deadlock.
- Directed integration tests pass.
- Random regression matches the reference memory model.

At that point, move upward to:

```text
CPU / LSU
    ↓
L1D / L1I
    ↓
L2
    ↓
DRAM
```

with the L2 + DRAM subsystem already independently verified.
