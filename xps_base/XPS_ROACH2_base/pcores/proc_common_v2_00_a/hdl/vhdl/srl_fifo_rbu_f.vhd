-------------------------------------------------------------------------------
-- $Id: srl_fifo_rbu_f.vhd,v 1.3 2007/12/13 00:20:22 ostlerf Exp $
-------------------------------------------------------------------------------
-- srl_fifo_rbu_f - entity / architecture pair
-------------------------------------------------------------------------------
--
--                  ****************************
--                  ** Copyright Xilinx, Inc. **
--                  ** All rights reserved.   **
--                  ****************************
--
-------------------------------------------------------------------------------
-- Filename:        srl_fifo_rbu_f.vhd
--
-- Description:     A small-to-medium depth FIFO with optional
--                  capability to back up and reread data.  For
--                  data storage, the SRL elements native to the
--                  target FGPA family are used. If the FIFO depth
--                  exceeds the available depth of the SRL elements,
--                  then SRLs are cascaded and MUXFN elements are
--                  used to select the output of the appropriate SRL stage.
--
--                  Features:
--                      - Width and depth are arbitrary, but each doubling of
--                        depth, starting from the native SRL depth, adds
--                        a level of MUXFN. Generally, in performance-oriented
--                        applications, the fifo depth may need to be limited to
--                        not exceed the SRL cascade depth supported by local
--                        fast interconnect or the number of MUXFN levels.
--                        However, deeper fifos will correctly build.
--                      - Commands: read, write, and reread n.
--                      - Flags: empty and full.
--                      - The reread n command (executed by applying
--                        a non-zero value, n, to signal Num_To_Reread
--                        for one clock period) allows n
--                        previously read elements to be restored to the FIFO,
--                        limited, however, to the number of elements that have
--                        not been overwritten. (It is the user's responsibility
--                        to assure that the elements being restored are
--                        actually in the FIFO storage; once the depth of the
--                        FIFO has been written, the maximum number that can
--                        be restored is equal to the vacancy.)
--                        The reread capability does not cost extra LUTs or FFs.
--                      - Commands may be asserted simultaneously.
--                        However, if read and reread n are asserted
--                        simultaneously, only the read is carried out.
--                      - Overflow and underflow are detected and latched until
--                        Reset. The state of the FIFO is undefined during
--                        status of underflow or overflow.
--                        Underflow can occur only by reading the FIFO when empty.
--                        Overflow can occur either from a write, a reread n,
--                        or a combination of both that would result in more
--                        elements occupying the FIFO that its C_DEPTH.
--                      - Any of the signals FIFO_Full, Underflow, or Overflow
--                        left unconnected can be expected to be trimmed.
--                      - The Addr output is always one less than the current
--                        occupancy when the FIFO is non-empty, and is all ones
--                        otherwise. Therefore, the value <FIFO_Empty, Addr>--
--                        i.e. FIFO_Empty concatenated on the left with Addr--
--                        when taken as a signed value, is one less than the
--                        current occupancy.
--                        This information can be used to generate additional
--                        flags, if needed.
--
-- VHDL-Standard:   VHDL'93
-------------------------------------------------------------------------------
-- Structure:   
--              srl_fifo_rbu_f.vhd
--                  dynshreg_f.vhd
--                  cntr_incr_decr_addn_f.vhd
--
-------------------------------------------------------------------------------
-- Author:          Farrell Ostler
--
-- History:
--   FLO   12/05/05   First Version. Derived from srl_fifo_rbu.
-- ~~~~~~
--  FLO         2007-12-12
-- ^^^^^^
--  Using function clog2 now instead of log2 to eliminate superfluous warnings.
-- ~~~~~~
--
-------------------------------------------------------------------------------
-- Naming Conventions:
--      active low signals:                     "*_n"
--      clock signals:                          "clk", "clk_div#", "clk_#x" 
--      reset signals:                          "rst", "rst_n" 
--      generics:                               "C_*" 
--      user defined types:                     "*_TYPE" 
--      state machine next state:               "*_ns" 
--      state machine current state:            "*_cs" 
--      combinatorial signals:                  "*_com" 
--      pipelined or register delay signals:    "*_d#" 
--      predecessor value by # clks:            "*_p#"
--      counter signals:                        "*cnt*"
--      clock enable signals:                   "*_ce" 
--      internal version of output port         "*_i"
--      device pins:                            "*_pin" 
--      ports:                                  - Names begin with Uppercase 
--      processes:                              "*_PROCESS" 
--      component instantiations:               "<ENTITY_>I_<#|FUNC>
-------------------------------------------------------------------------------


library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.UNSIGNED;
use     ieee.numeric_std.">=";
use     ieee.numeric_std.TO_UNSIGNED;
library proc_common_v2_00_a;
use     proc_common_v2_00_a.proc_common_pkg.clog2;

entity srl_fifo_rbu_f is
  generic (
    C_DWIDTH : natural;
    C_DEPTH  : positive := 16;
    C_FAMILY : string   := "nofamily"
    );
  port (
    Clk           : in  std_logic;
    Reset         : in  std_logic;
    FIFO_Write    : in  std_logic;
    Data_In       : in  std_logic_vector(0 to C_DWIDTH-1);
    FIFO_Read     : in  std_logic;
    Data_Out      : out std_logic_vector(0 to C_DWIDTH-1);
    FIFO_Full     : out std_logic;
    FIFO_Empty    : out std_logic;
    Addr          : out std_logic_vector(0 to clog2(C_DEPTH)-1);
    Num_To_Reread : in  std_logic_vector(0 to clog2(C_DEPTH)-1);
    Underflow     : out std_logic;
    Overflow      : out std_logic
    );
