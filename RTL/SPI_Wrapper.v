/**
 * @file    SPI_Wrapper.v
 * @author  [Omar Mohamed Eid]
 * @date    2025
 *
 * @brief   Top-level integration wrapper connecting SPI_SLAVE to the Ram.
 *
 * @details This module forms the complete SPI-accessible memory subsystem
 *          by connecting the SPI_SLAVE receiver/transmitter directly to the
 *          command-driven Ram module.  The wrapper itself contains no logic;
 *          it exists solely to define the external SPI bus interface and
 *          route the internal handshake signals.
 *
 *          Data flow:
 *            SPI Master  ──MOSI──►  SPI_SLAVE  ──RX_data/RX_VALID──►  Ram
 *            SPI Master  ◄─MISO──   SPI_SLAVE  ◄──TX_DATA/TX_VALID──   Ram
 *
 *          The 10-bit RX_data bus encodes both the command opcode and the
 *          payload, decoded by the Ram module on each RX_VALID pulse:
 *
 *            RX_data[9:8] = 2'b00 → Ram: latch write address
 *            RX_data[9:8] = 2'b01 → Ram: write data to stored address
 *            RX_data[9:8] = 2'b10 → Ram: latch read address
 *            RX_data[9:8] = 2'b11 → Ram: output data; assert Tx_Valid
 *
 *          TX_VALID latency note:
 *            Tx_Valid from the Ram is a registered output that becomes
 *            valid one cycle after the Ram processes the 2'b11 command.
 *            Because RX_VALID itself is latched on SS_N's rising edge,
 *            Tx_Valid arrives AFTER the current SPI frame ends.  MISO
 *            will therefore be hi-Z during the read frame; a second
 *            dedicated SPI read frame is required to retrieve the data.
 *
 * @param   DATA_WIDTH  Width of each RAM word and SPI payload (default: 8)
 * @param   ADDR_WIDTH  Width of the RAM address bus            (default: 8)
 *
 * ┌──────────────────────────────────────────────────────────────────┐
 * │                         Port List                                │
 * │  Port   │ Width │ Direction │ Description                        │
 * │─────────┼───────┼───────────┼─────────────────────────────────── │
 * │  CLK    │  1    │  input    │ System clock (shared by all sub-   │
 * │         │       │           │ modules)                           │
 * │  RST_N  │  1    │  input    │ Active-low asynchronous reset      │
 * │  MOSI   │  1    │  input    │ SPI: Master-out / Slave-in         │
 * │  SS_N   │  1    │  input    │ SPI: Active-low chip select        │
 * │  MISO   │  1    │  output   │ SPI: Master-in / Slave-out         │
 * └──────────────────────────────────────────────────────────────────┘
 */

module SPI_Wrapper #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 8
) (
    input wire CLK,
    input wire RST_N,
    input wire MOSI,
    input wire SS_N,
    output wire MISO
);

// --- Internal Handshake Signals ---

/// Received frame bus: {opcode[1:0], payload[DATA_WIDTH-1:0]}.
/// Valid for one clock cycle after SS_N rises (pulsed by SPI_SLAVE).
wire [DATA_WIDTH+1:0] RX_data;

/// Strobe from SPI_SLAVE: high for one cycle when RX_data is valid.
wire RX_VALID;

/// Strobe from Ram: high for one cycle when TX_DATA holds valid read data.
wire TX_VALID;

/// Parallel read data from Ram; serialised onto MISO by SPI_SLAVE.
wire [DATA_WIDTH-1:0] TX_DATA;

// --- SPI Slave Instantiation ---
/// Deserialises the incoming MOSI bitstream into 10-bit frames and
/// serialises TX_DATA from the Ram back onto MISO.
SPI_SLAVE #(
    .DATA_WIDTH(DATA_WIDTH)
) spi_slave_inst (
    .CLK      (CLK),
    .RST_N    (RST_N),
    .MOSI     (MOSI),
    .SS_N     (SS_N),
    .TX_DATA  (TX_DATA),
    .TX_VALID (TX_VALID),
    .MISO     (MISO),
    .RX_VALID (RX_VALID),
    .RX_data  (RX_data)
);

// --- RAM Instantiation ---
/// Decodes the command in RX_data, performs the requested read or write
/// operation, and drives TX_DATA / TX_VALID to the SPI slave on reads.
Ram #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH)
) ram_inst (
    .CLK      (CLK),
    .RST_N    (RST_N),
    .DATA_IN  (RX_data),
    .Rx_Valid (RX_VALID),
    .Tx_Valid (TX_VALID),
    .DATA_OUT (TX_DATA)
);

endmodule