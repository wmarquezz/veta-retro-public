import MetalKit
#if canImport(MetalFX)
import MetalFX
#endif

/// A distinct lease belongs to each display's submitted command buffer.
/// Completion may run off-main; releasing it never performs GL work.
private final class SharedVideoLease: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: UnsafeMutableRawPointer?
    init(_ pointer: UnsafeMutableRawPointer) { self.pointer = pointer }
    func finish() {
        lock.lock(); let owned = pointer; pointer = nil; lock.unlock()
        if let owned { veta_shared_frame_release(owned) }
    }
    deinit { finish() }
}

/// Independent spatial processing for each image of a dual-screen console.
/// All work stays on the view's command queue, ordered with upload and present.
/// Resources are private GPU textures, cached until source/output geometry changes.
final class SpatialVideoScaler {
    struct Region:Equatable {
        var source: CGRect
        var destination: CGRect
    }
    static func regions(width:Int,height:Int,outputWidth:Int,outputHeight:Int,layout:DSScreenLayout,dual:Bool,threeDSSideBySide:Bool)->[Region] {
        let w=CGFloat(width),h=CGFloat(height),ow=CGFloat(outputWidth),oh=CGFloat(outputHeight)
        func r(_ s:CGRect,_ d:CGRect)->Region {Region(source:s,destination:d)}
        let all=CGRect(x:0,y:0,width:w,height:h),dest=CGRect(x:0,y:0,width:ow,height:oh)
        guard dual else{return [r(all,dest)]}
        let half=floor(h/2),top=CGRect(x:0,y:0,width:w,height:half),bottom=CGRect(x:0,y:half,width:w,height:h-half)
        if threeDSSideBySide {
            let split=(ow*5/9).rounded()
            return [r(top,CGRect(x:0,y:0,width:split,height:oh)),r(CGRect(x:(w*0.1).rounded(),y:half,width:(w*0.8).rounded(),height:h-half),CGRect(x:split,y:0,width:ow-split,height:oh))]
        }
        switch layout {
        case .sideBySide:
            let split=floor(ow/2)
            return [r(top,CGRect(x:0,y:0,width:split,height:oh)),r(bottom,CGRect(x:split,y:0,width:ow-split,height:oh))]
        case .topOnly:return [r(top,dest)]
        case .bottomOnly:return [r(bottom,dest)]
        default:
            let split=floor(oh/2),a=CGRect(x:0,y:0,width:ow,height:split),b=CGRect(x:0,y:split,width:ow,height:oh-split)
            return layout == .swapped ? [r(bottom,a),r(top,b)]:[r(top,a),r(bottom,b)]
        }
    }
    #if canImport(MetalFX)
    private struct Slot {
        let region:Region
        let scaler:MTLFXSpatialScaler
        let input:MTLTexture
        let output:MTLTexture
    }
    private var slots:[Slot]=[]
    private var cachedRegions:[Region]=[]
    private var cachedFormat:MTLPixelFormat = .invalid
    #endif
    private(set) var status=""
    private(set) var resourceGeneration=0
    func reportGPUFailure() {status=L10n.text("MetalFX no disponible · suavizado nítido")}
    func encode(source:MTLTexture,target:MTLTexture,buffer:MTLCommandBuffer,pipeline:MTLRenderPipelineState,layout:DSScreenLayout,dual:Bool,threeDSSideBySide:Bool)->Bool {
        #if canImport(MetalFX)
        let device=source.device
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {status=L10n.text("MetalFX no disponible · suavizado nítido");return false}
        let regions=Self.regions(width:source.width,height:source.height,outputWidth:target.width,outputHeight:target.height,layout:layout,dual:dual,threeDSSideBySide:threeDSSideBySide)
        // Do not run a reconstruction pass when the destination is smaller.
        guard regions.allSatisfy({$0.destination.width >= $0.source.width && $0.destination.height >= $0.source.height}) else {status=L10n.text("Reducción · suavizado nítido");return false}
        if regions != cachedRegions || cachedFormat != source.pixelFormat {
            var fresh:[Slot]=[]
            for region in regions {
                let d=MTLFXSpatialScalerDescriptor()
                d.inputWidth=Int(region.source.width);d.inputHeight=Int(region.source.height)
                d.outputWidth=Int(region.destination.width);d.outputHeight=Int(region.destination.height)
                guard d.inputWidth>0,d.inputHeight>0,d.outputWidth>0,d.outputHeight>0 else{return false}
                d.colorTextureFormat=source.pixelFormat;d.outputTextureFormat=source.pixelFormat;d.colorProcessingMode = .perceptual
                guard let scaler=d.makeSpatialScaler(device:device) else {status=L10n.text("MetalFX rechazó tamaño · suavizado nítido");return false}
                func texture(_ w:Int,_ h:Int,_ usage:MTLTextureUsage)->MTLTexture? {
                    let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:source.pixelFormat,width:w,height:h,mipmapped:false)
                    desc.storageMode = .private;desc.usage=usage.union(.shaderRead)
                    return device.makeTexture(descriptor:desc)
                }
                guard let input=texture(d.inputWidth,d.inputHeight,scaler.colorTextureUsage),let output=texture(d.outputWidth,d.outputHeight,scaler.outputTextureUsage) else {status=L10n.text("Sin recursos · suavizado nítido");return false}
                fresh.append(Slot(region:region,scaler:scaler,input:input,output:output))
            }
            slots=fresh;cachedRegions=regions;cachedFormat=source.pixelFormat;resourceGeneration += 1
        }
        guard let blit=buffer.makeBlitCommandEncoder() else{return false}
        for slot in slots {
            blit.copy(from:source,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:Int(slot.region.source.minX),y:Int(slot.region.source.minY),z:0),sourceSize:MTLSize(width:slot.input.width,height:slot.input.height,depth:1),to:slot.input,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
        }
        blit.endEncoding()
        for slot in slots {
            slot.scaler.colorTexture=slot.input;slot.scaler.outputTexture=slot.output
            slot.scaler.inputContentWidth=slot.input.width;slot.scaler.inputContentHeight=slot.input.height
            slot.scaler.encode(commandBuffer:buffer)
        }
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1)
        guard let encoder=buffer.makeRenderCommandEncoder(descriptor:pass) else{return false}
        encoder.setRenderPipelineState(pipeline)
        var settings=SIMD2<UInt32>(VideoFilter.pixels.shaderValue,0)
        encoder.setFragmentBytes(&settings,length:MemoryLayout<SIMD2<UInt32>>.size,index:0)
        for slot in slots {
            let rect=slot.region.destination
            encoder.setViewport(MTLViewport(originX:Double(rect.minX),originY:Double(rect.minY),width:Double(rect.width),height:Double(rect.height),znear:0,zfar:1))
            encoder.setFragmentTexture(slot.output,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        }
        encoder.endEncoding()
        status=L10n.format("MetalFX espacial · %@×%@ → %@×%@ · %@ imagen(es)",String(source.width),String(source.height),String(target.width),String(target.height),String(slots.count))
        return true
        #else
        status=L10n.text("MetalFX no disponible · suavizado nítido");return false
        #endif
    }
}


