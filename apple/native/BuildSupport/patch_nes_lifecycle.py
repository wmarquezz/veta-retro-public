"""Reset per-cartridge MMC3 flags and safely read unmapped cartridge banks."""
from pathlib import Path


def apply(source: Path):
    edits = [
        (source / 'src/boards/mmc3.c',
         '\tWRAMSIZE = wram << 10;',
         '\t// VETA: RAM/battery flags belong to this cartridge, not the last one.\n\tmmc3opts = 0;\n\tWRAMSIZE = wram << 10;'),
        (source / 'src/cart.c',
         'DECLFR(CartBR) {\n\treturn Page[A >> 11][A];\n}',
         'DECLFR(CartBR) {\n\t// Unmapped banks behave like CartBROB: return the CPU open bus.\n\treturn Page[A >> 11] ? Page[A >> 11][A] : X.DB;\n}'),
    ]
    for path, old, new in edits:
        text = path.read_text()
        if new in text:
            continue
        if text.count(old) != 1:
            raise ValueError(f'Unexpected pinned NES source: {path.name}')
        path.write_text(text.replace(old, new))


if __name__ == '__main__':
    import sys
    apply(Path(sys.argv[1]))
