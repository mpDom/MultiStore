//
//  OnDeviceAnisetteManager.swift
//  SideStore
//
//  Created by Magesh K on 18/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import CommonCrypto
import Compression
import AnisetteKit
@preconcurrency import AltSign

public struct ODAInfo: Codable, Equatable, Sendable {
    public let url: String?
    public let base64Payload: String?
    public let sha256: String?

    enum CodingKeys: String, CodingKey {
        case url
        case sha256
        case sha
        case s
        case l
        case payload
        case data
        case libraries
    }

    public init(url: String? = nil, base64Payload: String? = nil, sha256: String? = nil) {
        self.url = url
        self.base64Payload = base64Payload
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sha256 = (try? container.decodeIfPresent(String.self, forKey: .sha256))
            ?? (try? container.decodeIfPresent(String.self, forKey: .sha))
            ?? (try? container.decodeIfPresent(String.self, forKey: .s))

        let lVal = (try? container.decodeIfPresent(String.self, forKey: .l))
            ?? (try? container.decodeIfPresent(String.self, forKey: .libraries))
            ?? (try? container.decodeIfPresent(String.self, forKey: .payload))
            ?? (try? container.decodeIfPresent(String.self, forKey: .data))
        let urlVal = try? container.decodeIfPresent(String.self, forKey: .url)

        if let raw = lVal ?? urlVal {
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                self.url = raw
                self.base64Payload = nil
            } else {
                self.url = nil
                self.base64Payload = raw
            }
        } else {
            self.url = nil
            self.base64Payload = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(base64Payload, forKey: .l)
        try container.encodeIfPresent(sha256, forKey: .s)
    }
}

public enum ODAValue: Codable, Equatable, Sendable {
    case path(String)
    case direct(ODAInfo)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringVal = try? container.decode(String.self) {
            self = .path(stringVal)
        } else if let info = try? container.decode(ODAInfo.self) {
            self = .direct(info)
        } else {
            throw DecodingError.typeMismatch(
                ODAValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or ODAInfo dictionary for 'oda'"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .path(let path):
            try container.encode(path)
        case .direct(let info):
            try container.encode(info)
        }
    }
}

public enum OnDeviceAnisetteError: LocalizedError, Sendable {
    case invalidServerSourceURL
    case missingODAEntry
    case downloadFailed(String)
    case sha256Mismatch(expected: String, actual: String)
    case invalidBase64Payload
    case decompressionFailed(String)
    case missingRequiredLibraries([String])
    case appGroupContainerNotFound
    case providerNotReady(String)
    case invalidAnisetteData

    public var errorDescription: String? {
        switch self {
        case .invalidServerSourceURL:
            return "Invalid Anisette server list source URL."
        case .missingODAEntry:
            return "No 'oda' configuration found in Anisette servers JSON."
        case .downloadFailed(let reason):
            return "Failed to download On-Device Anisette package: \(reason)"
        case .sha256Mismatch(let expected, let actual):
            return "SHA-256 checksum mismatch for On-Device Anisette package (expected \(expected), got \(actual))."
        case .invalidBase64Payload:
            return "Downloaded On-Device Anisette payload is not valid Base64 data."
        case .decompressionFailed(let reason):
            return "Failed to decompress On-Device Anisette archive: \(reason)"
        case .missingRequiredLibraries(let names):
            return "Required ADI shared libraries (\(names.joined(separator: ", "))) were not found in the extracted archive."
        case .appGroupContainerNotFound:
            return "Shared App Group container URL could not be resolved."
        case .providerNotReady(let reason):
            return "Local Anisette provider is not ready: \(reason)"
        case .invalidAnisetteData:
            return "Failed to construct valid ALTAnisetteData from local Anisette headers."
        }
    }
}

