--------------------------------------------------------------------------------
-- Variable length word combiner
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.all;
use work.common.all;

library xpm;
use xpm.vcomponents.all;

entity combiner is
  generic (
    BLOCK_SIZE    : integer;
    N_WORDS       : integer;
    MAX_LENGTH    : integer;
    LITTLE_ENDIAN : boolean
    );
  port (
    clk     : in std_logic;
    aresetn : in std_logic;

    in_words   : in std_logic_vector(N_WORDS * MAX_LENGTH - 1 downto 0);
    in_lengths : in unsigned(N_WORDS * num2bits(MAX_LENGTH) - 1 downto 0);
    in_valid   : in std_logic;
    in_last    : in std_logic;

    out_data  : out std_logic_vector(BLOCK_SIZE-1 downto 0);
    out_valid : out std_logic;
    out_last  : out std_logic;
    out_ready : in  std_logic;

    over_threshold : out std_logic
    );
end combiner;

architecture rtl of combiner is
  constant LENGTH_BITS         : integer := num2bits(MAX_LENGTH);
  constant BLOCK_SIZE_BITS     : integer := len2bits(BLOCK_SIZE);
  constant MAX_BLOCKS_PER_WORD : integer := (BLOCK_SIZE + MAX_LENGTH) / BLOCK_SIZE;
  constant MAX_BLOCKS          : integer := (BLOCK_SIZE - 1 + N_WORDS * MAX_LENGTH) / BLOCK_SIZE + 1;

  constant COUNTER_SIZE : integer := num2bits(MAX_BLOCKS);

  constant FIFO_DEPTH : integer := 128;

  -- The FIFO margin is the number of empty spaces in the FIFO when
  -- over_threshold is asserted. This must be large enough so that the FIFO can
  -- store the words coming out of the pipelines after the stream coming into
  -- the core has been stopped.
  constant FIFO_MARGIN : integer := 30;

  -- Element size in FIFO:
  --   * Data (blocks): MAX_BLOCKS * BLOCK_SIZE bits
  --   * Counter:       COUNTER_SIZE bits
  --   * Last flag:     1 bit
  constant FIFO_SIZE : integer := MAX_BLOCKS * BLOCK_SIZE + COUNTER_SIZE + 1;

  type word_arr_t is array (0 to 1, 0 to N_WORDS-1) of std_logic_vector(BLOCK_SIZE + MAX_LENGTH - 2 downto 0);
  type shift_arr_t is array (0 to N_WORDS-1) of integer range 0 to BLOCK_SIZE-1;
  type n_blocks_arr_t is array (0 to 1, 0 to N_WORDS-1) of integer range 0 to MAX_BLOCKS_PER_WORD;
  type full_blocks_t is array (0 to MAX_BLOCKS-1) of std_logic_vector(BLOCK_SIZE-1 downto 0);

  signal shift_arr    : shift_arr_t;
  signal n_blocks_arr : n_blocks_arr_t;
  signal words        : word_arr_t;
  signal full_blocks  : full_blocks_t;
  signal valid_regs   : std_logic_vector(1 downto 0);
  signal last_regs    : std_logic_vector(1 downto 0);

  -- Indication of whether there is some leftover bits to flush when LAST = 1
  signal last_flush_regs : std_logic_vector(1 downto 0);

  signal fifo_rden        : std_logic;
  signal fifo_wren        : std_logic;
  signal fifo_empty       : std_logic;
  signal fifo_in          : std_logic_vector(FIFO_SIZE-1 downto 0);
  signal fifo_out         : std_logic_vector(FIFO_SIZE-1 downto 0);
  signal to_fifo_count    : integer range 0 to MAX_BLOCKS;
  signal to_fifo_last     : std_logic;
  signal from_fifo_last   : std_logic;
  signal from_fifo_valid  : std_logic;
  signal from_fifo_count  : integer range 0 to MAX_BLOCKS;
  signal from_fifo_blocks : full_blocks_t;

  signal out_handshake : std_logic;

  signal counter : integer range 0 to MAX_BLOCKS-1;
