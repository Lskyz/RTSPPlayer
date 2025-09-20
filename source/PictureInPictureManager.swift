// MARK: - PictureInPictureManager.swift (Fixed Version)
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

// MARK: - Enhanced PiP Manager with Direct VLC Stream
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
    
    // VLC Components - CRITICAL FIX
    private var vlcPlayer: VLCMediaPlayer?
    private var containerView: UIView?
    
    // Direct Video Processing
    private var videoContext: UnsafeMutableRawPointer?
    private var currentPixelBuffer: CVPixelBuffer?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Frame Processing Queue
    private let videoQueue = DispatchQueue(label: "com.rtspplayer.video", qos: .userInteractive)
    
    // Timing
    private var timebase: CMTimebase?
    private var frameCount: Int64 = 0
    private let frameDuration = CMTime(value: 1, timescale: 30) // 30 FPS
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
    }
    
    // MARK: - Setup
    
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("System PiP Support: \(isPiPSupported)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            print("Audio session configured for System PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - CRITICAL FIX: Direct VLC Video Callback Setup
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        cleanup()
        
        self.vlcPlayer = vlcPlayer
        self.containerView = containerView
        
        // Setup display layer
        setupDisplayLayer(in: containerView)
        
        // CRITICAL: Setup direct VLC video callbacks
        setupVLCVideoCallbacks()
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        }
        
        print("VLC Player connected with direct video callbacks")
    }
    
    private func setupDisplayLayer(in containerView: UIView) {
        // Create sample buffer display layer
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = containerView.bounds
        
        // Create container view
        displayLayerView = UIView(frame: containerView.bounds)
        displayLayerView?.backgroundColor = .clear
        displayLayerView?.layer.addSublayer(displayLayer)
        displayLayerView?.isHidden = false
        displayLayerView?.alpha = 0.01 // Almost invisible but detectable by system
        
        containerView.addSubview(displayLayerView!)
        
        // Setup timebase
        setupTimebase()
        
        print("Display layer configured for System PiP")
    }
    
    private func setupTimebase() {
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
            print("Timebase configured with Host Clock")
        }
    }
    
    // MARK: - CRITICAL: Direct VLC Video Callbacks
    
    private func setupVLCVideoCallbacks() {
        guard let vlcPlayer = vlcPlayer else { return }
        
        // Create video context
        videoContext = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // Set video callbacks - CRITICAL for direct stream access
        vlc_set_video_format_callbacks(vlcPlayer, video_format_cb, nil)
        vlc_set_video_callbacks(vlcPlayer, video_lock_cb, video_unlock_cb, video_display_cb, videoContext)
        
        print("VLC video callbacks configured for direct stream access")
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
        
        print("Modern PiP controller configured with direct stream")
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
            print("PiP not available - Supported: \(isPiPSupported), Possible: \(isPiPPossible)")
            return
        }
        
        frameCount = 0
        
        // Start PiP with delay to ensure video is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pipController?.startPictureInPicture()
            print("Starting System PiP with direct VLC stream")
        }
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
    
    // MARK: - Video Processing Methods
    
    private func processVideoFrame(pixelBuffer: CVPixelBuffer) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.enqueueVideoFrame(sampleBuffer)
        }
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let format = formatDescription else { return nil }
        
        // Calculate presentation time
        let presentationTime = CMTime(value: frameCount, timescale: 30)
        frameCount += 1
        
        var timingInfo = CMSampleTimingInfo(
            duration: frameDuration,
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
        
        guard result == noErr else { return nil }
        
        // Mark for immediate display
        if let sampleBuffer = sampleBuffer,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            if CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        
        return sampleBuffer
    }
    
    private func enqueueVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        if displayLayer.status == .failed {
            displayLayer.flush()
            return
        }
        
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            if frameCount % 60 == 0 {
                print("System PiP: \(frameCount) frames processed")
            }
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        if let vlcPlayer = vlcPlayer {
            // Reset VLC video callbacks
            vlc_set_video_callbacks(vlcPlayer, nil, nil, nil, nil)
        }
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flushAndRemoveImage()
        sampleBufferDisplayLayer?.removeFromSuperlayer()
        sampleBufferDisplayLayer = nil
        
        displayLayerView?.removeFromSuperview()
        displayLayerView = nil
        
        currentPixelBuffer = nil
        videoContext = nil
        timebase = nil
        frameCount = 0
        
        cancellables.removeAll()
        
        print("PiP Manager cleanup completed")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Properties
    
    var canStartPiP: Bool {
        return isPiPSupported && isPiPPossible && !isPiPActive && (vlcPlayer?.isPlaying ?? false)
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "System PiP Active"
        } else if isPiPPossible {
            return "Ready for System PiP"
        } else {
            return "Preparing..."
        }
    }
}

