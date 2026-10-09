# Design C: K-Serial MatMul with Double Buffering

This file explains only the changes in `MatMulC.bsv` relative to Design B.

## What changes from B

Design C keeps the same 4-cycle K-serial multiply core as Design B, but it adds two banks of A and two banks of B. One bank is the compute bank for the active `Mul`. The other bank is the load bank for the next tile.

That is the whole point of Design C: loads can overlap with multiplication instead of waiting for the current multiply to finish.

## What is inherited from B

Design C reuses the same ideas from Design B:

- `f_step` still computes one K contribution for all 16 outputs.
- `rg_busy` still tracks whether a multiply is active.
- `rg_step` still tracks which of the four K positions is next.
- `f_req` and `f_rsp` still preserve request/response ordering.
- `rl_mul_step` still advances the active multiply across four cycles.

So C is not a new arithmetic design. It is the same K-serial engine with better buffering around it.

## New state

The extra state in `MatMulC.bsv` is:

- `rg_a`: two copies of A.
- `rg_b`: two copies of B.
- `rg_load_bank`: which bank is currently receiving loads.

The active compute bank is always the opposite bank.

This is the mechanism that lets the next tile be loaded while the current tile is still multiplying.

## Bank-switch protocol

The bank-switch rule is simple:

1. Before a `Mul`, the current load bank contains the tile that is about to be computed.
2. When `rl_mul_start` accepts the `Mul`, it latches that bank as the compute bank.
3. The rule flips `rg_load_bank` to the other bank immediately.
4. Loads after that point go into the now-inactive bank.
5. `rl_mul_step` reads only from the compute bank, so the current multiplication sees a frozen copy of A and B.

This is what prevents stale-data and mixed-tile bugs.

If the bank flip happened too early or too late, the next tile could overwrite the current tile’s operands, or a partially loaded next tile could leak into a multiply that has not yet started.

## How overlap works

The overlap in Design C is between two different kinds of work:

- the current `Mul` is reading one bank and updating C,
- the next tile’s `LoadA` and `LoadB` requests are filling the other bank.

Because the banks are disjoint, these operations do not interfere.

That is the reason Design C is faster than B on cycles: the 8 load requests for the next tile are no longer forced to wait for the current multiply to release A and B.

## ReadC while a Mul is active

Design C still blocks `ReadC` until the multiply finishes.

That is necessary because C has only one accumulator matrix. If a read were allowed too early, it could return a partially accumulated value instead of the final answer for that tile.

So the design overlaps loads with compute, but it does not overlap reads with the active multiply.

## Correctness hazards that the banks prevent

The main correctness hazards in Design C are:

- loading into the bank that is currently being multiplied,
- flipping banks too late and corrupting the current tile,
- reading C before the current tile is complete.

The code prevents those hazards by:

- using two distinct A banks and two distinct B banks,
- flipping `rg_load_bank` when a new `Mul` starts,
- keeping `rg_busy` asserted until the four K steps finish,
- blocking `ReadC` while `rg_busy` is true.

## Measured results

These are the actual results for `MatMulC.bsv` in this workspace.

| metric | value |
|---|---:|
| W1 cycles | 41729 |
| W2 cycles | 299777 |
| W1 stalls | 769 |
| W2 stalls | 769 |
| cells | 64129 |
| logic depth | 58 |

## Why the numbers improve

Compared with Design B, Design C spends the same number of cycles on the K-serial multiply itself, but it hides almost all of the operand-loading time behind that multiply.

That is why the cycle count drops sharply, while area and depth rise slightly:

- area rises because the design now stores two copies of A and B,
- depth rises a little because the bank-selection logic and extra muxing are now in the path,
- cycles fall because loads and compute overlap.

## Relationship to B

The easiest way to think about Design C is:

- same compute core as B,
- same accumulator behavior as B,
- same request/response contract as B,
- extra banked storage around it.

So if B is the "single-buffer" K-serial design, C is the "double-buffered" version of the same engine.

## Code map

The important blocks in `MatMulC.bsv` are:

- `rg_a`, `rg_b`, `rg_load_bank`: the double-buffering state.
- `rl_mul_start`: the bank switch and the start of a new tile.
- `rl_mul_step`: the active compute bank update.
- `rl_load_a` / `rl_load_b`: load requests routed to the inactive bank.
- `rl_read_c`: the readout path, still serialized after compute.
