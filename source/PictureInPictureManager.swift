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

// 강화된 Picture in Picture 관리 클래스
class PictureInPictureManager: NSObject, ObservableObject {
    
    // Singleton
    static let shared = PictureInPictureManager()
    
    // Published Properties
    @Published var isPiPSupported: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var isPiPPossible: Bool = false
    @Published var forcePiPEnabled: Bool = false
    
    // PiP Controller
    private var pipController: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    
    // 강제 PiP를 위한 Sample Buffer Display Layer
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    
    // Delegate
    weak var delegate: PictureInPictureManagerDelegate?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // 강제 PiP 타이머
    private var forcePiPTimer: Timer?
    
    override init() {
        super.init()
        checkPiPSupport()
        setupAudioSession()
    }
    
    // PiP 지원 확인
    private func checkPiPSupport() {
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("🎥 PiP Support: \(isPiPSupported)")
        
        // iOS 15+ 샘플 버퍼 지원 확인
        if #available(iOS 15.0, *) {
            print("📱 iOS 15+ Sample Buffer PiP supported")
        }
    }
    
    // 오디오 세션 설정 (백그라운드 재생을 위해)
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setActive(true)
            print("🔊 Audio session configured for PiP")
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }
    
    // PiP 컨트롤러 설정 (일반 AVPlayer용)
    func setupPiPController(with player: AVPlayer) {
        self.player = player
        cleanupPiPController()
        
        // 새 플레이어 레이어 생성
        playerLayer = AVPlayerLayer(player: player)
        
        guard let playerLayer = playerLayer else {
            print("❌ Failed to create player layer")
            return
        }
        
        // PiP 컨트롤러 생성
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self
        
        // iOS 14.2+ 자동 PiP 설정
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        setupPiPObservers()
        
        print("✅ PiP Controller setup completed")
    }
    
    // iOS 15+ 샘플 버퍼 기반 PiP 설정 (VLC용)
    @available(iOS 15.0, *)
    func setupSampleBufferPiP() {
        cleanupPiPController()
        
        // 샘플 버퍼 디스플레이 레이어 생성
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = sampleBufferDisplayLayer else { return }
        
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        
        // PiP 컨트롤러 생성 (샘플 버퍼용)
        pipController = AVPictureInPictureController(contentSource: 
            AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
        )
        
        pipController?.delegate = self
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        
        setupPiPObservers()
        forcePiPEnabled = true
        
        print("✅ Sample Buffer PiP setup completed")
    }
    
    // PiP 관찰자 설정
    private func setupPiPObservers() {
        // PiP 가능 여부 관찰
        pipController?.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPossible in
                self?.isPiPPossible = isPossible
                print("📺 PiP Possible: \(isPossible)")
            }
            .store(in: &cancellables)
        
        // PiP 활성 상태 관찰
        pipController?.publisher(for: \.isPictureInPictureActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isPiPActive = isActive
                print("🎭 PiP Active: \(isActive)")
            }
            .store(in: &cancellables)
    }
    
    // PiP 시작 (일반)
    func startPiP() {
        guard isPiPSupported else {
            print("❌ PiP not supported on this device")
            return
        }
        
        // 강제 PiP가 활성화되어 있으면 강제 시작
        if forcePiPEnabled {
            forceStartPiP()
            return
        }
        
        guard isPiPPossible else {
            print("❌ PiP not possible at this moment")
            return
        }
        
        pipController?.startPictureInPicture()
    }
    
    // PiP 강제 시작
    func forceStartPiP() {
        print("🚀 Force starting PiP...")
        
        // iOS 15+ 샘플 버퍼 방식 사용
        if #available(iOS 15.0, *), sampleBufferDisplayLayer != nil {
            forcePiPWithSampleBuffer()
        } else {
            // iOS 14 호환을 위한 대체 방법
            forcePiPWithPlayerLayer()
        }
    }
    
    // 샘플 버퍼로 강제 PiP (iOS 15+)
    @available(iOS 15.0, *)
    private func forcePiPWithSampleBuffer() {
        guard let pipController = pipController else {
            setupSampleBufferPiP()
            
            // 설정 후 다시 시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.pipController?.startPictureInPicture()
            }
            return
        }
        
        // PiP 즉시 시작 시도
        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            // 0.5초 후 재시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pipController?.startPictureInPicture()
            }
        }
    }
    
    // 플레이어 레이어로 강제 PiP (iOS 14 호환)
    private func forcePiPWithPlayerLayer() {
        // 더미 플레이어가 없으면 생성
        if player == nil {
            createDummyPlayer()
        }
        
        guard let pipController = pipController else { return }
        
        // 강제 시작 타이머 설정 (최대 5초 동안 시도)
        var attempts = 0
        forcePiPTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            attempts += 1
            
            if pipController.isPictureInPicturePossible {
                pipController.startPictureInPicture()
                timer.invalidate()
                self?.forcePiPTimer = nil
            } else if attempts > 50 { // 5초 후 포기
                timer.invalidate()
                self?.forcePiPTimer = nil
                print("❌ Failed to force start PiP after 5 seconds")
            }
        }
    }
    
    // 더미 플레이어 생성
    private func createDummyPlayer() {
        // 1초짜리 무음 오디오 파일 생성
        let dummyURL = createDummyAudioURL()
        let playerItem = AVPlayerItem(url: dummyURL)
        
        player = AVPlayer(playerItem: playerItem)
        
        // 무한 반복 설정
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }
        
        setupPiPController(with: player!)
        player?.play()
    }
    
    // 더미 오디오 URL 생성
    private func createDummyAudioURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let dummyURL = tempDir.appendingPathComponent("dummy_audio.m4a")
        
        // 더미 파일이 없으면 생성 (최소한의 무음 오디오)
        if !FileManager.default.fileExists(atPath: dummyURL.path) {
            // 기본 무음 M4A 헤더
            let dummyData = Data([
                0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70,
                0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00
            ])
            try? dummyData.write(to: dummyURL)
        }
        
        return dummyURL
    }
    
    // PiP 중지
    func stopPiP() {
        guard isPiPActive else { return }
        pipController?.stopPictureInPicture()
        forcePiPTimer?.invalidate()
        forcePiPTimer = nil
    }
    
    // PiP 토글
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }
    
    // 샘플 버퍼 enqueue (VLC 프레임 전달용)
    @available(iOS 15.0, *)
    func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        sampleBufferDisplayLayer?.enqueue(sampleBuffer)
    }
    
    // 정리
    private func cleanupPiPController() {
        forcePiPTimer?.invalidate()
        forcePiPTimer = nil
        
        pipController?.delegate = nil
        pipController = nil
        playerLayer = nil
        sampleBufferDisplayLayer = nil
        cancellables.removeAll()
    }
    
    deinit {
        cleanupPiPController()
        player?.pause()
        player = nil
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎭 PiP will start")
        delegate?.pipWillStart()
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎭 PiP did start")
        isPiPActive = true
        delegate?.pipDidStart()
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎭 PiP will stop")
        delegate?.pipWillStop()
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎭 PiP did stop")
        isPiPActive = false
        delegate?.pipDidStop()
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ Failed to start PiP: \(error.localizedDescription)")
        
        // 실패시 강제 PiP 다시 시도
        if forcePiPEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.forceStartPiP()
            }
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("🔄 Restore UI for PiP")
        delegate?.pipRestoreUserInterface(completionHandler: completionHandler)
    }
}

// MARK: - iOS 15+ Sample Buffer Playback Delegate
@available(iOS 15.0, *)
extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        print("🎮 PiP set playing: \(playing)")
        // VLC 재생 상태와 동기화
        if playing {
            // 재생 신호를 VLC로 전달
        } else {
            // 일시정지 신호를 VLC로 전달
        }
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 라이브 스트림이므로 무한 범위 반환
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // VLC 재생 상태 반환 (실제 구현시 VLC 상태와 연동)
        return false
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("📐 PiP render size changed: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        print("⏭️ PiP skip by interval: \(skipInterval.seconds)")
        // 라이브 스트림에서는 스킵 불가
        completionHandler()
    }
}
