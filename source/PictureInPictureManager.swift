import AVKit
import UIKit
import Combine
import VLCKitSPM
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - PiP Manager Protocol
protocol PictureInPictureManagerDelegate: AnyObject {
    func pipDidStart()
    func pipDidStop()
    func pipWillStart()
    func pipWillStop()
    func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void)
}

// MARK: - Enhanced PiP Manager with Sample Buffer Support
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
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Frame Processing
    private let frameProcessingQueue = DispatchQueue(label: "com.rtspplayer.frame.processing", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.rtspplayer.render", qos: .userInteractive)
    
    // Timing
    private var timebase: CMTimebase?
    private var lastPresentationTime = CMTime.zero
    private let frameDuration = CMTime(value: 1, timescale: 30) // 30 FPS
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
    }
    
    // MARK: - Setup
    
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("PiP Support: \(isPiPSupported)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            print("Audio session configured for PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - Sample Buffer PiP Setup
    
    func setupPiPForVLCStream(vlcPlayer: VLCMediaPlayer, in containerView: UIView) {
        cleanup()
        
        self.vlcPlayer = vlcPlayer
        
        // Create display layer and view
        setupDisplayLayer(in: containerView)
        
        // Setup frame extractor
        setupFrameExtractor()
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
    }
    
    private func setupDisplayLayer(in containerView: UIView) {
        // Create sample buffer display layer
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("Failed to create sample buffer display layer")
            return
        }
        
        // Configure display layer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = containerView.bounds
        
        // Create container view for the layer
        displayLayerView = UIView(frame: containerView.bounds)
        displayLayerView?.backgroundColor = .clear
        displayLayerView?.layer.addSublayer(displayLayer)
        displayLayerView?.isHidden = true // Initially hidden
        
        // Add to container
        containerView.addSubview(displayLayerView!)
        
        // Setup timebase
        setupTimebase()
        
        print("Display layer configured")
    }
    
    private func setupTimebase() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        // Create timebase
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithMasterClock(
            allocator: kCFAllocatorDefault,
            masterClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        
        if status == noErr, let tb = timebase {
            self.timebase = tb
            displayLayer.controlTimebase = tb
            
            // Set initial time and rate
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            
            print("Timebase configured")
        }
    }
    
    private func setupFrameExtractor() {
        frameExtractor = VLCFrameExtractor(vlcPlayer: vlcPlayer!)
        frameExtractor?.delegate = self
        print("Frame extractor configured")
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
        
        print("Modern PiP controller configured (iOS 15+)")
    }
    
    private func setupLegacyPiPController() {
        // For iOS 14 and below
        print("Legacy PiP not fully supported for sample buffer")
    }
    
    private func configurePiPController() {
        guard let pipController = pipController else { return }
        
        pipController.delegate = self
        
        if #available(iOS 14.2, *) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        observePiPStates()
    }
    
    private func observePiPStates() {
        guard let pipController = pipController else { return }
        
        pipController.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPossible in
                self?.isPiPPossible = isPossible
                print("PiP Possible: \(isPossible)")
            }
            .store(in: &cancellables)
        
        pipController.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isPiPActive = isActive
                print("PiP Active: \(isActive)")
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    func startPiP() {
        guard isPiPSupported, isPiPPossible else {
            print("PiP not available")
            return
        }
        
        // Start frame extraction
        frameExtractor?.startExtraction()
        
        // Start PiP
        pipController?.startPictureInPicture()
        print("Starting PiP")
    }
    
    func stopPiP() {
        guard isPiPActive else { return }
        
        // Stop frame extraction
        frameExtractor?.stopExtraction()
        
        // Stop PiP
        pipController?.stopPictureInPicture()
        print("Stopping PiP")
    }
    
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        frameExtractor?.stopExtraction()
        frameExtractor = nil
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flushAndRemoveImage()
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        
        displayLayerView?.removeFromSuperview()
        displayLayerView = nil
        
        timebase = nil
        lastPresentationTime = .zero
        
        cancellables.removeAll()
        
        print("Cleanup completed")
    }
    
    deinit {
        cleanup()
    }
}

// MARK: - VLC Frame Extractor
class VLCFrameExtractor: NSObject {
    weak var vlcPlayer: VLCMediaPlayer?
    weak var delegate: VLCFrameExtractionDelegate?
    
    private var isExtracting = false
    private var extractionTimer: Timer?
    private let extractionQueue = DispatchQueue(label: "com.rtspplayer.extraction", qos: .userInteractive)
    
