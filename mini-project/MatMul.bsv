// MatMul.bsv --- YOUR FILE.  Edit this one.
//
// What ships here is the naive design: `Mul` computes the entire M x N x K
// product as one combinational expression, in a single cycle.  It is correct,
// it passes the testbench, and it is a perfectly reasonable starting point --
// but it is not a good design, and §6 of the README explains why a design that
// wins on cycle count can still be the wrong answer.
//
// Read it, measure it (`make` and `make depth`), and then build something else.
//
// You may restructure this file however you like -- add rules, add state,
// split `Mul` across cycles, rename things.  The only fixed points are:
//
//   * the module is called `mkMatMul` and has interface `MatMul_IFC`
//   * `MM_Types.bsv` is unmodified
//   * the behaviour matches §4 of the README
//
// Keep the (* synthesize *) attribute: `make depth` needs it to find the
// module boundary.

package MatMul;

import Vector   :: *;
import FIFOF    :: *;
import MM_Types :: *;

// ================================================================
// The whole product as one expression.
//
// Count the operators in series along one output: one multiply, then a sum of
// K terms.  That chain is the critical path, and every cycle of the design has
// to be long enough to contain it.  §8 of the README asks which of the two
// terms dominates.

function C_Mat f_all (A_Mat a, B_Mat b, C_Mat c);
   C_Mat o = c;
   for (Integer i = 0; i < m_dim; i = i + 1)
      for (Integer j = 0; j < n_dim; j = j + 1) begin
	 Acc s = c[i][j];
	 for (Integer l = 0; l < k_dim; l = l + 1)
	    s = s + (signExtend (a[i][l]) * signExtend (b[l][j]));
	 o[i][j] = s;
      end
   return o;
endfunction

// ================================================================

(* synthesize *)
module mkMatMul (MatMul_IFC);

   Reg #(A_Mat) rg_a <- mkReg (replicate (replicate (0)));
   Reg #(B_Mat) rg_b <- mkReg (replicate (replicate (0)));
   Reg #(C_Mat) rg_c <- mkReg (replicate (replicate (0)));

   // Requests in, responses out.  Both methods below are guarded by these
   // FIFOs, which is where the back-pressure §3 promises comes from.
   FIFOF #(MM_Req) f_req <- mkFIFOF;
   FIFOF #(MM_Rsp) f_rsp <- mkFIFOF;

   // ---- One rule per request type.
   //
   // This is not a stylistic choice, and it will matter to you later: bsc
   // schedules WHOLE RULES.  A single rule with a `case` over the request tag
   // would conflict with itself on every register any arm touches, whether or
   // not that arm is taken, and no two request types could ever overlap.  See
   // §8, and `bsc -show-schedule`.

   rule rl_load_a (f_req.first matches tagged LoadA .w);
      f_req.deq;
      let a = rg_a;
      // ELEMS_PER_WORD elements, element 0 in the low-order bits.  `pack` on a
      // Vector puts index 0 in the HIGH bits, hence the reverse.
      //
      // `w.chunk` is ignored: at W_ELEM = 8 a row of A is exactly 32 bits, so
      // there is only ever chunk 0.  Change W_ELEM (§9) and that stops being
      // true.
      a[w.row] = reverse (unpack (w.word));
      rg_a <= a;
      f_rsp.enq (mm_rsp_none);
   endrule

   rule rl_load_b (f_req.first matches tagged LoadB .w);
      f_req.deq;
      let b = rg_b;
      b[w.row] = reverse (unpack (w.word));
      rg_b <= b;
      f_rsp.enq (mm_rsp_none);
   endrule

   rule rl_mul (f_req.first matches tagged Mul);
      f_req.deq;
      rg_c <= f_all (rg_a, rg_b, rg_c);
      f_rsp.enq (mm_rsp_none);
   endrule

   // Destructive read: return the slice and zero what was returned.  At
   // W_ACC = 32 one word is one element, so `chunk` is the column index.
   rule rl_read_c (f_req.first matches tagged ReadC .x);
      f_req.deq;
      let c = rg_c;
      Acc v = c [x.row][x.chunk];
      c [x.row][x.chunk] = 0;
      rg_c <= c;
      f_rsp.enq (mm_rsp_value (pack (v)));
   endrule

   // ---- The interface.  Both methods are guarded by their FIFO; do not add
   // explicit ready/valid signals.

   method Action req (MM_Req r) = f_req.enq (r);

   method ActionValue #(MM_Rsp) rsp;
      f_rsp.deq;
      return f_rsp.first;
   endmethod
endmodule

endpackage: MatMul
