import UIKit
import SwiftUI
import Combine
import VLCKitSPM
import AVKit
import VideoToolbox
import CoreMedia

// MARK: - PiP Delegate
protocol PictureInPictureManagerDelegate: AnyObject {
    func pipDidStart()
    func pipDidStop()
    func pipWillStart()
    func pipWillStop()
    func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void)
}

// MARK: - PictureInPictureManager (샘플버퍼 기반 PiP)
final class PictureInPictureManager: NSObject, ObservableObject {

    static let shared = PictureInPictureManager()

    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    @Published private(set) var pipReady: Bool = false   // 첫 유효 프레임 enqueue 이후 true

    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?

    private var vlcPlayer: VLCMediaPlayer?
    private var frameExtractor: VideoFrameExtractor?

    weak var delegate: PictureInPictureManagerDelegate?

    private var cancellables = Set<AnyCancellable>()
    private let displayQueue = DispatchQueue(label: "com.rtspplayer.display", qos: .userInteractive)

    // 레이어 부착용 호스트 뷰
    private var layerHostView: UIView?

    override init() {
        super.init()
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        setupAudioSession()
        ensureLayerHostAttached()
    }

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func ensureLayerHostAttached() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let host = self.layerHostView, host.window != nil { return }
            let window: UIWindow? = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? UIApplication.shared.windows.first
            let root = window?.rootViewController?.view ?? window
            let host = UIView(frame: CGRect(x: -1, y: -1, width: 1, height: 1))
            host.isHidden = true
            host.isUserInteractionEnabled = false
            host.backgroundColor = .clear
            root?.addSubview(host)
            self.layerHostView = host
        }
    }

    // MARK: Setup for VLC stream
    func setupPiPForCodecStream(vlcPlayer: VLCMediaPlayer, streamURL: String) {
        cleanupPiPController()
        ensureLayerHostAttached()

        self.vlcPlayer = vlcPlayer

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        self.sampleBufferDisplayLayer = displayLayer

        // 실제 계층에 부착
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.layerHostView else { return }
            if displayLayer.superlayer == nil {
                displayLayer.frame = host.bounds
                host.layer.addSublayer(displayLayer)
            }
        }

        // 타임베이스
        var timebase: CMTimebase?
        if CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault,
                                           masterClock: CMClockGetHostTimeClock(),
                                           timebaseOut: &timebase) == noErr,
           let tb = timebase {
            displayLayer.controlTimebase = tb
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }

        if #available(iOS 15.0, *) {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            pipController = AVPictureInPictureController(contentSource: contentSource)
            pipController?.delegate = self
            if #available(iOS 14.2, *) {
                pipController?.canStartPictureInPictureAutomaticallyFromInline = true
            }
            observePiPStates()
        } else {
            print("Legacy iOS: sample-buffer PiP 미지원")
        }

        // 프레임 추출
        let extractor = VideoFrameExtractor(vlcPlayer: vlcPlayer)
        extractor.delegate = self
        extractor.startFrameExtraction()
        self.frameExtractor = extractor
    }

    private func observePiPStates() {
        guard let pipController else { return }

        pipController.publisher(for: \.isPictureInPicturePossible)
            .receive(on: .main)
            .sink { [weak self] possible in
                self?.isPiPPossible = possible
            }
            .store(in: &cancellables)

        pipController.publisher(for: \.isPictureInPictureActive)
            .receive(on: .main)
            .sink { [weak self] active in
                self?.isPiPActive = active
            }
            .store(in: &cancellables)
    }

    private var canStartPiP: Bool {
        isPiPSupported && isPiPPossible && pipReady
    }

    func startPiP() {
        guard canStartPiP else {
            print("PiP not ready (supported:\(isPiPSupported) possible:\(isPiPPossible) ready:\(pipReady))")
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

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        displayQueue.async {
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
                if self.pipReady == false {
                    DispatchQueue.main.async { self.pipReady = true }
                }
            }
        }
    }

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
        pipReady = false
    }

    deinit { cleanupPiPController() }
}

