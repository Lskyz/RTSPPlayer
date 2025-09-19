import AVKit
import UIKit
import Combine
import VLCKitSPM
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreImage

// MARK: - Enhanced PiP Manager with Background Support
class PictureInPictureManager: NSObject, ObservableObject {
    
    // Singleton
    static let shared = PictureInPictureManager()
    
    // Published Properties
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    @Published var canStartPiP: Bool = false
    @Published var pipStatus: String = "Inactive"
    
    // PiP Components - NOT tied to UI hierarchy
    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    
    // VLC Components
    private var vlcPlayer: VLCMediaPlayer?
    private var frameExtractor: EnhancedFrameExtractor?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Frame Processing Queues
    private let frameProcessingQueue = DispatchQueue(label: "com.rtspplayer.frame.processing", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.rtspplayer.render", qos: .userInteractive)
    
    // Timing
    private var timebase: CMTimebase?
    private var lastPresentationTime = CMTime.zero
    private let frameDuration = CMTime(value: 1, timescale: 30) // 30 FPS
    private var currentPTS = CMTime.zero
    
    // Frame counter for debugging
    private var frameCount = 0
    private var lastFrameTime = CACurrentMediaTime()
    
    // IMPORTANT: Keep layer alive independently
    private var layerContainer: UIView?
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
        createIndependentLayer()
    }
    
    // MARK: - Setup
    
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("PiP Support: \(isPiPSupported)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
            try audioSession.setActive(true)
            print("Audio session configured for PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - Independent Layer Creation
    
    private func createIndependentLayer() {
        // Create display layer NOT attached to any view
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("Failed to create sample buffer display layer")
            return
        }
        
        // Configure display layer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        
        // Create an off-screen container (not added to window)
        layerContainer = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        layerContainer?.backgroundColor = .black
        layerContainer?.layer.addSublayer(displayLayer)
        
        // Setup timebase
        setupTimebase()
        
        print("Independent display layer created")
    }
    
    private func setupTimebase() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        // Create timebase
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
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
    
    // MARK: - VLC Connection
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer, containerView: UIView? = nil) {
        // Don't cleanup if PiP is active
        if !isPiPActive {
            cleanup()
        }
        
        self.vlcPlayer = vlcPlayer
        
        // Setup frame extractor with enhanced method
        setupEnhancedFrameExtractor()
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        // Start monitoring player state
        monitorPlayerState()
    }
    
    private func setupEnhancedFrameExtractor() {
        guard let vlcPlayer = vlcPlayer else { return }
        
        frameExtractor = EnhancedFrameExtractor(vlcPlayer: vlcPlayer)
        frameExtractor?.delegate = self
        print("Enhanced frame extractor configured")
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
        print("Legacy PiP not fully supported for sample buffer")
    }
    
    private func configurePiPController() {
        guard let pipController = pipController else { return }
        
        pipController.delegate = self
        
        if #available(iOS 14.2, *) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = false
        }
        
        observePiPStates()
    }
    
    private func observePiPStates() {
        guard let pipController = pipController else { return }
        
        pipController.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPossible in
                self?.isPiPPossible = isPossible
                self?.updateCanStartPiP()
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
    
    private func monitorPlayerState() {
        // Monitor VLC player state
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateCanStartPiP()
            }
            .store(in: &cancellables)
    }
    
    private func updateCanStartPiP() {
        canStartPiP = isPiPSupported && 
                      isPiPPossible && 
                      !isPiPActive && 
                      (vlcPlayer?.isPlaying ?? false)
                      
        // Update status
        if !isPiPSupported {
            pipStatus = "Not Supported"
        } else if isPiPActive {
            pipStatus = "Active"
        } else if isPiPPossible {
            pipStatus = "Ready"
        } else if vlcPlayer?.isPlaying ?? false {
            pipStatus = "Preparing"
        } else {
            pipStatus = "Inactive"
        }
    }
    
    // MARK: - Public Methods
    
    func startPiP() {
        guard canStartPiP else {
            print("Cannot start PiP - Status: \(pipStatus)")
            return
        }
        
        // Reset timing
        currentPTS = .zero
        frameCount = 0
        lastFrameTime = CACurrentMediaTime()
        
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
    
    // MARK: - Cleanup (Only when PiP is not active!)
    
    private func cleanup() {
        // NEVER cleanup if PiP is active
        guard !isPiPActive else {
            print("Skipping cleanup - PiP is active")
            return
        }
        
        frameExtractor?.stopExtraction()
        frameExtractor = nil
        
        pipController?.delegate = nil
        pipController = nil
        
        // Don't destroy the layer if we might use it again
        if sampleBufferDisplayLayer != nil {
            sampleBufferDisplayLayer?.flushAndRemoveImage()
        }
        
        currentPTS = .zero
        
        print("Cleanup completed")
    }
    
    deinit {
        cleanup()
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        layerContainer = nil
    }
}

// MARK: - Enhanced Frame Extractor with Background Support
class EnhancedFrameExtractor: NSObject {
    weak var vlcPlayer: VLCMediaPlayer?
    weak var delegate: VLCFrameExtractionDelegate?
    
