/**
 * @file    SPI_SLAVE.v
 * @author  [Omar Mohamed Eid]
 * @date    2025
 *
 * @brief   SPI Mode-0 slave receiver/transmitter with a 5-state FSM.
 *
 * @details Implements an SPI slave that accepts 10-bit frames (2-bit
 *          command + 8-bit payload) on MOSI while simultaneously
 *          streaming up to 8 bits back on MISO.
 *
 *          Frame format on MOSI:
 *            bit [9] — command bit 1 (first bit shifted in)
 *            bit [8] — command bit 2 (determines final FSM state)
 *            bits [7:0] — address or data payload
 *
 *          The FSM uses Gray encoding to minimise glitch transitions
 *          between adjacent states.
 *
 * ┌─────────────────────────────────────────────────────────────────┐
 * │                    FSM State Encoding                           │
 * │  State      │ Encoding │  Description                           │
 * │─────────────┼──────────┼─────────────────────────────────────── │
 * │  IDLE       │  3'b000  │  Waiting for SS_N to assert (go LOW)   │
 * │  CHK_CMD    │  3'b001  │  Sampling the two command bits         │
 * │  WRITE      │  3'b011  │  Receiving write-address / write-data  │
 * │  READ_ADDR  │  3'b010  │  Receiving read-address payload        │
 * │  READ_DATA  │  3'b110  │  Driving MISO; receiving dummy bits    │
 * └─────────────────────────────────────────────────────────────────┘
 *
 *          RX_VALID / RX_data design note:
 *            RX_VALID is latched on the rising edge of SS_N (end of
 *            transaction) rather than on bit_count == Max_Count.  This
 *            eliminates a one-cycle race where the state machine would
 *            return to IDLE before SS_N rose, preventing the latch from
 *            ever seeing a data state.  States return to IDLE exclusively
 *            when SS_N is high.
 *
 * ┌──────────────────────────────────────────────────────────────────┐
 * │                         Port List                                │
 * │  Port      │ Width          │ Dir    │ Description               │
 * │────────────┼────────────────┼────────┼───────────────────────────│
 * │  CLK       │  1             │ in     │ System clock              │
 * │  RST_N     │  1             │ in     │ Active-low async reset    │
 * │  MOSI      │  1             │ in     │ Master-out / Slave-in     │
 * │  SS_N      │  1             │ in     │ Active-low chip select    │
 * │  TX_DATA   │  DATA_WIDTH    │ in     │ Data to serialise on MISO │
 * │  TX_VALID  │  1             │ in     │ TX_DATA is valid / ready  │
 * │  MISO      │  1             │ out    │ Master-in / Slave-out     │
 * │  RX_VALID  │  1             │ out    │ RX_data is valid (1 clk)  │
 * │  RX_data   │  DATA_WIDTH+2  │ out    │ Received frame {cmd,data} │
 * └──────────────────────────────────────────────────────────────────┘
 */

module SPI_SLAVE #(
    parameter DATA_WIDTH = 8
)(
    input wire                      CLK,
    input wire                      RST_N,
    input wire                      MOSI,
    input wire                      SS_N,
    input wire   [DATA_WIDTH-1:0]   TX_DATA,
    input wire                      TX_VALID,
    output reg                      MISO,
    output reg                      RX_VALID,
    output reg   [DATA_WIDTH+1:0]   RX_data
);

// --- FSM State Encoding (Gray Code) ---
/// Gray-encoded states minimise the number of bit transitions between
/// adjacent states, reducing the likelihood of glitch-driven misfires
/// in downstream combinational logic.
localparam [2:0] IDLE      = 3'b000,
                 CHK_CMD   = 3'b001,
                 WRITE     = 3'b011,
                 READ_ADDR = 3'b010,
                 READ_DATA = 3'b110;

/// Total bits per frame = DATA_WIDTH payload + 2 command bits - 1 (0-indexed).
localparam [3:0] Max_Count = DATA_WIDTH + 1;   // = 9 for DATA_WIDTH=8

// --- Internal Registers ---

reg [2:0] Current_state, Next_state;

/// Counts the bit position within the current frame (0 to Max_Count).
reg [3:0] bit_count;