// MARK: AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        delegate?.pipWillStart()
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPiPActive = true
        delegate?.pipDidStart()
    }
    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        delegate?.pipWillStop()
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPiPActive = false
        delegate?.pipDidStop()
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        print("PiP start failed: \(error.localizedDescription)")
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: AVPictureInPictureSampleBufferPlaybackDelegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        playing ? vlcPlayer?.play() : vlcPlayer?.pause()
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        !(vlcPlayer?.isPlaying ?? false)
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("PiP render size: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - VideoFrameExtractor (스냅샷→픽셀버퍼→샘플버퍼)
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
        startPeriodicFrameCapture()
    }

    func stopFrameExtraction() { isExtracting = false }

    private func startPeriodicFrameCapture() {
        extractionQueue.async { [weak self] in
            guard let self else { return }
            while self.isExtracting {
                self.captureCurrentFrame()
                usleep(33333) // ~30 fps
            }
        }
    }

    private func captureCurrentFrame() {
        guard let vlcPlayer = vlcPlayer, vlcPlayer.isPlaying else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let drawable = vlcPlayer.drawable as? UIView else { return }

            // 아직 그려지지 않았으면 스킵
            let hasContent = (drawable.layer.presentation()?.contents != nil) || (drawable.layer.contents != nil)
            let validSize = drawable.bounds.width > 0 && drawable.bounds.height > 0
            guard hasContent && validSize else { return }

            let image = drawable.asImage()
            guard image.size.width > 0 && image.size.height > 0 else { return }

            self.processFrameImage(image)
        }
    }

    private func processFrameImage(_ image: UIImage) {
        var target = image.size
        if let mp = vlcPlayer {
            let vs = mp.videoSize
            if vs.width > 0 && vs.height > 0 { target = vs }
        }
        guard let pb = image.toCVPixelBuffer_BGRA_IOSurface(targetSize: target),
              let sb = pb.toCMSampleBuffer_DisplayNow() else { return }
        delegate?.didExtractFrame(sb)
    }
}

protocol VideoFrameExtractionDelegate: AnyObject {
    func didExtractFrame(_ sampleBuffer: CMSampleBuffer)
}

extension PictureInPictureManager: VideoFrameExtractionDelegate {
    func didExtractFrame(_ sampleBuffer: CMSampleBuffer) {
        processSampleBuffer(sampleBuffer)
    }
}

// MARK: - UIView 캡처
extension UIView {
    func asImage() -> UIImage {
        let scale = UIScreen.main.scale
        UIGraphicsBeginImageContextWithOptions(bounds.size, false, scale)
        defer { UIGraphicsEndImageContext() }
        if let ctx = UIGraphicsGetCurrentContext() { layer.render(in: ctx) }
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }
}

// MARK: - UIImage → CVPixelBuffer (IOSurface+BGRA)
extension UIImage {
    func toCVPixelBuffer_BGRA_IOSurface(targetSize: CGSize) -> CVPixelBuffer? {
        let width = Int(targetSize.width.rounded(.down))
        let height = Int(targetSize.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let cs = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                              CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)
        UIGraphicsPushContext(ctx)
        draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        UIGraphicsPopContext()
        return buffer
    }
}

// MARK: - CVPixelBuffer → CMSampleBuffer (DisplayImmediately)
extension CVPixelBuffer {
    func toCMSampleBuffer_DisplayNow() -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: self,
                                                           formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return nil }

        let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: self,
                                                       formatDescription: formatDesc,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr,
              let sb = sampleBuffer else { return nil }

        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let attachments = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachments,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

// MARK: - VLC Player UIView (RTSP)
final class RTSPPlayerUIView: UIView {

    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?

    private var pipManager: PictureInPictureManager?
    private var isPiPConfigured = false

    private let lowLatencyOptions = [
        "network-caching": "150",
        "rtsp-caching": "150",
        "tcp-caching": "150",
        "realrtsp-caching": "150",
        "clock-jitter": "150",
        "rtsp-tcp": "",
        "avcodec-hw": "any",
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0"
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
        setupPiPManager()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
        setupPiPManager()
    }

    private func setupPlayer() {
        backgroundColor = .black
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        mediaPlayer?.audio?.volume = 100
        mediaPlayer?.delegate = self
    }

    private func setupPiPManager() {
        pipManager = PictureInPictureManager.shared
    }

    // MARK: Playback
    func play(url: String, username: String? = nil, password: String? = nil) {
        guard let mediaPlayer = mediaPlayer else { return }
        if mediaPlayer.isPlaying { stop() }

        var rtspURL = url
        if let username, let password, let comps = URLComponents(string: url) {
            var s = "\(comps.scheme ?? "rtsp")://"
            s += "\(username):\(password)@"
            s += "\(comps.host ?? "")"
            if let port = comps.port { s += ":\(port)" }
            s += comps.path
            rtspURL = s
        }
        guard let u = URL(string: rtspURL) else { print("Invalid URL"); return }

        media = VLCMedia(url: u)
        applyCodecOptimizations()
        mediaPlayer.media = media
        mediaPlayer.play()
    }

