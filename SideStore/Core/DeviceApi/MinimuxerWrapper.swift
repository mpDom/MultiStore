//
//  MinimuxerWrapper.swift
//
//  Created by Magesh K on 22/02/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Network
import Minimuxer
import Combine

public var selectedGatewayBackendCache: GatewayBackend = .idevice
public var remotePairingPortCache: UInt16 = MinimuxerConstants.remotePairingPort

public func syncMinimuxerBackendFromUserDefaults() {
    let raw = UserDefaults.standard.minimuxerGatewayBackend
    selectedGatewayBackendCache = GatewayBackend(rawValue: raw) ?? .idevice

    let overridePort = UserDefaults.standard.remotePairingPortOverride
    if overridePort > 0 && overridePort <= 65535 {
        remotePairingPortCache = UInt16(overridePort)
    } else {
        remotePairingPortCache = MinimuxerConstants.remotePairingPort
    }
}

var minimuxer: any MinimuxerFacade {
    Minimuxer.shared(backend: selectedGatewayBackendCache, remotePairingPort: remotePairingPortCache)
}

private func resolveDiscoveredRemotePairingPort() async -> UInt16? {
    let overridePort = UserDefaults.standard.remotePairingPortOverride
    if overridePort > 0 && overridePort <= 65535 {
        return UInt16(overridePort)
    }
    if let resolved = await BonjourDiscoveryManager.resolveFirstService(
        ofType: MinimuxerConstants.remotePairingDaemonServiceType,
        timeout: AppConstants.Bonjour.defaultDiscoveryTimeout
    ) {
        debugLog("[SideStore] Discovered RemotePairing port via Bonjour: \(resolved.port)")
        return resolved.port
    }
    return nil
}

private var lastRemotePairingPortResolveTime: Date = .distantPast
private var activeRemotePairingPortResolveTask: Task<UInt16?, Never>?

private func resolveDiscoveredRemotePairingPortThrottled() async -> UInt16? {
    let overridePort = UserDefaults.standard.remotePairingPortOverride
    if overridePort > 0 && overridePort <= 65535 {
        return UInt16(overridePort)
    }

    let now = Date()
    guard now.timeIntervalSince(lastRemotePairingPortResolveTime) > 5.0 else {
        return nil
    }

    if let inFlight = activeRemotePairingPortResolveTask {
        return await inFlight.value
    }

    let task = Task<UInt16?, Never> {
        defer {
            activeRemotePairingPortResolveTask = nil
            lastRemotePairingPortResolveTime = Date()
        }
        return await resolveDiscoveredRemotePairingPort()
    }
    activeRemotePairingPortResolveTask = task
    return await task.value
}

private func withRemotePairingRetry<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch {
        guard minimuxer.gateway.isRPPairing else { throw error }

        if let newPort = await resolveDiscoveredRemotePairingPortThrottled(), newPort != remotePairingPortCache {
            debugLog("[SideStore] Operation failed, updating RemotePairing port from \(remotePairingPortCache) -> \(newPort) and retrying...")
            remotePairingPortCache = newPort
            _ = Minimuxer.shared(backend: selectedGatewayBackendCache, remotePairingPort: newPort)
            return try await operation()
        }
        throw error
    }
}

public var minimuxerStatusPublisher: AnyPublisher<Result<Bool, Error>, Never> {
    minimuxer.core.statusPublisher
        .map { result in
            result.mapError { $0 as Error }
        }
        .eraseToAnyPublisher()
}

