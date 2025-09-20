import AVKit
import UIKit
import Combine
import VLCKitSPM
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

// MARK: - Enhanced PiP Manager with System Level Support
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
    private var frameExtractor: VLCFrameExtractor?
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
    private let poolSize = 5
    
    // Performance tracking
    private var lastFrameTime = CACurrentMediaTime()
    private var frameCount = 0
    private var averageFPS: Double = 0
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
        setupPixelBufferPool()
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
    
    private func setupPixelBufferPool() {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferBytesPerRowAlignmentKey as String: 16
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
            print("🔧 Pixel buffer pool created successfully")
        } else {
            print("❌ Failed to create pixel buffer pool: \(result)")
        }
    }
    
    // MARK: - VLC Player Connection
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        cleanup()
        
        self.vlcPlayer = vlcPlayer
        self.containerView = containerView
        
        print("🔗 Connecting to VLC player...")
        
        // Create display layer and view
        setupDisplayLayer(in: containerView)
        
        // Setup frame extractor with optimized approach
        setupFrameExtractor()
        
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
        displayLayerView?.isHidden = true // Initially hidden, will show during PiP
        displayLayerView?.alpha = 0 // Transparent initially
        
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
        
        print("🖼️ Display layer configured with bounds: \(containerView.bounds)")
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
            
            print("⏰ Timebase configured with start time: \(presentationStartTime)")
        } else {
            print("❌ Failed to create timebase: \(status)")
        }
    }
    
    private func setupFrameExtractor() {
        frameExtractor = VLCFrameExtractor(vlcPlayer: vlcPlayer!, containerView: containerView!)
        frameExtractor?.delegate = self
        print("🎬 Frame extractor configured")
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
        
        // Disable linear playback to show all controls
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
                
                // Show/hide display layer based on PiP state
                self?.updateDisplayLayerVisibility(isActive)
            }
            .store(in: &cancellables)
    }
    
    private func updateDisplayLayerVisibility(_ isPiPActive: Bool) {
        guard let displayLayerView = displayLayerView else { return }
        
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.3) {
                displayLayerView.alpha = isPiPActive ? 1.0 : 0.0
            }
        }
    }
    
    // MARK: - Public PiP Control Methods
    
    func startPiP() {
        guard isPiPSupported, canStartPiP else {
            print("❌ Cannot start PiP - Supported: \(isPiPSupported), Can start: \(canStartPiP)")
            return
        }
        
        print("🚀 Starting PiP...")
        
        // Reset counters
        frameCounter = 0
        frameCount = 0
        lastFrameTime = CACurrentMediaTime()
        
        // Start frame extraction first
        frameExtractor?.startExtraction()
        
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
        
        // Stop frame extraction
        frameExtractor?.stopExtraction()
        
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
    
    private func updatePiPReadiness() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        print("🧹 Cleaning up PiP manager...")
        
        frameExtractor?.stopExtraction()
        frameExtractor = nil
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flushAndRemoveImage()
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        
        displayLayerView?.removeFromSuperview()
        displayLayerView = nil
        
        if let timebase = timebase {
            CFRelease(timebase)
            self.timebase = nil
        }
        
        presentationStartTime = .zero
        frameCounter = 0
        
        cancellables.removeAll()
        
        print("✅ Cleanup completed")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Helper Properties
    
    var canStartPiP: Bool {
        let canStart = isPiPSupported && isPiPPossible && !isPiPActive && (vlcPlayer?.isPlaying ?? false)
        return canStart
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "Active (\(String(format: "%.1f", averageFPS)) FPS)"
        } else if isPiPPossible {
            return "Ready"
        } else if vlcPlayer?.isPlaying ?? false {
            return "Preparing..."
        } else {
            return "Inactive"
        }
    }
}

// MARK: - Enhanced VLC Frame Extractor
class VLCFrameExtractor: NSObject {
    weak var vlcPlayer: VLCMediaPlayer?
    weak var delegate: VLCFrameExtractionDelegate?
    private var containerView: UIView
    
    private(set) var isExtracting = false
    private var extractionTimer: Timer?
    private let extractionQueue = DispatchQueue(label: "com.rtspplayer.extraction", qos: .userInteractive)
    
    // Enhanced capture approach - direct view capture instead of snapshots
    private var captureDisplayLink: CADisplayLink?
    private let targetFPS: Double = 30.0
    
    // Pixel buffer optimization
    private var pixelBufferPool: CVPixelBufferPool?
    private var lastCaptureTime = CACurrentMediaTime()
    
    init(vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        self.vlcPlayer = vlcPlayer
        self.containerView = containerView
        super.init()
        setupPixelBufferPool()
    }
    
