source [file join [file dirname [info script]] run_common.tcl]

namespace eval memory_width_test {
    variable directory [file normalize [file dirname [info script]]]
    variable root [file normalize [file join [file dirname [info script]] ../..]]
}

proc memory_width_test::run_case {cfg addr_width data_width} {
    variable root
    variable directory
    set rtl [file join $root src memory]
    set label "a${addr_width}_d${data_width}"
    set out [file join [dict get $cfg build-dir] memory_widths $label]
    set obj [file join $out obj_$::tcl_platform(os)_$::tcl_platform(machine)]
    set top tb_memory_widths
    set command [list [dict get $cfg verilator]]
    if {[dict get $cfg lint-only]} {lappend command --lint-only} else {lappend command --binary}
    lappend command --timing --assert -Wno-fatal -Wno-MODDUP --top-module $top --Mdir $obj -I$rtl \
        -GADDR_WIDTH=$addr_width -GDATA_WIDTH=$data_width
    if {![dict get $cfg lint-only]} {lappend command -j [dict get $cfg jobs]}
    lappend command [file join $rtl memory_system.sv] [file join $directory tb_memory_widths.sv]

    puts "=== memory widths ADDR_WIDTH=$addr_width DATA_WIDTH=$data_width ==="
    if {[dict get $cfg dry-run]} {
        puts "Build: $command"
        if {![dict get $cfg lint-only]} {puts "Run: [file join $obj V$top]"}
        return
    }
    file mkdir $out
    memory_test::execute $command [file join $out build.log]
    if {[dict get $cfg lint-only]} {return}
    set output [memory_test::execute [list [file join $obj V$top]] [file join $out run.log]]
    if {![regexp -line "^PASS: ${top} ADDR_WIDTH=${addr_width} DATA_WIDTH=${data_width} " $output]} {
        error "$top exited without its expected width-specific PASS marker"
    }
}

if {[catch {set cfg [memory_test::parse $argv]} message]} {
    puts stderr "ERROR: $message"
    exit 1
}
if {$cfg == {}} {return}
if {![dict get $cfg dry-run] && [auto_execok [dict get $cfg verilator]] == {}} {
    puts stderr "ERROR: Verilator not found; use --verilator PATH or install Verilator."
    exit 1
}

foreach {addr_width data_width} {32 32 40 64 40 512} {
    if {[catch {memory_width_test::run_case $cfg $addr_width $data_width} message]} {
        puts stderr "FAIL: memory widths ADDR_WIDTH=$addr_width DATA_WIDTH=$data_width: $message"
        exit 1
    }
    if {![dict get $cfg dry-run]} {
        set suffix ""
        if {[dict get $cfg lint-only]} {set suffix " (lint only)"}
        puts "OK: ADDR_WIDTH=$addr_width DATA_WIDTH=$data_width$suffix"
    }
}
if {![dict get $cfg dry-run]} {
    puts [expr {[dict get $cfg lint-only] ? "Lint completed: memory width regression" : "PASS: memory width regression"}]
}
