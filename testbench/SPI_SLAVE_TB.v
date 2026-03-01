/**
 * @file    SPI_SLAVE_TB.v
 * @author  [Omar Mohamed Eid]
 * @date    2025
 *
 * @brief   Self-checking testbench for the SPI_SLAVE module.
 *
 * @details Drives the SPI_SLAVE DUT with bit-accurate SPI frames using
 *          two reusable tasks (spi_write / spi_read) and verifies all
 *          major functional paths:
 *
 *          Test plan:
 *            1.  Reset
 *            2.  Write Address frame  (cmd = 2'b00)
 *            3.  Write Data frame     (cmd = 2'b01)
 *            4.  Read Address frame   (cmd = 2'b10)
 *            5.  Read Data frame      (cmd = 2'b11) — MISO capture
 *            6.  TX_VALID low → MISO must remain hi-Z
 *            7.  RX_VALID clears while SS_N = 0
 *            8.  Reset asserted mid-transaction
 *            9.  SS_N held high — no spurious activity
 *           10.  Back-to-back transactions
 *           11.  Delayed TX_VALID (simulates one-cycle RAM latency)
 *
 * @note    Task timing contract:
 *          spi_write() returns exactly one posedge after SS_N rises;
 *          at that point RX_VALID is guaranteed stable (registered latch).
 *          spi_read() samples MISO on each posedge after the command bits
 *          are consumed; no extra wait cycle is needed before capture.
 */

