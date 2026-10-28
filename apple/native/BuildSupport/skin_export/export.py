#!/usr/bin/env python3
"""Render unmodified VETA drawing/layout code using UIKit in an iOS simulator.
This is a development export tool. No emulator, phone, or user defaults accessed.
"""
import argparse,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--simulator',required=True);p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
r=Path(__file__).resolve().parents[2];a.work.mkdir(parents=True,exist_ok=True)
inputs=['TouchDeck.swift','ControllerSkins.swift','ConsoleSkin.swift','GameConsole.swift']
files={f:(r/'Sources'/f).read_text() for f in inputs}
(a.work/'TouchDeck.swift').write_text(files['TouchDeck.swift'].split('\nfinal class GameViewController:')[0]+'\n')
(a.work/'ControllerSkins.swift').write_text(files['ControllerSkins.swift'].split('\nstruct ControllerSkinDocument:')[0]+'\n')
(a.work/'Support.swift').write_text('''import UIKit
extension UIColor {convenience init(hex:UInt32,alpha:CGFloat=1) {self.init(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha)}}
enum L10n {static func text(_ value:String)->String {value}}
enum StateFile {static let coreID="export-only"}
enum VetaError:Error {case message(String)}
func veta_max_players(_ index:UInt32)->Int32 {1}
''')
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
exe=a.work/'ExportSkins'
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-sdk',sdk,'-target','arm64-apple-ios17.4-simulator',str(a.work/'TouchDeck.swift'),str(a.work/'ControllerSkins.swift'),str(a.work/'Support.swift'),str(r/'Sources/ConsoleSkin.swift'),str(r/'Sources/GameConsole.swift'),str(r/'Sources/PersonalSkin.swift'),str(r/'Sources/PersonalSkinLibrary.swift'),str(Path(__file__).with_name('Export.swift')),'-o',str(exe)],check=True)
subprocess.run(['codesign','-s','-',str(exe)],check=True)
subprocess.run(['xcrun','simctl','spawn',a.simulator,str(exe),str(a.output),str(r/'Content/Fonts')],check=True,timeout=180)
(a.output/'source-identity.json').write_text(json.dumps({'source':'VETA'+json.loads((r/'jit-integrated.json').read_text())['targets']['VetaJITLab']['info']['properties']['CFBundleVersion'],'renderer':'UIKit simulator; unmodified TouchDeck, ConsoleSkin and ControllerSkinLayout','scope':'Default layouts, not a capture of personal device profiles; full view uses reference safe areas and illustrative game/menu placeholders','sha256':{f:hashlib.sha256(s.encode()).hexdigest() for f,s in files.items()}},indent=2)+'\n')
