#if VETA_JIT_DEVELOPMENT
import Foundation

// A snapshot may take an upstream engine mutex or wait for a main-thread task.
// Only the lifecycle queue may read it; UI always sees a nonblocking POD copy.
final class NativeSnapshotMailbox {
    private let queue:DispatchQueue
    private let lock=NSLock()
    private var cached:VNGSnapshot?
    private var pending=false
    private var closed=false
    private var generation:UInt64=0
    init(queue:DispatchQueue){self.queue=queue}
    func value(refresh:@escaping()->VNGSnapshot?)->VNGSnapshot? {
        lock.lock()
        guard !closed else {lock.unlock();return nil}
        let value=cached,enqueue = !pending,revision=generation
        if enqueue {pending=true}
        lock.unlock()
        if enqueue {
            queue.async { [self] in
                lock.lock();let valid = !closed && generation==revision;lock.unlock()
                let result=valid ? refresh():nil
                lock.lock();pending=false
                if !closed && generation==revision {cached=result}
                lock.unlock()
            }
        }
        return value
    }
    func invalidate() {lock.lock();generation &+= 1;cached=nil;lock.unlock()}
    func close() {lock.lock();closed=true;generation &+= 1;cached=nil;lock.unlock()}
}

#endif
