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
package MatMul;

import Vector   :: *;
import FIFOF    :: *;
import MM_Types :: *;

function C_Mat f_step (A_Mat a, B_Mat b, C_Mat c, Bit #(2) k);
   C_Mat o = c;
   for (Integer i = 0; i < m_dim; i = i + 1)
      for (Integer j = 0; j < n_dim; j = j + 1)
         o[i][j] = c[i][j]
                   + (signExtend (a[i][k]) * signExtend (b[k][j]));
   return o;
endfunction

(* synthesize *)
module mkMatMul (MatMul_IFC);

   Reg #(A_Mat) rg_a <- mkReg (replicate (replicate (0)));
   Reg #(B_Mat) rg_b <- mkReg (replicate (replicate (0)));
   Reg #(C_Mat) rg_c <- mkReg (replicate (replicate (0)));
   Reg #(Bool)  rg_busy <- mkReg (False);
   Reg #(Bit #(2)) rg_step <- mkReg (0);

   FIFOF #(MM_Req) f_req <- mkFIFOF;
   FIFOF #(MM_Rsp) f_rsp <- mkFIFOF;

   rule rl_mul_step (rg_busy);
      let next_c = f_step (rg_a, rg_b, rg_c, rg_step);
      rg_c <= next_c;

      if (rg_step == 3) begin
         rg_busy <= False;
         rg_step <= 0;
         f_rsp.enq (mm_rsp_none);
      end
      else
         rg_step <= rg_step + 1;
   endrule

   rule rl_load_a (f_req.first matches tagged LoadA .w &&& ! rg_busy);
      f_req.deq;
      let a = rg_a;
      a[w.row] = reverse (unpack (w.word));
      rg_a <= a;
      f_rsp.enq (mm_rsp_none);
   endrule

   rule rl_load_b (f_req.first matches tagged LoadB .w &&& ! rg_busy);
      f_req.deq;
      let b = rg_b;
      b[w.row] = reverse (unpack (w.word));
      rg_b <= b;
      f_rsp.enq (mm_rsp_none);
   endrule

   rule rl_mul_start (f_req.first matches tagged Mul &&& ! rg_busy);
      f_req.deq;
      rg_c <= f_step (rg_a, rg_b, rg_c, 0);
      rg_busy <= True;
      rg_step <= 1;
   endrule

   rule rl_read_c (f_req.first matches tagged ReadC .x &&& ! rg_busy);
      f_req.deq;
      let c = rg_c;
      Acc v = c [x.row][x.chunk];
      c [x.row][x.chunk] = 0;
      rg_c <= c;
      f_rsp.enq (mm_rsp_value (pack (v)));
   endrule

   method Action req (MM_Req r) = f_req.enq (r);

   method ActionValue #(MM_Rsp) rsp;
      f_rsp.deq;
      return f_rsp.first;
   endmethod
endmodule

endpackage: MatMul
