# NAN Action Handler - Detailed Bug Analysis & Corrections

---

## BUG #1: Service ID Byte Order Error (CRITICAL)

### Location
File: `ip/enhanced_xpu/src/nan_action_handler.v`
Lines: 395-405

### Current Implementation
```verilog
// Shift in service ID bytes (little-endian)
service_id_buffer <= {pkt_data_in, service_id_buffer[47:8]};
service_id_byte_count <= service_id_byte_count + 1;

// Check for match after receiving all 6 bytes
if (service_id_byte_count == 5) begin
    if ({pkt_data_in, service_id_buffer[47:8]} == REMOTE_ID_SERVICE_ID) begin
        service_id_match <= 1;
    end else begin
        error_flags[ERR_SERVICE_ID_MISMATCH] <= 1;
    end
end
```

### Expected Service ID
```
Constant: localparam [47:0] REMOTE_ID_SERVICE_ID = 48'h886919_9D9209;
Bytes:    [0x88, 0x69, 0x19, 0x9D, 0x92, 0x09]
```

### Trace of Bug

Incoming bytes arrive in order: **B0=0x88, B1=0x69, B2=0x19, B3=0x9D, B4=0x92, B5=0x09**

**Clock 1: B0 arrives (service_id_byte_count=0)**
```
service_id_buffer <= {0x88, 0}
Result: 48'h00000000_0088
```

**Clock 2: B1 arrives (service_id_byte_count=1)**
```
service_id_buffer <= {0x69, service_id_buffer[47:8]}
           = {0x69, 0x000000_0000}
Result: 48'h00000000_6900
        ↑ B0 is lost!
```

**Clock 3: B2 arrives (service_id_byte_count=2)**
```
service_id_buffer <= {0x19, service_id_buffer[47:8]}
           = {0x19, 0x000000_69}
Result: 48'h00000001_9690
        ↑ Wrong position
```

**Clock 4: B3 arrives (service_id_byte_count=3)**
```
Result: 48'h00000019_69XX
```

**Clock 5: B4 arrives (service_id_byte_count=4)**
```
Result: 48'h000019_69XXXX
```

**Clock 6: B5 arrives (service_id_byte_count=5) - COMPARISON HAPPENS**
```
{pkt_data_in, service_id_buffer[47:8]} = {0x09, service_id_buffer[47:8]}
                                        = {0x09, 0x19_69XXXX}
                                        = 0x0919_69XXXX

Expected:    0x886919_9D9209
Got:         0x0919_69XXXX
Match: FALSE ✗
```

### Why It Happens

The operation `service_id_buffer <= {pkt_data_in, service_id_buffer[47:8]}` shifts bits LEFT, inserting new byte on the right. This causes:

1. Each new byte enters on the RIGHT
2. Existing bytes shift LEFT (toward MSB)
3. MSB byte is lost after 6 iterations
4. Bytes end up in **reverse order** in the buffer

### Correct Implementation (Option A: Array-based)

```verilog
// Method 1: Use intermediate storage and build complete ID
reg [7:0] service_id_bytes [0:5];

always @(posedge clk) begin
    if (state == ST_SVC_DESC_ID) begin
        if (pkt_data_valid) begin
            service_id_bytes[service_id_byte_count] <= pkt_data_in;
            if (service_id_byte_count == 5) begin
                // Reconstruct as 48-bit value
                service_id_buffer <= {
                    service_id_bytes[5],
                    service_id_bytes[4],
                    service_id_bytes[3],
                    service_id_bytes[2],
                    service_id_bytes[1],
                    pkt_data_in  // This is byte 0
                };
                if ({service_id_bytes[5:1], pkt_data_in} == REMOTE_ID_SERVICE_ID)
                    service_id_match <= 1;
                else
                    error_flags[ERR_SERVICE_ID_MISMATCH] <= 1;
            end
        end
    end
end
```

### Correct Implementation (Option B: Right-shift accumulator)

