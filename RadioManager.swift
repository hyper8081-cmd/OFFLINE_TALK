import Foundation
import CryptoKit
import Network
import SwiftUI
import UIKit
import UserNotifications
import Security

struct FoundHost: Identifiable {
    let id: String
    let displayName: String
    let channel: Int
    let endpoint: NWEndpoint
}

private struct PendingSend {
    let packet: Data
    let isAudio: Bool
}

private struct PeerRoster: Codable {
    let hostName: String
    let peers: [String]
}

@MainActor
final class RadioManager: ObservableObject {
    @Published private(set) var status = "待機中"
    @Published private(set) var isActive = false
    @Published private(set) var isHosting = false
    @Published private(set) var isBrowsing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectedPeerCount = 0
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var connectedHostName: String?
    @Published private(set) var connectedPeerNames: [String] = []
    @Published private(set) var foundHosts: [FoundHost] = []
    @Published private(set) var recentNotice = ""
    @Published private(set) var activeSpeakerName: String?
    @Published private(set) var isPTTActive = false
    @Published private(set) var isWaitingForFloor = false
    @Published private(set) var isContinuousTalkEnabled = false
    @Published private(set) var audioReady = false
    @Published private(set) var hostAccessCode = ""
    @Published private(set) var savedJoinSecret = ""

    var canUsePTT: Bool {
        if isHosting { return connectedPeerCount > 0 && audioReady }
        return clientConnection != nil && audioReady && !isConnecting
    }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var clientConnection: NWConnection?
    private var hostConnections: [ObjectIdentifier: NWConnection] = [:]
    private var readyHostConnections = Set<ObjectIdentifier>()
    private var pendingSends: [ObjectIdentifier: [PendingSend]] = [:]
    private var sendingConnections = Set<ObjectIdentifier>()
    private var hostReceiveBuffers: [ObjectIdentifier: Data] = [:]
    private var peerNames: [ObjectIdentifier: String] = [:]
    private var receiveStarted = Set<ObjectIdentifier>()
    private var authenticationTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var clientReceiveBuffer = Data()
    private var selectedChannel = 1
    private var currentTalker: ObjectIdentifier?
    private var hostIsTalking = false
    private var pttPressed = false
    private var audioStarting = false
    private var lifecycleGeneration = 0
    private var preferredHost: FoundHost?
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isAutomaticallySearching = false
    private let serviceType = "_offlinetalk._tcp"
    private let audio = AudioIO()
    private var sessionKey: SymmetricKey? {
        let raw = KeychainSecretStore.read(account: isHosting ? "host" : "join") ?? ""
        guard raw.count == 32, let data = Self.data(fromHex: raw) else { return nil }
        return SymmetricKey(data: data)
    }

    init() {
        savedJoinSecret = KeychainSecretStore.migrateAndRead(account: "join", legacyDefaultsKey: "offlineTalkJoinSecret") ?? ""
        _ = KeychainSecretStore.migrateAndRead(account: "host", legacyDefaultsKey: "offlineTalkHostSecret")
        audio.onCapturedPCM = { [weak self] pcm in
            Task { @MainActor in
                self?.sendAudio(pcm)
            }
        }
    }

    func saveJoinSecret(_ value: String) {
        guard value.count == 32 || value.isEmpty else { return }
        guard KeychainSecretStore.write(value, account: "join") else {
            status = "参加コードを安全に保存できませんでした"
            return
        }
        savedJoinSecret = value
    }

