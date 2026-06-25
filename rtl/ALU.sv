`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 13.06.2026 19:13:37
// Design Name: 
// Module Name: ALU
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ALU
#(parameter width=8)(
input clk,reset,
input [width-1:0]a,b,
input [1:0] mode,
output reg [2*width-1:0]result
);

localparam s0=2'b0, s1=2'b01, s2=2'b10, s3=2'b11;

always_ff @(posedge clk)
begin
    if(reset)
    result<=0;
    
    else
    begin
        case(mode)
        
        s0: result <= a+b;
        s1: result <= a-b;
        s2: result <= a*b;
        s3: result <= (a>b)?1:0;
         
        endcase
    end

end




endmodule
