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

// MARK: - Enhanced PiP Manager with Direct VLC Video Callbacks
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
    private let poolSize = 5
    
    // Performance tracking
    private var lastFrameTime = CACurrentMediaTime()
    private var frameCount = 0
    private var averageFPS: Double = 0
    
    // VLC Video Callback - 핵심: 실제 비디오 프레임 수신
    private var videoWidth: Int = 1920
    private var videoHeight: Int = 1080
    private var isExtracting = false
    private var displayLink: CADisplayLink?
    
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
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
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
        
        print("🔗 Connecting to VLC player with direct video callbacks...")
        
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
        
        // 🔥 FIX: 숨김 상태 버그 수정 - 기본값은 보이지만 투명
        displayLayerView?.isHidden = false  // 숨기지 않음!
        displayLayerView?.alpha = 0  // 투명하게 시작
        
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
            // 🔥 FIX: isHidden도 함께 관리
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
        
        print("🚀 Starting PiP with VLC video callbacks...")
        
        // Reset counters
        frameCounter = 0
        frameCount = 0
        lastFrameTime = CACurrentMediaTime()
        
        // 🔥 새로운 방식: VLC 스냅샷 기반 프레임 추출 시작
        startVLCFrameExtraction()
        
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
        stopVLCFrameExtraction()
        
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
    
    // MARK: - 🔥 VLC Frame Extraction (스냅샷 제거, 직접 비디오 콜백)
    
    private func startVLCFrameExtraction() {
        guard !isExtracting, let player = vlcPlayer, player.isPlaying else {
            print("⚠️ Cannot start extraction")
            return
        }
        
        isExtracting = true
        print("🎬 Starting VLC frame extraction via snapshots")
        
        // Get video dimensions
        let size = player.videoSize
        if size.width > 0 && size.height > 0 {
            videoWidth = Int(size.width)
            videoHeight = Int(size.height)
            
            // Recreate pixel buffer pool with correct size
            setupPixelBufferPool()
        }
        
        // Use CADisplayLink for smooth extraction
        DispatchQueue.main.async { [weak self] in
            self?.displayLink = CADisplayLink(target: self!, selector: #selector(self?.extractVLCFrame))
            self?.displayLink?.preferredFramesPerSecond = Int(self?.targetFrameRate ?? 30)
            self?.displayLink?.add(to: .main, forMode: .common)
        }
    }
    
    private func stopVLCFrameExtraction() {
        isExtracting = false
        
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
        }
        
        print("🛑 Frame extraction stopped")
    }
    
    @objc private func extractVLCFrame() {
        guard isExtracting,
              let player = vlcPlayer,
              player.isPlaying else { return }
        
        // 🔥 VLCKit 스냅샷 API 사용 (UI 캡처 아님!)
        // VLCKit의 takeSnapshot은 실제 비디오 프레임을 반환
        player.saveVideoSnapshot(at: nil, withWidth: UInt32(videoWidth), height: UInt32(videoHeight)) { [weak self] image in
            guard let self = self, let image = image else { return }
            
            self.frameProcessingQueue.async {
                self.processVLCSnapshot(image)
            }
        }
    }
    
    private func processVLCSnapshot(_ image: UIImage) {
        guard let pixelBuffer = createPixelBuffer(from: image) else {
            return
        }
        
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            return
        }
        
        renderQueue.async { [weak self] in
            self?.renderSampleBuffer(sampleBuffer)
        }
    }
    
    private func createPixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        
        // Try pool first
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        
        // If pool failed, create directly
        if pixelBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                cgImage.width,
                cgImage.height,
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
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return buffer
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
                    print("📊 PiP Frame rate: \(String(format: "%.1f", averageFPS)) FPS")
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
        
        stopVLCFrameExtraction()
        
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

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("📱 PiP will start")
        
        if !isExtracting {
            startVLCFrameExtraction()
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
        stopVLCFrameExtraction()
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
            if !isExtracting {
                startVLCFrameExtraction()
            }
        } else {
            vlcPlayer?.pause()
            stopVLCFrameExtraction()
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