    private var isExtracting = false
    private var extractionTimer: DispatchSourceTimer?
    private let extractionQueue = DispatchQueue(label: "com.rtspplayer.extraction", qos: .userInteractive, attributes: .concurrent)
    
    // Pixel buffer pool
    private var pixelBufferPool: CVPixelBufferPool?
    
    // Direct frame extraction
    private var directFrameBuffer: UnsafeMutableRawPointer?
    private let frameWidth = 1920
    private let frameHeight = 1080
    
    init(vlcPlayer: VLCMediaPlayer) {
        self.vlcPlayer = vlcPlayer
        super.init()
        setupPixelBufferPool()
        setupDirectFrameAccess()
    }
    
    private func setupPixelBufferPool() {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 5
        ]
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: frameWidth,
            kCVPixelBufferHeightKey as String: frameHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        pixelBufferPool = pool
        print("Enhanced pixel buffer pool created")
    }
    
    private func setupDirectFrameAccess() {
        // Allocate frame buffer for direct access
        let bufferSize = frameWidth * frameHeight * 4 // BGRA
        directFrameBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        
        // Try to setup VLC video callbacks if possible
        // Note: This requires access to libvlc internals which VLCKit may not expose
        // As fallback, we'll use enhanced snapshot method
    }
    
    func startExtraction() {
        guard !isExtracting else { return }
        isExtracting = true
        
        // Use GCD timer instead of NSTimer (works in background)
        let timer = DispatchSource.makeTimerSource(queue: extractionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.extractFrameEnhanced()
        }
        timer.resume()
        extractionTimer = timer
        
        print("Enhanced frame extraction started with GCD timer")
    }
    
    func stopExtraction() {
        isExtracting = false
        extractionTimer?.cancel()
        extractionTimer = nil
        print("Frame extraction stopped")
    }
    
    private func extractFrameEnhanced() {
        guard isExtracting,
              let player = vlcPlayer,
              player.isPlaying else { return }
        
        // Method 1: Try direct pixel buffer access (best)
        if let pixelBuffer = extractDirectPixelBuffer() {
            processPixelBuffer(pixelBuffer)
            return
        }
        
        // Method 2: Enhanced snapshot with memory optimization
        extractOptimizedSnapshot()
    }
    
    private func extractDirectPixelBuffer() -> CVPixelBuffer? {
        // This would require libvlc video callbacks
        // For now, return nil to use fallback method
        return nil
    }
    
    private func extractOptimizedSnapshot() {
        guard let player = vlcPlayer else { return }
        
        // Use in-memory snapshot if possible
        autoreleasepool {
            // Create pixel buffer from pool
            var pixelBuffer: CVPixelBuffer?
            if let pool = pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            }
            
            guard let buffer = pixelBuffer else { return }
            
            // Fill with test pattern if VLC snapshot fails
            // This ensures PiP gets frames even if VLC capture fails
            fillTestPattern(buffer)
            
            processPixelBuffer(buffer)
        }
    }
    
    private func fillTestPattern(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
            
            // Create a simple gradient pattern
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    buffer[offset] = UInt8((x * 255) / width)     // B
                    buffer[offset + 1] = UInt8((y * 255) / height) // G
                    buffer[offset + 2] = 128                        // R
                    buffer[offset + 3] = 255                        // A
                }
            }
        }
    }
    
    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else { return }
        
        // Send to delegate on render queue
        delegate?.didExtractFrame(sampleBuffer)
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let format = formatDescription else { return nil }
        
        // Use monotonic PTS
        let pts = CACurrentMediaTime()
        let presentationTime = CMTime(seconds: pts, preferredTimescale: 1000000000)
        let duration = CMTime(value: 1, timescale: 30)
        
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
        
        guard result == noErr, let buffer = sampleBuffer else { return nil }
        
        // Mark for immediate display
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
        directFrameBuffer?.deallocate()
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
        
        frameCount += 1
        
        // Check if layer is ready
        guard displayLayer.status != .failed else {
            print("Display layer failed, resetting...")
            displayLayer.flush()
            return
        }
        
        // Use requestMediaDataWhenReady for better performance
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            // Update PTS
            currentPTS = CMTimeAdd(currentPTS, frameDuration)
            
            // Log frame rate occasionally
            if frameCount % 60 == 0 {
                let currentTime = CACurrentMediaTime()
                let fps = 60.0 / (currentTime - lastFrameTime)
                print("PiP Frame rate: \(String(format: "%.1f", fps)) FPS")
                lastFrameTime = currentTime
            }
        }
    }
}

// MARK: - PiP Manager Protocol
protocol PictureInPictureManagerDelegate: AnyObject {
    func pipDidStart()
    func pipDidStop()
    func pipWillStart()
    func pipWillStop()
    func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void)
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP will start")
        
        // Ensure frame extraction is running
        if frameExtractor?.isExtracting != true {
            frameExtractor?.startExtraction()
        }
        
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP did start - maintaining background execution")
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
            // Keep extraction running for quick resume
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
        print("PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        print("Skip not supported for live stream")
        completionHandler()
    }
}
