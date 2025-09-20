import UIKit
import SwiftUI
import VLCKitSPM
import AVKit

// MARK: - RTSP Player UIView with Independent PiP Support
class RTSPPlayerUIView: UIView {
    
    // VLC Components
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // Video Container
    private var videoContainerView: UIView?
    private var containerViewConstraints: [NSLayoutConstraint] = []
    
    // PiP Components - 독립적인 관리
    private let pipManager = PictureInPictureManager.shared
    private var isPiPSetup = false
    
    // Stream Info
    private var currentStreamURL: String?
    private var streamUsername: String?
    private var streamPassword: String?
    private var streamCaching: Int = 150
    
    // Callbacks
    var onStreamInfo: ((StreamInfo) -> Void)?
    var onPiPStatusChanged: ((Bool) -> Void)?
    
    // UI State - PiP로 인한 숨김 상태 관리
    private var isHiddenForPiP = false {
        didSet {
            updateVisibility()
        }
    }
    
    // Low Latency Options
    private let lowLatencyOptions: [String: String] = [
        "network-caching": "150",
        "rtsp-caching": "150", 
        "tcp-caching": "150",
        "realrtsp-caching": "150",
        "clock-jitter": "150",
        "rtsp-tcp": "",
        "avcodec-hw": "videotoolbox",
        "clock-synchro": "0",
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0",
        "avcodec-threads": "4",
        "sout-mux-caching": "10",
        "live-caching": "150"
    ]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
        setupPiPDelegate()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
        setupPiPDelegate()
    }
    
    // MARK: - Setup
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // Create video container view
        setupVideoContainer()
        
        // Initialize VLC Media Player
        mediaPlayer = VLCMediaPlayer()
        mediaPlayer?.drawable = videoContainerView
        mediaPlayer?.audio?.volume = 100
        mediaPlayer?.delegate = self
        
        print("VLC Player initialized for independent PiP")
    }
    
    private func setupVideoContainer() {
        videoContainerView = UIView()
        videoContainerView?.backgroundColor = .black
        videoContainerView?.translatesAutoresizingMaskIntoConstraints = false
        
        guard let containerView = videoContainerView else { return }
        
        addSubview(containerView)
        
        containerViewConstraints = [
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        
        NSLayoutConstraint.activate(containerViewConstraints)
        
        print("Video container setup completed")
    }
    
    private func setupPiPDelegate() {
        // PiP 매니저 델리게이트 설정
        pipManager.delegate = self
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        videoContainerView?.frame = bounds
        
        // VLC drawable 업데이트 (PiP로 숨겨져 있지 않을 때만)
        if let player = mediaPlayer, player.isPlaying, !isHiddenForPiP {
            DispatchQueue.main.async {
                player.drawable = self.videoContainerView
            }
        }
    }
    
    // MARK: - Playback Control
    
    func play(url: String, username: String? = nil, password: String? = nil, networkCaching: Int = 150) {
        // Stop current playback
        if mediaPlayer?.isPlaying == true {
            stop()
        }
        
        // Store stream info for PiP
        currentStreamURL = url
        streamUsername = username
        streamPassword = password
        streamCaching = networkCaching
        
        // Build authenticated URL
        let authenticatedURL = buildAuthenticatedURL(url: url, username: username, password: password)
        
        guard let mediaURL = URL(string: authenticatedURL) else {
            print("Invalid URL: \(authenticatedURL)")
            return
        }
        
        // Create VLC Media
        media = VLCMedia(url: mediaURL)
        
        // Apply optimizations
        applyStreamOptimizations(caching: networkCaching)
        
        // Set media and play
        mediaPlayer?.media = media
        
        DispatchQueue.main.async { [weak self] in
            self?.mediaPlayer?.drawable = self?.videoContainerView
            self?.mediaPlayer?.play()
            
            print("Starting stream: \(url)")
            
            // Setup independent PiP after stream starts
            self?.setupIndependentPiPAfterDelay()
        }
    }
    
    private func buildAuthenticatedURL(url: String, username: String?, password: String?) -> String {
        guard let username = username, let password = password else { return url }
        
        if let urlComponents = URLComponents(string: url) {
            let components = urlComponents
            var urlString = "\(components.scheme ?? "rtsp")://"
            urlString += "\(username):\(password)@"
            urlString += "\(components.host ?? "")"
            if let port = components.port {
                urlString += ":\(port)"
            }
            urlString += components.path
            return urlString
        }
        
        return url
    }
    
    private func applyStreamOptimizations(caching: Int) {
        guard let media = media else { return }
        
        var options = lowLatencyOptions
        options["network-caching"] = "\(caching)"
        options["rtsp-caching"] = "\(caching)"
        options["tcp-caching"] = "\(caching)"
        options["realrtsp-caching"] = "\(caching)"
        options["live-caching"] = "\(caching)"
        
        for (key, value) in options {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional optimizations for independent PiP
        media.addOption("--intf=dummy")
        media.addOption("--no-audio-time-stretch")
        media.addOption("--no-network-synchronisation")
        media.addOption("--no-drop-late-frames")
        
        print("Applied optimizations for independent PiP with caching: \(caching)ms")
    }
    
    private func setupIndependentPiPAfterDelay() {
        guard let mediaPlayer = mediaPlayer,
              let streamURL = currentStreamURL else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard mediaPlayer.isPlaying else { return }
            
            // 독립적인 PiP 설정 (메인 플레이어와 스트림 URL 전달)
            self?.pipManager.setupIndependentPiP(for: mediaPlayer, streamURL: streamURL)
            self?.isPiPSetup = true
            
            print("Independent PiP setup completed")
        }
    }
    
    // MARK: - Playback Control Methods
    
    func stop() {
        // Stop PiP first if active
        if pipManager.isPiPActive {
            pipManager.stopPiP()
        }
        
        mediaPlayer?.stop()
        media = nil
        currentStreamURL = nil
        streamUsername = nil
        streamPassword = nil
        isPiPSetup = false
        isHiddenForPiP = false
        
        print("Stream stopped and PiP cleaned up")
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
    
    // MARK: - PiP Control Methods
    
    func startPictureInPicture() {
        guard isPiPSetup, pipManager.canStartPiP else {
            print("Cannot start PiP - not ready")
            return
        }
        
        pipManager.startPiP()
    }
    
    func stopPictureInPicture() {
        pipManager.stopPiP()
    }
    
    func togglePictureInPicture() {
        pipManager.togglePiP()
    }
    
    var isPiPActive: Bool {
        return pipManager.isPiPActive
    }
    
    var isPiPPossible: Bool {
        return pipManager.isPiPPossible && isPiPSetup
    }
    
    var canStartPiP: Bool {
        return pipManager.canStartPiP && isPiPSetup
    }
    
    // MARK: - Visibility Management
    
    private func updateVisibility() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.isHiddenForPiP {
                // PiP 활성화시 메인 플레이어 숨김
                self.videoContainerView?.alpha = 0.0
                self.backgroundColor = .clear
                
                // VLC drawable을 nil로 설정하여 렌더링 중단
                self.mediaPlayer?.drawable = nil
                
                print("Main player hidden for PiP")
            } else {
                // PiP 비활성화시 메인 플레이어 표시
                self.videoContainerView?.alpha = 1.0
                self.backgroundColor = .black
                
                // VLC drawable 복원
                if let player = self.mediaPlayer, player.isPlaying {
                    player.drawable = self.videoContainerView
                }
                
                print("Main player restored from PiP")
            }
        }
    }
    
    // MARK: - Stream Info
    
    func getStreamInfo() -> StreamInfo? {
        guard let mediaPlayer = mediaPlayer, mediaPlayer.isPlaying else { return nil }
        
        var info = StreamInfo()
        
        let videoSize = mediaPlayer.videoSize
        info.resolution = CGSize(width: CGFloat(videoSize.width), height: CGFloat(videoSize.height))
        info.videoCodec = detectVideoCodec()
        info.position = mediaPlayer.position
        info.time = TimeInterval(mediaPlayer.time.intValue / 1000)
        info.isBuffering = mediaPlayer.state == .buffering
        
        // PiP 상태 정보 추가
        info.isPiPActive = isPiPActive
        info.isPiPPossible = isPiPPossible
        info.pipStatus = pipManager.pipStatus
        
        // 콜백 호출
        onStreamInfo?(info)
        onPiPStatusChanged?(isPiPActive)
        
        return info
    }
    
    private func detectVideoCodec() -> String {
        if let media = media {
            let url = media.url?.absoluteString ?? ""
            if url.contains("h264") || url.contains("avc") {
                return "H.264/AVC"
            } else if url.contains("h265") || url.contains("hevc") {
                return "H.265/HEVC"
            }
        }
        return "Unknown"
    }
    
    // MARK: - Cleanup
    
    deinit {
        stop()
        
        NSLayoutConstraint.deactivate(containerViewConstraints)
        containerViewConstraints.removeAll()
        
        videoContainerView?.removeFromSuperview()
        videoContainerView = nil
        
        mediaPlayer = nil
        print("RTSPPlayerUIView deinitialized")
    }
}

