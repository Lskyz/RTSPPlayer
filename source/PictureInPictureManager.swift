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
    func pipShouldHideMainPlayer(_ hide: Bool) // 메인 플레이어 숨김/표시 제어
}

// MARK: - 완전 독립적인 PiP Manager
class PictureInPictureManager: NSObject, ObservableObject {
    
    static let shared = PictureInPictureManager()
    
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    
    // PiP 전용 컴포넌트 (메인 UI와 완전 분리)
    private var pipController: AVPictureInPictureController?
    private var pipDisplayLayer: AVSampleBufferDisplayLayer?
    private var pipPlayerLayer: AVPlayerLayer? // PiP 전용 플레이어
    
    // 독립적인 VLC 인스턴스 (PiP 전용)
    private var pipVLCPlayer: VLCMediaPlayer?
    private var mainVLCPlayer: VLCMediaPlayer? // 메인 플레이어 참조
    private var currentStreamURL: String?
    
    // 프레임 추출 컴포넌트
    private var frameExtractor: IndependentFrameExtractor?
    
    weak var delegate: PictureInPictureManagerDelegate?
    private var cancellables = Set<AnyCancellable>()
    
    // 백그라운드 태스크
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
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
            print("Audio session configured for independent PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - PiP 전용 플레이어 설정 (메인과 완전 분리)
    
    func setupIndependentPiP(for vlcPlayer: VLCMediaPlayer, streamURL: String) {
        cleanup()
        
        mainVLCPlayer = vlcPlayer
        currentStreamURL = streamURL
        
        // PiP 전용 디스플레이 레이어 생성
        setupPiPDisplayLayer()
        
        // PiP 컨트롤러 설정
        if #available(iOS 15.0, *) {
            setupSampleBufferPiPController()
        } else {
            setupLegacyPiPController()
        }
        
        print("Independent PiP setup completed")
    }
    
    private func setupPiPDisplayLayer() {
        // PiP 전용 샘플 버퍼 디스플레이 레이어
        pipDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = pipDisplayLayer else { return }
        
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        
        // 타임베이스 설정
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        
        if status == noErr, let tb = timebase {
            displayLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
        
        print("PiP display layer configured independently")
    }
    
    @available(iOS 15.0, *)
    private func setupSampleBufferPiPController() {
        guard let displayLayer = pipDisplayLayer else { return }
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        configurePiPController()
        
        print("Sample buffer PiP controller configured")
    }
    
    private func setupLegacyPiPController() {
        // iOS 14 이하 지원 (AVPlayerLayer 사용)
        setupPiPPlayerLayer()
        
        guard let playerLayer = pipPlayerLayer else { return }
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        configurePiPController()
        
        print("Legacy PiP controller configured")
    }
    
    private func setupPiPPlayerLayer() {
        let player = AVPlayer()
        pipPlayerLayer = AVPlayerLayer(player: player)
        pipPlayerLayer?.videoGravity = .resizeAspect
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
    
    // MARK: - PiP 제어 (완전 독립적)
    
    func startPiP() {
        guard isPiPSupported, isPiPPossible, let streamURL = currentStreamURL else {
            print("Cannot start PiP - conditions not met")
            return
        }
        
        // 백그라운드 태스크 시작
        startBackgroundTask()
        
        // PiP 전용 스트림 시작
        startIndependentStream(streamURL)
        
        // PiP 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pipController?.startPictureInPicture()
            
            // 메인 플레이어 숨김 요청
            self?.delegate?.pipShouldHideMainPlayer(true)
            
            print("Starting independent PiP")
        }
    }
    
    func stopPiP() {
        guard isPiPActive else { return }
        
        // PiP 정지
        pipController?.stopPictureInPicture()
        
        // 독립적인 스트림 정지
        stopIndependentStream()
        
        // 메인 플레이어 표시 요청
        delegate?.pipShouldHideMainPlayer(false)
        
        // 백그라운드 태스크 종료
        endBackgroundTask()
        
        print("Stopping independent PiP")
    }
    
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // MARK: - 독립적인 스트림 관리
    
    private func startIndependentStream(_ streamURL: String) {
        // PiP 전용 VLC 플레이어 생성
        pipVLCPlayer = VLCMediaPlayer()
        
        guard let pipPlayer = pipVLCPlayer,
              let url = URL(string: streamURL) else {
            print("Failed to create independent VLC player")
            return
        }
        
        // VLC 미디어 생성 및 설정
        let media = VLCMedia(url: url)
        
        // 저지연 옵션 적용
        applyLowLatencyOptions(to: media)
        
        pipPlayer.media = media
        
        // PiP 전용 프레임 추출기 설정
        setupIndependentFrameExtractor()
        
        // 스트림 시작
        pipPlayer.play()
        
        print("Independent PiP stream started")
    }
    
    private func stopIndependentStream() {
        frameExtractor?.stopExtraction()
        frameExtractor = nil
        
        pipVLCPlayer?.stop()
        pipVLCPlayer = nil
        
        pipDisplayLayer?.flushAndRemoveImage()
        
        print("Independent PiP stream stopped")
    }
    
    private func applyLowLatencyOptions(to media: VLCMedia) {
        let options: [String: String] = [
            "network-caching": "100",
            "rtsp-caching": "100", 
            "tcp-caching": "100",
            "avcodec-hw": "videotoolbox",
            "rtsp-tcp": "",
            "live-caching": "100"
        ]
        
        for (key, value) in options {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
    }
    
    private func setupIndependentFrameExtractor() {
        guard let pipPlayer = pipVLCPlayer else { return }
        
        frameExtractor = IndependentFrameExtractor(vlcPlayer: pipPlayer)
        frameExtractor?.delegate = self
        frameExtractor?.startExtraction()
        
        print("Independent frame extractor started")
    }
    
    // MARK: - 백그라운드 태스크 관리
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Independent PiP") { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    // MARK: - 정리
    
    private func cleanup() {
        stopIndependentStream()
        
        pipController?.delegate = nil
        pipController = nil
        
        pipDisplayLayer?.removeFromSuperlayer()
        pipDisplayLayer = nil
        
        pipPlayerLayer?.removeFromSuperlayer()
        pipPlayerLayer = nil
        
        cancellables.removeAll()
        
        endBackgroundTask()
        
        print("PiP cleanup completed")
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - 상태 프로퍼티
    
    var canStartPiP: Bool {
        return isPiPSupported && isPiPPossible && !isPiPActive && currentStreamURL != nil
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
            return "Inactive"
        }
    }
}

// MARK: - 독립적인 프레임 추출기 (백그라운드 지원)
class IndependentFrameExtractor: NSObject {
    weak var vlcPlayer: VLCMediaPlayer?
    weak var delegate: IndependentFrameExtractionDelegate?
    
    private var isExtracting = false
    private var extractionTimer: Timer?
    private let extractionQueue = DispatchQueue(label: "com.rtspplayer.independent.extraction", qos: .userInteractive)
    
    // 픽셀 버퍼 풀
    private var pixelBufferPool: CVPixelBufferPool?
    
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
    }
    
    func startExtraction() {
        guard !isExtracting, vlcPlayer != nil else { return }
        isExtracting = true
        
        // 30 FPS 타이머 (백그라운드에서도 동작)
        extractionTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.extractFrame()
        }
        
        // RunLoop에 추가하여 백그라운드에서도 실행
        if let timer = extractionTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        print("Independent frame extraction started")
    }
    
