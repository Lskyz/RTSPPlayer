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

// MARK: - Enhanced PiP Manager with Direct VLC Frame Processing
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
    
    // Frame Processing - Direct from VLC
    private let frameProcessingQueue = DispatchQueue(label: "com.rtspplayer.direct.frame.processing", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.rtspplayer.direct.render", qos: .userInteractive)
    
    // Timing with Host Clock
    private var timebase: CMTimebase?
    private var lastPresentationTime = CMTime.zero
    private let frameDuration = CMTime(value: 1, timescale: 30) // 30 FPS
    
    // Frame tracking for direct processing
    private var frameCount = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var firstFrameReceived = false
    private var isReceivingDirectFrames = false
    
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
    
    // MARK: - Direct VLC Frame Processing Setup
    
    func connectToVLCPlayerDirect(_ vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        cleanup()
        
        self.vlcPlayer = vlcPlayer
        self.containerView = containerView
        
        // Create display layer and view for direct frame processing
        setupDisplayLayerForDirectFrames(in: containerView)
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        // Mark as ready for direct frame processing
        isReceivingDirectFrames = true
        
        print("Connected to VLC player for direct frame processing")
    }
    
    private func setupDisplayLayerForDirectFrames(in containerView: UIView) {
        // Create sample buffer display layer for direct frame processing
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("Failed to create sample buffer display layer for direct frames")
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
        
        // CRITICAL: Keep layer visible but transparent for system PiP
        displayLayerView?.isHidden = false
        displayLayerView?.alpha = 0.01 // Almost invisible but detectable by system
        
        // Add to container
        containerView.addSubview(displayLayerView!)
        
        // Setup timebase with Host Clock for direct frame sync
        setupTimebaseWithHostClockForDirectFrames()
        
        print("Display layer configured for direct VLC frame processing")
    }
    
    private func setupTimebaseWithHostClockForDirectFrames() {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        // Create timebase with Host Clock for direct frame sync
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), // Host Clock for precise timing
            timebaseOut: &timebase
        )
        
        if status == noErr, let tb = timebase {
            self.timebase = tb
            displayLayer.controlTimebase = tb
            
            // Set initial time and rate for direct processing
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            
            print("Timebase configured with Host Clock for direct VLC frames")
        } else {
            print("Failed to create timebase for direct frames: \(status)")
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
        
        print("Modern PiP controller configured for direct VLC frames (iOS 15+)")
    }
    
    private func setupLegacyPiPController() {
        print("Legacy PiP not fully supported for direct frame processing")
    }
    
    private func configurePiPController() {
        guard let pipController = pipController else { return }
        
        pipController.delegate = self
        
        // CRITICAL: Enable automatic PiP transition for direct frames
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
                print("Direct Frame PiP Possible: \(isPossible)")
            }
            .store(in: &cancellables)
        
        pipController.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isPiPActive = isActive
                print("Direct Frame PiP Active: \(isActive)")
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Direct Frame Processing - Called from VLC callbacks
    
    func receivedDirectFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isReceivingDirectFrames else { return }
        
        renderQueue.async { [weak self] in
            self?.processDirectFrame(sampleBuffer)
        }
    }
    
    private func processDirectFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        frameCount += 1
        
        // Mark first frame received for PiP readiness
        if !firstFrameReceived {
            firstFrameReceived = true
            DispatchQueue.main.async { [weak self] in
                print("First direct frame received from VLC - System PiP ready")
                self?.checkPiPReadiness()
            }
        }
        
        // Check if layer is ready for direct frame processing
        guard displayLayer.status != .failed else {
            print("Display layer failed for direct frames, resetting...")
            displayLayer.flush()
            return
        }
        
        // Enqueue direct sample buffer from VLC
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            
            // Update presentation time for direct frames
            lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            // Log direct frame rate occasionally
            let currentTime = CACurrentMediaTime()
            if frameCount % 60 == 0 {
                let fps = 60.0 / (currentTime - lastFrameTime)
                print("Direct VLC Frame rate: \(String(format: "%.1f", fps)) FPS")
                lastFrameTime = currentTime
            }
        } else {
            if displayLayer.status == .failed {
                print("Display layer not ready for direct frames, flushing...")
                displayLayer.flush()
            }
        }
    }
    
    private func checkPiPReadiness() {
        // Check if all conditions are met for PiP
        guard isPiPSupported,
              firstFrameReceived,
              vlcPlayer?.isPlaying == true,
              sampleBufferDisplayLayer?.isReadyForMoreMediaData == true else {
            print("PiP not ready yet - checking conditions...")
            return
        }
        
        // Wait a bit more for stabilization then mark as possible
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isPiPPossible = true
            print("System PiP ready for direct VLC frames")
        }
    }
    
    // MARK: - Public Methods
    
    func startPiP() {
        guard isPiPSupported, isPiPPossible else {
            print("Direct Frame PiP not available - Supported: \(isPiPSupported), Possible: \(isPiPPossible)")
            return
        }
        
        guard firstFrameReceived else {
            print("Waiting for first direct frame from VLC...")
            // Try again after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startPiP()
            }
            return
        }
        
        // Reset tracking for new PiP session
        frameCount = 0
        lastFrameTime = CACurrentMediaTime()
        
        print("Starting System PiP with direct VLC frames")
        pipController?.startPictureInPicture()
    }
    
    func stopPiP() {
        guard isPiPActive else { return }
        
        print("Stopping System PiP with direct frames")
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
    
    private func cleanup() {
        isReceivingDirectFrames = false
        
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
        frameCount = 0
        
        cancellables.removeAll()
        
        print("Direct frame processing cleanup completed")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Integration Helper Properties
    
    var canStartPiP: Bool {
        let canStart = isPiPSupported && 
                      isPiPPossible && 
                      !isPiPActive && 
                      (vlcPlayer?.isPlaying ?? false) && 
                      firstFrameReceived
        
        print("Can start Direct Frame PiP: \(canStart) (Supported: \(isPiPSupported), Possible: \(isPiPPossible), Active: \(isPiPActive), Playing: \(vlcPlayer?.isPlaying ?? false), FirstFrame: \(firstFrameReceived))")
        return canStart
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "System PiP Active (Direct Frames)"
        } else if isPiPPossible && firstFrameReceived {
            return "Ready for System PiP (Direct Frames)"
        } else if vlcPlayer?.isPlaying ?? false {
            return "Processing Direct VLC Frames"
        } else {
            return "Inactive"
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate for Direct Frames
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP will start with direct VLC frames")
        
        // Ensure direct frame processing is active
        isReceivingDirectFrames = true
        
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP started successfully with direct VLC frames!")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP will stop (direct frames)")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("System PiP stopped (direct frames)")
        isPiPActive = false
        
        // Keep receiving frames for potential restart
        // Don't stop direct frame processing here
        
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start System PiP with direct frames: \(error.localizedDescription)")
        
        // Try to diagnose the issue
        print("Diagnosis - FirstFrame: \(firstFrameReceived), DisplayLayerReady: \(sampleBufferDisplayLayer?.isReadyForMoreMediaData ?? false), VLCPlaying: \(vlcPlayer?.isPlaying ?? false)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for System PiP (direct frames)")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Sample Buffer Playback Delegate for Direct Frames
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   setPlaying playing: Bool) {
        print("System PiP setPlaying: \(playing) with direct frames")
        
        if playing {
            vlcPlayer?.play()
            isReceivingDirectFrames = true
        } else {
            vlcPlayer?.pause()
            // Keep receiving frames even when paused for quick resume
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Live stream - infinite duration
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        let isPaused = !(vlcPlayer?.isPlaying ?? false)
        print("System PiP isPlaybackPaused: \(isPaused)")
        return isPaused
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("System PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height) (direct frames)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        print("Skip not supported for live RTSP stream (direct frames)")
        completionHandler()
    }
}
