// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class rv_timer_sanity_vseq extends rv_timer_base_vseq;
  `uvm_object_utils(rv_timer_sanity_vseq)
  `uvm_object_new

  rand bit [NUM_TIMERS-1:0] en_timers;
  rand bit [NUM_HARTS-1:0]  en_harts;

  rand uint64 timer_val[NUM_HARTS];
  rand uint64 compare_val[NUM_HARTS][NUM_TIMERS];
  rand bit    en_interrupt[NUM_HARTS][NUM_TIMERS];

  rand uint prescale[NUM_HARTS];
  rand uint step[NUM_HARTS];
  rand uint ticks[NUM_HARTS];
  rand bit  assert_reset;

  uint64 max_clks_until_expiry = 5_000_000;

  constraint assert_reset_c {
    (assert_reset == 1'b0);
  }

  constraint num_trans_c {
    num_trans inside {[1:6]};
  }

  // at least 1 timer enabled
  constraint en_timers_c {
    (|en_timers == 1'b1);
  }

  // at least 1 hart enabled
  constraint en_harts_c {
    (|en_harts == 1'b1);
  }

  // prescaler less than max prescale for enabled hart
  constraint prescale_c {
    solve en_harts before prescale;
    foreach (prescale[i]) {
      if (en_harts[i])  prescale[i] inside {[0:max_prescale]};
      else              prescale[i] == 0;
    }
  }

  // step less than max step for enabled hart
  constraint step_c {
    solve en_harts before step;
    foreach (step[i]) {
      if (en_harts[i])  step[i] inside {[1:max_step]};
      else              step[i] == 0;
    }
  }

  // ticks * prescale < max clks
  constraint ticks_c {
    solve prescale before ticks;
    foreach (ticks[i]) {
      if (en_harts[i]) {
        (ticks[i] * (prescale[i] + 1)) <= max_clks_until_expiry;
      }
    }
  }

  // timer expiry needs to occur within reasonable amount of time
  constraint timer_exp_c {
    solve en_harts before compare_val;
    solve en_timers before compare_val;
    solve timer_val before compare_val;
    solve step before compare_val;
    solve ticks before compare_val;
    foreach (en_harts[i]) {
      foreach (en_timers[j]) {
        if (en_harts[i] && en_timers[j]) {
          compare_val[i][j] == timer_val[i] + step[i] * ticks[i];
        }
      }
    }
  }

  task pre_start();
    super.pre_start();
    // Check Scoreboard is enabled
    `DV_CHECK_EQ_FATAL(cfg.en_scb, 1'b1)
  endtask

  task body();
    num_trans.rand_mode(0);
    for (int trans = 1; trans <= num_trans; trans++) begin
      `uvm_info(`gfn, $sformatf("Running test iteration %0d/%0d", trans, num_trans), UVM_LOW)

      `DV_CHECK_RANDOMIZE_FATAL(this)
      // disable timers first
      csr_wr(.csr(ral.ctrl), .value(ral.ctrl.get_reset()));

      // configure the timers and harts based on rand fields
      cfg_all_timers();

      // now enable timers
      for (int i = 0; i < NUM_HARTS; i++) begin
        for (int j = 0; j < NUM_TIMERS; j++) begin
          cfg_timer(.hart(i), .timer(j), .enable(en_timers[j]));
        end
      end

      fork
        begin : isolation_fork
          fork
            // assert reset while timer is running
            if (assert_reset) begin
              `DV_CHECK_MEMBER_RANDOMIZE_FATAL(delay)
              cfg.clk_rst_vif.wait_clks(delay);
              dut_init("HARD");
            end
          join_none

          for (int i = 0; i < NUM_HARTS; i++) begin
            automatic int a_i = i;
            fork
              // poll a intr_status continuously until it reads the expected value
              // in `timeout_ns` the delay value is mulitplied by two due to the
              // `intr_state_spinwait` task: if interrupt is set right after csr_rd, then the worst
              // case the code will wait for two `spinwait_delay_ns` before hitting the break
              // statement
              if (en_harts[a_i]) begin
                `DV_CHECK_MEMBER_RANDOMIZE_FATAL(delay)
                intr_state_spinwait(.hart(a_i), .exp_data(en_timers), .spinwait_delay_ns(delay),
                                    .timeout_ns(delay * 2 + (max_clks_until_expiry *
                                        (cfg.clk_rst_vif.clk_period_ps / 1000.0))));
              end
            join_none
          end
          wait fork;
        end : isolation_fork
      join

      // Disable timers
      csr_wr(.csr(ral.ctrl), .value(ral.ctrl.get_reset()));

      // Write one to clear the interrupt status
      for (int i = 0; i < NUM_HARTS; i++) begin
        for (int j = 0; j < NUM_TIMERS; j++) begin
          if (en_harts[i] && en_timers[j]) begin
            clear_intr_state(.hart(i), .timer(j));
          end
        end
      end

    end
  endtask : body

  // Function to calculate number of clks to interrup for given hart and timer
  function automatic uint calculate_num_clks(int hart = 0, int timer = 0);
    uint64 mtime_dif = compare_val[hart][timer] - timer_val[hart];
    calculate_num_clks = ((mtime_dif / step[hart]) +
                          ((mtime_dif % step[hart]) != 0)) * (prescale[hart] +1) + 1;
  endfunction : calculate_num_clks

  // configure all timers and harts based on rand fields
  task cfg_all_timers();
    for (int i = 0; i < NUM_HARTS; i++) begin
      cfg_hart(.hart(i), .prescale(prescale[i]), .step(step[i]));
      set_timer_val(.hart(i), .val(timer_val[i]));
      for (int j = 0; j < NUM_TIMERS; j++) begin
        set_compare_val(.hart(i), .timer(j), .val(compare_val[i][j]));
        cfg_interrupt(.hart(i), .timer(j), .enable(en_interrupt[i][j]));
      end
    end
  endtask : cfg_all_timers

endclass : rv_timer_sanity_vseq
