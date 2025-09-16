import Foundation
import Combine
import SwiftUI

// RTSP 스트림 정보 모델
struct RTSPStream: Identifiable, Codable {
    var id = UUID() // var로 변경하여 Codable 경고 해결
    var name: String
    var url: String
    var username: String?
    var password: String?
    var networkCaching: Int = 150
    
    // Codable을 위한 명시적 CodingKeys
    enum CodingKeys: String, CodingKey {
        case id, name, url, username, password, networkCaching
    }
    
    // 기본 생성자
    init(name: String, url: String, username: String? = nil, password: String? = nil, networkCaching: Int = 150) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.networkCaching = networkCaching
    }
}

// 플레이어 상태
enum PlayerState {
    case idle
    case loading
    case playing
    case paused
    case error(String)
}

// RTSP 플레이어 뷰모델
class RTSPViewModel: ObservableObject {
    
    // Published Properties
    @Published var streams: [RTSPStream] = []
    @Published var selectedStream: RTSPStream?
    @Published var playerState: PlayerState = .idle
    @Published var isPlaying: Bool = false
    @Published var currentStreamURL: String = ""
    @Published var networkCaching: Int = 150
    @Published var showSettings: Bool = false
    @Published var isPiPActive: Bool = false
    @Published var volume: Float = 1.0
    
    // 저지연 프리셋
    enum LatencyPreset: String, CaseIterable {
        case ultraLow = "초저지연 (50ms)"
        case low = "저지연 (150ms)"
        case normal = "일반 (300ms)"
        case high = "안정성 우선 (500ms)"
        
        var cachingValue: Int {
            switch self {
            case .ultraLow: return 50
            case .low: return 150
            case .normal: return 300
            case .high: return 500
            }
        }
    }
    
    @Published var selectedLatencyPreset: LatencyPreset = .low {
        didSet {
            networkCaching = selectedLatencyPreset.cachingValue
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadSavedStreams()
        setupDefaultStreams()
    }
    
    // 기본 테스트 스트림 설정
    private func setupDefaultStreams() {
        if streams.isEmpty {
            streams = [
                RTSPStream(
                    name: "테스트 스트림 1",
                    url: "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mp4",
                    networkCaching: 150
                ),
                RTSPStream(
                    name: "테스트 스트림 2", 
                    url: "rtsp://demo.streamlock.net/vod/sample.mp4",
                    networkCaching: 150
                ),
                RTSPStream(
                    name: "로컬 IP 카메라",
                    url: "rtsp://192.168.1.100:554/stream",
                    username: "admin",
                    password: "password",
                    networkCaching: 100
                )
            ]
        }
    }
    
    // 스트림 추가
    func addStream(_ stream: RTSPStream) {
        streams.append(stream)
        saveStreams()
    }
    
    // 스트림 삭제
    func deleteStream(at offsets: IndexSet) {
        streams.remove(atOffsets: offsets)
        saveStreams()
    }
    
    // 스트림 선택 및 재생
    func selectStream(_ stream: RTSPStream) {
        selectedStream = stream
        currentStreamURL = stream.url
        networkCaching = stream.networkCaching
        playerState = .loading
        isPlaying = true
    }
    
    // 재생/일시정지 토글
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    // 재생
    func play() {
        if let stream = selectedStream {
            currentStreamURL = stream.url
            isPlaying = true
            playerState = .playing
        }
    }
    
    // 일시정지
    func pause() {
        isPlaying = false
        playerState = .paused
    }
    
    // 정지
    func stop() {
        isPlaying = false
        currentStreamURL = ""
        playerState = .idle
        selectedStream = nil
    }
    
    // 볼륨 조절
    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
    }
    
    // 저지연 설정 적용
    func applyLatencySettings(_ preset: LatencyPreset) {
        selectedLatencyPreset = preset
        if var stream = selectedStream {
            stream.networkCaching = preset.cachingValue
            selectedStream = stream
            
            // 스트림 목록 업데이트
            if let index = streams.firstIndex(where: { $0.id == stream.id }) {
                streams[index] = stream
                saveStreams()
            }
        }
    }
    
    // UserDefaults에 스트림 저장
    private func saveStreams() {
        if let encoded = try? JSONEncoder().encode(streams) {
            UserDefaults.standard.set(encoded, forKey: "SavedRTSPStreams")
        }
    }
    
    // UserDefaults에서 스트림 불러오기
    private func loadSavedStreams() {
        if let data = UserDefaults.standard.data(forKey: "SavedRTSPStreams"),
           let decoded = try? JSONDecoder().decode([RTSPStream].self, from: data) {
            streams = decoded
        }
    }
    
    // URL 유효성 검사
    func isValidRTSPURL(_ url: String) -> Bool {
        let pattern = "^rtsp://.*"
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: url.utf16.count)
        return regex?.firstMatch(in: url, options: [], range: range) != nil
    }
    
    // 네트워크 상태 모니터링
    func monitorNetworkStatus() {
        // 네트워크 상태 변경 감지 로직
        // 실제 구현시 Network.framework 사용
    }
    
    // 스트림 재연결
    func reconnectStream() {
        if let stream = selectedStream {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.selectStream(stream)
            }
        }
    }
}
