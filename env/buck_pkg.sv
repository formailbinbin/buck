//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: package, 统一 include 顺序
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_PKG__SV
`define BUCK_PKG__SV

package buck_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "buck_transaction.sv"
    `include "token_bucket.sv"
    `include "buck_sequence.sv"
    `include "buck_driver.sv"
    `include "buck_monitor.sv"
    `include "buck_env.sv"
    `include "buck_test.sv"

endpackage: buck_pkg

`endif // BUCK_PKG__SV
