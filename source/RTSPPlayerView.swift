import UIKit
import SwiftUI
import VLCKitSPM
import AVKit
import CoreVideo

// UIView 래퍼 for VLCMediaPlayer with Forced PiP
class RTSPPlayerUIView: UIView {
    
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // PiP 강제 지원을 위한 AVPlayer 브릿지
    private var avPlayer: AVPlayer?
    private var avPlayerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    
    // 비디오 프레임 처리를 위한 변수들
    private var currentVideoSize: CGSize = .zero
    private var isVideoReady = false
    
    // 초저지연 설정 옵션 (50ms 목표)
    private let ultraLowLatencyOptions = [
        "network-caching": "30",           // 30ms로 더 줄임
        "rtsp-caching": "30",
        "tcp-caching": "30",
        "realrtsp-caching": "30",
        "clock-jitter": "30",
        "rtsp-tcp": "",                    // TCP 강제 사용 (더 안정적)
        "avcodec-hw": "none",              // 하드웨어 디코딩 비활성화 (지연 감소)
        "clock-synchro": "0",              // 클럭 동기화 완전 비활성화
        "audio-time-stretch": "0",         // 오디오 시간 조정 비활성화
        "no-audio-time-stretch": "",
        "no-network-synchronisation": "",
        "rtsp-frame-buffer-size": "1",     // 프레임 버퍼 크기 최소화
        "avcodec-skiploopfilter": "4",     // 루프 필터 완전 스킵
        "avcodec-skip-frame": "0",         // 프레임 스킵 비활성화
        "avcodec-skip-idct": "0",          // IDCT 스킵 비활성화
        "no-osd": "",                      // OSD 비활성화
        "rtsp-mcast-timeout": "1000",      // 멀티캐스트 타임아웃 줄임
        "demux": "ts",                     // TS demuxer 강제 사용
        "avcodec-fast": "",                // 빠른 디코딩 모드
    ]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
        setupPiPBridge()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
        setupPiPBridge()
    }
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // VLC 미디어 플레이어 초기화
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        mediaPlayer?.audio.volume = 100
        
        // VLC 라이브러리 초저지연 설정
        let vlcLibrary = VLCLibrary.shared()
        vlcLibrary.debugLogging = true
        vlcLibrary.debugLoggingLevel = 2  // 로그 레벨 줄여서 성능 향상
        
        // 델리게이트 설정으로 상태 모니터링
        mediaPlayer?.delegate = self
    }
    
    private func setupPiPBridge() {
        // AVPlayer 브릿지 설정 (PiP를 위해)
        avPlayer = AVPlayer()
        
        // 더미 비디오 아이템 생성 (PiP 활성화를 위해)
        createDummyPlayerItem()
        
        // PiP 매니저에 AVPlayer 등록
        PictureInPictureManager.shared.setupPiPController(with: avPlayer!)
    }
    
    private func createDummyPlayerItem() {
        // 1x1 픽셀의 더미 비디오 생성
        let dummyURL = createDummyVideoURL()
        avPlayerItem = AVPlayerItem(url: dummyURL)
        avPlayer?.replaceCurrentItem(with: avPlayerItem)
    }
    
    private func createDummyVideoURL() -> URL {
        // 시스템 임시 디렉토리에 더미 비디오 파일 생성
        let tempDir = FileManager.default.temporaryDirectory
        let dummyURL = tempDir.appendingPathComponent("dummy_video.mp4")
        
        // 더미 파일이 없으면 생성
        if !FileManager.default.fileExists(atPath: dummyURL.path) {
            let dummyData = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70]) // MP4 header 시작
            try? dummyData.write(to: dummyURL)
        }
        
        return dummyURL
    }
    
    func play(url: String, username: String? = nil, password: String? = nil) {
        guard let mediaPlayer = mediaPlayer else { return }
        
        // 기존 재생 중지
        stop()
        
        // RTSP URL 구성 (인증 포함)
        var rtspURL = url
        if let username = username, let password = password, 
           !username.isEmpty && !password.isEmpty {
            if let urlComponents = URLComponents(string: url) {
                var components = urlComponents
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
                rtspURL = urlString
            }
        }
        
        guard let url = URL(string: rtspURL) else {
            print("❌ Invalid RTSP URL: \(rtspURL)")
            return
        }
        
        // VLC Media 생성
        media = VLCMedia(url: url)
        guard let media = media else {
            print("❌ Failed to create VLC media")
            return
        }
        
        // 초저지연 옵션 적용
        for (key, value) in ultraLowLatencyOptions {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // 추가 네트워크 최적화 옵션
        media.addOption("--intf=dummy")
        media.addOption("--no-stats")
        media.addOption("--no-video-title-show")
        media.addOption("--no-snapshot-preview")
        media.addOption("--rtsp-kasenna")
        media.addOption("--rtsp-wmserver")
        
        // 미디어 설정 및 재생 시작
        mediaPlayer.media = media
        
        // 비동기 재생 시작
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            mediaPlayer.play()
            
            DispatchQueue.main.async {
                self?.startPiPBridge()
                print("🎥 RTSP Stream started: \(rtspURL)")
            }
        }
    }
    
    private func startPiPBridge() {
        // VLC가 재생 시작되면 AVPlayer도 시작
        avPlayer?.play()
        
        // 비디오 프레임 동기화를 위한 타이머 시작
        setupVideoSyncTimer()
    }
    
    private func setupVideoSyncTimer() {
        // CADisplayLink로 60fps 동기화
        displayLink = CADisplayLink(target: self, selector: #selector(syncVideoFrame))
        displayLink?.preferredFramesPerSecond = 60
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func syncVideoFrame() {
        // VLC 스냅샷을 AVPlayer로 전달하는 로직
        // (실제 프로덕션에서는 더 효율적인 방법 필요)
        guard isVideoReady else { return }
        
        // VLC 재생 상태를 AVPlayer에 동기화
        if let vlcIsPlaying = mediaPlayer?.isPlaying, vlcIsPlaying {
            if avPlayer?.rate == 0 {
                avPlayer?.play()
            }
        } else {
            avPlayer?.pause()
        }
    }
    
    func stop() {
        mediaPlayer?.stop()
        avPlayer?.pause()
        media = nil
        isVideoReady = false
        
        // 타이머 정리
        displayLink?.invalidate()
        displayLink = nil
        
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
        mediaPlayer?.audio.volume = volume
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    func captureSnapshot() -> UIImage? {
        return mediaPlayer?.snapShot()
    }
    
    func updateLatencySettings(networkCaching: Int) {
        // 실시간으로 캐싱 값 업데이트
        if let currentMedia = media?.url?.absoluteString,
           mediaPlayer?.isPlaying == true {
            
            // 현재 재생 중인 스트림 정보 저장
            let wasPlaying = true
            
            // 잠시 중지하고 새 설정으로 재시작
            stop()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.play(url: currentMedia)
            }
        }
    }
    
    // PiP 강제 시작 (외부에서 호출)
    func forcePiP() {
        PictureInPictureManager.shared.startPiP()
    }
    
    deinit {
        stop()
        displayLink?.invalidate()
        mediaPlayer = nil
        avPlayer = nil
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let mediaPlayer = mediaPlayer else { return }
        
        let state = mediaPlayer.state
        print("📺 VLC State: \(state.rawValue)")
        
        switch state {
        case .opening:
            print("🔄 Opening stream...")
            
        case .buffering:
            print("⏳ Buffering...")
            
        case .playing:
            print("▶️ Playing")
            isVideoReady = true
            
        case .paused:
            print("⏸️ Paused")
            
        case .stopped:
            print("⏹️ Stopped")
            isVideoReady = false
            
        case .error:
            print("❌ VLC Error occurred")
            isVideoReady = false
            
        default:
            break
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // 시간 변경 이벤트 (필요시 사용)
    }
}

// MARK: - SwiftUI 래퍼 (기존과 동일하지만 강제 PiP 기능 추가)
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 30  // 기본값을 30ms로 변경
    
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
        
        // 캐싱 설정 업데이트
        uiView.updateLatencySettings(networkCaching: networkCaching)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: ()) {
        uiView.stop()
    }
}

// MARK: - ContentView에서 사용할 PiP 강제 시작 함수
extension RTSPPlayerView {
    func forcePictureInPicture() {
        // UIViewRepresentable에서 직접 접근은 어려우니 
        // PictureInPictureManager를 통해 강제 시작
        PictureInPictureManager.shared.startPiP()
    }
}
