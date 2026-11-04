import SwiftUI

@main
struct OfflineTalkApp: App {
    @StateObject private var radio = RadioManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(radio)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var radio: RadioManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var channel = 1

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 20) {
                Picker("チャンネル", selection: $channel) {
                    ForEach(1...10, id: \.self) { number in
                        Text("チャンネル \(number)").tag(number)
                    }
                }
                .pickerStyle(.menu)
                .disabled(radio.isActive)

                HStack(spacing: 16) {
                    Button("親機を開始") {
                        radio.startHost(channel: channel)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(radio.isActive)

                    Button("子機を探す") {
                        radio.startBrowsing(channel: channel)
                    }
                    .buttonStyle(.bordered)
                    .disabled(radio.isActive)
                }

                if radio.isActive {
                    Button("通信を終了", role: .destructive) {
                        radio.stop()
                    }
                    .buttonStyle(.bordered)
                }

                GroupBox("状態") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(radio.status)
                        if let speaker = radio.activeSpeakerName {
                            Label("送話中: \(speaker)", systemImage: "waveform")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if radio.isHosting {
                            Text("接続中の子機: \(radio.connectedPeerCount) / 4")
                            Text("他の端末からチャンネル \(channel) の親機として表示されます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(radio.connectedPeers.enumerated()), id: \.offset) { item in
                                Label(item.element, systemImage: "iphone")
                                    .font(.caption)
                            }
                        }
                        if !radio.recentNotice.isEmpty {
                            Text(radio.recentNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if radio.isActive && !radio.isBrowsing {
                    VStack(spacing: 8) {
                        Button(action: {}) {
                            Text(radio.isPTTActive ? "送話中" : radio.isWaitingForFloor ? "確認中…" : "押して話す")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 180, height: 180)
                                .background(radio.isPTTActive ? Color.red : Color.blue, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in radio.beginPTT() }
                                .onEnded { _ in radio.endPTT() }
                        )
                        .accessibilityLabel(radio.isPTTActive ? "送話中" : "PTT送話")
                        .accessibilityHint("通常は押している間だけ送話します。VoiceOverでは実行のたびに送話を開始または終了します。")
                        .accessibilityAction(.activate) {
                            if radio.isPTTActive || radio.isWaitingForFloor {
                                radio.endPTT()
                            } else {
                                radio.beginPTT()
                            }
                        }
                        .disabled(!radio.canUsePTT || radio.isContinuousTalkEnabled)

                        Text(radio.isContinuousTalkEnabled
                             ? "常時送話中です。停止ボタンで終了します"
                             : radio.canUsePTT ? "押している間だけ送話します" : "接続とマイクの許可が必要です")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(radio.isContinuousTalkEnabled ? "常時送話を終了" : "常時送話を開始") {
                            radio.toggleContinuousTalk()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!radio.canUsePTT || (!radio.isContinuousTalkEnabled && (radio.isWaitingForFloor || radio.isPTTActive)))
                    }
                }

                if radio.isBrowsing {
                    GroupBox("見つかった親機") {
                        if radio.foundHosts.isEmpty {
                            Text("検索中です。両方の端末でWi-Fiをオンにし、近くに置いてください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(radio.foundHosts) { host in
                                Button {
                                    radio.connect(to: host)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(host.displayName)
                                            Text("チャンネル \(host.channel)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(radio.isConnecting)
                            }
                        }
                    }
                }

                Spacer()

                Text("音声は未実機検証の試作です。送話は一度に1台です。アプリが前面から外れると送話を終了します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            }
            .navigationTitle("OFFLINE TALK")
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                radio.appWillResignActive()
            } else {
                radio.appDidBecomeActive()
            }
        }
    }
}