func bindConnectionConfig() async {
    defer { debugLog("[SideStore] bindTunnelConfig() completed") }

    debugLog("[SideStore] bindTunnelConfig() invoked")
    let config = ConnectionConfig.shared
    let configBinding = ConnectionConfigBinding(
        setTunnelIfaceIp: { value in Task { @MainActor in config.tunnelIfaceIp = value } },
        setTunnelPeerIp: { value in Task { @MainActor in config.tunnelPeerIp = value } },
        setTunnelPeerSubnetMask: { value in Task { @MainActor in config.tunnelPeerSubnetMask = value } },
        setTunnelPeerReachable: { value in Task { @MainActor in config.tunnelPeerReachable = value } },
        setTunnelIfaceSubnetMask: { value in Task { @MainActor in config.tunnelIfaceSubnetMask = value } },
        getRemoteServerIp: { config.remoteServerIp },
        setRemoteReachable: { value in Task { @MainActor in config.remoteReachable = value } },
        getOverrideTunnelPeerIp: { config.overrideTunnelPeerIp },
        setOverrideTunnelPeerReachable: { value in Task { @MainActor in config.overrideTunnelPeerReachable = value } },
        getConnectionMode: { config.useLocalVPN ? .localVPN : .remoteServer }
    )
    await minimuxer.core.bindConnectionConfig(configBinding)
}

func getDeviceConnectionMode() async -> DeviceConnectionMode {
    return await minimuxer.core.getConnectionMode()
}

enum MinimuxerStatus: Equatable {
    case ready
    case noDevice(String?)
    case noConnection(String?)
    case notReachable(String)
    case noVPN(String?)
    case invalidVPN(String?)
    case invalidPairing(String?)
    case notStarted(String?)
    case pairingNotLoaded(String?)
    case unknown
    
    init(from error: MinimuxerError) {
        switch error {
        case .noVPN(let reason):                    self = .noVPN(reason)
        case .invalidVPN(let reason):               self = .invalidVPN(reason)
        case .invalidPairing(_, let reason):        self = .invalidPairing(reason)
        case .noDevice(let reason):                 self = .noDevice(reason)
        case .noConnection(let reason):             self = .noConnection(reason)
        case .notReachable(let reason):             self = .notReachable(reason)
        case .notStarted(let reason):               self = .notStarted(reason)
        case .pairingNotLoaded(let reason):         self = .pairingNotLoaded(reason)
        default:                                    self = .unknown
        }
    }
    
    var operationError: OperationError? {
        switch self {
        case .unknown, .ready:                  return nil
        case .noDevice(let reason):             return .noDevice(reason: reason)
        case .noConnection(let reason):         return .noConnection(reason: reason)
        case .notReachable(let reason):         return .notReachable(reason: reason)
        case .noVPN(let reason):                return .noVPN(reason: reason)
        case .invalidVPN(let reason):           return .invalidVPN(reason: reason)
        case .invalidPairing(let reason):       return .invalidPairingFile(reason: reason)
        case .notStarted(let reason):           return .minimuxerNotStarted(reason: reason)
        case .pairingNotLoaded(let reason):     return .pairingNotComplete(reason: reason)
        }
    }

    static func from(_ result: Result<Bool, Error>) -> MinimuxerStatus {
        switch result {
        case .success:
            return .ready
        case .failure(let error):
            guard let error = error as? MinimuxerError else { return .unknown }
            return MinimuxerStatus(from: error)
        }
    }
}

func getMinimuxerStatus() async -> MinimuxerStatus {
    // #if targetEnvironment(simulator)
    // debugLog("[SideStore] getMinimuxerStatus() = .ready on simulator")
    // return .ready
    // #endif
    let result = await minimuxer.core.isReady()
    return MinimuxerStatus.from(result.mapError { $0 as Error })
}

