#if VETA_JIT_DEVELOPMENT
import Foundation
// Losing focus (Control Center, an alert or an app transition) is not the same
// as entering the background. Only the latter requires tearing down a boot
// that cannot yet be paused. Keep this decision independently testable.
struct NativeLifecyclePolicy {
    enum Phase:Equatable {case idle,preparing,ready,loading,running,paused,stopping,stopped,failed}
    enum Event {case resignActive,enterBackground}
    enum Action:Equatable {case releaseInput,pause,stop}
    static func action(for event:Event,phase:Phase,canPause:Bool)->Action {
        switch event {
        case .resignActive:
            return phase == .running && canPause ? .pause:.releaseInput
        case .enterBackground:
            switch phase {
            case .preparing,.loading:return .stop
            case .running:return canPause ? .pause:.stop
            default:return .releaseInput
            }
        }
    }
}
// A pause caused by an interruption needs an explicit way back into the game.
// Wait for both native pause completion and foreground before presenting UI;
// neither event resumes the engine. This state is never persisted.
struct NativeInterruptionMenuPolicy {
    private(set) var pending=false
    private var pauseCompleted=false
    mutating func request(){pending=true;pauseCompleted=false}
    mutating func acknowledgePause(){if pending {pauseCompleted=true}}
    mutating func cancel(){pending=false;pauseCompleted=false}
    mutating func consume(foreground:Bool,phase:NativeLifecyclePolicy.Phase,menuVisible:Bool)->Bool {
        if [.stopping,.stopped,.failed].contains(phase){cancel();return false}
        guard pending,pauseCompleted,foreground,phase == .paused else{return false}
        cancel()
        return !menuVisible
    }
}
// Two bounded files retain recent lifecycle evidence without accumulating logs
// for the lifetime of an installed development build. Caller is the main actor.
enum NativeLifecycleLog {
    enum Failure:Error {case entryTooLarge}
    static let maximumBytes=256*1024
    static func append(_ entry:String,to file:URL,limit:Int=maximumBytes)throws {
        let bytes=Data((entry+"\n").utf8)
        guard limit>0,bytes.count<=limit else{throw Failure.entryTooLarge}
        let files=FileManager.default
        try files.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        if files.fileExists(atPath:file.path) {
            let size=(try files.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size>limit-bytes.count {
                let previous=file.appendingPathExtension("previous")
                if files.fileExists(atPath:previous.path){try files.removeItem(at:previous)}
                // Do not retain an already oversized file from an older build.
                if size>limit {try files.removeItem(at:file)}
                else {try files.moveItem(at:file,to:previous)}
            }
        }
        if files.fileExists(atPath:file.path) {
            let handle=try FileHandle(forWritingTo:file);defer{try? handle.close()}
            try handle.seekToEnd();try handle.write(contentsOf:bytes)
        } else {try bytes.write(to:file)}
    }
}
#endif
