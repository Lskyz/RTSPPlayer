// MARK: - Enhanced PictureInPictureManager.swift
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

// MARK: - Enhanced PiP Manager with UI-Independent Frame Supply
class PictureInPictureManager: NSObject, ObservableObject {
    
    // Singleton
    static let shared = PictureInPictureManager()
    
    // Published Properties
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    
    // PiP Components (UI Independent)
    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    private var independentDisplayLayer: AVSampleBufferDisplayLayer? // UI와 완전 분리된 레이어
    
    // VLC Components
    private var vlcPlayer: VLCMediaPlayer?
    private var frameProcessor: VLCFrameProcessor?
    
    // Background Processing
    private let backgroundQueue = DispatchQueue(label: "com.rtspplayer.background", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "com.rtspplayer.frames", qos: .userInteractive)
    private var pushTimer: DispatchSourceTimer?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Frame Management
    private var timebase: CMTimebase?
    private var lastPresentationTime = CMTime.zero
    private let frameDuration = CMTime(value: 1, timescale: 30) // 30 FPS
    
    // Background Mode Support
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
        setupBackgroundSupport()
    }
    
    // MARK: - Setup
    
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("Enhanced PiP Support: \(isPiPSupported)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            print("Audio session configured for enhanced PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupBackgroundSupport() {
        // 백그라운드 진입 시 PiP 활성 상태면 태스크 연장
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBackgroundTransition()
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleForegroundTransition()
        }
    }
    
    // MARK: - UI Independent PiP Setup
    
    func connectToVLCPlayer(_ vlcPlayer: VLCMediaPlayer) {
        cleanup(forceful: false) // PiP 활성이 아닐 때만 cleanup
        
        self.vlcPlayer = vlcPlayer
        
        // UI와 완전 독립된 디스플레이 레이어 생성
        setupIndependentDisplayLayer()
        
        // VLC 프레임 프로세서 설정
        setupFrameProcessor()
        
        // PiP 컨트롤러 설정
        if #available(iOS 15.0, *) {
            setupModernPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        // 프레임 푸시 시작 (UI와 독립적)
        startFramePushing()
        
        print("Enhanced PiP connected with UI-independent pipeline")
    }
    
    private func setupIndependentDisplayLayer() {
        // UI와 완전히 분리된 샘플 버퍼 디스플레이 레이어
        independentDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = independentDisplayLayer else {
            print("Failed to create independent display layer")
            return
        }
        
        // 레이어 설정
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        
        // 타임베이스 설정
        setupTimebase(for: displayLayer)
        
        print("Independent display layer configured")
    }
    
    private func setupTimebase(for layer: AVSampleBufferDisplayLayer) {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        
        if status == noErr, let tb = timebase {
            self.timebase = tb
            layer.controlTimebase = tb
            
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            
            print("Independent timebase configured")
        }
    }
    
    private func setupFrameProcessor() {
        guard let vlcPlayer = vlcPlayer else { return }
        
        frameProcessor = VLCFrameProcessor(vlcPlayer: vlcPlayer)
        frameProcessor?.delegate = self
        
        print("UI-independent frame processor configured")
    }
    
    @available(iOS 15.0, *)
    private func setupModernPiPController() {
        guard let displayLayer = independentDisplayLayer else { return }
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        configurePiPController()
        
        print("Modern enhanced PiP controller configured")
    }
    
    private func setupLegacyPiPController() {
        print("Legacy PiP requires iOS 15+ for sample buffer support")
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
                print("Enhanced PiP Possible: \(isPossible)")
            }
            .store(in: &cancellables)
        
        pipController.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isPiPActive = isActive
                print("Enhanced PiP Active: \(isActive)")
            }
            .store(in: &cancellables)
    }
    
    // MARK: - UI Independent Frame Pushing
    
    private func startFramePushing() {
        stopFramePushing() // 기존 타이머 정리
        
        // GCD 타이머로 UI 독립적 프레임 푸시
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5)) // 30 FPS
        
        timer.setEventHandler { [weak self] in
            self?.pushNextFrame()
        }
        
        timer.resume()
        pushTimer = timer
        
        print("UI-independent frame pushing started")
    }
    
    private func stopFramePushing() {
        pushTimer?.cancel()
        pushTimer = nil
    }
    
    private func pushNextFrame() {
        guard let processor = frameProcessor,
              let displayLayer = independentDisplayLayer,
              displayLayer.isReadyForMoreMediaData else { return }
        
        // VLC에서 독립적으로 프레임 획득
        processor.extractFrame { [weak self] sampleBuffer in
            self?.enqueueSampleBuffer(sampleBuffer)
        }
    }
    
    private func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = independentDisplayLayer,
              displayLayer.status != .failed else { return }
        
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
            lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        } else if displayLayer.status == .failed {
            print("Display layer failed, flushing...")
            displayLayer.flush()
        }
    }
    
    // MARK: - Background/Foreground Handling
    
    private func handleBackgroundTransition() {
        if isPiPActive {
            // PiP 활성 시 백그라운드 태스크 시작
            startBackgroundTask()
            print("Enhanced PiP: Maintaining stream in background")
        } else {
            print("Enhanced PiP: App backgrounded without active PiP")
        }
    }
    
    private func handleForegroundTransition() {
        endBackgroundTask()
        print("Enhanced PiP: App returned to foreground")
    }
    
    private func startBackgroundTask() {
        endBackgroundTask() // 기존 태스크 정리
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "EnhancedPiPStream") { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    // MARK: - Public Methods
    
    func startPiP() {
        guard isPiPSupported, isPiPPossible, !isPiPActive else {
            print("Enhanced PiP not available - Supported: \(isPiPSupported), Possible: \(isPiPPossible), Active: \(isPiPActive)")
            return
        }
        
        // 프레임 프로세싱 활성화
        frameProcessor?.startProcessing()
        
        // PiP 시작
        pipController?.startPictureInPicture()
        print("Starting enhanced PiP")
    }
    
    func stopPiP() {
        guard isPiPActive else { return }
        
        pipController?.stopPictureInPicture()
        print("Stopping enhanced PiP")
    }
    
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // MARK: - Cleanup (PiP 상태 고려)
    
    private func cleanup(forceful: Bool = false) {
        // PiP가 활성 상태이고 강제가 아니면 정리하지 않음
        if isPiPActive && !forceful {
            print("Enhanced PiP active - skipping cleanup")
            return
        }
        
        frameProcessor?.stopProcessing()
        frameProcessor = nil
        
        stopFramePushing()
        
        pipController?.delegate = nil
        pipController = nil
        
        independentDisplayLayer?.flushAndRemoveImage()
        independentDisplayLayer = nil
        
        timebase = nil
        lastPresentationTime = .zero
        
        endBackgroundTask()
        
        cancellables.removeAll()
        
        print("Enhanced PiP cleanup completed")
    }
    
    deinit {
        cleanup(forceful: true)
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Integration Helper Properties
    
    var canStartPiP: Bool {
        let canStart = isPiPSupported && isPiPPossible && !isPiPActive && (vlcPlayer?.isPlaying ?? false)
        return canStart
    }
    
    var pipStatus: String {
        if !isPiPSupported {
            return "Not Supported"
        } else if isPiPActive {
            return "Active (Enhanced)"
        } else if isPiPPossible {
            return "Ready (Enhanced)"
        } else if vlcPlayer?.isPlaying ?? false {
            return "Preparing (Enhanced)"
        } else {
            return "Inactive"
        }
    }
}

// MARK: - UI Independent VLC Frame Processor
class VLCFrameProcessor: NSObject {
    weak var vlcPlayer: VLCMediaPlayer?
    weak var delegate: VLCFrameProcessorDelegate?
    
    private var isProcessing = false
    private let processingQueue = DispatchQueue(label: "com.rtspplayer.processing", qos: .userInteractive)
    
    // Pixel buffer pool for efficiency
    private var pixelBufferPool: CVPixelBufferPool?
    
    // Frame generation with consistent timing
    private var frameCounter: Int64 = 0
    private let startTime = CACurrentMediaTime()
    
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
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        
        pixelBufferPool = pool
        print("Enhanced frame processor pixel buffer pool created")
    }
    
    func startProcessing() {
        isProcessing = true
        print("Enhanced frame processing started")
    }
    
    func stopProcessing() {
        isProcessing = false
        print("Enhanced frame processing stopped")
    }
    
    func extractFrame(completion: @escaping (CMSampleBuffer) -> Void) {
        guard isProcessing, let player = vlcPlayer, player.isPlaying else { return }
        
        processingQueue.async { [weak self] in
            self?.generateSyntheticFrame { sampleBuffer in
                DispatchQueue.main.async {
                    completion(sampleBuffer)
                }
            }
        }
    }
    
    // 향후 VLC 디코더 콜백으로 대체할 부분 (현재는 synthetic frame)
    private func generateSyntheticFrame(completion: @escaping (CMSampleBuffer) -> Void) {
        guard let pixelBuffer = createPixelBuffer() else { return }
        
        // 일관된 타임스탬프 생성
        frameCounter += 1
        let currentTime = startTime + Double(frameCounter) / 30.0 // 30 FPS
        let presentationTime = CMTime(seconds: currentTime, preferredTimescale: 1000000000)
        
        if let sampleBuffer = createSampleBuffer(from: pixelBuffer, presentationTime: presentationTime) {
            completion(sampleBuffer)
        }
    }
    
    private func createPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        
        guard let buffer = pixelBuffer else { return nil }
        
        // 검은 프레임 생성 (실제로는 VLC에서 받은 프레임 데이터로 채움)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let baseAddress = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        
        memset(baseAddress, 0, bytesPerRow * height) // 검은 화면
        
        return buffer
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let format = formatDescription else { return nil }
        
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
        
        // Display immediately attachment
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
        stopProcessing()
        pixelBufferPool = nil
    }
}

