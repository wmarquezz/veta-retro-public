"""Add Rocket type-97 cartridges to pinned mGBA, without changing ROM bytes.

VETA implementation of the bank-register behavior documented by Gearboy's
RocketMemoryRule (https://github.com/drhelius/Gearboy) and hhugboy.
Only used with the public app's BIOS-free GB startup. State uses the existing
four-byte mapper union; old mapper values and state layouts remain unchanged.
"""
from pathlib import Path

def apply(root):
 def edit(name,old,new):
  p=root/name;s=p.read_text()
  if new in s:return
  if s.count(old)!=1:raise ValueError('Unexpected mGBA source: '+name)
  p.write_text(s.replace(old,new))
 edit('include/mgba/gb/interface.h','\tGB_UNL_SACHEN_MMC2 = 0x231,','\tGB_UNL_SACHEN_MMC2 = 0x231,\n\tGB_UNL_ROCKET = 0x240,')
 old='\tif (memcmp(&header[4], _knownHeader, sizeof(_knownHeader)) == 0) {'
 new='''	// Rocket cartridges use their own logo and type, with a standard header checksum.
	if (header[0x47] == 0x97 && memcmp(&header[4], "\\x11\\x23\\xf1\\x1e", 4) == 0) {
		uint8_t checksum = 0;
		for (unsigned i = 0x34; i <= 0x4C; ++i) checksum -= header[i] + 1;
		if (checksum == header[0x4D]) return true;
	}
'''+old
 edit('src/gb/gb.c',old,new)
 old='static uint8_t _GBPocketCamRead(struct GBMemory*, uint16_t address);'
 new='''// Rocket has two independent ROM registers; no MBC5 RAM-enable register.
static void _GBRocket(struct GB* gb, uint16_t address, uint8_t value) {
	if (address == 0x3F00) gb->memory.mbcState.mbc1.bankLo = value ? value : 1;
	else if (address == 0x3FC0) gb->memory.mbcState.mbc1.bankHi = (uint8_t) (value << 4);
	else return;
	GBMBCSwitchBank0(gb, gb->memory.mbcState.mbc1.bankHi);
	GBMBCSwitchBank(gb, gb->memory.mbcState.mbc1.bankHi | gb->memory.mbcState.mbc1.bankLo);
}

'''+old
 edit('src/gb/mbc.c',old,new)
 old='\tgb->memory.mbcRead = NULL;'
 new='''	if (gb->memory.romSize >= 0x8000 && cart->type == 0x97 &&
	    memcmp(cart->logo, "\\x11\\x23\\xf1\\x1e", 4) == 0) {
		gb->memory.mbcType = GB_UNL_ROCKET;
		gb->sramSize = cart->ramSize == 0 ? 0 : cart->ramSize == 1 ? 0x800 : 0x2000;
	}
'''+old
 edit('src/gb/mbc.c',old,new)
 old='\tswitch (gb->memory.mbcType) {\n\tcase GB_MBC_NONE:'
 new='''	switch (gb->memory.mbcType) {
	case GB_UNL_ROCKET:
		gb->memory.mbcWrite = _GBRocket;
		break;
	case GB_MBC_NONE:'''
 edit('src/gb/mbc.c',old,new)
 edit('src/gb/mbc.c','\tgb->memory.sramAccess = false;\n\tgb->memory.rtcAccess = false;', '\tgb->memory.sramAccess = gb->memory.mbcType == GB_UNL_ROCKET && gb->sramSize;\n\tgb->memory.rtcAccess = false;')
 old='\tswitch (gb->memory.mbcType) {\n\tcase GB_MBC1:\n\t\tgb->memory.mbcState.mbc1.mode = 0;'
 new='''	switch (gb->memory.mbcType) {
	case GB_UNL_ROCKET:
		gb->memory.mbcState.mbc1.bankLo = 1;
		gb->memory.mbcState.mbc1.bankHi = 0;
		GBMBCSwitchBank0(gb, 0);
		GBMBCSwitchBank(gb, 1);
		break;
	case GB_MBC1:
		gb->memory.mbcState.mbc1.mode = 0;'''
 edit('src/gb/mbc.c',old,new)
 old='\tswitch (memory->mbcType) {\n\tcase GB_MBC1:\n\t\tstate->memory.mbc1.mode'
 new='\tswitch (memory->mbcType) {\n\tcase GB_UNL_ROCKET:\n\tcase GB_MBC1:\n\t\tstate->memory.mbc1.mode'
 edit('src/gb/memory.c',old,new)
 old='\tswitch (memory->mbcType) {\n\tcase GB_MBC1:\n\t\tmemory->mbcState.mbc1.mode'
 new='''	switch (memory->mbcType) {
	case GB_UNL_ROCKET:
		memory->mbcState.mbc1.bankLo = state->memory.mbc1.bankLo;
		memory->mbcState.mbc1.bankHi = state->memory.mbc1.bankHi;
		GBMBCSwitchBank0(gb, memory->mbcState.mbc1.bankHi);
		GBMBCSwitchBank(gb, memory->mbcState.mbc1.bankHi | memory->mbcState.mbc1.bankLo);
		break;
	case GB_MBC1:
		memory->mbcState.mbc1.mode'''
 edit('src/gb/memory.c',old,new)
if __name__=='__main__':
 import sys
 apply(Path(sys.argv[1]))
