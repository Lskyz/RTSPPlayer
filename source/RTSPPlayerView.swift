import UIKit
import SwiftUI
import VLCKitSPM
import AVKit

// UIView 래퍼 for VLCMediaPlayer with Enhanced PiP Support
class RTSPPlayerUIView: UIView {
    
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // PiP 관련
    private var pipManager: PictureInPictureManager?
    private var isPiPConfigured = false
    
    // 저지연 설정 옵션
    private let lowLatencyOptions = [
        "network-caching": "150",        // 네트워크 캐싱 (ms)
        "rtsp-caching": "150",           // RTSP 캐싱
        "tcp-caching": "150",            // TCP 캐싱  
        "realrtsp-caching": "150",       // Real RTSP 캐싱
        "clock-jitter": "150",           // 클럭 지터
        "rtsp-tcp": "",                  // TCP 사용 (UDP 대신)
        "avcodec-hw": "any",             // 하드웨어 디코딩 활성화 (H.264/H.265용)
        "clock-synchro": "0",            // 클럭 동기화 비활성화
        "avcodec-skiploopfilter": "0",   // 루프 필터 활성화 (품질 향상)
        "avcodec-skip-frame": "0",       // 프레임 스킵 비활성화
        "avcodec-skip-idct": "0"         // IDCT 스킵 비활성화
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
        
        // VLC 미디어 플레이어 초기화
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        
        // 볼륨 설정
        mediaPlayer?.audio?.volume = 100
        
        // 플레이어 델리게이트 설정
        mediaPlayer?.delegate = self
        
        print("VLC Player initialized with drawable view")
    }
    
    private func setupPiPManager() {
        pipManager = PictureInPictureManager.shared
        print("PiP Manager configured")
    }
    
    // MARK: - Playback Methods
    
    func play(url: String, username: String? = nil, password: String? = nil) {
        guard let mediaPlayer = mediaPlayer else { return }
        
        // 기존 재생 중지
        if mediaPlayer.isPlaying {
            stop()
        }
        
        // RTSP URL 구성
        var rtspURL = url
        if let username = username, let password = password {
            if let urlComponents = URLComponents(string: url) {
                let components = urlComponents
                var urlString = "\(components.scheme ?? "rtsp")://"
                urlString += "\(username):\(password)@"
                urlString += "\(components.host ?? "")"
                if let port = components.port {
                    urlString += ":\(port)"
                }
                urlString += components.path
                rtspURL = urlString
            }
        }
        
        guard let url = URL(string: rtspURL) else {
            print("Invalid URL: \(rtspURL)")
            return
        }
        
        // VLC Media 생성
        media = VLCMedia(url: url)
        
        // H.264/H.265 최적화 옵션 적용
        applyCodecOptimizations()
        
        // 미디어 설정 및 재생
        mediaPlayer.media = media
        mediaPlayer.play()
        
        print("RTSP Stream started: \(rtspURL)")
        
        // PiP 설정 (재생이 시작된 후)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.configurePiPIfNeeded()
        }
    }
    
    private func applyCodecOptimizations() {
        guard let media = media else { return }
        
        // 저지연 옵션 적용
        for (key, value) in lowLatencyOptions {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // H.264/H.265 전용 최적화 옵션
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        
        // VideoToolbox 하드웨어 디코딩 활성화
        media.addOption("--avcodec-hw=videotoolbox")
        
        // 프레임 처리 최적화
        media.addOption("--no-drop-late-frames")
        media.addOption("--no-skip-frames")
        
        print("H.264/H.265 codec optimizations applied")
    }
    
    private func configurePiPIfNeeded() {
        guard let mediaPlayer = mediaPlayer, 
              mediaPlayer.isPlaying,
              !isPiPConfigured else { return }
        
        // Enhanced PiP 설정
        pipManager?.setupPiPForCodecStream(vlcPlayer: mediaPlayer, streamURL: media?.url?.absoluteString ?? "")
        isPiPConfigured = true
        
        print("Enhanced PiP configured for H.264/H.265 stream")
    }
    
    func stop() {
        mediaPlayer?.stop()
        media = nil
        isPiPConfigured = false
        print("RTSP Stream stopped")
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
    
    // MARK: - Advanced Features
    
    func captureSnapshot() -> UIImage? {
        if let mediaPlayer = mediaPlayer {
            // 뷰의 현재 상태를 UIImage로 캡처
            UIGraphicsBeginImageContextWithOptions(bounds.size, false, UIScreen.main.scale)
            defer { UIGraphicsEndImageContext() }
            
            if let context = UIGraphicsGetCurrentContext() {
                layer.render(in: context)
                return UIGraphicsGetImageFromCurrentImageContext()
            }
        }
        return nil
    }
    
    func updateLatencySettings(networkCaching: Int) {
        // 재생 중인 경우 새 설정으로 재시작
        if let currentMedia = media?.url?.absoluteString,
           mediaPlayer?.isPlaying == true {
            
            let wasPlaying = isPlaying()
            stop()
            
            // 새로운 캐싱 값으로 옵션 업데이트
            var updatedOptions = lowLatencyOptions
            updatedOptions["network-caching"] = "\(networkCaching)"
            updatedOptions["rtsp-caching"] = "\(networkCaching)"
            updatedOptions["tcp-caching"] = "\(networkCaching)"
            updatedOptions["realrtsp-caching"] = "\(networkCaching)"
            
            if wasPlaying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.play(url: currentMedia)
                }
            }
        }
    }
    
    // 현재 스트림 정보 가져오기
    func getStreamInfo() -> [String: Any]? {
        guard let mediaPlayer = mediaPlayer, mediaPlayer.isPlaying else { return nil }
        
        var info: [String: Any] = [:]
        
        // 비디오 정보
        if let videoTrack = mediaPlayer.videoTrackNames.first {
            info["videoTrack"] = videoTrack
        }
        
        // 오디오 정보
        if let audioTrack = mediaPlayer.audioTrackNames.first {
            info["audioTrack"] = audioTrack
        }
        
        // 비디오 크기
        let videoSize = mediaPlayer.videoSize
        if videoSize.width > 0 && videoSize.height > 0 {
            info["videoSize"] = "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }
        
        // 재생 시간
        info["time"] = mediaPlayer.time.intValue
        info["position"] = mediaPlayer.position
        
        return info
    }
    
    // 네트워크 통계
    func getNetworkStats() -> [String: Any]? {
        // VLCKit에서 네트워크 통계를 가져오는 기능은 제한적
        // 실제 구현에서는 별도의 네트워크 모니터링이 필요할 수 있음
        return [
            "isPlaying": isPlaying(),
            "hasVideoTrack": (mediaPlayer?.videoTrackNames.count ?? 0) > 0,
            "hasAudioTrack": (mediaPlayer?.audioTrackNames.count ?? 0) > 0
        ]
    }
    
    deinit {
        stop()
        mediaPlayer = nil
        print("RTSPPlayerUIView deinitialized")
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .opening:
            print("VLC: Opening stream...")
        case .buffering:
            print("VLC: Buffering...")
        case .playing:
            print("VLC: Playing")
            // PiP 설정이 안 되어 있으면 설정
            if !isPiPConfigured {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.configurePiPIfNeeded()
                }
            }
        case .paused:
            print("VLC: Paused")
        case .stopped:
            print("VLC: Stopped")
        case .error:
            print("VLC: Error occurred")
        case .ended:
            print("VLC: Ended")
        @unknown default:
            print("VLC: Unknown state")
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        // 시간 변경 이벤트 처리 (필요한 경우)
    }
}

