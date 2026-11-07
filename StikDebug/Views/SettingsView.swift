//  SettingsView.swift
//  StikDebug
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

private enum SettingsLinks {
    static let githubStars = URL(string: "https://github.com/dammeiosvn/Stikdebug-VN")!
    static let pairingFileGuide = URL(string: "https://github.com/StikDebug/StikDebug/blob/main/PAIRING.md")!
    static let discord = URL(string: "https://discord.gg/qahjXNTDwS")!
}

struct SettingsView: View {
    @ObservedObject private var signingReminder = SigningExpiryReminder.shared
    @StateObject private var onDevicePairing = OnDevicePairingService.shared
    @AppStorage(UserDefaults.Keys.txmOverride) private var overrideTXMDetection = false
    @AppStorage(UserDefaults.Keys.confirmExternalJITRequests) private var confirmExternalJITRequests = true
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress
    @AppStorage("TunnelRemotePairingPort") private var remotePairingPortOverride = ""
    @AppStorage(UserDefaults.Keys.mallocDebug) private var mallocDebug = false

    private enum ConnectionField: Hashable {
        case address
        case port
    }

    @FocusState private var focusedConnectionField: ConnectionField?
    @State private var targetDeviceIPInput = ""
    @State private var remotePairingPortInput = ""
    @State private var automaticPortPlaceholder = "Discovering…".localized
    @State private var isShowingPairingFilePicker = false
    @State private var isImportingFile = false
    @State private var pairingImportMessage: (text: String, isError: Bool)?
    @State private var showDDIConfirmation = false
    @State private var isRedownloadingDDI = false
    @State private var ddiDownloadProgress: Double = 0.0
    @State private var ddiStatusMessage: String = ""
    @State private var ddiResultMessage: (text: String, isError: Bool)?