    func startHost(channel: Int) {
        stop()
        selectedChannel = channel
        hostAccessCode = Self.persistentHostSecret()
        guard hostAccessCode.count == 32 else {
            status = "参加コードをKeychainに保存できないため親機を開始できません"
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let newListener = try NWListener(using: parameters)
            let suffix = Self.persistentHostCode()
            newListener.service = NWListener.Service(
                name: "OT-CH\(String(format: "%02d", channel))-\(suffix)",
                type: serviceType
            )
            newListener.newConnectionHandler = { [weak self, weak newListener] connection in
                Task { @MainActor in
                    guard let self, let newListener, self.listener === newListener else { return }
                    self.accept(connection)
                }
            }
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                Task { @MainActor in
                    guard let self, let newListener, self.listener === newListener else { return }
                    self.handleListenerState(state)
                }
            }
            listener = newListener
            isActive = true
            isHosting = true
            status = "チャンネル \(channel) の親機を起動中…"
            newListener.start(queue: .main)
        } catch {
            status = "親機を開始できませんでした: \(error.localizedDescription)"
            stop(clearStatus: false)
        }
    }

    func startBrowsing(channel: Int) {
        stop()
        selectedChannel = channel
        beginBrowsing(channel: channel, automatically: false)
    }

    private func beginBrowsing(channel: Int, automatically: Bool) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )
        newBrowser.browseResultsChangedHandler = { [weak self, weak newBrowser] results, _ in
            let hosts = results.compactMap { result -> FoundHost? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      let parsed = Self.parseServiceName(name),
                      parsed.channel == channel else { return nil }
                return FoundHost(
                    id: name,
                    displayName: "親機 \(parsed.suffix)",
                    channel: parsed.channel,
                    endpoint: result.endpoint
                )
            }
            Task { @MainActor in
                guard let self, let newBrowser, self.browser === newBrowser else { return }
                self.foundHosts = hosts.sorted { $0.displayName < $1.displayName }
                if self.isAutomaticallySearching,
                   let preferredID = self.preferredHost?.id,
                   let match = hosts.first(where: { $0.id == preferredID }) {
                    self.isAutomaticallySearching = false
                    self.connect(to: match, automatically: true)
                }
            }
        }
        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            Task { @MainActor in
                guard let self, let newBrowser, self.browser === newBrowser else { return }
                self.handleBrowserState(state)
            }
        }
        browser = newBrowser
        isActive = true
        isBrowsing = true
        isAutomaticallySearching = automatically
        foundHosts = []
        status = automatically ? "親機を再検索中…" : "チャンネル \(channel) の親機を検索中…"
        newBrowser.start(queue: .main)
    }

    func connect(to host: FoundHost, automatically: Bool = false) {
        guard !isConnecting else { return }
        if !automatically {
            preferredHost = host
            reconnectAttempt = 0
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        isAutomaticallySearching = false
        isConnecting = true
        connectedHostName = nil
        connectedPeerNames = []
        status = "\(host.displayName) に接続中…"
        browser?.cancel()
        browser = nil
        isBrowsing = false

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: host.endpoint, using: parameters)
        clientReceiveBuffer.removeAll(keepingCapacity: true)
        clientConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection,
                      self.clientConnection === connection else { return }
                switch state {
                case .ready:
                    guard self.clientConnection === connection else { return }
                    self.isConnecting = false
                    self.connectedHostName = Self.safePeerName(host.displayName)
                    self.reconnectAttempt = 0
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.connectionTimeoutTask?.cancel()
                    self.connectionTimeoutTask = nil
                    self.isAutomaticallySearching = false
                    self.status = "親機に接続しました（チャンネル \(host.channel)）"
                    self.recentNotice = automatically ? "親機に再接続しました" : "親機に接続しました"
                    if automatically { self.notifyIfBackground(title: "再接続しました", body: "OFFLINE TALKの親機に再接続しました。") }
                    self.send(type: Wire.hello, payload: Data(Self.localDisplayName().utf8), through: connection)
                    self.startAudioIfNeeded()
                    self.receiveNext(from: connection)
                case .failed(let error):
                    guard self.clientConnection === connection else { return }
                    self.connectionTimeoutTask?.cancel()
                    self.connectionTimeoutTask = nil
                    self.clientConnection = nil
                    self.connectedHostName = nil
                    self.connectedPeerNames = []
                    self.clientReceiveBuffer.removeAll(keepingCapacity: true)
                    self.receiveStarted.remove(ObjectIdentifier(connection))
                    self.pendingSends.removeValue(forKey: ObjectIdentifier(connection))
                    self.sendingConnections.remove(ObjectIdentifier(connection))
                    self.isConnecting = false
                    self.audio.stop()
                    self.audioReady = false
                    self.isPTTActive = false
                    self.isWaitingForFloor = false
                    self.isContinuousTalkEnabled = false
                    self.pttPressed = false
                    self.activeSpeakerName = nil
                    self.status = "接続が切れました: \(error.localizedDescription)"
                    self.recentNotice = "親機との接続が切れました。再接続します"
                    self.notifyIfBackground(title: "接続が切れました", body: "親機との接続が切れました。再接続を試みます。")
                    self.scheduleReconnect()
                case .cancelled:
                    guard self.clientConnection === connection else { return }
                    self.connectionTimeoutTask?.cancel()
                    self.connectionTimeoutTask = nil
                    self.clientConnection = nil
                    self.connectedHostName = nil
                    self.connectedPeerNames = []
                    self.clientReceiveBuffer.removeAll(keepingCapacity: true)
                    self.receiveStarted.remove(ObjectIdentifier(connection))
                    self.pendingSends.removeValue(forKey: ObjectIdentifier(connection))
                    self.sendingConnections.remove(ObjectIdentifier(connection))
                    self.isConnecting = false
                    self.audio.stop()
                    self.audioReady = false
                    self.isPTTActive = false
                    self.isWaitingForFloor = false
                    self.isContinuousTalkEnabled = false
                    self.pttPressed = false
                    self.activeSpeakerName = nil
                    if self.isActive {
                        self.status = "親機との接続が終了しました。再接続します"
                        self.recentNotice = self.status
                        self.notifyIfBackground(title: "接続が切れました", body: "親機との接続が終了しました。再接続を試みます。")
                        self.scheduleReconnect()
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
            guard let self, let connection, !Task.isCancelled,
                  self.clientConnection === connection, self.isConnecting else { return }
            self.clientConnection = nil
            self.isConnecting = false
            self.clientReceiveBuffer.removeAll(keepingCapacity: true)
            self.pendingSends.removeValue(forKey: ObjectIdentifier(connection))
            self.sendingConnections.remove(ObjectIdentifier(connection))
            connection.cancel()
            self.status = "親機への接続がタイムアウトしました"
            self.recentNotice = "親機を再検索します"
            self.scheduleReconnect()
        }
    }

    func beginPTT() {
        guard canUsePTT, !pttPressed else { return }
        pttPressed = true
        if isHosting {
            guard currentTalker == nil, !hostIsTalking else {
                status = "他の端末が送話中です"
                if isContinuousTalkEnabled {
                    isContinuousTalkEnabled = false
                    pttPressed = false
                }
                return
            }
            hostIsTalking = true
            isPTTActive = true
            activeSpeakerName = Self.localDisplayName()
            audio.setTransmitting(true)
            status = "送話中（\(activeSpeakerName ?? "親機")）"
            broadcast(type: Wire.talkStarted, payload: Data((activeSpeakerName ?? "親機").utf8))
        } else if let clientConnection {
            isWaitingForFloor = true
            status = "発言権を確認中…"
            send(type: Wire.requestFloor, payload: Data(), through: clientConnection)
        }
    }

    func endPTT() {
        pttPressed = false
        if isHosting {
            guard hostIsTalking else { return }
            hostIsTalking = false
            isPTTActive = false
            activeSpeakerName = nil
            audio.setTransmitting(false)
            status = "親機として待機中（チャンネル \(selectedChannel)）"
            broadcast(type: Wire.talkEnded, payload: Data())
        } else if let clientConnection, isWaitingForFloor || isPTTActive {
            send(type: Wire.releaseFloor, payload: Data(), through: clientConnection)
            isWaitingForFloor = false
            isPTTActive = false
            activeSpeakerName = nil
            audio.setTransmitting(false)
            status = "親機に接続しました（チャンネル \(selectedChannel)）"
        }
    }

    func toggleContinuousTalk() {
        if isContinuousTalkEnabled {
            isContinuousTalkEnabled = false
            endPTT()
            return
        }
        guard canUsePTT, !pttPressed, !isWaitingForFloor else { return }
        isContinuousTalkEnabled = true
        beginPTT()
    }

    /// Release the floor whenever iOS removes the app from the foreground.
    /// PTT and continuous talk are intentionally foreground-only in this prototype.
    func appWillResignActive() {
        guard isPTTActive || isWaitingForFloor || isContinuousTalkEnabled else { return }
        isContinuousTalkEnabled = false
        endPTT()
    }

    /// Retry audio initialization after returning from Settings to enable microphone access.
    func appDidBecomeActive() {
        guard isActive, !audioReady, !audioStarting,
              isHosting || clientConnection != nil else { return }
        startAudioIfNeeded()
    }

    func stop(clearStatus: Bool = true) {
        endPTT()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        clientConnection?.cancel()
        clientConnection = nil
        for connection in hostConnections.values { connection.cancel() }
        hostConnections.removeAll()
        readyHostConnections.removeAll()
        pendingSends.removeAll()
        sendingConnections.removeAll()
        hostReceiveBuffers.removeAll()
        peerNames.removeAll()
        receiveStarted.removeAll()
        for timeout in authenticationTimeouts.values { timeout.cancel() }
        authenticationTimeouts.removeAll()
        clientReceiveBuffer.removeAll()
        connectedPeerCount = 0
        connectedPeers = []
        connectedHostName = nil
        connectedPeerNames = []
        isActive = false
        isHosting = false
        isBrowsing = false
        isConnecting = false
        isPTTActive = false
        isWaitingForFloor = false
        isContinuousTalkEnabled = false
        pttPressed = false
        lifecycleGeneration &+= 1
        audioStarting = false
        currentTalker = nil
        hostIsTalking = false
        activeSpeakerName = nil
        preferredHost = nil
        reconnectAttempt = 0
        isAutomaticallySearching = false
        foundHosts = []
        audio.stop()
        audioReady = false
        if clearStatus { status = "待機中" }
        if clearStatus { recentNotice = "" }
    }

    private func accept(_ connection: NWConnection) {
        guard isHosting, hostConnections.count < 4 else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        hostConnections[key] = connection
        hostReceiveBuffers[key] = Data()
        authenticationTimeouts[key] = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            guard let self, let connection,
                  self.hostConnections[key] === connection,
                  self.peerNames[key] == nil else { return }
            connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection,
                      self.hostConnections[key] === connection else { return }
                switch state {
                case .ready:
                    self.readyHostConnections.insert(key)
                    self.connectedPeerCount = self.readyHostConnections.count
                    self.refreshPeerList()
                    self.broadcastPeerRoster()
                    self.status = "親機として待機中（チャンネル \(self.selectedChannel)）"
                    self.startAudioIfNeeded()
                    self.receiveNext(from: connection)
                case .failed, .cancelled:
                    self.hostConnections.removeValue(forKey: key)
                    self.authenticationTimeouts.removeValue(forKey: key)?.cancel()
                    let wasReady = self.readyHostConnections.remove(key) != nil
                    self.pendingSends.removeValue(forKey: key)
                    self.sendingConnections.remove(key)
                    self.hostReceiveBuffers.removeValue(forKey: key)
                    self.receiveStarted.remove(key)
                    guard self.isHosting else { return }
                    let peerName = self.peerNames.removeValue(forKey: key) ?? "子機"
                    if wasReady {
                        self.recentNotice = "\(peerName)が切断しました"
                        self.notifyIfBackground(title: "子機が切断しました", body: "\(peerName)との接続が切れました。")
                    }
                    if self.currentTalker == key {
                        self.currentTalker = nil
                        self.activeSpeakerName = nil
                        self.broadcast(type: Wire.talkEnded, payload: Data())
                    }
                    self.connectedPeerCount = self.readyHostConnections.count
                    self.refreshPeerList()
                    self.broadcastPeerRoster()
                    if self.isHosting {
                        self.status = "親機として待機中（チャンネル \(self.selectedChannel)）"
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func startAudioIfNeeded() {
        guard !audioReady, !audioStarting else { return }
        audioStarting = true
        let generation = lifecycleGeneration
        audio.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard generation == self.lifecycleGeneration, self.isActive else {
                    self.audio.stop()
                    return
                }
                self.audioStarting = false
                switch result {
                case .success:
                    self.audioReady = true
                    self.requestNotificationPermission()
                    if self.isHosting {
                        self.status = "親機として待機中（チャンネル \(self.selectedChannel)）"
                    } else if self.clientConnection != nil {
                        self.status = "親機に接続しました（チャンネル \(self.selectedChannel)）"
                    }
                case .failure(let error):
                    self.requestNotificationPermission()
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func receiveNext(from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard receiveStarted.insert(key).inserted else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }
            Task { @MainActor in
                guard self.isCurrentConnection(connection) else { return }
                self.receiveStarted.remove(key)
                if let content, !content.isEmpty {
                    self.appendAndProcess(content, from: connection)
                }
                if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                self.receiveNext(from: connection)
            }
        }
    }

    private func appendAndProcess(_ bytes: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard isCurrentConnection(connection) else { return }
        var buffer: Data
        if isHosting {
            buffer = hostReceiveBuffers[key, default: Data()]
        } else {
            buffer = clientReceiveBuffer
        }
        buffer.append(bytes)

        while buffer.count >= 4 {
            let base = buffer.startIndex
            let length = (Int(buffer[base]) << 24)
                | (Int(buffer[base + 1]) << 16)
                | (Int(buffer[base + 2]) << 8)
                | Int(buffer[base + 3])
            guard length > 0, length <= 32_768 else {
                connection.cancel()
                return
            }
            guard buffer.count >= length + 4 else { break }
            let message = buffer.subdata(in: (base + 4)..<(base + 4 + length))
            buffer.removeSubrange(base..<(base + 4 + length))
            handle(message, from: connection)
        }

        if isHosting { hostReceiveBuffers[key] = buffer }
        else { clientReceiveBuffer = buffer }
    }

    private func handle(_ message: Data, from connection: NWConnection) {
        guard let key = sessionKey,
              let sealed = try? AES.GCM.SealedBox(combined: message),
              let plaintext = try? AES.GCM.open(sealed, using: key),
              let type = plaintext.first else {
            connection.cancel()
            return
        }
        if isHosting {
            authenticationTimeouts.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        }
        let payload = plaintext.dropFirst()
        if type == Wire.audio,
           (payload.isEmpty || payload.count % MemoryLayout<Int16>.size != 0
            || payload.count > Wire.maximumAudioPayloadBytes) {
            connection.cancel()
            return
        }
        if isHosting {
            handleAtHost(type: type, payload: Data(payload), from: connection)
        } else {
            handleAtClient(type: type, payload: Data(payload))
        }
    }

    private func handleAtHost(type: UInt8, payload: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        switch type {
        case Wire.hello:
            let announcedName = Self.safePeerName(String(decoding: payload.prefix(160), as: UTF8.self))
            peerNames[key] = announcedName.isEmpty ? "子機" : announcedName
            refreshPeerList()
            broadcastPeerRoster()
            recentNotice = "\(peerNames[key] ?? "子機")が接続しました"
        case Wire.requestFloor:
            guard currentTalker == nil, !hostIsTalking else {
                send(type: Wire.floorDenied, payload: Data(), through: connection)
                return
            }
            currentTalker = key
            activeSpeakerName = peerNames[key] ?? "子機"
            status = "受信中：\(activeSpeakerName ?? "子機")"
            send(type: Wire.floorGranted, payload: Data(), through: connection)
            broadcast(type: Wire.talkStarted, payload: Data((activeSpeakerName ?? "子機").utf8), excluding: key)
        case Wire.releaseFloor:
            guard currentTalker == key else { return }
            currentTalker = nil
            activeSpeakerName = nil
            status = "親機として待機中（チャンネル \(selectedChannel)）"
            broadcast(type: Wire.talkEnded, payload: Data())
        case Wire.audio:
            guard currentTalker == key else { return }
            audio.play(pcm16Mono: payload)
            broadcast(type: Wire.audio, payload: payload, excluding: key)
        default:
            break
        }
    }

    private func handleAtClient(type: UInt8, payload: Data) {
        switch type {
        case Wire.floorGranted:
            guard isWaitingForFloor, pttPressed else {
                if let clientConnection {
                    send(type: Wire.releaseFloor, payload: Data(), through: clientConnection)
                }
                return
            }
            isWaitingForFloor = false
            isPTTActive = true
            activeSpeakerName = Self.localDisplayName()
            audio.setTransmitting(true)
            status = "送話中"
        case Wire.floorDenied:
            guard isWaitingForFloor else { return }
            let wasContinuous = isContinuousTalkEnabled
            isWaitingForFloor = false
            isContinuousTalkEnabled = false
            if wasContinuous { pttPressed = false }
            status = "他の端末が送話中です"
        case Wire.talkStarted:
            let speaker = String(decoding: payload.prefix(80), as: UTF8.self)
            activeSpeakerName = speaker.isEmpty ? "他の端末" : speaker
            if !isPTTActive { status = "受信中：\(activeSpeakerName ?? "他の端末")" }
        case Wire.talkEnded:
            activeSpeakerName = nil
            if !pttPressed {
                audio.setTransmitting(false)
                isPTTActive = false
                isWaitingForFloor = false
                isContinuousTalkEnabled = false
                activeSpeakerName = nil
            }
            if !isPTTActive { status = "親機に接続しました（チャンネル \(selectedChannel)）" }
        case Wire.peerRoster:
            guard payload.count <= 2_048,
                  let roster = try? JSONDecoder().decode(PeerRoster.self, from: payload),
                  roster.peers.count <= 4 else { return }
            let hostName = Self.safePeerName(roster.hostName)
            connectedHostName = hostName.isEmpty ? "親機" : hostName
            connectedPeerNames = roster.peers
                .map(Self.safePeerName)
                .filter { !$0.isEmpty }
        case Wire.audio:
            audio.play(pcm16Mono: payload)
        default:
            break
        }
    }

    private func sendAudio(_ pcm: Data) {
        guard isPTTActive else { return }
        if isHosting {
            broadcast(type: Wire.audio, payload: pcm)
        } else if let clientConnection {
            send(type: Wire.audio, payload: pcm, through: clientConnection)
        }
    }

    private func send(type: UInt8, payload: Data, through connection: NWConnection) {
        guard let encryptionKey = sessionKey else { connection.cancel(); return }
        var plaintext = Data([type])
        plaintext.append(payload)
        guard let sealed = try? AES.GCM.seal(plaintext, using: encryptionKey).combined else {
            connection.cancel()
            return
        }
        var body = sealed
        var length = UInt32(body.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(body)
        let key = ObjectIdentifier(connection)
        var queue = pendingSends[key, default: []]
        if type == Wire.releaseFloor || type == Wire.talkEnded {
            queue.removeAll(where: { $0.isAudio })
        }
        if type == Wire.audio {
            let queuedAudioCount = queue.reduce(into: 0) { count, item in
                if item.isAudio { count += 1 }
            }
            if queuedAudioCount >= 8,
               let oldestAudio = queue.firstIndex(where: { $0.isAudio }) {
                queue.remove(at: oldestAudio)
            }
        }
        queue.append(PendingSend(packet: packet, isAudio: type == Wire.audio))
        pendingSends[key] = queue
        sendNext(for: connection)
    }

    private func sendNext(for connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard isCurrentConnection(connection),
              !sendingConnections.contains(key),
              var queue = pendingSends[key],
              !queue.isEmpty else { return }

        let pending = queue.removeFirst()
        pendingSends[key] = queue
        sendingConnections.insert(key)
        connection.send(content: pending.packet, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            Task { @MainActor in
                self.sendingConnections.remove(key)
                guard self.isCurrentConnection(connection) else {
                    self.pendingSends.removeValue(forKey: key)
                    return
                }
                if let error {
                    self.pendingSends.removeValue(forKey: key)
                    self.status = "データを送れませんでした: \(error.localizedDescription)"
                    connection.cancel()
                    return
                }
                self.sendNext(for: connection)
            }
        })
    }

    private func broadcast(type: UInt8, payload: Data, excluding excludedPeer: ObjectIdentifier? = nil) {
        for (key, connection) in hostConnections
        where key != excludedPeer && readyHostConnections.contains(key) {
            send(type: type, payload: payload, through: connection)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = "親機として待機中（チャンネル \(selectedChannel)）"
        case .failed(let error):
            status = "親機を開始できませんでした: \(error.localizedDescription)"
            stop(clearStatus: false)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            status = isAutomaticallySearching
                ? "親機を再検索中…"
                : "チャンネル \(selectedChannel) の親機を検索中…"
        case .failed(let error):
            if isAutomaticallySearching, preferredHost != nil {
                browser = nil
                isBrowsing = false
                status = "親機の再検索をやり直します: \(error.localizedDescription)"
                scheduleReconnect()
            } else {
                status = "親機を検索できませんでした: \(error.localizedDescription)"
                stop(clearStatus: false)
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    nonisolated private static func parseServiceName(_ name: String) -> (channel: Int, suffix: String)? {
        let parts = name.split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              parts[0] == "OT",
              parts[1].hasPrefix("CH"),
              let channel = Int(parts[1].dropFirst(2)),
              (1...10).contains(channel) else { return nil }
        return (channel, String(parts[2]))
    }

    private static func persistentHostCode() -> String {
        let key = "offlineTalkHostID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let generated = String(UUID().uuidString.prefix(6)).lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static func persistentHostSecret() -> String {
        if let saved = KeychainSecretStore.migrateAndRead(account: "host", legacyDefaultsKey: "offlineTalkHostSecret"), saved.count == 32 { return saved }
        let generated = SymmetricKey(size: .bits128).withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        guard KeychainSecretStore.write(generated, account: "host") else { return "" }
        return generated
    }

    private static func data(fromHex value: String) -> Data? {
        guard value.count == 32 else { return nil }
        var data = Data(capacity: 16)
        var index = value.startIndex
        for _ in 0..<16 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func safePeerName(_ name: String) -> String {
        let visible = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(visible).prefix(40))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func localDisplayName() -> String {
        let configuredName = UserDefaults.standard.string(forKey: "offlineTalkDisplayName") ?? ""
        let safeConfiguredName = safePeerName(configuredName)
        if !safeConfiguredName.isEmpty { return safeConfiguredName }
        let deviceName = safePeerName(UIDevice.current.name)
        return deviceName.isEmpty ? "iPhone" : deviceName
    }

    private func refreshPeerList() {
        connectedPeers = readyHostConnections
            .map { peerNames[$0] ?? "接続中…" }
            .sorted()
    }

    private func broadcastPeerRoster() {
        let hostName = Self.localDisplayName()
        let roster = PeerRoster(
            hostName: hostName.isEmpty ? "親機" : hostName,
            peers: connectedPeers
        )
        guard let payload = try? JSONEncoder().encode(roster), payload.count <= 2_048 else { return }
        broadcast(type: Wire.peerRoster, payload: payload)
    }

    private func isCurrentConnection(_ connection: NWConnection) -> Bool {
        if isHosting {
            return hostConnections[ObjectIdentifier(connection)] === connection
        }
        return clientConnection === connection
    }

    private func scheduleReconnect() {
        guard isActive, !isHosting, preferredHost != nil, reconnectTask == nil else { return }
        let delaySeconds = min(1 << min(reconnectAttempt, 4), 16)
        reconnectAttempt += 1
        status = "親機を再検索します（\(delaySeconds)秒後）"
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.isActive,
                  let host = self.preferredHost else { return }
            self.reconnectTask = nil
            self.beginBrowsing(channel: host.channel, automatically: true)
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfBackground(title: String, body: String) {
        guard UIApplication.shared.applicationState == .background else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private enum KeychainSecretStore {
    private static let service = "jp.offlinetalk.app.encryption"

    static func read(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrSynchronizable as String] = false
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func migrateAndRead(account: String, legacyDefaultsKey: String) -> String? {
        if let existing = read(account: account) { return existing }
        guard let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey) else { return nil }
        guard write(legacy, account: account) else { return nil }
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return legacy
    }

    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

private enum Wire {
    static let maximumAudioPayloadBytes = 4_096
    static let requestFloor: UInt8 = 1
    static let floorGranted: UInt8 = 2
    static let floorDenied: UInt8 = 3
    static let releaseFloor: UInt8 = 4
    static let talkStarted: UInt8 = 5
    static let talkEnded: UInt8 = 6
    static let audio: UInt8 = 7
    static let hello: UInt8 = 8
    static let peerRoster: UInt8 = 9
}