begin

  process (clk)
    constant SUM_SIZE           : integer := len2bits(BLOCK_SIZE + MAX_LENGTH);
    variable sum                : unsigned(SUM_SIZE-1 downto 0);
    variable num_remaining_bits : unsigned(BLOCK_SIZE_BITS-1 downto 0);
    variable remaining_bits     : std_logic_vector(BLOCK_SIZE + MAX_LENGTH-2 downto 0);
    variable temp               : std_logic_vector(BLOCK_SIZE + MAX_LENGTH-2 downto 0);
    variable count              : integer range 0 to MAX_BLOCKS - 1;
  begin
    if (rising_edge(clk)) then
      if (aresetn = '0') then
        full_blocks        <= (others => (others => '0'));
        remaining_bits     := (others => '0');
        words              <= (others => (others => (others => '0')));
        num_remaining_bits := (others => '0');
        valid_regs         <= (others => '0');
        last_flush_regs    <= (others => '0');
      else
        --------------------------------------------------------------------------------
        -- Stage 1 - Compute shift amounts and number of blocks
        --------------------------------------------------------------------------------
        if (in_valid = '1') then
          for i in 0 to N_WORDS-1 loop
            words(0, i) <= in_words((i+1)*MAX_LENGTH-1 downto i*MAX_LENGTH) & (BLOCK_SIZE-2 downto 0 => '0');

            -- Compute bits left after this word is shifted in
            sum                := resize(num_remaining_bits, SUM_SIZE) + in_lengths((i+1)*LENGTH_BITS-1 downto i*LENGTH_BITS);
            shift_arr(i)       <= to_integer(num_remaining_bits);
            n_blocks_arr(0, i) <= to_integer(sum(sum'high downto BLOCK_SIZE_BITS));
            num_remaining_bits := sum(BLOCK_SIZE_BITS-1 downto 0);
          end loop;
          if (in_last = '1') then
            if (num_remaining_bits /= 0) then
              last_flush_regs(0) <= '1';
            else
              last_flush_regs(0) <= '0';
            end if;
            num_remaining_bits := (others => '0');
          end if;
        end if;
        valid_regs(0) <= in_valid;
        last_regs(0)  <= in_last;

        --------------------------------------------------------------------------------
        -- Stage 2 - Shift each incoming word
        --------------------------------------------------------------------------------
        if (valid_regs(0) = '1') then
          for i in 0 to N_WORDS-1 loop
            n_blocks_arr(1, i) <= n_blocks_arr(0, i);
            words(1, i)        <= std_logic_vector(shift_right(unsigned(words(0, i)), shift_arr(i)));
          end loop;
        end if;
        valid_regs(1)      <= valid_regs(0);
        last_regs(1)       <= last_regs(0);
        last_flush_regs(1) <= last_flush_regs(0);

        --------------------------------------------------------------------------------
        -- Stage 3 - Combine shifted words and extract blocks
        --------------------------------------------------------------------------------
        count := 0;
        if (valid_regs(1) = '1') then
          for i in 0 to N_WORDS-1 loop
            temp := remaining_bits or words(1, i);

            for blk in 0 to MAX_BLOCKS_PER_WORD-1 loop
              if (n_blocks_arr(1, i) > blk) then
                full_blocks(count) <= temp(BLOCK_SIZE+MAX_LENGTH-2 downto MAX_LENGTH-1);
                temp               := temp(MAX_LENGTH-2 downto 0) & (BLOCK_SIZE-1 downto 0 => '0');
                count              := count + 1;
              end if;
            end loop;
            remaining_bits := temp;
          end loop;

          -- If last is 1 and we have some bits left over after extracting
          -- blocks, then we put these into a new block
          if (last_regs(1) = '1' and last_flush_regs(1) = '1') then
            full_blocks(count) <= remaining_bits(BLOCK_SIZE+MAX_LENGTH-2 downto MAX_LENGTH-1);
            count              := count + 1;
            remaining_bits     := (others => '0');
          end if;
        end if;
        to_fifo_count <= count;
        if (valid_regs(1) = '1' and count /= 0) then
          fifo_wren <= '1';
        else
          fifo_wren <= '0';
        end if;
        to_fifo_last <= last_regs(1);
      end if;
    end if;
  end process;

  process (full_blocks, to_fifo_count, to_fifo_last)
  begin
    for i in full_blocks'range loop
      fifo_in((i+1)*BLOCK_SIZE-1 downto i*BLOCK_SIZE) <= full_blocks(i);
    end loop;
    fifo_in(MAX_BLOCKS*BLOCK_SIZE+COUNTER_SIZE-1 downto MAX_BLOCKS*BLOCK_SIZE) <= std_logic_vector(to_unsigned(to_fifo_count, COUNTER_SIZE));
    fifo_in(fifo_in'high)                                                      <= to_fifo_last;
  end process;

  i_fifo : xpm_fifo_sync
    generic map (
      FIFO_MEMORY_TYPE    => "auto",
      ECC_MODE            => "no_ecc",
      FIFO_WRITE_DEPTH    => FIFO_DEPTH,
      WRITE_DATA_WIDTH    => FIFO_SIZE,
      WR_DATA_COUNT_WIDTH => num2bits(FIFO_DEPTH),
      PROG_FULL_THRESH    => FIFO_DEPTH - FIFO_MARGIN,
      FULL_RESET_VALUE    => 0,
      READ_MODE           => "std",
      FIFO_READ_LATENCY   => 1,
      READ_DATA_WIDTH     => FIFO_SIZE,
      RD_DATA_COUNT_WIDTH => num2bits(FIFO_DEPTH),
      PROG_EMPTY_THRESH   => 10,
      DOUT_RESET_VALUE    => "0",
      WAKEUP_TIME         => 0
      )
    port map (
      rst           => not aresetn,
      wr_clk        => clk,
      wr_en         => fifo_wren,
      din           => fifo_in,
      full          => open,
      overflow      => open,
      wr_rst_busy   => open,
      rd_en         => fifo_rden,
      dout          => fifo_out,
      empty         => fifo_empty,
      underflow     => open,
      rd_rst_busy   => open,
      prog_full     => over_threshold,
      wr_data_count => open,
      prog_empty    => open,
      rd_data_count => open,
      sleep         => '0',
      injectsbiterr => '0',
      injectdbiterr => '0',
      sbiterr       => open,
      dbiterr       => open
      );

  fifo_rden <= '1' when fifo_empty = '0' and (from_fifo_valid = '0' or
                                              (out_handshake = '1' and counter = from_fifo_count - 1))
               else '0';
  from_fifo_count <= to_integer(unsigned(fifo_out(fifo_out'high - 1 downto fifo_out'high - COUNTER_SIZE)));
  from_fifo_last  <= fifo_out(fifo_out'high);
  process (fifo_out)
  begin
    for i in from_fifo_blocks'range loop
      from_fifo_blocks(i) <= fifo_out((i+1)*BLOCK_SIZE-1 downto i*BLOCK_SIZE);
    end loop;
  end process;

  process (clk)
  begin
    if (rising_edge(clk)) then
      if (aresetn = '0') then
        counter         <= 0;
        from_fifo_valid <= '0';
      else
        if (fifo_rden = '1') then
          from_fifo_valid <= '1';
          counter         <= 0;
        elsif (out_handshake = '1' and counter = from_fifo_count - 1) then
          from_fifo_valid <= '0';
        elsif (out_handshake = '1') then
          counter <= counter + 1;
        end if;
      end if;
    end if;
  end process;

  out_handshake <= from_fifo_valid and out_ready;
  out_valid <= from_fifo_valid;

  process (counter, from_fifo_last, from_fifo_count, from_fifo_blocks)
  begin
    -- Perform optional endianness swap
    if (LITTLE_ENDIAN) then
      for i in 0 to BLOCK_SIZE/8-1 loop
        out_data((i+1)*8-1 downto i*8) <= from_fifo_blocks(counter)((BLOCK_SIZE/8-i)*8-1 downto ((BLOCK_SIZE/8-i-1)*8));
      end loop;
    else
      out_data <= from_fifo_blocks(counter);
    end if;

    if (from_fifo_last = '1' and counter = from_fifo_count - 1) then
      out_last <= '1';
    else
      out_last <= '0';
    end if;
  end process;
end rtl;
