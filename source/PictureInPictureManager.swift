import AVKit
import UIKit
import Combine
import VLCKitSPM
import VideoToolbox
import CoreMedia

// PiP 관리자 프로토콜
protocol PictureInPictureManagerDelegate: AnyObject {
    func pipDidStart()
    func pipDidStop()
    func pipWillStart()
    func pipWillStop()
    func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void)
}

// Enhanced Picture in Picture 관리 클래스 - H.264/H.265 직접 지원 (수정본)
final class PictureInPictureManager: NSObject, ObservableObject {

    // Singleton
    static let shared = PictureInPictureManager()

    // Published Properties
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false

    // PiP Controllers
    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?

    // VLC Integration
    private var vlcPlayer: VLCMediaPlayer?
    private var frameExtractor: VideoFrameExtractor?

    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?

    // Cancellables
    private var cancellables = Set<AnyCancellable>()

    // Queues
    private let frameQueue = DispatchQueue(label: "com.rtspplayer.frameprocessing", qos: .userInteractive)
    private let displayQueue = DispatchQueue(label: "com.rtspplayer.display", qos: .userInteractive)

    // 내부 호스트 뷰(레이어 부착용, 자동 부착/숨김)
    private var layerHostView: UIView?

    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
        ensureLayerHostAttached()
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

    // 호스트 뷰를 실제 윈도우 계층에 자동 부착
    private func ensureLayerHostAttached() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let host = self.layerHostView, host.window != nil { return }

            // 최상단 윈도우/루트 찾기
            let window: UIWindow? = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? UIApplication.shared.windows.first

            let rootView = window?.rootViewController?.view ?? window

