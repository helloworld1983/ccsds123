library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.all;
use ieee.math_real.all;
use work.common.all;

entity shared_store is
  generic (
    PIPELINES    : integer;
    DELAY        : integer;
    ELEMENT_SIZE : integer;
    ELEMENTS     : integer
    );

  port (
    clk     : in std_logic;
    aresetn : in std_logic;

    wr      : in std_logic;
    wr_data : in std_logic_vector(PIPELINES*ELEMENT_SIZE-1 downto 0);

    rd      : in  std_logic;
    rd_data : out std_logic_vector(PIPELINES*ELEMENT_SIZE-1 downto 0)
    );
end shared_store;

architecture rtl of shared_store is
  constant STEP     : integer := ELEMENTS mod PIPELINES;
  constant RAM_SIZE : integer := integer(ceil(real(ELEMENTS)/real(PIPELINES)));

  type delay_stages_t is array (0 to DELAY-1) of std_logic_vector(PIPELINES*ELEMENT_SIZE-1 downto 0);
  signal delay_stages : delay_stages_t;
  signal rd_data_vec  : std_logic_vector(PIPELINES*ELEMENT_SIZE-1 downto 0);

  signal rd_cnt : integer range 0 to RAM_SIZE-1;
  signal wr_cnt : integer range 0 to RAM_SIZE-1;

  type idx_arr_t is array (0 to PIPELINES-1) of integer range 0 to RAM_SIZE-1;
  signal wr_idx : idx_arr_t;

  type data_arr_t is array (0 to PIPELINES-1) of std_logic_vector(ELEMENT_SIZE-1 downto 0);
  signal wr_data_arr : data_arr_t;
  signal rd_data_arr : data_arr_t;
begin
  g_rams : for i in 0 to PIPELINES-1 generate
    -- Write data and address must be remapped based on relationship between
    -- number of pipelines and number of planes in the cube
    wr_data_arr((i + STEP) mod PIPELINES) <= wr_data((i+1)*ELEMENT_SIZE-1 downto i*ELEMENT_SIZE);
    wr_idx((i + STEP) mod PIPELINES)      <= wr_cnt when i + STEP < PIPELINES else wrap_inc(wr_cnt, RAM_SIZE-1);

    -- Read data maps directly to pipelines
    rd_data_vec((i+1)*ELEMENT_SIZE-1 downto i*ELEMENT_SIZE) <= rd_data_arr(i);

    i_bram : entity work.dp_bram
      generic map (
        ELEMENTS     => RAM_SIZE,
        ELEMENT_SIZE => ELEMENT_SIZE)
      port map (
        clk     => clk,
        aresetn => aresetn,

        wr     => wr,
        wraddr => wr_idx(i),
        wrdata => wr_data_arr(i),

        rd     => rd,
        rdaddr => rd_cnt,
        rddata => rd_data_arr(i));
  end generate g_rams;

  process (clk)
  begin
    if (rising_edge(clk)) then
      if (aresetn = '0') then
        wr_cnt <= 0;

        -- Start read count at 1 so that reading is always behind writing.
        -- Otherwise we can end (due to pipeline stalls) in a situation where
        -- a read is attempted in the same location as currently being written
        -- to.
        if (ELEMENTS mod PIPELINES /= 0) then
          rd_cnt <= 1;
        else
          rd_cnt <= 0;
        end if;
        delay_stages <= (others => (others => '0'));
      else
        if (rd = '1') then
          rd_cnt <= wrap_inc(rd_cnt, RAM_SIZE-1);
        end if;
        if (wr = '1') then
          wr_cnt <= wrap_inc(wr_cnt, RAM_SIZE-1);
        end if;

        if (DELAY > 0) then
          delay_stages(0) <= rd_data_vec;

          for i in 1 to DELAY-1 loop
            delay_stages(i) <= delay_stages(i-1);
          end loop;
        end if;
      end if;
    end if;
  end process;

  rd_data <= delay_stages(DELAY-1) when DELAY > 0 else rd_data_vec;
end rtl;
