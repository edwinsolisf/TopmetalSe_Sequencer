----------------------------------------------------------------------------------
-- Manual stepping of the TopmetalSe large array (100 x 100) from the Basys3 switches.
--
-- The row and column selects are two 100-stage shift registers on the chip
-- (TopmetalSe-Respin verilog/gl/shift_register.v): they shift on the rising edge of CLK
-- while ENA = '1' (stage 0 <- DIN), hold while ENA = '0', and clear asynchronously while
-- RST = '1'. A pixel is selected where the single '1' of each register sits.
--
-- Each switch acts when it is turned on and then off again (debounced):
--   STEP_PIXEL: next pixel in raster order (column + 1; after column 99, column 0 of the
--               next row; after pixel 9999, pixel 0)
--   STEP_ROW:   next row, same column (after row 99, row 0)
--   GOTO_ZERO:  clear both registers, then clock a '1' into row 0 and column 0 (pixel 0)
-- The outputs only change during a step; between steps ENA = '1', CLK = '0', RST = '0'.
-- ROW and COL here are the chip's rows and columns (the FPGA's LA_ROW_* / LA_COL_* ports).
--
-- ROW_BCD / COL_BCD give the current position as two decimal digits each, so the
-- 4-digit display shows the pixel number (row * 100 + column) directly.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity switch_release is
    generic (DEBOUNCE_CYCLES : natural := 1000000);    -- 10 ms at 100 MHz
    port (
        CLK      : in  std_logic;
        SW       : in  std_logic;
        RELEASED : out std_logic                       -- one-cycle pulse on a debounced on -> off
    );
end switch_release;

architecture Behavioral of switch_release is
    signal sync   : std_logic_vector(1 downto 0) := "00";
    signal stable : std_logic := '0';
    signal count  : natural range 0 to DEBOUNCE_CYCLES := 0;
begin
    process(CLK)
    begin
        if rising_edge(CLK) then
            sync <= sync(0) & SW;
            RELEASED <= '0';
            if sync(1) = stable then
                count <= 0;
            elsif count = DEBOUNCE_CYCLES then
                count <= 0;
                stable <= sync(1);
                if stable = '1' then            -- was on, now off
                    RELEASED <= '1';
                end if;
            else
                count <= count + 1;
            end if;
        end if;
    end process;
end Behavioral;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity la_manual is
    generic (
        DEBOUNCE_CYCLES : natural := 1000000;          -- 10 ms at 100 MHz
        PHASE_CYCLES    : natural := 100               -- 1 us per pulse phase at 100 MHz
    );
    port (
        CLK        : in  std_logic;                    -- 100 MHz
        RESET      : in  std_logic;
        STEP_PIXEL : in  std_logic;                    -- switch
        STEP_ROW   : in  std_logic;                    -- switch
        GOTO_ZERO  : in  std_logic;                    -- switch

        ROW_CLK, ROW_ENA, ROW_RST, ROW_DIN : out std_logic;
        COL_CLK, COL_ENA, COL_RST, COL_DIN : out std_logic;

        ROW_BCD : out std_logic_vector(7 downto 0);    -- tens & ones
        COL_BCD : out std_logic_vector(7 downto 0)
    );
end la_manual;

architecture Behavioral of la_manual is
    signal rel_pixel, rel_row, rel_zero : std_logic;

    -- A step is a list of register actions done one after another:
    --   clear both, clock the row register, clock the column register
    type state_t is (IDLE, CLEAR, ROW_SETUP, ROW_HIGH, ROW_HOLD, COL_SETUP, COL_HIGH, COL_HOLD);
    signal state : state_t := IDLE;
    signal timer : natural range 0 to PHASE_CYCLES := 0;

    signal do_clear, do_row, do_col : std_logic := '0';    -- what the current step still needs
    signal row_din_v, col_din_v     : std_logic := '0';

    signal row, col : natural range 0 to 99 := 0;
    signal valid    : std_logic := '0';                     -- registers hold a known token

    function bcd(n : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(n / 10, 4)) & std_logic_vector(to_unsigned(n mod 10, 4));
    end function;
