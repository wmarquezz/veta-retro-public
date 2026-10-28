#!/usr/bin/env python3
"""Mac contract test of the production launch selector and Dreamcast policy.
Only device snapshots, console metadata and library paths are fixtures; no
emulator, VPN, device or performance claim. Source is extracted unchanged.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='veta-auto-jit-') as tmp:
    out = Path(tmp).resolve()
    plan = (root/'Sources/GameLaunchPlan.swift').read_text().split('\nstruct GameLaunchRequest:')[0]
    assets = (root/'Sources/DreamcastWebServer.swift').read_text().split('enum DreamcastWebAssets {',1)[1].split('\n/// Mutable state',1)[0]
    (out/'Policy.swift').write_text(plan + '\nimport CryptoKit\nenum DreamcastWebAssets {' + assets)
    (out/'Fixtures.swift').write_text('''
import Foundation
struct Game {let id:String;let console:GameConsole;var coreID:String {console.rawValue}}
enum GameConsole:String,CaseIterable {
 case nes,threeDS,dreamcast,gamecube,wii,ps2,xbox
 var usesSharedJITPool:Bool {[.threeDS,.dreamcast,.gamecube,.wii,.ps2].contains(self)}
 var requiresJIT:Bool {usesSharedJITPool || self == .xbox}
}
struct DeviceReadiness {
 struct Snapshot {var jitAvailable=false;var experimentalBuild=true
 var includedInterpreterConsoles:Set<GameConsole> = [.threeDS,.dreamcast,.gamecube,.wii]
 var includedWebAssemblyConsoles:Set<GameConsole> = []}
 let snapshot:Snapshot
}
struct Library {
 let root:URL
 func romURL(_ game:Game)->URL {root.appendingPathComponent("game.chd")}
 func stateDirectory(_ game:Game)->URL {root.appendingPathComponent("states")}
 func file(_ game:Game,_ name:String)->URL {root.appendingPathComponent(name)}
}
enum L10n {
 static func text(_ s:String)->String{s}
 static func format(_ s:String,_ args:CVarArg...)->String {String(format:s,arguments:args)}
}
''')
    (out/'Main.swift').write_text('''
import Foundation
@main struct Contracts {
 @MainActor static func main() throws {
  var checks=0
  func check(_ value:Bool,_ label:String) {precondition(value,label);checks += 1}
  unsetenv("VETA_OFFLINE160_CONSOLE")
  setenv("VETA_DREAMCAST_WEB165","0",1)
  let folder=URL(fileURLWithPath:CommandLine.arguments[1])
  let lib=Library(root:folder)
  for jit in [false,true] {
   var facts=DeviceReadiness.Snapshot();facts.jitAvailable=jit
   for console in GameLaunchPlan.localInterpreterConsoles {
    let game=Game(id:String(repeating:"a",count:64),console:console)
    let plan=GameLaunchPlan.resolve(console:console,snapshot:facts,preference:.automatic)
    check(plan.mode == (jit ? .jit:.interpreter),"automatic availability")
    check(plan.usesSharedPreparation == jit,"shared preparation")
    check((plan.stateNamespace == nil) == jit,"state namespace isolated")
    check(GameLaunchPlan.capture(for:game,readiness:.init(snapshot:facts),library:lib,preference:.automatic).mode == plan.mode,"real capture including Dreamcast")
    check(GameLaunchPlan.resolve(console:console,snapshot:facts,preference:.maximumPerformance).mode == .jit,"explicit preparation")
    for pref in GameLaunchPlan.Preference.allCases {
     check(GameLaunchPlan.resolve(console:console,snapshot:facts,preference:pref,interpreterOverride:true).mode == .interpreter,"QA override")
    }
   }
   for pref in GameLaunchPlan.Preference.allCases {
    facts.includedWebAssemblyConsoles=[.ps2]
    check(GameLaunchPlan.resolve(console:.ps2,snapshot:facts,preference:pref).mode == .jit,"PS2 remains JIT")
    check(GameLaunchPlan.resolve(console:.ps2,snapshot:facts,preference:pref,interpreterOverride:true).mode == .webAssembly,"PS2 QA only")
    check(GameLaunchPlan.resolve(console:.nes,snapshot:facts,preference:pref).mode == .standard,"basic console unchanged")
   }
  }
  var facts=DeviceReadiness.Snapshot();facts.jitAvailable=true;facts.experimentalBuild=false
  for c in GameLaunchPlan.localInterpreterConsoles {
   check(GameLaunchPlan.resolve(console:c,snapshot:facts,preference:.automatic).mode == .interpreter,"public build cannot claim JIT")
  }
  facts.experimentalBuild=true;facts.includedWebAssemblyConsoles=[.dreamcast]
  setenv("VETA_DREAMCAST_WEB165","1",1)
  check(GameLaunchPlan.resolve(console:.dreamcast,snapshot:facts,preference:.automatic).mode == .jit,"active JIT wins over Web assets")
  let frozen=GameLaunchPlan.resolve(console:.gamecube,snapshot:facts,preference:.automatic)
  facts.jitAvailable=false
  check(GameLaunchPlan.resolve(console:.dreamcast,snapshot:facts,preference:.automatic).mode == .webAssembly,"inactive JIT restores Web route")
  check(GameLaunchPlan.resolve(console:.gamecube,snapshot:facts,preference:.automatic).mode == .interpreter,"new process chooses local")
  check(frozen.mode == .jit,"running plan frozen")
  // Existing malformed Web storage must not be read or overwritten when JIT is
  // selected; it remains an error when returning to the local Web route.
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let marker=folder.appendingPathComponent("states/engines/flycast-web-v1/persistent.bin")
  try FileManager.default.createDirectory(at:marker.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data([1,2,3]).write(to:marker)
  facts.jitAvailable=true
  let dc=Game(id:String(repeating:"a",count:64),console:.dreamcast)
  check(GameLaunchPlan.capture(for:dc,readiness:.init(snapshot:facts),library:lib,preference:.automatic).mode == .jit,"Dreamcast JIT bypasses local asset failure")
  facts.jitAvailable=false
  let blocked=GameLaunchPlan.capture(for:dc,readiness:.init(snapshot:facts),library:lib,preference:.automatic)
  check(blocked.blocker != nil,"local failures stay blocking")
  let retained=try Data(contentsOf:marker)
  check(retained == Data([1,2,3]),"selection never replaces files")
  print("PASS: \\(checks) launch-policy checks; production Swift, synthetic snapshots; no device or performance test")
 }
}
''')
    binary=out/'contracts'
    subprocess.run(['xcrun','swiftc','-D','VETA_JIT_DEVELOPMENT',str(out/'Policy.swift'),str(out/'Fixtures.swift'),str(root/'Sources/DreamcastWebLaunchPolicy.swift'),str(root/'Sources/DreamcastWebVMUStore.swift'),str(out/'Main.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(out/'fixture')],check=True)
