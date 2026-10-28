#!/usr/bin/env python3
from pathlib import Path
import argparse,subprocess,plistlib,shutil
p=argparse.ArgumentParser();p.add_argument('--work',type=Path,required=True);p.add_argument('--simulator',required=True);a=p.parse_args();r=Path(__file__).resolve().parents[2];a.work.mkdir(parents=True,exist_ok=True)
app=a.work/'SkinPreview.app';app.mkdir(exist_ok=True)
(a.work/'TouchDeck.swift').write_text((r/'Sources/TouchDeck.swift').read_text().split('\nfinal class GameViewController:')[0]+'\n')
(a.work/'Support.swift').write_text('''import UIKit
extension UIColor {convenience init(hex:UInt32,alpha:CGFloat=1) {self.init(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha)}}
enum L10n {static func text(_ value:String)->String {value};static func format(_ s:String,_ args:CVarArg...)->String{String(format:s,arguments:args)}}
enum StateFile {static let coreID="preview-only"}
enum VetaError:Error {case message(String)}
func veta_max_players(_ index:UInt32)->Int32 {1}
''')
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-swift-version','5','-sdk',sdk,'-target','arm64-apple-ios17.4-simulator',str(a.work/'TouchDeck.swift'),str(a.work/'Support.swift'),*[str(r/'Sources'/f) for f in ['ControllerSkins.swift','ConsoleSkin.swift','GameConsole.swift','PersonalSkin.swift','PersonalSkinLibrary.swift','PersonalSkinViews.swift']],str(Path(__file__).with_name('PreviewApp.swift')),'-o',str(app/'SkinPreview')],check=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.krafify.veta.skins.preview168','CFBundleExecutable':'SkinPreview','CFBundleName':'SkinPreview','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSRequiresIPhoneOS':True,'UIDeviceFamily':[1,2],'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']}))
subprocess.run(['codesign','--force','-s','-',str(app)],check=True)
subprocess.run(['xcrun','simctl','install',a.simulator,str(app)],check=True)
subprocess.run(['xcrun','simctl','launch',a.simulator,'com.krafify.veta.skins.preview168'],check=True)
