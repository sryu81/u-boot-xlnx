if { $argc < 2 } {
    puts "ERROR: Not enough arguments."
    puts "Usage: xsct create_fsbl_only_2020.2.tcl <platform_name> <path_to_xsa_file>"
    exit 1
}

set platform_name [lindex $argv 0]
set xsa_file [lindex $argv 1]
set workspace_dir "./${platform_name}"

setws ./$platform_name
puts "INFO: Creating FSBL application..."
app create -name fsbl -platform $platform_name -hw $xsa_file -proc ps7_cortexa9_0 -lang c -template {Empty Application}
bsp setlib -name xilffs

puts "INFO: Configuring FSBL Application Compiler Settings for QSPI..."
app config -name fsbl -add define "FSBL_SD_EXCLUDE=1"
app config -name fsbl -add define "FSBL_DEBUG_INFO=1"

puts "INFO: Building the FSBL application..."
app build -name fsbl
#platform generate

file copy -force ./$platform_name/System/zynq_fsbl/fsbl.elf ./fsbl_sf.elf
puts "INFO: Script finished successfully."
puts "INFO: Your QSPI-configured 'fsbl_sf.elf'"