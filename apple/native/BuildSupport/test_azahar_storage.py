#!/usr/bin/env python3
"""Exercise the patched core's actual path conversion, without Nintendo files."""
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1] / '.build/engine-sources/azahar/src/common/file_util.cpp'
text = source.read_text()
start = text.index('bool StringReplace(')
end = text.index('const std::string& GetUserPath(', start)
functions = text[start:end]
assert 'Older VETA states' in functions, 'Apply the storage patch before testing'
harness = r'''
#include <cassert>
#include <string>
#include <iostream>
enum class UserPath { UserDir, SDMCDir, NANDDir };
std::string root="/new-container/Library/Application Support/VetaNative/game/CoreSaves/Azahar/";
std::string sd=root+"sdmc/", nand=root+"nand/", g_currentRomPath="/new-container/game.3ds";
const std::string& GetUserPath(UserPath p) { return p==UserPath::UserDir ? root:p==UserPath::SDMCDir ? sd:nand; }
'''+functions+r'''
int main() {
    const std::string old="/old-container/Library/Application Support/VetaNative/game/CoreSaves/Azahar/";
    const std::string suffix="nand/data/0000/sysdata/00010026/00000000/";
    assert(SerializePath(old+suffix,false)==root+suffix);
    assert(SerializePath(old+"sdmc/Nintendo 3DS/file",false)==root+"sdmc/Nintendo 3DS/file");
    assert(SerializePath(root+suffix,false)==root+suffix);
    const auto portable=SerializePath(root+suffix,true);
    assert(portable=="%CITRA_USER_DIR%"+suffix);
    assert(SerializePath(portable,false)==root+suffix);
    root="/third-container/game/CoreSaves/Azahar/";
    assert(SerializePath(portable,false)==root+suffix);
    assert(SerializePath(old+suffix,false)==root+suffix);
    for (const auto& escape:{"../outside","nand/../../outside","nand/.."})
        assert(SerializePath(old+escape,false)==old+escape);
    assert(SerializePath("/unrelated/nand/file",false)=="/unrelated/nand/file");
    assert(SerializePath(g_currentRomPath,true)=="%CITRA_ROM_FILE%");
    assert(SerializePath("%CITRA_ROM_FILE%",false)==g_currentRomPath);
    root="/non-veta-emulator/";
    assert(SerializePath(old+suffix,false)==old+suffix);
    std::cout<<"PASS: legacy/portable saves, repeated relocation, ROM path, unrelated paths, traversal boundary\n";
}
'''
with tempfile.TemporaryDirectory(prefix='veta-azahar-paths-') as directory:
    path=Path(directory);(path/'test.cpp').write_text(harness)
    subprocess.run(['xcrun','clang++','-std=c++20','-Wall','-Wextra','-Werror',str(path/'test.cpp'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
