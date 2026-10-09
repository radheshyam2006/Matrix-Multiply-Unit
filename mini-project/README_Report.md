# Mini-Project Technical Study Report

This is a study guide and analysis scaffold for the matrix-multiply mini-project. It is not written as a final submission; it is organized to help defend the design choices orally and to separate measured facts from predictions.

## 1. Objective and interface

The unit computes:

$$
C[4][4] \mathrel{+}= A[4][4] \times B[4][4]
$$

with signed 8-bit elements in A and B and signed 32-bit accumulation in C.

The interface is intentionally narrow:

- one 32-bit word per request,
- one 32-bit word per response,
- request/response streams stay in order,
- `ReadC` is destructive.

That narrow interface is the reason the design problem is interesting: the compute core is small, but the data movement and sequencing constraints are the real trade-off.

## 2. The three architectures

### Design A: combinational reference

Design A does the whole 4x4x4 product in one rule firing. It is the reference behavior and the simplest correct design.

### Design B: K-serial

Design B computes one K contribution per cycle. It uses one copy each of A, B, and C, plus a busy flag and a K-step counter.

### Design C: K-serial with double buffering

Design C keeps the same K-serial compute core as B, but adds a second bank of A and B so loads for the next tile can overlap with the current multiply.

## 3. BSV concepts that matter here

### Functions

`f_all` in the baseline and `f_step` in B/C are pure combinational helpers. They make the arithmetic structure obvious and keep the rules small.

### Rules and guards

Rules express multi-cycle behavior. Their guards are what keep the machine sequentially correct.

The essential idea is:

- a rule fires only when the relevant request is at the head of the request FIFO,
- `Mul`-related rules are additionally blocked while the multiply is busy,
- B and C use the same request/response contract but different storage behavior.

### Registers

Registers store the matrices, the accumulator, the busy flag, the K step, and in C the load-bank selector.

### FIFOs

The request FIFO preserves input order. The response FIFO preserves the output contract. Even when a design overlaps work internally, the visible request/response streams must stay in lockstep.

## 4. Sequential-reference correctness

The correctness condition is: the unit must behave like a sequential machine that handles requests one at a time in order.

That means:

- loads cannot leak into a multiply that started earlier,
- a multiply must add onto the current accumulator state, not overwrite it,
- reads must return the current value and then zero only that slice,
- responses must come back in request order.

For B, sequential correctness comes from stopping all later requests until the multiply has finished.

For C, correctness comes from making the later loads go to a different bank so they do not affect the active multiply.

## 5. Cycle-cost predictions

Let K be the number of K-tiles per output tile and let the 4-cycle multiply be the unit of serialized work in B/C.

### Design A

A has no multi-cycle multiply. One output tile costs:

$$
9K + 16
$$

cycles, where 9K is the load-and-multiply request stream and 16 is the readout.

### Design B

B stretches every K contribution over 4 cycles, so one output tile costs:

$$
12K + 16
$$

cycles.

### Design C

C overlaps the 8 load requests of the next tile with the 4-cycle multiply of the current tile. The measured form is:

$$
9K + 3
$$

cycles per output tile.

That is the key payoff from double buffering.

## 6. Measured results

The actual measurements obtained in this workspace are:

| design | W1 cycles | W2 cycles | W1 stalls | W2 stalls | cells | logic depth |
|---|---:|---:|---:|---:|---:|---:|
| A | 40961 | 299009 | 1 | 1 | 113160 | 71 |
| B | 53249 | 397313 | 12289 | 98305 | 62153 | 56 |
| C | 41729 | 299777 | 769 | 769 | 64129 | 58 |

### Derived rankings

- Lowest cycles: A on raw cycle count, but it is the wrong comparison because it has the largest depth and area.
- Lowest area: B.
- Lowest depth: B.
- Best cycle-depth product: C is much better than B, and A is dominated by both in depth and area.

## 7. Interpreting W1 versus W2

