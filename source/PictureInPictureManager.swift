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

// MARK: - RTSP Sample Buffer PiP Manager
class PictureInPictureManager: NSObject, ObservableObject {
    
    // Singleton
    static let shared = PictureInPictureManager()
    
    // Published Properties
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    
    // PiP Controllers
    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    
    // RTSP Stream Processing
    private var rtspSampleBufferExtractor: RTSPSampleBufferExtractor?
    private var vlcPlayer: VLCMediaPlayer?
    
    // Video Format
    private var formatDescription: CMVideoFormatDescription?
    private var lastPresentationTime = CMTime.zero
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Processing queues
    private let sampleBufferQueue = DispatchQueue(label: "com.rtspplayer.samplebuffer", qos: .userInteractive)
    private let displayQueue = DispatchQueue(label: "com.rtspplayer.display", qos: .userInteractive)
    
    override init() {
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
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            print("Audio session configured for PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - RTSP Sample Buffer Setup
    
    func setupPiPForRTSPStream(vlcPlayer: VLCMediaPlayer, streamURL: String) {
        cleanupPiPController()
        
        self.vlcPlayer = vlcPlayer
        
        // Create sample buffer display layer
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("Failed to create sample buffer display layer")
            return
        }
        
        // Configure display layer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        
        // Setup timebase
        setupTimebase(for: displayLayer)
        
        // Initialize RTSP sample buffer extractor
        rtspSampleBufferExtractor = RTSPSampleBufferExtractor(vlcPlayer: vlcPlayer)
        rtspSampleBufferExtractor?.delegate = self
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupSampleBufferPiPController(with: displayLayer)
        } else {
            setupLegacyPiPController(with: displayLayer)
        }
        
        // Start extraction
        rtspSampleBufferExtractor?.startExtraction()
        
        print("PiP setup completed for RTSP stream")
    }
    
    private func setupTimebase(for layer: AVSampleBufferDisplayLayer) {
        var timebase: CMTimebase?
        let result = CMTimebaseCreateWithMasterClock(
            allocator: kCFAllocatorDefault,
            masterClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        
        if result == noErr, let timebase = timebase {
            layer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: CMTime.zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            print("Timebase configured successfully")
        }
    }
    
    @available(iOS 15.0, *)
    private func setupSampleBufferPiPController(with layer: AVSampleBufferDisplayLayer) {
        pipController = AVPictureInPictureController(contentSource:
            AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: self
            )
        )
        
        configurePiPController()
    }
    
    private func setupLegacyPiPController(with layer: AVSampleBufferDisplayLayer) {
        // iOS 14 and below - use alternative approach
        print("Legacy PiP setup for iOS 14 and below")
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
            }
            .store(in: &cancellables)
        
        pipController.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isPiPActive = isActive
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Sample Buffer Processing
    
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        displayQueue.async { [weak self] in
            guard self != nil else { return }
            
            // Check if layer is ready
            if displayLayer.status == .failed {
                print("Display layer failed")
                displayLayer.flush()
            }
            
            // Enqueue sample buffer
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
                
                // Update format description if needed
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    self?.formatDescription = formatDesc
                }
            } else {
                // Drop frame if not ready
                print("Display layer not ready, dropping frame")
            }
        }
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
    
    // MARK: - Cleanup
    
    private func cleanupPiPController() {
        rtspSampleBufferExtractor?.stopExtraction()
        rtspSampleBufferExtractor = nil
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flush()
        sampleBufferDisplayLayer = nil
        
        formatDescription = nil
        lastPresentationTime = .zero
        
        cancellables.removeAll()
    }
    
    deinit {
        cleanupPiPController()
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start PiP: \(error.localizedDescription)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Sample Buffer Playback Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            vlcPlayer?.play()
            rtspSampleBufferExtractor?.resumeExtraction()
        } else {
            vlcPlayer?.pause()
            rtspSampleBufferExtractor?.pauseExtraction()
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // For live RTSP streams, return infinite time range
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(vlcPlayer?.isPlaying ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // Skip not supported for live streams
        completionHandler()
    }
}

// MARK: - RTSP Sample Buffer Extractor
class RTSPSampleBufferExtractor: NSObject {
    private weak var vlcPlayer: VLCMediaPlayer?
    private var isExtracting = false
    private var isPaused = false
    
    weak var delegate: RTSPSampleBufferDelegate?
    
    // Video processing
    private var videoDecompressionSession: VTDecompressionSession?
    private var videoFormatDescription: CMVideoFormatDescription?
    
