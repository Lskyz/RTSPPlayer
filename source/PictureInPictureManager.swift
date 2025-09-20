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

// MARK: - Enhanced PiP Manager with Direct VLC Stream Processing
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
    private var vlcVideoOutput: VLCVideoOutput?
    private var containerView: UIView?
    
    // Direct Video Processing
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Processing Queues
    private let videoProcessingQueue = DispatchQueue(label: "com.rtspplayer.video.processing", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.rtspplayer.render", qos: .userInteractive)
    
    // Timing Management
    private var timebase: CMTimebase?
    private var frameCount: Int64 = 0
    private var startTime: CMTime = .zero
    private let targetFrameRate: Int32 = 30
    
    // Video Properties
    private var videoWidth: Int = 1920
    private var videoHeight: Int = 1080
    private var firstFrameReceived = false
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
        setupPixelBufferPool()
    }
    
    // MARK: - Setup
    
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("PiP Support: \(isPiPSupported)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlaybook, options: [.mixWithOthers, .allowAirPlay])
            try audioSession.setActive(true)
            print("Audio session configured for PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupPixelBufferPool() {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferBytesPerRowAlignmentKey as String: 16
        ]
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 5,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0
        ]
        
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        if status == kCVReturnSuccess {
            pixelBufferPool = pool
            print("Pixel buffer pool created successfully")
        } else {
            print("Failed to create pixel buffer pool: \(status)")
        }
    }
    
    // MARK: - Direct VLC Integration
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        cleanup()
        
        self.vlcPlayer = vlcPlayer
        self.containerView = containerView
        
        // Setup display layer
        setupDisplayLayer(in: containerView)
        
        // CRITICAL: Setup direct VLC video output
        setupDirectVLCVideoOutput()
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        }
        
        print("Connected to VLC with direct video output")
    }
    
    private func setupDisplayLayer(in containerView: UIView) {
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("Failed to create sample buffer display layer")
            return
        }
        
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = containerView.bounds
        
        // Create container view
        displayLayerView = UIView(frame: containerView.bounds)
        displayLayerView?.backgroundColor = .clear
        displayLayerView?.layer.addSublayer(displayLayer)
        displayLayerView?.isHidden = false
        displayLayerView?.alpha = 0.01 // Keep visible for system PiP
        
        containerView.addSubview(displayLayerView!)
        
        // Setup timebase
        setupTimebaseWithHostClock()
        
        print("Display layer configured for system PiP")
    }
    
    private func setupTimebaseWithHostClock() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        
        if status == noErr, let tb = timebase {
            self.timebase = tb
            displayLayer.controlTimebase = tb
            
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            
            startTime = CMClockGetTime(CMClockGetHostTimeClock())
            
            print("Timebase configured with Host Clock")
        }
    }
    
    private func setupDirectVLCVideoOutput() {
        guard let vlcPlayer = vlcPlayer else { return }
        
        // CRITICAL: Create custom VLC video output
        vlcVideoOutput = VLCVideoOutput()
        vlcVideoOutput?.delegate = self
        
        // Configure VLC for direct video callback
        vlcPlayer.setVideoCallbacks(
            lock: { [weak self] (opaque, planes) -> UnsafeMutableRawPointer? in
                return self?.videoLockCallback(opaque: opaque, planes: planes)
            },
            unlock: { [weak self] (opaque, picture, planes) in
                self?.videoUnlockCallback(opaque: opaque, picture: picture, planes: planes)
            },
            display: { [weak self] (opaque, picture) in
                self?.videoDisplayCallback(opaque: opaque, picture: picture)
            },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
        
        // Set video format callback
        vlcPlayer.setVideoFormatCallbacks(
            setup: { [weak self] (opaque, chroma, width, height, pitches, lines) -> UnsafeMutableRawPointer? in
                return self?.videoSetupCallback(opaque: opaque, chroma: chroma, width: width, height: height, pitches: pitches, lines: lines)
            },
            cleanup: { [weak self] (opaque) in
                self?.videoCleanupCallback(opaque: opaque)
            }
        )
        
        print("Direct VLC video output configured")
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
        
        print("Modern PiP controller configured")
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
    
    // MARK: - VLC Video Callbacks
    
    private func videoSetupCallback(opaque: UnsafeMutableRawPointer?, 
                                   chroma: UnsafeMutablePointer<vlc_fourcc_t>?, 
                                   width: UnsafeMutablePointer<UInt32>?, 
                                   height: UnsafeMutablePointer<UInt32>?, 
                                   pitches: UnsafeMutablePointer<UInt32>?, 
                                   lines: UnsafeMutablePointer<UInt32>?) -> UnsafeMutableRawPointer? {
        
        guard let width = width, let height = height else { return nil }
        
        videoWidth = Int(width.pointee)
        videoHeight = Int(height.pointee)
        
        print("Video format setup: \(videoWidth)x\(videoHeight)")
        
        // Force I420 format for better compatibility
        chroma?.pointee = VLC_CODEC_I420
        
        // Update pixel buffer pool with new dimensions
        setupPixelBufferPool()
        
        // Create format description
        createFormatDescription()
        
        return Unmanaged.passUnretained(self).toOpaque()
    }
    
    private func videoCleanupCallback(opaque: UnsafeMutableRawPointer?) {
        print("Video format cleanup")
    }
    
    private func videoLockCallback(opaque: UnsafeMutableRawPointer?, planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? {
        // Allocate frame buffer
        guard let pool = pixelBufferPool else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        
        if status == kCVReturnSuccess, let buffer = pixelBuffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            
            // Set up planes for I420 format
            if let planes = planes {
                planes[0] = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) // Y plane
                planes[1] = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) // U plane  
                planes[2] = CVPixelBufferGetBaseAddressOfPlane(buffer, 2) // V plane
            }
            
            return Unmanaged.passRetained(buffer).toOpaque()
        }
        
        return nil
    }
    
    private func videoUnlockCallback(opaque: UnsafeMutableRawPointer?, picture: UnsafeMutableRawPointer?, planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
        guard let picture = picture else { return }
        
        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(picture).takeRetainedValue()
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        
        // Process frame on background queue
        videoProcessingQueue.async { [weak self] in
            self?.processVideoFrame(pixelBuffer)
        }
    }
    
    private func videoDisplayCallback(opaque: UnsafeMutableRawPointer?, picture: UnsafeMutableRawPointer?) {
        // Frame is ready for display - handled in unlock callback
    }
    
    // MARK: - Video Frame Processing
    
    private func createFormatDescription() {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_420YpCbCr8BiPlanarVideoRange,
            width: Int32(videoWidth),
            height: Int32(videoHeight),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        if status == noErr {
            self.formatDescription = formatDescription
            print("Format description created: \(videoWidth)x\(videoHeight)")
        }
    }
    
    private func processVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let formatDesc = formatDescription else { return }
        
        // Create sample buffer with proper timing
        let currentTime = CMClockGetTime(CMClockGetHostTimeClock())
        let presentationTime = CMTimeSubtract(currentTime, startTime)
        let duration = CMTime(value: 1, timescale: targetFrameRate)
        
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        if status == noErr, let buffer = sampleBuffer {
            // Mark for immediate display
            attachDisplayAttributes(to: buffer)
            
            // Send to display layer
            renderQueue.async { [weak self] in
                self?.renderSampleBuffer(buffer)
            }
            
            frameCount += 1
            
            if !firstFrameReceived {
                firstFrameReceived = true
                print("First direct video frame received from VLC")
            }
        }
    }
    
    private func attachDisplayAttributes(to sampleBuffer: CMSampleBuffer) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachmentsArray) > 0 else { return }
        
        let attachments = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
        
        CFDictionarySetValue(
            attachments,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
        
        CFDictionarySetValue(
            attachments,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_IsDependedOnByOthers).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
        )
    }
    
    private func renderSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        if displayLayer.status == .failed {
            print("Display layer failed, flushing...")
            displayLayer.flush()
            return
        }
        
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            if frameCount % 90 == 0 {
                print("System PiP: \(frameCount) frames processed")
            }
        }
    }
    
    // MARK: - Public Interface
    
    func startPiP() {
        guard isPiPSupported, isPiPPossible else {
            print("PiP not available - Supported: \(isPiPSupported), Possible: \(isPiPPossible)")
            return
        }
        
        frameCount = 0
        firstFrameReceived = false
        startTime = CMClockGetTime(CMClockGetHostTimeClock())
        
        // Wait for first frame then start PiP
        waitForFirstFrameAndStartPiP()
    }
    
    private func waitForFirstFrameAndStartPiP() {
        let checkInterval: TimeInterval = 0.1
        let maxWaitTime: TimeInterval = 5.0
        var elapsedTime: TimeInterval = 0
        
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            elapsedTime += checkInterval
            
            if self.firstFrameReceived && (self.sampleBufferDisplayLayer?.isReadyForMoreMediaData == true) {
                timer.invalidate()
                print("First direct frame received, starting system PiP")
                self.pipController?.startPictureInPicture()
            } else if elapsedTime >= maxWaitTime {
                timer.invalidate()
                print("Timeout waiting for direct frame, starting PiP anyway")
                self.pipController?.startPictureInPicture()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + maxWaitTime + 0.1) {
            timer.invalidate()
        }
    }
    
    func stopPiP() {
        guard isPiPActive else { return }
        pipController?.stopPictureInPicture()
        print("Stopping system PiP")
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
        vlcVideoOutput = nil
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flushAndRemoveImage()
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        
        displayLayerView?.removeFromSuperview()
        displayLayerView = nil
        
        formatDescription = nil
        timebase = nil
        frameCount = 0
        firstFrameReceived = false
        
        cancellables.removeAll()
        
        print("Cleanup completed")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Properties
    
    var canStartPiP: Bool {
        let canStart = isPiPSupported && isPiPPossible && !isPiPActive && (vlcPlayer?.isPlaying ?? false)
        return canStart
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "System PiP Active (Direct Stream)"
        } else if isPiPPossible {
            return "Ready for System PiP (Direct)"
        } else if vlcPlayer?.isPlaying ?? false {
            return "Preparing Direct Stream"
        } else {
            return "Inactive"
        }
    }
}

// MARK: - VLC Video Output Helper
class VLCVideoOutput: NSObject {
    weak var delegate: VLCVideoOutputDelegate?
}

protocol VLCVideoOutputDelegate: AnyObject {
    func didReceiveVideoFrame(_ pixelBuffer: CVPixelBuffer)
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP will start (direct stream)")
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP did start - Direct stream active!")
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
        } else {
            vlcPlayer?.pause()
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