    private func applyCodecOptimizations() {
        guard let media else { return }
        for (k, v) in lowLatencyOptions {
            v.isEmpty ? media.addOption("--\(k)") : media.addOption("--\(k)=\(v)")
        }
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        media.addOption("--avcodec-hw=videotoolbox")
        media.addOption("--no-drop-late-frames")
        media.addOption("--no-skip-frames")
    }

    private func configurePiPIfNeeded() {
        guard let mediaPlayer = mediaPlayer,
              mediaPlayer.isPlaying,
              !isPiPConfigured else { return }
        PictureInPictureManager.shared.setupPiPForCodecStream(
            vlcPlayer: mediaPlayer,
            streamURL: media?.url?.absoluteString ?? ""
        )
        isPiPConfigured = true
    }

    func stop() {
        mediaPlayer?.stop()
        media = nil
        isPiPConfigured = false
    }

    func pause() { mediaPlayer?.pause() }
    func resume() { mediaPlayer?.play() }
    func setVolume(_ volume: Int32) { mediaPlayer?.audio?.volume = volume }
    func isPlaying() -> Bool { mediaPlayer?.isPlaying ?? false }

    // 품질/네트워크 정보는 필요 시 사용
    func getStreamInfo() -> [String: Any]? {
        guard let mp = mediaPlayer, mp.isPlaying else { return nil }
        var info: [String: Any] = [:]
        if let v = mp.videoTrackNames.first { info["videoTrack"] = v }
        if let a = mp.audioTrackNames.first { info["audioTrack"] = a }
        let sz = mp.videoSize
        if sz.width > 0 && sz.height > 0 { info["videoSize"] = "\(Int(sz.width))x\(Int(sz.height))" }
        info["time"] = mp.time.intValue
        info["position"] = mp.position
        return info
    }
}

// MARK: VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        switch player.state {
        case .opening:  print("VLC opening")
        case .buffering: print("VLC buffering")
        case .playing:
            print("VLC playing")
            waitUntilFirstVideoFrameThenConfigurePiP()
        case .paused: print("VLC paused")
        case .stopped: print("VLC stopped")
        case .error: print("VLC error")
        case .ended: print("VLC ended")
        @unknown default: print("VLC unknown")
        }
    }

    private func waitUntilFirstVideoFrameThenConfigurePiP() {
        guard let mp = self.mediaPlayer else { return }
        var checks = 0
        func poll() {
            checks += 1
            let sz = mp.videoSize
            if sz.width > 0 && sz.height > 0 {
                if !self.isPiPConfigured { self.configurePiPIfNeeded() }
            } else if checks < 40 { // 최대 2초 (40 x 50ms)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            } else {
                print("No first frame within timeout; skip PiP configure")
            }
        }
        poll()
    }
}

// MARK: - SwiftUI Wrapper
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 150

    func makeUIView(context: Context) -> RTSPPlayerUIView {
        RTSPPlayerUIView()
    }

    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password)
            }
        } else {
            if uiView.isPlaying() { uiView.pause() }
        }
        // 네트워크 캐싱 변경 로직 필요 시 여기서 재생 재구성
    }

    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: ()) {
        uiView.stop()
    }
}

// MARK: - 품질 정보(선택)
extension RTSPPlayerUIView {
    func detectVideoCodec() -> String? {
        guard let mp = mediaPlayer, mp.isPlaying else { return nil }
        if let media = media {
            let s = media.url?.absoluteString ?? ""
            if s.contains("h264") || s.contains("avc") { return "H.264" }
            if s.contains("h265") || s.contains("hevc") { return "H.265" }
        }
        return "Unknown"
    }
    func getStreamQuality() -> StreamQualityInfo {
        let sz = mediaPlayer?.videoSize ?? .zero
        let isHD = sz.width >= 1280 && sz.height >= 720
        let is4K = sz.width >= 3840 && sz.height >= 2160
        return StreamQualityInfo(
            resolution: sz,
            isHD: isHD,
            is4K: is4K,
            codec: detectVideoCodec() ?? "Unknown",
            hasHardwareDecoding: true
        )
    }
}

struct StreamQualityInfo {
    let resolution: CGSize
    let isHD: Bool
    let is4K: Bool
    let codec: String
    let hasHardwareDecoding: Bool
    var qualityDescription: String { is4K ? "4K UHD" : (isHD ? "HD" : "SD") }
}