```verilog
// Method 2: Accumulate with right-shift (simpler)
reg [47:0] service_id_accumulator;

always @(posedge clk) begin
    if (state == ST_SVC_DESC_ID && pkt_data_valid) begin
        // Right-shift: new byte enters on LEFT
        service_id_accumulator <= {pkt_data_in, service_id_accumulator[47:8]};

        if (service_id_byte_count == 5) begin
            // On 6th byte, full accumulator contains: [B0, B1, B2, B3, B4, B5]
            if ({pkt_data_in, service_id_accumulator[47:8]} == REMOTE_ID_SERVICE_ID)
                service_id_match <= 1;
        end
        service_id_byte_count <= service_id_byte_count + 1;
    end
end
```

Wait, this has the same issue! Let me reconsider...

### Correct Implementation (Option C: Left-shift with MSB entry)

```verilog
// Method 3: Proper accumulation from MSB
always @(posedge clk) begin
    if (state == ST_SVC_DESC_ID && pkt_data_valid) begin
        if (service_id_byte_count == 0) begin
            service_id_buffer <= pkt_data_in << 40;  // Place first byte at MSB
        end else begin
            // Shift left, insert new byte at LSB
            service_id_buffer <= {service_id_buffer[39:0], pkt_data_in};
        end

        service_id_byte_count <= service_id_byte_count + 1;

        if (service_id_byte_count == 5) begin
            // After this clock, buffer has complete value
            // But we need to check NEXT clock
            if ({service_id_buffer[39:0], pkt_data_in} == REMOTE_ID_SERVICE_ID)
                service_id_match <= 1;
        end
    end
end
```

### Verification Trace (Method C)

**Clock 1: B0=0x88 (service_id_byte_count=0)**
```
service_id_buffer <= 0x88 << 40 = 48'h88_0000_0000
```

**Clock 2: B1=0x69 (service_id_byte_count=1)**
```
service_id_buffer <= {48'h88_0000_0000[39:0], 0x69}
                  = {40'h0_0000_00, 0x69}
                  = 48'h00_0000_0069
```

Hmm, this is still not working. The issue is we need to place FIRST byte at MSB and LAST byte at LSB.

### Correct Implementation (Option D: Explicit positional)

```verilog
reg [47:0] service_id_bytes_temp [0:5];  // or just use 6 separate bytes

always @(posedge clk) begin
    if (state == ST_SVC_DESC_ID && pkt_data_valid) begin
        service_id_bytes_temp[service_id_byte_count] <= pkt_data_in;

        if (service_id_byte_count == 5) begin
            // All 6 bytes received, now check
            service_id_buffer <= {
                service_id_bytes_temp[0],
                service_id_bytes_temp[1],
                service_id_bytes_temp[2],
                service_id_bytes_temp[3],
                service_id_bytes_temp[4],
                pkt_data_in
            };

            if ({service_id_bytes_temp[0], service_id_bytes_temp[1],
                 service_id_bytes_temp[2], service_id_bytes_temp[3],
                 service_id_bytes_temp[4], pkt_data_in} == REMOTE_ID_SERVICE_ID) begin
                service_id_match <= 1;
            end else begin
                error_flags[ERR_SERVICE_ID_MISMATCH] <= 1;
            end
        end

        service_id_byte_count <= service_id_byte_count + 1;
    end
end
```

This is the CORRECT way - store each byte in order as it arrives, then assemble when complete.

---

## BUG #2: EOF Handling Override (CRITICAL)

### Location
File: `ip/enhanced_xpu/src/nan_action_handler.v`
Lines: 154-279

### Current Code
```verilog
always @(*) begin
    next_state = state;

    case (state)
        ST_IDLE: begin
            if (pkt_sof && is_nan_frame && parse_enable) begin
                next_state = ST_SKIP_HEADERS;
            end
        end

        // ... other states ...

        ST_ATTR_TYPE: begin
            if (pkt_data_valid) begin
                if (byte_counter >= pkt_length - 3) begin
                    // Not enough bytes for complete attribute
                    next_state = ST_COMPLETE;
                end else begin
                    next_state = ST_ATTR_LEN_LOW;
                end
            end else if (pkt_eof) begin
                next_state = ST_COMPLETE;  // ← Correct completion
            end
        end

        // ...
    endcase

    // Force return to idle on EOF in most states
    if (pkt_eof && (state != ST_REMOTE_ID_DATA) &&
        (state != ST_COMPLETE) && (state != ST_ERROR)) begin
        next_state = ST_ERROR;  // ← This OVERRIDES above!
    end
end
```

