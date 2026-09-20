set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set build_dir [file join $script_dir build cpu_units]
set obj_dir [file join $build_dir obj]
set src_dir [file join $repo_root src]

set verilator verilator
if {[info exists ::env(VERILATOR)]} {
    set verilator $::env(VERILATOR)
}

proc run_command {label command} {
    puts "$label: [join $command { }]"
    if {[catch {exec {*}$command 2>@1} output]} {
        puts stderr $output
        error "$label failed"
    }
    puts $output
    return $output
}

set benches [list \
    [file join $script_dir tb_alu_arithmetic.sv] \
    [file join $script_dir tb_alu_branch.sv] \
    [file join $script_dir tb_alu_div.sv] \
    [file join $script_dir tb_alu_logical.sv] \
    [file join $script_dir tb_alu_mac.sv] \
    [file join $script_dir tb_alu_multiply.sv] \
    [file join $script_dir tb_alu_shift.sv] \
    [file join $script_dir tb_alu_top.sv] \
    [file join $script_dir tb_alu_widths.sv] \
    [file join $script_dir tb_fetch.sv] \
    [file join $script_dir tb_imm_gen.sv] \
    [file join $script_dir tb_regfile.sv] \
    [file join $script_dir tb_cpu_unit_suite.sv]]

set sources [list \
    [file join $src_dir alu alu.sv] \
    [file join $src_dir fetch.sv] \
    [file join $src_dir imm_gen.sv] \
    [file join $src_dir regfile.sv]]

file mkdir $obj_dir
set build_command [list $verilator --binary --timing --assert -Wno-fatal -Wno-MODDUP \
    -Wno-TIMESCALEMOD --top-module tb_cpu_unit_suite --Mdir $obj_dir \
    -I$src_dir -I[file join $src_dir alu] {*}$sources {*}$benches]

if {[catch {run_command "Build CPU unit tests" $build_command} message]} {
    puts stderr "FAIL: $message"
    exit 1
}

set simulation [file join $obj_dir Vtb_cpu_unit_suite]
if {[catch {set output [run_command "Run CPU unit tests" [list $simulation]]} message]} {
    puts stderr "FAIL: $message"
    exit 1
}
if {[string first "PASS: tb_cpu_unit_suite" $output] < 0} {
    puts stderr "FAIL: CPU unit simulation exited without a PASS marker"
    exit 1
}
