# Synthesis and Implementation Strategy for RFSoC4x2
# Based on ZCU102 strategy, optimized for Zynq UltraScale+ RFSoC

# Create synthesis run
set obj [get_runs synth_1]
set_property -name "strategy" -value "Vivado Synthesis Defaults" -objects $obj
set_property -name "steps.synth_design.args.directive" -value "Default" -objects $obj
set_property -name "steps.synth_design.args.retiming" -value "1" -objects $obj
set_property -name "steps.synth_design.args.fsm_extraction" -value "auto" -objects $obj
set_property -name "steps.synth_design.args.keep_equivalent_registers" -value "1" -objects $obj
set_property -name "steps.synth_design.args.resource_sharing" -value "auto" -objects $obj
set_property -name "steps.synth_design.args.no_lc" -value "0" -objects $obj
set_property -name "steps.synth_design.args.shreg_min_size" -value "5" -objects $obj
set_property -name "steps.synth_design.args.more options" -value "-generic NUM_CLK_PER_US=100" -objects $obj

# Create implementation run
set obj [get_runs impl_1]
set_property -name "strategy" -value "Performance_ExplorePostRoutePhysOpt" -objects $obj
set_property -name "steps.opt_design.args.directive" -value "ExploreWithRemap" -objects $obj
set_property -name "steps.place_design.args.directive" -value "Explore" -objects $obj
set_property -name "steps.phys_opt_design.is_enabled" -value "1" -objects $obj
set_property -name "steps.phys_opt_design.args.directive" -value "Explore" -objects $obj
set_property -name "steps.route_design.args.directive" -value "Explore" -objects $obj
set_property -name "steps.post_route_phys_opt_design.is_enabled" -value "1" -objects $obj
set_property -name "steps.post_route_phys_opt_design.args.directive" -value "Explore" -objects $obj
set_property -name "steps.write_bitstream.args.readback_file" -value "0" -objects $obj
set_property -name "steps.write_bitstream.args.verbose" -value "0" -objects $obj

# Report configurations
set_property STEPS.SYNTH_DESIGN.REPORT_STRATEGY {Vivado Synthesis Default Reports} [get_runs synth_1]
set_property STEPS.ROUTE_DESIGN.REPORT_STRATEGY {Vivado Implementation Default Reports} [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
