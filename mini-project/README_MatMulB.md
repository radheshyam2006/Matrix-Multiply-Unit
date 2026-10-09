# Design B: K-Serial MatMul

This file explains the implementation in `MatMulB.bsv` as it actually exists in this repository.

## What Design B does

Design B keeps one copy of A, one copy of B, and one accumulator C inside the unit. The key change from the baseline is that `Mul` is no longer one combinational sweep. Instead, it is split across four cycles, and each cycle adds exactly one K-slice contribution:

$$
C[i][j] \leftarrow C[i][j] + A[i][k] \times B[k][j]
$$

for one fixed `k` per cycle.

That means Design B uses the same 4x4 mathematical interface, but it pays for the multiply in time instead of in a large combinational block.

## State and structure

The important state in `MatMulB.bsv` is:

- `rg_a`: the current 4x4 A matrix.
- `rg_b`: the current 4x4 B matrix.
- `rg_c`: the accumulator matrix.
- `rg_busy`: whether a multi-cycle `Mul` is still in progress.
- `rg_step`: which K contribution is being computed next.
- `f_req`: the request FIFO.
- `f_rsp`: the response FIFO.

The split between `rg_busy` and `rg_step` is what turns a one-cycle multiply into a four-cycle multiply. `rg_busy` tells the rules whether a multiply is active. `rg_step` remembers which of the four K positions is next.

## Lifecycle of a Mul request

The request stream enters `f_req`. The request-processing rules look at the head of that FIFO and only act when the current state allows it.

1. A `Mul` request reaches the head of `f_req`.
2. `rl_mul_start` fires when the unit is not already busy.
3. The rule computes the first outer-product contribution immediately and writes the result into `rg_c`.
4. It sets `rg_busy` and initializes `rg_step` to 1.
5. The helper rule `rl_mul_step` then fires once per cycle while `rg_busy` is true.
6. Each firing adds the next K contribution, updates `rg_c`, and advances `rg_step`.
7. After the fourth contribution, the rule clears `rg_busy` and resets `rg_step`.

This is a real multi-cycle machine, not just a delayed response. The accumulator is updated incrementally, one K-slice at a time, so the state visible to later requests stays sequentially correct.

## Signed math and accumulation

The code uses `signExtend` before multiplying each Int8 element pair. That matters because the operands are signed 8-bit values, but the multiply and sum must behave like signed arithmetic inside a wider accumulator.

The accumulator is `Int#(32)`, so each partial product is added into a 32-bit signed running sum. The project workloads are designed so this width is sufficient; no overflow occurs in the expected cases.

The helper function `f_step` is the key arithmetic block. It computes one K-slice contribution for all 16 output elements at once, so Design B uses 16 multipliers per active cycle instead of 64 multipliers in one giant combinational path.

## Request and response handling

The request FIFO preserves program order. The rules consume requests in that same order:

- `rl_load_a` writes one row of A.
- `rl_load_b` writes one row of B.
- `rl_mul_start` starts the 4-cycle multiply.
- `rl_read_c` reads one accumulator element and zeros it.

The response FIFO mirrors the request stream. Every request enqueues exactly one response:

- `LoadA`, `LoadB`, and `Mul` enqueue `mm_rsp_none`.
- `ReadC` enqueues `mm_rsp_value` with the read element.

This preserves the locked-step request/response contract required by the harness.

## Why the guards matter

The guards in `MatMulB.bsv` are what prevent observable overlap from breaking correctness.

- `rl_mul_step` only runs while `rg_busy` is true.
- The load rules only run when the head of the request FIFO is the matching request and the multiply is not occupying the machine.
- `rl_read_c` also waits for the multiply to finish.

That means A and B cannot be modified while a `Mul` is reading them. If a later load were allowed to slip through early, it could corrupt the operands seen by the active multiply and break the sequential-reference behavior.

## Why the design is correct

The design is correct because it behaves like a sequential machine that processes each request in order:

- Loads update exactly one row.
- `Mul` accumulates on top of the current C.
- `ReadC` returns the current value and clears only the slice that was read.
- No request can overtake an older request in a way that changes the returned values.

The request FIFO preserves ordering; the busy flag preserves atomicity of the multi-cycle multiply.

## Measured results

These numbers are from the actual run of `MatMulB.bsv` in this workspace.

| metric | value |
|---|---:|
| W1 cycles | 53249 |
| W2 cycles | 397313 |
| W1 stalls | 12289 |
| W2 stalls | 98305 |
| cells | 62153 |
| logic depth | 56 |

The cycle counts match the expected K-serial behavior: compared with the baseline, every K-step now costs extra cycles because the multiply is stretched over four cycles.

## Cycle-cost intuition

For this workload shape, Design B behaves like this per output tile:

- Each K-tile costs 8 load requests plus 4 multiply cycles.
- There are 16 reads at the end of the output tile.

So the output-tile cost is:

$$
16 \times (8 + 4) + 16 = 208
$$

for W1, where there are 16 K-tiles per output tile, and

$$
128 \times (8 + 4) + 16 = 1552
$$

for W2.

That explains why W2 is much more expensive in absolute cycles: the extra K work is paid in full.

## Why the depth dropped

The cell and depth numbers are both lower than the combinational baseline because Design B removes the huge one-cycle K chain. The arithmetic is still real, but the longest combinational path is much shorter because the sum over K is no longer one large expression.

## Code map

The most important blocks to read in `MatMulB.bsv` are:

- `f_step`: the one-K-slice arithmetic.
- `rl_mul_step`: the multi-cycle accumulator update.
- `rl_load_a` / `rl_load_b`: operand loading.
- `rl_mul_start`: the start of a new multiply.
- `rl_read_c`: destructive readout.
- `f_req` / `f_rsp`: request-order and response-order buffering.
