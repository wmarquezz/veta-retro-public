"""Make mGBA cleanup safe after a later cartridge is rejected before allocation."""
from pathlib import Path

def apply(source: Path):
    path = source / 'src/platform/libretro/libretro.c'
    text = path.read_text()
    edits = [
        ('void retro_deinit(void) {\n\tfree(outputBuffer);',
         'void retro_deinit(void) {\n\tfree(outputBuffer);\n\t// VETA: a rejected subsequent ROM can reach deinit without allocating video.\n\toutputBuffer = NULL;'),
        ('\tcore->deinit(core);\n\tmappedMemoryFree(data, dataSize);',
         '\tcore->deinit(core);\n\tcore = NULL;\n\tmappedMemoryFree(data, dataSize);'),
    ]
    for old, new in edits:
        if new in text:
            continue
        if text.count(old) != 1:
            raise ValueError('Unexpected pinned mGBA lifecycle source')
        text = text.replace(old, new)
    path.write_text(text)

if __name__ == '__main__':
    import sys
    apply(Path(sys.argv[1]))
