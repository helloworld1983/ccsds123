library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
use work.common.all;

entity pipeline_top is
  generic (
    PIPELINES      : integer;
    PIPELINE_INDEX : integer;
    LITTLE_ENDIAN  : boolean;
    COL_ORIENTED   : boolean;
    REDUCED        : boolean;
    OMEGA          : integer;
    D              : integer;
    P              : integer;
    CZ             : integer;
    R              : integer;
    V_MIN          : integer;
    V_MAX          : integer;
    TINC_LOG       : integer;
    UMAX           : integer;
    KZ_PRIME       : integer;
    COUNTER_SIZE   : integer;
    INITIAL_COUNT  : integer;
    NX             : integer;
    NY             : integer;
    NZ             : integer
    );
  port (
    clk     : in std_logic;
    aresetn : in std_logic;

    in_sample      : in std_logic_vector(D-1 downto 0);
    in_prev_sample : in std_logic_vector(D-1 downto 0);
    in_valid       : in std_logic;
    in_weights     : in signed(CZ*(OMEGA+3)-1 downto 0);

    -- Intermediate signals
    w_update_wr      : out std_logic;
    w_update_weights : out signed(CZ*(OMEGA+3)-1 downto 0);

    accumulator_rd      : out std_logic;
    accumulator_rd_data : in  std_logic_vector(D+COUNTER_SIZE-1 downto 0);
    accumulator_wr      : out std_logic;
    accumulator_wr_data : out std_logic_vector(D+COUNTER_SIZE-1 downto 0);

    out_central_diff       : out signed(D+2 downto 0);
    out_central_diff_valid : out std_logic;
    out_central_diff_zb    : out integer range 0 to NZ/PIPELINES-1;
    in_prev_central_diffs  : in  signed(P*(D+3)-1 downto 0);

    out_data     : out std_logic_vector(UMAX + D - 1 downto 0);
    out_num_bits : out unsigned(len2bits(UMAX + D)-1 downto 0);
    out_valid    : out std_logic;
    out_last     : out std_logic
    );
end pipeline_top;

architecture rtl of pipeline_top is
  function blk_idx(z : integer) return integer is
  begin
    return z / PIPELINES;
  end function blk_idx;

  subtype z_type is integer range 0 to NZ-1;
  subtype sample_type is signed(D-1 downto 0);
  subtype locsum_type is signed(D+2 downto 0);
  subtype weights_type is signed(CZ*(OMEGA+3)-1 downto 0);
  subtype diffs_type is signed(CZ*(D+3)-1 downto 0);

  signal s_ne : std_logic_vector(D-1 downto 0);
  signal s_n  : std_logic_vector(D-1 downto 0);
  signal s_nw : std_logic_vector(D-1 downto 0);
  signal s_w  : std_logic_vector(D-1 downto 0);

  signal from_ctrl_ctrl : ctrl_t;
  signal from_ctrl_z    : z_type;

  signal from_local_diff_ctrl   : ctrl_t;
  signal from_local_diff_valid  : std_logic;
  signal from_local_diff_z      : z_type;
  signal from_local_diff_s      : sample_type;
  signal from_local_diff_prev_s : sample_type;
  signal from_local_diff_locsum : locsum_type;
  signal d_n                    : signed(D+2 downto 0);
  signal d_nw                   : signed(D+2 downto 0);
  signal d_w                    : signed(D+2 downto 0);

  signal local_diffs      : signed(CZ*(D+3)-1 downto 0);
  signal pred_d_c         : signed(D+3+OMEGA+3+CZ-1-1 downto 0);
  signal from_dot_valid   : std_logic;
  signal from_dot_ctrl    : ctrl_t;
  signal from_dot_s       : sample_type;
  signal from_dot_prev_s  : sample_type;
  signal from_dot_locsum  : locsum_type;
  signal from_dot_z       : z_type;
  signal from_dot_weights : weights_type;
  signal from_dot_diffs   : diffs_type;

  signal from_pred_valid   : std_logic;
  signal from_pred_pred_s  : signed(D downto 0);
  signal from_pred_ctrl    : ctrl_t;
  signal from_pred_s       : sample_type;
  signal from_pred_z       : z_type;
  signal from_pred_weights : weights_type;
  signal from_pred_diffs   : diffs_type;

  signal from_w_update_valid   : std_logic;
  signal from_w_update_weights : weights_type;

  signal from_res_mapper_valid : std_logic;
  signal from_res_mapper_delta : unsigned(D-1 downto 0);
  signal from_res_mapper_z     : z_type;
  signal from_res_mapper_ctrl  : ctrl_t;

