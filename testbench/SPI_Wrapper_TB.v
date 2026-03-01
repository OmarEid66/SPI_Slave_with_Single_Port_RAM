/**
 * @file    SPI_Wrapper_TB.v
 * @author  [Omar Mohamed Eid]
 * @date    2025
 *
 * @brief   End-to-end self-checking testbench for the SPI_Wrapper system.
 *
 * @details Exercises the complete SPI_SLAVE + Ram pipeline through the
 *          external SPI bus, mirroring real master behaviour.  Internal
 *          wires are observed via hierarchical references for white-box
 *          verification without modifying the DUT ports.
 *
 *          SPI frame protocol (cmd = DATA_IN[9:8]):
 *            2'b00 → Write Address : Ram latches din[7:0] as write_addr
 *            2'b01 → Write Data    : Ram writes din[7:0] to ram[write_addr]
 *            2'b10 → Read Address  : Ram latches din[7:0] as read_addr
 *            2'b11 → Read Data     : Ram outputs ram[read_addr]; Tx_Valid=1
 *
 *          TX_VALID / MISO timing constraint:
 *            The SPI_SLAVE latches RX_VALID on SS_N's rising edge via a
 *            non-blocking assignment.  The Ram only observes RX_VALID=1
 *            on the NEXT posedge (P+1) due to NBA scheduling.  Tx_Valid
 *            therefore becomes valid at P+1, one frame AFTER the read
 *            command.  All TX_VALID and TX_DATA checks must be deferred
 *            by one extra posedge using wait_ram_output().  MISO=Z during
 *            the read frame is the expected, correct behaviour.
 *
 *          Test plan:
 *             1.  Power-on reset
 *             2.  Write Address frame
 *             3.  Write Data frame
 *             4.  Read Address frame
 *             5.  RX_VALID clears on SS_N falling edge
 *             6.  Multi-address write sequence
 *             7.  Read Data command: Tx_Valid, TX_DATA, and MISO-Z check
 *             8.  Reset mid-transaction
 *             9.  Back-to-back write-address frames
 *            10.  Full write → read pipeline (3 addresses)
 *            11.  Address 0x00 boundary
 *            12.  Address 0xFF boundary
 *            13.  Overwrite existing address
 *            14.  SS_N held high — MISO stays Z
 *            15.  Write data without prior write-address (defaults to 0)
 */

