# RFSoC4x2 Board Configuration
# OpenWiFi port to RFSoC platform with integrated RF Data Converters

set origin_dir [file dirname [info script]]

# HDL source files for RFSoC4x2 board
set files [list \
 [file normalize "${origin_dir}/src/system_wrapper.v"] \
 [file normalize "${origin_dir}/src/system.bd"] \
 [file normalize "${origin_dir}/src/system_top.v"] \
 [file normalize "${origin_dir}/ip_repo/openofdm_rx/src/atan_lut.coe"] \
 [file normalize "${origin_dir}/ip_repo/openofdm_rx/src/deinter_lut.coe"] \
 [file normalize "${origin_dir}/ip_repo/openofdm_rx/src/rot_lut.coe"] \
]

# Constraint files
set files_xdc [list \
 [file normalize "${origin_dir}/src/rfsoc4x2_constr.xdc"] \
 [file normalize "${origin_dir}/src/system.xdc"] \
]

# IP repositories (no ADI HDL needed for RFSoC - integrated RF frontend)
set ip_repos [list \
 [file normalize "$origin_dir/ip_repo/"] \
]

# Board part repository (RealDigital RFSoC4x2 board files)
set board_part_repos [list \
 [file normalize "$origin_dir/../../board_files/"] \
]
