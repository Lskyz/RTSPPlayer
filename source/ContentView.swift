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
            
            Text(viewModel.selectedStream?.name ?? "스트림")
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
            // PiP 버튼
            if pipManager.isPiPSupported {
                Button(action: {
                    pipManager.togglePiP()
                }) {
                    Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                        .font(.title2)
                        .foregroundColor(pipManager.isPiPPossible ? .white : .gray)
                }
                .disabled(!pipManager.isPiPPossible)
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
            
            // 지연 설정
            VStack(alignment: .leading, spacing: 8) {
                Text("지연 설정: \(viewModel.selectedLatencyPreset.rawValue)")
                    .font(.caption)
                    .foregroundColor(.gray)
                
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
                
                Section(header: Text("PiP 설정")) {
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
                            Text(pipManager.isPiPActive ? "활성" : "비활성")
                                .foregroundColor(pipManager.isPiPActive ? .green : .gray)
                        }
                    }
                }
                
                Section(header: Text("정보")) {
                    HStack {
                        Text("버전")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("VLCKit 버전")
                        Spacer()
                        Text("3.5.1")
                            .foregroundColor(.gray)
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
}

// MARK: - Stream Row View
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
                    
                    if stream.username != nil {
                        Label("인증 필요", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
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