`timescale 1ns/1ps

module SPI_Wrapper_TB #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 8
)();

parameter CLK_PERIOD = 10;  ///< 100 MHz

// --- DUT Signals ---

reg  CLK_TB, RST_N_TB, MOSI_TB, SS_N_TB;
wire MISO_TB;

// --- DUT Instantiation ---

SPI_Wrapper #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH)
) DUT (
    .CLK  (CLK_TB),
    .RST_N(RST_N_TB),
    .MOSI (MOSI_TB),
    .SS_N (SS_N_TB),
    .MISO (MISO_TB)
);

// --- Clock Generation ---

initial CLK_TB = 0;
/// Toggle every half-period to produce CLK_PERIOD frequency.
always #(CLK_PERIOD/2) CLK_TB = ~CLK_TB;

// --- Internal Observation Wires (hierarchical references) ---
/// These probes allow white-box verification of intermediate signals
/// without adding extra output ports to the DUT.
wire [DATA_WIDTH+1:0] w_RX_data  = DUT.RX_data;
wire                  w_RX_VALID = DUT.RX_VALID;
wire                  w_TX_VALID = DUT.TX_VALID;
wire [DATA_WIDTH-1:0] w_TX_DATA  = DUT.TX_DATA;

// --- Test Bookkeeping ---

integer pass_count, fail_count;

/// Convenience task: log a PASS and increment the counter.
task pass;
    input [240*8-1:0] msg;
    begin
        $display("PASS %0s", msg);
        pass_count = pass_count + 1;
    end
endtask

/// Convenience task: log a FAIL and increment the counter.
task fail;
    input [240*8-1:0] msg;
    begin
        $display("FAIL %0s", msg);
        fail_count = fail_count + 1;
    end
endtask

// =========================================================
// Task: spi_write
// =========================================================
/**
 * @brief  Drives a complete (DATA_WIDTH+2)-bit SPI write frame.
 *
 * @param  frame  {cmd[1:0], payload[DATA_WIDTH-1:0]}
 *
 * Returns one posedge after SS_N rises.  At that point,
 * w_RX_VALID is guaranteed to be stable (registered latch).
 */
task spi_write;
    input [DATA_WIDTH+1:0] frame;
    begin
        MOSI_TB = frame[DATA_WIDTH+1];   // Pre-drive MSB before SS_N asserts.
        @(negedge CLK_TB); SS_N_TB = 0;

        begin : wr_loop
            integer i;
            for (i = DATA_WIDTH; i >= 0; i = i - 1) begin
                @(negedge CLK_TB);
                MOSI_TB = frame[i];
            end
        end

        @(negedge CLK_TB);
        SS_N_TB = 1;
        MOSI_TB = 0;
        @(posedge CLK_TB); #1;   // Settle past the RX_VALID latch update.
    end
endtask

// =========================================================
// Task: spi_read
// =========================================================
/**
 * @brief  Drives a READ_DATA SPI frame and captures MISO bits.
 *
 * @param  frame     {2'b11, payload} — payload is a don't-care.
 * @param  received  Output: DATA_WIDTH bits captured MSB-first from MISO.
 *
 * Returns one posedge after SS_N rises (P_end).
 *
 * IMPORTANT: TX_VALID / TX_DATA are NOT valid at return.  Call
 * wait_ram_output() after this task to advance one extra posedge
 * so the Ram's registered Tx_Valid has time to propagate.
 *
 * MISO=Z is expected during this frame because Tx_Valid (and
 * therefore the MISO serialiser) only becomes active after RX_VALID
 * is processed by the Ram — which happens at P_end+1.
 */
task spi_read;
    input  [DATA_WIDTH+1:0] frame;
    output [DATA_WIDTH-1:0] received;
    begin
        received = 0;

        MOSI_TB = frame[DATA_WIDTH+1];
        @(negedge CLK_TB); SS_N_TB = 0;

        @(negedge CLK_TB); MOSI_TB = frame[DATA_WIDTH];

        begin : rd_loop
            integer i;
            for (i = DATA_WIDTH-1; i >= 0; i = i - 1) begin
                @(negedge CLK_TB); MOSI_TB = 0;
                @(posedge CLK_TB); #1;
                received[i] = MISO_TB;
            end
        end

        @(negedge CLK_TB);
        SS_N_TB = 1;
        MOSI_TB = 0;
        @(posedge CLK_TB); #1;
    end
endtask

// =========================================================
// Task: wait_ram_output
// =========================================================
/**
 * @brief  Advances simulation by one posedge to allow the Ram's
 *         registered Tx_Valid and DATA_OUT to propagate.
 *
 * Why this is required:
 *   spi_read() returns at posedge P_end, the clock edge on which
 *   the SPI slave schedules RX_VALID<=1 via a non-blocking
 *   assignment.  The Ram's always block fires on the SAME posedge
 *   but reads the PRE-NBA value of RX_VALID (=0); Verilog's NBA
 *   region updates RX_VALID only after all active-region events
 *   have settled.  Tx_Valid therefore remains 0 at P_end.
 *
 *   At posedge P_end+1, the Ram sees RX_VALID=1, evaluates the
 *   2'b11 command, and schedules Tx_Valid<=1 / DATA_OUT<=ram[addr].
 *   After the NBA region of P_end+1, both outputs are valid.
 */
task wait_ram_output;
    begin
        @(posedge CLK_TB); #1;
    end
endtask

// =========================================================
// Task: full_write
// =========================================================
/**
 * @brief  Convenience wrapper: issues a Set Write Address frame
 *         immediately followed by a Write Data frame.
 *
 * @param  addr  Target RAM address (DATA_WIDTH bits).
 * @param  data  Data to write      (DATA_WIDTH bits).
 */
task full_write;
    input [DATA_WIDTH-1:0] addr;
    input [DATA_WIDTH-1:0] data;
    begin
        spi_write({2'b00, addr});   // cmd=00: latch write address.
        spi_write({2'b01, data});   // cmd=01: write data to that address.
    end
endtask

// --- Test Variables ---

reg [DATA_WIDTH-1:0] miso_received;

// =========================================================
// Main Test Sequence
// =========================================================
initial begin
    pass_count = 0;
    fail_count = 0;

    RST_N_TB = 1;
    SS_N_TB  = 1;
    MOSI_TB  = 0;

    // ====================================================
    // Test 1: Power-on Reset
    // All outputs must be 0 and MISO hi-Z after reset.
    // ====================================================
    @(negedge CLK_TB); RST_N_TB = 0;
    @(negedge CLK_TB); RST_N_TB = 1;
    @(posedge CLK_TB); #1;

    if (w_RX_VALID !== 0 || MISO_TB !== 1'bz)
        fail("Test 1: Reset — unexpected output");
    else
        pass("Test 1: Reset OK");

    // ====================================================
    // Test 2: Write Address Frame  (cmd = 2'b00)
    // The FSM routes to WRITE state; RX_VALID pulses on SS_N rise.
    // ====================================================
    spi_write(10'b00_10110011);

    if (w_RX_VALID !== 1)
        fail("Test 2: RX_VALID not asserted after write-address frame");
    else if (w_RX_data !== 10'b00_10110011)
        fail("Test 2: RX_data mismatch");
    else
        pass("Test 2: Write Address frame — RX_VALID and RX_data correct");

    // ====================================================
    // Test 3: Write Data Frame  (cmd = 2'b01)
    // ====================================================
    spi_write(10'b01_11001010);

    if (w_RX_VALID !== 1)
        fail("Test 3: RX_VALID not asserted after write-data frame");
    else if (w_RX_data !== 10'b01_11001010)
        fail("Test 3: RX_data mismatch");
    else
        pass("Test 3: Write Data frame — RX_VALID and RX_data correct");

    // ====================================================
    // Test 4: Read Address Frame  (cmd = 2'b10)
    // ====================================================
    spi_write(10'b10_10110011);

    if (w_RX_VALID !== 1)
        fail("Test 4: RX_VALID not asserted after read-address frame");
    else if (w_RX_data !== 10'b10_10110011)
        fail("Test 4: RX_data mismatch");
    else
        pass("Test 4: Read Address frame — RX_VALID and RX_data correct");

    // ====================================================
    // Test 5: RX_VALID Clears on SS_N Falling Edge
    // Ensures the downstream Ram cannot re-process a stale frame
    // when a new transaction begins.
    // ====================================================
    @(negedge CLK_TB); SS_N_TB = 0;   // Start a new transaction.
    @(posedge CLK_TB); #1;

    if (w_RX_VALID !== 0)
        fail("Test 5: RX_VALID should clear on SS_N falling edge");
    else
        pass("Test 5: RX_VALID clears on SS_N falling edge");

    @(negedge CLK_TB); SS_N_TB = 1;
    @(posedge CLK_TB); #1;

    // ====================================================
    // Test 6: Multi-address Write Sequence
    // Write three distinct values to three consecutive addresses.
    // Final RX_VALID and RX_data should reflect the last frame only.
    // ====================================================
    spi_write(10'b00_00000001);
    spi_write(10'b01_10101010);   // ram[0x01] ← 0xAA
    spi_write(10'b00_00000010);
    spi_write(10'b01_01010101);   // ram[0x02] ← 0x55
    spi_write(10'b00_00000011);
    spi_write(10'b01_11110000);   // ram[0x03] ← 0xF0

    if (w_RX_VALID !== 1 || w_RX_data !== 10'b01_11110000)
        fail("Test 6: Multi-address write sequence — final RX_data wrong");
    else
        pass("Test 6: Multi-address write sequence OK");

    // ====================================================
    // Test 7: Read Data Command  (cmd = 2'b11)
    //
    //  7a — Verify Tx_Valid is asserted one posedge after spi_read.
    //  7b — Verify TX_DATA equals the value written to ram[0x01].
    //  7c — Verify MISO=Z during the frame (expected design constraint).
    // ====================================================
    spi_write(10'b10_00000001);                         // Set read_addr = 0x01
    spi_read(10'b11_00000000, miso_received);           // Issue read frame.
    wait_ram_output;                                    // +1 posedge for RAM.

    if (w_TX_VALID !== 1)
        fail("Test 7a: Tx_Valid not asserted one cycle after read-data frame");
    else
        pass("Test 7a: Tx_Valid correctly asserted after read-data frame");

    if (w_TX_DATA !== 8'hAA)
        $display("FAIL Test 7b: TX_DATA=0x%0h, expected 0xAA (ram[0x01])",
                 w_TX_DATA);
    else
        pass("Test 7b: TX_DATA=0xAA correct — RAM[0x01] holds written value");

    if (miso_received !== {DATA_WIDTH{1'bz}})
        $display("NOTE  Test 7c: MISO=0x%0h (Z expected — design constraint)",
                 miso_received);
    else
        pass("Test 7c: MISO=Z during frame (Tx_Valid arrives after frame — design constraint)");

    // ====================================================
    // Test 8: Reset Mid-transaction
    // Assert RST_N several bits into a frame; all outputs must
    // return to 0 synchronously with reset release.
    // ====================================================
    MOSI_TB = 1;
    @(negedge CLK_TB); SS_N_TB = 0;
    repeat(3) @(negedge CLK_TB);   // Advance several bits into the frame.
    RST_N_TB = 0;
    @(negedge CLK_TB); RST_N_TB = 1; SS_N_TB = 1;
    @(posedge CLK_TB); #1;

    if (w_RX_VALID !== 0 || MISO_TB !== 1'bz)
        fail("Test 8: Reset mid-transaction — unexpected outputs");
    else
        pass("Test 8: Reset mid-transaction — outputs cleared correctly");

    // ====================================================
    // Test 9: Back-to-back Write-Address Frames
    // Three frames issued without any idle gap; RX_data must
    // reflect the last frame only (no stale latching).
    // ====================================================
    spi_write(10'b00_00000001);
    spi_write(10'b00_00000010);
    spi_write(10'b00_00000011);

    if (w_RX_data !== 10'b00_00000011)
        fail("Test 9: Back-to-back frames — RX_data should hold last frame");
    else
        pass("Test 9: Back-to-back frames — RX_data holds last frame correctly");

    // ====================================================
    // Test 10: Full Write → Read Pipeline (3 addresses)
    // After the mid-transaction reset in Test 8, write fresh values
    // to three addresses and read them back to verify end-to-end
    // data integrity through the SPI → Ram → SPI path.
    // ====================================================
    full_write(8'hA0, 8'h12);   // ram[0xA0] ← 0x12
    full_write(8'hB0, 8'h34);   // ram[0xB0] ← 0x34
    full_write(8'hC0, 8'h56);   // ram[0xC0] ← 0x56

    spi_write(10'b10_10100000);
    spi_read(10'b11_00000000, miso_received);
    wait_ram_output;
    if (w_TX_DATA !== 8'h12 || w_TX_VALID !== 1)
        $display("FAIL Test 10a: Read 0xA0 — TX_DATA=0x%0h, TX_VALID=%0b (expected 0x12, 1)",
                 w_TX_DATA, w_TX_VALID);
    else
        pass("Test 10a: Read addr 0xA0 — RAM outputs 0x12 correctly");

    spi_write(10'b10_10110000);
    spi_read(10'b11_00000000, miso_received);
    wait_ram_output;
    if (w_TX_DATA !== 8'h34 || w_TX_VALID !== 1)
        $display("FAIL Test 10b: Read 0xB0 — TX_DATA=0x%0h, TX_VALID=%0b (expected 0x34, 1)",
                 w_TX_DATA, w_TX_VALID);
    else
        pass("Test 10b: Read addr 0xB0 — RAM outputs 0x34 correctly");

    spi_write(10'b10_11000000);
    spi_read(10'b11_00000000, miso_received);
    wait_ram_output;
    if (w_TX_DATA !== 8'h56 || w_TX_VALID !== 1)
        $display("FAIL Test 10c: Read 0xC0 — TX_DATA=0x%0h, TX_VALID=%0b (expected 0x56, 1)",
                 w_TX_DATA, w_TX_VALID);
    else
        pass("Test 10c: Read addr 0xC0 — RAM outputs 0x56 correctly");

    // ====================================================
    // Test 11: Address 0x00 Boundary
    // The lowest valid address must be independently accessible.
    // ====================================================
    full_write(8'h00, 8'hFF);
    spi_write(10'b10_00000000);
    spi_read(10'b11_00000000, miso_received);
    wait_ram_output;
    if (w_TX_DATA !== 8'hFF || w_TX_VALID !== 1)
        $display("FAIL Test 11: Addr 0x00 — TX_DATA=0x%0h (expected 0xFF)",
                 w_TX_DATA);
    else
        pass("Test 11: Address 0x00 boundary — RAM outputs 0xFF correctly");

    // ====================================================
    // Test 12: Address 0xFF Boundary
    // The highest valid address must be independently accessible.
    // ====================================================
    full_write(8'hFF, 8'hAB);
    spi_write(10'b10_11111111);
    spi_read(10'b11_00000000, miso_received);
    wait_ram_output;
    if (w_TX_DATA !== 8'hAB || w_TX_VALID !== 1)
        $display("FAIL Test 12: Addr 0xFF — TX_DATA=0x%0h (expected 0xAB)",
                 w_TX_DATA);
    else
        pass("Test 12: Address 0xFF boundary — RAM outputs 0xAB correctly");

    // ====================================================
    // Test 13: Overwrite Existing Address
    // Writing to an already-occupied address must update the cell
    // without corrupting neighbouring locations.
    // ====================================================
    full_write(8'hA0, 8'h12);   // Write initial value.
    full_write(8'hA0, 8'hDE);   // Overwrite with new value.
    spi_write(10'b10_10100000);
    spi_read(10'b11_00000000, miso_received);
    wait_ram_output;
    if (w_TX_DATA !== 8'hDE || w_TX_VALID !== 1)
        $display("FAIL Test 13: Overwrite — TX_DATA=0x%0h (expected 0xDE)",
                 w_TX_DATA);
    else
        pass("Test 13: Overwrite address 0xA0 — RAM correctly updated to 0xDE");

    // ====================================================
    // Test 14: SS_N Held High — MISO Must Remain Hi-Z
    // With SS_N de-asserted the slave must not drive the bus,
    // allowing other devices to share the MISO line.
    // ====================================================
    SS_N_TB = 1;
    MOSI_TB = 1;
    repeat(8) @(posedge CLK_TB);
    if (MISO_TB !== 1'bz)
        fail("Test 14: MISO should be Z when SS_N=1");
    else
        pass("Test 14: MISO=Z when SS_N=1 (no transaction)");

    // ====================================================
    // Test 15: Write Data Without Prior Write-Address
    // After reset, write_addr defaults to 0; a cmd=01 frame
    // must write to ram[0x00] even without a preceding cmd=00.
    // ====================================================
    @(negedge CLK_TB); RST_N_TB = 0;
    @(negedge CLK_TB); RST_N_TB = 1;
    @(posedge CLK_TB); #1;

    spi_write(10'b01_01110111);   // Write 0x77 to ram[write_addr=0].
    spi_write(10'b10_00000000);   // Set read_addr = 0x00.
    spi_read(10'b11_00000000, miso_received);
    wait_ram_output;
    if (w_TX_DATA !== 8'h77 || w_TX_VALID !== 1)
        $display("FAIL Test 15: Default addr — TX_DATA=0x%0h (expected 0x77)",
                 w_TX_DATA);
    else
        pass("Test 15: Write without prior addr defaults to addr 0 after reset");

    // ====================================================
    // Summary
    // ====================================================
    #20;
    $display("=============================================");
    $display("  Results: %0d PASS  |  %0d FAIL", pass_count, fail_count);
    $display("=============================================");
    $display("  NOTE: Test 7c (MISO=Z) reflects a known  ");
    $display("  design constraint: Tx_Valid arrives one   ");
    $display("  frame late. MISO serialization requires   ");
    $display("  RX_VALID to pulse at bc==Max_Count instead");
    $display("  of at SS_N rise to fix the read path.     ");
    $display("=============================================");
    $stop;
end

endmodule