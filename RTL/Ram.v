/**
 * @file    Ram.v
 * @author  [Omar Mohamed Eid]
 * @date    2025
 *
 * @brief   Synchronous single-port RAM with a command-driven interface.
 *
 * @details This module implements a 256-deep, 8-bit-wide RAM that is
 *          controlled via a 10-bit command bus (DATA_IN[9:8] = opcode,
 *          DATA_IN[7:0] = address or data payload).  It is designed to
 *          sit downstream of the SPI_SLAVE receiver in the SPI_Wrapper
 *          system; Rx_Valid is driven by the SPI slave's RX_VALID output.
 *
 * @param   DATA_WIDTH  Width of each RAM word in bits  (default: 8)
 * @param   ADDR_WIDTH  Width of the address bus in bits (default: 8)
 * @param   DEPTH       Number of addressable locations  (default: 256)
 *
 * ┌──────────────────────────────────────────────────────────────────┐
 * │                     DATA_IN Command Encoding                     │
 * │  Bits [9:8]  │  Operation        │  Bits [7:0] Meaning           │
 * │──────────────┼───────────────────┼────────────────────────────── │
 * │  2'b00       │  Set Write Addr   │  Address to latch             │
 * │  2'b01       │  Write Data       │  Data written to write_addr   │
 * │  2'b10       │  Set Read Addr    │  Address to latch             │
 * │  2'b11       │  Read Data        │  Ignored; triggers read       │
 * └──────────────────────────────────────────────────────────────────┘
 *
 * ┌──────────────────────────────────────────────────────────────────┐
 * │                         Port List                                │
 * │  Port        │ Width          │ Direction │ Description          │
 * │──────────────┼────────────────┼───────────┼──────────────────────│
 * │  CLK         │  1             │  input    │ System clock         │
 * │  RST_N       │  1             │  input    │ Active-low async rst │
 * │  DATA_IN     │  DATA_WIDTH+2  │  input    │ Command + payload    │
 * │  Rx_Valid    │  1             │  input    │ Strobe: DATA_IN valid│
 * │  Tx_Valid    │  1             │  output   │ DATA_OUT is valid    │
 * │  DATA_OUT    │  DATA_WIDTH    │  output   │ Read data to SPI TX  │
 * └──────────────────────────────────────────────────────────────────┘
 */

module Ram #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 8,
    parameter DEPTH = 256
) (
    input wire CLK,
    input wire RST_N,
    input wire [DATA_WIDTH+1:0] DATA_IN,
    input wire Rx_Valid,

    output reg Tx_Valid,
    output reg [DATA_WIDTH-1:0] DATA_OUT
);

// --- Internal Storage & Address Registers ---

/// Backing array: DEPTH words, each DATA_WIDTH bits wide.
reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

/// Registered write address; latched by the 2'b00 command.
reg [ADDR_WIDTH-1:0] write_addr;

/// Registered read address; latched by the 2'b10 command.
reg [ADDR_WIDTH-1:0] read_addr;

integer i;  // Loop variable used only during synchronous reset.

// --- Command Decode & RAM Operation ---
/**
 * All RAM operations are sequenced on the rising clock edge.
 * An asynchronous active-low reset clears all storage and control
 * registers so the module reaches a known state without requiring
 * a clock edge — important for power-on and mid-transaction recovery.
 *
 * When Rx_Valid is asserted, DATA_IN[DATA_WIDTH+1:DATA_WIDTH] selects
 * one of four operations.  When Rx_Valid is de-asserted, all outputs
 * are cleared; this ensures Tx_Valid is only high for exactly one
 * cycle per read command, preventing false data captures downstream.
 */
always @(posedge CLK or negedge RST_N) begin
    if (!RST_N) begin
        write_addr <= 0;
        read_addr  <= 0;
        DATA_OUT   <= 0;
        Tx_Valid   <= 0;
        // Zero-initialise every cell so simulation and post-reset
        // reads return 0 rather than 'X' (avoids metastability in SIM).
        for (i = 0; i < DEPTH; i = i + 1) begin
            ram[i] <= 0;
        end
    end
    else if (Rx_Valid) begin

        // Decode the two most-significant bits as the operation code.
        case (DATA_IN[DATA_WIDTH+1:DATA_WIDTH])

            // 2'b00 — Latch Write Address
            // Lower DATA_WIDTH bits become the target address for the
            // next Write Data command.  No data is written here.
            2'b00: begin
                write_addr <= DATA_IN[DATA_WIDTH-1:0];
            end

            // 2'b01 — Write Data
            // Write the payload to the previously latched write_addr.
            // Address is NOT auto-incremented; a new Set Write Addr
            // command is required before each write to a new location.
            2'b01: begin
                ram[write_addr] <= DATA_IN[DATA_WIDTH-1:0];
            end

            // 2'b10 — Latch Read Address
            // Lower DATA_WIDTH bits become the target address for the
            // next Read Data command.
            2'b10: begin
                read_addr <= DATA_IN[DATA_WIDTH-1:0];
            end

            // 2'b11 — Read Data
            // Drive DATA_OUT with the word at read_addr and assert
            // Tx_Valid for one cycle to notify the SPI TX path.
            // DATA_IN[DATA_WIDTH-1:0] is intentionally ignored here.
            2'b11: begin
                DATA_OUT <= ram[read_addr];
                Tx_Valid <= 1;
            end

            // Default — no recognised command
            // Suppress outputs and hold addresses to prevent
            // unintended writes or spurious Tx_Valid pulses.
            default: begin
                write_addr <= write_addr;
                read_addr  <= read_addr;
                DATA_OUT   <= 0;
                Tx_Valid   <= 0;
            end

        endcase

    end
    else begin
        // Rx_Valid de-asserted: clear output signals.
        // Holding write_addr / read_addr preserves the last latched
        // addresses so back-to-back write or read sequences remain valid.
        write_addr <= write_addr;
        read_addr  <= read_addr;
        DATA_OUT   <= 0;
        Tx_Valid   <= 0;
    end
end

endmodule