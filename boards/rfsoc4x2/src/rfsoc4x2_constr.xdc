# RFSoC4x2 Pin Constraints
# GPIO, LED, and external interface constraints

# LEDs
set_property PACKAGE_PIN E16 [get_ports {gpio_led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_led[0]}]
set_property PACKAGE_PIN F16 [get_ports {gpio_led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_led[1]}]

# Buttons (if used for debug/control)
# set_property PACKAGE_PIN D19 [get_ports {gpio_button[0]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {gpio_button[0]}]

# PMOD connectors (for debug signals, ILA triggers, etc.)
# PMOD0
# set_property PACKAGE_PIN G14 [get_ports {pmod0[0]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {pmod0[0]}]

# Note: RFSoC4x2 RF interfaces are internal to the chip
# No external RF pin constraints needed (ADC/DAC are on-chip)
# SYSREF and reference clocks are also typically internal or from clock chips

# Optional: External clock input (if using external LMK/LMX)
# set_property PACKAGE_PIN XX [get_ports sysref_in_p]
# set_property PACKAGE_PIN YY [get_ports sysref_in_n]
# set_property IOSTANDARD LVDS [get_ports sysref_in_p]
# set_property DIFF_TERM_ADV TERM_100 [get_ports sysref_in_p]