// MARK: - VLCMediaPlayerDelegate
extension RTSPPlayerUIView: VLCMediaPlayerDelegate {
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        switch player.state {
        case .opening:
            print("VLC: Opening stream...")
            
        case .buffering:
            let bufferPercent = player.position * 100
            print("VLC: Buffering... \(Int(bufferPercent))%")
            
        case .playing:
            print("VLC: Playing - Video size: \(player.videoSize)")
            
            DispatchQueue.main.async { [weak self] in
                self?.videoContainerView?.setNeedsLayout()
                self?.setNeedsLayout()
                
                // 스트림 정보 업데이트
                _ = self?.getStreamInfo()
            }
            
        case .paused:
            print("VLC: Paused")
            
        case .stopped:
            print("VLC: Stopped")
            
        case .error:
            print("VLC: Error occurred")
            
        case .ended:
            print("VLC: Ended")
            
        case .esAdded:
            print("VLC: Elementary stream added")
            
        @unknown default:
            print("VLC: Unknown state")
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Time updates can be handled here if needed
        DispatchQueue.main.async { [weak self] in
            _ = self?.getStreamInfo()
        }
    }
}

// MARK: - PictureInPictureManagerDelegate
extension RTSPPlayerUIView: PictureInPictureManagerDelegate {
    
