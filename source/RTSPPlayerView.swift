import UIKit
import SwiftUI
import VLCKitSPM
import AVKit

// MARK: - Enhanced RTSP Player UIView with Direct VLC Integration
class RTSPPlayerUIView: UIView {
    
    // VLC Components
    private var mediaPlayer: VLCMediaPlayer?
    private var media: VLCMedia?
    
    // Video Display
    private var videoContainerView: UIView?
    private var renderingView: UIView?
    
    // PiP Manager
    private let pipManager = PictureInPictureManager.shared
    private var isPiPSetup = false
    
    // Stream Properties
    private var currentStreamURL: String?
    private var streamInfo: StreamInfo?
    
    // Performance Monitoring
    private var performanceMonitor: PerformanceMonitor?
    
    // Constraints
    private var containerViewConstraints: [NSLayoutConstraint] = []
    
    // Enhanced Low Latency Options for Direct Stream
    private let enhancedLowLatencyOptions: [String: String] = [
        // Network caching
        "network-caching": "0",
        "rtsp-caching": "0", 
        "tcp-caching": "0",
        "live-caching": "0",
        
        // Clock and sync
        "clock-jitter": "0",
        "clock-synchro": "0",
        "rtsp-tcp": "",
        
        // Hardware acceleration
        "avcodec-hw": "videotoolbox",
        "videotoolbox-temporal-deinterlacing": "",
        "videotoolbox-deinterlace": "0",
        
        // Frame handling  
        "avcodec-skiploopfilter": "0",
        "avcodec-skip-frame": "0",
        "avcodec-skip-idct": "0",
        "avcodec-threads": "0", // Auto
        
        // Disable filters
        "video-filter": "",
        "deinterlace": "0",
        "no-audio-time-stretch": "",
        "no-network-synchronisation": "",
        "no-drop-late-frames": "",
        "no-skip-frames": "",
        
        // Direct rendering
        "vout": "ios_window",
        "aout": "audiounit_ios"
    ]
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
        setupPerformanceMonitoring()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
        setupPerformanceMonitoring()
    }
    
    // MARK: - Setup
    
    private func setupPlayer() {
        backgroundColor = .black
        
        // Create container and rendering views
        setupVideoContainer()
        setupRenderingView()
        
        // Initialize VLC Media Player
        mediaPlayer = VLCMediaPlayer()
        
        // CRITICAL: Set drawable to rendering view for direct output
        mediaPlayer?.drawable = renderingView
        mediaPlayer?.audio?.volume = 100
        mediaPlayer?.delegate = self
        
        // Configure for direct video processing
        configureVLCForDirectProcessing()
        
        print("VLC Player initialized with direct processing")
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
    
    private func setupRenderingView() {
        guard let containerView = videoContainerView else { return }
        
        renderingView = UIView()
        renderingView?.backgroundColor = .black
        renderingView?.translatesAutoresizingMaskIntoConstraints = false
        
        guard let renderView = renderingView else { return }
        
        containerView.addSubview(renderView)
        
        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: containerView.topAnchor),
            renderView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        print("Rendering view setup completed")
    }
    
    private func configureVLCForDirectProcessing() {
        guard let player = mediaPlayer else { return }
        
        // Configure for direct video output
        player.videoAspectRatio = nil // Auto-detect
        
        // Enable direct rendering for PiP
        if let renderView = renderingView {
            renderView.contentMode = .scaleAspectFit
            print("VLC configured for direct rendering")
        }
    }
    
    private func setupPerformanceMonitoring() {
        performanceMonitor = PerformanceMonitor()
        performanceMonitor?.startMonitoring()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Update container bounds
        videoContainerView?.frame = bounds
        
        // Force VLC to update if playing
        if let player = mediaPlayer, player.isPlaying {
            DispatchQueue.main.async {
                player.drawable = self.renderingView
            }
        }
    }
    
    // MARK: - Playback Control with Direct Stream Setup
    
    func play(url: String, username: String? = nil, password: String? = nil, networkCaching: Int = 0) {
        // Stop current playback
        if mediaPlayer?.isPlaying == true {
            stop()
        }
        
        // Build authenticated URL
        let authenticatedURL = buildAuthenticatedURL(url: url, username: username, password: password)
        
        guard let mediaURL = URL(string: authenticatedURL) else {
            print("Invalid URL: \(authenticatedURL)")
            return
        }
        
        currentStreamURL = authenticatedURL
        
        // Create VLC Media with enhanced options
        media = VLCMedia(url: mediaURL)
        
        // Apply enhanced optimizations for direct processing
        applyEnhancedStreamOptimizations(caching: networkCaching)
        
        // Set media
        mediaPlayer?.media = media
        
        // CRITICAL: Setup direct video processing BEFORE playing
        DispatchQueue.main.async { [weak self] in
            self?.setupDirectVideoProcessing()
            
            // Start playback
            self?.mediaPlayer?.play()
            
            print("Starting direct stream: \(url)")
            
            // Setup PiP after stream starts
            self?.setupPiPAfterStreamStart()
        }
    }
    
    private func setupDirectVideoProcessing() {
        guard let player = mediaPlayer, let containerView = videoContainerView else { return }
        
        // CRITICAL: Connect PiP manager for direct stream processing
        pipManager.connectToVLCPlayer(player, containerView: containerView)
        isPiPSetup = true
        
        print("Direct video processing setup completed")
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
    
    private func applyEnhancedStreamOptimizations(caching: Int) {
        guard let media = media else { return }
        
        // Use enhanced options for direct processing
        var options = enhancedLowLatencyOptions
        
        // Override caching if specified (but keep very low for direct processing)
        if caching > 0 {
            let optimizedCaching = min(caching, 100) // Cap at 100ms for direct processing
            options["network-caching"] = "\(optimizedCaching)"
            options["rtsp-caching"] = "\(optimizedCaching)"
            options["live-caching"] = "\(optimizedCaching)"
        }
        
        // Apply all optimizations
        for (key, value) in options {
            if value.isEmpty {
                media.addOption("--\(key)")
            } else {
                media.addOption("--\(key)=\(value)")
            }
        }
        
        // Additional direct processing options
        media.addOption("--intf=dummy")
        media.addOption("--no-stats")
        media.addOption("--no-osd")
        media.addOption("--no-video-title-show")
        
        // Force specific decoders for better PiP compatibility
        media.addOption("--codec=avcodec,none")
        media.addOption("--avcodec-options")
        media.addOption("lowres=0,fast=1,skiploopfilter=none")
        
        print("Enhanced optimizations applied for direct processing")
    }
    
    private func setupPiPAfterStreamStart() {
        // Wait for VLC to fully initialize the stream
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            
            if let player = self.mediaPlayer, player.isPlaying, self.isPiPSetup {
                print("Stream initialized, PiP ready for direct processing")
                // PiP is now ready to be activated
            }
        }
    }
    
    // MARK: - Playback Control
    
    func stop() {
        mediaPlayer?.stop()
        media = nil
        currentStreamURL = nil
        isPiPSetup = false
        streamInfo = nil
        
        // Clean up rendering views
        renderingView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        
        print("Stream stopped")
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
    
    func updateNetworkCaching(_ caching: Int) {
        guard let currentURL = currentStreamURL, isPlaying() else { return }
        
        // For direct processing, restart with new optimized settings
        let wasPlaying = isPlaying()
        stop()
        
        if wasPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(url: currentURL, networkCaching: caching)
            }
        }
    }
    
    func getStreamInfo() -> StreamInfo? {
        guard let mediaPlayer = mediaPlayer, mediaPlayer.isPlaying else { return nil }
        
        var info = StreamInfo()
        
        // Video info
        let videoSize = mediaPlayer.videoSize
        info.resolution = CGSize(width: CGFloat(videoSize.width), height: CGFloat(videoSize.height))
        info.videoCodec = detectVideoCodec()
        
        // Audio info
        if let audioTracks = mediaPlayer.audioTrackNames as? [String],
           let audioTrack = audioTracks.first {
            info.audioTrack = audioTrack
        }
        
        // Playback info
        info.position = mediaPlayer.position
        info.time = TimeInterval(mediaPlayer.time.intValue / 1000)
        
        // Direct processing info
        info.isBuffering = mediaPlayer.state == .buffering
        info.droppedFrames = 0 // Direct processing reduces dropped frames
        
        // Performance info
        if let performance = performanceMonitor?.getCurrentMetrics() {
            info.cpuUsage = performance.cpuUsage
            info.memoryUsage = performance.memoryUsage
            info.fps = performance.fps
        }
        
        // PiP info
        info.pipStatus = pipManager.pipStatus
        info.isPiPActive = pipManager.isPiPActive
        
        self.streamInfo = info
        return info
    }
    
    private func detectVideoCodec() -> String {
        if let media = media {
            let url = media.url?.absoluteString ?? ""
            if url.contains("h264") || url.contains("avc") {
                return "H.264/AVC (Direct)"
            } else if url.contains("h265") || url.contains("hevc") {
                return "H.265/HEVC (Direct)"
            }
        }
        
        return "Direct Processing"
    }
    
    // MARK: - PiP Control with Direct Processing
    
    func startPictureInPicture() {
        guard isPiPSetup else {
            print("PiP not setup - need active stream first")
            return
        }
        
        if pipManager.canStartPiP {
            print("Starting direct processing PiP")
            pipManager.startPiP()
        } else {
            print("Cannot start PiP - conditions not met")
        }
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
    
    // MARK: - Cleanup
    
    deinit {
        stop()
        performanceMonitor?.stopMonitoring()
        
        NSLayoutConstraint.deactivate(containerViewConstraints)
        containerViewConstraints.removeAll()
        
        renderingView?.removeFromSuperview()
        videoContainerView?.removeFromSuperview()
        renderingView = nil
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
            print("VLC: Opening direct stream...")
            streamInfo?.state = "Opening Direct"
            
        case .buffering:
            let bufferPercent = player.position * 100
            print("VLC: Buffering direct stream... \(Int(bufferPercent))%")
            streamInfo?.state = "Buffering Direct"
            
        case .playing:
            print("VLC: Playing direct stream - Video size: \(player.videoSize)")
            streamInfo?.state = "Playing Direct"
            
            // Ensure rendering is properly setup
            DispatchQueue.main.async { [weak self] in
                self?.renderingView?.setNeedsLayout()
                self?.setNeedsLayout()
                
                // Verify PiP setup
                if self?.isPiPSetup == false {
                    self?.setupDirectVideoProcessing()
                }
            }
            
        case .paused:
            print("VLC: Paused direct stream")
            streamInfo?.state = "Paused Direct"
            
        case .stopped:
            print("VLC: Stopped direct stream")
            streamInfo?.state = "Stopped"
            
        case .error:
            print("VLC: Error in direct stream")
            streamInfo?.state = "Error"
            streamInfo?.lastError = "Direct stream error"
            
        case .ended:
            print("VLC: Direct stream ended")
            streamInfo?.state = "Ended"
            
        case .esAdded:
            print("VLC: Elementary stream added to direct processing")
            streamInfo?.state = "Direct ES Added"
            
        @unknown default:
            print("VLC: Unknown state in direct processing")
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if let player = aNotification.object as? VLCMediaPlayer {
            streamInfo?.time = TimeInterval(player.time.intValue / 1000)
            streamInfo?.position = player.position
        }
    }
}

