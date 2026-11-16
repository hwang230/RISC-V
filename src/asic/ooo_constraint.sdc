current_design ooo_core

# Identical to the in-order 100 MHz exploration budget. Retirement is an
# observable architectural interface and receives the same output budget.
create_clock -name core_clock -period 10.000 [get_ports clk]
set_clock_uncertainty -setup 0.200 [get_clocks core_clock]
set_clock_uncertainty -hold 0.100 [get_clocks core_clock]
set_clock_transition 0.100 [get_clocks core_clock]

set cpu_inputs [get_ports {rst_n i_data[*] i_waitrequest d_rdata[*] d_waitrequest}]
set cpu_outputs [get_ports {i_read i_addr[*] d_read d_write d_addr[*] d_wdata[*] d_wstrb[*] retire_*}]
set_input_delay -max 1.000 -clock core_clock $cpu_inputs
set_input_delay -min 0.000 -clock core_clock $cpu_inputs
set_output_delay -max 1.000 -clock core_clock $cpu_outputs
set_output_delay -min 0.000 -clock core_clock $cpu_outputs
set_input_transition 0.100 $cpu_inputs
set_load 5.000 $cpu_outputs