### The Problem

When in `ST_ATTR_TYPE` with `pkt_eof`:
1. Case statement sets: `next_state = ST_COMPLETE` (correct)
2. EOF override executes: checks if `pkt_eof && state != ST_REMOTE_ID_DATA`
3. Condition is TRUE: `pkt_eof=1 && state=ST_ATTR_TYPE (which != ST_REMOTE_ID_DATA)`
4. Override forces: `next_state = ST_ERROR` (WRONG!)

**Result:** Frame that should complete successfully is marked as error.

### Verilog Behavior

When same signal assigned twice in `always @(*)`:
```verilog
always @(*) begin
    x = 5;
    if (condition) x = 10;  // ← This assignment WINS
end
```

The **last assignment wins**. Since EOF override comes after case statement, it always wins.

### Correct Solution (Integrate EOF into each state)

```verilog
always @(*) begin
    next_state = state;

    case (state)
        ST_IDLE: begin
            if (pkt_sof && is_nan_frame && parse_enable) begin
                next_state = ST_SKIP_HEADERS;
            end
        end

        ST_SKIP_HEADERS: begin
            if (pkt_eof) begin
                next_state = ST_ERROR;  // Premature EOF, no attributes
            end else if (pkt_data_valid && skip_counter >= NAN_HEADER_SIZE - 1) begin
                next_state = ST_ATTR_TYPE;
            end
        end

        ST_ATTR_TYPE: begin
            if (pkt_eof) begin
                next_state = ST_COMPLETE;  // Normal end
            end else if (pkt_data_valid) begin
                if (byte_counter >= pkt_length - 3) begin
                    next_state = ST_COMPLETE;
                end else begin
                    next_state = ST_ATTR_LEN_LOW;
                end
            end
        end

        // ... similar for all other states ...

        ST_REMOTE_ID_DATA: begin
            if (pkt_data_valid) begin
                if (rid_byte_count >= REMOTE_ID_SIZE - 1) begin
                    next_state = ST_ATTR_TYPE;
                end
            end else if (pkt_eof) begin
                if (rid_byte_count >= REMOTE_ID_SIZE - 1) begin
                    next_state = ST_COMPLETE;  // Got all 25 bytes
                end else begin
                    next_state = ST_ERROR;     // Incomplete message
                end
            end
        end

        // Remove the global EOF override
    endcase
end
```

---

## BUG #3: Test Bench Port Mismatch (CRITICAL)

### Location
File: `ip/enhanced_xpu/test/nan_action_handler_tb.v`
Lines: 56-83

### Module Port Declaration
```verilog
module nan_action_handler #(
    parameter DATA_WIDTH = 8,
    parameter REMOTE_ID_SIZE = 25,
    parameter MAX_PKT_SIZE = 2048,
    parameter ADDR_WIDTH = 11
)(
    input wire clk,
    input wire rstn,
    input wire [DATA_WIDTH-1:0] pkt_data_in,
    input wire pkt_data_valid,
    output reg pkt_data_ready,
    input wire pkt_sof,
    input wire pkt_eof,
    input wire is_nan_frame,
    input wire [ADDR_WIDTH-1:0] pkt_length,
    input wire parse_enable,

    output reg [DATA_WIDTH-1:0] rid_data_out,
    output reg rid_data_valid,
    input wire rid_data_ready,
    output reg rid_sof,
    output reg rid_eof,
    output reg [7:0] rid_msg_type,

    output reg remote_id_found,
    output reg parse_complete,
    output reg [3:0] error_flags,
    output reg [7:0] attr_count,
    output reg [ADDR_WIDTH-1:0] bytes_processed
);
```

### Test Bench Instantiation
```verilog
nan_action_handler dut (
    .clk(clk),
    .rstn(rstn),
    .frame_valid(frame_valid),              // ✗ Wrong: pkt_data_valid
    .frame_byte(frame_byte),                // ✗ Wrong: pkt_data_in
    .frame_last(frame_last),                // ✗ Wrong: pkt_eof
    .frame_length(frame_length),            // ✗ Wrong: pkt_length
    .expected_service_id(service_id),       // ✗ Not a module port!
    .nan_frame_detected(nan_frame_detected), // ✗ Wrong: remote_id_found
    // ... many more wrong connections ...
);
```

