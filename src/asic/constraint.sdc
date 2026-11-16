current_design core

# Provisional exploration target: 10 ns period (100 MHz).
create_clock -name core_clock -period 10.000 [get_ports clk]
set_clock_uncertainty -setup 0.200 [get_clocks core_clock]
set_clock_uncertainty -hold 0.100 [get_clocks core_clock]
set_clock_transition 0.100 [get_clocks core_clock]

# Provisional synchronous interface budget: external input arrival and output
# required time each consume 1 ns. This covers reset and both memory channels;
# no multicycle or false-path exceptions are applied.
set_input_delay  -max 1.000 -clock core_clock [get_ports {rst_n i_data[*] i_waitrequest d_rdata[*] d_waitrequest}]
# No external minimum-delay specification is available. Assume 0 ns for a
# conservative input-to-register hold check; the physical flow must repair it.
set_input_delay  -min 0.000 -clock core_clock [get_ports {rst_n i_data[*] i_waitrequest d_rdata[*] d_waitrequest}]
set_output_delay -max 1.000 -clock core_clock [get_ports {i_read i_addr[*] d_read d_write d_addr[*] d_wdata[*] d_wstrb[*] retire_*}]
set_output_delay -min 0.000 -clock core_clock [get_ports {i_read i_addr[*] d_read d_write d_addr[*] d_wdata[*] d_wstrb[*] retire_*}]

# Provisional interface electrical assumptions.
set_input_transition 0.100 [get_ports {rst_n i_data[*] i_waitrequest d_rdata[*] d_waitrequest}]
set_load 5.000 [get_ports {i_read i_addr[*] d_read d_write d_addr[*] d_wdata[*] d_wstrb[*] retire_*}]