begin
    DB_PIX: entity work.switch_release generic map (DEBOUNCE_CYCLES) port map (CLK, STEP_PIXEL, rel_pixel);
    DB_ROW: entity work.switch_release generic map (DEBOUNCE_CYCLES) port map (CLK, STEP_ROW, rel_row);
    DB_ZER: entity work.switch_release generic map (DEBOUNCE_CYCLES) port map (CLK, GOTO_ZERO, rel_zero);

    ROW_BCD <= bcd(row);
    COL_BCD <= bcd(col);

    ROW_ENA <= '1';
    COL_ENA <= '1';
    ROW_RST <= '1' when state = CLEAR else '0';
    COL_RST <= '1' when state = CLEAR else '0';
    ROW_CLK <= '1' when state = ROW_HIGH else '0';
    COL_CLK <= '1' when state = COL_HIGH else '0';
    ROW_DIN <= row_din_v when state = ROW_SETUP or state = ROW_HIGH or state = ROW_HOLD else '0';
    COL_DIN <= col_din_v when state = COL_SETUP or state = COL_HIGH or state = COL_HOLD else '0';

    process(CLK)
        -- Next action of the step in progress, in the order clear -> row -> column
        procedure next_action(clr, r, c : std_logic) is
        begin
            if clr = '1' then
                state <= CLEAR;
            elsif r = '1' then
                state <= ROW_SETUP;
            elsif c = '1' then
                state <= COL_SETUP;
            else
                state <= IDLE;
            end if;
        end procedure;
    begin
        if rising_edge(CLK) then
            if RESET = '1' then
                state <= IDLE;
                timer <= 0;
                do_clear <= '0'; do_row <= '0'; do_col <= '0';
                row <= 0; col <= 0; valid <= '0';
            else
                case state is
                    when IDLE =>
                        timer <= 0;
                        if rel_zero = '1' or (valid = '0' and (rel_pixel = '1' or rel_row = '1')) then
                            -- pixel 0: clear, then a '1' into row 0 and column 0
                            do_clear <= '1'; do_row <= '1'; do_col <= '1';
                            row_din_v <= '1'; col_din_v <= '1';
                            row <= 0; col <= 0; valid <= '1';
                            next_action('1', '1', '1');
                        elsif rel_pixel = '1' then
                            if col = 99 then
                                -- column 99 -> column 0 of the next row: the column token
                                -- shifts out as a new one enters column 0; the row moves on
                                col <= 0;
                                col_din_v <= '1';
                                if row = 99 then row <= 0; row_din_v <= '1'; else row <= row + 1; row_din_v <= '0'; end if;
                                do_clear <= '0'; do_row <= '1'; do_col <= '1';
                                next_action('0', '1', '1');
                            else
                                col <= col + 1;
                                col_din_v <= '0';
                                do_clear <= '0'; do_row <= '0'; do_col <= '1';
                                next_action('0', '0', '1');
                            end if;
                        elsif rel_row = '1' then
                            if row = 99 then row <= 0; row_din_v <= '1'; else row <= row + 1; row_din_v <= '0'; end if;
                            do_clear <= '0'; do_row <= '1'; do_col <= '0';
                            next_action('0', '1', '0');
                        end if;

                    when CLEAR =>
                        if timer = PHASE_CYCLES then
                            timer <= 0; do_clear <= '0';
                            next_action('0', do_row, do_col);
                        else
                            timer <= timer + 1;
                        end if;

                    when ROW_SETUP | COL_SETUP | ROW_HIGH | COL_HIGH =>
                        if timer = PHASE_CYCLES then
                            timer <= 0;
                            case state is
                                when ROW_SETUP => state <= ROW_HIGH;
                                when ROW_HIGH  => state <= ROW_HOLD;
                                when COL_SETUP => state <= COL_HIGH;
                                when others    => state <= COL_HOLD;
                            end case;
                        else
                            timer <= timer + 1;
                        end if;

                    when ROW_HOLD =>
                        if timer = PHASE_CYCLES then
                            timer <= 0; do_row <= '0';
                            next_action('0', '0', do_col);
                        else
                            timer <= timer + 1;
                        end if;

                    when COL_HOLD =>
                        if timer = PHASE_CYCLES then
                            timer <= 0; do_col <= '0';
                            state <= IDLE;
                        else
                            timer <= timer + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end Behavioral;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Basys3 4-digit 7-segment display (common anode: segments and anodes active low).
-- DIGITS(15 downto 12) is the leftmost digit.
entity sevenseg is
    generic (REFRESH_CYCLES : natural := 100000);      -- 1 ms per digit at 100 MHz
    port (
        CLK    : in  std_logic;
        DIGITS : in  std_logic_vector(15 downto 0);
        SEG    : out std_logic_vector(6 downto 0);     -- CA..CG = SEG(0)..SEG(6)
        AN     : out std_logic_vector(3 downto 0)
    );
end sevenseg;

architecture Behavioral of sevenseg is
    signal count : natural range 0 to REFRESH_CYCLES := 0;
    signal digit : natural range 0 to 3 := 0;
    signal nib   : std_logic_vector(3 downto 0);
begin
    process(CLK)
    begin
        if rising_edge(CLK) then
            if count = REFRESH_CYCLES then
                count <= 0;
                digit <= (digit + 1) mod 4;
            else
                count <= count + 1;
            end if;
        end if;
    end process;

    nib <= DIGITS(4 * digit + 3 downto 4 * digit);
    AN <= "1110" when digit = 0 else "1101" when digit = 1 else "1011" when digit = 2 else "0111";

    with nib select SEG <=          -- gfedcba, active low
        "1000000" when "0000",
        "1111001" when "0001",
        "0100100" when "0010",
        "0110000" when "0011",
        "0011001" when "0100",
        "0010010" when "0101",
        "0000010" when "0110",
        "1111000" when "0111",
        "0000000" when "1000",
        "0010000" when "1001",
        "1111111" when others;
end Behavioral;
