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
    
    // Player size management
    @State private var playerSize: CGSize = .zero
    
    // PiP 상태 추적
    @State private var isPiPModeActive = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // 메인 리스트 뷰
                streamListView
                
                // 플레이어 오버레이 (PiP 모드일 때 숨김/투명도 조절)
                if showPlayer, viewModel.selectedStream != nil {
                    playerOverlay
                        .opacity(isPiPModeActive ? 0.3 : 1.0) // PiP 활성시 반투명
                        .animation(.easeInOut(duration: 0.3), value: isPiPModeActive)
                }
            }
            .navigationTitle(isPiPModeActive ? "RTSP 플레이어 (PiP 모드)" : "RTSP 플레이어")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        // PiP 상태 표시
                        if isPiPModeActive {
                            Image(systemName: "pip.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                        
                        Button(action: { showAddStream = true }) {
                            Image(systemName: "plus")
                        }
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
                settingsView
            }
            .sheet(isPresented: $showStreamInfo) {
                streamInfoView
            }
            .onChange(of: pipManager.isPiPActive) { isActive in
                isPiPModeActive = isActive
                
                // PiP 상태 변경시 UI 업데이트
                if isActive {
                    print("PiP 모드 활성화 - 메인 UI 반투명 처리")
                } else {
                    print("PiP 모드 비활성화 - 메인 UI 복원")
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    // MARK: - Stream List View
    private var streamListView: some View {
        List {
            Section(header: Text("저장된 스트림")) {
                ForEach(viewModel.streams) { stream in
                    StreamRowView(stream: stream) {
                        viewModel.selectStream(stream)
                        showPlayer = true
                    }
                }
                .onDelete(perform: viewModel.deleteStream)
            }
            
            if !viewModel.streams.isEmpty {
                Section(header: Text("재생 상태")) {
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
                    
                    // Enhanced PiP 상태 표시
                    if pipManager.isPiPSupported {
                        HStack {
                            Text("독립 PiP:")
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(pipManager.isPiPActive ? Color.green : (pipManager.isPiPPossible ? Color.orange : Color.gray))
                                    .frame(width: 8, height: 8)
                                Text(pipStatusText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // 상세 PiP 정보
                        if viewModel.selectedStream != nil {
                            HStack {
                                Text("PiP 모드:")
                                Spacer()
                                Text(pipManager.pipStatus)
                                    .font(.caption2)
                                    .foregroundColor(pipManager.isPiPActive ? .green : .blue)
                            }
                            
                            if isPiPModeActive {
                                HStack {
                                    Text("독립 실행:")
                                    Spacer()
                                    Text("백그라운드 지원")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                    
                    // 스트림 정보 표시
                    if let streamInfo = currentStreamInfo {
                        HStack {
                            Text("해상도:")
                            Spacer()
                            Text(streamInfo.resolutionString)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("코덱:")
                            Spacer()
                            Text(streamInfo.videoCodec)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
    
    // MARK: - Player Overlay with PiP Support
    private var playerOverlay: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(isPiPModeActive ? 0.7 : 0.9)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    // 헤더 (PiP 상태 표시 포함)
                    playerHeader
                    
                    // 플레이어 뷰 (PiP 모드에서도 유지되지만 반투명)
                    RTSPPlayerView(
                        url: $viewModel.currentStreamURL,
                        isPlaying: $viewModel.isPlaying,
                        username: viewModel.selectedStream?.username,
                        password: viewModel.selectedStream?.password,
                        networkCaching: viewModel.networkCaching
                    )
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.width * 9 / 16
                    )
                    .background(Color.black)
                    .clipped()
                    .onTapGesture(count: 2) {
                        // 더블 탭으로 PiP 토글
                        pipManager.togglePiP()
                    }
                    .onStreamInfoUpdate { info in
                        currentStreamInfo = info
                    }
                    .onPiPStatusUpdate { isActive in
                        isPiPModeActive = isActive
                    }
                    .onAppear {
                        playerSize = CGSize(
                            width: geometry.size.width,
                            height: geometry.size.width * 9 / 16
                        )
                    }
                    .overlay(
                        // PiP 모드일 때 오버레이 표시
                        isPiPModeActive ? pipModeOverlay : nil
                    )
                    
                    Spacer()
                    
                    // 컨트롤러 (PiP 상태에 따라 조절)
                    playerControls
                }
            }
            .transition(.move(edge: .bottom))
            .animation(.spring(), value: showPlayer)
        }
    }
    
    // MARK: - PiP 모드 오버레이
    private var pipModeOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
            
            VStack(spacing: 12) {
                Image(systemName: "pip.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                
                Text("PiP 모드 실행 중")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("독립적으로 재생됩니다")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Button("PiP 종료") {
                    pipManager.stopPiP()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
    }
    
    // MARK: - Player Header (PiP 상태 포함)
    private var playerHeader: some View {
        HStack {
            Button(action: {
                // PiP 활성 상태라면 먼저 종료
                if pipManager.isPiPActive {
                    pipManager.stopPiP()
                }
                
                viewModel.stop()
                showPlayer = false
                isPiPModeActive = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text(viewModel.selectedStream?.name ?? "스트림")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    // PiP 상태 인디케이터
                    if isPiPModeActive {
                        Image(systemName: "pip.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                if let stream = viewModel.selectedStream {
                    Text(getStreamQualityText(for: stream))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                
                if let streamInfo = currentStreamInfo {
                    Text(streamInfo.pipStatusDescription)
                        .font(.caption2)
                        .foregroundColor(isPiPModeActive ? .green : .blue)
                }
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                // 스트림 정보 버튼
                Button(action: {
                    showStreamInfo = true
                }) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                
                // Enhanced PiP 버튼 (독립적)
                if pipManager.isPiPSupported {
                    Button(action: {
                        print("Independent PiP button tapped")
                        pipManager.togglePiP()
                    }) {
                        Image(systemName: getPiPButtonIcon())
                            .font(.title2)
                            .foregroundColor(pipManager.canStartPiP ? .white : .gray)
                    }
                    .disabled(!pipManager.canStartPiP && !pipManager.isPiPActive)
                    .overlay(
                        // PiP 활성 상태 표시
                        isPiPModeActive ? 
                        Circle()
                            .stroke(Color.green, lineWidth: 2)
                            .scaleEffect(1.2)
                        : nil
                    )
                }
            }
        }
        .padding()
        .background(
            isPiPModeActive ? 
            Color.green.opacity(0.2) : 
            Color.black.opacity(0.8)
        )
    }
    
    // MARK: - Player Controls (PiP 상태 고려)
    private var playerControls: some View {
        VStack(spacing: 20) {
            // PiP 모드 안내
            if isPiPModeActive {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.green)
                    Text("독립 PiP 모드에서 실행 중입니다. 앱을 백그라운드로 이동해도 계속 재생됩니다.")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.2))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            
            // 재생 컨트롤
            HStack(spacing: 40) {
                Button(action: {
                    print("Reconnecting independent stream...")
                    viewModel.reconnectStream()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                .disabled(isPiPModeActive) // PiP 모드에서는 비활성화
                
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
            
            // 볼륨 컨트롤 (PiP 모드에서도 작동)
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.white)
                
                Slider(value: $viewModel.volume, in: 0...1)
                    .accentColor(.white)
                    .onChange(of: viewModel.volume) { newValue in
                        print("Volume changed to: \(newValue)")
                    }
                
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.white)
            }
            .padding(.horizontal)
            
            // 지연 설정 (PiP 모드에서는 변경 불가)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("지연 설정: \(viewModel.selectedLatencyPreset.rawValue)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    if isPiPModeActive {
                        Text("PiP 모드에서 변경 불가")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else {
                        Text("독립 PiP 최적화")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                            .foregroundColor(.blue)
                    }
                }
                
                Picker("지연 설정", selection: $viewModel.selectedLatencyPreset) {
                    ForEach(RTSPViewModel.LatencyPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .disabled(isPiPModeActive) // PiP 모드에서는 비활성화
                .onChange(of: viewModel.selectedLatencyPreset) { newValue in
                    if !isPiPModeActive {
                        print("Latency preset changed to: \(newValue)")
                        viewModel.applyLatencySettings(newValue)
                    }
                }
            }
            .padding(.horizontal)
            
            // PiP 컨트롤 패널
            if pipManager.isPiPSupported {
                pipControlPanel
            }
        }
        .padding()
        .background(
            isPiPModeActive ? 
            Color.green.opacity(0.1) : 
            Color.black.opacity(0.8)
        )
    }
    
    // MARK: - PiP 컨트롤 패널
    private var pipControlPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "pip")
                    .foregroundColor(.blue)
                
                Text("독립 PiP (Enhanced)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text(pipStatusText)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        pipManager.isPiPActive ? Color.green.opacity(0.2) : Color.gray.opacity(0.2)
                    )
                    .cornerRadius(6)
                    .foregroundColor(pipManager.isPiPActive ? .green : .gray)
            }
            
            if pipManager.isPiPActive {
                HStack(spacing: 12) {
                    Button("PiP 종료") {
                        pipManager.stopPiP()
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.2))
                    .cornerRadius(6)
                    .foregroundColor(.red)
                    
                    Text("백그라운드에서 독립 실행 중")
                        .font(.caption2)
                        .foregroundColor(.green)
                    
                    Spacer()
                }
            } else if pipManager.canStartPiP {
                HStack(spacing: 12) {
                    Button("PiP 시작") {
                        pipManager.startPiP()
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(6)
                    .foregroundColor(.blue)
                    
                    Text("메인 UI와 독립적으로 실행됩니다")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    Spacer()
                }
            }
            
            // 기능 설명
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("백그라운드 재생")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("독립적인 스트림 인스턴스")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("저지연 최적화")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("하드웨어 디코딩")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    // MARK: - Add Stream View (동일하게 유지)
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
                    Button("테스트 스트림 1 사용") {
                        newStreamName = "테스트 스트림"
                        newStreamURL = "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mp4"
                    }
                    
                    Button("테스트 스트림 2 사용") {
                        newStreamName = "샘플 스트림"
                        newStreamURL = "rtsp://demo.streamlock.net/vod/sample.mp4"
                    }
                }
                
                Section(header: Text("독립 PiP 정보")) {
                    HStack {
                        Text("PiP 지원")
                        Spacer()
                        Text(pipManager.isPiPSupported ? "지원됨" : "지원 안됨")
                            .foregroundColor(pipManager.isPiPSupported ? .green : .red)
                    }
                    
                    if pipManager.isPiPSupported {
                        Text("독립적인 PiP 인스턴스를 생성하여 메인 UI와 분리된 백그라운드 재생을 지원합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
    
    // MARK: - Settings View (PiP 정보 포함)
    private var settingsView: some View {
        NavigationView {
            Form {
                Section(header: Text("네트워크 설정")) {
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
                
                Section(header: Text("독립 PiP 설정")) {
                    HStack {
                        Text("PiP 지원")
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
                            Text("독립 PiP 기능")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Text("• 메인 UI와 완전 분리된 독립 실행")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("• 백그라운드에서 지속적인 재생")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("• 별도 VLC 인스턴스로 안정성 향상")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("• 저지연 RTSP 스트리밍 최적화")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("정보")) {
                    HStack {
                        Text("버전")
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
                        Text("독립 PiP")
                        Spacer()
                        Text(pipManager.isPiPSupported ? "활성화됨" : "지원 안됨")
                            .foregroundColor(pipManager.isPiPSupported ? .green : .red)
                    }
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") {
                        viewModel.showSettings = false
                    }
                }
            }
        }
    }
    
    // MARK: - Stream Info View (PiP 상태 포함)
    private var streamInfoView: some View {
        NavigationView {
            Form {
                if let stream = viewModel.selectedStream {
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
                    }
                    
                    if let streamInfo = currentStreamInfo {
                        Section(header: Text("재생 정보")) {
                            HStack {
                                Text("해상도")
                                Spacer()
                                Text(streamInfo.resolutionString)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack {
                                Text("품질")
                                Spacer()
                                Text(streamInfo.qualityDescription)
                                    .foregroundColor(.blue)
                            }
                            
                            HStack {
                                Text("코덱")
                                Spacer()
                                Text(streamInfo.videoCodec)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Section(header: Text("PiP 상태")) {
                            HStack {
                                Text("PiP 모드")
                                Spacer()
                                Text(streamInfo.pipStatusDescription)
                                    .foregroundColor(streamInfo.isPiPActive ? .green : .blue)
                            }
                            
                            HStack {
                                Text("독립 실행")
                                Spacer()
                                Text(streamInfo.isPiPActive ? "예" : "아니오")
                                    .foregroundColor(streamInfo.isPiPActive ? .green : .gray)
                            }
                            
                            if streamInfo.isPiPActive {
                                HStack {
                                    Text("백그라운드 지원")
                                    Spacer()
                                    Text("활성화")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("스트림 상세 정보")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") {
                        showStreamInfo = false
                    }
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
    
    private var playerStateText: String {
        switch viewModel.playerState {
        case .idle: return "대기"
        case .loading: return "로딩 중..."
        case .playing: return isPiPModeActive ? "재생 중 (PiP)" : "재생 중"
        case .paused: return "일시정지"
        case .error(let message): return "오류: \(message)"
        }
    }
    
    private var playerStateColor: Color {
        switch viewModel.playerState {
        case .idle: return .gray
        case .loading: return .orange
        case .playing: return isPiPModeActive ? .green : .blue
        case .paused: return .yellow
        case .error: return .red
        }
    }
    
    private var pipStatusText: String {
        if pipManager.isPiPActive {
            return "독립 실행"
        } else if pipManager.isPiPPossible {
            return "준비됨"
        } else {
            return "대기 중"
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

// MARK: - Enhanced Stream Row View with PiP Status
struct StreamRowView: View {
    let stream: RTSPStream
    let action: () -> Void
    @StateObject private var pipManager = PictureInPictureManager.shared
    
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
                        
                        Text("\(stream.networkCaching)ms")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(3)
                            .foregroundColor(.blue)
                        
                        if pipManager.isPiPSupported {
                            HStack(spacing: 2) {
                                Image(systemName: "pip")
                                    .font(.caption2)
                                Text("독립")
                                    .font(.caption2)
                            }
                            .foregroundColor(.green)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
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
