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

// MARK: - Enhanced PiP Manager with Independent Player
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
    
    // VLC Components - 독립적인 PiP용 플레이어
    private var mainVLCPlayer: VLCMediaPlayer?  // 메인 플레이어 참조용
    private var pipVLCPlayer: VLCMediaPlayer?   // PiP 전용 플레이어
    private var frameExtractor: VLCFrameExtractor?
    private var containerView: UIView?
    
    // 스트림 정보 저장
    private var currentStreamURL: String?
    private var streamUsername: String?
    private var streamPassword: String?
    private var networkCaching: Int = 150
    
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
    
    // Frame counter for debugging
    private var frameCount = 0
    private var lastFrameTime = CACurrentMediaTime()
    
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
    
    // MARK: - 독립적인 PiP 설정
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer, containerView: UIView) {
        cleanup()
        
        self.mainVLCPlayer = vlcPlayer
        self.containerView = containerView
        
        // 현재 스트림 정보 저장
        if let media = vlcPlayer.media {
            self.currentStreamURL = media.url?.absoluteString
            // 추가 스트림 정보가 필요하면 여기서 추출
        }
        
        // Create display layer and view
        setupDisplayLayer(in: containerView)
        
        // Setup PiP controller
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        print("PiP Manager connected to main VLC player")
    }
    
    // 스트림 정보 설정 메소드 추가
    func setStreamInfo(url: String, username: String? = nil, password: String? = nil, caching: Int = 150) {
        self.currentStreamURL = url
        self.streamUsername = username
        self.streamPassword = password
        self.networkCaching = caching
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
        
        // Create container view for the layer - 숨겨진 상태로 시작
        displayLayerView = UIView(frame: containerView.bounds)
        displayLayerView?.backgroundColor = .clear
        displayLayerView?.layer.addSublayer(displayLayer)
        displayLayerView?.isHidden = true // PiP 비활성 시 숨김
        
        // Add to container
        containerView.addSubview(displayLayerView!)
        
        // Setup timebase
        setupTimebase()
        
        print("Display layer configured with bounds: \(containerView.bounds)")
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
    
    // MARK: - PiP용 독립 플레이어 생성
    
    private func createPiPPlayer() {
        guard let streamURL = currentStreamURL else {
            print("No stream URL available for PiP")
            return
        }
        
        // PiP 전용 VLC 플레이어 생성
        pipVLCPlayer = VLCMediaPlayer()
        
        // 숨겨진 뷰에 연결 (오디오만 필요)
        let hiddenView = UIView(frame: CGRect.zero)
        pipVLCPlayer?.drawable = hiddenView
        
        // 오디오 설정
        pipVLCPlayer?.audio?.volume = 0 // PiP는 비디오만, 오디오는 메인에서
        
        // 미디어 설정
        let authenticatedURL = buildAuthenticatedURL(url: streamURL, username: streamUsername, password: streamPassword)
        guard let mediaURL = URL(string: authenticatedURL) else {
            print("Invalid PiP URL: \(authenticatedURL)")
            return
        }
        
        let media = VLCMedia(url: mediaURL)
        applyStreamOptimizations(to: media, caching: networkCaching)
        
        pipVLCPlayer?.media = media
        
        print("PiP player created with independent stream")
    }
    
    private func buildAuthenticatedURL(url: String, username: String?, password: String?) -> String {
        guard let username = username, let password = password else { return url }
        
        if let urlComponents = URLComponents(string: url) {
            let components = urlComponents
            var urlString = "\(components.scheme ?? "rtsp")://"
            urlString += "\(username):\(password)@"
            urlString += "\(components.host ?? "")"
            if let port = components.port {
                urlString += ":\(port)"
            }
            urlString += components.path
            return urlString
        }
        
        return url
    }
    
    private func applyStreamOptimizations(to media: VLCMedia, caching: Int) {
        let lowLatencyOptions: [String: String] = [
            "network-caching": "\(caching)",
            "rtsp-caching": "\(caching)",
            "tcp-caching": "\(caching)",
            "realrtsp-caching": "\(caching)",
            "clock-jitter": "\(caching)",
            "rtsp-tcp": "",
            "avcodec-hw": "videotoolbox",
            "clock-synchro": "0",
            "avcodec-skiploopfilter": "0",
            "avcodec-skip-frame": "0",
            "avcodec-skip-idct": "0",
            "avcodec-threads": "4",
            "sout-mux-caching": "10",
            "live-caching": "\(caching)"
        ]
        
        // Apply all options
        for (key, value) in lowLatencyOptions {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional codec optimizations
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        media.addOption("--no-drop-late-frames")
        media.addOption("--no-skip-frames")
        media.addOption("--video-filter=")
        media.addOption("--deinterlace=0")
    }
    
    // MARK: - Public Methods
    
    func startPiP() {
        guard isPiPSupported, isPiPPossible else {
            print("PiP not available - Supported: \(isPiPSupported), Possible: \(isPiPPossible)")
            return
        }
        
        print("Starting PiP with independent player...")
        
        // 1. PiP용 독립 플레이어 생성 및 시작
        createPiPPlayer()
        
        // 2. 메인 플레이어의 drawable 해제 (중요!)
        DispatchQueue.main.async { [weak self] in
            self?.mainVLCPlayer?.drawable = nil
            print("Main player drawable disconnected for PiP")
        }
        
        // 3. PiP 플레이어 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pipVLCPlayer?.play()
            
            // 4. 프레임 추출 시작
            self?.setupFrameExtractor()
            
            // 5. PiP UI 시작
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.pipController?.startPictureInPicture()
                print("PiP UI started")
            }
        }
    }
    
    private func setupFrameExtractor() {
        guard let pipPlayer = pipVLCPlayer else { return }
        
        frameExtractor = VLCFrameExtractor(vlcPlayer: pipPlayer, containerView: UIView()) // 더미 뷰
        frameExtractor?.delegate = self
        
        // Reset frame counter
        frameCount = 0
        lastFrameTime = CACurrentMediaTime()
        
        frameExtractor?.startExtraction()
        print("Frame extractor started for PiP player")
    }
    
    func stopPiP() {
        guard isPiPActive else { return }
        
        print("Stopping PiP...")
        
        // 1. 프레임 추출 중지
        frameExtractor?.stopExtraction()
        frameExtractor = nil
        
        // 2. PiP 플레이어 정지
        pipVLCPlayer?.stop()
        pipVLCPlayer = nil
        
        // 3. PiP UI 중지
        pipController?.stopPictureInPicture()
        
        // 4. 메인 플레이어의 drawable 복원
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let containerView = self?.containerView {
                self?.mainVLCPlayer?.drawable = containerView
                print("Main player drawable restored")
            }
        }
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
        
        pipVLCPlayer?.stop()
        pipVLCPlayer = nil
        
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
    
    // MARK: - Integration Helper Properties
    
    var canStartPiP: Bool {
        let hasStream = currentStreamURL != nil
        let canStart = isPiPSupported && isPiPPossible && !isPiPActive && hasStream
        print("Can start PiP: \(canStart) (Supported: \(isPiPSupported), Possible: \(isPiPPossible), Active: \(isPiPActive), HasStream: \(hasStream))")
        return canStart
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "Active (Independent)"
        } else if isPiPPossible {
            return "Ready"
        } else if currentStreamURL != nil {
            return "Preparing"
        } else {
            return "No Stream"
        }
    }
}