// MARK: - Frame Processor Delegate
protocol VLCFrameProcessorDelegate: AnyObject {
    func didProcessFrame(_ sampleBuffer: CMSampleBuffer)
}

// MARK: - PiP Delegate Extensions
extension PictureInPictureManager: VLCFrameProcessorDelegate {
    func didProcessFrame(_ sampleBuffer: CMSampleBuffer) {
        enqueueSampleBuffer(sampleBuffer)
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Enhanced PiP will start")
        frameProcessor?.startProcessing()
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Enhanced PiP did start")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Enhanced PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Enhanced PiP did stop")
        isPiPActive = false
        frameProcessor?.stopProcessing()
        endBackgroundTask()
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start enhanced PiP: \(error.localizedDescription)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for enhanced PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Enhanced Sample Buffer Playback Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   setPlaying playing: Bool) {
        if playing {
            vlcPlayer?.play()
            frameProcessor?.startProcessing()
        } else {
            vlcPlayer?.pause()
            frameProcessor?.stopProcessing()
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
        print("Enhanced PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        print("Skip not supported for live stream")
        completionHandler()
    }
}

// MARK: - Enhanced RTSPPlayerView.swift
import UIKit
import SwiftUI
import VLCKitSPM
import AVKit

class RTSPPlayerUIView: UIView {
    
    // VLC Components
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // Video Container
    private var videoContainerView: UIView?
    
    // Enhanced PiP Manager
    private let pipManager = PictureInPictureManager.shared
    private var isPiPSetup = false
    
    // Stream Info
    private var currentStreamURL: String?
    private var streamInfo: StreamInfo?
    
    // Performance Monitoring
    private var performanceMonitor: PerformanceMonitor?
    
    // Layout constraints
    private var containerViewConstraints: [NSLayoutConstraint] = []
    
    // Enhanced Low Latency Options
    private let enhancedLowLatencyOptions: [String: String] = [
        "network-caching": "100",
        "rtsp-caching": "100",
        "tcp-caching": "100",
        "realrtsp-caching": "100",
        "clock-jitter": "100",
        "rtsp-tcp": "",
        "avcodec-hw": "videotoolbox",
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0",
        "avcodec-threads": "4",
        "sout-mux-caching": "10",
        "live-caching": "100",
        // Enhanced options for PiP stability
        "no-audio-time-stretch": "",
        "no-network-synchronisation": "",
        "no-drop-late-frames": "",
        "no-skip-frames": ""
    ]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
        setupPerformanceMonitoring()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
        setupPerformanceMonitoring()
    }
    
    // MARK: - Setup
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // Create video container view
        setupVideoContainer()
        
        // Initialize VLC Media Player
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = videoContainerView
        mediaPlayer?.audio?.volume = 100
        mediaPlayer?.delegate = self
        
        configureVLCPlayer()
        
        print("Enhanced VLC Player initialized")
    }
    
    private func setupVideoContainer() {
        videoContainerView = UIView()
        videoContainerView?.backgroundColor = .black
        videoContainerView?.translatesAutoresizingMaskIntoConstraints = false
        
        guard let containerView = videoContainerView else { return }
        
        addSubview(containerView)
        
        containerViewConstraints = [
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        
        NSLayoutConstraint.activate(containerViewConstraints)
        
        print("Enhanced video container setup completed")
    }
    
    private func configureVLCPlayer() {
        guard let player = mediaPlayer else { return }
        
        player.videoAspectRatio = nil
        
        if let videoView = videoContainerView {
            videoView.contentMode = .scaleAspectFit
        }
        
        print("Enhanced VLC Player configured")
    }
    
    private func setupPerformanceMonitoring() {
        performanceMonitor = PerformanceMonitor()
        performanceMonitor?.startMonitoring()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        videoContainerView?.frame = bounds
        
        // Enhanced PiP setup when stable
        if let player = mediaPlayer, player.isPlaying && !isPiPSetup {
            setupEnhancedPiP()
        }
    }
    
    // MARK: - Enhanced Playback Control
    
    func play(url: String, username: String? = nil, password: String? = nil, networkCaching: Int = 100) {
        if mediaPlayer?.isPlaying == true {
            stop()
        }
        
        let authenticatedURL = buildAuthenticatedURL(url: url, username: username, password: password)
        
        guard let mediaURL = URL(string: authenticatedURL) else {
            print("Invalid URL: \(authenticatedURL)")
            return
        }
        
        currentStreamURL = authenticatedURL
        
        // Create VLC Media with enhanced options
        media = VLCMedia(url: mediaURL)
        applyEnhancedStreamOptimizations(caching: networkCaching)
        
        mediaPlayer?.media = media
        
        // Start playback
        DispatchQueue.main.async { [weak self] in
            self?.mediaPlayer?.drawable = self?.videoContainerView
            self?.mediaPlayer?.play()
            
            print("Starting enhanced stream: \(url)")
            
            // Setup enhanced PiP after stream is stable
            self?.setupEnhancedPiPAfterDelay()
        }
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
    
    private func applyEnhancedStreamOptimizations(caching: Int) {
        guard let media = media else { return }
        
        var options = enhancedLowLatencyOptions
        options["network-caching"] = "\(caching)"
        options["rtsp-caching"] = "\(caching)"
        options["tcp-caching"] = "\(caching)"
        options["realrtsp-caching"] = "\(caching)"
        options["live-caching"] = "\(caching)"
        
        // Apply all enhanced options
        for (key, value) in options {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional enhanced codec optimizations
        media.addOption("--intf=dummy")
        media.addOption("--video-filter=")
        media.addOption("--deinterlace=0")
        
        print("Applied enhanced optimizations with caching: \(caching)ms")
    }
    
    private func setupEnhancedPiPAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.setupEnhancedPiP()
        }
    }
    
    private func setupEnhancedPiP() {
        guard let mediaPlayer = mediaPlayer,
              mediaPlayer.isPlaying,
              !isPiPSetup else { return }
        
        // Connect to enhanced PiP manager (UI independent)
        pipManager.connectToVLCPlayer(mediaPlayer)
        isPiPSetup = true
        
        print("Enhanced PiP setup completed - UI independent")
    }
    
    func stop() {
        // PiP 상태 확인 후 정리
        if !pipManager.isPiPActive {
            mediaPlayer?.stop()
            media = nil
            currentStreamURL = nil
            streamInfo = nil
            isPiPSetup = false
            
            videoContainerView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            
            print("Enhanced stream stopped")
        } else {
            print("Enhanced stream continues for active PiP")
        }
    }
    
    func pause() {
        mediaPlayer?.pause()
    }
    
    func resume() {
        mediaPlayer?.play()
    }
    
    func setVolume(_ volume: Int32) {
        mediaPlayer?.audio?.volume = volume
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    // MARK: - Enhanced PiP Control
    
    func startPictureInPicture() {
        if !isPiPSetup {
            setupEnhancedPiP()
        }
        
        if pipManager.canStartPiP {
            pipManager.startPiP()
        }
    }
    
    func stopPictureInPicture() {
        pipManager.stopPiP()
    }
    
    func togglePictureInPicture() {
        pipManager.togglePiP()
    }
    
    var isPiPActive: Bool {
        return pipManager.isPiPActive
    }
    
    var isPiPPossible: Bool {
        return pipManager.isPiPPossible
    }
    
    // MARK: - Stream Info
    
    func getStreamInfo() -> StreamInfo? {
        guard let mediaPlayer = mediaPlayer, mediaPlayer.isPlaying else { return nil }
        
        var info = StreamInfo()
        
        let videoSize = mediaPlayer.videoSize
        info.resolution = CGSize(width: CGFloat(videoSize.width), height: CGFloat(videoSize.height))
        info.videoCodec = detectVideoCodec()
        
        if let audioTracks = mediaPlayer.audioTrackNames as? [String],
           let audioTrack = audioTracks.first {
            info.audioTrack = audioTrack
        }
        
        info.position = mediaPlayer.position
        info.time = TimeInterval(mediaPlayer.time.intValue / 1000)
        info.isBuffering = mediaPlayer.state == .buffering
        info.droppedFrames = getDroppedFrames()
        
        if let performance = performanceMonitor?.getCurrentMetrics() {
            info.cpuUsage = performance.cpuUsage
            info.memoryUsage = performance.memoryUsage
            info.fps = performance.fps
        }
        
        self.streamInfo = info
        return info
    }
    
    private func detectVideoCodec() -> String {
        if let media = media {
            let url = media.url?.absoluteString ?? ""
            if url.contains("h264") || url.contains("avc") {
                return "H.264/AVC (Enhanced)"
            } else if url.contains("h265") || url.contains("hevc") {
                return "H.265/HEVC (Enhanced)"
            }
        }
        
        return "Unknown (Enhanced)"
    }
    
    private func getDroppedFrames() -> Int {
        return 0
    }
    
    func updateNetworkCaching(_ caching: Int) {
        guard let currentURL = currentStreamURL, isPlaying() else { return }
        
        let wasPlaying = isPlaying()
        stop()
        
        if wasPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(url: currentURL, networkCaching: caching)
            }
        }
    }
    
    // MARK: - Enhanced Cleanup
    
    deinit {
        // PiP 활성 상태가 아닐 때만 완전 정리
        if !pipManager.isPiPActive {
            stop()
        }
        
        performanceMonitor?.stopMonitoring()
        NSLayoutConstraint.deactivate(containerViewConstraints)
        containerViewConstraints.removeAll()
        videoContainerView?.removeFromSuperview()
        videoContainerView = nil
        mediaPlayer = nil
        
        print("Enhanced RTSPPlayerUIView deinitialized")
    }
}

