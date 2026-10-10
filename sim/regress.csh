#!/bin/csh -f
#######################################################################################
#     dem_buck demo: 回归脚本
#     用法: cd dem_buck/sim && ./regress.csh
#######################################################################################

cd `dirname $0`

set tc_list = "tc_buck_base tc_buck_rate tc_buck_burst tc_buck_pps tc_buck_shared tc_buck_beatgap"

mkdir -p log

foreach tc ($tc_list)
    echo "##### $tc #####"
    ./simv +UVM_TESTNAME=$tc +UVM_VERBOSITY=UVM_LOW +ntb_random_seed=1 +TIMEOUT_MS=50 -l log/$tc.log
end

echo ""
echo "########## regress summary ##########"
foreach tc ($tc_list)
    echo "----- $tc -----"
    grep -A 6 "result ====" log/$tc.log | grep -E "configured|measured|error"
    grep -E "^UVM_ERROR |^UVM_FATAL " log/$tc.log
end