    // Frame buffer pool for performance
    private var pixelBufferPool: CVPixelBufferPool?
    private let poolAttributes: [String: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey as String: 5
    ]
    
    init(vlcPlayer: VLCMediaPlayer) {
        self.vlcPlayer = vlcPlayer
        super.init()
        setupPixelBufferPool()
    }
    
    private func setupPixelBufferPool() {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        pixelBufferPool = pool
    }
    
    func startExtraction() {
        guard !isExtracting, vlcPlayer != nil else { return }
        isExtracting = true
        
        // Setup VLC video callback
        setupVLCVideoCallback()
        
        print("Frame extraction started")
    }
    
    func stopExtraction() {
        isExtracting = false
        extractionTimer?.invalidate()
        extractionTimer = nil
        
        // Remove VLC video callback
        removeVLCVideoCallback()
        
        print("Frame extraction stopped")
    }
    
    private func setupVLCVideoCallback() {
        // Method 1: Use VLC snapshot capability
        startSnapshotBasedExtraction()
        
        // Method 2: Direct callback (if available in VLCKit version)
        // setupDirectVideoCallback()
    }
    
    private func startSnapshotBasedExtraction() {
        extractionTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.extractCurrentFrame()
        }
    }
    
    private func extractCurrentFrame() {
        guard let player = vlcPlayer,
              player.isPlaying,
              let drawable = player.drawable as? UIView else { return }
        
        extractionQueue.async { [weak self] in
            // Capture current frame from VLC drawable
            DispatchQueue.main.sync {
                if let pixelBuffer = self?.captureViewToPixelBuffer(drawable) {
                    self?.processPixelBuffer(pixelBuffer)
                }
            }
        }
    }
    
    private func captureViewToPixelBuffer(_ view: UIView) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        } else {
            // Create pixel buffer without pool
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(view.bounds.width),
                Int(view.bounds.height),
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }
        
        guard let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
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
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        UIGraphicsPushContext(context)
        view.layer.render(in: context)
        UIGraphicsPopContext()
        
        return buffer
    }
    
    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        // Create sample buffer from pixel buffer
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else { return }
        
        // Send to delegate
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didExtractFrame(sampleBuffer)
        }
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let format = formatDescription else { return nil }
        
        let now = CACurrentMediaTime()
        let presentationTime = CMTime(seconds: now, preferredTimescale: 1000000)
        let duration = CMTime(value: 1, timescale: 30)
        
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        // Mark for immediate display
        if let buffer = sampleBuffer {
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
        }
        
        return sampleBuffer
    }
    
    private func removeVLCVideoCallback() {
        // Clean up any VLC callbacks
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

// MARK: - Frame Processing
extension PictureInPictureManager: VLCFrameExtractionDelegate {
    func didExtractFrame(_ sampleBuffer: CMSampleBuffer) {
        renderQueue.async { [weak self] in
            self?.renderSampleBuffer(sampleBuffer)
        }
    }
    
    private func renderSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        // Check if layer is ready
        guard displayLayer.status != .failed else {
            print("Display layer failed")
            return
        }
        
        // Enqueue sample buffer
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            // Update presentation time
            lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        } else {
            // Layer is not ready, we might need to flush
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP will start")
        
        // Start frame extraction if not already started
        frameExtractor?.startExtraction()
        
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP did start")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP did stop")
        isPiPActive = false
        
        // Stop frame extraction
        frameExtractor?.stopExtraction()
        
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start PiP: \(error.localizedDescription)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Sample Buffer Playback Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   setPlaying playing: Bool) {
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
        return !(vlcPlayer?.isPlaying ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
        
        // Optionally recreate pixel buffer pool with new size
        // This can help optimize memory usage
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        // Live streams typically don't support skip
        print("Skip not supported for live stream")
        completionHandler()
    }
}

// MARK: - Integration Helper
extension PictureInPictureManager {
    
    /// Convenience method for VLC integration
    func connectToVLCPlayer(_ player: VLCMediaPlayer, containerView: UIView) {
        setupPiPForVLCStream(vlcPlayer: player, in: containerView)
        
        // Wait for player to start before enabling PiP
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if player.isPlaying {
                self?.frameExtractor?.startExtraction()
            }
        }
    }
    
    /// Check if PiP can be started
    var canStartPiP: Bool {
        return isPiPSupported && isPiPPossible && !isPiPActive && (vlcPlayer?.isPlaying ?? false)
    }
    
    /// Get current PiP status
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "Active"
        } else if isPiPPossible {
            return "Ready"
        } else if vlcPlayer?.isPlaying ?? false {
            return "Preparing"
        } else {
            return "Inactive"
        }
    }
}
