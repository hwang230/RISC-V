set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set build_dir [file join $script_dir build]
set obj_dir [file join $build_dir obj]

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

file mkdir $obj_dir
set build_command [list $verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module tb_decoder --Mdir $obj_dir -I[file join $repo_root src] \
    [file join $repo_root src decoder.sv] [file join $script_dir tb_decoder.sv]]

if {[catch {run_command "Build decoder test" $build_command} message]} {
    puts stderr "FAIL: $message"
    exit 1
}

set simulation [file join $obj_dir Vtb_decoder]
if {[catch {set output [run_command "Run decoder test" [list $simulation]]} message]} {
    puts stderr "FAIL: $message"
    exit 1
}
if {[string first "PASS: tb_decoder (" $output] < 0} {
    puts stderr "FAIL: decoder simulation exited without a PASS marker"
    exit 1
}
