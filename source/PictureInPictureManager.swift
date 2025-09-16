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

// Enhanced Picture in Picture 관리 클래스 - H.264/H.265 직접 지원
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
    
    // VLC Integration
    private var vlcPlayer: VLCMediaPlayer?
    private var frameExtractor: VideoFrameExtractor?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // Frame processing queue
    private let frameQueue = DispatchQueue(label: "com.rtspplayer.frameprocessing", qos: .userInteractive)
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
    
    // MARK: - H.264/H.265 Direct PiP Implementation
    
    /// VLCKit 기반 H.264/H.265 스트림을 위한 PiP 설정
    func setupPiPForCodecStream(vlcPlayer: VLCMediaPlayer, streamURL: String) {
        cleanupPiPController()
        
        self.vlcPlayer = vlcPlayer
        
        // AVSampleBufferDisplayLayer 생성
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        
        guard let displayLayer = sampleBufferDisplayLayer else {
            print("Failed to create sample buffer display layer")
            return
        }
        
        // Display layer 설정
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        
        // Timebase 설정
        setupTimebase(for: displayLayer)
        
        // PiP 컨트롤러 생성 (iOS 15+)
        if #available(iOS 15.0, *) {
            setupSampleBufferPiPController(with: displayLayer)
        } else {
            // iOS 14 이하에서는 AVPlayer 브릿지 사용
            setupLegacyPiPController(vlcPlayer: vlcPlayer)
        }
        
        // Frame extractor 초기화
        frameExtractor = VideoFrameExtractor(vlcPlayer: vlcPlayer)
        frameExtractor?.delegate = self
        frameExtractor?.startFrameExtraction()
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
    
    private func setupLegacyPiPController(vlcPlayer: VLCMediaPlayer) {
        // iOS 14 이하: AVPlayer 브릿지 방식
        // 실제 구현에서는 VLC 출력을 AVPlayer로 브릿지하는 복잡한 과정 필요
        print("Legacy PiP setup for iOS 14 and below")
        // 여기서는 기본 설정만 제공
    }
    
    private func configurePiPController() {
        pipController?.delegate = self
        
        // iOS 14.2+ 자동 PiP 설정
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        // PiP 상태 관찰
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
    
    // MARK: - Frame Processing
    
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        displayQueue.async {
            // Sample buffer를 display layer에 전달
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
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanupPiPController() {
        frameExtractor?.stopFrameExtraction()
        frameExtractor = nil
        
        pipController?.delegate = nil
        pipController = nil
        
        sampleBufferDisplayLayer?.flush()
        sampleBufferDisplayLayer = nil
        
        cancellables.removeAll()
    }
    
    deinit {
        cleanupPiPController()
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP will start")
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP did start")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("PiP did stop")
        isPiPActive = false
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("Failed to start PiP: \(error.localizedDescription)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("Restore UI for PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Sample Buffer Playback Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing {
            vlcPlayer?.play()
        } else {
            vlcPlayer?.pause()
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 라이브 스트림의 경우 무한 시간 범위 반환
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return !(vlcPlayer?.isPlaying ?? false)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // 라이브 스트림에서는 스킵 기능이 제한적
        completionHandler()
    }
}

// MARK: - Video Frame Extractor
class VideoFrameExtractor: NSObject {
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
        
        // VLC에서 프레임 추출을 위한 설정
        // 실제 구현에서는 VLC의 video callback을 사용하여 프레임 데이터를 추출
        setupFrameCallback()
    }
    
    func stopFrameExtraction() {
        isExtracting = false
    }
    
    private func setupFrameCallback() {
        // VLC video callback 설정
        // 주의: 이 부분은 VLCKit의 내부 API 접근이 필요하므로 
        // 실제 구현에서는 더 복잡한 방법이 필요할 수 있습니다
        
        // 대안: VLC의 스냅샷 기능을 주기적으로 사용
        startPeriodicFrameCapture()
    }
    
    private func startPeriodicFrameCapture() {
        extractionQueue.async { [weak self] in
            while self?.isExtracting == true {
                self?.captureCurrentFrame()
                usleep(33333) // ~30 FPS
            }
        }
    }
    
    private func captureCurrentFrame() {
        guard let vlcPlayer = vlcPlayer, vlcPlayer.isPlaying else { return }
        
        // VLC에서 현재 프레임을 UIImage로 캡처
        // 실제 VLCKit에서는 더 효율적인 방법을 사용해야 함
        
        // 임시 구현: VLC drawable view에서 스냅샷 생성
        DispatchQueue.main.async { [weak self] in
            if let drawable = vlcPlayer.drawable as? UIView {
                let image = drawable.asImage()
                self?.processFrameImage(image)
            }
        }
    }
    
    private func processFrameImage(_ image: UIImage) {
        // UIImage를 CVPixelBuffer로 변환
        guard let pixelBuffer = image.toCVPixelBuffer() else { return }
        
        // CVPixelBuffer를 CMSampleBuffer로 변환
        if let sampleBuffer = pixelBuffer.toCMSampleBuffer() {
            delegate?.didExtractFrame(sampleBuffer)
        }
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
        UIGraphicsBeginImageContextWithOptions(bounds.size, false, UIScreen.main.scale)
        defer { UIGraphicsEndImageContext() }
        
        if let context = UIGraphicsGetCurrentContext() {
            layer.render(in: context)
        }
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }
}

extension UIImage {
    func toCVPixelBuffer() -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: pixelData,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
            return nil
        }
        
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        
        UIGraphicsPushContext(context)
        draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        UIGraphicsPopContext()
        
        CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        
        return buffer
    }
}

extension CVPixelBuffer {
    func toCMSampleBuffer() -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: self,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let formatDesc = formatDescription else {
            return nil
        }
        
        var sampleBuffer: CMSampleBuffer?
        let presentationTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000)
        
        let sampleTimingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: 1.0/30.0, preferredTimescale: 1000000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: self,
            formatDescription: formatDesc,
            sampleTiming: [sampleTimingInfo],
            sampleBufferOut: &sampleBuffer
        )
        
        guard createStatus == noErr else {
            return nil
        }
        
        // Display immediately 속성 설정
        if let buffer = sampleBuffer,
           let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0 {
            let attachments = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        return sampleBuffer
    }
}