// MARK: - Enhanced VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .opening:
            print("Enhanced VLC: Opening stream...")
            streamInfo?.state = "Opening (Enhanced)"
            
        case .buffering:
            let bufferPercent = player.position * 100
            print("Enhanced VLC: Buffering... \(Int(bufferPercent))%")
            streamInfo?.state = "Buffering (Enhanced)"
            
        case .playing:
            print("Enhanced VLC: Playing - Video size: \(player.videoSize)")
            streamInfo?.state = "Playing (Enhanced)"
            
            DispatchQueue.main.async { [weak self] in
                self?.videoContainerView?.setNeedsLayout()
                self?.setNeedsLayout()
                
                if self?.isPiPSetup == false {
                    self?.setupEnhancedPiPAfterDelay()
                }
            }
            
        case .paused:
            print("Enhanced VLC: Paused")
            streamInfo?.state = "Paused (Enhanced)"
            
        case .stopped:
            print("Enhanced VLC: Stopped")
            streamInfo?.state = "Stopped (Enhanced)"
            
        case .error:
            print("Enhanced VLC: Error occurred")
            streamInfo?.state = "Error (Enhanced)"
            streamInfo?.lastError = "Enhanced stream playback error"
            
        case .ended:
            print("Enhanced VLC: Ended")
            streamInfo?.state = "Ended (Enhanced)"
            
        case .esAdded:
            print("Enhanced VLC: Elementary stream added")
            streamInfo?.state = "ES Added (Enhanced)"
            
        @unknown default:
            print("Enhanced VLC: Unknown state")
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if let player = aNotification.object as? VLCMediaPlayer {
            streamInfo?.time = TimeInterval(player.time.intValue / 1000)
            streamInfo?.position = player.position
        }
    }
}

