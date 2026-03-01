# SPI Slave with Single-Port RAM

![Vivado](https://img.shields.io/badge/Vivado-2025.2-blue?logo=amd)
![Device](https://img.shields.io/badge/Device-xc7a35tcpg236--2L-orange)
![Family](https://img.shields.io/badge/Family-Artix--7-green)
![Language](https://img.shields.io/badge/HDL-Verilog-blueviolet)
![DRC](https://img.shields.io/badge/DRC-0%20Violations-brightgreen)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

A fully synthesised and implemented **SPI Mode-0 Slave** interfaced with a **256×8-bit single-port RAM** on a Xilinx Artix-7 FPGA. The design accepts 10-bit command frames over SPI and performs addressed read/write operations on the internal memory array. The entire pipeline — deserialisation, command decoding, memory access, and re-serialisation — is implemented in synthesisable RTL Verilog with no vendor IP dependencies.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Design Diagrams](#design-diagrams)
- [SPI Frame Protocol](#spi-frame-protocol)
- [File Structure](#file-structure)
- [FPGA Implementation](#fpga-implementation)
  - [Device & Toolchain](#device--toolchain)
  - [Resource Utilization](#resource-utilization)
  - [Power Analysis](#power-analysis)
  - [DRC & Methodology](#drc--methodology)
- [Design Schematics](#design-schematics)
- [Constraints](#constraints)
- [How to Simulate](#how-to-simulate)
- [How to Synthesise & Implement](#how-to-synthesise--implement)
- [Known Limitations](#known-limitations)

---

## Architecture Overview

The top-level `SPI_Wrapper` module connects two sub-modules in a direct pipeline. The SPI_SLAVE deserialises incoming MOSI bits into 10-bit frames and passes them to the RAM via the `RX_data` / `RX_VALID` handshake. The RAM decodes the opcode, performs the requested operation, and drives `TX_DATA` / `TX_VALID` back to the SPI_SLAVE for serialisation onto MISO.

![Block Diagram](https://github.com/OmarEid66/SPI_Slave_with_Single_Port_RAM/blob/main/Screenshots/Block_Diagram.png)

| Signal        | Width | Direction         | Description                              |
|---------------|-------|-------------------|------------------------------------------|
| `MOSI`        | 1     | Master → Slave    | Serial data input                        |
| `MISO`        | 1     | Slave → Master    | Serial data output (hi-Z when inactive)  |
| `SS_N`        | 1     | Master → Slave    | Active-low chip select                   |
| `CLK`         | 1     | Shared            | System clock (100 MHz)                   |
| `RST_N`       | 1     | Shared            | Active-low asynchronous reset            |
| `rx_data`     | 10    | SPI_SLAVE → RAM   | Deserialised frame `{cmd[1:0], data[7:0]}` |
| `rx_valid`    | 1     | SPI_SLAVE → RAM   | Strobe: `rx_data` is valid for one cycle |
| `tx_data`     | 8     | RAM → SPI_SLAVE   | Read data to serialise onto MISO         |
| `tx_valid`    | 1     | RAM → SPI_SLAVE   | Strobe: `tx_data` is valid               |

---

### SPI_SLAVE FSM

The SPI slave is controlled by a 5-state **Gray-encoded** FSM. The state transitions are driven exclusively by `SS_N` and the incoming `MOSI` command bits — **not** by `bit_count` reaching `Max_Count`. This ensures `RX_VALID` always latches on SS_N's rising edge while the FSM is still in a data state, eliminating a one-cycle race condition.

![FSM Diagram](https://github.com/OmarEid66/SPI_Slave_with_Single_Port_RAM/blob/main/Screenshots/FSM_Diagram.png)

| State       | Encoding | Description                                      |
|-------------|----------|--------------------------------------------------|
| `IDLE`      | `3'b000` | Waiting for SS_N to assert (go LOW)              |
| `CHK_CMD`   | `3'b001` | Sampling the two MSB command bits from MOSI      |
| `WRITE`     | `3'b011` | Receiving write-address or write-data payload    |
| `READ_ADDR` | `3'b010` | Receiving read-address payload                   |
| `READ_DATA` | `3'b110` | Driving MISO; receiving dummy payload bits       |

---

## Design Diagrams

### System Block Diagram

![System Block Diagram](https://github.com/OmarEid66/SPI_Slave_with_Single_Port_RAM/blob/main/Screenshots/Block_Diagram.png)

### FSM State Diagram

![FSM State Diagram](https://github.com/OmarEid66/SPI_Slave_with_Single_Port_RAM/blob/main/Screenshots/FSM_Diagram.png)

---

## SPI Frame Protocol

Every transaction is a single **10-bit frame**: the two MSBs select the operation, and the lower 8 bits carry the address or data payload.

| `DATA_IN[9:8]` | Operation        | `DATA_IN[7:0]` Meaning              |
|----------------|------------------|--------------------------------------|
| `2'b00`        | Set Write Address | Address to latch into `write_addr`  |
| `2'b01`        | Write Data        | Data written to `ram[write_addr]`   |
| `2'b10`        | Set Read Address  | Address to latch into `read_addr`   |
| `2'b11`        | Read Data         | Ignored; triggers `ram[read_addr]` output |

**Example write sequence:**
```
Master sends: {2'b00, 8'hA0}  → Set write address = 0xA0
Master sends: {2'b01, 8'h55}  → Write 0x55 to ram[0xA0]
```

**Example read sequence:**
```
Master sends: {2'b10, 8'hA0}  → Set read address = 0xA0
Master sends: {2'b11, 8'hXX}  → Trigger read; TX_DATA = ram[0xA0]
```

> **MISO Timing Note:** `TX_VALID` from the RAM is a registered output that becomes valid one cycle *after* the read-data frame ends (because `RX_VALID` fires on SS_N rise, and the RAM processes it on the next posedge). MISO will be hi-Z during the read frame itself. A second dedicated SPI frame is required to retrieve serialised data.

---

## File Structure

```
SPI_Slave_with_Single_Port_RAM/
│
├── RTL/
│   ├── Ram.v                    # 256×8-bit synchronous single-port RAM
│   ├── SPI_SLAVE.v              # SPI Mode-0 slave FSM with MISO serialiser
│   └── SPI_Wrapper.v            # Top-level integration wrapper
│
├── Testbench/
│   ├── Ram_TB.v                 # Self-checking testbench for Ram module
│   ├── SPI_SLAVE_TB.v           # Self-checking testbench for SPI_SLAVE
│   └── SPI_Wrapper_TB.v         # End-to-end system testbench
│
├── Constraints/
│   └── SPI_Constrain.xdc        # Vivado XDC pin & timing constraints
│
├── Netlist/
│   └── SPI_With_RAM_Netlist.v   # Post-synthesis netlist (Verilog)
│
├── Bitstream/
│   └── Bitstream_File.bit       # Generated bitstream for xc7a35tcpg236-2L
│
├── Reports/
│   ├── Utilization_Report.txt   # Slice LUT, FF, and I/O utilization
│   ├── Power_Report.txt         # On-chip power breakdown
│   ├── DRC_Report.txt           # Design Rule Check results
│   ├── Methodology_Report.txt   # UltraFast methodology check results
│   └── Timing_Report.rpx        # Full timing report (Vivado format)
│
└── Schematics/
    ├── Elaborated_Design.png    # RTL-level block diagram
    ├── Synthesized_Design.png   # Post-synthesis netlist schematic
    └── Implemented_Design.png   # Post-implementation device floorplan
```

---

## FPGA Implementation

### Device & Toolchain

| Parameter        | Value                        |
|------------------|------------------------------|
| FPGA Family      | Xilinx Artix-7               |
| Device           | `xc7a35tcpg236-2L`           |
| Speed Grade      | -2L                          |
| Toolchain        | Vivado v2025.2               |
| Clock Constraint | 10.0 ns (100 MHz)            |
| Design State     | Synthesised & Implemented    |

---

### Resource Utilization

> Source: `Utilization_Report.txt` — Vivado v2025.2

| Resource              | Used  | Available | Utilization |
|-----------------------|-------|-----------|-------------|
| Slice LUTs (as Logic) | 894   | 20,800    | **4.30%**   |
| Slice Registers (FF)  | 2,136 | 41,600    | **5.13%**   |
| F7 Muxes              | 264   | 16,300    | 1.62%       |
| F8 Muxes              | 128   | 8,150     | 1.57%       |
| Bonded IOBs           | 5     | 106       | 4.72%       |
| Block RAM Tiles       | 0     | 50        | 0.00%       |
| DSP Slices            | 0     | 90        | 0.00%       |
| BUFGCTRL              | 1     | 32        | 3.13%       |

**Key observations:**
- The 256-deep RAM is implemented entirely in **distributed LUTs and flip-flops** (2,136 FFs), not Block RAM. This is because the `for` loop reset initialisation and the mux-based access pattern prevent BRAM inference in Vivado.
- Only **4.30% LUT** and **5.13% FF** utilization confirms the design is very lightweight and leaves ample fabric for integration into a larger SoC design.
- Zero DSP and zero BRAM usage means the design is fully portable to any Artix-7 variant regardless of BRAM/DSP count.

---

### Power Analysis

> Source: `Power_Report.txt` — Vivado v2025.2 (synthesised, typical process)

| Parameter                | Value      |
|--------------------------|------------|
| Total On-Chip Power      | **83 mW**  |
| Dynamic Power            | 12 mW      |
| Static Power             | 72 mW      |
| Clock Domain Power       | 11 mW      |
| Slice Logic Power        | < 1 mW     |
| I/O Power                | < 1 mW     |
| Junction Temperature     | 25.4 °C    |
| Max Ambient Temperature  | 99.6 °C    |
| Confidence Level         | Medium     |

**Hierarchy breakdown:**

| Module        | Dynamic Power |
|---------------|---------------|
| `SPI_Wrapper` | 12 mW         |
| `ram_inst`    | 11 mW         |
| `spi_slave_inst` | < 1 mW     |

> **Note:** Static power (72 mW) dominates because the device is mostly idle during synthesis-state estimation. Confidence level is Medium due to missing I/O activity annotations; values will be more accurate after place-and-route with a simulation activity file (SAIF).

---

### DRC & Methodology

> Source: `DRC_Report.txt` and `Methodology_Report.txt`

| Check                | Result                       |
|----------------------|------------------------------|
| DRC Violations       | ✅ **0 violations**          |
| Methodology Warnings | ⚠️ 4 warnings (TIMING-18)   |

The four `TIMING-18` methodology warnings indicate that **input/output delay constraints** are missing for the SPI ports relative to the system clock:

| Port   | Warning              |
|--------|----------------------|
| `MOSI` | Missing input delay  |
| `RST_N`| Missing input delay  |
| `SS_N` | Missing input delay  |
| `MISO` | Missing output delay |

These warnings are expected for an SPI slave whose setup/hold requirements are governed by the SPI master's timing, not a shared board-level clock domain. They can be resolved by adding `set_input_delay` / `set_output_delay` constraints in the XDC file once the master clock relationship is known.

---

## Design Schematics

### Elaborated Design (RTL Block Diagram)
> Vivado RTL analysis view showing the `SPI_Wrapper` top-level with `ram_inst` and `spi_slave_inst` sub-modules and all inter-module connections.

![Elaborated Design](Schematics/Elaborated_Design.png)

---

### Synthesized Design (Post-Synthesis Netlist)
> Post-synthesis schematic showing technology primitives: `IBUF`, `BUFG`, `FDCE` flip-flops, `LUT6`, `MUXF7/F8`, and the tri-state `OBUFT` on MISO.

![Synthesized Design](Schematics/Synthesized_Design.png)

---

### Implemented Design (Device Floorplan)
> Post-implementation device view showing placed logic clusters in the lower region of the Artix-7 fabric, consistent with the low (~5%) utilization figures.

![Implemented Design](Schematics/Implemented_Design.png)

---

## Hardware Target

The design was synthesised, implemented, and programmed onto the **Digilent Basys 3** development board.

![Digilent Basys 3](https://github.com/OmarEid66/SPI_Slave_with_Single_Port_RAM/blob/main/Screenshots/FPGA_Board.jpg)

| Feature               | Specification                              |
|-----------------------|--------------------------------------------|
| Board                 | Digilent Basys 3                           |
| FPGA                  | Xilinx Artix-7 `xc7a35tcpg236-2L`         |
| On-chip Clock         | 100 MHz (`CLK100MHZ`)                      |
| User I/O              | 16 switches, 16 LEDs, 5 buttons            |
| Pmod Connectors       | 4 × Pmod headers (used for SPI signals)    |
| Programming Interface | USB-JTAG (on-board Digilent USB)           |
| Power Supply          | USB (500 mA) or external 5 V jack          |

> The SPI signals (`MOSI`, `MISO`, `SS_N`) are routed through the Pmod headers. The system clock (`CLK`) is sourced from the on-board 100 MHz oscillator, and `RST_N` is mapped to a push button.

---

## Constraints

The XDC file (`SPI_Constrain.xdc`) defines the clock and pin assignments for the `xc7a35tcpg236-2L` package.

```tcl
# Example constraint structure (refer to SPI_Constrain.xdc for full details)
create_clock -period 10.000 -name sys_clk_pin [get_ports CLK]

set_property PACKAGE_PIN <pin> [get_ports CLK]
set_property PACKAGE_PIN <pin> [get_ports RST_N]
set_property PACKAGE_PIN <pin> [get_ports MOSI]
set_property PACKAGE_PIN <pin> [get_ports SS_N]
set_property PACKAGE_PIN <pin> [get_ports MISO]
```

---

## How to Simulate

All three testbenches are self-checking and print `PASS` / `FAIL` for each test case.

**Using Vivado Simulator:**
```tcl
# Add source files and testbench, then run:
launch_simulation
run all
```

**Using Icarus Verilog (iverilog):**
```bash
# Simulate the full system testbench
iverilog -o sim_wrapper Ram.v SPI_SLAVE.v SPI_Wrapper.v SPI_Wrapper_TB.v
vvp sim_wrapper

# Simulate the SPI slave in isolation
iverilog -o sim_spi SPI_SLAVE.v SPI_SLAVE_TB.v
vvp sim_spi

# Simulate the RAM in isolation
iverilog -o sim_ram Ram.v Ram_TB.v
vvp sim_ram
```

Expected output (all tests passing):
```
PASS Test 1:  Reset OK
PASS Test 2:  Write Address frame — RX_VALID and RX_data correct
PASS Test 3:  Write Data frame — RX_VALID and RX_data correct
...
Results: 17 PASS  |  0 FAIL
```

---

## How to Synthesise & Implement

1. Open **Vivado 2025.2** and create a new RTL project.
2. Add all files from the `RTL/` directory as design sources.
3. Add `Constraints/SPI_Constrain.xdc` as the constraint file.
4. Set the target part to `xc7a35tcpg236-2L`.
5. Run **Synthesis** → **Implementation** → **Generate Bitstream**.
6. Program the device using the generated `Bitstream/Bitstream_File.bit`.

```
Flow Manager:
  Synthesis   →  synth_design -top SPI_Wrapper -part xc7a35tcpg236-2L
  Opt         →  opt_design
  Place       →  place_design
  Route       →  route_design
  Bitstream   →  write_bitstream
```

---

## Known Limitations

| Limitation | Description |
|------------|-------------|
| **MISO Read Latency** | MISO is hi-Z during the read-data frame. TX_DATA is valid one frame later due to the registered RX_VALID → RAM → TX_VALID pipeline delay. |
| **No BRAM Inference** | The RAM is implemented in distributed flip-flops (2,136 FFs) rather than Block RAM due to the synchronous reset initialisation loop. Remove the `for` loop reset to enable BRAM inference for deeper memories. |
| **Missing I/O Delays** | Four `TIMING-18` methodology warnings exist for missing `set_input_delay` / `set_output_delay` constraints on SPI ports. Add these once the master timing relationship is defined. |
| **Single Clock Domain** | MOSI/SS_N are sampled on the system clock. No CDC synchronisation is implemented; a dedicated SPI clock input (SCLK) is not supported in the current architecture. |

---

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE) for details.
