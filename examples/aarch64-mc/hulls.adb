------------------------------------------------------------------------------
--                                                                          --
--                               GNAT EXAMPLE                               --
--                                                                          --
--                        Copyright (C) 2017, AdaCore                       --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 2,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNAT;  see file COPYING.  If not, write --
-- to  the  Free Software Foundation,  51  Franklin  Street,  Fifth  Floor, --
-- Boston, MA 02110-1301, USA.                                              --
--                                                                          --
-- As a special exception,  if other files  instantiate  generics from this --
-- unit, or you link  this unit with other files  to produce an executable, --
-- this  unit  does not  by itself cause  the resulting  executable  to  be --
-- covered  by the  GNU  General  Public  License.  This exception does not --
-- however invalidate  any other reasons why  the executable file  might be --
-- covered by the  GNU Public License.                                      --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Unchecked_Conversion;
with System.Machine_Code; use System.Machine_Code;
with Uart; use Uart;
with Interfaces.AArch64; use Interfaces.AArch64;

package body Hulls is
   type Hull_Context_AArch64_Acc is access all Hull_Context_AArch64;
   pragma Convention (C, Hull_Context_AArch64_Acc);

   procedure Execute_Hull (Ctxt : Hull_Context_AArch64_Acc);
   pragma Import (C, Execute_Hull);

   procedure Handler_Syn_A64 (Ctxt : Hull_Context_Acc);

   function To_Unsigned_64 is new Ada.Unchecked_Conversion
     (Source => Address, Target => Unsigned_64);

   procedure Cache_Sync_By_Range
     (Start : System.Address;
      Len   : System.Storage_Elements.Storage_Count)
   is
      Line_Size : constant := 16;
      Line_Off : Storage_Count;
      Off : Storage_Count;
      Addr : Address;
   begin
      Line_Off := Start mod Line_Size;
      Addr := Start - Line_Off;
      Off := 0;
      loop
         DC_CVAU (Addr);
         IC_IVAU (Addr);
         Off := Off + Line_Size;
         exit when Off > Len + Line_Off;
         Addr := Addr + Line_Size;
      end loop;

      DSB_ISH;
      ISB;
   end Cache_Sync_By_Range;

   subtype Fat_String is String (Positive);
   type Fat_String_Acc is access Fat_String;
   function To_Fat_String_Acc is new Ada.Unchecked_Conversion
     (Address, Fat_String_Acc);

   procedure Copy_File
     (F : File_Entry;
      Base : Address; Off : Storage_Count; Len : Storage_Count)
   is
      Src : Storage_Array (1 .. F.Len);
      pragma Import (Ada, Src);
      for Src'Address use F.Content;

      Dest : Storage_Array (1 .. F.Len);
      pragma Import (Ada, Dest);
      for Dest'Address use Base + Off;

      Name : constant Fat_String_Acc := To_Fat_String_Acc (F.Name);
   begin
      if Off + F.Len > Len then
         raise Constraint_Error;
      end if;

      Put ("Copying '");
      for I in Name'Range loop
         exit when Name (I) = ASCII.NUL;
         Put (Name (I));
      end loop;
      Put ("' to ");
      Put_Hex8 (To_Unsigned_64 (Base + Off));
      New_Line;

      Dest := Src;

      Cache_Sync_By_Range (Dest'Address, F.Len);
   end Copy_File;

   function Is_Image (F : File_Entry; Name : String) return Boolean
   is

      Str : constant Fat_String_Acc := To_Fat_String_Acc (F.Name);
   begin
      for I in 1 .. Name'Length loop
         if Str (I) /= Name (I) then
            return False;
         end if;
      end loop;
      if Str (Name'Length + 1) /= ASCII.NUL then
         return False;
      end if;

      return True;
   end Is_Image;

   procedure Align (Addr : in out Storage_Count; Off : Storage_Count) is
   begin
      Addr := Addr + Off - 1;
      Addr := Addr - (Addr mod Off);
   end Align;

   procedure Set_Debug_Vectors
     (Paddr : Address; Off : in out Storage_Count) is
   begin
      for I in 0 .. 16 loop
         declare
            Insn : Unsigned_32 with Import, Volatile,
              Address => Paddr + Off + Storage_Count (I * 16#80#);
         begin
            Insn := 16#d4000102# + Unsigned_32 (I * 16); -- HVC
            Cache_Sync_By_Range (Insn'Address, 4);
         end;
      end loop;
      Off := Off + 16#800#;
   end Set_Debug_Vectors;

   procedure Load_Files (Desc : Hull_Desc; Ctxt : Hull_Context_Acc) is
      Vaddr : Address;
      Paddr : Address;
      Off : Storage_Count;
      Len : Storage_Offset;
   begin
      if Desc.Memmap_Nbr = 0 then
         --  There should be memory to load a file.
         raise Constraint_Error;
      end if;

      Put ("Copying Hull......");
      New_Line;

      Paddr := Desc.Memmap (0).Paddr;
      Vaddr := Desc.Memmap (0).Vaddr;
      Off := 0;
      Len := Desc.Memmap (0).Size;

      for I in 0 .. Desc.Files_Nbr - 1 loop
         declare
            F : File_Entry renames Desc.Files (I);
         begin
            if Is_Image (F, "dtb") then
               --  Align
               Align (Off, 8);

               if Off + F.Len > Len then
                  raise Constraint_Error;
               end if;

               Copy_File (F, Paddr, Off, Len);
               Ctxt.Cpu.Xregs (0) := To_Unsigned_64 (Vaddr + Off);
               Ctxt.Cpu.Xregs (1) := 0;
               Ctxt.Cpu.Xregs (2) := 0;
               Ctxt.Cpu.Xregs (3) := 0;

               Off := Off + F.Len;

               if True then
                  Align (Off, 16#800#);
                  Ctxt.Cpu.Vbar := To_Unsigned_64 (Vaddr + Off);
                  Set_Debug_Vectors (Paddr, Off);
               end if;

            elsif Is_Image (F, "linux") then
               --  Assume everything is ok...
               Align (Off, 16#80000#);

               Copy_File (F, Paddr, Off, Len);
               Ctxt.Cpu.PC := To_Unsigned_64 (Vaddr + Off);

               Off := Off + F.Len;
            elsif Is_Image (F, "bin") then
               Copy_File (F, Paddr, Off, Len);
               Ctxt.Cpu.PC := To_Unsigned_64 (Vaddr + Off);
               Off := Off + F.Len;
            else
               --  Not handled.
               raise Constraint_Error;
            end if;
         end;
      end loop;
   end Load_Files;

   procedure Create_Hull (Desc : Hull_Desc; Ctxt : Hull_Context_Acc)
   is
   begin
      Ctxt.Cpu :=
        (Xregs => (others => 0),
         PC => 0,
         Sp => 16#100#,
         Pstate => 16#1c5#,  -- el1h
         Sp_El0 => 0,
         Esr => 0,
         Far => 0,
         Hpfar => 0,
         Vttbr => To_Unsigned_64 (Desc.Mmu_Table),
         Vtcr => (TCR_PS_4GB or TCR_TG0_4KB or TCR_SH0_OS
                  or TCR_ORGN0_WBWAC or TCR_IRGN0_WBWAC
                  or TCR_SL0_01 or (32 * TCR_T0SZ)),

         --  TID2: concerns cache (CTR, CCSIDR, CLIDR, CSSELR)
         --  [TODO: value of CSSELR should be saved for context switch]
         Hcr => (HCR_RW
                 or HCR_TACR or HCR_TIDCP or HCR_TSC or HCR_TID3
                 or HCR_TID1 or HCR_TID0 or HCR_TWE or HCR_TWI
                 or HCR_IMO or HCR_FMO or HCR_VM),

         Vbar => 16#ffffffff_fffff000#,
         V_MDSCR_EL1 => 0);

      Ctxt.Machine_Reset := False;

      --  Copy file
      if Desc.Files_Nbr > 0 then
         Load_Files (Desc, Ctxt);
      end if;

      Set_VTTBR_EL2 (Ctxt.Cpu.Vttbr);
      TLBI_VMALLS12E1;

      Put ("Starting Hull......");
      New_Line;

      loop
         Execute_Hull (Ctxt.Cpu'Access);
         Handler_Syn_A64 (Ctxt);
         exit when Ctxt.Machine_Reset;
      end loop;
   end Create_Hull;

   --  Exceptions

   procedure Dump (Regs : Hull_Context_Acc; Id : Natural);

   subtype Xreg_Num is Natural range 0 .. 31;

   function Get_Xreg
     (Ctxt : Hull_Context_Acc; Num : Xreg_Num)
      return Unsigned_64 is
   begin
      if Num = 31 then
         return 0;
      else
         return Ctxt.Cpu.Xregs (Num);
      end if;
   end Get_Xreg;

   procedure Set_Xreg
     (Ctxt : Hull_Context_Acc; Num : Xreg_Num; Val : Unsigned_64) is
   begin
      if Num = 31 then
         Dump (Ctxt, 16 + 3);
         return;
      end if;

      Ctxt.Cpu.Xregs (Num) := Val;
   end Set_Xreg;

   procedure Handle_Data (Ctxt : Hull_Context_Acc)
   is
      ESR : constant Unsigned_32 := Ctxt.Cpu.Esr;
   begin
      --  Exception from a Data abort.

      --  Check ISV, if no -> fails
      if (ESR and 16#100_0000#) = 0 then
         Dump (Ctxt, 16 + 1);
         return;
      end if;

      --  Check AR, fails if set.
      if (ESR and 16#4000#) /= 0 then
         Dump (Ctxt, 16 + 4);
         return;
      end if;

      --  Check DFSC
      case ESR and 16#3f# is
         when 2#100# | 2#101# | 2#110# | 2#111# =>
            null;
         when others =>
            Dump (Ctxt, 16 + 5);
      end case;

      --  Check EA
      if (ESR and 16#200#) /= 0 then
         Dump (Ctxt, 16 + 6);
         return;
      end if;

      --  Check FAR/HPFAR and find emu in table.  If no -> fails
      declare
         HPFAR : constant Unsigned_64 := Ctxt.Cpu.Hpfar;
         FAR : constant Unsigned_64 := Ctxt.Cpu.Far;
         Addr : constant Address :=
           System'To_Address (HPFAR * 16#100# or (FAR and 16#fff#));
         SAS : constant Natural range 0 .. 3 :=
           Natural (Shift_Right (ESR, 22) and 3);
         SRT : constant Natural :=
           Natural (Shift_Right (ESR, 16) and 31);
         Dev : IOEmu_Dev_Acc;
         Off : Off_T;
      begin
         Find_IO (Ctxt.all, Addr, Dev, Off);
         if Dev = null then
            Dump (Ctxt, 16 + 2);
            return;
         end if;

         if (ESR and 16#40#) = 0 then
            --  If read: dispatch and compute result
            declare
               SSE : constant Boolean :=
                 Boolean'Val (Shift_Right (ESR, 21) and 1);
               SF : constant Boolean :=
                 Boolean'Val (Shift_Right (ESR, 15) and 1);

               R : Unsigned_64;
               V8 : Unsigned_8;
               V16 : Unsigned_16;
               V32 : Unsigned_32;
            begin
               case SAS is
                  when 0 =>
                     V8 := Dev.Read8 (Off);
                     if SSE and (V8 and 16#80#) /= 0 then
                        R := 16#ffffffff_ffffff00# or Unsigned_64 (V8);
                     else
                        R := Unsigned_64 (V8);
                     end if;
                  when 1 =>
                     V16 := Dev.Read16 (Off);
                     if SSE and (V16 and 16#8000#) /= 0 then
                        R := 16#ffffffff_ffff0000# or Unsigned_64 (V16);
                     else
                        R := Unsigned_64 (V16);
                     end if;
                  when 2 =>
                     V32 := Dev.Read32 (Off);
                     if SSE and (V32 and 16#80000000#) /= 0 then
                        R := 16#ffffffff_00000000# or Unsigned_64 (V32);
                     else
                        R := Unsigned_64 (V32);
                     end if;
                  when 3 =>
                     R := Dev.Read64 (Off);
               end case;

               if not SF then
                  R := R and 16#00000000_ffffffff#;
               end if;

               Set_Xreg (Ctxt, SRT, R);
            end;
         else
            --  If write: compute data and dispatch
            declare
               R : constant Unsigned_64 := Get_Xreg (Ctxt, SRT);
            begin
               case SAS is
                  when 0 =>
                     Dev.Write8 (Off, Unsigned_8 (R and 16#ff#));
                  when 1 =>
                     Dev.Write16 (Off, Unsigned_16 (R and 16#ffff#));
                  when 2 =>
                     Dev.Write32 (Off, Unsigned_32 (R and 16#ffff_ffff#));
                  when 3 =>
                     Dev.Write64 (Off, R);
               end case;
            end;
         end if;
      end;

      --  PC = PC + 4
      Ctxt.Cpu.PC := Ctxt.Cpu.PC + 4;
   end Handle_Data;

   type Sys_Reg_Enum is
     (Unknown, MDSCR_EL1, ID_AA64AFR0_EL1, ID_AA64DFR0_EL1,
      ID_AA64MMFR0_EL1, ID_AA64MMFR1_EL1);

   function Extract_Sys_Reg (ISS : Unsigned_32) return Sys_Reg_Enum is
   begin
      --  Mask is   Op0 Op2 Op1 CRn  reg   CRm  d
      case ISS and 2#11_111_111_1111_00000_1111_0# is
         when 2#10_010_000_0000_00000_0010_0# =>
            return MDSCR_EL1;
         when 2#11_100_000_0000_00000_0101_0# =>
            return ID_AA64AFR0_EL1;
         when 2#11_000_000_0000_00000_0101_0# =>
            return ID_AA64DFR0_EL1;
         when 2#11_000_000_0000_00000_0111_0# =>
            return ID_AA64MMFR0_EL1;
         when 2#11_001_000_0000_00000_0111_0# =>
            return ID_AA64MMFR0_EL1;
         when others =>
            return Unknown;
      end case;
   end Extract_Sys_Reg;

   procedure Handle_Sys_Reg (Ctxt : Hull_Context_Acc)
   is
      ESR : constant Unsigned_32 := Ctxt.Cpu.Esr;
      Sreg : constant Sys_Reg_Enum := Extract_Sys_Reg (ESR);
      Is_Read : constant Boolean := (ESR and 1) = 1;
      Rt : constant Xreg_Num := Xreg_Num (Shift_Right (ESR, 5) and 31);
      Val : Unsigned_64;
   begin
      if not Is_Read then
         Val := Get_Xreg (Ctxt, Rt);
      end if;

      case Sreg is
         when MDSCR_EL1 =>
            if Is_Read then
               Val := Ctxt.Cpu.V_MDSCR_EL1;
            else
               Ctxt.Cpu.V_MDSCR_EL1 := Val;
            end if;
         when ID_AA64AFR0_EL1 =>
            if Is_Read then
               Val := 0;
            else
               --  TODO: register is RO
               raise Program_Error;
            end if;
         when ID_AA64DFR0_EL1 =>
            if Is_Read then
               --  1 BP, 1 WP...
               Val := 2#0001_0000_0001_0000_0001_0000_0000_0110#;
            else
               --  TODO: register is RO
               raise Program_Error;
            end if;
         when ID_AA64MMFR0_EL1 =>
            if Is_Read then
               Val := Get_ID_AA64MMFR0_EL1;
               --  Limite PA range to 32 bits
               Val := Val and 16#ffff_fff_0#;
            else
               --  TODO
               raise Program_Error;
            end if;
         when ID_AA64MMFR1_EL1 =>
            if Is_Read then
               Val := Get_ID_AA64MMFR1_EL1;
            else
               --  TODO
               raise Program_Error;
            end if;
         when Unknown =>
            Dump (Ctxt, 64 + 1);
      end case;

      if Is_Read then
         Set_Xreg (Ctxt, Rt, Val);
      end if;

      --  PC = PC + 4
      Ctxt.Cpu.PC := Ctxt.Cpu.PC + 4;
   end Handle_Sys_Reg;

   procedure Handler_Syn_A64 (Ctxt : Hull_Context_Acc)
   is
      ESR : constant Unsigned_32 := Ctxt.Cpu.Esr;
      EC : constant Unsigned_8 := Unsigned_8 (Shift_Right (ESR, 26));
   begin
      if False then
         Put ("SYN, EC=");
         Put_Hex4 (ESR);
         Put (", PC=");
         Put_Hex8 (Ctxt.Cpu.PC);
         New_Line;
      end if;

      if EC = 16#24# then
         --  Exception for a Data abort.
         Handle_Data (Ctxt);
      elsif EC = 16#18# then
         --  Exception for MSR/MRS
         Handle_Sys_Reg (Ctxt);
      else
         Dump (Ctxt, 32);
      end if;
   end Handler_Syn_A64;

   procedure Dump (Regs : Hull_Context_Acc; Id : Natural)
   is
      procedure Trap_dump (Regs : Hull_Context_AArch64_Acc; Id : Natural);
      pragma Import (C, Trap_dump, "__trap_dump");
   begin
      --  Mask interrupts so that Trap_Dump has full control of the console
      Asm ("msr DAIFset, #3", Volatile => True);
      Trap_dump (Regs.Cpu'Unrestricted_Access, Id);
      Asm ("msr DAIFclr, #3", Volatile => True);
   end Dump;
end Hulls;
