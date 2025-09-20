import AVKit
import UIKit
import Combine
import MobileVLCKit
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreImage

// MARK: - PiP Manager Protocol
protocol PictureInPictureManagerDelegate: AnyObject {
    func pipDidStart()
    func pipDidStop()
    func pipWillStart()
    func pipWillStop()
    func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void)
}

// MARK: - Enhanced PiP Manager with Direct libvlc Video Callbacks
class PictureInPictureManager: NSObject, ObservableObject {
    
    // Singleton
    static let shared = PictureInPictureManager()
    
    // Published Properties
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    
    // PiP Components
    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    private var displayLayerView: UIView?
    
    // VLC Components
    private var vlcPlayer: VLCMediaPlayer?
    private var containerView: UIView?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Frame Processing
    private let frameProcessingQueue = DispatchQueue(label: "com.rtspplayer.frame.processing", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.rtspplayer.render", qos: .userInteractive)
    
    // Timing and Synchronization
    private var timebase: CMTimebase?
    private var presentationStartTime = CMTime.zero
    private let targetFrameRate: Double = 30.0
    private var frameCounter: Int64 = 0
    
    // Frame buffer management
    private var pixelBufferPool: CVPixelBufferPool?
    private let poolSize = 10
    
    // Performance tracking
    private var lastFrameTime = CACurrentMediaTime()
    private var frameCount = 0
    private var averageFPS: Double = 0
    
    // 🔥 libvlc C API Video Callback - 직접 프레임 수신
    private var videoWidth: Int = 1920
    private var videoHeight: Int = 1080
    private var isReceivingFrames = false
    
    // Video frame buffer (libvlc에서 직접 쓰는 버퍼)
    private var videoBuffer: UnsafeMutableRawPointer?
    private var videoBufferSize: Int = 0
    
    // Current pixel buffer being written
    private var currentPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
    }
    
    // MARK: - Setup
    
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("📺 PiP Support: \(isPiPSupported)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
            try audioSession.setActive(true)
            print("🔊 Audio session configured for PiP")
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }
    