final class MetalScreen: MTKView, MTKViewDelegate {
    var isPrimaryDisplay = true
    var enhancementConsole:GameConsole?
    private(set) var presentation = VideoPresentation()
    var isNintendoDS = false
    var isNintendo3DS = false
    private let spatialScaler=SpatialVideoScaler()
    private(set) var enhancementStatus=""
    private(set) var completedFrames=0
    private(set) var lastGPUError:String?
    private var spatialGPUFailed=false
    var threeDSSideBySide = false {didSet {if oldValue != threeDSSideBySide {veta_set_pointer(0,0,false)}}}
    func applyPresentation(_ value: VideoPresentation) {
        if presentation != value {veta_set_pointer(0,0,false)}
        presentation=value
        #if VETA_JIT_DEVELOPMENT
        // Explicit UI-test probe of the TV algorithm on the phone's drawable.
        // Never persisted; ordinary launches keep independent phone/TV profiles.
        if isPrimaryDisplay,ProcessInfo.processInfo.environment["VETA_TV158_QA_PRIMARY"] == "1",let console=enhancementConsole {
            presentation.filter=TVImageMode.automatic.filter(for:console,inherited:value.filter)
        }
        #endif
    }
    private var lastShareTime: TimeInterval = 0
    private var pipeline: MTLRenderPipelineState?
    private var commands: MTLCommandQueue?
    private var textures: [MTLTexture] = []
    private var index = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private var pendingFrame = false
    private var pendingTexture: MTLTexture?
    private var pendingSharedLease: SharedVideoLease?
    private func cancelPendingFrame() {
        guard pendingFrame else { return }
        pendingFrame = false
        let lease = pendingSharedLease
        pendingSharedLease = nil; pendingTexture = nil
        lease?.finish(); inFlight.signal()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelPendingFrame() }
    }
    deinit {
        pendingSharedLease?.finish()
        if pendingFrame { inFlight.signal() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        delegate = self
        accessibilityIdentifier = "nes-screen"
        isAccessibilityElement = true
        accessibilityLabel = L10n.text("Pantalla NES")
        guard let device, let library = device.makeDefaultLibrary() else { return }
        commands = device.makeCommandQueue()
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name:"veta_vertex")
        desc.fragmentFunction = library.makeFunction(name:"veta_fragment")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor:desc)
    }
