# Verilator regression driver. Requires Tcl 8.5 or newer.
namespace eval memory_test {
    variable directory [file dirname [file normalize [info script]]]
    variable root [file normalize [file join $directory ../..]]
}

proc memory_test::usage {} {
    puts {Usage: tclsh test/memory/run_all.tcl [options]
  --seed N | --seeds N,N,...   Reproducible seeds (default 1)
  --random-iters N            Operations after directed tests (default 200; 0..100000)
  --jobs N                    C++ build parallelism (default 2)
  --l1-cache-size N           L1 bytes per cache (default 65536)
  --cache-size N              L2 bytes (default 262144; alias --l2-cache-size)
  --l1-latency N              L1 lookup cycles (default 2)
  --l2-latency N              L2 lookup cycles (default 3)
  --dram-latency N            DRAM access cycles (default 4)
  --waves                     Generate FST waveforms
  --lint-only                 Compile/check only; do not simulate
  --keep-going                Run remaining layers after a failure; exit nonzero
  --build-dir PATH            Artifacts (default test/memory/build)
  --verilator PATH            Executable (default VERILATOR environment or PATH)
  --dry-run                   Print commands without running them
  --help                      Show this help

Individual runners: run_dram.tcl, run_l2_protocol.tcl, run_l2_integration.tcl,
run_l1i.tcl, run_l1d.tcl, run_memory_subsystem.tcl.}
}

proc memory_test::parse {arguments} {
    variable directory
    set executable verilator
    if {[info exists ::env(VERILATOR)]} {set executable $::env(VERILATOR)}
    set cfg [dict create seeds {1} random-iters 200 jobs 2 l1-cache-size 65536 \
        cache-size 262144 l1-latency 2 l2-latency 3 dram-latency 4 waves 0 \
        lint-only 0 keep-going 0 dry-run 0 verilator $executable \
        build-dir [file join $directory build]]
    for {set i 0} {$i < [llength $arguments]} {incr i} {
        set arg [lindex $arguments $i]
        switch -- $arg {
            --help {usage; return {}}
            --waves - --lint-only - --keep-going - --dry-run {
                dict set cfg [string range $arg 2 end] 1
            }
            --seed - --seeds - --random-iters - --jobs - --l1-cache-size -
            --cache-size - --l2-cache-size - --l1-latency - --l2-latency -
            --dram-latency - --build-dir - --verilator {
                incr i
                if {$i >= [llength $arguments]} {error "Missing value for $arg"}
                set value [lindex $arguments $i]
                set key [string range $arg 2 end]
                if {$key == "seed" || $key == "seeds"} {
                    dict set cfg seeds [split $value ,]
                } else {
                    if {$key == "l2-cache-size"} {set key cache-size}
                    dict set cfg $key $value
                }
            }
            default {error "Unknown option $arg (use --help)"}
        }
    }
    foreach key {random-iters jobs l1-cache-size cache-size l1-latency l2-latency dram-latency} {
        set value [dict get $cfg $key]
        if {![string is integer -strict $value] || $value < 0 || $value > 2147483647 ||
            ($value == 0 && $key != "random-iters")} {error "Invalid integer for --$key: $value"}
        dict set cfg $key [expr {$value + 0}]
    }
    if {[dict get $cfg random-iters] > 100000} {error "random-iters must be in 0..100000"}
    if {[llength [dict get $cfg seeds]] == 0} {error "At least one seed is required"}
    set seeds {}
    foreach value [dict get $cfg seeds] {
        if {![string is wideinteger -strict $value] || $value < 1 || $value > 2147483647} {
            error "Seeds must be integers in 1..2147483647"
        }
        lappend seeds [expr {$value + 0}]
    }
    dict set cfg seeds $seeds
    foreach {key maximum} {l1-cache-size 65536 cache-size 262144} {
        set value [dict get $cfg $key]
        if {$value < 1024 || $value > $maximum || ($value & ($value-1)) != 0} {
            error "$key must be a power of two in 1024..$maximum"
        }
    }
    dict set cfg build-dir [file normalize [dict get $cfg build-dir]]
    return $cfg
}

proc memory_test::execute {command log} {
    puts "Command: $command"
    set output [open $log w]
    set status [catch {exec {*}$command >@$output 2>@$output} reason]
    close $output
    set input [open $log r]
    set transcript [read $input]
    close $input
    puts $transcript
    if {$status} {error "$reason; see $log"}
    return $transcript
}

