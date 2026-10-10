// dem_buck demo filelist for VCS
// RTL
${DEM_BUCK_HOME}/rtl/buck_sink.v

// interface 需在 package 之前编译
+incdir+${DEM_BUCK_HOME}/env
+incdir+${DEM_BUCK_HOME}/tc
${DEM_BUCK_HOME}/env/buck_if.sv
${DEM_BUCK_HOME}/env/buck_pkg.sv

// testbench top
${DEM_BUCK_HOME}/th/tb_top.sv