// MARK: - 개선된 VLC Frame Extractor
class VLCFrameExtractor: NSObject {
    weak var vlcPlayer: VLCMediaPlayer?
    weak var delegate: VLCFrameExtractionDelegate?
    
    var isExtracting = false
    private var extractionTimer: Timer?
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
        
        // Use faster extraction method with snapshots
        startSnapshotBasedExtraction()
        
        print("Frame extraction started")
    }
    
    func stopExtraction() {
        isExtracting = false
        extractionTimer?.invalidate()
        extractionTimer = nil
        
        print("Frame extraction stopped")
    }
    
    private func startSnapshotBasedExtraction() {
        // Use 30 FPS for smooth PiP
        extractionTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.extractFrameViaSnapshot()
        }
    }
    
    private func extractFrameViaSnapshot() {
        guard let player = vlcPlayer,
              player.isPlaying else { return }
        
        extractionQueue.async { [weak self] in
            self?.captureFrameFromVLCSnapshot()
        }
    }
    
    private func captureFrameFromVLCSnapshot() {
        guard let player = vlcPlayer else { return }
        
        snapshotCounter += 1
        let snapshotPath = "\(documentsPath)vlc_frame_\(snapshotCounter).png"
        
        // Use the corrected method name
        player.saveVideoSnapshot(at: snapshotPath, withWidth: 1920, andHeight: 1080)
        
        // Wait a bit for file to be written
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.processSnapshotFile(at: snapshotPath)
        }
    }
    
    private func processSnapshotFile(at path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let image = UIImage(contentsOfFile: path) else {
            return
        }
        
        // Convert UIImage to CVPixelBuffer
        if let pixelBuffer = imageToPixelBuffer(image) {
            processPixelBuffer(pixelBuffer)
        }
        
        // Clean up snapshot file
        try? FileManager.default.removeItem(atPath: path)
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
    
    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer) else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didExtractFrame(sampleBuffer)
        }
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
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
        
        let now = CACurrentMediaTime()
        let presentationTime = CMTime(seconds: now, preferredTimescale: 1000000000)
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
                print("PiP Frame rate: \(String(format: "%.1f", fps)) FPS")
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
        print("PiP will start")
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP did start - Independent mode active")
        isPiPActive = true
        
        // 메인 플레이어는 백그라운드에서 오디오만 유지
        DispatchQueue.main.async { [weak self] in
            self?.mainVLCPlayer?.audio?.volume = 100  // 오디오는 메인에서
        }
        
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP did stop - Restoring main player")
        isPiPActive = false
        
        // PiP 리소스 정리
        frameExtractor?.stopExtraction()
        pipVLCPlayer?.stop()
        pipVLCPlayer = nil
        
        // 메인 플레이어의 drawable 복원
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let containerView = self?.containerView {
                self?.mainVLCPlayer?.drawable = containerView
                print("Main player drawable fully restored")
            }
        }
        
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start PiP: \(error.localizedDescription)")
        
        // 실패 시 복원
        DispatchQueue.main.async { [weak self] in
            if let containerView = self?.containerView {
                self?.mainVLCPlayer?.drawable = containerView
            }
        }
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
            pipVLCPlayer?.play()
            frameExtractor?.startExtraction()
        } else {
            pipVLCPlayer?.pause()
            frameExtractor?.stopExtraction()
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(pipVLCPlayer?.isPlaying ?? false)
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
