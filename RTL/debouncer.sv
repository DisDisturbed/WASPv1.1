module button_pulse_generator #(
    parameter DEBOUNCE_MAX = 1000000 // 20ms at 50MHz
)(
    input  wire clk,
    input  wire btn_in,
    output reg  irq_pulse_out
);
    reg btn_sync_0, btn_sync_1;
    reg [19:0] counter;
    reg state;

    // Double-flop synchronizer to prevent metastability from asynchronous human presses
    always @(posedge clk) begin
        btn_sync_0 <= btn_in;
        btn_sync_1 <= btn_sync_0;
    end

    always @(posedge clk) begin
        irq_pulse_out <= 1'b0; // Default to absolutely no interrupt

        if (btn_sync_1 == state) begin
            counter <= 0; // Not changing, reset debounce counter
        end else begin
            counter <= counter + 1;
            if (counter >= DEBOUNCE_MAX) begin
                state <= btn_sync_1; // Button state has been stable for 20ms
                counter <= 0;
                
                // EXACTLY ONE CYCLE RISING EDGE DETECTOR
                if (btn_sync_1 == 1'b1) begin
                    irq_pulse_out <= 1'b1; 
                end
            end
        end
    end
endmodule