// MARK: - Enhanced App.swift
import SwiftUI
import AVKit
import VLCKitSPM

@main
struct EnhancedRTSPPlayerApp: App {
    @UIApplicationDelegateAdaptor(EnhancedAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        let pipManager = PictureInPictureManager.shared
        
        switch phase {
        case .background:
            print("Enhanced app moved to background")
            if pipManager.isPiPActive {
                print("Enhanced PiP active - maintaining stream")
            }
            
        case .inactive:
            print("Enhanced app is inactive")
            
        case .active:
            print("Enhanced app is active")
            if pipManager.isPiPActive {
                print("Enhanced app active with PiP running")
            }
            
        @unknown default:
            break
        }
    }
}

// MARK: - Enhanced App Delegate with Background Support
class EnhancedAppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Enhanced audio session setup
        configureEnhancedAudioSession()
        
        // VLC logging setup
        configureVLCLogging()
        
        // Background app refresh
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        
        // Screen timeout prevention during video playback
        UIApplication.shared.isIdleTimerDisabled = true
        
        print("Enhanced RTSP Player app initialized")
        
        return true
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .all
    }
    
    // MARK: - Enhanced Background Handling
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        let pipManager = PictureInPictureManager.shared
        
        if pipManager.isPiPActive {
            print("Enhanced app entering background with active PiP - maintaining resources")
            // PiP 매니저가 자동으로 백그라운드 태스크 관리
        } else {
            print("Enhanced app entering background without PiP")
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        let pipManager = PictureInPictureManager.shared
        
        print("Enhanced app entering foreground - PiP active: \(pipManager.isPiPActive)")
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("Enhanced app became active")
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        print("Enhanced app will resign active")
    }
    
    // MARK: - Background Fetch Support
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let pipManager = PictureInPictureManager.shared
        
        if pipManager.isPiPActive {
            print("Background fetch - PiP stream maintained")
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }
    
    // MARK: - Private Methods
    
    private func configureEnhancedAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Enhanced category with all necessary options
            try audioSession.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers, .allowAirPlay, .allowBluetoothA2DP]
            )
            
            try audioSession.setActive(true)
            
            print("Enhanced audio session configured successfully")
        } catch {
            print("Failed to configure enhanced audio session: \(error)")
        }
    }
    
    private func configureVLCLogging() {
        #if DEBUG
        let consoleLogger = VLCConsoleLogger()
        VLCLibrary.shared().setLogger(consoleLogger)
        print("Enhanced VLC logging configured")
        #endif
    }
}