W1 has 16 K-tiles per output tile. W2 has 128 K-tiles per output tile.

That means:

- W2 contains a much deeper accumulation chain between reads,
- W2 is more sensitive to any design choice that serializes the K loop,
- W1 gives the readout more relative weight than W2 does.

The measured stall counts reflect that difference: Design B pays heavily because every extra K step is exposed; Design C hides most of the load traffic and therefore stays close to the request count.

## 8. Critical-path analysis

The central lesson is that fewer multipliers does not automatically mean a shorter critical path.

- Design A has 64 multipliers, but the critical path is dominated by the long combinational K-sum.
- Design B reduces the multiplier count and shortens the combinational path dramatically.
- Design C adds a little muxing and bank selection, so it is slightly deeper than B even though the core multiply is the same.

So the ranking by multiplier count, cell count, and logic depth do not line up perfectly.

## 9. Scheduling and rule conflicts

The schedule command completed, but this environment did not expose a readable `.sched` file in the mini-project build directory. The source-level lesson is still clear:

- B and C rely on `rg_busy` to separate the active multiply from request processing.
- C also relies on the bank selector to keep the active and loading banks disjoint.
- When a rule or guard is wrong, the likely symptom is that a request that should have overlapped gets serialized instead.

If the schedule report is available in another environment, the things to inspect first are the overlap between the request-processing rules and the multiply-step rule, and whether the banked loads are being recognized as disjoint from the compute bank.

## 10. Accumulator width reasoning

Each product term is the product of two signed 8-bit values, so a single term fits comfortably in 16 bits, but the sum of many terms needs extra headroom.

A safe bound for a signed accumulator is:

$$
W_{ACC} \ge W_{ELEM} + \lceil \log_2(K) \rceil + 1
$$

where the final `+1` is the sign bit.

For the project values, `W_ELEM = 8` and `K = 4`, so the bound is safely below 32 bits. That is why the provided 32-bit accumulator has plenty of margin.

If `W_ACC = 16`, the safe number of K-steps depends on the operand range, but the takeaway is that 16 bits is enough only for a relatively small number of accumulate steps. The spec’s wider accumulator is there so readout can be amortized across many multiplies.

## 11. DMA appendix questions

The appendix asks when a DMA-fed 4x4x4 unit stops being instruction-bound.

The useful facts are:

- a 4x4x4 tile reads 16 bytes of A and 16 bytes of B,
- it performs 64 MACs,
- so it does 2 MACs per byte.

At 1 GHz and 64 MACs per cycle, feeding one tile requires about 32 GB/s of bandwidth.

The OS-side guarantees that DMA requires, but the register-file interface does not, are:

- cache coherence,
- address translation support,
- page pinning or equivalent lifetime guarantees,
- asynchronous completion handling.

That is the right way to explain why the narrow request interface is simple but bandwidth-limited, while DMA is faster but much more demanding.

## 12. Numbered-question checklist

Use this as the final cross-check before writing the submission report.

1. Did the predicted cycle formulas match the measured W1/W2 numbers?
2. Where did the extra stalls come from in each design?
3. Why is MACs-per-request the same for all three designs?
4. What dominates the critical path in the combinational design?
5. What has to happen when LoadA arrives during a multi-cycle Mul in B and C?
6. Why does W2 change the cost profile relative to W1?
7. How much accumulator width is needed, and why is 32 bits safe here?
8. At what tile size does a DMA-fed design become bandwidth-bound?
9. What OS guarantees does DMA require that the register-file interface does not?
10. What did the scheduler report, and which rules are sensitive to the busy/bank split?

## 13. What remains to decide in the final writeup

The final report can choose any of the three designs, but the choice should be argued against the alternative priorities:

- raw cycle count,
- area,
- logic depth,
- the combined product of area and depth,
- the combined product of cycles and depth.

The actual measurement table above is enough to support that argument without inventing any additional data.
