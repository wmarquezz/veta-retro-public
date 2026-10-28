#!/usr/bin/env python3
"""Read-only readiness checks. Never signs, uploads, publishes or asserts Apple approval."""
import argparse,hashlib,json,plistlib,re,subprocess,sys
from pathlib import Path
from urllib.parse import urlsplit
REQUIRED=['reviewContactConfirmed','supportMailboxVerified','privacyAnswersReviewed','encryptionDeclarationReviewed','licensesAndContentRightsReviewed','catalogSafeguardsReviewed','publicConsoleMatrixPassed','iPhoneAndIPadValidationPassed','correspondingSourcesPrepared','screenshotsMatchPublicBuild','ageRatingCompleted']
BANNED={'PS2Core.framework','PS2Wasm','StikJIT.framework','VetaInternalJIT.appex','VetaInternalVPN.appex','DukeXCore.framework','RPCS3Core.framework','XeniOSCore.framework','VetaARMSCore.framework'}
BIOS={'sega_101.bin','mpr-17933.bin','scph5500.bin','scph5501.bin','scph5502.bin','scph1001.bin','dc_boot.bin','dc_flash.bin'}
def check(app,metadata):
 blockers=[];checks=[]
 def require(value,message):
  (checks if value else blockers).append(message)
 info=plistlib.loads((app/'Info.plist').read_bytes())
 require(info.get('CFBundleIdentifier')=='com.krafify.vetaretro','Public bundle identifier; integrated development app is not a submission')
 require('ITSAppUsesNonExemptEncryption' in info and type(info['ITSAppUsesNonExemptEncryption']) is bool,'Export-compliance declaration present; answer must match encryption review')
 require(bool(info.get('NSLocalNetworkUsageDescription')),'Local-network purpose string')
 require(bool(info.get('NSBonjourServices')),'Bonjour service declarations')
 require(bool(info.get('CFBundleIcons')),'App icon compiled')
 resources=list(app.rglob('*'));files=[p for p in resources if p.is_file()]
 from public_games import audit as audit_public_games
 try:
  game_errors=audit_public_games(app)
  blockers.extend(game_errors)
  require(not game_errors,'Public catalog: 2–4 reviewed games, pinned resources, no external offers')
 except (ValueError,KeyError,OSError,StopIteration) as error:
  blockers.append('Public game audit failed: '+str(error))
 for p in resources:
  if p.name in BANNED or p.suffix=='.xctest':blockers.append('Development/test component: '+p.relative_to(app).as_posix())
 for p in files:
  if p.name.lower() in BIOS or p.name in ['pairing.plist','embedded.mobileprovision.private','private-pairing-backup.bin'] or p.suffix in ['.p12','.jks','.key']:
   blockers.append('Private/firmware material requires removal: '+p.relative_to(app).as_posix())
 manifests=[p for p in files if p.name=='PrivacyInfo.xcprivacy']
 require(bool(manifests),'Privacy manifest included')
 reasons={}
 for p in manifests:
  data=plistlib.loads(p.read_bytes())
  for entry in data.get('NSPrivacyAccessedAPITypes',[]):reasons.setdefault(entry['NSPrivacyAccessedAPIType'],set()).update(entry['NSPrivacyAccessedAPITypeReasons'])
 for category,required in {'UserDefaults':{'CA92.1'},'FileTimestamp':{'C617.1','3B52.1'},'SystemBootTime':{'35F9.1'}}.items():
  require(required<=reasons.get('NSPrivacyAccessedAPICategory'+category,set()),'Declared host API reasons: '+category)
 # Public APIs scan is a triage, not a substitute for reviewing all SDKs and dynamic lookups.
 scanned=[]
 bundles=[app]+list((app/'Frameworks').glob('*.framework'))
 for bundle in bundles:
  meta=plistlib.loads((bundle/'Info.plist').read_bytes());binary=bundle/meta['CFBundleExecutable']
  result=subprocess.run(['xcrun','nm','-u',str(binary)],capture_output=True,text=True)
  require(result.returncode==0,'Imported-symbol scan: '+bundle.name)
  found=sorted(set(re.findall(r'(?m)\b(_(?:ptrace|csops|task_for_pid|memorystatus_control))\s*$',result.stdout)))
  if found:blockers.append('Review non-public/restricted imports in '+bundle.name+': '+', '.join(found))
  scanned.append({'bundle':bundle.name,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'flaggedImports':found})
 sign=subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True)
 require(sign.returncode==0,'Strict package signature')
 ent=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True)
 try:
  ents=plistlib.loads(ent.stdout);require(not ents.get('get-task-allow',False),'Distribution signing without debugger entitlement')
  require(not any(k.startswith('com.apple.private.') for k in ents),'No private entitlements')
  require('com.apple.developer.networking.networkextension' not in ents,'No development VPN entitlement')
 except Exception:blockers.append('Unable to inspect signing entitlements')
 publication=[p for p in files if p.name=='Publication.plist'];contact=plistlib.loads(publication[0].read_bytes()) if len(publication)==1 else {}
 require(bool(metadata.get('publisherName','').strip()) and contact.get('PublisherName')==metadata.get('publisherName'),'Legal publisher supplied and matches app')
 require(bool(re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',metadata.get('supportEmail',''))) and contact.get('SupportEmail')==metadata.get('supportEmail'),'Support contact supplied and matches app')
 for key,appkey in [('supportURL','SupportURL'),('privacyPolicyURL','PrivacyPolicyURL')]:
  u=urlsplit(metadata.get(key,''));require(u.scheme=='https' and bool(u.hostname) and not u.username and not u.password and contact.get(appkey)==metadata.get(key),key+' supplied and matches app')
 for key in REQUIRED:require(metadata.get(key) is True,'Human/device evidence: '+key)
 evidence=metadata.get('evidence',[]);require(bool(evidence),'Evidence references recorded; flags alone do not certify compliance')
 return {'status':'blocked' if blockers else 'automated-checks-passed','appleApprovalGuaranteed':False,'app':str(app),'version':info.get('CFBundleVersion'),'checksPassed':checks,'blockers':blockers,'binaryInventory':scanned,'manualReviewStillRequired':True}
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('app',type=Path);ap.add_argument('--metadata',type=Path,required=True);ap.add_argument('--report',type=Path,required=True);a=ap.parse_args()
 result=check(a.app,json.loads(a.metadata.read_text()));a.report.write_text(json.dumps(result,indent=2));print(json.dumps({'status':result['status'],'passed':len(result['checksPassed']),'blockers':len(result['blockers']),'report':str(a.report)}));sys.exit(1 if result['blockers'] else 0)
