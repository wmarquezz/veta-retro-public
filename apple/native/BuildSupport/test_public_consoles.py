"""Compile the actual console catalog for both editions; reject PS2 package regression."""
from pathlib import Path
import subprocess,tempfile,sys,json
base=Path(__file__).resolve().parents[1]
text=(base/'Sources/GameConsole.swift').read_text().split('    var maximumPlayers:')[0]
text=text.replace(',Identifiable {',' {')+'}\n'
with tempfile.TemporaryDirectory() as folder:
 p=Path(folder);(p/'main.swift').write_text(text+'''
#if VETA_JIT_DEVELOPMENT
precondition(GameConsole.allCases.contains(.ps2))
precondition(GameConsole.allCases.count == 20)
#else
precondition(!GameConsole.allCases.contains(.ps2))
precondition(GameConsole.allCases.count == 19)
#endif
precondition(try! JSONDecoder().decode(GameConsole.self,from:Data("\\\"ps2\\\"".utf8)) == .ps2)
print("Catalog and retained decoding PASS")
''')
 for flags in [[],['-D','VETA_JIT_DEVELOPMENT']]:
  subprocess.run(['swiftc',*flags,str(p/'main.swift'),'-o',str(p/'check')],check=True)
  subprocess.run([str(p/'check')],check=True)
sys.path.insert(0,str(base/'BuildSupport'))
from public_games import apply
project=json.loads((base/'project.json').read_text())
project['targets']['VetaNative']['dependencies'].append({'framework':'.build/PS2Core.xcframework'})
apply(project)
assert not any('PS2Core' in str(d) for d in project['targets']['VetaNative']['dependencies'])
from app_store_preflight import BANNED
assert {'PS2Core.framework','PS2Wasm','VetaInternalJIT.appex','VetaInternalVPN.appex'} <= BANNED
print('Public packaging removes reintroduced PS2; release audit bans JIT helpers: PASS')