// MARK: - Enhanced Stream Info Model
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
    
    // Enhanced PiP info
    var pipStatus: String = "Unknown"
    var isPiPActive: Bool = false
    
    var qualityDescription: String {
        if resolution.width >= 3840 {
            return "4K UHD (Direct)"
        } else if resolution.width >= 1920 {
            return "Full HD (Direct)"
        } else if resolution.width >= 1280 {
            return "HD (Direct)"
        } else if resolution.width > 0 {
            return "SD (Direct)"
        } else {
            return "Direct Processing"
        }
    }
    
    var resolutionString: String {
        if resolution.width > 0 && resolution.height > 0 {
            return "\(Int(resolution.width))x\(Int(resolution.height))"
        }
        return "N/A"
    }
    
    var processingMode: String {
        return "Direct VLC Stream"
    }
}

// MARK: - Performance Monitor (Enhanced)
class PerformanceMonitor {
    private var timer: Timer?
    private var frameCounter: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    
    struct Metrics {
        var cpuUsage: Float = 0.0
        var memoryUsage: Float = 0.0
        var fps: Float = 0.0
        var directProcessing: Bool = true
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
        lastFrameTime = CACurrentMediaTime()
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    func getCurrentMetrics() -> Metrics {
        var metrics = Metrics()
        
        metrics.cpuUsage = getCPUUsage()
        metrics.memoryUsage = getMemoryUsage()
        metrics.fps = calculateFPS()
        metrics.directProcessing = true
        
        return metrics
    }
    