#if VETA_JIT_DEVELOPMENT
    // XCTest needs a current snapshot: the on-screen summary updates only once
    // per second, which biases short audio windows by almost a full second.
    override var accessibilityValue:String? {
        get {
            let count=Int(veta_width()*veta_height()),pixels=veta_video()
            let colors=Set(stride(from:0,to:count,by:max(1,count/1024)).map{pixels![$0]}).count
            return "frames:\(veta_frame_count());audio:\(veta_audio_nonzero());input:\(veta_input_mask(0));fpsTarget:\(veta_fps());audioProduced:\(veta_audio_count());sampleRate:\(veta_sample_rate());audioDelivered:\(veta_audio_delivered());audioUnderruns:\(veta_audio_underruns());audioDropped:\(veta_audio_dropped());videoColors:\(colors);videoWidth:\(veta_width());videoHeight:\(veta_height());enhancement:\(enhancementStatus);gpuCompleted:\(completedFrames);gpuError:\(lastGPUError ?? "none");jitPool:\(veta_jit_available() ? 1:0)" + Emulation.runProfileMetrics
        }
        set {super.accessibilityValue=newValue}
    }
#endif
    var acceptsTouchscreen = false
    private func updatePointer(_ touches:Set<UITouch>,pressed:Bool) {
        guard acceptsTouchscreen,let touch=touches.first,bounds.width>0,bounds.height>0 else{return}
        let p=touch.location(in:self)
        let normalized=CGPoint(x:p.x/bounds.width,y:p.y/bounds.height)
        let mapped:CGPoint
        if threeDSSideBySide {
            guard let touch=ThreeDSScreenGeometry.touchPoint(normalized) else {veta_set_pointer(0,0,false);return}
            mapped=touch
        } else if isNintendoDS {
            guard let touch=presentation.dsLayout.touchPoint(normalized) else {veta_set_pointer(0,0,false);return}
            mapped=touch
        } else {mapped=normalized}
        let x=Int16(max(-32767,min(32767,mapped.x*65534-32767)))
        let y=Int16(max(-32767,min(32767,mapped.y*65534-32767)))
        veta_set_pointer(x,y,pressed && bounds.contains(p))
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?){updatePointer(touches,pressed:true)}
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?){updatePointer(touches,pressed:true)}
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?){updatePointer(touches,pressed:false)}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?){veta_set_pointer(0,0,false)}
    var ready: Bool { pipeline != nil }
    func presentFrame() {
        guard !pendingFrame, let device, inFlight.wait(timeout: .now()) == .success else { return }
        let frame = veta_shared_frame_acquire(Unmanaged.passUnretained(device as AnyObject).toOpaque())
        let w = Int(frame.width), h = Int(frame.height)
        let lease = frame.lease.map { SharedVideoLease($0) }
        guard w > 0, h > 0 else { lease?.finish(); inFlight.signal(); return }
        let sharedTexture = frame.texture.flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? MTLTexture }
        if let sharedTexture, let lease, sharedTexture.device === device,
           sharedTexture.width == w, sharedTexture.height == h {
            pendingTexture = sharedTexture
            pendingSharedLease = lease
        } else {
            lease?.finish()
            if textures.first?.width != w || textures.first?.height != h {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
                descriptor.usage = .shaderRead
                let newTextures = (0..<3).compactMap { _ in device.makeTexture(descriptor:descriptor) }
                guard newTextures.count == 3 else { inFlight.signal(); return }
                textures = newTextures; index = 0
            }
            // The ordinary three-slot CPU path remains the default and the
            // fallback for this exact publication, including a full shared pool.
            textures[index].replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:veta_video(),bytesPerRow:w*4)
            pendingTexture = textures[index]
            pendingSharedLease = nil
        }
        pendingFrame = true
        draw()
        // MTKView can skip its delegate when detached/backgrounded. Never keep
        // an unsubmitted lease or semaphore token waiting for a future draw.
        // A late delegate callback sees pendingFrame=false and does nothing.
        cancelPendingFrame()
        if isPrimaryDisplay {
            ExternalDisplayHub.shared.presentFrame()
            let now = ProcessInfo.processInfo.systemUptime
            if PlayTogether.shared.isHosting, PlayTogether.shared.shareVideo, now - lastShareTime >= 0.2 {
                lastShareTime = now
                // Copy while the core's frame is stable; the shared preview owns its pixels.
                let data = Data(bytes: veta_video(), count: w * h * 4)
                if let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                    PlayTogether.shared.publishFrame(image)
                }
            }
        }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard pendingFrame else { return }
        pendingFrame = false
        let selectedTexture = pendingTexture, lease = pendingSharedLease
        pendingTexture = nil; pendingSharedLease = nil
        guard let pipeline, let texture = selectedTexture, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let buffer = commands?.makeCommandBuffer() else { lease?.finish(); inFlight.signal(); return }
        if lease == nil { index = (index + 1) % 3 }
        let spatial=presentation.filter == .spatial && !spatialGPUFailed && spatialScaler.encode(source:texture,target:drawable.texture,buffer:buffer,pipeline:pipeline,layout:presentation.dsLayout,dual:isNintendoDS || isNintendo3DS || threeDSSideBySide,threeDSSideBySide:threeDSSideBySide)
        if spatial {enhancementStatus=spatialScaler.status}
        else {
            guard let encoder=buffer.makeRenderCommandEncoder(descriptor:pass) else {lease?.finish();inFlight.signal();return}
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture,index:0)
            let filter=presentation.filter == .spatial ? VideoFilter.sharpSmooth:presentation.filter
            var settings=SIMD2<UInt32>(filter.shaderValue,presentation.dsLayout.shaderValue | (isNintendoDS || isNintendo3DS || threeDSSideBySide ? 0x100:0) | (threeDSSideBySide ? 0x200:0))
            encoder.setFragmentBytes(&settings,length:MemoryLayout<SIMD2<UInt32>>.size,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
            encoder.endEncoding()
            enhancementStatus=presentation.filter == .spatial ? spatialScaler.status:"\(filter.rawValue) · \(texture.width)×\(texture.height) → \(drawable.texture.width)×\(drawable.texture.height)"
        }
        let semaphore = inFlight
        buffer.addCompletedHandler { [weak self, lease] command in
            lease?.finish()
            semaphore.signal()
            let error=command.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else{return}
                self.completedFrames += 1
                if let error {self.lastGPUError=error;if spatial {self.spatialGPUFailed=true;self.spatialScaler.reportGPUFailure()}}
            }
        }
        buffer.present(drawable); buffer.commit()
    }
}