/// Accumulates incoming MOSI bits; MSB is shifted in last.
reg [DATA_WIDTH+1:0] shift_reg;

/// Holds TX_DATA after it is latched in READ_DATA; shifted MSB-first to MISO.
reg [DATA_WIDTH-1:0] miso_shift;

/// Set once TX_DATA has been latched into miso_shift to prevent re-latching
/// on subsequent clock edges within the same READ_DATA transaction.
reg                  miso_loaded;

/// Captures SS_N one cycle earlier to detect the rising-edge event.
reg                  ss_n_prev;

// =========================================================
// Sequential: FSM State Register
// =========================================================
/// State updates on every rising clock edge; asynchronous reset
/// forces the machine to IDLE regardless of current inputs.
always @ (posedge CLK or negedge RST_N) begin
    if (!RST_N)
        Current_state <= IDLE;
    else
        Current_state <= Next_state;
end

// =========================================================
// Sequential: Bit Counter
// =========================================================
/// Counts the number of MOSI bits received in the current frame.
/// Reset to 0 whenever SS_N is high (no active transaction) or
/// when the maximum count is reached, ready for the next frame.
always @ (posedge CLK or negedge RST_N) begin
    if (!RST_N)
        bit_count <= 0;
    else if (SS_N)                         // Chip de-selected: reset counter.
        bit_count <= 0;
    else if (bit_count == Max_Count)       // End of frame: wrap to 0.
        bit_count <= 0;
    else
        bit_count <= bit_count + 1;        // Increment on each active clock.
end

// =========================================================
// Sequential: MOSI Shift Register
// =========================================================
/// Shifts MOSI data in MSB-first while SS_N is asserted.
/// The accumulated value in shift_reg represents the complete
/// received frame (command bits + payload) at end-of-transaction.
always @ (posedge CLK or negedge RST_N) begin
    if (!RST_N)
        shift_reg <= 0;
    else if (!SS_N)
        shift_reg <= {shift_reg[DATA_WIDTH:0], MOSI};
end

// =========================================================
// Sequential: MISO Shift Register
// =========================================================
/**
 * Controls the serialisation of TX_DATA onto MISO during a
 * READ_DATA transaction.
 *
 * Latch policy:
 *   TX_DATA is captured into miso_shift on the first rising clock
 *   edge where TX_VALID is asserted while in READ_DATA.  Subsequent
 *   edges shift miso_shift left, presenting bits MSB-first on MISO.
 *   The miso_loaded flag prevents re-latching if TX_VALID stays
 *   high for multiple cycles (e.g. registered RAM output).
 *
 * Reset / clear:
 *   miso_shift and miso_loaded are cleared on reset OR whenever
 *   the FSM leaves READ_DATA (SS_N rises or state changes).
 *   This guarantees MISO returns to high-impedance between frames.
 */