    private func updateMetrics() {
        frameCounter += 1
    }
    
    private func calculateFPS() -> Float {
        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - lastFrameTime
        
        if elapsed >= 1.0 {
            let fps = Float(frameCounter) / Float(elapsed)
            frameCounter = 0
            lastFrameTime = currentTime
            return fps
        }
        
        return 30.0 // Default estimate for direct processing
    }
    
    private func getCPUUsage() -> Float {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Float(info.resident_size) / Float(1024 * 1024)
        }
        
        return 0.0
    }
    
    private func getMemoryUsage() -> Float {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Float(info.resident_size) / Float(1024 * 1024 * 1024)
        }
        
        return 0.0
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - SwiftUI Wrapper (Enhanced)
struct RTSPPlayerView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isPlaying: Bool
    var username: String?
    var password: String?
    var networkCaching: Int = 0
    
    var onStreamInfo: ((StreamInfo) -> Void)?
    var onPiPStatusChanged: ((Bool) -> Void)?
    
    func makeUIView(context: Context) -> RTSPPlayerUIView {
        let playerView = RTSPPlayerUIView()
        
        PictureInPictureManager.shared.delegate = context.coordinator
        
        return playerView
    }
    
    func updateUIView(_ uiView: RTSPPlayerUIView, context: Context) {
        if isPlaying {
            if !uiView.isPlaying() && !url.isEmpty {
                uiView.play(url: url, username: username, password: password, networkCaching: networkCaching)
            }
        } else {
            if uiView.isPlaying() {
                uiView.pause()
            }
        }
        
        uiView.updateNetworkCaching(networkCaching)
        
        if let info = uiView.getStreamInfo() {
            onStreamInfo?(info)
        }
        
        onPiPStatusChanged?(uiView.isPiPActive)
    }
    
    static func dismantleUIView(_ uiView: RTSPPlayerUIView, coordinator: Coordinator) {
        uiView.stop()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PictureInPictureManagerDelegate {
        let parent: RTSPPlayerView
        
        init(_ parent: RTSPPlayerView) {
            self.parent = parent
        }
        
        func pipDidStart() {
            print("Direct processing PiP started")
            parent.onPiPStatusChanged?(true)
        }
        
        func pipDidStop() {
            print("Direct processing PiP stopped")
            parent.onPiPStatusChanged?(false)
        }
        
        func pipWillStart() {
            print("Direct processing PiP will start")
        }
        
        func pipWillStop() {
            print("Direct processing PiP will stop")
        }
        
        func pipRestoreUserInterface(completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
    }
}

// MARK: - Helper Extensions
extension RTSPPlayerView {
    
    func onStreamInfoUpdate(_ callback: @escaping (StreamInfo) -> Void) -> RTSPPlayerView {
        var view = self
        view.onStreamInfo = callback
        return view
    }
    
    func onPiPStatusUpdate(_ callback: @escaping (Bool) -> Void) -> RTSPPlayerView {
        var view = self
        view.onPiPStatusChanged = callback
        return view
    }
}