            let host = UIView(frame: CGRect(x: -1, y: -1, width: 1, height: 1))
            host.isHidden = true
            host.isUserInteractionEnabled = false
            host.backgroundColor = .clear
            rootView?.addSubview(host)
            self.layerHostView = host
        }
    }

    // MARK: - H.264/H.265 Direct PiP Implementation

    /// VLCKit 기반 H.264/H.265 스트림을 위한 PiP 설정
    func setupPiPForCodecStream(vlcPlayer: VLCMediaPlayer, streamURL: String) {
        cleanupPiPController()
        ensureLayerHostAttached()

        self.vlcPlayer = vlcPlayer

        // AVSampleBufferDisplayLayer 생성
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        self.sampleBufferDisplayLayer = displayLayer

        // 호스트 뷰에 실제 부착 (필수)
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.layerHostView else { return }
            if displayLayer.superlayer == nil {
                displayLayer.frame = host.bounds
                host.layer.addSublayer(displayLayer)
            }
        }

        // Timebase 설정
        setupTimebase(for: displayLayer)

        // PiP 컨트롤러 생성 (iOS 15+)
        if #available(iOS 15.0, *) {
            setupSampleBufferPiPController(with: displayLayer)
        } else {
            setupLegacyPiPController(vlcPlayer: vlcPlayer)
        }

        // Frame extractor 초기화
        let extractor = VideoFrameExtractor(vlcPlayer: vlcPlayer)
        extractor.delegate = self
        extractor.startFrameExtraction()
        self.frameExtractor = extractor
    }

    private func setupTimebase(for layer: AVSampleBufferDisplayLayer) {
        var timebase: CMTimebase?
        let result = CMTimebaseCreateWithMasterClock(
            allocator: kCFAllocatorDefault,
            masterClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if result == noErr, let timebase {
            layer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }

    @available(iOS 15.0, *)
    private func setupSampleBufferPiPController(with layer: AVSampleBufferDisplayLayer) {
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        pipController = AVPictureInPictureController(contentSource: contentSource)
        configurePiPController()
    }

    private func setupLegacyPiPController(vlcPlayer: VLCMediaPlayer) {
        // iOS 14 이하: AVPlayer 브릿지 방식(여기서는 로그만 남김)
        print("Legacy PiP setup for iOS 14 and below")
    }

    private func configurePiPController() {
        guard let pipController else { return }
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
            .sink { [weak self] possible in
                self?.isPiPPossible = possible
                print("PiP Possible: \(possible)")
            }
            .store(in: &cancellables)

        pipController.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isPiPActive = active
                print("PiP Active: \(active)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Frame Processing

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        displayQueue.async {
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
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
        isPiPActive ? stopPiP() : startPiP()
    }

    // MARK: - Cleanup

    private func cleanupPiPController() {
        frameExtractor?.stopFrameExtraction()
        frameExtractor = nil

        pipController?.delegate = nil
        pipController = nil

        if let layer = sampleBufferDisplayLayer {
            layer.flushAndRemoveImage()
            layer.removeFromSuperlayer()
        }
        sampleBufferDisplayLayer = nil

        cancellables.removeAll()
    }

    deinit {
        cleanupPiPController()
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP will start")
        delegate?.pipWillStart()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP did start")
        isPiPActive = true
        delegate?.pipDidStart()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP will stop")
        delegate?.pipWillStop()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        print("PiP did stop")
        isPiPActive = false
        delegate?.pipDidStop()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start PiP: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Sample Buffer Playback Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        playing ? vlcPlayer?.play() : vlcPlayer?.pause()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // 라이브 스트림용 무한 범위 (로딩 고정 방지)
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) // ★ FIX
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        return !(vlcPlayer?.isPlaying ?? false)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - Video Frame Extractor
final class VideoFrameExtractor: NSObject {
    private weak var vlcPlayer: VLCMediaPlayer?
    private var isExtracting = false
    private let extractionQueue = DispatchQueue(label: "com.rtspplayer.extraction", qos: .userInteractive)

    weak var delegate: VideoFrameExtractionDelegate?

    init(vlcPlayer: VLCMediaPlayer) {
        self.vlcPlayer = vlcPlayer
        super.init()
    }

    func startFrameExtraction() {
        guard !isExtracting else { return }
        isExtracting = true
        setupFrameCallback()
    }

    func stopFrameExtraction() {
        isExtracting = false
    }

    private func setupFrameCallback() {
        // 실제 VLCKit video callbacks 사용이 이상적이지만
        // 여기서는 주기적 스냅샷 캡처 방식을 유지
        startPeriodicFrameCapture()
    }

    private func startPeriodicFrameCapture() {
        extractionQueue.async { [weak self] in
            guard let self else { return }
            while self.isExtracting {
                self.captureCurrentFrame()
                usleep(33333) // ~30 FPS
            }
        }
    }

    private func captureCurrentFrame() {
        guard let vlcPlayer = vlcPlayer, vlcPlayer.isPlaying else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let drawable = vlcPlayer.drawable as? UIView {
                let image = drawable.asImage()
                self.processFrameImage(image)
            }
        }
    }

    private func processFrameImage(_ image: UIImage) {
        guard let pixelBuffer = image.toCVPixelBuffer_BGRA_IOSurface(),
              let sampleBuffer = pixelBuffer.toCMSampleBuffer_DisplayNow() else { return }
        delegate?.didExtractFrame(sampleBuffer)
    }
}

// MARK: - Frame Extraction Delegate
protocol VideoFrameExtractionDelegate: AnyObject {
    func didExtractFrame(_ sampleBuffer: CMSampleBuffer)
}

extension PictureInPictureManager: VideoFrameExtractionDelegate {
    func didExtractFrame(_ sampleBuffer: CMSampleBuffer) {
        processSampleBuffer(sampleBuffer)
    }
}

// MARK: - Helper Extensions
extension UIView {
    func asImage() -> UIImage {
        let scale = UIScreen.main.scale
        UIGraphicsBeginImageContextWithOptions(bounds.size, false, scale)
        defer { UIGraphicsEndImageContext() }
        if let context = UIGraphicsGetCurrentContext() {
            layer.render(in: context)
        }
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }
}

extension UIImage {
    // ★ FIX: BGRA + IOSurface 호환 PixelBuffer
    func toCVPixelBuffer_BGRA_IOSurface() -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] // IOSurface attach
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA, // BGRA
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        UIGraphicsPushContext(context)
        draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        UIGraphicsPopContext()

        return buffer
    }
}

extension CVPixelBuffer {
    // ★ FIX: DisplayImmediately 첨부 포함
    func toCMSampleBuffer_DisplayNow() -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: self,
                                                           formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)

        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: self,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sb = sampleBuffer else { return nil }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0 {
            let attachments = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachments,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