    func pipWillStart() {
        print("Main player: PiP will start")
    }
    
    func pipDidStart() {
        print("Main player: PiP did start")
        onPiPStatusChanged?(true)
    }
    
    func pipWillStop() {
        print("Main player: PiP will stop")
    }
    
    func pipDidStop() {
        print("Main player: PiP did stop")
        onPiPStatusChanged?(false)
    }
    
    func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void) {
        // UI 복원 처리
        DispatchQueue.main.async { [weak self] in
            self?.isHiddenForPiP = false
            completionHandler(true)
        }
    }
    
    func pipShouldHideMainPlayer(_ hide: Bool) {
        // 핵심: PiP 상태에 따른 메인 플레이어 숨김/표시 제어
        print("Main player should be \(hide ? "hidden" : "visible") for PiP")
        isHiddenForPiP = hide
    }
}

// MARK: - Enhanced Stream Info with PiP Status
struct StreamInfo {
    var state: String = "Idle"
    var resolution: CGSize = .zero
    var videoCodec: String = "Unknown"
    var audioTrack: String?
    var position: Float = 0.0
    var time: TimeInterval = 0
    var isBuffering: Bool = false
    var droppedFrames: Int = 0
    var lastError: String?
    var cpuUsage: Float = 0.0
    var memoryUsage: Float = 0.0
    var fps: Float = 0.0
    
    // PiP 관련 정보
    var isPiPActive: Bool = false
    var isPiPPossible: Bool = false
    var pipStatus: String = "Inactive"
    
    var qualityDescription: String {
        if resolution.width >= 3840 {
            return "4K UHD"
        } else if resolution.width >= 1920 {
            return "Full HD"
        } else if resolution.width >= 1280 {
            return "HD"
        } else if resolution.width > 0 {
            return "SD"
        } else {
            return "Unknown"
        }
    }
    
    var resolutionString: String {
        if resolution.width > 0 && resolution.height > 0 {
            return "\(Int(resolution.width))x\(Int(resolution.height))"
        }
        return "N/A"
    }
    
    var pipStatusDescription: String {
        if isPiPActive {
            return "활성 (독립 실행)"
        } else if isPiPPossible {
            return "준비됨"
        } else {
            return "비활성"
        }
    }
}

// MARK: - SwiftUI Wrapper
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 150
    
    // 콜백 클로저들 - 이제 직접 매개변수로 받음
    var onStreamInfoCallback: ((StreamInfo) -> Void)?
    var onPiPStatusCallback: ((Bool) -> Void)?
    
    // 생성자 추가 - 콜백들을 직접 받을 수 있도록
    init(url: Binding<String>, 
         isPlaying: Binding<Bool>, 
         username: String? = nil, 
         password: String? = nil, 
         networkCaching: Int = 150,
         onStreamInfo: ((StreamInfo) -> Void)? = nil,
         onPiPStatus: ((Bool) -> Void)? = nil) {
        self._url = url
        self._isPlaying = isPlaying
        self.username = username
        self.password = password
        self.networkCaching = networkCaching
        self.onStreamInfoCallback = onStreamInfo
        self.onPiPStatusCallback = onPiPStatus
    }
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        
        // 콜백 설정
        playerView.onStreamInfo = onStreamInfoCallback
        playerView.onPiPStatusChanged = onPiPStatusCallback
        
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        // 콜백 업데이트
        uiView.onStreamInfo = onStreamInfoCallback
        uiView.onPiPStatusChanged = onPiPStatusCallback
        
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password, networkCaching: networkCaching)
            }
        } else {
            if uiView.isPlaying() {
                uiView.pause()
            }
        }
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: Coordinator) {
        uiView.stop()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        let parent: RTSPPlayerView
        
        init(_ parent: RTSPPlayerView) {
            self.parent = parent
        }
    }
}