end entity srl_fifo_rbu_f;


architecture imp of srl_fifo_rbu_f is

  function bitwise_or(s: std_logic_vector) return std_logic is
    variable v: std_logic := '0';
  begin
    for i in s'range loop v := v or s(i); end loop;
    return v;
  end bitwise_or;

  constant ADDR_BITS : integer := clog2(C_DEPTH);
  
    -- An extra bit will be carried as the empty flag.
  signal addr_i                 : std_logic_vector(ADDR_BITS downto 0);  
  signal addr_i_p1              : std_logic_vector(ADDR_BITS downto 0);
  signal num_to_reread_zeroext  : std_logic_vector(ADDR_BITS downto 0);
  signal fifo_empty_i           : std_logic;
  signal overflow_i             : std_logic;
  signal underflow_i            : std_logic;

begin

    fifo_empty_i           <= addr_i(ADDR_BITS);
    Addr(0 to ADDR_BITS-1) <= addr_i(ADDR_BITS-1 downto 0);
    FIFO_Empty             <= fifo_empty_i;
  
    num_to_reread_zeroext <= '0' & Num_To_Reread;
  

    ----------------------------------------------------------------------------
    -- The FIFO address counter. Addresses the next element to be read.
    -- All ones when the FIFO is empty. 
    ----------------------------------------------------------------------------
    CNTR_INCR_DECR_ADDN_F_I : entity proc_common_v2_00_a.cntr_incr_decr_addn_f
        generic map (
          C_SIZE   => ADDR_BITS + 1,
          C_FAMILY => C_FAMILY 
        )
        port map (
          Clk           => Clk,
          Reset         => Reset,
          Incr          => FIFO_Write,
          Decr          => FIFO_Read,
          N_to_add      => num_to_reread_zeroext,
          Cnt           => addr_i,
          Cnt_p1        => addr_i_p1
        );


    ----------------------------------------------------------------------------
    -- The dynamic shift register that holds the FIFO elements.
    ----------------------------------------------------------------------------
    DYNSHREG_F_I : entity proc_common_v2_00_a.dynshreg_f
        generic map (
            C_DEPTH   => C_DEPTH,
            C_DWIDTH  => C_DWIDTH,
            C_FAMILY  => C_FAMILY
        )
        port map (
            Clk   => Clk,
            Clken => FIFO_Write,
            Addr  => addr_i(ADDR_BITS-1 downto 0),
            Din   => Data_In,
            Dout  => Data_Out
        );

    
    ----------------------------------------------------------------------------
    -- Full flag.
    ----------------------------------------------------------------------------
    FULL_PROCESS: process (Clk)
    begin
        if Clk'event and Clk='1' then
          if Reset='1' then
              FIFO_Full <= '0';
          else
              if addr_i_p1 = std_logic_vector(
                               TO_UNSIGNED(
                                 C_DEPTH-1,ADDR_BITS+1
                               )
                             ) then
                  FIFO_Full <= '1';
              else
                  FIFO_Full <= '0';
              end if;
          end if;
        end if;
    end process;

  
    ----------------------------------------------------------------------------
    -- Underflow detection.
    ----------------------------------------------------------------------------
    UNDERFLOW_PROCESS: process (Clk)
    begin
        if Clk'event and Clk='1' then
            if Reset = '1' then
                underflow_i <= '0';
            elsif underflow_i = '1' then
                underflow_i <= '1';      -- Underflow sticks until reset
            else
                underflow_i <= fifo_empty_i and FIFO_Read;
            end if;
        end if;
    end process;
  
    Underflow <= underflow_i;
  

    ----------------------------------------------------------------------------
    -- Overflow detection.
    -- The only case of non-erroneous operation for which addr_i (including
    -- the high-order bit used as the empty flag) taken as an unsigned value
    -- may be greater than or equal to C_DEPTH is when the FIFO is empty.
    -- No overflow is possible when FIFO_Read, since Num_To_Reread is
    -- overriden in this case and the number elements can at most remain
    -- unchanged (that being when there is a simultaneous FIFO_Write).
    -- However, when there is no FIFO_Read and there is either a
    -- FIFO_Write or a restoration of one or more read elements, or both, then
    -- addr_i, extended by the carry-out bit, becoming greater than
    -- or equal to C_DEPTH indicates an overflow.
    ----------------------------------------------------------------------------
    OVERFLOW_PROCESS: process (Clk)
    begin
        if Clk'event and Clk='1' then
            if Reset = '1' then
                overflow_i <= '0';
            elsif overflow_i = '1' then
                overflow_i <= '1';       -- Overflow sticks until Reset
            elsif FIFO_Read = '0' and
                  (FIFO_Write= '1' or bitwise_or(Num_To_Reread)='1') and
                  UNSIGNED(addr_i_p1) >= C_DEPTH then
                overflow_i <= '1';
            else
                overflow_i <= '0';
            end if;
        end if;
    end process;
  
    Overflow <= overflow_i;

end architecture imp;
