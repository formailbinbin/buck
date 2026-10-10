//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: 包事务
//     len 是真实载荷字节数, payload 里就是要搬的那 len 个字节
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_TRANSACTION__SV
`define BUCK_TRANSACTION__SV

// 总线宽度, 需与 buck_if / buck_sink 的 DW 保持一致
parameter int BUCK_DW  = 32;
parameter int BUCK_BPB = BUCK_DW / 8;

class buck_transaction extends uvm_sequence_item;

    rand int unsigned len;        // 包长(byte), 既是令牌开销也是实际搬运字节数
    byte unsigned     payload[];  // 真实载荷, 由 post_randomize 按 len 填充

    constraint len_c {
        len inside {[16:256]};
    }

    `uvm_object_utils_begin(buck_transaction)
        `uvm_field_int(len, UVM_ALL_ON | UVM_DEC)
        `uvm_field_array_int(payload, UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end

    function new(string name = "buck_transaction");
        super.new(name);
    endfunction

    // 载荷不进约束求解器, 直接用 $urandom 填, 避免大包随机化开销
    function void post_randomize();
        payload = new[len];
        foreach (payload[i])
            payload[i] = $urandom_range(0, 255);
    endfunction

    // 本包需要占用的总线拍数
    function int unsigned num_beats();
        return (len + BUCK_BPB - 1) / BUCK_BPB;
    endfunction

endclass: buck_transaction

`endif // BUCK_TRANSACTION__SV