begin
  i_control : entity work.control
    generic map (
      PIPELINES      => PIPELINES,
      PIPELINE_INDEX => PIPELINE_INDEX,
      V_MIN          => V_MIN,
      V_MAX          => V_MAX,
      TINC_LOG       => TINC_LOG,
      NX             => NX,
      NY             => NY,
      NZ             => NZ,
      CZ             => CZ,
      D              => D)
    port map (
      clk     => clk,
      aresetn => aresetn,

      tick     => in_valid,
      out_ctrl => from_ctrl_ctrl,
      out_z    => from_ctrl_z);

  i_sample_store : entity work.sample_store
    generic map (
      D  => D,
      NX => NX,
      NZ => NZ/PIPELINES)
    port map (
      clk     => clk,
      aresetn => aresetn,

      in_sample => in_sample,
      in_valid  => in_valid,

      out_s_ne => s_ne,
      out_s_n  => s_n,
      out_s_nw => s_nw,
      out_s_w  => s_w);

  g_local_diff_full : if (not REDUCED) generate
    i_local_diff : entity work.local_diff
      generic map (
        COL_ORIENTED => COL_ORIENTED,
        NX           => NX,
        NZ           => NZ,
        CZ           => CZ,
        D            => D)
      port map (
        clk     => clk,
        aresetn => aresetn,

        s_cur     => signed(in_sample),
        s_ne      => signed(s_ne),
        s_n       => signed(s_n),
        s_nw      => signed(s_nw),
        s_w       => signed(s_w),
        in_prev_s => signed(in_prev_sample),
        in_valid  => in_valid,
        in_ctrl   => from_ctrl_ctrl,
        in_z      => from_ctrl_z,

        local_sum  => from_local_diff_locsum,
        d_c        => out_central_diff,
        d_n        => local_diffs((D+3)*(P+3)-1 downto (D+3)*(P+2)),
        d_w        => local_diffs((D+3)*(P+2)-1 downto (D+3)*(P+1)),
        d_nw       => local_diffs((D+3)*(P+1)-1 downto (D+3)*P),
        out_valid  => from_local_diff_valid,
        out_ctrl   => from_local_diff_ctrl,
        out_z      => from_local_diff_z,
        out_s      => from_local_diff_s,
        out_prev_s => from_local_diff_prev_s);
  end generate g_local_diff_full;

  g_local_diff_reduced : if (REDUCED) generate
    i_local_diff : entity work.local_diff
      generic map (
        COL_ORIENTED => COL_ORIENTED,
        NX           => NX,
        NZ           => NZ,
        CZ           => CZ,
        D            => D)
      port map (
        clk     => clk,
        aresetn => aresetn,

        s_cur     => signed(in_sample),
        s_ne      => signed(s_ne),
        s_n       => signed(s_n),
        s_nw      => signed(s_nw),
        s_w       => signed(s_w),
        in_prev_s => signed(in_prev_sample),
        in_valid  => in_valid,
        in_ctrl   => from_ctrl_ctrl,
        in_z      => from_ctrl_z,

        local_sum  => from_local_diff_locsum,
        d_c        => out_central_diff,
        d_n        => open,
        d_w        => open,
        d_nw       => open,
        out_valid  => from_local_diff_valid,
        out_ctrl   => from_local_diff_ctrl,
        out_z      => from_local_diff_z,
        out_s      => from_local_diff_s,
        out_prev_s => from_local_diff_prev_s);
  end generate g_local_diff_reduced;

  out_central_diff_valid <= from_local_diff_valid;
  out_central_diff_zb    <= blk_idx(from_local_diff_z);

  g_add_central_diffs : if (P > 0) generate
    local_diffs(P*(D+3)-1 downto 0) <= in_prev_central_diffs;
  end generate g_add_central_diffs;

  i_dot : entity work.dot_product
    generic map (
      N      => CZ,
      A_SIZE => D+3,
      B_SIZE => OMEGA+3,
      NX     => NX,
      NZ     => NZ,
      D      => D,
      CZ     => CZ,
      OMEGA  => OMEGA)
    port map (
      clk     => clk,
      aresetn => aresetn,

      a       => local_diffs,
      a_valid => from_local_diff_valid,
      b       => in_weights,
      b_valid => '1',
      s       => pred_d_c,
      s_valid => from_dot_valid,

      in_locsum  => from_local_diff_locsum,
      in_ctrl    => from_local_diff_ctrl,
      in_z       => from_local_diff_z,
      in_prev_s  => from_local_diff_prev_s,
      in_s       => from_local_diff_s,
      in_weights => in_weights,
      in_diffs   => local_diffs,

      out_locsum  => from_dot_locsum,
      out_ctrl    => from_dot_ctrl,
      out_z       => from_dot_z,
      out_s       => from_dot_s,
      out_prev_s  => from_dot_prev_s,
      out_weights => from_dot_weights,
      out_diffs   => from_dot_diffs);

  i_predictor : entity work.predictor
    generic map (
      NX    => NX,
      NZ    => NZ,
      D     => D,
      R     => R,
      OMEGA => OMEGA,
      P     => P,
      CZ    => CZ)
    port map (
      clk     => clk,
      aresetn => aresetn,

      in_valid => from_dot_valid,
      in_d_c   => pred_d_c,

      in_locsum  => from_dot_locsum,
      in_z       => from_dot_z,
      in_prev_s  => from_dot_prev_s,
      in_s       => from_dot_s,
      in_ctrl    => from_dot_ctrl,
      in_weights => from_dot_weights,
      in_diffs   => from_dot_diffs,

      out_valid   => from_pred_valid,
      out_pred_s  => from_pred_pred_s,
      out_z       => from_pred_z,
      out_s       => from_pred_s,
      out_ctrl    => from_pred_ctrl,
      out_weights => from_pred_weights,
      out_diffs   => from_pred_diffs);

  i_weight_update : entity work.weight_update
    generic map (
      REDUCED => REDUCED,
      NX      => NX,
      NZ      => NZ,
      OMEGA   => OMEGA,
      D       => D,
      R       => R,
      CZ      => CZ,
      V_MIN   => V_MIN,
      V_MAX   => V_MAX)
    port map (
      clk     => clk,
      aresetn => aresetn,

      in_ctrl    => from_pred_ctrl,
      in_s       => from_pred_s,
      in_pred_s  => from_pred_pred_s,
      in_diffs   => from_pred_diffs,
      in_valid   => from_pred_valid,
      in_weights => from_pred_weights,

      out_valid   => from_w_update_valid,
      out_weights => from_w_update_weights);

  w_update_wr      <= from_w_update_valid;
  w_update_weights <= from_w_update_weights;

  i_residual_mapper : entity work.residual_mapper
    generic map (
      D  => D,
      NZ => NZ)
    port map (
      clk     => clk,
      aresetn => aresetn,

      in_valid         => from_pred_valid,
      in_ctrl          => from_pred_ctrl,
      in_z             => from_pred_z,
      in_s             => from_pred_s,
      in_scaled_pred_s => from_pred_pred_s,

      out_valid => from_res_mapper_valid,
      out_ctrl  => from_res_mapper_ctrl,
      out_z     => from_res_mapper_z,
      out_delta => from_res_mapper_delta);

  i_sa_encoder : entity work.sa_encoder
    generic map (
      NZB           => NZ/PIPELINES,
      D             => D,
      UMAX          => UMAX,
      KZ_PRIME      => KZ_PRIME,
      COUNTER_SIZE  => COUNTER_SIZE,
      INITIAL_COUNT => INITIAL_COUNT)
    port map (
      clk     => clk,
      aresetn => aresetn,

      in_valid    => from_res_mapper_valid,
      in_ctrl     => from_res_mapper_ctrl,
      in_zb       => blk_idx(from_res_mapper_z),
      in_residual => from_res_mapper_delta,

      accumulator_rd_data => accumulator_rd_data,
      accumulator_wr      => accumulator_wr,
      accumulator_wr_data => accumulator_wr_data,

      out_valid    => out_valid,
      out_last     => out_last,
      out_data     => out_data,
      out_num_bits => out_num_bits);

  accumulator_rd <= from_res_mapper_valid;

end rtl;