func reinitializePairingData(_ pairingFile: String) async throws {
    defer { debugLog("[SideStore] reinitializePairingData(pairingFile) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] reinitializePairingData(pairingFile) is no-op on simulator")
    #else
    debugLog("[SideStore] reinitializePairingData(pairingFile) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.reinitializePairingData(pairingFile: pairingFile)
    }
    #endif
}

func minimuxerStart(_ pairingFile: String, mountPath: String) async throws {
    defer { debugLog("[SideStore] minimuxerStart(pairingFile) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] minimuxerStart(pairingFile) is no-op on simulator")
    await bindConnectionConfig()
    await minimuxer.network.start()
    #else
    await bindConnectionConfig()
    debugLog("[SideStore] minimuxerStart(pairingFile) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.start(pairingFile: pairingFile, mountPath: mountPath)
    }
    #endif
}


func reinitializePairingData(pairingFile: String) async throws {
    defer { debugLog("[SideStore] reinitializePairingData(pairingFile) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] reinitializePairingData(pairingFile) is no-op on simulator")
    #else
    debugLog("[SideStore] reinitializePairingData(pairingFile) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.reinitializePairingData(pairingFile: pairingFile)
    }
    #endif
}

func installProvisioningProfiles(_ profileData: Data) async throws {
    defer { debugLog("[SideStore] installProvisioningProfiles(profileData) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] installProvisioningProfiles(profileData) is no-op on simulator")
    #else
    debugLog("[SideStore] installProvisioningProfiles(profileData) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.installProvisioningProfile(profile: profileData)
    }
    #endif
}

func removeProvisioningProfile(_ id: String) async throws {
    defer { debugLog("[SideStore] removeProvisioningProfile(id) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] removeProvisioningProfile(id) is no-op on simulator")
    #else
    debugLog("[SideStore] removeProvisioningProfile(id) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.removeProvisioningProfile(id: id)
    }
    #endif
}

func removeApp(_ bundleId: String) async throws {
    defer { debugLog("[SideStore] removeApp(bundleId) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] removeApp(bundleId) is no-op on simulator")
    #else
    debugLog("[SideStore] removeApp(bundleId) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.removeApp(bundleId: bundleId)
    }
    #endif
}

func yeetAppAFC(_ bundleId: String, _ rawBytes: Data) async throws {
    defer { debugLog("[SideStore] yeetAppAFC(bundleId, rawBytes) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] yeetAppAFC(bundleId, rawBytes) is no-op on simulator")
    #else
    debugLog("[SideStore] yeetAppAFC(bundleId, rawBytes) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.yeetAppAfc(bundleId: bundleId, ipaBytes: rawBytes)
    }
    #endif
}

func installIPA(_ bundleId: String) async throws {
    defer { debugLog("[SideStore] installIPA(bundleId) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] installIPA(bundleId) is no-op on simulator")
    #else
    debugLog("[SideStore] installIPA(bundleId) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.installIpa(bundleId: bundleId)
    }
    #endif
}

@discardableResult
func fetchUDID(useStatic: Bool = false) async throws -> String? {
    defer { debugLog("[SideStore] fetchUDID() completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] fetchUDID() is no-op on simulator")
    return "XXXXX-XXXX-XXXXX-XXXX"
    #else
    debugLog("[SideStore] fetchUDID() invoked")
    let result = try? await withRemotePairingRetry {
        try await minimuxer.core.fetchUDID()
    }
    if let udid = result ?? nil, !udid.isEmpty, udid != "XXXXX-XXXX-XXXXX-XXXX" {
        return udid
    }
    if useStatic {
        return PairingFileManager.shared.pairingUDID
    }
    return nil
    #endif
}

func debugApp(_ appId: String) async throws {
    defer { debugLog("[SideStore] debugApp(appId) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] debugApp(appId) is no-op on simulator")
    #else
    debugLog("[SideStore] debugApp(appId) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.debugApp(appId: appId)
    }
    #endif
}

func attachDebugger(_ pid: UInt32) async throws {
    defer { debugLog("[SideStore] attachDebugger(pid) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] attachDebugger(pid) is no-op on simulator")
    #else
    debugLog("[SideStore] attachDebugger(pid) invoked")
    try await withRemotePairingRetry {
        try await minimuxer.core.attachDebugger(pid: pid)
    }
    #endif
}


func dumpProfiles(_ docsPath: String) async throws -> String {
    defer { debugLog("[SideStore] dumpProfiles(docsPath) completed") }
    #if targetEnvironment(simulator)
    debugLog("[SideStore] dumpProfiles(docsPath) is no-op on simulator")
    return ""
    #else
    debugLog("[SideStore] dumpProfiles(docsPath) invoked")
    return try await withRemotePairingRetry {
        try await minimuxer.core.dumpProfiles(docsPath: docsPath)
    }
    #endif
}

func minimuxerSetLogging(_ enabled: Bool) {
    defer { debugLog("[SideStore] minimuxerSetLogging(enabled) completed") }
    debugLog("[SideStore] minimuxerSetLogging(enabled) invoked")
    #if !targetEnvironment(simulator)
    minimuxer.core.setLogging(enabled)
    #endif
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

extension MinimuxerError {
    public var failureReason: String? {
        switch self {
        case .noDevice:
            return NSLocalizedString("Cannot fetch the device from the muxer", comment: "")
        case .noConnection:
            return NSLocalizedString("You do not appear to be connected to Wi-Fi or a wired network connection! Please connect to a Wi-Fi or wired connection.", comment: "")
        case .notReachable(let reason):
            return NSLocalizedString(reason, comment: "")
        case .connectionModeNotConfigured(let reason):
            return NSLocalizedString(reason, comment: "")
        case .noVPN(let reason):
            return String(format: NSLocalizedString("Unable to connect to the device via %@ VPN. Please make sure LocalDevVPN is enabled and running! Reason: %@", comment: ""), "LocalDev", reason)
        case .invalidPairing(let proto, let reason):
            return String(format: NSLocalizedString("Invalid pairing file (%@ protocol): %@. Please use iloader to replace it.", comment: ""), proto.description, reason)
        case .createDebug:
            return createService(name: "debug")
        case .lookupApps:
            return getFromDevice(name: "installed apps")
        case .findApp:
            return getFromDevice(name: "path to the app")
        case .bundlePath:
            return getFromDevice(name: "bundle path")
        case .maxPacket:
            return setArgument(name: "max packet")
        case .workingDirectory:
            return setArgument(name: "working directory")
        case .argv:
            return setArgument(name: "argv")
        case .launchSuccess:
            return getFromDevice(name: "launch success")
        case .detach:
            return NSLocalizedString("Unable to detach from the app's process", comment: "")
        case .attach:
            return NSLocalizedString("Unable to attach to the app's process", comment: "")
        case .createInstproxy:
            return createService(name: "instproxy")
        case .createAfc:
            return createService(name: "AFC")
        case .rwAfc:
            return NSLocalizedString("AFC was unable to manage files on the device.", comment: "")
        case .installApp(let message):
            return NSLocalizedString("Unable to install the app: \(message)", comment: "")
        case .uninstallApp:
            return NSLocalizedString("Unable to uninstall the app", comment: "")
        case .createMisagent:
            return createService(name: "misagent")
        case .profileInstall:
            return NSLocalizedString("Unable to manage profiles on the device", comment: "")
        case .profileRemove:
            return NSLocalizedString("Unable to manage profiles on the device", comment: "")
        case .createLockdown:
            return NSLocalizedString("Unable to connect to lockdown", comment: "")
        case .createCoreDevice:
            return NSLocalizedString("Unable to connect to core device proxy", comment: "")
        case .createSoftwareTunnel:
            return NSLocalizedString("Unable to create software tunnel", comment: "")
        case .createRemoteServer:
            return NSLocalizedString("Unable to connect to remote server", comment: "")
        case .createProcessControl:
            return NSLocalizedString("Unable to connect to process control", comment: "")
        case .getLockdownValue:
            return NSLocalizedString("Unable to get value from lockdown", comment: "")
        case .connect:
            return NSLocalizedString("Unable to connect to TCP port", comment: "")
        case .close:
            return NSLocalizedString("Unable to close TCP port", comment: "")
        case .xpcHandshake:
            return NSLocalizedString("Unable to get services from XPC", comment: "")
        case .noService:
            return NSLocalizedString("Device did not contain service", comment: "")
        case .invalidProductVersion:
            return NSLocalizedString("Service version was in an unexpected format", comment: "")
        case .createFolder:
            return NSLocalizedString("Unable to create DDI folder", comment: "")
        case .downloadImage:
            return NSLocalizedString("Unable to download DDI", comment: "")
        case .imageLookup:
            return NSLocalizedString("Unable to lookup DDI images", comment: "")
        case .imageRead:
            return NSLocalizedString("Unable to read images to memory", comment: "")
        case .mount(let proto, let reason):
            return String(format: NSLocalizedString("Mount failed (%@ protocol): %@", comment: ""), proto.description, reason)
        case .restartAlreadyInProgressError:
            return NSLocalizedString("Restart already in progress", comment: "")
        case .invalidVPN:
            return NSLocalizedString("Invalid VPN configuration", comment: "")
        case .muxerNotListening:
            return NSLocalizedString("Usbmuxd server is not listening on the device", comment: "")
        case .notStarted(let reason):
            return String(format: NSLocalizedString("Minimuxer has not been started: %@", comment: ""), reason)
        case .pairingNotLoaded(let reason):
            return String(format: NSLocalizedString("No pairing file loaded: %@", comment: ""), reason)
        }
    }

    fileprivate func createService(name: String) -> String {
        String(format: NSLocalizedString("Cannot start a %@ server on the device.", comment: ""), name)
    }

    fileprivate func getFromDevice(name: String) -> String {
        String(format: NSLocalizedString("Cannot fetch %@ from the device.", comment: ""), name)
    }

    fileprivate func setArgument(name: String) -> String {
        String(format: NSLocalizedString("Cannot set %@ on the device.", comment: ""), name)
    }
}

public enum MinimuxerWrapperError: Error, LocalizedError {
    case profileInstall
    case restartAlreadyInProgress
    case pairingFile
    
    public var errorDescription: String? {
        switch self {
        case .profileInstall:
            return NSLocalizedString("Unable to manage profiles on the device", comment: "")
        case .restartAlreadyInProgress:
            return NSLocalizedString("Restart already in progress", comment: "")
        case .pairingFile:
            return NSLocalizedString("Invalid pairing file. Your pairing file either didn't have a UDID, or it wasn't a valid plist. Please use iloader to replace it.", comment: "")
        }
    }

    public var failureReason: String? {
        return errorDescription
    }
}

extension Error {
    public var isMinimuxerNoConnection: Bool {
        if let minimuxerErr = self as? MinimuxerError,
           case .noConnection = minimuxerErr { return true }
        return false
    }
    public var isMinimuxerNotReachable: Bool {
        if let minimuxerErr = self as? MinimuxerError,
           case .notReachable = minimuxerErr { return true }
        return false
    }
    public var isMinimuxerNoVPN: Bool {
        if let minimuxerErr = self as? MinimuxerError,
           case .noVPN = minimuxerErr { return true }
        return false
    }
    public var isMinimuxerProfileInstall: Bool {
        if let minimuxerErr = self as? MinimuxerError,
           case .profileInstall = minimuxerErr { return true }
        return (self as? MinimuxerWrapperError) == .profileInstall
    }
    public var isMinimuxerPairingFile: Bool {
        if let minimuxerErr = self as? MinimuxerError,
           case .invalidPairing = minimuxerErr { return true }
        return (self as? MinimuxerWrapperError) == .pairingFile
    }
    public var isMinimuxerRestartInProgress: Bool {
        if let minimuxerErr = self as? MinimuxerError,
           case .restartAlreadyInProgressError = minimuxerErr { return true }
        return (self as? MinimuxerWrapperError) == .restartAlreadyInProgress
    }
    public var isMinimuxerNotStarted: Bool {
        if let minimuxerErr = self as? MinimuxerError,
           case .notStarted = minimuxerErr { return true }
        return false
    }
}

func minimuxerRestart() async throws {
    #if !targetEnvironment(simulator)
    try await withRemotePairingRetry {
        try await minimuxer.core.restart()
    }
    #endif
}

public struct MinimuxerPairedDevice: Codable, Sendable {
    public let name: String
    public let model: String
    public let udid: String
    public let pairingFilePath: String
    
    public init(name: String, model: String, udid: String, pairingFilePath: String) {
        self.name = name
        self.model = model
        self.udid = udid
        self.pairingFilePath = pairingFilePath
    }
}

public final class WirelessPairWrapper {
    public static let shared = WirelessPairWrapper()
    
    private init() {}
    
    public var onPinReceived: ((String) -> Void)? {
        get {
            #if !targetEnvironment(simulator)
            return minimuxer.wirelessPair.onPinReceived
            #else
            return nil
            #endif
        }
        set {
            #if !targetEnvironment(simulator)
            minimuxer.wirelessPair.onPinReceived = newValue
            #endif
        }
    }
    
    public var onReadyToPair: ((String, Int) -> Void)? {
        get {
            #if !targetEnvironment(simulator)
            return minimuxer.wirelessPair.onReadyToPair
            #else
            return nil
            #endif
        }
        set {
            #if !targetEnvironment(simulator)
            minimuxer.wirelessPair.onReadyToPair = newValue
            #endif
        }
    }
    
    public var onRequestPin: ((@escaping (String) -> Void) -> Void)? {
        get {
            #if !targetEnvironment(simulator)
            return minimuxer.wirelessPair.onRequestPin
            #else
            return nil
            #endif
        }
        set {
            #if !targetEnvironment(simulator)
            minimuxer.wirelessPair.onRequestPin = newValue
            #endif
        }
    }
    
    public func start(
        outPath: String,
        completion: @escaping (Result<MinimuxerPairedDevice, Error>) -> Void
    ) {
        debugLog("[WirelessPairWrapper] start(outPath: '\(outPath)')")
        #if !targetEnvironment(simulator)
        minimuxer.wirelessPair.start(outPath: outPath) { result in
            debugLog("[WirelessPairWrapper] start callback received: result=\(result)")
            switch result {
            case .success(let device):
                completion(.success(MinimuxerPairedDevice(
                    name: device.name,
                    model: device.model,
                    udid: device.udid,
                    pairingFilePath: device.pairingFilePath
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        #else
        completion(.failure(MinimuxerWrapperError.pairingFile))
        #endif
    }

    public func trigger(
        targetIp: String,
        targetPort: UInt16,
        hostName: String = MinimuxerConstants.defaultHostName,
        hostModel: String = MinimuxerConstants.defaultHostModel,
        outPath: String,
        completion: @escaping (Result<MinimuxerPairedDevice, Error>) -> Void
    ) {
        debugLog("[WirelessPairWrapper] trigger(targetIp: '\(targetIp)', targetPort: \(targetPort), hostName: '\(hostName)', hostModel: '\(hostModel)', outPath: '\(outPath)')")
        #if !targetEnvironment(simulator)
        minimuxer.wirelessPair.trigger(
            targetIp: targetIp,
            targetPort: targetPort,
            hostName: hostName,
            hostModel: hostModel,
            outPath: outPath
        ) { result in
            debugLog("[WirelessPairWrapper] trigger callback received: result=\(result)")
            switch result {
            case .success(let device):
                completion(.success(MinimuxerPairedDevice(
                    name: device.name,
                    model: device.model,
                    udid: device.udid,
                    pairingFilePath: device.pairingFilePath
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        #else
        completion(.failure(MinimuxerWrapperError.pairingFile))
        #endif
    }
    
    public func stop() {
        debugLog("[WirelessPairWrapper] stop() invoked")
        #if !targetEnvironment(simulator)
        minimuxer.wirelessPair.stop()
        #endif
    }
}

let wirelessPairing = WirelessPairWrapper.shared
