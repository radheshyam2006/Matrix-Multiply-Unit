# Mini Project 1 — Radheshyam (2023102032)

## 1. Measurements

| Metric | Design A: Combinational | Design B: K-Serial | Design C: Double-Buffered |
|---|---:|---:|---:|
| W1 cycles | 40,961 | 53,249 | 41,729 |
| W2 cycles | 299,009 | 397,313 | 299,777 |
| W1/W2 stalls | 1 / 1 | 12,289 / 98,305 | 769 / 769 |
| Cells | 113,160 | 62,158 | 65,681 |
| Logic depth | 71 | 56 | 58 |
| W1 cycles × depth | 2,908,231 | 2,981,944 | 2,420,282 |
| W2 cycles × depth | 21,229,639 | 22,249,528 | 17,387,066 |
| Cells × depth | 8,034,360 | 3,480,848 | 3,809,498 |

All three designs passed W1 and W2 with zero errors. Design C also passed a directed test of partial operand updates, loads overlapping multiplication, response ordering, expected results, and destructive `ReadC`.

## 2. Predictions from §6.4, and Where They Were Wrong

### Cycles per K-tile

Each K-tile has eight operand loads and one `Mul` request. Let `l` be the arithmetic latency.

- **A — Combinational:** `C_K = 8 + l = 8 + 1 = 9 cycles`.
- **B — Blocking K-serial:** `C_K = 8 + l = 8 + 4 = 12 cycles`. The four-cycle `Mul` adds three cycles beyond its request cycle because subsequent requests are blocked.
- **C — Double-buffered:** Ideal `C_K ≈ max(8, 4) + 1 = 9 cycles`, because loading the alternate bank should overlap the four-cycle computation.

Let `N` be the total requests and `M` the number of `Mul` requests. Including the final response-drain cycle, the predictions are `A: N + 1`, `B: N + 3M + 1`, and ideal `C: N + 1`. W1 has `N = 40,960`, `M = 4,096`; W2 has `N = 299,008`, `M = 32,768`.

| Design | Workload | Predicted cycles | Measured cycles | Difference |
|---|---|---:|---:|---:|
| A | W1 | 40,961 | 40,961 | 0 |
| A | W2 | 299,009 | 299,009 | 0 |
| B | W1 | 53,249 | 53,249 | 0 |
| B | W2 | 397,313 | 397,313 | 0 |
| C | W1 | 40,961 | 41,729 | +768 |
| C | W2 | 299,009 | 299,777 | +768 |

A and B match the predictions. B adds `3 × 4,096 = 12,288` cycles in W1 and `3 × 32,768 = 98,304` in W2, plus the final drain cycle. C exceeds the ideal prediction by `768 = 3 × 256` cycles: three additional stalls per output tile across 256 output tiles. The ideal overlap formula does not capture all per-tile overhead in the implementation. Its measured stalls are 769 because stalls are measured relative to requests and include the final drain cycle.

The predicted cell ranking was `A > C > B`, confirmed by measurements. The predicted logic-depth ranking was `A > C > B`, also confirmed. A fully unrolls 64 multipliers and the four-term accumulation; B and C reuse 16 multipliers and accumulate across four K-steps. C's bank-selection logic adds two depth levels relative to B. Fewer multipliers alone do not guarantee a shorter critical path.

## 3. Where do your cycles go?

A has one stall per workload, the final response-drain cycle. B has `3M + 1` stalls: 12,289 in W1 and 98,305 in W2, because each four-cycle `Mul` blocks incoming requests for three additional cycles. C has 769 stalls in both workloads (`3 × 256 + 1`): double buffering overlaps loading and computation, but leaves three additional stalls per output tile.

## 4. Why is MACs-per-request the same for all three designs?

Every K-tile performs 64 MACs using eight load requests and one `Mul` request, so all designs achieve `64/9 ≈ 7.11 MACs/request`. This is fixed by the interface and tile shape, not the internal implementation. Changing it requires changing request granularity, transfer width, tile dimensions, or the amount of computation represented by a request.