    // Buffer pool for efficiency
    private var pixelBufferPool: CVPixelBufferPool?
    private let bufferQueue = DispatchQueue(label: "com.rtspplayer.buffer", qos: .userInteractive)
    
    // Timing
    private var frameNumber: Int64 = 0
    private let frameRate: Double = 30.0
    
    init(vlcPlayer: VLCMediaPlayer) {
        self.vlcPlayer = vlcPlayer
        super.init()
        setupVideoProcessing()
    }
    
    // MARK: - Setup
    
    private func setupVideoProcessing() {
        // Setup VLC video callbacks
        setupVLCVideoCallbacks()
        
        // Create pixel buffer pool
        createPixelBufferPool()
    }
    
    private func setupVLCVideoCallbacks() {
        guard let player = vlcPlayer else { return }
        
        // Configure VLC to provide video frames
        // This is where we'd set up the actual VLC video output callbacks
        // In a real implementation, this would involve:
        // 1. Setting up libvlc_video_set_callbacks
        // 2. Configuring the video format
        // 3. Handling the frame data in callbacks
        
        // For now, we'll use a bridging approach
        configureVLCVideoOutput(player)
    }
    
    private func configureVLCVideoOutput(_ player: VLCMediaPlayer) {
        // Set video output format to I420 for efficient processing
        // This would typically be done through VLC's internal APIs
        print("Configuring VLC video output for RTSP sample buffer extraction")
        
        // Start with a timer-based approach for frame extraction
        startFrameExtractionTimer()
    }
    
    private func createPixelBufferPool() {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 5]
        
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pixelBufferPool
        )
    }
    
    // MARK: - Extraction Control
    
    func startExtraction() {
        guard !isExtracting else { return }
        isExtracting = true
        isPaused = false
        frameNumber = 0
        print("Started RTSP sample buffer extraction")
    }
    
    func stopExtraction() {
        isExtracting = false
        isPaused = false
        print("Stopped RTSP sample buffer extraction")
    }
    
    func pauseExtraction() {
        isPaused = true
    }
    
    func resumeExtraction() {
        isPaused = false
    }
    
    // MARK: - Frame Extraction
    
    private func startFrameExtractionTimer() {
        bufferQueue.async { [weak self] in
            while self?.isExtracting == true {
                if !(self?.isPaused ?? true) {
                    self?.extractCurrentFrame()
                }
                // 30 FPS timing
                usleep(33333)
            }
        }
    }
    
    private func extractCurrentFrame() {
        guard let vlcPlayer = vlcPlayer,
              vlcPlayer.isPlaying,
              let drawable = vlcPlayer.drawable as? UIView else {
            return
        }
        
        // Extract frame from VLC drawable
        DispatchQueue.main.async { [weak self] in
            self?.processDrawableView(drawable)
        }
    }
    
    private func processDrawableView(_ view: UIView) {
        // Create sample buffer from view
        guard let pixelBuffer = createPixelBuffer(from: view) else { return }
        
        // Create CMSampleBuffer
        if let sampleBuffer = createSampleBuffer(from: pixelBuffer) {
            delegate?.didExtractSampleBuffer(sampleBuffer)
        }
        
        frameNumber += 1
    }
    
    // MARK: - Buffer Creation
    
    private func createPixelBuffer(from view: UIView) -> CVPixelBuffer? {
        let width = Int(view.bounds.width * UIScreen.main.scale)
        let height = Int(view.bounds.height * UIScreen.main.scale)
        
        // Get pixel buffer from pool
        var pixelBuffer: CVPixelBuffer?
        
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        } else {
            // Create pixel buffer without pool
            let attrs = [
                kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ] as CFDictionary
            
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32ARGB,
                attrs,
                &pixelBuffer
            )
        }
        
        guard let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: UIScreen.main.scale, y: -UIScreen.main.scale)
        
        UIGraphicsPushContext(context)
        view.layer.render(in: context)
        UIGraphicsPopContext()
        
        return buffer
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        // Create or update format description
        if videoFormatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &videoFormatDescription
            )
        }
        
        guard let formatDesc = videoFormatDescription else { return nil }
        
        // Calculate presentation time
        let presentationTime = CMTime(
            value: CMTimeValue(frameNumber),
            timescale: CMTimeScale(frameRate)
        )
        
        // Create timing info
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: 1.0/frameRate, preferredTimescale: 600),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status == noErr, let buffer = sampleBuffer else {
            print("Failed to create sample buffer: \(status)")
            return nil
        }
        
        // Set display immediately attachment for live streaming
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
    
    deinit {
        stopExtraction()
        videoDecompressionSession = nil
        pixelBufferPool = nil
    }
}