always @ (posedge CLK or negedge RST_N) begin
    if (!RST_N) begin
        miso_shift  <= 0;
        miso_loaded <= 0;
    end
    else if (SS_N || Current_state != READ_DATA) begin
        // Transaction ended or wrong state: discard any partial output.
        miso_shift  <= 0;
        miso_loaded <= 0;
    end
    else if (!miso_loaded && TX_VALID) begin
        // First valid TX_DATA seen in READ_DATA: latch it for serialisation.
        miso_shift  <= TX_DATA;
        miso_loaded <= 1;
    end
    else if (miso_loaded) begin
        // Shift left each cycle so the next MSB appears at [DATA_WIDTH-1].
        miso_shift  <= {miso_shift[DATA_WIDTH-2:0], 1'b0};
        miso_loaded <= 1;
    end
end

// =========================================================
// Sequential: RX_VALID / RX_data Output Latch
// =========================================================
/**
 * Latches the received frame on the rising edge of SS_N.
 *
 * Design rationale:
 *   A purely combinational RX_VALID that tracks the current FSM
 *   state creates a race: by the time SS_N rises, the state machine
 *   may have already returned to IDLE (if it was driven by
 *   bit_count == Max_Count), making the output zero when the
 *   downstream module samples it.
 *
 *   Instead, ss_n_prev records SS_N one cycle earlier.  When
 *   SS_N=1 && ss_n_prev=0 (rising edge), the current state still
 *   reflects the final data state (WRITE / READ_ADDR / READ_DATA),
 *   allowing a clean one-cycle RX_VALID pulse with the correct data.
 *
 *   RX_VALID is cleared as soon as SS_N goes low (new transaction
 *   begins), preventing false re-reads on subsequent cycles.
 */
always @ (posedge CLK or negedge RST_N) begin
    if (!RST_N) begin
        ss_n_prev <= 1;
        RX_VALID  <= 0;
        RX_data   <= 0;
    end
    else begin
        ss_n_prev <= SS_N;   // Track SS_N to detect rising edge next cycle.

        if (SS_N && !ss_n_prev) begin
            // SS_N rising edge: transaction just completed.
            // Assert RX_VALID only if the frame ended in a data state;
            // a CHK_CMD-only transaction (too short) is silently discarded.
            if (Current_state == WRITE     ||
                Current_state == READ_ADDR ||
                Current_state == READ_DATA) begin
                RX_VALID <= 1;
                RX_data  <= shift_reg;
            end
            else begin
                RX_VALID <= 0;
                RX_data  <= 0;
            end
        end
        else if (!SS_N) begin
            // SS_N asserted (transaction in progress): clear previous result
            // so the downstream module cannot latch stale data.
            RX_VALID <= 0;
            RX_data  <= 0;
        end
        // SS_N remains high between transactions: hold RX_VALID steady
        // so the downstream RAM has at least one full clock cycle to sample.
    end
end

// =========================================================
// Combinational: Next-State Logic
// =========================================================
/**
 * State transitions are driven exclusively by SS_N and MOSI,
 * NOT by bit_count reaching Max_Count.
 *
 * Removing the bit_count-based return-to-IDLE condition was
 * critical: previously, the state reverted to IDLE one cycle
 * before SS_N rose, so the RX_VALID latch above always observed
 * IDLE and never fired.  The state now stays in the current
 * data state until SS_N rises, matching the SPI spec intent that
 * SS_N defines transaction boundaries.
 */
always @ (*) begin
    case (Current_state)

        IDLE:
            // Enter CHK_CMD on the first active-low assertion of SS_N.
            Next_state = (!SS_N) ? CHK_CMD : IDLE;

        CHK_CMD: begin
            if (SS_N)
                Next_state = IDLE;                        // Aborted frame.
            else if (bit_count == 0)
                // First command bit: 0 → WRITE path, wait for second bit.
                Next_state = (!MOSI) ? WRITE : CHK_CMD;
            else if (bit_count == 1)
                // Second command bit: 0 → READ_ADDR, 1 → READ_DATA.
                Next_state = (!MOSI) ? READ_ADDR : READ_DATA;
            else
                Next_state = CHK_CMD;                     // Still sampling.
        end

        WRITE:
            // Remain in WRITE until the master de-asserts SS_N.
            Next_state = SS_N ? IDLE : WRITE;

        READ_ADDR:
            // Remain in READ_ADDR until the master de-asserts SS_N.
            Next_state = SS_N ? IDLE : READ_ADDR;

        READ_DATA:
            // Remain in READ_DATA, streaming MISO, until SS_N rises.
            Next_state = SS_N ? IDLE : READ_DATA;

        default: Next_state = IDLE;

    endcase
end

// =========================================================
// Combinational: Output Logic — MISO
// =========================================================
/**
 * MISO is driven only in READ_DATA state and only after TX_DATA
 * has been latched (miso_loaded == 1).  In all other states, MISO
 * is tri-stated (1'bz) so the master can share the MISO line with
 * other slaves without bus contention.
 *
 * Note: RX_VALID and RX_data are driven by the registered block
 *       above, not here, to ensure glitch-free one-cycle pulses.
 */
always @ (*) begin
    case (Current_state)
        READ_DATA : MISO = miso_loaded ? miso_shift[DATA_WIDTH-1] : 1'bz;
        default   : MISO = 1'bz;
    endcase
end

endmodule