proc memory_test::run_layer {layer cfg} {
    variable directory
    variable root
    set rtl [file join $root src memory]
    set top tb_$layer
    set out [file join [dict get $cfg build-dir] $layer]
    # Separate native and container object files to avoid reusing foreign objects.
    set obj [file join $out obj_$::tcl_platform(os)_$::tcl_platform(machine)]
    set command [list [dict get $cfg verilator]]
    if {[dict get $cfg lint-only]} {lappend command --lint-only} else {lappend command --binary}
    lappend command --timing --assert -Wno-fatal -Wno-MODDUP --top-module $top --Mdir $obj -I$rtl
    if {![dict get $cfg lint-only]} {lappend command -j [dict get $cfg jobs]}
    if {[dict get $cfg waves]} {lappend command --trace-fst --trace-depth 3}
    switch -- $layer {
        dram {
            lappend command -GDRAM_LATENCY=[dict get $cfg dram-latency]
            set sources [list [file join $rtl DRAM.sv] [file join $directory tb_dram.sv]]
        }
        l2_protocol - l2_integration {
            lappend command -GCACHE_SIZE=[dict get $cfg cache-size] \
                -GL2_LATENCY=[dict get $cfg l2-latency] -GDRAM_LATENCY=[dict get $cfg dram-latency]
            set sources [list [file join $rtl L2_cache.sv] [file join $rtl DRAM.sv] \
                [file join $directory controllable_dram.sv] [file join $directory l2_assertions.sv] \
                [file join $directory tb_l2.sv] [file join $directory $top.sv]]
        }
        l1i - l1d {
            set name [expr {$layer == "l1i" ? "L1I_cache.sv" : "L1D_cache.sv"}]
            lappend command -GL1_CACHE_SIZE=[dict get $cfg l1-cache-size] \
                -GL1_LATENCY=[dict get $cfg l1-latency]
            set sources [list [file join $rtl L1_cache_interface.sv] [file join $rtl $name] \
                [file join $directory controllable_dram.sv] [file join $directory $top.sv]]
        }
        memory_subsystem {
            lappend command -GL1_CACHE_SIZE=[dict get $cfg l1-cache-size] \
                -GL2_CACHE_SIZE=[dict get $cfg cache-size] -GL1_LATENCY=[dict get $cfg l1-latency] \
                -GL2_LATENCY=[dict get $cfg l2-latency] -GDRAM_LATENCY=[dict get $cfg dram-latency]
            set sources [list [file join $rtl memory_system.sv] [file join $directory $top.sv]]
        }
        default {error "Unknown test layer $layer"}
    }
    lappend command {*}$sources
    puts "=== $layer ==="
    if {[dict get $cfg dry-run]} {puts "Build: $command"} else {
        file mkdir $out
        execute $command [file join $out build.log]
    }
    if {[dict get $cfg lint-only]} {return}
    foreach seed [dict get $cfg seeds] {
        set command [list [file join $obj V$top] +SEED=$seed +RANDOM_ITERS=[dict get $cfg random-iters]]
        if {[dict get $cfg waves]} {lappend command +WAVE_FILE=[file join $out seed_$seed.fst]}
        if {[dict get $cfg dry-run]} {puts "Run: $command"} else {
            set output [execute $command [file join $out seed_$seed.log]]
            if {![regexp -line "^PASS: ${top}( |$)" $output]} {error "$top exited without a PASS marker"}
        }
    }
}

proc memory_test::main {layers arguments} {
    if {[catch {set cfg [parse $arguments]} message]} {puts stderr "ERROR: $message"; exit 1}
    if {$cfg == {}} {return}
    if {![dict get $cfg dry-run] && [auto_execok [dict get $cfg verilator]] == {}} {
        puts stderr "ERROR: Verilator not found; use --verilator PATH or install Verilator."
        exit 1
    }
    set failed {}
    foreach layer $layers {
        if {[catch {run_layer $layer $cfg} message]} {
            puts stderr "FAIL: $layer: $message"
            lappend failed $layer
            if {![dict get $cfg keep-going]} {break}
        } elseif {![dict get $cfg dry-run]} {
            puts "OK: $layer[expr {[dict get $cfg lint-only] ? " (lint only)" : ""}]"
        }
    }
    if {[llength $failed]} {puts stderr "FAILED layers: $failed"; exit 1}
    if {![dict get $cfg dry-run]} {
        puts [expr {[dict get $cfg lint-only] ? "Lint completed: $layers" : "PASS: memory regression ($layers)"}]
    }
}
