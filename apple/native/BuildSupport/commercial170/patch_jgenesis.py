"""Expose cartridge RAM to Libretro without a shadow copy or filesystem writes.

Applied only to the pinned source checkout. The frontend owns persistence;
pointer lifetimes end on unload/reset/state-load, as with other Libretro cores.
"""
from pathlib import Path

def apply(root: Path):
    # The adapter exposes Standalone Genesis only, never 32X. Do not embed
    # upstream's unused proprietary boot ROMs through the s32x dependency.
    path = root / 'backend/s32x-core/src/bootrom.rs'
    text = path.read_text()
    for name, size in (('sh2_master_boot_rom.bin', 2048), ('sh2_slave_boot_rom.bin', 1024), ('m68k_vectors.bin', 256)):
        text = text.replace(f'include_bytes!("{name}")', f'&[0; {size}] /* VETA: 32X unavailable; boot ROM excluded */')
    assert 'include_bytes!' not in text
    path.write_text(text)
    edits = {
        'backend/genesis-components/src/cartridge/external.rs': (
            '    pub fn get_memory(&self) -> &[u8] {',
            '''    // VETA Libretro integration: frontend-managed SRAM/EEPROM.
    pub fn veta_memory_mut(&mut self) -> &mut [u8] {
        match self {
            Self::None => &mut [],
            Self::Ram(ram) => &mut ram.ram,
            Self::Eeprom { chip, .. } => chip.get_memory_mut(),
        }
    }

'''),
        'backend/genesis-components/src/cartridge.rs': (
            '    pub fn external_ram(&self) -> &[u8] {',
            '''    pub fn veta_ram_mut(&mut self) -> &mut [u8] {
        self.external.veta_memory_mut()
    }

'''),
        'backend/genesis-core/src/api.rs': (
            'impl GenesisEmulator {',
            '''impl GenesisEmulator {
    pub fn veta_ram_mut(&mut self) -> &mut [u8] {
        match self.bus.cartridge_mut() {
            Some(cartridge) if cartridge.is_ram_persistent() => cartridge.veta_ram_mut(),
            _ => &mut [],
        }
    }
}

'''),
        'backend/smsgg-core/src/memory.rs': (
            '    pub fn cartridge_ram(&self) -> &[u8] {',
            '''    pub fn veta_ram_mut(&mut self) -> &mut [u8] {
        &mut self.cartridge.ram
    }

'''),
        'backend/smsgg-core/src/api.rs': (
            'impl SmsGgEmulator {',
            '''impl SmsGgEmulator {
    pub fn veta_ram_mut(&mut self) -> &mut [u8] {
        self.memory.veta_ram_mut()
    }
}

'''),
    }
    for relative, (anchor, addition) in edits.items():
        path = root / relative
        text = path.read_text()
        if addition in text:
            continue
        assert text.count(anchor) == 1, relative
        path.write_text(text.replace(anchor, addition + anchor))
    # Use stable IEEE operations instead of the upstream experimental relaxed
    # float methods. No compiler bootstrap/nightly or fast-math is required.
    path = root / 'common/jgenesis-common/src/audio/fir_resampler.rs'
    text = path.read_text()
    for coefficient in ('coefficient', 'coefficients[i]'):
        text = text.replace(f'sum.algebraic_add({coefficient}.algebraic_mul(samples[ch].buffer[input_idx]))',
                            f'*sum + {coefficient} * samples[ch].buffer[input_idx]')
    path.write_text(text)

if __name__ == '__main__':
    import sys
    apply(Path(sys.argv[1]))