// MARK: - Enhanced Scene Delegate
class EnhancedSceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let _ = (scene as? UIWindowScene) else { return }
        print("Enhanced scene connected")
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        let pipManager = PictureInPictureManager.shared
        
        // PiP 활성 상태에서는 정리하지 않음
        if !pipManager.isPiPActive {
            print("Enhanced scene disconnected without PiP")
        } else {
            print("Enhanced scene disconnected with active PiP - resources maintained")
        }
    }
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        print("Enhanced scene became active")
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        print("Enhanced scene will resign active")
        // PiP 준비 시점
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        print("Enhanced scene will enter foreground")
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        let pipManager = PictureInPictureManager.shared
        
        if pipManager.isPiPActive {
            print("Enhanced scene entered background with active PiP")
        } else {
            print("Enhanced scene entered background")
        }
    }
}

// MARK: - Additional Required Structs
struct StreamInfo {
    var state: String = "Idle"
    var resolution: CGSize = .zero
    var videoCodec: String = "Unknown"
    var audioTrack: String?
    var position: Float = 0.0
    var time: TimeInterval = 0
    var isBuffering: Bool = false
    var droppedFrames: Int = 0
    var lastError: String?
    var cpuUsage: Float = 0.0
    var memoryUsage: Float = 0.0
    var fps: Float = 0.0
    