// MARK: - CRITICAL: VLC Video Callback Functions

private func video_format_cb(
    _ opaque: UnsafeMutableRawPointer?,
    _ chroma: UnsafeMutablePointer<UInt32>?,
    _ width: UnsafeMutablePointer<UInt32>?,
    _ height: UnsafeMutablePointer<UInt32>?,
    _ pitches: UnsafeMutablePointer<UInt32>?,
    _ lines: UnsafeMutablePointer<UInt32>?
) -> UInt32 {
    
    // Set preferred format for iOS
    chroma?.pointee = VLC_CODEC_RGB32
    
    print("VLC Video Format: \(width?.pointee ?? 0)x\(height?.pointee ?? 0)")
    return 1 // Success
}

private func video_lock_cb(
    _ opaque: UnsafeMutableRawPointer?,
    _ planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> UnsafeMutableRawPointer? {
    
    guard let opaque = opaque else { return nil }
    
    let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
    
    // Create pixel buffer if needed
    if manager.currentPixelBuffer == nil {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080, // Default size, will be adjusted
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        manager.currentPixelBuffer = pixelBuffer
    }
    
    guard let pixelBuffer = manager.currentPixelBuffer else { return nil }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
    
    planes?.pointee = baseAddress
    
    return baseAddress
}

private func video_unlock_cb(
    _ opaque: UnsafeMutableRawPointer?,
    _ picture: UnsafeMutableRawPointer?,
    _ planes: UnsafePointer<UnsafeMutableRawPointer?>?
) {
    
    guard let opaque = opaque else { return }
    
    let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
    
    if let pixelBuffer = manager.currentPixelBuffer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
}

private func video_display_cb(
    _ opaque: UnsafeMutableRawPointer?,
    _ picture: UnsafeMutableRawPointer?
) {
    
    guard let opaque = opaque else { return }
    
    let manager = Unmanaged<PictureInPictureManager>.fromOpaque(opaque).takeUnretainedValue()
    
    if let pixelBuffer = manager.currentPixelBuffer {
        manager.processVideoFrame(pixelBuffer: pixelBuffer)
    }
}

// MARK: - VLC Constants
private let VLC_CODEC_RGB32: UInt32 = 0x20424752 // 'RGX '

// MARK: - VLC C Functions Declaration
@_silgen_name("vlc_set_video_format_callbacks")
private func vlc_set_video_format_callbacks(
    _ player: VLCMediaPlayer,
    _ setup: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt32)?,
    _ cleanup: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
)

@_silgen_name("vlc_set_video_callbacks")
private func vlc_set_video_callbacks(
    _ player: VLCMediaPlayer,
    _ lock: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?)?,
    _ unlock: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<UnsafeMutableRawPointer?>?) -> Void)?,
    _ display: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?,
    _ opaque: UnsafeMutableRawPointer?
)

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP will start with direct VLC stream")
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP started successfully with direct stream!")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP stopped")
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
        print("System PiP render size: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        print("Skip not supported for live stream")
        completionHandler()
    }
}
