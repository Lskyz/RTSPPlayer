import UIKit
import SwiftUI
import VLCKit  // VLCKit 대신 MobileVLCKit 사용
import AVKit

// UIView 래퍼 for VLCMediaPlayer
class RTSPPlayerUIView: UIView {
    
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // 저지연 설정 옵션
    private let lowLatencyOptions = [
        "network-caching": "150",        // 네트워크 캐싱 (ms)
        "rtsp-caching": "150",           // RTSP 캐싱
        "tcp-caching": "150",            // TCP 캐싱  
        "realrtsp-caching": "150",       // Real RTSP 캐싱
        "clock-jitter": "150",           // 클럭 지터
        "rtsp-tcp": "",                  // TCP 사용 (UDP 대신)
        "avcodec-hw": "none",            // 하드웨어 디코딩 비활성화 (저지연을 위해)
        "clock-synchro": "0"             // 클럭 동기화 비활성화
    ]
    
    // PiP를 위한 AVPlayerLayer
    var playerLayer: AVPlayerLayer?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
    }
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // VLC 미디어 플레이어 초기화
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = self
        
        // 볼륨 설정 (안전한 방식으로 수정)
        if let audio = mediaPlayer?.audio {
            audio.volume = 100
        }
        
        // VLCLibrary 초기화 확인 (MobileVLCKit에서 중요)
        _ = VLCLibrary.shared()
        
        print("VLC Media Player initialized successfully")
    }
    
    func play(url: String, username: String? = nil, password: String? = nil) {
        guard let mediaPlayer = mediaPlayer else {
            print("Media player not initialized")
            return
        }
        
        // RTSP URL 구성
        var rtspURL = url
        if let username = username, let password = password {
            // 인증이 필요한 경우 URL에 포함
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
        
        print("Starting RTSP stream: \(rtspURL)")
        
        // VLC Media 생성
        media = VLCMedia(url: url)
        
        guard let media = media else {
            print("Failed to create VLC Media")
            return
        }
        
        // 저지연 옵션 적용
        for (key, value) in lowLatencyOptions {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // 추가 네트워크 옵션
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        
        // 미디어 설정 및 재생
        mediaPlayer.media = media
        
        // 재생 시작
        let result = mediaPlayer.play()
        if result {
            print("RTSP Stream started successfully: \(rtspURL)")
        } else {
            print("Failed to start RTSP Stream: \(rtspURL)")
        }
    }
    
    func stop() {
        guard let mediaPlayer = mediaPlayer else { return }
        
        mediaPlayer.stop()
        media = nil
        print("RTSP Stream stopped")
    }
    
    func pause() {
        guard let mediaPlayer = mediaPlayer else { return }
        mediaPlayer.pause()
    }
    
    func resume() {
        guard let mediaPlayer = mediaPlayer else { return }
        mediaPlayer.play()
    }
    
    func setVolume(_ volume: Int32) {
        // 안전한 볼륨 설정
        guard let mediaPlayer = mediaPlayer,
              let audio = mediaPlayer.audio else { return }
        
        let clampedVolume = max(0, min(200, volume)) // 0-200 범위로 제한
        audio.volume = clampedVolume
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    // 스냅샷 캡처 (대안 방법 사용)
    func captureSnapshot() -> UIImage? {
        guard let mediaPlayer = mediaPlayer else { return nil }
        
        // VLCKit의 최신 버전에서는 takeSnapshot 메서드 사용
        // 뷰의 현재 상태를 UIImage로 캡처
        UIGraphicsBeginImageContextWithOptions(bounds.size, false, UIScreen.main.scale)
        defer { UIGraphicsEndImageContext() }
        
        if let context = UIGraphicsGetCurrentContext() {
            layer.render(in: context)
            return UIGraphicsGetImageFromCurrentImageContext()
        }
        
        return nil
    }
    
    // 저지연 옵션 업데이트
    func updateLatencySettings(networkCaching: Int) {
        // 현재 재생 중인 미디어의 URL 저장
        guard let currentMedia = media,
              let currentURL = currentMedia.url?.absoluteString else { return }
        
        let wasPlaying = mediaPlayer?.isPlaying ?? false
        
        if wasPlaying {
            stop()
            
            // 약간의 지연 후 재시작
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(url: currentURL)
            }
        }
    }
    
    deinit {
        stop()
        mediaPlayer = nil
        print("RTSPPlayerUIView deinitialized")
    }
}

// SwiftUI 래퍼
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
        // URL이 변경되었거나 재생 상태가 변경된 경우에만 업데이트
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password)
            }
        } else {
            if uiView.isPlaying() {
                uiView.pause()
            }
        }
        
        // 캐싱 설정 업데이트 (필요시에만)
        // uiView.updateLatencySettings(networkCaching: networkCaching)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: ()) {
        uiView.stop()
    }
}
