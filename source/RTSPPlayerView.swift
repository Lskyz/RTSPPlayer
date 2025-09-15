import UIKit
import SwiftUI
import VLCKitSPM
import AVKit
import CoreVideo

// VLC 3.6.0 완전 대응 RTSP 플레이어
class RTSPPlayerUIView: UIView {
    
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // PiP 강제 지원을 위한 AVPlayer 브릿지
    private var avPlayer: AVPlayer?
    private var avPlayerItem: AVPlayerItem?
    private var playerLayer: AVPlayerLayer?
    
    // 비디오 동기화를 위한 타이머
    private var syncTimer: Timer?
    private var isVideoReady = false
    
    // VLC 3.6.0 초저지연 최적화 옵션 (30ms 목표)
    private let ultraLowLatencyOptions: [String: String] = [
        "network-caching": "30",           // 30ms 네트워크 캐싱
        "rtsp-caching": "30",             // RTSP 캐싱
        "tcp-caching": "30",              // TCP 캐싱
        "clock-jitter": "30",             // 클럭 지터
        "rtsp-tcp": "",                   // TCP 강제 사용
        "avcodec-hw": "none",             // 하드웨어 디코딩 비활성화
        "clock-synchro": "0",             // 클럭 동기화 비활성화
        "no-audio-time-stretch": "",      // 오디오 시간 조정 비활성화
        "rtsp-frame-buffer-size": "1",    // 프레임 버퍼 최소화
        "avcodec-skiploopfilter": "4",    // 루프 필터 완전 스킵
        "avcodec-fast": "",               // 빠른 디코딩
        "no-osd": "",                     // OSD 비활성화
        "rtsp-mcast-timeout": "1000"      // 멀티캐스트 타임아웃
    ]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupVLCPlayer()
        setupPiPBridge()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupVLCPlayer()
        setupPiPBridge()
    }
    
    // MARK: - VLC 플레이어 설정
    private func setupVLCPlayer() {
        backgroundColor = .black
        
        // VLC 미디어 플레이어 초기화
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        
        // VLC 3.6.0 볼륨 설정 (옵셔널 체이닝)
        if let audio = mediaPlayer?.audio {
            audio.volume = 100
        }
        
        // 델리게이트 설정
        mediaPlayer?.delegate = self
        
        print("✅ VLC 3.6.0 Player initialized")
    }
    
    // MARK: - PiP 브릿지 설정
    private func setupPiPBridge() {
        // 더미 AVPlayer 생성 (PiP 활성화용)
        createDummyAVPlayer()
        
        // PiP 매니저에 등록
        if let avPlayer = avPlayer {
            PictureInPictureManager.shared.setupPiPController(with: avPlayer)
        }
        
        print("✅ PiP Bridge initialized")
    }
    
    private func createDummyAVPlayer() {
        // 무음 더미 비디오 URL 생성
        let dummyURL = createDummyVideoURL()
        avPlayerItem = AVPlayerItem(url: dummyURL)
        avPlayer = AVPlayer(playerItem: avPlayerItem)
        
        // 무한 루프 설정
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayerItem,
            queue: .main
        ) { [weak self] _ in
            self?.avPlayer?.seek(to: .zero)
            self?.avPlayer?.play()
        }
    }
    
    private func createDummyVideoURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let dummyURL = tempDir.appendingPathComponent("dummy_pip.mp4")
        
        // 최소한의 MP4 헤더 데이터 생성
        if !FileManager.default.fileExists(atPath: dummyURL.path) {
            let dummyData = Data([
                // MP4 ftyp box
                0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70,
                0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00,
                0x69, 0x73, 0x6F, 0x6D, 0x69, 0x73, 0x6F, 0x32,
                0x6D, 0x70, 0x34, 0x31, 0x00, 0x00, 0x00, 0x08,
                // mdat box
                0x6D, 0x64, 0x61, 0x74
            ])
            try? dummyData.write(to: dummyURL)
        }
        
        return dummyURL
    }
    
    // MARK: - 스트림 재생
    func play(url: String, username: String? = nil, password: String? = nil) {
        guard let mediaPlayer = mediaPlayer else { return }
        
        // 기존 재생 정지
        stop()
        
        // 인증이 포함된 RTSP URL 생성
        let authenticatedURL = buildRTSPURL(url: url, username: username, password: password)
        
        guard let rtspURL = URL(string: authenticatedURL) else {
            print("❌ Invalid RTSP URL: \(authenticatedURL)")
            return
        }
        
        // VLC Media 생성
        media = VLCMedia(url: rtspURL)
        guard let media = media else {
            print("❌ Failed to create VLC media")
            return
        }
        
        // 초저지연 옵션 적용
        applyLowLatencyOptions(to: media)
        
        // 미디어 설정 및 재생
        mediaPlayer.media = media
        
        // 비동기 재생 시작
        DispatchQueue.global(qos: .userInitiated).async {
            mediaPlayer.play()
            
            DispatchQueue.main.async { [weak self] in
                self?.startPiPBridge()
                print("🎥 RTSP Stream started: \(authenticatedURL)")
            }
        }
    }
    
    private func buildRTSPURL(url: String, username: String?, password: String?) -> String {
        guard let username = username, let password = password,
              !username.isEmpty, !password.isEmpty,
              let urlComponents = URLComponents(string: url) else {
            return url
        }
        
        let components = urlComponents
        var urlString = "\(components.scheme ?? "rtsp")://"
        urlString += "\(username):\(password)@"
        urlString += "\(components.host ?? "")"
        
        if let port = components.port {
            urlString += ":\(port)"
        }
        
        urlString += components.path
        
        if let query = components.query {
            urlString += "?\(query)"
        }
        
        return urlString
    }
    
    private func applyLowLatencyOptions(to media: VLCMedia) {
        // 초저지연 옵션 적용
        for (key, value) in ultraLowLatencyOptions {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // 추가 네트워크 최적화
        media.addOption("--intf=dummy")
        media.addOption("--no-stats")
        media.addOption("--no-video-title-show")
        media.addOption("--no-snapshot-preview")
        media.addOption("--rtsp-kasenna")
        media.addOption("--rtsp-wmserver")
    }
    
    private func startPiPBridge() {
        // AVPlayer 시작 (PiP 가능하게 만들기)
        avPlayer?.play()
        
        // VLC와 AVPlayer 동기화 타이머 시작
        startSyncTimer()
    }
    
    private func startSyncTimer() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.syncPlaybackState()
        }
    }
    
    @objc private func syncPlaybackState() {
        guard let vlcPlayer = mediaPlayer, let avPlayer = avPlayer else { return }
        
        // VLC 재생 상태를 AVPlayer에 동기화
        if vlcPlayer.isPlaying {
            if avPlayer.rate == 0 {
                avPlayer.play()
            }
        } else {
            if avPlayer.rate > 0 {
                avPlayer.pause()
            }
        }
    }
    
    // MARK: - 제어 함수들
    func stop() {
        mediaPlayer?.stop()
        avPlayer?.pause()
        media = nil
        isVideoReady = false
        
        // 타이머 정리
        syncTimer?.invalidate()
        syncTimer = nil
        
        print("🛑 RTSP Stream stopped")
    }
    
    func pause() {
        mediaPlayer?.pause()
        avPlayer?.pause()
    }
    
    func resume() {
        mediaPlayer?.play()
        avPlayer?.play()
    }
    
    func setVolume(_ volume: Int32) {
        // VLC 3.6.0 볼륨 설정
        if let audio = mediaPlayer?.audio {
            audio.volume = volume
        }
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    func captureSnapshot() -> UIImage? {
        // VLC 3.6.0에서 스냅샷 메서드 변경됨 - 대체 방법 사용
        guard let mediaPlayer = mediaPlayer else { return nil }
        
        // VLC 3.6.0 호환 스냅샷 방법
        if mediaPlayer.responds(to: Selector("takeSnapshot")) {
            return mediaPlayer.perform(Selector("takeSnapshot"))?.takeUnretainedValue() as? UIImage
        } else if mediaPlayer.responds(to: Selector("snapShot")) {
            return mediaPlayer.perform(Selector("snapShot"))?.takeUnretainedValue() as? UIImage
        } else {
            // 스냅샷 기능이 없으면 현재 뷰를 캡처
            return captureCurrentView()
        }
    }
    
    private func captureCurrentView() -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        return renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }
    
    func updateLatencySettings(networkCaching: Int) {
        // 재생 중이면 재시작
        if let currentURL = media?.url?.absoluteString, isPlaying() {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.play(url: currentURL)
            }
        }
    }
    
    // PiP 강제 시작
    func forcePiP() {
        PictureInPictureManager.shared.forceStartPiP()
    }
    
    deinit {
        stop()
        syncTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        mediaPlayer = nil
        avPlayer = nil
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ notification: Notification) {
        guard let mediaPlayer = mediaPlayer else { return }
        
        let state = mediaPlayer.state
        print("📺 VLC State: \(state.rawValue)")
        
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .opening:
                print("🔄 Opening stream...")
                
            case .buffering:
                print("⏳ Buffering...")
                
            case .playing:
                print("▶️ Playing - Ultra Low Latency Mode")
                self?.isVideoReady = true
                
            case .paused:
                print("⏸️ Paused")
                
            case .stopped:
                print("⏹️ Stopped")
                self?.isVideoReady = false
                
            case .error:
                print("❌ VLC Error occurred")
                self?.isVideoReady = false
                
            default:
                break
            }
        }
    }
    
    func mediaPlayerTimeChanged(_ notification: Notification) {
        // 시간 변경 이벤트 처리 (필요시)
    }
}

// MARK: - SwiftUI 래퍼
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 30  // 기본 30ms 초저지연
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        if isPlaying {
            if !uiView.isPlaying() {
                uiView.play(url: url, username: username, password: password)
            }
        } else {
            uiView.stop()
        }
        
        // 지연 설정 업데이트
        uiView.updateLatencySettings(networkCaching: networkCaching)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: ()) {
        uiView.stop()
    }
}

// MARK: - PiP 강제 시작 extension
extension RTSPPlayerView {
    func forcePictureInPicture() {
        // PiP 강제 시작
        PictureInPictureManager.shared.forceStartPiP()
    }
}
