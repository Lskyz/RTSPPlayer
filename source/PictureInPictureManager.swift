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

// MARK: - Enhanced PiP Manager with System Level PiP Support
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
    
    // Timing with Host Clock
    private var timebase: CMTimebase?
    private var lastPresentationTime = CMTime.zero
    private let frameDuration = CMTime(value: 1, timescale: 30) // 30 FPS
    
    // Frame counter for debugging
    private var frameCount = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var firstFrameReceived = false
    
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
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        cleanup()
        
        self.vlcPlayer = vlcPlayer
        self.containerView = containerView
        
        // Create display layer and view
        setupDisplayLayer(in: containerView)
        
        // Setup frame extractor with improved method
        setupFrameExtractor()
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        // Wait for player to be stable before starting frame extraction
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if vlcPlayer.isPlaying {
                print("VLC player is playing, ready for PiP")
            }
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
        
        // CRITICAL FIX: Keep layer visible for system PiP
        displayLayerView?.isHidden = false
        displayLayerView?.alpha = 0.01 // Almost invisible but not zero
        
        // Add to container
        containerView.addSubview(displayLayerView!)
        
        // Setup timebase with Host Clock
        setupTimebaseWithHostClock()
        
        print("Display layer configured with bounds: \(containerView.bounds), visible for system PiP")
    }
    
    private func setupTimebaseWithHostClock() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        // Create timebase with Host Clock for better sync
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), // Use Host Clock
            timebaseOut: &timebase
        )
        
        if status == noErr, let tb = timebase {
            self.timebase = tb
            displayLayer.controlTimebase = tb
            
            // Set initial time and rate
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            
            print("Timebase configured with Host Clock")
        }
    }
    
    private func setupFrameExtractor() {
        frameExtractor = VLCFrameExtractor(vlcPlayer: vlcPlayer!, containerView: containerView!)
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
        print("Legacy PiP not fully supported for sample buffer")
    }
    
    private func configurePiPController() {
        guard let pipController = pipController else { return }
        
        pipController.delegate = self
        
        // CRITICAL FIX: Enable automatic PiP transition
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
            print("PiP not available - Supported: \(isPiPSupported), Possible: \(isPiPPossible)")
            return
        }
        
        // Reset frame counter
        frameCount = 0
        lastFrameTime = CACurrentMediaTime()
        firstFrameReceived = false
        
        // Start frame extraction
        frameExtractor?.startExtraction()
        
        // IMPROVED: Wait for first frame before starting PiP
        waitForFirstFrameAndStartPiP()
    }
    
    private func waitForFirstFrameAndStartPiP() {
        let checkInterval: TimeInterval = 0.1
        let maxWaitTime: TimeInterval = 3.0
        var elapsedTime: TimeInterval = 0
        
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            elapsedTime += checkInterval
            
            // Check if we have received frames and layer is ready
            if self.firstFrameReceived && (self.sampleBufferDisplayLayer?.isReadyForMoreMediaData == true) {
                timer.invalidate()
                print("First frame received, starting PiP")
                self.pipController?.startPictureInPicture()
            } else if elapsedTime >= maxWaitTime {
                timer.invalidate()
                print("Timeout waiting for first frame, starting PiP anyway")
                self.pipController?.startPictureInPicture()
            }
        }
        
        // Store timer reference to prevent deallocation
        DispatchQueue.main.asyncAfter(deadline: .now() + maxWaitTime + 0.1) {
            timer.invalidate()
        }
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
        firstFrameReceived = false
        
        cancellables.removeAll()
        
        print("Cleanup completed")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Integration Helper Properties
    
    var canStartPiP: Bool {
        let canStart = isPiPSupported && isPiPPossible && !isPiPActive && (vlcPlayer?.isPlaying ?? false)
        print("Can start PiP: \(canStart) (Supported: \(isPiPSupported), Possible: \(isPiPPossible), Active: \(isPiPActive), Playing: \(vlcPlayer?.isPlaying ?? false))")
        return canStart
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "System PiP Active"
        } else if isPiPPossible {
            return "Ready for System PiP"
        } else if vlcPlayer?.isPlaying ?? false {
            return "Preparing System PiP"
        } else {
            return "Inactive"
        }
    }
}

// MARK: - Improved VLC Frame Extractor with Background Timer
class VLCFrameExtractor: NSObject {
    weak var vlcPlayer: VLCMediaPlayer?
    weak var delegate: VLCFrameExtractionDelegate?
    private var containerView: UIView
    
    var isExtracting = false
    
    // CRITICAL FIX: Use DispatchSourceTimer for background operation
    private var extractionTimerSrc: DispatchSourceTimer?
    private let extractionQueue = DispatchQueue(label: "com.rtspplayer.extraction", qos: .userInteractive)
    
    // Snapshot path for frame extraction
    private let documentsPath = NSTemporaryDirectory()
    private var snapshotCounter = 0
    
