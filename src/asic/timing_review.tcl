# POST_CTS_TCL runs after timing repair and estimated placement parasitics.
# Keep named paths as well as the worst global paths: the global winner can
# hide a scheduler, register-file or multiplier regression.
set report_file $::env(REPORTS_DIR)/4_cts_backend_paths.rpt
set stream [open $report_file w]
puts $stream "Post-CTS timing with estimated placement parasitics; not signoff."
close $stream
foreach {label pattern} {
    scheduler *iq*
    register_file *physical_regs*
    multiplier *u_mul*
    rename *speculative_map*
    reorder_buffer *rob*
} {
    set cells [get_cells -quiet -hierarchical $pattern]
    set stream [open $report_file a]
    puts $stream "\n=== $label ($pattern): [llength $cells] matching cells ==="
    close $stream
    if { [llength $cells] > 0 } {
        report_checks -through [get_pins -of_objects $cells -filter "direction == output"] \
            -path_delay max -group_path_count 3 -format full_clock_expanded \
            >> $report_file
    }
}
report_checks -path_delay max -group_path_count 5 -format full_clock_expanded \
    >> $report_file
report_checks -path_delay min -group_path_count 5 -format full_clock_expanded \
    >> $report_file