    private func setupPixelBufferPool() {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferBytesPerRowAlignmentKey as String: 16
        ]
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        pixelBufferPool = pool
        print("🔧 Frame extractor pixel buffer pool created")
    }
    
    func startExtraction() {
        guard !isExtracting, vlcPlayer != nil else {
            print("⚠️ Cannot start extraction - already extracting or no player")
            return
        }
        
        isExtracting = true
        lastCaptureTime = CACurrentMediaTime()
        
        // Use CADisplayLink for smooth frame extraction
        DispatchQueue.main.async { [weak self] in
            self?.startDisplayLinkCapture()
        }
        
        print("🎬 Frame extraction started")
    }
    
    func stopExtraction() {
        isExtracting = false
        
        DispatchQueue.main.async { [weak self] in
            self?.captureDisplayLink?.invalidate()
            self?.captureDisplayLink = nil
        }
        
        print("🛑 Frame extraction stopped")
    }
    
    private func startDisplayLinkCapture() {
        captureDisplayLink = CADisplayLink(target: self, selector: #selector(captureFrame))
        captureDisplayLink?.preferredFramesPerSecond = Int(targetFPS)
        captureDisplayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func captureFrame() {
        guard isExtracting,
              let player = vlcPlayer,
              player.isPlaying else { return }
        
        let currentTime = CACurrentMediaTime()
        let timeDelta = currentTime - lastCaptureTime
        
        // Throttle to target FPS
        if timeDelta < (1.0 / targetFPS) {
            return
        }
        
        lastCaptureTime = currentTime
        
        extractionQueue.async { [weak self] in
            self?.performFrameCapture()
        }
    }
    
    private func performFrameCapture() {
        guard let pixelBuffer = captureViewToPixelBuffer() else {
            return
        }
        
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didExtractFrame(sampleBuffer)
        }
    }
    
    private func captureViewToPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        
        // Try pool first for better performance
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        
        guard let buffer = pixelBuffer else {
            // Fallback to direct creation
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            
            let width = Int(containerView.bounds.width * UIScreen.main.scale)
            let height = Int(containerView.bounds.height * UIScreen.main.scale)
            
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            
            guard let fallbackBuffer = pixelBuffer else { return nil }
            buffer = fallbackBuffer
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        // Capture on main thread to ensure proper rendering
        var captureSuccess = false
        DispatchQueue.main.sync {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1.0, y: -1.0)
            
            UIGraphicsPushContext(context)
            containerView.layer.render(in: context)
            UIGraphicsPopContext()
            
            captureSuccess = true
        }
        
        return captureSuccess ? buffer : nil
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        // Create format description
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
        
        // Create timing info with precise timestamps
        let now = CACurrentMediaTime()
        let presentationTime = CMTime(seconds: now, preferredTimescale: 1000000000)
        let duration = CMTime(value: 1, timescale: Int32(targetFPS))
        
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        // Create sample buffer
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
        
        // Set display immediately flag for low latency
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
    
    deinit {
        stopExtraction()
        pixelBufferPool = nil
    }
}

// MARK: - Frame Extraction Delegate
protocol VLCFrameExtractionDelegate: AnyObject {
    func didExtractFrame(_ sampleBuffer: CMSampleBuffer)
}

// MARK: - Frame Processing Implementation
extension PictureInPictureManager: VLCFrameExtractionDelegate {
    func didExtractFrame(_ sampleBuffer: CMSampleBuffer) {
        renderQueue.async { [weak self] in
            self?.renderSampleBuffer(sampleBuffer)
        }
    }
    
    private func renderSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        frameCount += 1
        frameCounter += 1
        
        // Check layer readiness
        guard displayLayer.status != .failed else {
            print("❌ Display layer failed, flushing...")
            displayLayer.flush()
            return
        }
        
        // Enqueue frame if layer is ready
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            // Update FPS calculation
            let currentTime = CACurrentMediaTime()
            if frameCount % 30 == 0 {
                let timeDelta = currentTime - lastFrameTime
                if timeDelta > 0 {
                    averageFPS = 30.0 / timeDelta
                    print("📊 PiP Frame rate: \(String(format: "%.1f", averageFPS)) FPS")
                }
                lastFrameTime = currentTime
            }
        } else {
            // Layer not ready, check status
            if displayLayer.status == .failed {
                print("⚠️ Display layer not ready, status: \(displayLayer.status.rawValue)")
                
                // Try to recover
                DispatchQueue.main.async {
                    displayLayer.flush()
                }
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📱 PiP will start")
        
        // Ensure frame extraction is active
        if frameExtractor?.isExtracting != true {
            frameExtractor?.startExtraction()
        }
        
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP started successfully")
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
        
        // Stop frame extraction
        frameExtractor?.stopExtraction()
        
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
            frameExtractor?.startExtraction()
        } else {
            vlcPlayer?.pause()
            frameExtractor?.stopExtraction()
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // For live streams, return infinite range
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        let isPaused = !(vlcPlayer?.isPlaying ?? false)
        return isPaused
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
