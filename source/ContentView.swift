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
            .navigationTitle("RTSP 플레이어 Pro")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddStream = true }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.blue)
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { viewModel.showSettings.toggle() }) {
                        Image(systemName: "gear")
                            .foregroundColor(.blue)
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
        .onAppear {
            // iOS 15+ 샘플 버퍼 PiP 설정
            if #available(iOS 15.0, *) {
                pipManager.setupSampleBufferPiP()
            }
        }
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
                            .fontWeight(.semibold)
                    }
                    
                    if let stream = viewModel.selectedStream {
                        HStack {
                            Text("재생 중:")
                            Spacer()
                            Text(stream.name)
                                .lineLimit(1)
                                .fontWeight(.medium)
                        }
                        
                        HStack {
                            Text("지연 시간:")
                            Spacer()
                            Text("\(stream.networkCaching)ms")
                                .foregroundColor(stream.networkCaching <= 50 ? .green : .orange)
                                .fontWeight(.semibold)
                        }
                    }
                }
                
                Section(header: Text("PiP 상태")) {
                    HStack {
                        Text("PiP 지원:")
                        Spacer()
                        Text(pipManager.isPiPSupported ? "✅ 지원됨" : "❌ 미지원")
                            .foregroundColor(pipManager.isPiPSupported ? .green : .red)
                    }
                    
                    HStack {
                        Text("PiP 상태:")
                        Spacer()
                        Text(pipManager.isPiPActive ? "🎭 활성" : "⏸️ 비활성")
                            .foregroundColor(pipManager.isPiPActive ? .green : .gray)
                    }
                    
                    if pipManager.forcePiPEnabled {
                        HStack {
                            Text("강제 PiP:")
                            Spacer()
                            Text("🚀 활성화됨")
                                .foregroundColor(.orange)
                                .fontWeight(.bold)
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
            Color.black.opacity(0.95)
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
                    networkCaching: max(30, viewModel.networkCaching) // 최소 30ms
                )
                .aspectRatio(16/9, contentMode: .fit)
                .background(Color.black)
                .cornerRadius(12)
                .padding(.horizontal)
                
                // 컨트롤러
                playerControls
            }
        }
        .transition(.move(edge: .bottom))
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: showPlayer)
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
            
            VStack {
                Text(viewModel.selectedStream?.name ?? "스트림")
                    .font(.headline)
                    .foregroundColor(.white)
                
                if let stream = viewModel.selectedStream {
                    Text("\(stream.networkCaching)ms 지연")
                        .font(.caption)
                        .foregroundColor(stream.networkCaching <= 50 ? .green : .orange)
                }
            }
            
            Spacer()
            
            // PiP 버튼들
            HStack(spacing: 16) {
                // 일반 PiP 버튼
                if pipManager.isPiPSupported {
                    Button(action: {
                        pipManager.togglePiP()
                    }) {
                        Image(systemName: pipManager.isPiPActive ? "pip.exit" : "pip.enter")
                            .font(.title2)
                            .foregroundColor(pipManager.isPiPPossible ? .white : .gray)
                    }
                    .disabled(!pipManager.isPiPPossible && !pipManager.forcePiPEnabled)
                }
                
                // 강제 PiP 버튼
                Button(action: {
                    pipManager.forceStartPiP()
                }) {
                    Image(systemName: "pip.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                }
                .disabled(!pipManager.isPiPSupported)
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Player Controls
    private var playerControls: some View {
        VStack(spacing: 20) {
            // 메인 재생 컨트롤
            HStack(spacing: 40) {
                Button(action: viewModel.reconnectStream) {
                    VStack {
                        Image(systemName: "arrow.clockwise")
                            .font(.title2)
                        Text("재연결")
                            .font(.caption)
                    }
                    .foregroundColor(.white)
                }
                
                Button(action: viewModel.togglePlayPause) {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                }
                
                Button(action: { viewModel.showSettings = true }) {
                    VStack {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                        Text("설정")
                            .font(.caption)
                    }
                    .foregroundColor(.white)
                }
            }
            
            // 볼륨 컨트롤
            HStack {
                Image(systemName: viewModel.volume > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill")
                    .foregroundColor(.white)
                
                Slider(value: $viewModel.volume, in: 0...1) { editing in
                    // 슬라이더 변경시 볼륨 적용
                    if !editing {
                        viewModel.setVolume(viewModel.volume)
                    }
                }
                .accentColor(.white)
                
                Text("\(Int(viewModel.volume * 100))")
                    .font(.caption)
                    .foregroundColor(.white)
                    .frame(width: 30)
            }
            .padding(.horizontal)
            
            // 초저지연 프리셋 설정
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("🚀 지연 설정")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Text(viewModel.selectedLatencyPreset.rawValue)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fontWeight(.semibold)
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
            
            // PiP 컨트롤 섹션
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("🎭 Picture in Picture")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    if pipManager.isPiPActive {
                        Text("활성")
                            .font(.caption)
                            .foregroundColor(.green)
                            .fontWeight(.semibold)
                    }
                }
                
                HStack(spacing: 16) {
                    // 일반 PiP
                    Button(action: {
                        pipManager.startPiP()
                    }) {
                        HStack {
                            Image(systemName: "pip.enter")
                            Text("일반 PiP")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(pipManager.isPiPPossible ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(!pipManager.isPiPPossible)
                    
                    // 강제 PiP
                    Button(action: {
                        pipManager.forceStartPiP()
                    }) {
                        HStack {
                            Image(systemName: "pip.fill")
                            Text("강제 PiP")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(!pipManager.isPiPSupported)
                    
                    // PiP 중지
                    if pipManager.isPiPActive {
                        Button(action: {
                            pipManager.stopPiP()
                        }) {
                            HStack {
                                Image(systemName: "pip.exit")
                                Text("PiP 종료")
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                    
                    Spacer()
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
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("인증 정보 (선택사항)")) {
                    TextField("사용자명", text: $newStreamUsername)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("비밀번호", text: $newStreamPassword)
                }
                
                Section(header: Text("샘플 URL")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("테스트 스트림 1") {
                            newStreamURL = "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mp4"
                            newStreamName = "BigBuckBunny 테스트"
                        }
                        
                        Button("테스트 스트림 2") {
                            newStreamURL = "rtsp://demo.streamlock.net/vod/sample.mp4"
                            newStreamName = "Sample 테스트"
                        }
                        
                        Button("로컬 IP 카메라 예시") {
                            newStreamURL = "rtsp://192.168.1.100:554/stream"
                            newStreamName = "로컬 IP 카메라"
                            newStreamUsername = "admin"
                            newStreamPassword = "password"
                        }
                    }
                    .font(.caption)
                }
                
                Section {
                    Button(action: addNewStream) {
                        Text("스트림 추가")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
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
                Section(header: Text("초저지연 설정")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("네트워크 캐싱: \(viewModel.networkCaching)ms")
                            .fontWeight(.semibold)
                        
                        Slider(value: Binding(
                            get: { Double(viewModel.networkCaching) },
                            set: { viewModel.networkCaching = max(30, Int($0)) }
                        ), in: 30...1000, step: 10)
                        
                        HStack {
                            Text("30ms (초저지연)")
                                .font(.caption)
                                .foregroundColor(.green)
                            Spacer()
                            Text("1000ms (안정성)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Text("⚠️ 30ms 이하는 불안정할 수 있습니다")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Section(header: Text("PiP 정보")) {
                    HStack {
                        Text("기기 PiP 지원")
                        Spacer()
                        Text(pipManager.isPiPSupported ? "✅ 지원" : "❌ 미지원")
                            .foregroundColor(pipManager.isPiPSupported ? .green : .red)
                    }
                    
                    HStack {
                        Text("PiP 현재 상태")
                        Spacer()
                        Text(pipManager.isPiPActive ? "🎭 활성" : "⏸️ 비활성")
                            .foregroundColor(pipManager.isPiPActive ? .green : .gray)
                    }
                    
                    HStack {
                        Text("강제 PiP 모드")
                        Spacer()
                        Text(pipManager.forcePiPEnabled ? "🚀 활성" : "❌ 비활성")
                            .foregroundColor(pipManager.forcePiPEnabled ? .orange : .gray)
                    }
                    
                    if pipManager.isPiPSupported {
                        Button("강제 PiP 테스트") {
                            pipManager.forceStartPiP()
                        }
                        .foregroundColor(.orange)
                    }
                }
                
                Section(header: Text("앱 정보")) {
                    HStack {
                        Text("버전")
                        Spacer()
                        Text("1.0.0 Pro")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("VLCKit 버전")
                        Spacer()
                        Text("3.6.0")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("최적화")
                        Spacer()
                        Text("초저지연 + 강제 PiP")
                            .foregroundColor(.green)
                            .fontWeight(.semibold)
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
            networkCaching: max(30, viewModel.networkCaching) // 최소 30ms
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
        case .playing: return "🚀 재생 중 (초저지연)"
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

// MARK: - Stream Row View (향상된 버전)
struct StreamRowView: View {
    let stream: RTSPStream
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stream.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(stream.url)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    
                    HStack {
                        if stream.username != nil {
                            Label("인증", systemImage: "lock.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        
                        Label("\(stream.networkCaching)ms", systemImage: "speedometer")
                            .font(.caption2)
                            .foregroundColor(stream.networkCaching <= 50 ? .green : .blue)
                    }
                }
                
                Spacer()
                
                VStack {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    if stream.networkCaching <= 50 {
                        Text("초저지연")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .fontWeight(.bold)
                    }
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