    func stopExtraction() {
        isExtracting = false
        extractionTimer?.invalidate()
        extractionTimer = nil
        
        print("Independent frame extraction stopped")
    }
    
    private func extractFrame() {
        guard let player = vlcPlayer,
              player.isPlaying,
              isExtracting else { return }
        
        extractionQueue.async { [weak self] in
            self?.captureCurrentFrame()
        }
    }
    
    private func captureCurrentFrame() {
        guard let player = vlcPlayer else { return }
        
        // 백그라운드에서도 작동하는 프레임 캡처
        let tempPath = NSTemporaryDirectory() + "pip_frame_\(Date().timeIntervalSince1970).png"
        
        // VLC 스냅샷 (백그라운드에서도 동작)
        player.saveVideoSnapshot(at: tempPath, withWidth: 1280, andHeight: 720)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.processSnapshot(at: tempPath)
        }
    }
    
    private func processSnapshot(at path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let image = UIImage(contentsOfFile: path) else { return }
        
        if let pixelBuffer = convertToPixelBuffer(image) {
            if let sampleBuffer = createSampleBuffer(from: pixelBuffer) {
                delegate?.didExtractIndependentFrame(sampleBuffer)
            }
        }
        
        // 임시 파일 삭제
        try? FileManager.default.removeItem(atPath: path)
    }
    
    private func convertToPixelBuffer(_ image: UIImage) -> CVPixelBuffer? {
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
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let format = formatDescription else { return nil }
        
        let presentationTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000000)
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
        
        return result == noErr ? sampleBuffer : nil
    }
    
    deinit {
        stopExtraction()
    }
}

// MARK: - 독립 프레임 추출 델리게이트
protocol IndependentFrameExtractionDelegate: AnyObject {
    func didExtractIndependentFrame(_ sampleBuffer: CMSampleBuffer)
}

// MARK: - 프레임 처리
extension PictureInPictureManager: IndependentFrameExtractionDelegate {
    func didExtractIndependentFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = pipDisplayLayer else { return }
        
        DispatchQueue.main.async {
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Independent PiP will start")
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Independent PiP did start")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Independent PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("Independent PiP did stop")
        isPiPActive = false
        stopIndependentStream()
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for independent PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start independent PiP: \(error.localizedDescription)")
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
        print("Independent PiP render size: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        print("Skip not supported for live RTSP stream")
        completionHandler()
    }
}
