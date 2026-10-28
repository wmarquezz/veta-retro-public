#!/usr/bin/env python3
from pathlib import Path
import subprocess,argparse,shutil
p=argparse.ArgumentParser();p.add_argument('--work',type=Path,required=True);p.add_argument('--simulator',required=True);a=p.parse_args();a.work=a.work.resolve();a.work.mkdir(parents=True,exist_ok=True)
r=Path(__file__).resolve().parents[2]
(a.work/'TouchDeck.swift').write_text((r/'Sources/TouchDeck.swift').read_text().split('\nfinal class GameViewController:')[0]+'\n')
(a.work/'ControllerSkins.swift').write_text((r/'Sources/ControllerSkins.swift').read_text().split('\nstruct ControllerSkinDocument:')[0]+'\n')
(a.work/'Support.swift').write_text('''import UIKit
extension UIColor {convenience init(hex:UInt32,alpha:CGFloat=1) {self.init(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha)}}
enum L10n {static func text(_ value:String)->String {value}}
enum StateFile {static let coreID="component-only"}
enum VetaError:Error {case message(String)}
func veta_max_players(_ index:UInt32)->Int32 {1}
''')
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip();exe=a.work/'Contracts'
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-sdk',sdk,'-target','arm64-apple-ios17.4-simulator',str(a.work/'TouchDeck.swift'),str(a.work/'ControllerSkins.swift'),str(a.work/'Support.swift'),*[str(r/'Sources'/f) for f in ['ConsoleSkin.swift','GameConsole.swift','PersonalSkin.swift','PersonalSkinLibrary.swift']],str(Path(__file__).with_name('StudioSkinContracts.swift')),'-o',str(exe)],check=True)
for resource in (r/'Sources/Resources').glob('studio-*.vetaskin'):shutil.copy2(resource,a.work/resource.name)
subprocess.run(['codesign','-s','-',str(exe)],check=True)
subprocess.run(['xcrun','simctl','spawn',a.simulator,str(exe),str(a.work/'fixtures')],check=True,timeout=180)