// MARK: - SwiftUI 래퍼
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 150
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password)
            }
        } else {
            if uiView.isPlaying() {
                uiView.pause()
            }
        }
        
        // 캐싱 설정 업데이트
        uiView.updateLatencySettings(networkCaching: networkCaching)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: ()) {
        uiView.stop()
    }
}

// MARK: - Helper Extensions for Enhanced Functionality
extension RTSPPlayerUIView {
    
    /// H.264/H.265 스트림 감지
    func detectVideoCodec() -> String? {
        guard let mediaPlayer = mediaPlayer,
              mediaPlayer.isPlaying else { return nil }
        
        // VLCKit에서 코덱 정보를 가져오는 것은 제한적
        // 실제로는 미디어 정보에서 코덱을 파싱해야 할 수도 있음
        
        if let media = media {
            // URL에서 코덱 힌트 찾기
            let urlString = media.url?.absoluteString ?? ""
            if urlString.contains("h264") || urlString.contains("avc") {
                return "H.264"
            } else if urlString.contains("h265") || urlString.contains("hevc") {
                return "H.265"
            }
        }
        
        return "Unknown"
    }
    
    /// 스트림 품질 정보
    func getStreamQuality() -> StreamQualityInfo {
        let videoSize = mediaPlayer?.videoSize ?? CGSize.zero
        let isHD = videoSize.width >= 1280 && videoSize.height >= 720
        let is4K = videoSize.width >= 3840 && videoSize.height >= 2160
        
        return StreamQualityInfo(
            resolution: videoSize,
            isHD: isHD,
            is4K: is4K,
            codec: detectVideoCodec() ?? "Unknown",
            hasHardwareDecoding: lowLatencyOptions["avcodec-hw"] == "any"
        )
    }
}

struct StreamQualityInfo {
    let resolution: CGSize
    let isHD: Bool
    let is4K: Bool
    let codec: String
    let hasHardwareDecoding: Bool
    
    var qualityDescription: String {
        if is4K {
            return "4K UHD"
        } else if isHD {
            return "HD"
        } else {
            return "SD"
        }
    }
}
