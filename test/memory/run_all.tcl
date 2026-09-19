source [file join [file dirname [info script]] run_common.tcl]
memory_test::main {dram l2_protocol l2_integration l1i l1d memory_subsystem} $argv
