import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var viewModel = RTSPViewModel()
    @StateObject private var pipManager = PictureInPictureManager.shared
    @State private var showAddStream = false
    @State private var showPlayer = false
    @State private var newStreamName = ""
    @State private var newStreamURL = ""
    @State private var newStreamUsername = ""
    @State private var newStreamPassword = ""
    @State private var showStreamInfo = false
    @State private var currentStreamInfo: StreamInfo?
    
    // Player management
    @State private var playerSize: CGSize = .zero
    @State private var isPlayerInitialized = false
    
    // PiP state tracking
    @State private var pipDebugInfo: String = "Not initialized"
    
    var body: some View {
        NavigationView {
            ZStack {
                // Main list view
                streamListView
                
                // Enhanced player overlay
                if showPlayer && viewModel.selectedStream != nil {
                    playerOverlay
                }
            }
            .navigationTitle("Enhanced RTSP Player")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddStream = true }) {
                        Image(systemName: "plus")
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { viewModel.showSettings.toggle() }) {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showAddStream) {
                addStreamView
            }
            .sheet(isPresented: $viewModel.showSettings) {
                enhancedSettingsView
            }
            .sheet(isPresented: $showStreamInfo) {
                enhancedStreamInfoView
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            updatePiPDebugInfo()
        }
    }
    
    // MARK: - Enhanced Stream List View
    private var streamListView: some View {
        List {
            Section(header: Text("저장된 스트림")) {
                ForEach(viewModel.streams) { stream in
                    EnhancedStreamRowView(stream: stream) {
                        viewModel.selectStream(stream)
                        showPlayer = true
                        isPlayerInitialized = false
                    }
                }
                .onDelete(perform: viewModel.deleteStream)
            }
            
            if !viewModel.streams.isEmpty {
                Section(header: Text("플레이어 상태")) {
                    playerStatusSection
                }
                
                Section(header: Text("Enhanced PiP 상태")) {
                    pipStatusSection
                }
                
                if let streamInfo = currentStreamInfo {
                    Section(header: Text("스트림 정보")) {
                        streamInfoSection(streamInfo)
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
    
    // MARK: - Player Status Section
    private var playerStatusSection: some View {
        Group {
            HStack {
                Text("현재 상태:")
                Spacer()
                Text(playerStateText)
                    .foregroundColor(playerStateColor)
            }
            
            if let stream = viewModel.selectedStream {
                HStack {
                    Text("재생 중:")
                    Spacer()
                    Text(stream.name)
                        .lineLimit(1)
                }
            }
            
            if isPlayerInitialized {
                HStack {
                    Text("플레이어:")
                    Spacer()
                    Text("초기화됨")
                        .foregroundColor(.green)
                }
            }
        }
    }
    
    // MARK: - Enhanced PiP Status Section
    private var pipStatusSection: some View {
        Group {
            HStack {
                Text("PiP 지원:")
                Spacer()
                Text(pipManager.isPiPSupported ? "지원됨" : "지원 안됨")
                    .foregroundColor(pipManager.isPiPSupported ? .green : .red)
            }
            
            if pipManager.isPiPSupported {
                HStack {
                    Text("PiP 상태:")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(pipStatusColor)
                            .frame(width: 8, height: 8)
                        Text(pipStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Text("상세 상태:")
                    Spacer()
                    Text(pipManager.pipStatus)
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                
                HStack {
                    Text("시작 가능:")
                    Spacer()
                    Text(pipManager.canStartPiP ? "예" : "아니오")
                        .foregroundColor(pipManager.canStartPiP ? .green : .orange)
                }
                
                // Debug information
                VStack(alignment: .leading, spacing: 4) {
                    Text("디버그 정보:")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Text(pipDebugInfo)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(3)
                }
                
                // Manual PiP control
                if pipManager.canStartPiP || pipManager.isPiPActive {
                    Button(action: {
                        pipManager.togglePiP()
                        updatePiPDebugInfo()
                    }) {
                        HStack {
                            Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                            Text(pipManager.isPiPActive ? "PiP 종료" : "PiP 시작")
                        }
                        .foregroundColor(.blue)
                    }
                }
            }
        }
    }
    
    // MARK: - Stream Info Section
    private func streamInfoSection(_ info: StreamInfo) -> some View {
        Group {
            HStack {
                Text("해상도:")
                Spacer()
                Text(info.resolutionString)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("코덱:")
                Spacer()
                Text(info.videoCodec)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("품질:")
                Spacer()
                Text(info.qualityDescription)
                    .foregroundColor(.blue)
            }
            
            HStack {
                Text("PiP 상태:")
                Spacer()
                Text(info.pipStatusDescription)
                    .foregroundColor(info.isPiPActive ? .green : .gray)
            }
            
            if info.fps > 0 {
                HStack {
                    Text("프레임율:")
                    Spacer()
                    Text("\(String(format: "%.1f", info.fps)) FPS")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Enhanced Player Overlay
    private var playerOverlay: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.95)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    // Enhanced player header
                    enhancedPlayerHeader
                    
                    // Main player view with enhanced PiP support
                    RTSPPlayerView(
                        url: $viewModel.currentStreamURL,
                        isPlaying: $viewModel.isPlaying,
                        username: viewModel.selectedStream?.username,
                        password: viewModel.selectedStream?.password,
                        networkCaching: viewModel.networkCaching,
                        onStreamInfo: { info in
                            currentStreamInfo = info
                        },
                        onPiPStatusChanged: { isActive in
                            updatePiPDebugInfo()
                        }
                    )
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.width * 9 / 16
                    )
                    .background(Color.black)
                    .clipped()
                    .onTapGesture(count: 2) {
                        // Double tap to toggle PiP
                        pipManager.togglePiP()
                        updatePiPDebugInfo()
                    }
                    .onAppear {
                        playerSize = CGSize(
                            width: geometry.size.width,
                            height: geometry.size.width * 9 / 16
                        )
                        isPlayerInitialized = true
                        
                        // Update PiP debug info
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            updatePiPDebugInfo()
                        }
                    }
                    
                    Spacer()
                    
                    // Enhanced player controls
                    enhancedPlayerControls
                }
            }
            .transition(.move(edge: .bottom))
            .animation(.spring(), value: showPlayer)
        }
    }
    
    // MARK: - Enhanced Player Header
    private var enhancedPlayerHeader: some View {
        HStack {
            Button(action: {
                viewModel.stop()
                showPlayer = false
                isPlayerInitialized = false
                currentStreamInfo = nil
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(viewModel.selectedStream?.name ?? "스트림")
                    .font(.headline)
                    .foregroundColor(.white)
                
                if let stream = viewModel.selectedStream {
                    Text(getStreamQualityText(for: stream))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                
                if playerSize != .zero {
                    Text("화면: \(Int(playerSize.width))×\(Int(playerSize.height))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                // Stream info button
                Button(action: {
                    showStreamInfo = true
                }) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                // Enhanced PiP button with status indicator
                if pipManager.isPiPSupported {
                    Button(action: {
                        pipManager.togglePiP()
                        updatePiPDebugInfo()
                    }) {
                        ZStack {
                            Image(systemName: getPiPButtonIcon())
                                .font(.title2)
                                .foregroundColor(pipManager.canStartPiP || pipManager.isPiPActive ? .white : .gray)
                            
                            // Status indicator
                            if pipManager.isPiPActive {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .disabled(!pipManager.canStartPiP && !pipManager.isPiPActive)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Enhanced Player Controls
    private var enhancedPlayerControls: some View {
        VStack(spacing: 20) {
            // Main playback controls
            HStack(spacing: 40) {
                Button(action: {
                    viewModel.reconnectStream()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                Button(action: viewModel.togglePlayPause) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                }
                
                Button(action: { viewModel.showSettings = true }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            
            // Volume control
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.white)
                
                Slider(value: $viewModel.volume, in: 0...1)
                    .accentColor(.white)
                    .onChange(of: viewModel.volume) { newValue in
                        print("🔊 Volume changed to: \(newValue)")
                    }
                
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.white)
            }
            .padding(.horizontal)
            
            // Enhanced latency settings with PiP optimization
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("지연 설정: \(viewModel.selectedLatencyPreset.rawValue)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    // Enhanced codec info with PiP status
                    HStack(spacing: 8) {
                        Text("H.264/H.265 최적화")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                            .foregroundColor(.blue)
                        
                        if pipManager.isPiPSupported {
                            Text("PiP 지원")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .cornerRadius(4)
                                .foregroundColor(.green)
                        }
                    }
                }
                
                Picker("지연 설정", selection: $viewModel.selectedLatencyPreset) {
                    ForEach(RTSPViewModel.LatencyPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .onChange(of: viewModel.selectedLatencyPreset) { newValue in
                    viewModel.applyLatencySettings(newValue)
                }
            }
            .padding(.horizontal)
            
            // Enhanced PiP status and controls
            if pipManager.isPiPSupported {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "pip")
                            .foregroundColor(.blue)
                        
                        Text("Enhanced PiP: \(pipStatusText)")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Spacer()
                        
                        if pipManager.canStartPiP || pipManager.isPiPActive {
                            Button(pipManager.isPiPActive ? "종료" : "시작") {
                                pipManager.togglePiP()
                                updatePiPDebugInfo()
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                            .foregroundColor(.blue)
                        }
                    }
                    
                    // Enhanced debug information
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("상태: \(pipManager.pipStatus)")
                                .font(.caption2)
                                .foregroundColor(.yellow)
                            Spacer()
                        }
                        
                        if let streamInfo = currentStreamInfo {
                            HStack {
                                Text("프레임: \(streamInfo.resolutionString) @ \(String(format: "%.1f", streamInfo.fps))fps")
                                    .font(.caption2)
                                    .foregroundColor(.cyan)
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Enhanced Add Stream View
    private var addStreamView: some View {
        NavigationView {
            Form {
                Section(header: Text("스트림 정보")) {
                    TextField("스트림 이름", text: $newStreamName)
                    TextField("RTSP URL", text: $newStreamURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                
                Section(header: Text("인증 (선택사항)")) {
                    TextField("사용자명", text: $newStreamUsername)
                        .autocapitalization(.none)
                    SecureField("비밀번호", text: $newStreamPassword)
                }
                
                Section(header: Text("테스트 URL")) {
                    testUrlButtons
                }
                
                Section(header: Text("Enhanced PiP 호환성")) {
                    pipCompatibilityInfo
                }
                
                Section {
                    Button(action: addNewStream) {
                        Text("스트림 추가")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(newStreamName.isEmpty || newStreamURL.isEmpty)
                }
            }
            .navigationTitle("새 스트림 추가")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("취소") {
                        showAddStream = false
                        resetAddStreamForm()
                    }
                }
            }
        }
    }
    
    private var testUrlButtons: some View {
        Group {
            Button("테스트 스트림 1 사용") {
                newStreamName = "테스트 스트림"
                newStreamURL = "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mp4"
            }
            
            Button("테스트 스트림 2 사용") {
                newStreamName = "샘플 스트림"
                newStreamURL = "rtsp://demo.streamlock.net/vod/sample.mp4"
            }
            
            Button("로컬 IP 카메라 템플릿") {
                newStreamName = "IP 카메라"
                newStreamURL = "rtsp://192.168.1.100:554/stream"
                newStreamUsername = "admin"
                newStreamPassword = "password"
            }
        }
    }
    
    private var pipCompatibilityInfo: some View {
        Group {
            HStack {
                Text("시스템 PiP 지원")
                Spacer()
                Text(pipManager.isPiPSupported ? "지원됨" : "지원 안됨")
                    .foregroundColor(pipManager.isPiPSupported ? .green : .red)
            }
            
            if pipManager.isPiPSupported {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enhanced Features:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("• 실시간 프레임 추출 및 렌더링")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("• H.264/H.265 하드웨어 디코딩 최적화")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("• 30fps 스냅샷 기반 시스템 PiP")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("• iOS 15+ AVSampleBufferDisplayLayer 지원")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Enhanced Settings View
    private var enhancedSettingsView: some View {
        NavigationView {
            Form {
                Section(header: Text("네트워크 설정")) {
                    networkSettingsSection
                }
                
                Section(header: Text("Enhanced PiP 설정")) {
                    pipSettingsSection
                }
                
                Section(header: Text("시스템 정보")) {
                    systemInfoSection
                }
                
                Section(header: Text("디버그 정보")) {
                    debugInfoSection
                }
            }
            .navigationTitle("Enhanced 설정")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") {
                        viewModel.showSettings = false
                    }
                }
            }
        }
    }
    
    private var networkSettingsSection: some View {
        Group {
            VStack(alignment: .leading) {
                Text("네트워크 캐싱 (ms)")
                Slider(value: Binding(
                    get: { Double(viewModel.networkCaching) },
                    set: { viewModel.networkCaching = Int($0) }
                ), in: 0...1000, step: 50)
                Text("\(viewModel.networkCaching) ms")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
    
    private var pipSettingsSection: some View {
        Group {
            HStack {
                Text("시스템 PiP 지원")
                Spacer()
                Text(pipManager.isPiPSupported ? "예" : "아니오")
                    .foregroundColor(pipManager.isPiPSupported ? .green : .red)
            }
            
            if pipManager.isPiPSupported {
                HStack {
                    Text("현재 PiP 상태")
                    Spacer()
                    Text(pipStatusText)
                        .foregroundColor(pipManager.isPiPActive ? .green : .gray)
                }
                
                HStack {
                    Text("상세 상태")
                    Spacer()
                    Text(pipManager.pipStatus)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enhanced Features")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ForEach([
                        "AVSampleBufferDisplayLayer 기반 렌더링",
                        "실시간 CVPixelBuffer 처리",
                        "30fps CADisplayLink 동기화",
                        "메모리 풀 기반 버퍼 관리",
                        "하드웨어 가속 프레임 추출"
                    ], id: \.self) { feature in
                        Text("• \(feature)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    private var systemInfoSection: some View {
        Group {
            HStack {
                Text("앱 버전")
                Spacer()
                Text("1.3.0")
                    .foregroundColor(.gray)
            }
            
            HStack {
                Text("VLCKit 버전")
                Spacer()
                Text("3.6.0")
                    .foregroundColor(.gray)
            }
            
            HStack {
                Text("iOS 버전")
                Spacer()
                Text(UIDevice.current.systemVersion)
                    .foregroundColor(.gray)
            }
            
            HStack {
                Text("디바이스")
                Spacer()
                Text(UIDevice.current.model)
                    .foregroundColor(.gray)
            }
        }
    }
    
    private var debugInfoSection: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text("PiP 디버그:")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text(pipDebugInfo)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .lineLimit(nil)
            }
            
            if let streamInfo = currentStreamInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("스트림 디버그:")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Text("상태: \(streamInfo.state)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    Text("해상도: \(streamInfo.resolutionString)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    Text("메모리: \(String(format: "%.1f", streamInfo.memoryUsage))MB")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            
            Button("PiP 상태 새로고침") {
                updatePiPDebugInfo()
            }
            .font(.caption)
            .foregroundColor(.blue)
        }
    }
    
    // MARK: - Enhanced Stream Info View
    private var enhancedStreamInfoView: some View {
        NavigationView {
            Form {
                if let stream = viewModel.selectedStream {
                    streamDetailsSection(stream)
                }
                
                if let streamInfo = currentStreamInfo {
                    streamMetricsSection(streamInfo)
                }
                
                pipInfoSection
            }
            .navigationTitle("스트림 정보")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") {
                        showStreamInfo = false
                    }
                }
            }
        }
    }
    
    private func streamDetailsSection(_ stream: RTSPStream) -> some View {
        Section(header: Text("스트림 정보")) {
            HStack {
                Text("이름")
                Spacer()
                Text(stream.name)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("URL")
                Spacer()
                Text(stream.url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            HStack {
                Text("캐싱 설정")
                Spacer()
                Text("\(stream.networkCaching) ms")
                    .foregroundColor(.secondary)
            }
            
            if stream.username != nil {
                HStack {
                    Text("인증")
                    Spacer()
                    Text("필요")
                        .foregroundColor(.orange)
                }
            }
        }
    }
    
    private func streamMetricsSection(_ info: StreamInfo) -> some View {
        Section(header: Text("실시간 메트릭")) {
            HStack {
                Text("해상도")
                Spacer()
                Text(info.resolutionString)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("코덱")
                Spacer()
                Text(info.videoCodec)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("품질")
                Spacer()
                Text(info.qualityDescription)
                    .foregroundColor(.blue)
            }
            
            if info.fps > 0 {
                HStack {
                    Text("프레임율")
                    Spacer()
                    Text("\(String(format: "%.1f", info.fps)) FPS")
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Text("메모리 사용량")
                Spacer()
                Text("\(String(format: "%.1f", info.memoryUsage)) MB")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var pipInfoSection: some View {
        Section(header: Text("PiP 정보")) {
            HStack {
                Text("PiP 상태")
                Spacer()
                Text(pipManager.pipStatus)
                    .foregroundColor(.blue)
            }
            
            HStack {
                Text("시작 가능")
                Spacer()
                Text(pipManager.canStartPiP ? "예" : "아니오")
                    .foregroundColor(pipManager.canStartPiP ? .green : .orange)
            }
            
            if playerSize != .zero {
                HStack {
                    Text("플레이어 크기")
                    Spacer()
                    Text("\(Int(playerSize.width))×\(Int(playerSize.height))")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func addNewStream() {
        let newStream = RTSPStream(
            name: newStreamName,
            url: newStreamURL,
            username: newStreamUsername.isEmpty ? nil : newStreamUsername,
            password: newStreamPassword.isEmpty ? nil : newStreamPassword,
            networkCaching: viewModel.networkCaching
        )
        viewModel.addStream(newStream)
        showAddStream = false
        resetAddStreamForm()
    }
    
    private func resetAddStreamForm() {
        newStreamName = ""
        newStreamURL = ""
        newStreamUsername = ""
        newStreamPassword = ""
    }
    
    private func updatePiPDebugInfo() {
        var debugInfo = [String]()
        
        debugInfo.append("지원: \(pipManager.isPiPSupported)")
        debugInfo.append("가능: \(pipManager.isPiPPossible)")
        debugInfo.append("활성: \(pipManager.isPiPActive)")
        debugInfo.append("시작가능: \(pipManager.canStartPiP)")
        debugInfo.append("플레이어: \(isPlayerInitialized)")
        
        if let stream = viewModel.selectedStream {
            debugInfo.append("스트림: \(stream.name)")
        }
        
        pipDebugInfo = debugInfo.joined(separator: "\n")
    }
    
    private var playerStateText: String {
        switch viewModel.playerState {
        case .idle: return "대기"
        case .loading: return "로딩 중..."
        case .playing: return "재생 중"
        case .paused: return "일시정지"
        case .error(let message): return "오류: \(message)"
        }
    }
    
    private var playerStateColor: Color {
        switch viewModel.playerState {
        case .idle: return .gray
        case .loading: return .orange
        case .playing: return .green
        case .paused: return .yellow
        case .error: return .red
        }
    }
    
    private var pipStatusText: String {
        if pipManager.isPiPActive {
            return "활성"
        } else if pipManager.isPiPPossible {
            return "준비됨"
        } else {
            return "대기 중"
        }
    }
    
    private var pipStatusColor: Color {
        if pipManager.isPiPActive {
            return .green
        } else if pipManager.isPiPPossible {
            return .orange
        } else {
            return .gray
        }
    }
    
    private func getPiPButtonIcon() -> String {
        if pipManager.isPiPActive {
            return "pip.exit"
        } else {
            return "pip.enter"
        }
    }
    
    private func getStreamQualityText(for stream: RTSPStream) -> String {
        let url = stream.url.lowercased()
        if url.contains("4k") || url.contains("2160") {
            return "4K UHD"
        } else if url.contains("1080") || url.contains("hd") {
            return "Full HD"
        } else if url.contains("720") {
            return "HD"
        } else {
            return "SD"
        }
    }
}

// MARK: - Enhanced Stream Row View
struct EnhancedStreamRowView: View {
    let stream: RTSPStream
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(stream.url)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        if stream.username != nil {
                            Label("인증", systemImage: "lock.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        
                        // Latency indicator
                        Text("\(stream.networkCaching)ms")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(3)
                            .foregroundColor(.blue)
                        
                        // Enhanced PiP support indicator
                        if PictureInPictureManager.shared.isPiPSupported {
                            HStack(spacing: 2) {
                                Image(systemName: "pip")
                                    .font(.caption2)
                                Text("Enhanced")
                                    .font(.caption2)
                            }
                            .foregroundColor(.green)
                        }
                    }
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    Text("시스템 PiP")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
