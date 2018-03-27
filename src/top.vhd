library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
use work.common.all;

entity ccsds123_top is
  generic (
    LITTLE_ENDIAN : boolean := true;
    COL_ORIENTED  : boolean := false;
    REDUCED       : boolean := false;
    OMEGA         : integer := 19;
    D             : integer := 16;
    P             : integer := 15;
    R             : integer := 64;
    TINC_LOG      : integer := 4;
    V_MIN         : integer := -6;
    V_MAX         : integer := 9;
    UMAX          : integer := 9;
    KZ_PRIME      : integer := 8;
    COUNTER_SIZE  : integer := 8;
    INITIAL_COUNT : integer := 6;
    BUS_WIDTH     : integer := 64;
    NX            : integer := 500;
    NY            : integer := 500;
    NZ            : integer := 10
    );
  port (
    clk     : in std_logic;
    aresetn : in std_logic;

    -- Input AXI stream
    in_tdata  : in  std_logic_vector(D-1 downto 0);
    in_tvalid : in  std_logic;
    in_tready : out std_logic;

    out_tdata  : out std_logic_vector(BUS_WIDTH-1 downto 0);
    out_tvalid : out std_logic;
    out_tlast  : out std_logic
    );
end ccsds123_top;

architecture rtl of ccsds123_top is
  function CZ return integer is
  begin
    if (REDUCED) then
      return P;
    else
      return P + 3;
    end if;
  end function CZ;

  signal in_handshake : std_logic;
  signal in_ready     : std_logic;

  subtype z_type is integer range 0 to NZ-1;
  subtype sample_type is signed(D-1 downto 0);
  subtype locsum_type is signed(D+2 downto 0);
  subtype weights_type is signed(CZ*(OMEGA+3)-1 downto 0);
  subtype diffs_type is signed(CZ*(D+3)-1 downto 0);

  signal from_ctrl_ctrl : ctrl_t;
  signal from_ctrl_z    : integer range 0 to NZ-1;

  signal s_ne : std_logic_vector(D-1 downto 0);
  signal s_n  : std_logic_vector(D-1 downto 0);
  signal s_nw : std_logic_vector(D-1 downto 0);
  signal s_w  : std_logic_vector(D-1 downto 0);

  signal from_local_diff_ctrl   : ctrl_t;
  signal from_local_diff_valid  : std_logic;
  signal from_local_diff_z      : z_type;
  signal from_local_diff_s      : sample_type;
  signal from_local_diff_locsum : locsum_type;
  signal d_c                    : signed(D+2 downto 0);
  signal d_n                    : signed(D+2 downto 0);
  signal d_nw                   : signed(D+2 downto 0);
  signal d_w                    : signed(D+2 downto 0);

  signal local_diffs      : signed(CZ*(D+3)-1 downto 0);
  signal weights          : signed(CZ*(OMEGA+3)-1 downto 0);
  signal pred_d_c         : signed(D+3+OMEGA+3+CZ-1-1 downto 0);
  signal from_dot_valid   : std_logic;
  signal from_dot_ctrl    : ctrl_t;
  signal from_dot_s       : sample_type;
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
  signal from_w_update_z       : z_type;
  signal from_w_update_weights : weights_type;

  signal from_res_mapper_valid : std_logic;
  signal from_res_mapper_delta : unsigned(D-1 downto 0);
  signal from_res_mapper_z     : z_type;
  signal from_res_mapper_ctrl  : ctrl_t;

  signal from_encoder_valid    : std_logic;
  signal from_encoder_last     : std_logic;
  signal from_encoder_data     : std_logic_vector(UMAX + D-1 downto 0);
  signal from_encoder_num_bits : unsigned(len2bits(UMAX + D) - 1 downto 0);

  signal combiner_over_threshold : std_logic;
