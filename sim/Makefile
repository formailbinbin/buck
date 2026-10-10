#######################################################################################
#     dem_buck demo Makefile (VCS)
#
#     用法:
#       source /data2/project/Su2520/taohu/Su2520/script/project.cshrc
#       make comp                 # 编译
#       make run TC=tc_buck_base  # 跑单个 case
#       make all TC=tc_buck_rate  # 编译+仿真
#       make regress              # 跑全部 case
#       make wave TC=tc_buck_base # 带 fsdb 波形
#       make verdi TC=tc_buck_base
#       make clean
#######################################################################################

DEM_BUCK_HOME := $(shell cd $(dir $(lastword $(MAKEFILE_LIST)))/.. && pwd)
export DEM_BUCK_HOME

TC        ?= tc_buck_base
SEED      ?= 1
VERB      ?= UVM_LOW
TIMEOUT_MS ?= 50

SIMV      := $(DEM_BUCK_HOME)/sim/simv
LOG_DIR   := $(DEM_BUCK_HOME)/sim/log
LOG       := $(LOG_DIR)/$(TC).log

# 全部 testcase
TC_LIST   := tc_buck_base tc_buck_rate tc_buck_burst tc_buck_pps tc_buck_shared tc_buck_beatgap

VCS_OPTS  = -full64 -sverilog -timescale=1ns/1ps \
            -ntb_opts uvm \
            +define+UVM_NO_DEPRECATED \
            -debug_access+all \
            +lint=TFIPC-L \
            -kdb \
            -l $(LOG_DIR)/comp.log \
            -o $(SIMV) \
            -f $(DEM_BUCK_HOME)/cfg/tb.f

SIM_OPTS  = +UVM_TESTNAME=$(TC) \
            +UVM_VERBOSITY=$(VERB) \
            +ntb_random_seed=$(SEED) \
            +TIMEOUT_MS=$(TIMEOUT_MS) \
            -l $(LOG)

.PHONY: all comp run wave verdi regress clean help

all: comp run

$(LOG_DIR):
	@mkdir -p $(LOG_DIR)

comp: $(LOG_DIR)
	@echo "==== compiling dem_buck ===="
	cd $(DEM_BUCK_HOME)/sim && vcs $(VCS_OPTS)

run: $(LOG_DIR)
	@echo "==== running $(TC) ===="
	cd $(DEM_BUCK_HOME)/sim && $(SIMV) $(SIM_OPTS)
	@echo "---- log: $(LOG) ----"

wave: $(LOG_DIR)
	cd $(DEM_BUCK_HOME)/sim && $(SIMV) $(SIM_OPTS) +FSDB

verdi:
	cd $(DEM_BUCK_HOME)/sim && verdi -dbdir $(SIMV).daidir -ssf tb_top.fsdb &

regress: comp
	@for tc in $(TC_LIST); do \
	    echo "==== regress: $$tc ===="; \
	    $(MAKE) run TC=$$tc SEED=$(SEED); \
	done
	@echo ""
	@echo "==== regress summary ===="
	@grep -H "TC_RESULT" -A 6 $(LOG_DIR)/tc_buck_*.log | grep -E "configured|measured|error" || true

clean:
	rm -rf $(DEM_BUCK_HOME)/sim/simv* $(DEM_BUCK_HOME)/sim/csrc \
	       $(DEM_BUCK_HOME)/sim/*.fsdb $(DEM_BUCK_HOME)/sim/*.vpd \
	       $(DEM_BUCK_HOME)/sim/ucli.key $(DEM_BUCK_HOME)/sim/vc_hdrs.h \
	       $(DEM_BUCK_HOME)/sim/novas* $(DEM_BUCK_HOME)/sim/verdiLog \
	       $(LOG_DIR)

help:
	@echo "make comp                 # compile"
	@echo "make run TC=<testcase>    # simulate"
	@echo "make all TC=<testcase>    # compile + simulate"
	@echo "make regress              # run all testcases"
	@echo "make wave TC=<testcase>   # simulate with fsdb"
	@echo "make clean"
	@echo ""
	@echo "available TC: $(TC_LIST)"