## 5. What sets your longest path?

A's critical path includes an 8-bit multiplication and the accumulation of four products, giving logic depth 71. B and C serialize accumulation across K-steps, reducing depth to 56 and 58. The improvement comes from reducing operations in series, not simply from using fewer multipliers. C's bank-selection logic adds two depth levels over B.

## 6. What happens when a LoadA arrives while a Mul is in progress?

In B, incoming requests wait until the active four-cycle multiplication finishes; otherwise, a load could change an operand during computation and violate sequential request semantics. C computes from one bank while loads target the alternate bank, enabling overlap. Its extra storage and bank-selection logic cost area, and untouched rows must be preserved when switching banks so partial updates remain correct.

## 7. Why does W2 cost more than W1 per unit of readout, but less per MAC?

Each output tile has 16 `ReadC` requests. W1 performs 16 Muls before readout, giving `16/16 = 1` read per Mul; W2 performs 128, giving `16/128 = 0.125` reads per Mul. Readout is 10% of W1's 40,960 requests but only about 1.4% of W2's 299,008 requests. W2 therefore amortizes the fixed readout cost over eight times as many Muls. B is most sensitive: its stalls rise from 12,289 to 98,305, approximately eightfold, because each additional Mul exposes three stalls. C remains at 769 stalls because its measured overhead depends on the 256 output tiles.

## 8. How wide does the accumulator have to be?

For signed `W_ELEM`-bit operands, the maximum positive product is `2^(2*W_ELEM - 2)`. If each Mul accumulates `K` products and `T` Muls occur between readouts, a conservative positive bound is `S_max = T * K * 2^(2*W_ELEM - 2)`. Avoiding signed overflow requires `2^(W_ACC - 1) - 1 >= S_max`, so a sufficient width is `W_ACC >= 1 + ceil(log2(S_max + 1))`.

For `W_ELEM = 8` and `K = 4`, one Mul can sum `4 × 128 × 128 = 65,536`. A signed 16-bit accumulator has maximum 32,767, so it cannot safely hold even one worst-case Mul result: the maximum number of complete worst-case Muls at `W_ACC = 16` is zero. A signed 32-bit accumulator can hold 2,147,483,647, or `floor(2,147,483,647 / 65,536) = 32,767` worst-case Mul results under this bound. The actual workload is specified not to overflow its 32-bit accumulator.

## 9. When does a DMA-fed unit stop being instruction-bound?

Appendix A states that the 4 × 4 × 4 DMA-fed unit becomes memory-bound almost immediately. At 64 MACs per cycle and 1 GHz, it needs 32 bytes/cycle, or `32 × 10^9 = 32 GB/s`, to sustain peak throughput. Larger tiles improve data reuse, but the bottleneck shifts to memory bandwidth. DMA also requires OS support absent from the request interface; for example, the OS must pin pages so they cannot be moved or swapped out during a transfer. Cache coherence or address translation/IOMMU support are other valid examples.

## 10. When BSV does not do what you expect

BSV schedules whole rules atomically. If rules call conflicting methods on the same resource, such as dequeuing the same FIFO, the compiler may prevent them from firing in the same cycle. The schedule report (build_bsim/mkMatMul.sched) shows no blocking rules for rl_mul_step, rl_load_a, rl_load_b, rl_mul_start, or rl_read_c. It identifies no specific rule conflict preventing concurrent execution.

## 11. Design choice and trade-offs

**Priority:** Balance execution time against hardware cost and logic depth.

**Choice:** Design C, the double-buffered K-serial design. Compared with B, C reduces cycles by 21.6% in W1 and 24.5% in W2, at the cost of 3,523 additional cells and two more logic-depth levels. Compared with A, C uses 47,479 fewer cells and has depth 58 instead of 71, while taking only 768 more cycles in each workload.

**Strongest argument against C:** It is not the fastest design and is larger than B. A is preferable if cycle count alone matters; B is preferable if minimizing cell count is the priority. C is the compromise: near-A cycle counts with substantially lower cell count and logic depth.