// MARK: - RTSP Sample Buffer Delegate
protocol RTSPSampleBufferDelegate: AnyObject {
    func didExtractSampleBuffer(_ sampleBuffer: CMSampleBuffer)
}

extension PictureInPictureManager: RTSPSampleBufferDelegate {
    func didExtractSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        processSampleBuffer(sampleBuffer)
    }
}

// MARK: - VLC Video Callback Bridge (Advanced Implementation)
extension RTSPSampleBufferExtractor {
    
    // This would be the actual implementation using VLC's video callbacks
    // In a production app, you'd need to bridge to VLC's C API
    
    func setupAdvancedVideoCallbacks() {
        // Example of what the actual implementation would look like:
        /*
        guard let player = vlcPlayer else { return }
        
        // Set up video format callback
        libvlc_video_set_format_callbacks(
            player.media?.mediaPlayer,
            videoFormatCallback,
            videoCleanupCallback
        )
        
        // Set up video display callback
        libvlc_video_set_callbacks(
            player.media?.mediaPlayer,
            videoLockCallback,
            videoUnlockCallback,
            videoDisplayCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        */
    }
    
    // These would be the actual callback functions
    /*
    private let videoLockCallback: libvlc_video_lock_cb = { opaque, planes in
        // Lock and provide buffer for VLC to decode into
    }
    
    private let videoUnlockCallback: libvlc_video_unlock_cb = { opaque, picture, planes in
        // Unlock buffer after VLC has decoded frame
    }
    
    private let videoDisplayCallback: libvlc_video_display_cb = { opaque, picture in
        // Process the decoded frame and create CMSampleBuffer
    }
    */
}

// MARK: - H.264/H.265 NAL Unit Parser (For Direct Stream Processing)
class NALUnitParser {
    
    enum NALUnitType: UInt8 {
        // H.264
        case h264SPS = 7
        case h264PPS = 8
        case h264IDR = 5
        case h264NonIDR = 1
        
        // H.265
        case h265VPS = 32
        case h265SPS = 33
        case h265PPS = 34
        case h265IDR_W_RADL = 19
        case h265IDR_N_LP = 20
    }
    
    static func parseNALUnits(from data: Data) -> [(type: NALUnitType, data: Data)] {
        var nalUnits: [(type: NALUnitType, data: Data)] = []
        
        // Find NAL unit start codes (0x00 0x00 0x00 0x01)
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var currentIndex = 0
        
        while currentIndex < data.count - 4 {
            // Check for start code
            if data[currentIndex..<currentIndex+4].elementsEqual(startCode) {
                // Found NAL unit
                let nalStart = currentIndex + 4
                
                // Find next start code
                var nalEnd = data.count
                for i in (nalStart + 4)..<data.count - 3 {
                    if data[i..<i+4].elementsEqual(startCode) {
                        nalEnd = i
                        break
                    }
                }
                
                // Extract NAL unit
                let nalData = data[nalStart..<nalEnd]
                if !nalData.isEmpty {
                    let nalType = nalData[0] & 0x1F // H.264 NAL type
                    if let type = NALUnitType(rawValue: nalType) {
                        nalUnits.append((type: type, data: Data(nalData)))
                    }
                }
                
                currentIndex = nalEnd
            } else {
                currentIndex += 1
            }
        }
        
        return nalUnits
    }
    
    static func createFormatDescription(sps: Data, pps: Data, vps: Data? = nil) -> CMVideoFormatDescription? {
        var formatDescription: CMFormatDescription?
        
        if let vps = vps {
            // H.265
            let parameterSetPointers: [UnsafePointer<UInt8>] = [
                vps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
                sps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
                pps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
            ]
            let parameterSetSizes: [Int] = [vps.count, sps.count, pps.count]
            
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 3,
                parameterSetPointers: parameterSetPointers,
                parameterSetSizes: parameterSetSizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        } else {
            // H.264
            let parameterSetPointers: [UnsafePointer<UInt8>] = [
                sps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
                pps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
            ]
            let parameterSetSizes: [Int] = [sps.count, pps.count]
            
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 2,
                parameterSetPointers: parameterSetPointers,
                parameterSetSizes: parameterSetSizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &formatDescription
            )
        }
        
        return formatDescription
    }
}
