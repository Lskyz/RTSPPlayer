import UIKit
import SwiftUI
import VLCKitSPM
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
        
        // 볼륨 설정
        mediaPlayer?.audio.volume = 100
        
        // 디버깅을 위한 로그 레벨 설정
        mediaPlayer?.libraryInstance.debugLogging = true
        mediaPlayer?.libraryInstance.debugLoggingLevel = 4
    }
    
    func play(url: String, username: String? = nil, password: String? = nil) {
        guard let mediaPlayer = mediaPlayer else { return }
        
        // RTSP URL 구성
        var rtspURL = url
        if let username = username, let password = password {
            // 인증이 필요한 경우 URL에 포함
            if let urlComponents = URLComponents(string: url) {
                var components = urlComponents
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
        
        // 저지연 옵션 적용
        for (key, value) in lowLatencyOptions {
            if value.isEmpty {
                media?.addOption("--\(key)")
            } else {
                media?.addOption("--\(key)=\(value)")
            }
        }
        
        // 추가 네트워크 옵션
        media?.addOption("--intf=dummy")
        media?.addOption("--no-audio-time-stretch")
        media?.addOption("--no-network-synchronisation")
        
        // 미디어 설정 및 재생
        mediaPlayer.media = media
        mediaPlayer.play()
        
        print("RTSP Stream started: \(rtspURL)")
    }
    
    func stop() {
        mediaPlayer?.stop()
        media = nil
        print("RTSP Stream stopped")
    }
    
    func pause() {
        mediaPlayer?.pause()
    }
    
    func resume() {
        mediaPlayer?.play()
    }
    
    func setVolume(_ volume: Int32) {
        mediaPlayer?.audio.volume = volume
    }
    
    func isPlaying() -> Bool {
        return mediaPlayer?.isPlaying ?? false
    }
    
    // 스냅샷 캡처
    func captureSnapshot() -> UIImage? {
        return mediaPlayer?.snapShot()
    }
    
    // 저지연 옵션 업데이트
    func updateLatencySettings(networkCaching: Int) {
        // 재생 중인 경우 중지하고 새 설정으로 재시작
        if let currentMedia = media?.url?.absoluteString,
           mediaPlayer?.isPlaying == true {
            stop()
            
            // 새로운 캐싱 값으로 옵션 업데이트
            var updatedOptions = lowLatencyOptions
            updatedOptions["network-caching"] = "\(networkCaching)"
            updatedOptions["rtsp-caching"] = "\(networkCaching)"
            updatedOptions["tcp-caching"] = "\(networkCaching)"
            updatedOptions["realrtsp-caching"] = "\(networkCaching)"
            
            // 재시작
            play(url: currentMedia)
        }
    }
    
    deinit {
        stop()
        mediaPlayer = nil
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