### Comparison Table

| Test Bench Port | Expected Module Port | Match |
|-----------------|----------------------|-------|
| `frame_valid` | `pkt_data_valid` | ✗ |
| `frame_byte` | `pkt_data_in` | ✗ |
| `frame_last` | `pkt_eof` | ✗ |
| `frame_length` | `pkt_length` | ✗ |
| `expected_service_id` | (not a port) | ✗ |
| `nan_frame_detected` | `remote_id_found` | Partially |
| `service_id_match` | (not an output) | ✗ |
| `attr_type` | (not an output) | ✗ |
| `attr_length` | (not an output) | ✗ |
| `attr_valid` | (not an output) | ✗ |
| `payload_byte` | `rid_data_out` | Partially |
| `payload_valid` | `rid_data_valid` | Partially |
| `payload_complete` | `parse_complete` | Partially |
| `payload_length` | (not an output) | ✗ |
| `error_invalid_length` | `error_flags[0]` | Partially |
| `error_wrong_service_id` | `error_flags[1]` | Partially |
| `error_truncated_attr` | `error_flags[3]` | Partially |

### Compilation Error

This testbench would produce:
```
Error: nan_action_handler does not have port "frame_valid"
Error: nan_action_handler does not have port "frame_byte"
...
```

### Corrected Test Bench Structure

```verilog
module nan_action_handler_tb;
    parameter CLK_PERIOD = 10;

    // Clock and reset
    reg clk, rstn;

    // Input packet stream
    reg [7:0] pkt_data_in;
    reg pkt_data_valid;
    wire pkt_data_ready;
    reg pkt_sof, pkt_eof;

    // Control signals
    reg is_nan_frame;
    reg [10:0] pkt_length;
    reg parse_enable;

    // Output Remote ID stream
    wire [7:0] rid_data_out;
    wire rid_data_valid;
    reg rid_data_ready;
    wire rid_sof, rid_eof;
    wire [7:0] rid_msg_type;

    // Status outputs
    wire remote_id_found;
    wire parse_complete;
    wire [3:0] error_flags;
    wire [7:0] attr_count;
    wire [10:0] bytes_processed;

    // Instantiate DUT
    nan_action_handler dut (
        .clk(clk),
        .rstn(rstn),
        .pkt_data_in(pkt_data_in),
        .pkt_data_valid(pkt_data_valid),
        .pkt_data_ready(pkt_data_ready),
        .pkt_sof(pkt_sof),
        .pkt_eof(pkt_eof),
        .is_nan_frame(is_nan_frame),
        .pkt_length(pkt_length),
        .parse_enable(parse_enable),
        .rid_data_out(rid_data_out),
        .rid_data_valid(rid_data_valid),
        .rid_data_ready(rid_data_ready),
        .rid_sof(rid_sof),
        .rid_eof(rid_eof),
        .rid_msg_type(rid_msg_type),
        .remote_id_found(remote_id_found),
        .parse_complete(parse_complete),
        .error_flags(error_flags),
        .attr_count(attr_count),
        .bytes_processed(bytes_processed)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Test: Valid Remote ID
    task test_valid_remote_id();
        // Setup
        rstn = 0;
        pkt_data_valid = 0;
        rid_data_ready = 1;
        #100;
        rstn = 1;

        // Send frame
        is_nan_frame = 1;
        parse_enable = 1;
        pkt_length = 11'd70;  // Header(31) + TLV(3) + SvcDesc(36)

        // Start of frame
        pkt_sof = 1;
        pkt_data_in = 8'h7F;  // Category
        pkt_data_valid = 1;
        #CLK_PERIOD;
        pkt_sof = 0;

        // ... more bytes ...

        // End of frame
        pkt_eof = 1;
        #CLK_PERIOD;
        pkt_data_valid = 0;

        // Wait for completion
        #1000;
        if (remote_id_found) $display("✓ Test passed");
        else $display("✗ Test failed");
    endtask

    initial begin
        test_valid_remote_id();
        $finish;
    end
endmodule
```

---

