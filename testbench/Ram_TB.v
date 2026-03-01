/**
 * @file    Ram_TB.v
 * @author  [Omar Mohamed Eid]
 * @date    2025
 *
 * @brief   Self-checking testbench for the Ram module.
 *
 * @details Exercises all four command opcodes (Set Write Addr, Write Data,
 *          Set Read Addr, Read Data), verifies Tx_Valid gating behaviour,
 *          and confirms that both power-on reset and mid-operation reset
 *          drive all outputs to a known-zero state.
 *
 *          Test plan:
 *            1.  Power-on reset verification
 *            2.  Set Write Address  (cmd = 2'b00)
 *            3.  Write Data         (cmd = 2'b01)
 *            4.  Set Read Address   (cmd = 2'b10)
 *            5.  Read Data + Tx_Valid assertion  (cmd = 2'b11)
 *            6.  Tx_Valid clears when Rx_Valid de-asserts
 *            7.  Multi-location write and read-back
 *            8.  Reset asserted mid-operation
 */

`timescale 1ns/1ps

module Ram_TB();

// --- Parameters ---

parameter DATA_WIDTH = 8;
parameter ADDR_WIDTH = 8;

// --- DUT Interface Signals ---

reg CLK_TB;
reg RST_N_TB;
reg [DATA_WIDTH+1:0] DATA_IN_TB;   ///< {opcode[1:0], payload[7:0]}
reg Rx_Valid_TB;

wire Tx_Valid_TB;
wire [DATA_WIDTH-1:0] DATA_OUT_TB;

// --- DUT Instantiation ---

Ram #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH)
) DUT (
    .CLK      (CLK_TB),
    .RST_N    (RST_N_TB),
    .DATA_IN  (DATA_IN_TB),
    .Rx_Valid (Rx_Valid_TB),
    .Tx_Valid (Tx_Valid_TB),
    .DATA_OUT (DATA_OUT_TB)
);

// --- Clock Generation ---

/// 10 ns period → 100 MHz reference clock.
always #5 CLK_TB = ~CLK_TB;

// --- Test Sequence ---

initial begin
    // =========================================================
    // Initialisation
    // All inputs idle; CLK starts LOW so the first rising edge
    // is deterministic relative to all negedge event triggers below.
    // =========================================================
    RST_N_TB    = 1;
    Rx_Valid_TB = 0;
    DATA_IN_TB  = 0;
    CLK_TB      = 0;

    // =========================================================
    // Test 1: Power-on Reset
    // Assert RST_N for one full clock cycle to confirm that
    // write_addr, read_addr, DATA_OUT, and Tx_Valid all clear.
    // =========================================================
    @(negedge CLK_TB); RST_N_TB = 0;  // Assert active-low reset.
    @(negedge CLK_TB); RST_N_TB = 1;  // Release reset.

    @(posedge CLK_TB);
    if (Tx_Valid_TB !== 0 || DATA_OUT_TB !== 0)
        $display("FAIL Test 1: Reset failed — Tx_Valid=%0b DATA_OUT=%0h",
                 Tx_Valid_TB, DATA_OUT_TB);
    else
        $display("PASS Test 1: Reset OK");

    // =========================================================
    // Test 2: Set Write Address  (opcode = 2'b00)
    // DATA_IN[9:8]=2'b00 causes the module to latch DATA_IN[7:0]
    // into write_addr.  No RAM write occurs at this step.
    // =========================================================
    @(negedge CLK_TB);
    Rx_Valid_TB = 1;
    DATA_IN_TB  = {2'b00, 8'hAA};   // Target write address = 0xAA.
    @(negedge CLK_TB);
    Rx_Valid_TB = 0;
    $display("Test 2: Set Write Address = 0xAA");

    // =========================================================
    // Test 3: Write Data  (opcode = 2'b01)
    // DATA_IN[9:8]=2'b01 writes DATA_IN[7:0] to ram[write_addr].
    // Relies on write_addr latched in Test 2.
    // =========================================================
    @(negedge CLK_TB);
    Rx_Valid_TB = 1;
    DATA_IN_TB  = {2'b01, 8'hBB};   // Write 0xBB to ram[0xAA].
    @(negedge CLK_TB);
    Rx_Valid_TB = 0;
    $display("Test 3: Write Data 0xBB to Address 0xAA");

    // =========================================================
    // Test 4: Set Read Address  (opcode = 2'b10)
    // DATA_IN[9:8]=2'b10 latches DATA_IN[7:0] into read_addr.
    // Set to 0xAA so the subsequent read retrieves what Test 3 wrote.
    // =========================================================
    @(negedge CLK_TB);
    Rx_Valid_TB = 1;
    DATA_IN_TB  = {2'b10, 8'hAA};   // Target read address = 0xAA.
    @(negedge CLK_TB);
    Rx_Valid_TB = 0;
    $display("Test 4: Set Read Address = 0xAA");

    // =========================================================
    // Test 5: Read Data + Tx_Valid assertion  (opcode = 2'b11)
    // DATA_IN[9:8]=2'b11 drives DATA_OUT from ram[read_addr] and
    // asserts Tx_Valid for one clock cycle.  DATA_IN[7:0] is a
    // don't-care for this opcode.
    // =========================================================
    @(negedge CLK_TB);
    Rx_Valid_TB = 1;
    DATA_IN_TB  = {2'b11, 8'h00};   // Payload ignored on Read Data.
    @(negedge CLK_TB);
    Rx_Valid_TB = 0;

    @(posedge CLK_TB);
    if (Tx_Valid_TB !== 1)
        $display("FAIL Test 5: Tx_Valid should be HIGH");
    else if (DATA_OUT_TB !== 8'hBB)
        $display("FAIL Test 5: Expected 0xBB, Got 0x%0h", DATA_OUT_TB);
    else
        $display("PASS Test 5: Read Data = 0x%0h, Tx_Valid = %0b",
                 DATA_OUT_TB, Tx_Valid_TB);

    // =========================================================
    // Test 6: Tx_Valid Gating
    // Tx_Valid must de-assert in the same clock cycle that
    // Rx_Valid goes low.  Holding Tx_Valid high would cause
    // spurious re-reads on the SPI transmit path.
    // =========================================================
    @(negedge CLK_TB); Rx_Valid_TB = 0;
    @(posedge CLK_TB);
    if (Tx_Valid_TB !== 0)
        $display("FAIL Test 6: Tx_Valid should be LOW when Rx_Valid=0");
    else
        $display("PASS Test 6: Tx_Valid cleared correctly");

    // =========================================================
    // Test 7: Multi-location Write / Read-back
    // Verify that each address cell is independently addressable
    // and that reads from one address do not bleed into another.
    // =========================================================

    // --- Write 0x11 to address 0x01 ---
    @(negedge CLK_TB); Rx_Valid_TB = 1; DATA_IN_TB = {2'b00, 8'h01};
    @(negedge CLK_TB);                  DATA_IN_TB = {2'b01, 8'h11};
    @(negedge CLK_TB); Rx_Valid_TB = 0;

    // --- Write 0x22 to address 0x02 ---
    @(negedge CLK_TB); Rx_Valid_TB = 1; DATA_IN_TB = {2'b00, 8'h02};
    @(negedge CLK_TB);                  DATA_IN_TB = {2'b01, 8'h22};
    @(negedge CLK_TB); Rx_Valid_TB = 0;

    // --- Read back from address 0x01 and check for 0x11 ---
    @(negedge CLK_TB); Rx_Valid_TB = 1; DATA_IN_TB = {2'b10, 8'h01};
    @(negedge CLK_TB);                  DATA_IN_TB = {2'b11, 8'h00};
    @(negedge CLK_TB); Rx_Valid_TB = 0;
    @(posedge CLK_TB);
    if (DATA_OUT_TB !== 8'h11)
        $display("FAIL Test 7a: Expected 0x11, Got 0x%0h", DATA_OUT_TB);
    else
        $display("PASS Test 7a: Read Address 0x01 = 0x%0h", DATA_OUT_TB);

    // --- Read back from address 0x02 and check for 0x22 ---
    @(negedge CLK_TB); Rx_Valid_TB = 1; DATA_IN_TB = {2'b10, 8'h02};
    @(negedge CLK_TB);                  DATA_IN_TB = {2'b11, 8'h00};
    @(negedge CLK_TB); Rx_Valid_TB = 0;
    @(posedge CLK_TB);
    if (DATA_OUT_TB !== 8'h22)
        $display("FAIL Test 7b: Expected 0x22, Got 0x%0h", DATA_OUT_TB);
    else
        $display("PASS Test 7b: Read Address 0x02 = 0x%0h", DATA_OUT_TB);

    // =========================================================
    // Test 8: Reset Asserted Mid-operation
    // Confirms that an in-flight write address command does not
    // survive a reset pulse, and that both Tx_Valid and DATA_OUT
    // return to 0 after reset is released.
    // =========================================================
    @(negedge CLK_TB);
    Rx_Valid_TB = 1;
    DATA_IN_TB  = {2'b00, 8'hFF};   // Begin a Set Write Addr command.
    @(negedge CLK_TB);
    RST_N_TB    = 0;                 // Interrupt with reset.
    Rx_Valid_TB = 0;
    @(negedge CLK_TB); RST_N_TB = 1;
    @(posedge CLK_TB);
    if (Tx_Valid_TB !== 0 || DATA_OUT_TB !== 0)
        $display("FAIL Test 8: Reset mid-operation failed");
    else
        $display("PASS Test 8: Reset mid-operation OK");

    // =========================================================
    // Simulation Complete
    // =========================================================
    #20;
    $display("=============================");
    $display("  Testbench Complete");
    $display("=============================");
    $stop;
end

endmodule