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

// MARK: - Enhanced PiP Manager with Direct Sample Buffer
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
    private var videoProcessingQueue: DispatchQueue
    private var displayLink: CADisplayLink?
    
    // VLC Integration
    private var vlcPlayer: VLCMediaPlayer?
    private var videoOutputView: UIView?
    
    // Sample Buffer Generation
    private var formatDescription: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?
    private var timebase: CMTimebase?
    private var frameCount: Int64 = 0
    private let frameRate: Double = 30.0
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        self.videoProcessingQueue = DispatchQueue(
            label: "com.rtspplayer.video.processing",
            qos: .userInteractive,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        
        super.init()
        checkPiPSupport()
        setupAudioSession()
    }
    
    // MARK: - Setup Methods
    
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("PiP Support: \(isPiPSupported)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            print("Audio session configured for PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - Enhanced Sample Buffer PiP Setup
    
    func setupPiPForVLCPlayer(_ vlcPlayer: VLCMediaPlayer, in view: UIView) {
        cleanupPiP()
        
        self.vlcPlayer = vlcPlayer
        self.videoOutputView = view
        
        // Create sample buffer display layer
        setupSampleBufferDisplayLayer()
        
        // Setup pixel buffer pool for efficient memory management
        setupPixelBufferPool()
        
        // Setup CMTimebase for sample timing
        setupTimebase()
        
        // Setup VLC video callbacks for direct frame extraction
        setupVLCVideoCallbacks()
        
        // Create PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        // Start frame extraction
        startFrameExtraction()
    }
    
    private func setupSampleBufferDisplayLayer() {
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("Failed to create sample buffer display layer")
            return
        }
        
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        
        // Set the display layer bounds
        displayLayer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        
        print("Sample buffer display layer created")
    }
    
    private func setupPixelBufferPool() {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        self.pixelBufferPool = pool
        
        // Create format description
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1920,
            height: 1080,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        self.formatDescription = formatDesc
        
        print("Pixel buffer pool created")
    }
    
    private func setupTimebase() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        var timebase: CMTimebase?
        CMTimebaseCreateWithMasterClock(
            allocator: kCFAllocatorDefault,
            masterClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        
        if let timebase = timebase {
            self.timebase = timebase
            displayLayer.controlTimebase = timebase
            
            // Set initial time and rate
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            
            print("Timebase configured")
        }
    }
    
    // MARK: - VLC Video Callbacks
    
    private func setupVLCVideoCallbacks() {
        // This is where we'd ideally set up direct VLC callbacks
        // In practice, VLCKit doesn't expose direct frame callbacks easily
        // So we'll use an alternative approach with display link
        
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback))
        displayLink?.preferredFramesPerSecond = 30
        displayLink?.add(to: .main, forMode: .common)
        
        print("Video callbacks configured")
    }
    
    @objc private func displayLinkCallback(_ displayLink: CADisplayLink) {
        guard let vlcPlayer = vlcPlayer,
              vlcPlayer.isPlaying,
              let view = videoOutputView else { return }
        
        videoProcessingQueue.async { [weak self] in
            self?.captureAndProcessFrame(from: view)
        }
    }
    
    // MARK: - Frame Capture and Processing
    
    private func captureAndProcessFrame(from view: UIView) {
        // Create pixel buffer from view
        guard let pixelBuffer = createPixelBuffer(from: view) else { return }
        
        // Create sample buffer from pixel buffer
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else { return }
        
        // Enqueue to display layer
        enqueueSampleBuffer(sampleBuffer)
    }
    
    private func createPixelBuffer(from view: UIView) -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
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
        
        // Render view into context
        DispatchQueue.main.sync {
            UIGraphicsPushContext(context)
            view.layer.render(in: context)
            UIGraphicsPopContext()
        }
        
        return buffer
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        guard let formatDescription = formatDescription else { return nil }
        
        // Calculate presentation time
        let presentationTime = CMTime(
            value: frameCount,
            timescale: CMTimeScale(frameRate)
        )
        frameCount += 1
        
        // Create timing info
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status == noErr, let buffer = sampleBuffer else { return nil }
        
        // Set display immediately attachment
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        
        return buffer
    }
    
    private func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }
    
    // MARK: - PiP Controller Setup
    
    @available(iOS 15.0, *)
    private func setupModernPiPController() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        configurePiPController()
    }
    
    private func setupLegacyPiPController() {
        // Legacy implementation for iOS 14 and below
        print("Legacy PiP setup not implemented")
    }
    
    private func configurePiPController() {
        pipController?.delegate = self
        
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
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
        
        pipController?.startPictureInPicture()
    }
    
    func stopPiP() {
        guard isPiPActive else { return }
        pipController?.stopPictureInPicture()
    }
    
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // MARK: - Frame Extraction Control
    
    private func startFrameExtraction() {
        displayLink?.isPaused = false
        frameCount = 0
        print("Frame extraction started")
    }
    
    private func stopFrameExtraction() {
        displayLink?.isPaused = true
        displayLink?.invalidate()
        displayLink = nil
        print("Frame extraction stopped")
    }
    
    // MARK: - Cleanup
    
    private func cleanupPiP() {
        stopFrameExtraction()
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flushAndRemoveImage()
        sampleBufferDisplayLayer = nil
        
        pixelBufferPool = nil
        formatDescription = nil
        timebase = nil
        
        cancellables.removeAll()
        
        print("PiP cleanup completed")
    }
    
    deinit {
        cleanupPiP()
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP will start")
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
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start PiP: \(error.localizedDescription)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            vlcPlayer?.play()
            startFrameExtraction()
        } else {
            vlcPlayer?.pause()
            stopFrameExtraction()
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // For live streams, return infinite time range
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(vlcPlayer?.isPlaying ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
        
        // Update pixel buffer pool if needed
        if newRenderSize.width > 0 && newRenderSize.height > 0 {
            updatePixelBufferPool(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // Skip not supported for live streams
        completionHandler()
    }
}

// MARK: - Pixel Buffer Pool Update
extension PictureInPictureManager {
    
    private func updatePixelBufferPool(width: Int, height: Int) {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        self.pixelBufferPool = pool
        
        // Update format description
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        self.formatDescription = formatDesc
        
        print("Pixel buffer pool updated: \(width)x\(height)")
    }
}

// MARK: - VLC Direct Frame Access Extension
extension PictureInPictureManager {
    
    /// Alternative method using VLC's snapshot capability
    func captureVLCFrameAsPixelBuffer() -> CVPixelBuffer? {
        guard let vlcPlayer = vlcPlayer,
              vlcPlayer.isPlaying,
              let pool = pixelBufferPool else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        
        guard let buffer = pixelBuffer else { return nil }
        
        // This is where we'd ideally access VLC's raw frame data
        // Since VLCKit doesn't expose this directly, we use the view rendering approach
        
        return buffer
    }
    
    /// Setup for direct VLC frame callback (if VLCKit supports it in future)
    func setupDirectVLCFrameCallback() {
        // Future implementation when VLCKit exposes frame callbacks
        // vlcPlayer?.setVideoCallback({ pixelBuffer in
        //     self.processDirectVLCFrame(pixelBuffer)
        // })
    }
}
