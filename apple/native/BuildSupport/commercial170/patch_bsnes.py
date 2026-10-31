"""Preserve AAPCS64 callee-saved FP registers across coroutine switches."""
from pathlib import Path
import re, shutil

def apply(root: Path):
    free = Path(__file__).resolve().parent/'spc700-free'
    header = root/'target-libretro/veta-spc700.h'
    changed = not header.exists() or header.read_bytes() != (free/'spc700_boot_rom.h').read_bytes()
    shutil.copy2(free/'spc700_boot_rom.h', header)
    if changed: (root/'target-libretro/libretro.cpp').touch()
    shutil.copy2(free/'LICENSE', root/'target-libretro/veta-spc700-LICENSE')
    path = root/'target-libretro/libretro.cpp'
    text = path.read_text()
    if '#define iplrom spc700_boot_rom' not in text:
        text, count = re.subn(r'const uint8 iplrom\[64\] = \{.*?\n\};',
            '#include "veta-spc700.h"\n#define iplrom spc700_boot_rom', text, count=1, flags=re.S)
        assert count == 1, 'Unknown upstream IPL declaration'
        path.write_text(text)
    path=root/'libco/aarch64.c'; text=path.read_text()
    if 'VETA AAPCS64' in text:
        (root/'libco/libco.c').touch()
        return
    stores=''.join(f'      "  stp d{i}, d{i+1}, [x1, #{176+(i-8)*8}]\\n"\n' for i in range(8,16,2))
    loads=''.join(f'      "  ldp d{i}, d{i+1}, [x0, #{176+(i-8)*8}]\\n"\n' for i in range(8,16,2))
    a='      "  stp x16, x30, [x1, #160]\\n"\n'
    b='      "  ldp x16, x17, [x0, #160]\\n"\n'
    assert a in text and b in text
    text=text.replace(a,a+stores).replace(b,loads+b)
    text=text.replace('   uint64_t *ptr = (uint64_t*)handle;',
        '   /* VETA AAPCS64: initialize the complete register context, including d8-d15. */\n   memset(handle, 0, 512);\n   uint64_t *ptr = (uint64_t*)handle;')
    path.write_text(text)
    (root/'libco/libco.c').touch()