    private var appVersion: String {
        let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return marketingVersion
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image("StikDebug")
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text("StikDebug VN").font(.title2.weight(.semibold))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                Section {
                    Link(destination: SettingsLinks.githubStars) {
                        Label("Star on GitHub".localized, systemImage: "star")
                    }
                }

                Section {
                    Toggle("Nhắc sắp hết hạn ký", isOn: Binding(
                        get: { signingReminder.isEnabled },
                        set: { signingReminder.setEnabled($0) }
                    ))
                    if let expiry = signingReminder.expiry {
                        LabeledContent("Hạn ký VN", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                    if signingReminder.isEnabled && !signingReminder.status.isEmpty {
                        Text(signingReminder.status).font(.caption).foregroundStyle(.secondary)
                    }
                    if signingReminder.isEnabled && signingReminder.permissionDenied {
                        Button("Mở cài đặt thông báo") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Hạn ký ứng dụng")
                } footer: {
                    Text("Nhắc mỗi 3 giờ trong 24 giờ cuối. Sau khi gia hạn bằng AltStore, mở lại VN để cập nhật lịch.")
                }

                Section("Pairing File".localized) {
                    NavigationLink {
                        OnDevicePairingView(service: onDevicePairing)
                    } label: {
                        Label("Pair a Device".localized, systemImage: "iphone.and.arrow.forward")
                    }

                    Button {
                        isShowingPairingFilePicker = true
                    } label: {
                        Label("Import Pairing File".localized, systemImage: "doc.badge.plus")
                    }
                    .disabled(isImportingFile)

                    if isImportingFile {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing pairing file…".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let pairingImportMessage {
                        Label(
                            pairingImportMessage.text,
                            systemImage: pairingImportMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pairingImportMessage.isError ? .red : .green)
                    }
                }

                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent Audio".localized)
                            Text("Plays inaudible audio so iOS keeps the app running.".localized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        handleAudioKeepAliveChange(enabled)
                    }

                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Location".localized)
                            Text("Uses low-accuracy location to stay alive when an activity needs it.".localized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        handleLocationKeepAliveChange(enabled)
                    }

                } header: {
                    Text("Background Keep-Alive".localized)
                }

                Section("Behavior".localized) {
                    Toggle(isOn: $confirmExternalJITRequests) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Confirm JIT Links".localized)
                            Text("Ask before external links enable JIT or run scripts.".localized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $overrideTXMDetection) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Always Run Scripts".localized)
                            Text("Treats device as TXM-capable to bypass hardware checks.".localized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Debugging".localized) {
                    Toggle(isOn: $mallocDebug) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Malloc Debugging".localized)
                            Text("Attaches processes with MallocGuardEdges and MallocScribble to detect memory corruption.".localized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Advanced".localized) {
                    HStack {
                        Text("Target Device IP".localized)
                        Spacer()
                        TextField(DeviceConnectionContext.defaultTargetIPAddress, text: $targetDeviceIPInput)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.decimalPad)
                            .focused($focusedConnectionField, equals: .address)
                            .frame(maxWidth: 160)
                    }
                    HStack {
                        Text("Remote Pairing Port".localized)
                        Spacer()
                        TextField(automaticPortPlaceholder, text: $remotePairingPortInput)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .keyboardType(.numberPad)
                            .focused($focusedConnectionField, equals: .port)
                            .frame(maxWidth: 160)
                    }
                    Button { openAppFolder() } label: {
                        Label("App Folder".localized, systemImage: "folder")
                    }.foregroundStyle(.primary)
                    Button { showDDIConfirmation = true } label: {
                        Label("Redownload DDI".localized, systemImage: "arrow.down.circle")
                    }.foregroundStyle(.primary).disabled(isRedownloadingDDI)
                    if isRedownloadingDDI {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: ddiDownloadProgress, total: 1.0)
                            Text(ddiStatusMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let result = ddiResultMessage {
                        Text(result.text).font(.caption).foregroundStyle(result.isError ? .red : .green)
                    }
                }

                Section {
                    Text("Bản Việt hóa và nâng cấp: © Sentechtipsvn").font(.footnote)
                    Link("Mã nguồn gốc · StikDebug / AGPL-3.0", destination: URL(string: "https://github.com/StikDebug/StikDebug")!)
                }

                Section("Help".localized) {
                    Link(destination: SettingsLinks.pairingFileGuide) {
                        Label("Pairing File Guide".localized, systemImage: "questionmark.circle")
                    }
                    Button(action: connectLocalDevVPN) {
                        Label("Connect LocalDevVPN".localized, systemImage: "network")
                    }
                    Link(destination: SettingsLinks.discord) {
                        Label("Discord Support".localized, systemImage: "bubble.left.and.bubble.right")
                    }
                }

                Section {
                    Text(versionFooter)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings".localized)
            .background(KeyboardTapDismissal())
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            targetDeviceIPInput = targetDeviceIP
            remotePairingPortInput = remotePairingPortOverride
        }
        .task(id: targetDeviceIP) {
            automaticPortPlaceholder = "Discovering…".localized
            let result = await Task.detached {
                RemotePairingPortResolver.discover()
            }.value
            guard !Task.isCancelled else { return }
            automaticPortPlaceholder = result.source == "Bonjour"
                ? "Bonjour (\(result.port))"
                : "Fallback (\(result.port))"
        }
        .onChange(of: focusedConnectionField) { _, field in
            if field == nil {
                applyConnectionSettings()
            }
        }
        .onDisappear {
            applyConnectionSettings()
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }

                let fileManager = FileManager.default
                isImportingFile = true
                pairingImportMessage = nil

                do {
                    try PairingFileStore.importFromPicker(url, fileManager: fileManager)
                    isImportingFile = false
                    pairingImportMessage = ("Imported successfully".localized, false)
                    startTunnelInBackground()
                    schedulePairingStatusDismiss()
                } catch {
                    isImportingFile = false
                    pairingImportMessage = ("Nhập thất bại: \(error.localizedDescription)", true)
                    schedulePairingStatusDismiss()
                }
            case .failure(let error):
                isImportingFile = false
                pairingImportMessage = ("Nhập thất bại: \(error.localizedDescription)", true)
                schedulePairingStatusDismiss()
            }
        }
        .confirmationDialog("Redownload DDI Files?".localized, isPresented: $showDDIConfirmation, titleVisibility: .visible) {
            Button("Redownload".localized, role: .destructive) {
                redownloadDDIPressed()
            }
            Button("Cancel".localized, role: .cancel) { }
        } message: {
            Text("Existing DDI files will be removed before downloading fresh copies.".localized)
        }
    }

    private func applyConnectionSettings() {
        let address = targetDeviceIPInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = remotePairingPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address != targetDeviceIP || port != remotePairingPortOverride else { return }
        targetDeviceIP = address
        remotePairingPortOverride = port
        TunnelManager.shared.restart()
    }

    private var versionFooter: String {
        let processInfo = ProcessInfo.processInfo
        let txmLabel: String
        if processInfo.isTXMOverridden {
            txmLabel = "TXM (Override)".localized
        } else {
            txmLabel = processInfo.hasTXM ? "TXM" : "Non TXM".localized
        }
        return "VN beta 3 · Phiên bản \(appVersion) • iOS \(UIDevice.current.systemVersion) • \(txmLabel)"
    }

    private func handleAudioKeepAliveChange(_ enabled: Bool) {
        if !enabled, !keepAliveLocation {
            keepAliveLocation = true
            BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
        }
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }

    private func handleLocationKeepAliveChange(_ enabled: Bool) {
        if enabled {
            BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
        } else if !keepAliveAudio {
            keepAliveAudio = true
        }
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }

    // MARK: - Business Logic

    private func openAppFolder() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = documentsURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        if let url = URL(string: path) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func redownloadDDIPressed() {
        guard !isRedownloadingDDI else { return }
        Task {
            await MainActor.run {
                isRedownloadingDDI = true
                ddiDownloadProgress = 0
                ddiStatusMessage = "Preparing download…".localized
                ddiResultMessage = nil
            }
            do {
                try await redownloadDDI { progress, status in
                    Task { @MainActor in
                        self.ddiDownloadProgress = progress
                        self.ddiStatusMessage = status
                    }
                }
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = ("DDI files refreshed successfully.".localized, false)
                }
            } catch {
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = ("Không tải lại được DDI: \(error.localizedDescription)", true)
                }
            }
        }
        scheduleDDIStatusDismiss()
    }

    private func schedulePairingStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isImportingFile {
                    pairingImportMessage = nil
                }
            }
        }
    }

    private func scheduleDDIStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isRedownloadingDDI {
                    ddiResultMessage = nil
                }
            }
        }
    }
}

private struct KeyboardTapDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> DismissalView {
        DismissalView()
    }

    func updateUIView(_ uiView: DismissalView, context: Context) {}

    final class DismissalView: UIView, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private lazy var tapRecognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachedWindow?.removeGestureRecognizer(tapRecognizer)
            attachedWindow = window
            window?.addGestureRecognizer(tapRecognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UIInputView {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func dismissKeyboard() {
            window?.endEditing(true)
        }
    }
}

func connectLocalDevVPN() {
    let callbackScheme = ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
        ? "livecontainer"
        : "stikdebugvn"
    guard let url = URL(string: "localdevvpn://enable?scheme=\(callbackScheme)") else { return }
    UIApplication.shared.open(url, options: [:]) { opened in
        if !opened {
            DispatchQueue.main.async {
                UIApplication.shared.open(URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!)
            }
        }
    }
}

