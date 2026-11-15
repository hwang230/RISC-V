current_design asic_memory_top

# Provisional 10 ns / 100 MHz exploration target.
create_clock -name memory_clock -period 10.000 [get_ports clk]
set_clock_uncertainty -setup 0.200 [get_clocks memory_clock]
set_clock_uncertainty -hold 0.100 [get_clocks memory_clock]
set_clock_transition 0.100 [get_clocks memory_clock]

# Provisional interface budget: 1 ns input arrival and output required time.
# All top-level ports except clk are covered; no timing exceptions are used.
set_input_delay -max 1.000 -clock memory_clock [get_ports {rst_n i_read i_addr[*] d_read d_write d_addr[*] d_wdata[*] d_wstrb[*]}]
set_input_delay -min 0.000 -clock memory_clock [get_ports {rst_n i_read i_addr[*] d_read d_write d_addr[*] d_wdata[*] d_wstrb[*]}]
set_output_delay -max 1.000 -clock memory_clock [get_ports {i_data[*] i_waitrequest d_rdata[*] d_waitrequest}]
set_output_delay -min 0.000 -clock memory_clock [get_ports {i_data[*] i_waitrequest d_rdata[*] d_waitrequest}]
set_input_transition 0.100 [get_ports {rst_n i_read i_addr[*] d_read d_write d_addr[*] d_wdata[*] d_wstrb[*]}]
set_load 5.000 [get_ports {i_data[*] i_waitrequest d_rdata[*] d_waitrequest}]