    // Frame buffer pool for performance
    private var pixelBufferPool: CVPixelBufferPool?
    private let poolAttributes: [String: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey as String: 3
    ]
    
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
        print("Pixel buffer pool created")
    }
    
    func startExtraction() {
        guard !isExtracting, vlcPlayer != nil else { return }
        isExtracting = true
        
        // CRITICAL FIX: Use DispatchSourceTimer for background operation
        startBackgroundTimerExtraction()
        
        print("Background frame extraction started")
    }
    
    func stopExtraction() {
        isExtracting = false
        extractionTimerSrc?.cancel()
        extractionTimerSrc = nil
        
        print("Background frame extraction stopped")
    }
    
    private func startBackgroundTimerExtraction() {
        let timer = DispatchSource.makeTimerSource(queue: extractionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5)) // ~30 FPS
        timer.setEventHandler { [weak self] in
            self?.extractFrameViaSnapshot()
        }
        timer.resume()
        extractionTimerSrc = timer
        
        print("Background timer configured for 30 FPS extraction")
    }
    
    private func extractFrameViaSnapshot() {
        guard let player = vlcPlayer,
              player.isPlaying,
              isExtracting else { return }
        
        captureFrameFromVLCSnapshot()
    }
    
    private func captureFrameFromVLCSnapshot() {
        guard let player = vlcPlayer else { return }
        
        snapshotCounter += 1
        // Cleanup old snapshots to prevent storage issues
        if snapshotCounter > 100 {
            cleanupOldSnapshots()
            snapshotCounter = 1
        }
        
        let snapshotPath = "\(documentsPath)vlc_frame_\(snapshotCounter).png"
        
        // Use the corrected method name
        player.saveVideoSnapshot(at: snapshotPath, withWidth: 1920, andHeight: 1080)
        
        // Reduced wait time for better performance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.processSnapshotFile(at: snapshotPath)
        }
    }
    
    private func cleanupOldSnapshots() {
        extractionQueue.async {
            let fileManager = FileManager.default
            let tempDir = NSTemporaryDirectory()
            
            do {
                let files = try fileManager.contentsOfDirectory(atPath: tempDir)
                for file in files {
                    if file.hasPrefix("vlc_frame_") && file.hasSuffix(".png") {
                        try fileManager.removeItem(atPath: tempDir + file)
                    }
                }
            } catch {
                print("Failed to cleanup snapshots: \(error)")
            }
        }
    }
    
    private func processSnapshotFile(at path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let image = UIImage(contentsOfFile: path) else {
            // If snapshot failed, try direct view capture as fallback
            captureViewDirectly()
            return
        }
        
        // Convert UIImage to CVPixelBuffer
        if let pixelBuffer = imageToPixelBuffer(image) {
            processPixelBuffer(pixelBuffer)
        }
        
        // Clean up snapshot file immediately
        try? FileManager.default.removeItem(atPath: path)
    }
    
    private func captureViewDirectly() {
        // Fallback method: capture the container view directly
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let pixelBuffer = self.captureViewToPixelBuffer(self.containerView) {
                self.processPixelBuffer(pixelBuffer)
            }
        }
    }
    
    private func imageToPixelBuffer(_ image: UIImage) -> CVPixelBuffer? {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        
        var pixelBuffer: CVPixelBuffer?
        
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
    }
    
    private func captureViewToPixelBuffer(_ view: UIView) -> CVPixelBuffer? {
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        
        guard width > 0, height > 0 else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }
        
        guard let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
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
        guard let sampleBuffer = createSampleBufferWithHostClock(from: pixelBuffer) else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didExtractFrame(sampleBuffer)
        }
    }
    
    private func createSampleBufferWithHostClock(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let format = formatDescription else {
            print("Failed to create format description")
            return nil
        }
        
        // CRITICAL FIX: Use Host Clock for consistent timing
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let duration = CMTime(value: 1, timescale: 30)
        
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: hostTime,
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
            print("Failed to create sample buffer")
            return nil
        }
        
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
        
        // Mark first frame received for PiP timing
        if !firstFrameReceived {
            firstFrameReceived = true
            print("First frame received, PiP can now start")
        }
        
        // Check if layer is ready
        guard displayLayer.status != .failed else {
            print("Display layer failed, resetting...")
            displayLayer.flush()
            return
        }
        
        // Enqueue sample buffer
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            // Update presentation time
            lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            // Log frame rate occasionally
            let currentTime = CACurrentMediaTime()
            if frameCount % 60 == 0 {
                let fps = 60.0 / (currentTime - lastFrameTime)
                print("System PiP Frame rate: \(String(format: "%.1f", fps)) FPS")
                lastFrameTime = currentTime
            }
        } else {
            if displayLayer.status == .failed {
                print("Display layer not ready, flushing...")
                displayLayer.flush()
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP will start")
        
        // Ensure frame extraction is running
        if frameExtractor?.isExtracting != true {
            frameExtractor?.startExtraction()
        }
        
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP did start - Success!")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP did stop")
        isPiPActive = false
        
        frameExtractor?.stopExtraction()
        
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start System PiP: \(error.localizedDescription)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for System PiP")
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
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(vlcPlayer?.isPlaying ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("System PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        print("Skip not supported for live stream")
        completionHandler()
    }
}
