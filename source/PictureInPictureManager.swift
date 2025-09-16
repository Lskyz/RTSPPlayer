import AVKit
import UIKit
import Combine

// PiP 관리자 프로토콜
protocol PictureInPictureManagerDelegate: AnyObject {
    func pipDidStart()
    func pipDidStop()
    func pipWillStart()
    func pipWillStop()
    func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void)
}

// Picture in Picture 관리 클래스
class PictureInPictureManager: NSObject, ObservableObject {
    
    // Singleton
    static let shared = PictureInPictureManager()
    
    // Published Properties
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    
    // PiP Controller
    private var pipController: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
    }
    
    // PiP 지원 확인
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("PiP Support: \(isPiPSupported)")
    }
    
    // 오디오 세션 설정 (백그라운드 재생을 위해)
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            print("Audio session configured for PiP")
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // PiP 컨트롤러 설정
    func setupPiPController(with player: AVPlayer) {
        // 기존 컨트롤러 정리
        cleanupPiPController()
        
        // 새 플레이어 레이어 생성
        playerLayer = AVPlayerLayer(player: player)
        
        guard let playerLayer = playerLayer else {
            print("Failed to create player layer")
            return
        }
        
        // PiP 컨트롤러 생성
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self
        
        // iOS 14.2+ 자동 PiP 설정
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        // PiP 가능 여부 관찰
        pipController?.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPossible in
                self?.isPiPPossible = isPossible
                print("PiP Possible: \(isPossible)")
            }
            .store(in: &cancellables)
        
        // PiP 활성 상태 관찰
        pipController?.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isPiPActive = isActive
                print("PiP Active: \(isActive)")
            }
            .store(in: &cancellables)
    }
    
    // VLC 플레이어를 위한 커스텀 PiP 설정
    // VLCKit은 직접적인 PiP를 지원하지 않으므로 AVPlayer로 브릿지 필요
    func setupPiPForVLCPlayer(view: UIView) {
        // VLC 비디오 출력을 AVPlayer로 미러링하는 복잡한 과정 필요
        // 실제 구현시 다음과 같은 접근 필요:
        // 1. VLC의 비디오 프레임을 캡처
        // 2. CVPixelBuffer로 변환
        // 3. AVSampleBufferDisplayLayer 사용
        // 4. AVPictureInPictureController와 연결
        
        print("VLC PiP setup requires custom implementation")
        // 이 부분은 실제 프로덕션에서는 더 복잡한 구현이 필요합니다
    }
    
    // PiP 시작
    func startPiP() {
        guard isPiPSupported, isPiPPossible else {
            print("PiP not available")
            return
        }
        
        pipController?.startPictureInPicture()
    }
    
    // PiP 중지
    func stopPiP() {
        guard isPiPActive else { return }
        pipController?.stopPictureInPicture()
    }
    
    // PiP 토글
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // 정리
    private func cleanupPiPController() {
        pipController?.delegate = nil
        pipController = nil
        playerLayer = nil
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

// MARK: - iOS 15+ Sample Buffer Support
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // 재생 상태 처리
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // 렌더 크기 변경 처리
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // 스킵 처리
        completionHandler()
    }
}