## BUG #4: rid_byte_count Not Reset (MAJOR)

### Location
File: `ip/enhanced_xpu/src/nan_action_handler.v`
Lines: 238-250, 328

### Current Code
```verilog
ST_REMOTE_ID_DATA: begin
    if (pkt_data_valid && rid_data_ready) begin
        pkt_data_ready <= 1;
        byte_counter <= byte_counter + 1;
        attr_value_counter <= attr_value_counter + 1;
        bytes_processed <= byte_counter;

        rid_data_out <= pkt_data_in;
        rid_data_valid <= 1;
        rid_byte_count <= rid_byte_count + 1;  // ← Increments

        // Start of frame on first byte
        if (rid_byte_count == 0) begin
            rid_sof <= 1;
            rid_msg_type <= pkt_data_in;
            remote_id_found <= 1;
        end

        // End of frame on last byte
        if (rid_byte_count == REMOTE_ID_SIZE - 1) begin
            rid_eof <= 1;
        end
    end
end

// State transition (line 239)
if (rid_byte_count >= REMOTE_ID_SIZE - 1) begin
    next_state = ST_ATTR_TYPE;  // ← Transitions back
end
```

### Problem

After 25 bytes are extracted:
- `rid_byte_count` reaches 24 (0-indexed)
- State transitions to `ST_ATTR_TYPE`
- **Counter is never reset**

If a second Remote ID Service Descriptor exists in the frame:
- State returns to `ST_REMOTE_ID_DATA`
- `rid_byte_count` is still 24
- Condition `if (rid_byte_count == 0)` never true again
- `rid_sof` and `rid_msg_type` never set for second message

### Trace of Bug

**First Remote ID:**
```
Clock  rid_byte_count  rid_sof  rid_eof  rid_msg_type  Bytes
  1         0            1       0         0x00       1/25 ✓
  2         1            0       0         0x00       2/25
  ...
 25        24            0       1         0x00      25/25 ✓
State transitions to ST_ATTR_TYPE
rid_byte_count NOT reset (stays at 24)
```

**Second Remote ID (if present):**
```
Clock  rid_byte_count  rid_sof  rid_eof  rid_msg_type  Bytes
 30        24            0       0         0x00       (old)
 31        25            0       0         0x00       (old)  ← Over-counter!
 32        26            0       0         0x00       (old)
...
 54        48            0       0         0x00       (old)  ← Still not matching first byte!
```

### Solution: Reset on State Exit

**Method 1: Reset in same state**
```verilog
ST_REMOTE_ID_DATA: begin
    if (pkt_data_valid && rid_data_ready) begin
        rid_byte_count <= rid_byte_count + 1;

        if (rid_byte_count == REMOTE_ID_SIZE - 1) begin
            rid_eof <= 1;
            rid_byte_count <= 0;  // ← Reset immediately
        end
    end
end
```

**Method 2: Reset on state entry**
```verilog
ST_ATTR_TYPE: begin
    if (pkt_data_valid) begin
        pkt_data_ready <= 1;
        current_attr_id <= pkt_data_in;
        byte_counter <= byte_counter + 1;
        attr_value_counter <= 0;
        rid_byte_count <= 0;  // ← Reset when entering from Remote ID
        attr_count <= attr_count + 1;
        bytes_processed <= byte_counter;
    end
end
```

**Method 3: Reset in specific transitions**
```verilog
if (rid_byte_count >= REMOTE_ID_SIZE - 1) begin
    next_state = ST_ATTR_TYPE;
    rid_byte_count_next = 0;  // Explicit reset signal
end
```

---

## Summary of Fixes Required

| Bug | File | Lines | Fix Type | Effort |
|-----|------|-------|----------|--------|
| Service ID byte order | nan_action_handler.v | 395-405 | Logic rewrite | 1 hour |
| EOF override | nan_action_handler.v | 276-278 | Restructure | 1 hour |
| Test bench interface | nan_action_handler_tb.v | All | Complete rewrite | 1.5 hours |
| rid_byte_count reset | nan_action_handler.v | 238-250 | Add reset | 0.5 hours |
| Unused state | nan_action_handler.v | 114, 171 | Remove | 0.5 hours |

**Total estimated effort: 4.5 hours**

