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
    @State private var currentStreamInfo: [String: Any] = [:]
    
    var body: some View {
        NavigationView {
            ZStack {
                // 메인 리스트 뷰
                streamListView
                
                // 플레이어 오버레이
                if showPlayer, viewModel.selectedStream != nil {
                    playerOverlay
                }
            }
            .navigationTitle("RTSP 플레이어")
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
                settingsView
            }
            .sheet(isPresented: $showStreamInfo) {
                streamInfoView
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
                            Text("Enhanced PiP:")
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
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
    
    // MARK: - Player Overlay
    private var playerOverlay: some View {
        ZStack {
            Color.black.opacity(0.9)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // 헤더
                playerHeader
                
                // 플레이어 뷰
                RTSPPlayerView(
                    url: $viewModel.currentStreamURL,
                    isPlaying: $viewModel.isPlaying,
                    username: viewModel.selectedStream?.username,
                    password: viewModel.selectedStream?.password,
                    networkCaching: viewModel.networkCaching
                )
                .aspectRatio(16/9, contentMode: .fit)
                .background(Color.black)
                .onTapGesture(count: 2) {
                    // 더블 탭으로 PiP 토글
                    pipManager.togglePiP()
                }
                
                // 컨트롤러
                playerControls
            }
        }
        .transition(.move(edge: .bottom))
        .animation(.spring(), value: showPlayer)
    }
    
    // MARK: - Player Header
    private var playerHeader: some View {
        HStack {
            Button(action: {
                viewModel.stop()
                showPlayer = false
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
                
                // 스트림 품질 정보 표시
                if let stream = viewModel.selectedStream {
                    Text(getStreamQualityText(for: stream))
                        .font(.caption2)
                        .foregroundColor(.gray)
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
                
                // Enhanced PiP 버튼
                if pipManager.isPiPSupported {
                    Button(action: {
                        pipManager.togglePiP()
                    }) {
                        Image(systemName: getPiPButtonIcon())
                            .font(.title2)
                            .foregroundColor(pipManager.isPiPPossible ? .white : .gray)
                    }
                    .disabled(!pipManager.isPiPPossible)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Player Controls
    private var playerControls: some View {
        VStack(spacing: 20) {
            // 재생 컨트롤
            HStack(spacing: 40) {
                Button(action: viewModel.reconnectStream) {
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
            
            // 볼륨 컨트롤
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.white)
                
                Slider(value: $viewModel.volume, in: 0...1)
                    .accentColor(.white)
                
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.white)
            }
            .padding(.horizontal)
            
            // Enhanced 지연 설정 with 코덱 최적화
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("지연 설정: \(viewModel.selectedLatencyPreset.rawValue)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    // 코덱 정보 표시
                    Text("H.264/H.265 최적화")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.blue)
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
            
            // PiP 상태 표시
            if pipManager.isPiPSupported {
                HStack {
                    Image(systemName: "pip")
                        .foregroundColor(.blue)
                    
                    Text("Enhanced PiP: \(pipStatusText)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    if pipManager.isPiPPossible {
                        Button("토글") {
                            pipManager.togglePiP()
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Add Stream View
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
                
                Section(header: Text("Enhanced PiP 설정")) {
                    HStack {
                        Text("PiP 지원")
                        Spacer()
                        Text(pipManager.isPiPSupported ? "지원됨" : "지원 안됨")
                            .foregroundColor(pipManager.isPiPSupported ? .green : .red)
                    }
                    
                    if pipManager.isPiPSupported {
                        Text("H.264/H.265 스트림에서 Enhanced PiP를 지원합니다.")
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
    
    // MARK: - Settings View
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
                
                Section(header: Text("Enhanced PiP 설정")) {
                    HStack {
                        Text("PiP 지원")
                        Spacer()
                        Text(pipManager.isPiPSupported ? "예" : "아니오")
                            .foregroundColor(pipManager.isPiPSupported ? .green : .red)
                    }
                    
                    if pipManager.isPiPSupported {
                        HStack {
                            Text("PiP 상태")
                            Spacer()
                            Text(pipStatusText)
                                .foregroundColor(pipManager.isPiPActive ? .green : .gray)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enhanced Features")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Text("• H.264/H.265 하드웨어 디코딩")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("• 저지연 스트리밍 최적화")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("• 실시간 프레임 추출")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section(header: Text("코덱 지원")) {
                    HStack {
                        Text("H.264 지원")
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    
                    HStack {
                        Text("H.265 지원")
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    
                    HStack {
                        Text("하드웨어 디코딩")
                        Spacer()
                        Text("VideoToolbox")
                            .foregroundColor(.blue)
                    }
                }
                
                Section(header: Text("정보")) {
                    HStack {
                        Text("버전")
                        Spacer()
                        Text("1.1.0")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("VLCKit 버전")
                        Spacer()
                        Text("3.6.0")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("Enhanced PiP")
                        Spacer()
                        Text("활성화됨")
                            .foregroundColor(.green)
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
    
    // MARK: - Stream Info View
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
                        
                        HStack {
                            Text("품질")
                            Spacer()
                            Text(getStreamQualityText(for: stream))
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Section(header: Text("네트워크 정보")) {
                        HStack {
                            Text("캐싱 설정")
                            Spacer()
                            Text("\(stream.networkCaching) ms")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("프로토콜")
                            Spacer()
                            Text("RTSP")
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
    
    private func getPiPButtonIcon() -> String {
        if pipManager.isPiPActive {
            return "pip.exit"
        } else {
            return "pip.enter"
        }
    }
    
    private func getStreamQualityText(for stream: RTSPStream) -> String {
        // URL에서 품질 힌트 추출
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
struct StreamRowView: View {
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
                        
                        // 지연 설정 표시
                        Text("\(stream.networkCaching)ms")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(3)
                            .foregroundColor(.blue)
                        
                        // Enhanced PiP 지원 표시
                        if PictureInPictureManager.shared.isPiPSupported {
                            Image(systemName: "pip")
                                .font(.caption2)
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