    private func setupPixelBufferPool(width: Int, height: Int) {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64
        ]
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: poolSize,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0
        ]
        
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        if result == kCVReturnSuccess {
            pixelBufferPool = pool
            print("🔧 Pixel buffer pool created: \(width)x\(height)")
        } else {
            print("❌ Failed to create pixel buffer pool: \(result)")
        }
    }
    
    // MARK: - VLC Player Connection
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        cleanup()
        
        self.vlcPlayer = vlcPlayer
        self.containerView = containerView
        
        print("🔗 Connecting to VLC player with direct libvlc video callbacks...")
        
        // Create display layer and view
        setupDisplayLayer(in: containerView)
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        // Wait for player to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if vlcPlayer.isPlaying {
                print("✅ VLC player is stable and playing")
                self?.updatePiPReadiness()
            }
        }
    }
    
    private func setupDisplayLayer(in containerView: UIView) {
        // Create sample buffer display layer
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("❌ Failed to create sample buffer display layer")
            return
        }
        
        // Configure display layer properties
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = containerView.bounds
        displayLayer.isOpaque = true
        
        // Create container view for the layer
        displayLayerView = UIView(frame: containerView.bounds)
        displayLayerView?.backgroundColor = .clear
        displayLayerView?.layer.addSublayer(displayLayer)
        
        // Initially hidden but not removed
        displayLayerView?.isHidden = false
        displayLayerView?.alpha = 0
        
        // Add to container with proper constraints
        containerView.addSubview(displayLayerView!)
        displayLayerView?.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            displayLayerView!.topAnchor.constraint(equalTo: containerView.topAnchor),
            displayLayerView!.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            displayLayerView!.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            displayLayerView!.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        // Setup timebase for proper synchronization
        setupTimebase()
        
        print("🖼️ Display layer configured (visible but transparent)")
    }
    
    private func setupTimebase() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        // Create timebase with host clock
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        
        if status == noErr, let tb = timebase {
            self.timebase = tb
            displayLayer.controlTimebase = tb
            
            // Set initial presentation time
            presentationStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000000)
            CMTimebaseSetTime(tb, time: presentationStartTime)
            CMTimebaseSetRate(tb, rate: 1.0)
            
            print("⏰ Timebase configured")
        } else {
            print("❌ Failed to create timebase: \(status)")
        }
    }
    
    @available(iOS 15.0, *)
    private func setupModernPiPController() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        configurePiPController()
        
        print("📱 Modern PiP controller configured (iOS 15+)")
    }
    
    private func setupLegacyPiPController() {
        print("⚠️ Legacy PiP not supported for sample buffer")
    }
    
    private func configurePiPController() {
        guard let pipController = pipController else { return }
        
        pipController.delegate = self
        
        // Configure automatic PiP behavior
        if #available(iOS 14.2, *) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = false
        }
        
        pipController.requiresLinearPlayback = false
        
        observePiPStates()
    }
    
    private func observePiPStates() {
        guard let pipController = pipController else { return }
        
        pipController.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPossible in
                self?.isPiPPossible = isPossible
                print("📊 PiP Possible: \(isPossible)")
            }
            .store(in: &cancellables)
        
        pipController.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isPiPActive = isActive
                print("📊 PiP Active: \(isActive)")
                self?.updateDisplayLayerVisibility(isActive)
            }
            .store(in: &cancellables)
    }
    
    private func updateDisplayLayerVisibility(_ isPiPActive: Bool) {
        guard let displayLayerView = displayLayerView else { return }
        
        DispatchQueue.main.async {
            if isPiPActive {
                displayLayerView.isHidden = false
            }
            
            UIView.animate(withDuration: 0.3) {
                displayLayerView.alpha = isPiPActive ? 1.0 : 0.0
            } completion: { _ in
                if !isPiPActive {
                    displayLayerView.isHidden = true
                }
            }
        }
    }
    
    // MARK: - Public PiP Control Methods
    
    func startPiP() {
        guard isPiPSupported, canStartPiP else {
            print("❌ Cannot start PiP - Supported: \(isPiPSupported), Can start: \(canStartPiP)")
            return
        }
        
        print("🚀 Starting PiP with direct libvlc video callbacks...")
        
        // Reset counters
        frameCounter = 0
        frameCount = 0
        lastFrameTime = CACurrentMediaTime()
        
        // 🔥 Setup libvlc video callbacks for direct frame reception
        setupLibVLCVideoCallbacks()
        
        // Small delay to ensure frames are being generated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pipController?.startPictureInPicture()
        }
    }
    
    func stopPiP() {
        guard isPiPActive else {
            print("⚠️ PiP is not active")
            return
        }
        
        print("🛑 Stopping PiP...")
        
        // Stop receiving frames
        removeLibVLCVideoCallbacks()
        
        // Stop PiP
        pipController?.stopPictureInPicture()
    }
    
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // MARK: - 🔥 libvlc C API Video Callbacks - Direct Frame Reception
    
    private func setupLibVLCVideoCallbacks() {
        guard let media = vlcPlayer?.media,
              let libvlcMedia = media.libVLCMediaInstance else {
            print("❌ Cannot access libvlc media instance")
            return
        }
        
        // Get actual video dimensions from VLC
        let size = vlcPlayer?.videoSize ?? CGSize(width: 1920, height: 1080)
        videoWidth = Int(size.width)
        videoHeight = Int(size.height)
        
        print("📐 Video dimensions: \(videoWidth)x\(videoHeight)")
        
        // Setup pixel buffer pool with actual dimensions
        setupPixelBufferPool(width: videoWidth, height: videoHeight)
        
        // Calculate buffer size for BGRA format
        videoBufferSize = videoWidth * videoHeight * 4
        
        // Setup libvlc video callbacks
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        // Set video format callback
        libvlc_video_set_format_callbacks(
            libvlcMedia,
            { (opaque, chroma, width, height, pitches, lines) -> UInt32 in
                guard let opaque = opaque else { return 0 }
                let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
                return manager.videoSetupCallback(chroma: chroma, width: width, height: height, pitches: pitches, lines: lines)
            },
            { (opaque) in
                guard let opaque = opaque else { return }
                let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
                manager.videoCleanupCallback()
            }
        )
        
        // Set video callbacks for lock/unlock/display
        libvlc_video_set_callbacks(
            libvlcMedia,
            { (opaque, planes) -> UnsafeMutableRawPointer? in
                guard let opaque = opaque else { return nil }
                let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
                return manager.videoLockCallback(planes: planes)
            },
            { (opaque, picture, planes) in
                guard let opaque = opaque else { return }
                let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
                manager.videoUnlockCallback(picture: picture, planes: planes)
            },
            { (opaque, picture) in
                guard let opaque = opaque else { return }
                let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
                manager.videoDisplayCallback(picture: picture)
            },
            selfPtr
        )
        
        isReceivingFrames = true
        print("✅ libvlc video callbacks configured")
    }
    
    private func removeLibVLCVideoCallbacks() {
        guard let media = vlcPlayer?.media,
              let libvlcMedia = media.libVLCMediaInstance else {
            return
        }
        
        // Remove callbacks
        libvlc_video_set_callbacks(libvlcMedia, nil, nil, nil, nil)
        libvlc_video_set_format_callbacks(libvlcMedia, nil, nil)
        
        isReceivingFrames = false
        
        // Clean up buffer
        if let buffer = videoBuffer {
            buffer.deallocate()
            videoBuffer = nil
        }
        
        print("🛑 libvlc video callbacks removed")
    }
    
    // MARK: - libvlc Video Callback Implementations
    
    private func videoSetupCallback(chroma: UnsafeMutablePointer<Int8>?, 
                                   width: UnsafeMutablePointer<UInt32>?, 
                                   height: UnsafeMutablePointer<UInt32>?, 
                                   pitches: UnsafeMutablePointer<UInt32>?, 
                                   lines: UnsafeMutablePointer<UInt32>?) -> UInt32 {
        
        // Set format to BGRA (reverse of ARGB due to byte order)
        chroma?.pointee = Int8(bitPattern: UInt8(ascii: "R"))
        chroma?.advanced(by: 1).pointee = Int8(bitPattern: UInt8(ascii: "V"))
        chroma?.advanced(by: 2).pointee = Int8(bitPattern: UInt8(ascii: "3"))
        chroma?.advanced(by: 3).pointee = Int8(bitPattern: UInt8(ascii: "2"))
        
        // Get dimensions
        if let w = width?.pointee, let h = height?.pointee {
            videoWidth = Int(w)
            videoHeight = Int(h)
            
            // Setup pitch (bytes per row)
            pitches?.pointee = w * 4
            lines?.pointee = h
            
            print("📹 Video format: \(videoWidth)x\(videoHeight) BGRA")
            
            // Recreate pixel buffer pool with correct size
            setupPixelBufferPool(width: videoWidth, height: videoHeight)
        }
        
        return 1 // Success
    }
    
    private func videoCleanupCallback() {
        print("🧹 Video cleanup callback")
        
        if let buffer = videoBuffer {
            buffer.deallocate()
            videoBuffer = nil
        }
        
        currentPixelBuffer = nil
    }
    
    private func videoLockCallback(planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        bufferLock.lock()
        
        // Create or reuse pixel buffer
        var pixelBuffer: CVPixelBuffer?
        
        if let pool = pixelBufferPool {
            let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            if result != kCVReturnSuccess {
                print("❌ Failed to create pixel buffer from pool: \(result)")
                bufferLock.unlock()
                return nil
            }
        }
        
        guard let buffer = pixelBuffer else {
            bufferLock.unlock()
            return nil
        }
        
        // Lock pixel buffer
        CVPixelBufferLockBaseAddress(buffer, [])
        
        // Get base address
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            bufferLock.unlock()
            return nil
        }
        
        // Store current buffer
        currentPixelBuffer = buffer
        
        // Set plane pointer for libvlc to write to
        planes?.pointee = baseAddress
        
        return baseAddress
    }
    
    private func videoUnlockCallback(picture: UnsafeMutableRawPointer?, 
                                    planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
        defer {
            bufferLock.unlock()
        }
        
        guard let pixelBuffer = currentPixelBuffer else {
            return
        }
        
        // Unlock pixel buffer
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    
    private func videoDisplayCallback(picture: UnsafeMutableRawPointer?) {
        guard let pixelBuffer = currentPixelBuffer else {
            return
        }
        
        // Process frame on background queue
        frameProcessingQueue.async { [weak self] in
            self?.processVideoFrame(pixelBuffer)
        }
        
        currentPixelBuffer = nil
    }
    
    // MARK: - Frame Processing
    
    private func processVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            return
        }
        
        renderQueue.async { [weak self] in
            self?.renderSampleBuffer(sampleBuffer)
        }
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let format = formatDescription else {
            print("❌ Failed to create format description: \(status)")
            return nil
        }
        
        let now = CACurrentMediaTime()
        let presentationTime = CMTime(seconds: now, preferredTimescale: 1000000000)
        let duration = CMTime(value: 1, timescale: Int32(targetFrameRate))
        
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        guard result == noErr, let buffer = sampleBuffer else {
            print("❌ Failed to create sample buffer: \(result)")
            return nil
        }
        
        // Set display immediately
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            if CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        
        return buffer
    }
    
    private func renderSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        frameCount += 1
        frameCounter += 1
        
        // Check layer status
        guard displayLayer.status != .failed else {
            print("❌ Display layer failed, flushing...")
            displayLayer.flush()
            return
        }
        
        // Enqueue frame
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            // Update FPS
            let currentTime = CACurrentMediaTime()
            if frameCount % 30 == 0 {
                let timeDelta = currentTime - lastFrameTime
                if timeDelta > 0 {
                    averageFPS = 30.0 / timeDelta
                    print("📊 PiP Frame rate: \(String(format: "%.1f", averageFPS)) FPS (Direct libvlc)")
                }
                lastFrameTime = currentTime
            }
        } else {
            if displayLayer.status == .failed {
                print("⚠️ Display layer not ready")
                DispatchQueue.main.async {
                    displayLayer.flush()
                }
            }
        }
    }
    
    private func updatePiPReadiness() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        print("🧹 Cleaning up PiP manager...")
        
        removeLibVLCVideoCallbacks()
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flushAndRemoveImage()
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        
        displayLayerView?.removeFromSuperview()
        displayLayerView = nil
        
        timebase = nil
        presentationStartTime = .zero
        frameCounter = 0
        
        currentPixelBuffer = nil
        pixelBufferPool = nil
        
        cancellables.removeAll()
        
        print("✅ Cleanup completed")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Helper Properties
    
    var canStartPiP: Bool {
        return isPiPSupported && isPiPPossible && !isPiPActive && (vlcPlayer?.isPlaying ?? false)
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "Active (Direct libvlc - \(String(format: "%.1f", averageFPS)) FPS)"
        } else if isPiPPossible {
            return "Ready"
        } else if vlcPlayer?.isPlaying ?? false {
            return "Preparing..."
        } else {
            return "Inactive"
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📱 PiP will start")
        
        if !isReceivingFrames {
            setupLibVLCVideoCallbacks()
        }
        
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP started successfully with direct libvlc video callbacks")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📱 PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP stopped")
        isPiPActive = false
        removeLibVLCVideoCallbacks()
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        print("❌ Failed to start PiP: \(error.localizedDescription)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("🔄 Restore UI for PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Sample Buffer Playback Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   setPlaying playing: Bool) {
        print("🎮 PiP playback control: \(playing ? "play" : "pause")")
        
        if playing {
            vlcPlayer?.play()
            if !isReceivingFrames {
                setupLibVLCVideoCallbacks()
            }
        } else {
            vlcPlayer?.pause()
            removeLibVLCVideoCallbacks()
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(vlcPlayer?.isPlaying ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("📐 PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        print("⏭️ Skip not supported for live stream")
        completionHandler()
    }
}
