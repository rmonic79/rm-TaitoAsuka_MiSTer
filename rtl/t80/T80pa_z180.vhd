--
-- T80pa_z180 — T80pa con gli opcode Z180 (IN0/OUT0) abilitati.
--
-- Perche' un wrapper e non un semplice override del generic dal SystemVerilog:
-- Quartus accetterebbe `T80pa #(.Z180(1))`, ma il convertitore VHDL->Verilog
-- del simulatore elabora ogni entity con i generic di DEFAULT, quindi in
-- simulazione si otterrebbe silenziosamente un T80 con Z180=0 — cioe' IN0 e
-- OUT0 trattati come NOP, e il link che non parte senza dare spiegazioni.
-- Con un'entity dedicata il valore e' fissato nel VHDL e vale ovunque.
--
-- Author: Umberto Parisi (rmonic79), 2026. GPL-3.
--

library IEEE;
use IEEE.std_logic_1164.all;

entity T80pa_z180 is
	port(
		RESET_n     : in  std_logic;
		CLK         : in  std_logic;
		CEN_p       : in  std_logic := '1';
		CEN_n       : in  std_logic := '1';
		WAIT_n      : in  std_logic := '1';
		INT_n       : in  std_logic := '1';
		NMI_n       : in  std_logic := '1';
		BUSRQ_n     : in  std_logic := '1';
		M1_n        : out std_logic;
		MREQ_n      : out std_logic;
		IORQ_n      : out std_logic;
		RD_n        : out std_logic;
		WR_n        : out std_logic;
		RFSH_n      : out std_logic;
		HALT_n      : out std_logic;
		BUSAK_n     : out std_logic;
		A           : out std_logic_vector(15 downto 0);
		DI          : in  std_logic_vector(7 downto 0);
		DO          : out std_logic_vector(7 downto 0);
		-- stato interno: PC = REG(79 downto 64). Serve al banco di prova e
		-- un domani ai savestate; se non lo si collega sparisce in sintesi.
		REG         : out std_logic_vector(211 downto 0)
	);
end T80pa_z180;

architecture rtl of T80pa_z180 is
	component T80pa
		generic(
			Z180 : integer := 0;
			Mode : integer := 0
		);
		port(
			RESET_n : in  std_logic;
			CLK     : in  std_logic;
			CEN_p   : in  std_logic;
			CEN_n   : in  std_logic;
			WAIT_n  : in  std_logic;
			INT_n   : in  std_logic;
			NMI_n   : in  std_logic;
			BUSRQ_n : in  std_logic;
			M1_n    : out std_logic;
			MREQ_n  : out std_logic;
			IORQ_n  : out std_logic;
			RD_n    : out std_logic;
			WR_n    : out std_logic;
			RFSH_n  : out std_logic;
			HALT_n  : out std_logic;
			BUSAK_n : out std_logic;
			OUT0    : in  std_logic;
			A       : out std_logic_vector(15 downto 0);
			DI      : in  std_logic_vector(7 downto 0);
			DO      : out std_logic_vector(7 downto 0);
			REG     : out std_logic_vector(211 downto 0);
			DIRSet  : in  std_logic;
			DIR     : in  std_logic_vector(211 downto 0)
		);
	end component;

begin
	u_cpu : T80pa
		generic map (Z180 => 1, Mode => 0)
		port map (
			RESET_n => RESET_n,
			CLK     => CLK,
			CEN_p   => CEN_p,
			CEN_n   => CEN_n,
			WAIT_n  => WAIT_n,
			INT_n   => INT_n,
			NMI_n   => NMI_n,
			BUSRQ_n => BUSRQ_n,
			M1_n    => M1_n,
			MREQ_n  => MREQ_n,
			IORQ_n  => IORQ_n,
			RD_n    => RD_n,
			WR_n    => WR_n,
			RFSH_n  => RFSH_n,
			HALT_n  => HALT_n,
			BUSAK_n => BUSAK_n,
			OUT0    => '0',
			A       => A,
			DI      => DI,
			DO      => DO,
			REG     => REG,
			DIRSet  => '0',
			DIR     => (others => '0')
		);
end;
