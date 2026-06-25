`timescale 1ns / 1ps
//==============================================================================
// File        : ALU_testbench.sv
// Description : SystemVerilog Layered Functional Verification Testbench
//               for a parameterized synchronous ALU (4 operations)
// Components  : Transaction · Generator · Driver · Monitor · Scoreboard
// Features    : Constrained-random stimulus · Functional coverage ·
//               Self-checking scoreboard · Virtual interface
// Simulator   : Vivado XSim 2024.2
// Author      : [Chhandak Roy] - IIT Guwahati, M.Tech VLSI (2024-2026)
// Date        : June 2026
//==============================================================================


//==============================================================================
// INTERFACE
//==============================================================================
interface alu_if;
    parameter WIDTH          = 8;
    bit                      clk;
    bit                      reset;
    bit signed [WIDTH-1:0]   a, b;
    bit [1:0]                mode;
    bit signed [2*WIDTH-1:0] result;
endinterface


//==============================================================================
// TESTBENCH TOP MODULE
//==============================================================================
module ALU_testbench;

    //--------------------------------------------------------------------------
    // Parameters & Type Definitions
    //--------------------------------------------------------------------------
    parameter WIDTH = 8;

    typedef enum logic [1:0] {
        ADD = 2'b00,
        SUB = 2'b01,
        MUL = 2'b10,
        CMP = 2'b11
    } alu_op_e;


    //==========================================================================
    // CLASS : TRANSACTION
    // Purpose : Randomized data object carrying stimulus and response fields
    //==========================================================================
    class transaction;

        rand bit signed [WIDTH-1:0]  a, b;
        rand alu_op_e                operation;
        bit signed [2*WIDTH-1:0]     result;

        //----------------------------------------------------------------------
        // Constraint : Guard against 16-bit multiplication overflow
        //----------------------------------------------------------------------
        constraint c_mul_range {
            if (operation == MUL) {
                a < 200;
                b < 200;
            }
        }

        //----------------------------------------------------------------------
        // Constraint : Weighted operation distribution
        //----------------------------------------------------------------------
        constraint c_op_dist {
            operation dist {
                ADD := 30,
                SUB := 10,
                MUL := 40,
                CMP := 20
            };
        }

        function new();
            $display("[TRANSACTION] Created");
        endfunction

    endclass : transaction


    //==========================================================================
    // CLASS : GENERATOR
    // Purpose : Randomizes transactions and dispatches to Driver and Monitor
    //==========================================================================
    class generator;

        mailbox #(transaction) gen2drv;
        mailbox #(transaction) gen2mon;

        function new(
            input mailbox #(transaction) gen2drv,
            input mailbox #(transaction) gen2mon
        );
            this.gen2drv = gen2drv;
            this.gen2mon = gen2mon;
        endfunction

        task run();
            transaction tr;
            repeat (20) begin
                tr = new();
                assert (tr.randomize()) else
                    $fatal(1, "[GENERATOR] Randomization failed - check constraints");
                gen2drv.put(tr);
                gen2mon.put(tr);
                $display("[GENERATOR] Transaction dispatched to gen2drv & gen2mon");
            end
        endtask

    endclass : generator


    //==========================================================================
    // CLASS : DRIVER
    // Purpose : Consumes transactions from gen2drv; drives DUT via interface
    //==========================================================================
    class driver;

        virtual alu_if         vif;
        mailbox #(transaction) gen2drv;
        transaction            tr;

        function new(
            input mailbox #(transaction) gen2drv,
            input virtual alu_if         vif
        );
            this.gen2drv = gen2drv;
            this.vif     = vif;
        endfunction

        task run();
            repeat (20) begin
                gen2drv.get(tr);
                @(posedge vif.clk);
                vif.a    <= tr.a;
                vif.b    <= tr.b;
                vif.mode <= tr.operation;
                $display("[DRIVER]     a = %3d | b = %3d | Mode = %s",
                          tr.a, tr.b, tr.operation.name());
            end
        endtask

    endclass : driver


    //==========================================================================
    // CLASS : MONITOR
    // Purpose : Samples DUT output post clock-edge; collects functional coverage
    //==========================================================================
    class monitor;

        virtual alu_if         vif;
        mailbox #(transaction) gen2mon;
        mailbox #(transaction) mon2sb;

        //----------------------------------------------------------------------
        // Covergroup : Functional Coverage Collection
        //----------------------------------------------------------------------
        covergroup alu_cov @(posedge vif.clk);

            // Operation mode coverage
            cp_mode: coverpoint vif.mode {
                bins add = {2'b00};
                bins sub = {2'b01};
                bins mul = {2'b10};
                bins cmp = {2'b11};
            }

            // Operand A - range coverage
            cp_a: coverpoint vif.a {
                bins low  = {[0   : 63 ]};
                bins mid  = {[64  : 127]};
                bins high = {[128 : 191]};
                bins max  = {[192 : 255]};
            }

            // Operand B - range coverage
            cp_b: coverpoint vif.b {
                bins low  = {[0   : 63 ]};
                bins mid  = {[64  : 127]};
                bins high = {[128 : 191]};
                bins max  = {[192 : 255]};
            }

            // Result - range coverage
            cp_result: coverpoint vif.result {
                bins zero = {0};
                bins low  = {[1    : 255  ]};
                bins mid  = {[256  : 4095 ]};
                bins high = {[4096 : 65535]};
            }

            // Cross coverage : mode × operand A range
            cx_mode_a: cross cp_mode, cp_a;

            // Cross coverage : mode × operand B range
            cx_mode_b: cross cp_mode, cp_b;

        endgroup : alu_cov

        function new(
            input mailbox #(transaction) gen2mon,
            input mailbox #(transaction) mon2sb,
            input virtual alu_if         vif
        );
            this.gen2mon = gen2mon;
            this.mon2sb  = mon2sb;
            this.vif     = vif;
            alu_cov      = new();
        endfunction

        task run();
            transaction tr;
            @(posedge vif.clk);          // Absorb initial pipeline latency
            repeat (20) begin
                gen2mon.get(tr);
                @(posedge vif.clk);
                #1;                       // Step past NBA region - DUT output is stable
                tr.result = vif.result;
                mon2sb.put(tr);
                $display("[MONITOR]    a = %3d | b = %3d | Mode = %-3s | Result = %5d",
                          tr.a, tr.b, tr.operation.name(), tr.result);
            end
        endtask

        function void report();
            $display("[MONITOR]    Functional Coverage = %0.2f%%", alu_cov.get_coverage());
        endfunction

    endclass : monitor


    //==========================================================================
    // CLASS : SCOREBOARD
    // Purpose : Computes expected result; compares with DUT output; PASS/FAIL
    //==========================================================================
    class scoreboard;

        mailbox #(transaction) mon2sb;
        transaction            tr;

        bit signed [2*WIDTH-1:0] expected;
        int add_count;
        int sub_count;
        int mul_count;
        int cmp_count;
        int pass_count;
        int fail_count;

        function new(input mailbox #(transaction) mon2sb);
            this.mon2sb = mon2sb;
        endfunction

        task run();
            repeat (20) begin
                mon2sb.get(tr);

                //--------------------------------------------------------------
                // Reference model : compute expected result per operation
                //--------------------------------------------------------------
                case (tr.operation)
                    ADD: begin add_count++; expected = tr.a + tr.b;     end
                    SUB: begin sub_count++; expected = tr.a - tr.b;     end
                    MUL: begin mul_count++; expected = tr.a * tr.b;     end
                    CMP: begin cmp_count++; expected = (tr.a > tr.b);   end
                endcase

                //--------------------------------------------------------------
                // Compare : === catches X/Z mismatches that == would miss
                //--------------------------------------------------------------
                if (expected === tr.result) begin
                    pass_count++;
                    $display("[SCOREBOARD] PASSED | %-3s | a=%3d | b=%3d | Exp=%5d | Got=%5d",
                              tr.operation.name(), tr.a, tr.b, expected, tr.result);
                end else begin
                    fail_count++;
                    $display("[SCOREBOARD] FAILED | %-3s | a=%3d | b=%3d | Exp=%5d | Got=%5d  <= MISMATCH",
                              tr.operation.name(), tr.a, tr.b, expected, tr.result);
                end
            end
        endtask

        function void report();
            $display("==================================================");
            $display("[SCOREBOARD] -------- Simulation Summary ---------");
            $display("==================================================");
            $display("  ADD transactions  : %0d", add_count);
            $display("  SUB transactions  : %0d", sub_count);
            $display("  MUL transactions  : %0d", mul_count);
            $display("  CMP transactions  : %0d", cmp_count);
            $display("--------------------------------------------------");
            $display("  TOTAL PASSED      : %0d", pass_count);
            $display("  TOTAL FAILED      : %0d", fail_count);
            $display("--------------------------------------------------");
            if (fail_count == 0)
                $display("  STATUS            : ALL TESTS PASSED ");
            else
                $display("  STATUS            : %0d TEST(S) FAILED ", fail_count);
            $display("==================================================");
        endfunction

    endclass : scoreboard


    //==========================================================================
    // DUT INSTANTIATION
    //==========================================================================
    alu_if vif ();

    ALU #(.width(WIDTH)) DUT (
        .clk    (vif.clk   ),
        .reset  (vif.reset ),
        .a      (vif.a     ),
        .b      (vif.b     ),
        .mode   (vif.mode  ),
        .result (vif.result)
    );


    //==========================================================================
    // TESTBENCH COMPONENT HANDLES & MAILBOXES
    //==========================================================================
    generator              gen;
    driver                 drv;
    monitor                mon;
    scoreboard             sb;

    mailbox #(transaction) gen2drv;
    mailbox #(transaction) gen2mon;
    mailbox #(transaction) mon2sb;


    //==========================================================================
    // CLOCK GENERATION - 100 MHz (10 ns period)
    //==========================================================================
    initial begin
        vif.clk = 1'b0;
        forever #5 vif.clk = ~vif.clk;
    end


    //==========================================================================
    // RESET GENERATION - Active-high, held for 2 clock cycles
    //==========================================================================
    initial begin
        vif.reset = 1'b1;
        #20;
        vif.reset = 1'b0;
    end


    //==========================================================================
    // COMPONENT CONSTRUCTION - Mailboxes to Components to Connect
    //==========================================================================
    initial begin
        gen2drv = new();
        gen2mon = new();
        mon2sb  = new();

        gen = new(gen2drv, gen2mon);
        drv = new(gen2drv, vif);
        mon = new(gen2mon, mon2sb, vif);
        sb  = new(mon2sb);
    end


    //==========================================================================
    // SIMULATION CONTROL
    //==========================================================================
    initial begin
        wait (vif.reset === 1'b0);    // Wait for reset de-assertion

        fork
            gen.run();
            drv.run();
            mon.run();
            sb.run();
        join

        $display("==================================================");
        mon.report();
        sb.report();
        $display("==================================================");

        $finish;
    end

endmodule : ALU_testbench