`timescale 1ns/1ps

module SPI_SLAVE_TB();

// --- Parameters ---

parameter DATA_WIDTH = 8;
parameter CLK_PERIOD = 10;  ///< 100 MHz

// --- DUT Interface Signals ---

reg CLK_TB, RST_N_TB, MOSI_TB, SS_N_TB;
reg [DATA_WIDTH-1:0] TX_DATA_TB;
reg TX_VALID_TB;

wire MISO_TB;
wire RX_VALID_TB;
wire [DATA_WIDTH+1:0] RX_data_TB;

// --- DUT Instantiation ---

SPI_SLAVE #(.DATA_WIDTH(DATA_WIDTH)) DUT (
    .CLK      (CLK_TB),
    .RST_N    (RST_N_TB),
    .MOSI     (MOSI_TB),
    .SS_N     (SS_N_TB),
    .TX_DATA  (TX_DATA_TB),
    .TX_VALID (TX_VALID_TB),
    .MISO     (MISO_TB),
    .RX_VALID (RX_VALID_TB),
    .RX_data  (RX_data_TB)
);

// --- Clock Generation ---

initial CLK_TB = 0;
/// Toggle every half-period to produce CLK_PERIOD frequency.
always #(CLK_PERIOD/2) CLK_TB = ~CLK_TB;

// =========================================================
// Task: spi_write
// =========================================================
/**
 * @brief  Transmits a full (DATA_WIDTH+2)-bit SPI frame to the DUT.
 *
 * @param  data  Full frame: {cmd[1:0], payload[DATA_WIDTH-1:0]}
 *
 * Timing contract:
 *   - The MSB of 'data' is driven BEFORE the first negedge so it
 *     is stable when SS_N asserts.
 *   - Each subsequent bit is applied on a negedge (setup before
 *     the following posedge) to meet SPI Mode-0 hold requirements.
 *   - SS_N de-asserts one negedge after the last bit is shifted.
 *   - The task returns one posedge after SS_N rises, at which point
 *     the registered RX_VALID latch is guaranteed to have updated.
 *
 * Fix vs. original:
 *   Replaced the time-based #(CLK_PERIOD) end-wait with an explicit
 *   @(posedge CLK_TB); #1 to ensure the check always occurs after
 *   the same clock edge on which the latch fires, eliminating a
 *   race condition when the period is small relative to sim delta.
 */
task spi_write;
    input [DATA_WIDTH+1:0] data;
    begin
        MOSI_TB = data[DATA_WIDTH+1];   // Pre-drive MSB before SS_N asserts.
        @(negedge CLK_TB);
        SS_N_TB = 0;                    // Start of transaction.

        begin : write_loop
            integer i;
            for (i = DATA_WIDTH; i >= 0; i = i - 1) begin
                @(negedge CLK_TB);
                MOSI_TB = data[i];      // Present each bit before posedge.
            end
        end

        @(negedge CLK_TB);
        SS_N_TB = 1;    // End of transaction; RX_VALID will latch this cycle.
        MOSI_TB = 0;
        @(posedge CLK_TB); #1;  // Settle: RX_VALID is valid at this point.
    end
endtask

// =========================================================
// Task: spi_read
// =========================================================
/**
 * @brief  Transmits a READ_DATA frame and captures DATA_WIDTH
 *         bits from MISO into 'received'.
 *
 * @param  data      Full frame: {2'b11, payload[DATA_WIDTH-1:0]}
 *                   (payload is a don't-care for the read command)
 * @param  received  Output register; bits captured MSB-first.
 *
 * Capture sequence (TX_VALID asserted before transaction):
 *   negedge: drive cmd_bit1, assert SS_N
 *   posedge1: IDLE → CHK_CMD,  bit_count = 1
 *   negedge: drive cmd_bit2
 *   posedge2: CHK_CMD → READ_DATA, bit_count = 2
 *   Loop (DATA_WIDTH iterations):
 *     negedge: drive dummy MOSI=0
 *     posedge: miso_shift[MSB] is combinatorially on MISO → sample here
 *   negedge: de-assert SS_N
 *   posedge: task returns
 *
 * Fix vs. original:
 *   Removed the erroneous extra @(posedge CLK_TB); #1 before the
 *   capture loop.  That extra wait consumed bit[7] before the loop
 *   started, resulting in the captured value being shifted one bit
 *   (received = expected >> 1).
 */
task spi_read;
    input  [DATA_WIDTH+1:0] data;
    output [DATA_WIDTH-1:0] received;
    begin
        received = 0;

        MOSI_TB = data[DATA_WIDTH+1];   // First command bit; presented before SS_N.
        @(negedge CLK_TB);
        SS_N_TB = 0;

        @(negedge CLK_TB);
        MOSI_TB = data[DATA_WIDTH];     // Second command bit; determines READ_DATA state.

        // Capture DATA_WIDTH bits MSB-first.
        // On posedge3 (first READ_DATA clock with miso_loaded=1),
        // miso_shift[DATA_WIDTH-1] is valid on MISO combinatorially.
        begin : capture_loop
            integer i;
            for (i = DATA_WIDTH-1; i >= 0; i = i - 1) begin
                @(negedge CLK_TB);
                MOSI_TB = 0;            // Dummy MOSI during read.
                @(posedge CLK_TB); #1;
                received[i] = MISO_TB;  // Sample each MISO bit after posedge.
            end
        end

        @(negedge CLK_TB);
        SS_N_TB = 1;
        MOSI_TB = 0;
        @(posedge CLK_TB); #1;
    end
endtask

// --- Test Stimulus Variables ---

reg [DATA_WIDTH-1:0] miso_received;

// =========================================================
// Main Test Sequence
// =========================================================
initial begin
    RST_N_TB = 1; SS_N_TB = 1; MOSI_TB = 0;
    TX_DATA_TB = 0; TX_VALID_TB = 0;

    // ── Test 1: Reset ──────────────────────────────────────
    // Verify all outputs clear to 0 after a synchronous reset cycle.
    @(negedge CLK_TB); RST_N_TB = 0;
    @(negedge CLK_TB); RST_N_TB = 1;
    @(posedge CLK_TB); #1;
    if (RX_VALID_TB !== 0 || RX_data_TB !== 0)
        $display("FAIL Test 1: Reset — RX_VALID=%0b RX_data=%0h",
                 RX_VALID_TB, RX_data_TB);
    else
        $display("PASS Test 1: Reset OK");

    // ── Test 2: Write Address Frame  (cmd = 2'b00) ─────────
    // MSBs 2'b00 route the FSM through CHK_CMD → WRITE.
    // Expect RX_VALID=1 and RX_data matching the sent frame.
    spi_write(10'b00_10101010);
    if (RX_VALID_TB !== 1)
        $display("FAIL Test 2: RX_VALID should be HIGH, got %0b", RX_VALID_TB);
    else if (RX_data_TB !== 10'b00_10101010)
        $display("FAIL Test 2: Expected 0x0AA, Got 0x%0h", RX_data_TB);
    else
        $display("PASS Test 2: Write Address OK — RX_data=0x%0h", RX_data_TB);

    // ── Test 3: Write Data Frame  (cmd = 2'b01) ────────────
    spi_write(10'b01_11001100);
    if (RX_VALID_TB !== 1)
        $display("FAIL Test 3: RX_VALID should be HIGH, got %0b", RX_VALID_TB);
    else if (RX_data_TB !== 10'b01_11001100)
        $display("FAIL Test 3: Expected 0x1CC, Got 0x%0h", RX_data_TB);
    else
        $display("PASS Test 3: Write Data OK — RX_data=0x%0h", RX_data_TB);

    // ── Test 4: Read Address Frame  (cmd = 2'b10) ──────────
    spi_write(10'b10_10101010);
    if (RX_VALID_TB !== 1)
        $display("FAIL Test 4: RX_VALID should be HIGH, got %0b", RX_VALID_TB);
    else if (RX_data_TB !== 10'b10_10101010)
        $display("FAIL Test 4: Expected 0x2AA, Got 0x%0h", RX_data_TB);
    else
        $display("PASS Test 4: Read Address OK — RX_data=0x%0h", RX_data_TB);

    // ── Test 5: Read Data Frame  (cmd = 2'b11) — MISO Capture ──
    // TX_VALID is pre-asserted so miso_shift is latched on the first
    // READ_DATA posedge.  The spi_read task captures all 8 bits.
    TX_DATA_TB  = 8'hA5;
    TX_VALID_TB = 1;
    spi_read(10'b11_00000000, miso_received);
    TX_VALID_TB = 0;
    if (miso_received !== 8'hA5)
        $display("FAIL Test 5: MISO received=0x%0h, Expected=0xA5",
                 miso_received);
    else
        $display("PASS Test 5: Read Data OK — MISO=0x%0h", miso_received);

    // ── Test 6: TX_VALID Low — MISO Must Be Hi-Z ───────────
    // When the slave has no valid data to return, MISO must be
    // tri-stated so it cannot drive the shared bus.
    TX_DATA_TB  = 8'hFF;
    TX_VALID_TB = 0;
    spi_read(10'b11_00000000, miso_received);
    if (miso_received !== {DATA_WIDTH{1'bz}})
        $display("FAIL Test 6: MISO should be Z, Got=0x%0h", miso_received);
    else
        $display("PASS Test 6: MISO is Z when TX_VALID=0");

    // ── Test 7: RX_VALID Clears on SS_N Assertion ──────────
    // RX_VALID must clear as soon as a new transaction begins
    // (SS_N falls) to prevent the downstream RAM from processing
    // the previous frame twice.
    spi_write(10'b00_11110000);
    @(negedge CLK_TB); SS_N_TB = 0;   // Start a new (incomplete) transaction.
    @(posedge CLK_TB); #1;
    if (RX_VALID_TB !== 0)
        $display("FAIL Test 7: RX_VALID should be LOW when SS_N=0");
    else
        $display("PASS Test 7: RX_VALID clears when SS_N=0");
    @(negedge CLK_TB); SS_N_TB = 1;
    @(posedge CLK_TB); #1;

    // ── Test 8: Reset During Transaction ───────────────────
    // Assert RST_N after SS_N falls but before the frame completes.
    // All outputs must return to 0 synchronously with reset release.
    MOSI_TB = 0;
    @(negedge CLK_TB); SS_N_TB = 0;
    repeat(3) @(negedge CLK_TB);      // Advance several bits into the frame.
    RST_N_TB = 0;
    @(negedge CLK_TB); RST_N_TB = 1; SS_N_TB = 1;
    @(posedge CLK_TB); #1;
    if (RX_VALID_TB !== 0 || RX_data_TB !== 0)
        $display("FAIL Test 8: Reset mid-transaction failed");
    else
        $display("PASS Test 8: Reset mid-transaction OK");

    // ── Test 9: SS_N Held High — No Spurious Activity ──────
    // With SS_N de-asserted, MOSI transitions must not alter any
    // internal state; RX_VALID must remain 0.
    SS_N_TB = 1; MOSI_TB = 1;
    repeat(5) @(posedge CLK_TB);
    if (RX_VALID_TB !== 0)
        $display("FAIL Test 9: RX_VALID should stay LOW when SS_N=1");
    else
        $display("PASS Test 9: No operation when SS_N=1");

    // ── Test 10: Back-to-back Transactions ─────────────────
    // Three consecutive frames without any idle gap between them.
    // The final RX_data should reflect only the last frame.
    spi_write(10'b00_00001111);
    spi_write(10'b01_10110101);
    spi_write(10'b10_00001111);
    if (RX_data_TB !== 10'b10_00001111)
        $display("FAIL Test 10: Back-to-back failed, Got 0x%0h", RX_data_TB);
    else
        $display("PASS Test 10: Back-to-back transactions OK");

    // ── Test 11: Delayed TX_VALID (RAM Latency Simulation) ──
    /**
     * Simulates a one-cycle RAM read latency: TX_VALID is asserted
     * on the same negedge as the second command bit rather than
     * before the transaction, matching the SPI_Wrapper pipeline
     * where TX_VALID comes from the RAM module's Tx_Valid.
     *
     * Why no repeat() before asserting TX_VALID:
     *   TX_VALID must be set on neg2 (the negedge that presents
     *   the second command bit).  On the following posedge (pos3),
     *   the FSM transitions to READ_DATA AND sees TX_VALID=1 in the
     *   same cycle — miso_shift is latched immediately.  The capture
     *   loop's first @(negedge) → @(posedge) pair therefore samples
     *   bit[7] on pos3 correctly.
     *
     *   Using repeat(N≥1) would set TX_VALID one or more negedges
     *   later, causing the capture loop to see bit[6:0]+zero and
     *   produce received = expected >> N (e.g. 0x78 instead of 0x3C).
     */
    TX_DATA_TB  = 8'h3C;
    TX_VALID_TB = 0;
    MOSI_TB = 1;
    @(negedge CLK_TB); SS_N_TB = 0;   // First command bit (MOSI=1).
    @(negedge CLK_TB); MOSI_TB = 1;   // Second command bit → READ_DATA.
    TX_VALID_TB = 1;                   // Assert on same negedge as cmd bit 2.

    begin : capture_t11
        integer i;
        miso_received = 0;
        for (i = DATA_WIDTH-1; i >= 0; i = i - 1) begin
            @(negedge CLK_TB); MOSI_TB = 0;
            @(posedge CLK_TB); #1;
            miso_received[i] = MISO_TB;
        end
    end

    @(negedge CLK_TB); SS_N_TB = 1; TX_VALID_TB = 0; MOSI_TB = 0;
    @(posedge CLK_TB); #1;
    if (miso_received !== 8'h3C)
        $display("FAIL Test 11: Delayed TX_VALID — MISO=0x%0h, Expected=0x3C",
                 miso_received);
    else
        $display("PASS Test 11: Delayed TX_VALID handshake OK — MISO=0x%0h",
                 miso_received);

    // ── Simulation Complete ─────────────────────────────────
    #20;
    $display("=============================");
    $display("   Testbench Complete");
    $display("=============================");
    $stop;
end

endmodule