    var qualityDescription: String {
        if resolution.width >= 3840 {
            return "4K UHD (Enhanced)"
        } else if resolution.width >= 1920 {
            return "Full HD (Enhanced)"
        } else if resolution.width >= 1280 {
            return "HD (Enhanced)"
        } else if resolution.width > 0 {
            return "SD (Enhanced)"
        } else {
            return "Unknown"
        }
    }
    
    var resolutionString: String {
        if resolution.width > 0 && resolution.height > 0 {
            return "\(Int(resolution.width))x\(Int(resolution.height))"
        }
        return "N/A"
    }
}

class PerformanceMonitor {
    private var timer: Timer?
    
    struct Metrics {
        var cpuUsage: Float = 0.0
        var memoryUsage: Float = 0.0
        var fps: Float = 0.0
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    func getCurrentMetrics() -> Metrics {
        var metrics = Metrics()
        metrics.cpuUsage = getCPUUsage()
        metrics.memoryUsage = getMemoryUsage()
        metrics.fps = 30.0
        return metrics
    }
    
    private func updateMetrics() {
        _ = getCurrentMetrics()
    }
    
    private func getCPUUsage() -> Float {
        return 0.0 // Simplified
    }
    
    private func getMemoryUsage() -> Float {
        return 0.0 // Simplified
    }
    
    deinit {
        stopMonitoring()
    }
}