public actor OnDeviceAnisetteManager {
    public static let shared = OnDeviceAnisetteManager()

    public static let hiddenBaseDirectoryName = ".anisette"
    public static let librariesDirectoryName = "Libraries"
    public static let provisioningDirectoryName = "Provisioning"
    public static let appSupportSubdirectory = "SideStore"
    public static let defaultODAMetadataURL = "https://zzz.haus/oda.json"
    public static let defaultDeviceSerialNumber = "0"
    public static let iso8601DateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    public static let posixLocaleIdentifier = "en_US_POSIX"
    public static let defaultTimeZoneAbbreviation = "UTC"
    public static let cachingPollingDelayNanoseconds: UInt64 = 200_000_000

    private var localProvider: LocalAnisetteProvider?
    private var isCaching: Bool = false

    private init() {}

    public nonisolated var baseAnisetteDirectory: URL? {
        if let sharedDir = FileManager.default.altstoreSharedDirectory {
            return sharedDir.appendingPathComponent(Self.hiddenBaseDirectoryName, isDirectory: true)
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent(Self.appSupportSubdirectory, isDirectory: true)
            .appendingPathComponent(Self.hiddenBaseDirectoryName, isDirectory: true)
    }

    public nonisolated var librariesDirectory: URL? {
        baseAnisetteDirectory?.appendingPathComponent(Self.librariesDirectoryName, isDirectory: true)
    }

    public nonisolated var provisioningDirectory: URL? {
        baseAnisetteDirectory?.appendingPathComponent(Self.provisioningDirectoryName, isDirectory: true)
    }

    public func isReady() -> Bool {
        guard let libDir = librariesDirectory else { return false }
        return LocalAnisetteProvider.validateLibrariesExist(at: libDir)
    }

    public func fetchODAInfo(from serverSourceURL: String? = nil) async throws -> ODAInfo {
        let sourceString = serverSourceURL ?? (UserDefaults.standard.menuAnisetteList.isEmpty ? AnisetteServersManager.defaultSource : UserDefaults.standard.menuAnisetteList)
        guard let sourceURL = URL(string: sourceString) else {
            debugLog("[OnDeviceAnisetteManager] ERROR: Invalid server list source URL: \(sourceString)")
            throw OnDeviceAnisetteError.invalidServerSourceURL
        }

        debugLog("[OnDeviceAnisetteManager] [ODA Fetch] Requesting server list from: \(sourceURL.absoluteString)")
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            debugLog("[OnDeviceAnisetteManager] ERROR: Server list request failed with HTTP \(status)")
            throw OnDeviceAnisetteError.downloadFailed("Server list request failed with HTTP \(status)")
        }

        debugLog("[OnDeviceAnisetteManager] [ODA Fetch] Received server list response (\(data.count) bytes, HTTP \(httpResp.statusCode))")
        let decoder = JSONDecoder()
        let serverData = try? decoder.decode(AnisetteServerData.self, from: data)

        switch serverData?.oda {
        case .direct(let directInfo):
            debugLog("[OnDeviceAnisetteManager] [ODA Fetch] Direct ODA config found: url=\(directInfo.url), sha256=\(directInfo.sha256 ?? "none")")
            return directInfo

        case .path(let pathString):
            let targetURL: URL
            if let direct = URL(string: pathString), direct.scheme != nil {
                targetURL = direct
            } else if let relative = URL(string: pathString, relativeTo: sourceURL)?.absoluteURL {
                targetURL = relative
            } else if let fallback = URL(string: Self.defaultODAMetadataURL) {
                targetURL = fallback
            } else {
                debugLog("[OnDeviceAnisetteManager] ERROR: Unable to resolve ODA target URL string: \(pathString)")
                throw OnDeviceAnisetteError.missingODAEntry
            }

            debugLog("[OnDeviceAnisetteManager] [ODA Fetch] Fetching ODA endpoint: \(targetURL.absoluteString)")
            var odaReq = URLRequest(url: targetURL)
            odaReq.cachePolicy = .reloadIgnoringLocalCacheData
            let (odaData, odaResp) = try await URLSession.shared.data(for: odaReq)
            guard let httpOdaResp = odaResp as? HTTPURLResponse, (200...299).contains(httpOdaResp.statusCode) else {
                let status = (odaResp as? HTTPURLResponse)?.statusCode ?? -1
                debugLog("[OnDeviceAnisetteManager] ERROR: ODA metadata request failed with HTTP \(status)")
                throw OnDeviceAnisetteError.downloadFailed("ODA metadata request failed with HTTP \(status)")
            }

            let decoded = try decoder.decode(ODAInfo.self, from: odaData)
            debugLog("[OnDeviceAnisetteManager] [ODA Fetch] Successfully parsed ODA info: url=\(decoded.url), sha256=\(decoded.sha256 ?? "none")")
            return decoded

        case .none:
            debugLog("[OnDeviceAnisetteManager] [ODA Fetch] 'oda' key not found in server list. Falling back to default: \(Self.defaultODAMetadataURL)")
            guard let defaultFallbackURL = URL(string: Self.defaultODAMetadataURL) else {
                throw OnDeviceAnisetteError.missingODAEntry
            }

            var odaReq = URLRequest(url: defaultFallbackURL)
            odaReq.cachePolicy = .reloadIgnoringLocalCacheData
            let (odaData, odaResp) = try await URLSession.shared.data(for: odaReq)
            guard let httpOdaResp = odaResp as? HTTPURLResponse, (200...299).contains(httpOdaResp.statusCode) else {
                let status = (odaResp as? HTTPURLResponse)?.statusCode ?? -1
                debugLog("[OnDeviceAnisetteManager] ERROR: Fallback ODA metadata request failed with HTTP \(status)")
                throw OnDeviceAnisetteError.downloadFailed("Fallback ODA metadata request failed with HTTP \(status)")
            }

            let decoded = try decoder.decode(ODAInfo.self, from: odaData)
            debugLog("[OnDeviceAnisetteManager] [ODA Fetch] Fallback ODA metadata loaded: url=\(decoded.url), sha256=\(decoded.sha256 ?? "none")")
            return decoded
        }
    }

    public func downloadAndCacheLibraries(from oda: ODAInfo) async throws {
        guard !isCaching else {
            debugLog("[OnDeviceAnisetteManager] [Download & Cache] Another cache operation is already in progress, waiting...")
            while isCaching {
                try await Task.sleep(nanoseconds: Self.cachingPollingDelayNanoseconds)
            }
            return
        }
        isCaching = true
        defer { isCaching = false }

        guard let libDir = librariesDirectory, let provDir = provisioningDirectory else {
            debugLog("[OnDeviceAnisetteManager] ERROR: Failed to resolve shared App Group container directories.")
            throw OnDeviceAnisetteError.appGroupContainerNotFound
        }

        let fm = FileManager.default
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: provDir, withIntermediateDirectories: true)

        let zipData: Data
        if let inlineBase64 = oda.base64Payload,
           let decoded = Data(base64Encoded: inlineBase64.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters) {
            debugLog("[OnDeviceAnisetteManager] [Download & Cache] Found inline Base64 payload (\(inlineBase64.count) chars -> \(decoded.count) bytes)")
            zipData = decoded
        } else if let urlStr = oda.url, let downloadURL = URL(string: urlStr) {
            debugLog("[OnDeviceAnisetteManager] [Download & Cache] Downloading ADI package from: \(downloadURL.absoluteString)...")
            var request = URLRequest(url: downloadURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (downloadedData, response) = try await URLSession.shared.data(for: request)

            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                debugLog("[OnDeviceAnisetteManager] ERROR: Package download failed with HTTP \(status)")
                throw OnDeviceAnisetteError.downloadFailed("Package download failed with HTTP \(status)")
            }

            debugLog("[OnDeviceAnisetteManager] [Download & Cache] Downloaded \(downloadedData.count) bytes (HTTP \(httpResp.statusCode))")

            let rawString = String(data: downloadedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let base64String = rawString,
               let decoded = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) {
                debugLog("[OnDeviceAnisetteManager] [Download & Cache] Decoded downloaded Base64 payload (\(downloadedData.count) chars -> \(decoded.count) bytes)")
                zipData = decoded
            } else {
                debugLog("[OnDeviceAnisetteManager] [Download & Cache] Using downloaded binary payload (\(downloadedData.count) bytes)")
                zipData = downloadedData
            }
        } else {
            debugLog("[OnDeviceAnisetteManager] ERROR: No valid URL or Base64 payload in ODA info.")
            throw OnDeviceAnisetteError.downloadFailed("No valid URL or Base64 payload in ODA configuration.")
        }

        if let expectedSHA = oda.sha256, !expectedSHA.isEmpty {
            let zipSHA = computeSHA256(data: zipData)
            debugLog("[OnDeviceAnisetteManager] [Download & Cache] Computed ZIP SHA-256: \(zipSHA)")
            if zipSHA.caseInsensitiveCompare(expectedSHA) != .orderedSame {
                debugLog("[OnDeviceAnisetteManager] [Download & Cache] Note: SHA-256 differs (expected=\(expectedSHA), actual=\(zipSHA)). Proceeding with extraction.")
            }
        }

        debugLog("[OnDeviceAnisetteManager] [Download & Cache] Decompressing and extracting ADI libraries to: \(libDir.path)...")
        try OnDeviceZIPExtractor.extract(zipData: zipData, to: libDir)

        guard LocalAnisetteProvider.validateLibrariesExist(at: libDir) else {
            debugLog("[OnDeviceAnisetteManager] ERROR: Extracted files missing required libraries: \(LocalAnisetteProvider.requiredLibraryNames)")
            throw OnDeviceAnisetteError.missingRequiredLibraries(LocalAnisetteProvider.requiredLibraryNames)
        }

        let config = await AnisetteConfigManager.shared.loadConfig()
        let resolvedClientInfo = FetchAnisetteDataOperation.sanitizedClientInfo(config.clientInfo.isEmpty ? LocalAnisetteProvider.defaultClientInfo : config.clientInfo)

        let provider = try LocalAnisetteProvider(
            provisioningDir: provDir,
            clientInfo: resolvedClientInfo
        ) {
            libDir
        }

        self.localProvider = provider
        debugLog("[OnDeviceAnisetteManager] [Download & Cache] SUCCESS: ADI libraries cached in \(libDir.path) and LocalAnisetteProvider loaded.")
    }

    public func setupFromRemote(serverSourceURL: String? = nil) async throws {
        debugLog("[OnDeviceAnisetteManager] [Setup] Starting remote setup flow...")
        let odaInfo = try await fetchODAInfo(from: serverSourceURL)
        try await downloadAndCacheLibraries(from: odaInfo)
    }

    public func ensureProviderLoaded() async throws -> LocalAnisetteProvider {
        if let existing = self.localProvider {
            return existing
        }

        guard let libDir = librariesDirectory, let provDir = provisioningDirectory else {
            debugLog("[OnDeviceAnisetteManager] ERROR: Cannot resolve base Anisette directory.")
            throw OnDeviceAnisetteError.appGroupContainerNotFound
        }

        if LocalAnisetteProvider.validateLibrariesExist(at: libDir) {
            debugLog("[OnDeviceAnisetteManager] [Provider] Found cached libraries at \(libDir.path), initializing LocalAnisetteProvider...")
            let config = await AnisetteConfigManager.shared.loadConfig()
            let resolvedClientInfo = FetchAnisetteDataOperation.sanitizedClientInfo(config.clientInfo.isEmpty ? LocalAnisetteProvider.defaultClientInfo : config.clientInfo)

            let provider = try LocalAnisetteProvider(
                provisioningDir: provDir,
                clientInfo: resolvedClientInfo
            ) {
                libDir
            }
            self.localProvider = provider
            debugLog("[OnDeviceAnisetteManager] [Provider] LocalAnisetteProvider ready.")
            return provider
        }

        debugLog("[OnDeviceAnisetteManager] [Provider] Libraries missing locally. Triggering setupFromRemote...")
        try await setupFromRemote()

        guard let loaded = self.localProvider else {
            debugLog("[OnDeviceAnisetteManager] ERROR: Provider failed to load after remote setup.")
            throw OnDeviceAnisetteError.providerNotReady("Provider failed to load after remote setup.")
        }
        return loaded
    }

    private func resolveDeviceIdentifier() -> UUID {
        if let storedId = AnisetteDataManager.shared.anisetteIdentifier {
            if let parsed = UUID(uuidString: storedId) {
                debugLog("[OnDeviceAnisetteManager] [Fetch] Using existing device UUID: \(parsed.uuidString)")
                return parsed
            }
            if let data = Data(base64Encoded: storedId), data.count == 16 {
                let uuid = data.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
                debugLog("[OnDeviceAnisetteManager] [Fetch] Using existing base64-encoded device UUID: \(uuid.uuidString)")
                return uuid
            }
        }
        let generated = UUID()
        AnisetteDataManager.shared.anisetteIdentifier = generated.uuidString
        debugLog("[OnDeviceAnisetteManager] [Fetch] Generated new device UUID: \(generated.uuidString)")
        return generated
    }

    public func fetchAnisetteData() async throws -> ALTAnisetteData {
        debugLog("[OnDeviceAnisetteManager] [Fetch] Fetching on-device Anisette headers...")
        let provider = try await ensureProviderLoaded()

        let identifierUUID = resolveDeviceIdentifier()

        var existingAdiPbData: Data? = nil
        if let base64Blob = AnisetteDataManager.shared.anisetteAdiBlob,
           let decoded = Data(base64Encoded: base64Blob, options: .ignoreUnknownCharacters),
           !decoded.isEmpty {
            existingAdiPbData = decoded
            debugLog("[OnDeviceAnisetteManager] [Fetch] Reusing existing adi.pb from Keychain (\(decoded.count) bytes)")
        } else {
            debugLog("[OnDeviceAnisetteManager] [Fetch] No existing adi.pb in Keychain -> local in-memory provisioning will be performed")
        }

        let (headers, newAdiPb) = try await provider.getHeaders(identifier: identifierUUID, storage: .memory(existingBlob: existingAdiPbData))

        if let freshBlob = newAdiPb {
            AnisetteDataManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
            debugLog("[OnDeviceAnisetteManager] [Fetch] Fresh local provisioning completed -> saved new adi.pb (\(freshBlob.count) bytes) to Keychain")
        }

        let config = await AnisetteConfigManager.shared.loadConfig()

        let machineID = headers["X-Apple-I-MD-M"] ?? ""
        let oneTimePassword = headers["X-Apple-I-MD"] ?? ""
        let routingInfoStr = headers["X-Apple-I-MD-RINFO"] ?? LocalAnisetteProvider.defaultRoutingInfo
        let localUserID = headers["X-Apple-I-MD-LU"] ?? config.customLocalUserID ?? LocalAnisetteProvider.defaultLocalUserID
        let deviceUID = config.customDeviceID ?? identifierUUID.uuidString.uppercased()
        let clientInfo = config.clientInfo.isEmpty ? provider.clientInfo : config.clientInfo

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Self.posixLocaleIdentifier)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = Self.iso8601DateFormat
        let dateString = formatter.string(from: Date())

        let resolvedLocale = config.customLocale ?? Locale.current.identifier
        let resolvedTimeZone = config.customTimeZone ?? (TimeZone.current.abbreviation() ?? Self.defaultTimeZoneAbbreviation)

        debugLog("[OnDeviceAnisetteManager] [Fetch] Constructed headers: MD=\(!oneTimePassword.isEmpty), MD-M=\(!machineID.isEmpty), RINFO=\(routingInfoStr), LU=\(localUserID.prefix(8))..., Locale=\(resolvedLocale), TimeZone=\(resolvedTimeZone)")

        let formattedJSON: [String: String] = [
            "deviceSerialNumber": Self.defaultDeviceSerialNumber,
            "machineID": machineID,
            "oneTimePassword": oneTimePassword,
            "routingInfo": routingInfoStr,
            "deviceDescription": clientInfo,
            "localUserID": localUserID,
            "deviceUniqueIdentifier": deviceUID,
            "date": dateString,
            "locale": resolvedLocale,
            "timeZone": resolvedTimeZone
        ]

        guard let anisetteData = ALTAnisetteData(json: formattedJSON) else {
            debugLog("[OnDeviceAnisetteManager] ERROR: Failed to instantiate ALTAnisetteData from generated JSON dictionary.")
            throw OnDeviceAnisetteError.invalidAnisetteData
        }

        debugLog("[OnDeviceAnisetteManager] [Fetch] SUCCESS: ALTAnisetteData generated successfully.")
        return anisetteData
    }

    public func fetchAnisetteDataFromDisk() async throws -> ALTAnisetteData {
        debugLog("[OnDeviceAnisetteManager] [Disk Fetch] Fetching disk-backed Anisette headers...")
        let provider = try await ensureProviderLoaded()

        let identifierUUID = resolveDeviceIdentifier()

        let headers = try await provider.getHeaders(identifier: identifierUUID, storage: .disk).headers
        let config = await AnisetteConfigManager.shared.loadConfig()

        let machineID = headers["X-Apple-I-MD-M"] ?? ""
        let oneTimePassword = headers["X-Apple-I-MD"] ?? ""
        let routingInfoStr = headers["X-Apple-I-MD-RINFO"] ?? LocalAnisetteProvider.defaultRoutingInfo
        let localUserID = headers["X-Apple-I-MD-LU"] ?? config.customLocalUserID ?? LocalAnisetteProvider.defaultLocalUserID
        let deviceUID = config.customDeviceID ?? identifierUUID.uuidString.uppercased()
        let clientInfo = config.clientInfo.isEmpty ? provider.clientInfo : config.clientInfo

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Self.posixLocaleIdentifier)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = Self.iso8601DateFormat
        let dateString = formatter.string(from: Date())

        let resolvedLocale = config.customLocale ?? Locale.current.identifier
        let resolvedTimeZone = config.customTimeZone ?? (TimeZone.current.abbreviation() ?? Self.defaultTimeZoneAbbreviation)

        let formattedJSON: [String: String] = [
            "deviceSerialNumber": Self.defaultDeviceSerialNumber,
            "machineID": machineID,
            "oneTimePassword": oneTimePassword,
            "routingInfo": routingInfoStr,
            "deviceDescription": clientInfo,
            "localUserID": localUserID,
            "deviceUniqueIdentifier": deviceUID,
            "date": dateString,
            "locale": resolvedLocale,
            "timeZone": resolvedTimeZone
        ]

        guard let anisetteData = ALTAnisetteData(json: formattedJSON) else {
            debugLog("[OnDeviceAnisetteManager] ERROR: Failed to instantiate ALTAnisetteData from disk-backed JSON.")
            throw OnDeviceAnisetteError.invalidAnisetteData
        }

        debugLog("[OnDeviceAnisetteManager] [Disk Fetch] SUCCESS: ALTAnisetteData generated successfully from disk.")
        return anisetteData
    }

    private func computeSHA256(data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct OnDeviceZIPExtractor {
    static let targetLibraries = LocalAnisetteProvider.requiredLibraryNames
    static let minZIPFileSize = 22
    static let maxEOCDSearchRange = 65557
    static let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    static let centralDirectoryHeaderSignature: UInt32 = 0x02014B50
    static let localFileHeaderSignature: UInt32 = 0x04034B50
    static let macosxPrefix = "__MACOSX"

    static func extract(zipData: Data, to destinationDir: URL) throws {
        let fileSize = zipData.count
        guard fileSize > minZIPFileSize else {
            debugLog("[OnDeviceZIPExtractor] ERROR: Archive too small (\(fileSize) bytes)")
            throw OnDeviceAnisetteError.decompressionFailed("Archive is too small (\(fileSize) bytes).")
        }

        let searchLimit = max(0, fileSize - maxEOCDSearchRange)
        var eocdOffset: Int?
        for i in stride(from: fileSize - minZIPFileSize, through: searchLimit, by: -1) {
            if zipData[i] == eocdSignature[0] &&
               zipData[i + 1] == eocdSignature[1] &&
               zipData[i + 2] == eocdSignature[2] &&
               zipData[i + 3] == eocdSignature[3] {
                eocdOffset = i
                break
            }
        }

        guard let eocdPos = eocdOffset else {
            debugLog("[OnDeviceZIPExtractor] ERROR: EOCD signature not found in archive")
            throw OnDeviceAnisetteError.decompressionFailed("EOCD signature not found in archive.")
        }

        let totalEntries = Int(zipData.getUInt16(at: eocdPos + 10))
        let cdSize = Int(zipData.getUInt32(at: eocdPos + 12))
        let cdOffset = Int(zipData.getUInt32(at: eocdPos + 16))

        guard cdOffset + cdSize <= fileSize else {
            debugLog("[OnDeviceZIPExtractor] ERROR: Central Directory out of bounds (offset=\(cdOffset), size=\(cdSize), file=\(fileSize))")
            throw OnDeviceAnisetteError.decompressionFailed("Central Directory out of bounds.")
        }

        debugLog("[OnDeviceZIPExtractor] Parsing ZIP archive: \(fileSize) bytes, \(totalEntries) entries")
        var offset = cdOffset
        var extractedLibraries = Set<String>()

        for entryIndex in 0..<totalEntries {
            guard offset + 46 <= zipData.count else { break }
            let sig = zipData.getUInt32(at: offset)
            guard sig == centralDirectoryHeaderSignature else { break }

            let compressionMethod = zipData.getUInt16(at: offset + 10)
            let compressedSize = Int(zipData.getUInt32(at: offset + 20))
            let uncompressedSize = Int(zipData.getUInt32(at: offset + 24))
            let fileNameLength = Int(zipData.getUInt16(at: offset + 28))
            let extraLength = Int(zipData.getUInt16(at: offset + 30))
            let commentLength = Int(zipData.getUInt16(at: offset + 32))
            let localHeaderOffset = Int(zipData.getUInt32(at: offset + 42))

            let fileNameStart = offset + 46
            guard fileNameStart + fileNameLength <= zipData.count else { break }
            let nameData = zipData.subdata(in: fileNameStart..<(fileNameStart + fileNameLength))
            let fullPath = String(data: nameData, encoding: .utf8) ?? ""
            let lastComponent = (fullPath as NSString).lastPathComponent

            if !fullPath.contains(macosxPrefix),
               let targetLib = targetLibraries.first(where: { $0.caseInsensitiveCompare(lastComponent) == .orderedSame }) {

                debugLog("[OnDeviceZIPExtractor] Extracting target library #\(entryIndex + 1): \(targetLib) (compressed=\(compressedSize) B, uncompressed=\(uncompressedSize) B, method=\(compressionMethod))")
                guard localHeaderOffset + 30 <= zipData.count else {
                    throw OnDeviceAnisetteError.decompressionFailed("Local file header out of bounds for \(lastComponent).")
                }

                let localSig = zipData.getUInt32(at: localHeaderOffset)
                guard localSig == localFileHeaderSignature else {
                    throw OnDeviceAnisetteError.decompressionFailed("Invalid local header signature for \(lastComponent).")
                }

                let localNameLen = Int(zipData.getUInt16(at: localHeaderOffset + 26))
                let localExtraLen = Int(zipData.getUInt16(at: localHeaderOffset + 28))
                let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen

                guard dataStart + compressedSize <= zipData.count else {
                    throw OnDeviceAnisetteError.decompressionFailed("Compressed data out of bounds for \(lastComponent).")
                }

                let compBytes = zipData.subdata(in: dataStart..<(dataStart + compressedSize))
                let decompressedData: Data

                if compressionMethod == 0 {
                    decompressedData = compBytes
                } else if compressionMethod == 8 {
                    var buffer = Data(count: uncompressedSize)
                    let decodedCount = buffer.withUnsafeMutableBytes { dst in
                        compBytes.withUnsafeBytes { src in
                            compression_decode_buffer(
                                dst.bindMemory(to: UInt8.self).baseAddress!,
                                uncompressedSize,
                                src.bindMemory(to: UInt8.self).baseAddress!,
                                compressedSize,
                                nil,
                                COMPRESSION_ZLIB
                            )
                        }
                    }
                    guard decodedCount == uncompressedSize else {
                        throw OnDeviceAnisetteError.decompressionFailed("ZLIB decompression returned \(decodedCount), expected \(uncompressedSize).")
                    }
                    decompressedData = buffer
                } else {
                    throw OnDeviceAnisetteError.decompressionFailed("Unsupported ZIP compression method (\(compressionMethod)) for \(lastComponent).")
                }

                let destFileURL = destinationDir.appendingPathComponent(targetLib)
                try decompressedData.write(to: destFileURL, options: .atomic)
                extractedLibraries.insert(targetLib)
                debugLog("[OnDeviceZIPExtractor] Wrote \(decompressedData.count) bytes to \(destFileURL.path)")
            }

            offset += 46 + fileNameLength + extraLength + commentLength
        }

        let missing = targetLibraries.filter { !extractedLibraries.contains($0) }
        guard missing.isEmpty else {
            debugLog("[OnDeviceZIPExtractor] ERROR: Missing libraries after extraction: \(missing)")
            throw OnDeviceAnisetteError.missingRequiredLibraries(missing)
        }
        debugLog("[OnDeviceZIPExtractor] Extraction completed successfully. Extracted libraries: \(Array(extractedLibraries))")
    }
}

private extension Data {
    func getUInt16(at offset: Int) -> UInt16 {
        let idx = startIndex + offset
        guard idx + 1 < endIndex else { return 0 }
        let b0 = UInt16(self[idx])
        let b1 = UInt16(self[idx + 1])
        return b0 | (b1 << 8)
    }

    func getUInt32(at offset: Int) -> UInt32 {
        let idx = startIndex + offset
        guard idx + 3 < endIndex else { return 0 }
        let b0 = UInt32(self[idx])
        let b1 = UInt32(self[idx + 1])
        let b2 = UInt32(self[idx + 2])
        let b3 = UInt32(self[idx + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