begin
  in_handshake <= in_tvalid and in_ready;
  in_tready    <= in_ready;

  i_control : entity work.control
    generic map (
      V_MIN    => V_MIN,
      V_MAX    => V_MAX,
      TINC_LOG => TINC_LOG,
      NX       => NX,
      NY       => NY,
      NZ       => NZ,
      CZ       => CZ,
      D        => D)
    port map (
      clk     => clk,
      aresetn => aresetn,

      tick               => in_handshake,
      w_upd_handshake    => from_w_update_valid,
      ready              => in_ready,
      out_over_threshold => combiner_over_threshold,

      out_ctrl => from_ctrl_ctrl,
      out_z    => from_ctrl_z);

  i_sample_store : entity work.sample_store
    generic map (
      D  => D,
      NX => NX,
      NZ => NZ)
    port map (
      clk     => clk,
      aresetn => aresetn,

      in_sample => in_tdata,
      in_valid  => in_handshake,

      out_s_ne => s_ne,
      out_s_n  => s_n,
      out_s_nw => s_nw,
      out_s_w  => s_w);

  g_local_diff_full : if (not REDUCED) generate
    i_local_diff : entity work.local_diff
      generic map (
        COL_ORIENTED => COL_ORIENTED,
        NX           => NX,
        NY           => NY,
        NZ           => NZ,
        CZ           => CZ,
        D            => D)
      port map (
        clk     => clk,
        aresetn => aresetn,

        s_cur    => signed(in_tdata),
        s_ne     => signed(s_ne),
        s_n      => signed(s_n),
        s_nw     => signed(s_nw),
        s_w      => signed(s_w),
        in_valid => in_handshake,
        in_ctrl  => from_ctrl_ctrl,
        in_z     => from_ctrl_z,

        local_sum => from_local_diff_locsum,
        d_c       => d_c,
        d_n       => local_diffs((D+3)*(P+3)-1 downto (D+3)*(P+2)),
        d_w       => local_diffs((D+3)*(P+2)-1 downto (D+3)*(P+1)),
        d_nw      => local_diffs((D+3)*(P+1)-1 downto (D+3)*P),
        out_valid => from_local_diff_valid,
        out_ctrl  => from_local_diff_ctrl,
        out_z     => from_local_diff_z,
        out_s     => from_local_diff_s);
  end generate g_local_diff_full;

  g_local_diff_reduced : if (REDUCED) generate
    i_local_diff : entity work.local_diff
      generic map (
        COL_ORIENTED => COL_ORIENTED,
        NX           => NX,
        NY           => NY,
        NZ           => NZ,
        CZ           => CZ,
        D            => D)
      port map (
        clk     => clk,
        aresetn => aresetn,

        s_cur    => signed(in_tdata),
        s_ne     => signed(s_ne),
        s_n      => signed(s_n),
        s_nw     => signed(s_nw),
        s_w      => signed(s_w),
        in_valid => in_handshake,
        in_ctrl  => from_ctrl_ctrl,
        in_z     => from_ctrl_z,

        local_sum => from_local_diff_locsum,
        d_c       => d_c,
        d_n       => open,
        d_w       => open,
        d_nw      => open,
        out_valid => from_local_diff_valid,
        out_ctrl  => from_local_diff_ctrl,
        out_z     => from_local_diff_z,
        out_s     => from_local_diff_s);
  end generate g_local_diff_reduced;

  g_local_diff_store : if (P > 0) generate
    i_local_diff_store : entity work.local_diff_store
      generic map (
        NZ => NZ,
        P  => P,
        D  => D)
      port map (
        clk     => clk,
        aresetn => aresetn,

        wr            => from_local_diff_valid,
        wr_local_diff => d_c,
        z             => from_local_diff_z,

        local_diffs => local_diffs((D+3)*P-1 downto 0));
  end generate g_local_diff_store;

  i_weight_store : entity work.weight_store
    generic map (
      DELAY => 3,
      OMEGA => OMEGA,
      CZ    => CZ,
      NZ    => NZ)
    port map (
      clk     => clk,
      aresetn => aresetn,

      wr        => from_w_update_valid,
      wr_z      => from_w_update_z,
      wr_weight => from_w_update_weights,

      rd        => in_handshake,
      rd_z      => from_ctrl_z,
      rd_weight => weights);

  i_dot : entity work.dot_product
    generic map (
      N      => CZ,
      A_SIZE => D+3,
      B_SIZE => OMEGA+3,
      NX     => NX,
      NY     => NY,
      NZ     => NZ,
      D      => D,
      CZ     => CZ,
      OMEGA  => OMEGA)
    port map (
      clk     => clk,
      aresetn => aresetn,

      a       => local_diffs,
      a_valid => from_local_diff_valid,
      b       => weights,
      b_valid => '1',
      s       => pred_d_c,
      s_valid => from_dot_valid,

      in_locsum  => from_local_diff_locsum,
      in_ctrl    => from_local_diff_ctrl,
      in_z       => from_local_diff_z,
      in_s       => from_local_diff_s,
      in_weights => weights,
      in_diffs   => local_diffs,

      out_locsum  => from_dot_locsum,
      out_ctrl    => from_dot_ctrl,
      out_z       => from_dot_z,
      out_s       => from_dot_s,
      out_weights => from_dot_weights,
      out_diffs   => from_dot_diffs);

  i_predictor : entity work.predictor
    generic map (
      NX    => NX,
      NY    => NY,
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
      NY      => NY,
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
      in_z       => from_pred_z,
      in_s       => from_pred_s,
      in_pred_s  => from_pred_pred_s,
      in_diffs   => from_pred_diffs,
      in_valid   => from_pred_valid,
      in_weights => from_pred_weights,

      out_valid   => from_w_update_valid,
      out_z       => from_w_update_z,
      out_weights => from_w_update_weights);

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
      NZ            => NZ,
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
      in_z        => from_res_mapper_z,
      in_residual => from_res_mapper_delta,

      out_valid    => from_encoder_valid,
      out_last     => from_encoder_last,
      out_data     => from_encoder_data,
      out_num_bits => from_encoder_num_bits);

  i_packer : entity work.combiner
    generic map (
      BLOCK_SIZE    => 64,
      N_WORDS       => 1,
      MAX_LENGTH    => UMAX + D,
      LITTLE_ENDIAN => LITTLE_ENDIAN)
    port map (
      clk     => clk,
      aresetn => aresetn,

      in_words   => from_encoder_data,
      in_lengths => from_encoder_num_bits,
      in_valid   => from_encoder_valid,
      in_last    => from_encoder_last,

      out_data  => out_tdata,
      out_valid => out_tvalid,
      out_last  => out_tlast,

      over_threshold => combiner_over_threshold
      );

end rtl;
