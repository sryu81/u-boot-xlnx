if { $argc < 2 } {
    puts "ERROR: Not enough arguments."
    puts "Usage: xsct create_fsbl_only_2020.2.tcl <platform_name> <path_to_xsa_file>"
    exit 1
}

set platform_name [lindex $argv 0]
set xsa_file [lindex $argv 1]
set workspace_dir "./${platform_name}"

puts "INFO: Setting workspace to: $workspace_dir"
setws $workspace_dir

puts "INFO: Creating platform '$platform_name'..."
platform create -name $platform_name -hw $xsa_file

puts "INFO: Setting platform '$platform_name' as active..."
platform active $platform_name

puts "INFO: Explicitly creating the standalone software domain..."
domain create -name {standalone_ps7_cortexa9_0} -os {standalone} -proc {ps7_cortexa9_0}

puts "INFO: (First) Generating platform to create the base BSP..."
platform generate

puts "INFO: Adding xilffs library to standalone domain (FSBL dependency)..."
domain active {standalone_ps7_cortexa9_0}
bsp setlib -name xilffs

puts "INFO: (Second) Regenerating platform to commit library change..."
platform generate

puts "INFO: Creating FSBL application..."
app create -name fsbl -platform $platform_name -domain standalone_ps7_cortexa9_0 -template {Zynq FSBL}

puts "INFO: Configuring FSBL Application Compiler Settings for QSPI..."
#app config -name fsbl -add define "FSBL_SD_EXCLUDE=1"
app config -name fsbl -add define "FSBL_DEBUG_INFO=1"

puts "INFO: Building the FSBL application..."
app build -name fsbl

puts "INFO: Script finished successfully."
puts "INFO: Your QSPI-configured 'fsbl.elf' is ready in '$workspace_dir/fsbl/Debug/'"