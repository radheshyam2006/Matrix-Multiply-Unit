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

function Bit #(1) f_other (Bit #(1) b);
   return ~b;
endfunction

(* synthesize *)
module mkMatMul (MatMul_IFC);

   Reg #(Vector #(2, A_Mat)) rg_a
      <- mkReg (replicate (replicate (replicate (0))));

   Reg #(Vector #(2, B_Mat)) rg_b
      <- mkReg (replicate (replicate (replicate (0))));

   Reg #(C_Mat) rg_c <- mkReg (replicate (replicate (0)));

   Reg #(Bool) rg_busy <- mkReg (False);
   Reg #(Bit #(2)) rg_step <- mkReg (0);
   Reg #(Bit #(1)) rg_load_bank <- mkReg (0);

   FIFOF #(MM_Req) f_req <- mkFIFOF;
   FIFOF #(MM_Rsp) f_rsp <- mkFIFOF;

   // Compute one K contribution per cycle.
   rule rl_mul_step (rg_busy);
      let bank = f_other (rg_load_bank);
      let next_c = f_step (rg_a[bank], rg_b[bank],
                           rg_c, rg_step);

      rg_c <= next_c;

      if (rg_step == 3) begin
         rg_busy <= False;
         rg_step <= 0;
      end
      else begin
         rg_step <= rg_step + 1;
      end
   endrule

   // Load A into the bank not used by the active multiplication.
   rule rl_load_a (f_req.first matches tagged LoadA .w);
      f_req.deq;

      let bank = rg_load_bank;
      let a = rg_a;
      let row = a[bank];

      row[w.row] = reverse (unpack (w.word));
      a[bank] = row;
      rg_a <= a;

      f_rsp.enq (mm_rsp_none);
   endrule

   // Load B into the bank not used by the active multiplication.
   rule rl_load_b (f_req.first matches tagged LoadB .w);
      f_req.deq;

      let bank = rg_load_bank;
      let b = rg_b;
      let row = b[bank];

      row[w.row] = reverse (unpack (w.word));
      b[bank] = row;
      rg_b <= b;

      f_rsp.enq (mm_rsp_none);
   endrule

   // Start Mul and copy the current operands into the next loading bank.
   rule rl_mul_start (
      f_req.first matches tagged Mul &&& !rg_busy
   );
      f_req.deq;

      let bank = rg_load_bank;
      let next_bank = f_other (bank);

      rg_c <= f_step (rg_a[bank], rg_b[bank], rg_c, 0);
      rg_busy <= True;
      rg_step <= 1;

      // Preserve rows not overwritten by subsequent loads.
      let a = rg_a;
      let b = rg_b;
      a[next_bank] = a[bank];
      b[next_bank] = b[bank];

      rg_a <= a;
      rg_b <= b;
      rg_load_bank <= next_bank;

      f_rsp.enq (mm_rsp_none);
   endrule

   // Read and clear one accumulator element.
   rule rl_read_c (
      f_req.first matches tagged ReadC .x &&& !rg_busy
   );
      f_req.deq;

      let c = rg_c;
      Acc v = c[x.row][x.chunk];

      c[x.row][x.chunk] = 0;
      rg_c <= c;

      f_rsp.enq (mm_rsp_value (pack (v)));
   endrule

   method Action req (MM_Req r);
      f_req.enq (r);
   endmethod

   method ActionValue #(MM_Rsp) rsp;
      let value = f_rsp.first;
      f_rsp.deq;
      return value;
   endmethod

endmodule

endpackage: MatMul