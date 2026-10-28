import Foundation
import CryptoKit
@main struct Tests {
 static func main() throws {
  let folder=URL(fileURLWithPath:CommandLine.arguments[1]),fm=FileManager.default
  let manifest=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:folder.appendingPathComponent("manifest.json")))
  var checks=0
  func check(_ condition:Bool,_ label:String){precondition(condition,label);checks+=1}
  func reject(_ label:String,_ run:()throws->Void){do{try run();preconditionFailure(label)}catch{checks+=1}}
  for (name,stage) in manifest.sorted(by:{$0.key<$1.key}) {
   let url=folder.appendingPathComponent(name)
   if stage=="init" {reject(name){_=try PS2DiscReader(url:url)};continue}
   let reader=try PS2DiscReader(url:url)
   if stage=="read" {reject(name){_=try reader.read(offset:0,length:2048)};continue}
   let reference=try Data(contentsOf:folder.appendingPathComponent(name.hasPrefix("plain-partial") ? "plain-partial.iso":"reference.iso"))
   check(reader.logicalSize==reference.count,name+"size")
   check(try reader.read(offset:0,length:reference.count)==reference,name+"whole")
   var rng:UInt64=0x987654321
   for _ in 0..<400 {
    rng=rng&*6364136223846793005&+1;let start=Int(rng%UInt64(reference.count))
    rng=rng&*6364136223846793005&+1;let count=min(Int(rng%8192)+1,reference.count-start)
    check(try reader.read(offset:UInt64(start),length:count)==reference[start..<(start+count)],name+"range")
   }
   check(try reader.read(offset:reader.logicalSize,length:0).isEmpty,name+"EOF")
   reject("EOF+1"){_=try reader.read(offset:reader.logicalSize,length:1)}
   reject("overflow"){_=try reader.read(offset:UInt64.max,length:1)}
   reject("negative"){_=try reader.read(offset:0,length:-1)}
   reject("huge request"){_=try reader.read(offset:0,length:Int.max)}
   let tally=NSLock();var failures=0
   DispatchQueue.concurrentPerform(iterations:100){i in
    let start=(i*1999)%(reference.count-64)
    do{if try reader.read(offset:UInt64(start),length:64) != reference[start..<(start+64)]{tally.lock();failures+=1;tally.unlock()}}
    catch{tally.lock();failures+=1;tally.unlock()}
   }
   check(failures==0,"concurrent ranges")
   if name.hasSuffix(".cso") {
    let cache=Mirror(reflecting:reader).children.first(where:{$0.label=="cache"})!.value as! [Int:Data]
    check(cache.values.reduce(0){$0+$1.count}<=131072,"cache byte ceiling")
   }
  }
  let temp=folder.appendingPathComponent("mutation.iso");try Data(repeating:1,count:4096).write(to:temp)
  let reader=try PS2DiscReader(url:temp);_=try reader.read(offset:0,length:8)
  try Data(repeating:2,count:4096).write(to:temp,options:[]) // same inode, changed data
  reject("changed file"){_=try reader.read(offset:0,length:8)};try fm.removeItem(at:temp)
  let csotemp=folder.appendingPathComponent("mutation.cso");try fm.copyItem(at:folder.appendingPathComponent("good-0.cso"),to:csotemp)
  let cached=try PS2DiscReader(url:csotemp);_=try cached.read(offset:0,length:8)
  let writer=try FileHandle(forWritingTo:csotemp);try writer.truncate(atOffset:24);try writer.close()
  reject("truncated after cache"){_=try cached.read(offset:0,length:8)};try fm.removeItem(at:csotemp)
  reject("directory"){_=try PS2DiscReader(url:folder)}
  let link=folder.appendingPathComponent("link.iso");try fm.createSymbolicLink(at:link,withDestinationURL:folder.appendingPathComponent("reference.iso"))
  reject("symlink"){_=try PS2DiscReader(url:link)};try fm.removeItem(at:link)
  let report:[String:Any]=["status":"PASS","checks":checks,"fixtureCount":manifest.count,"realDisc":false]
  let out=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]);print(String(decoding:out,as:UTF8.self))
 }
}
