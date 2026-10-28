import CryptoKit
import Foundation

public struct EcoFlowCredentials: Sendable, Equatable {
    public var accessKey: String
    public var secretKey: String
    public var serialNumber: String

    public init(accessKey: String, secretKey: String, serialNumber: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.serialNumber = serialNumber
    }

    public var isComplete: Bool {
        ![accessKey, secretKey, serialNumber].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

public struct EcoFlowDevice: Sendable, Equatable, Identifiable {
    public var id: String { serialNumber }
    public var serialNumber: String
    public var name: String
    public var online: Bool
}

public enum EcoFlowError: LocalizedError {
    case http(Int)
    case api(code: String, message: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .http(let status): "EcoFlow returned HTTP \(status)"
        case .api(let code, let message): "EcoFlow error \(code): \(message)"
        case .malformedResponse: "Unexpected response from EcoFlow"
        }
    }
}

/// Signed client for EcoFlow's IoT Open Platform HTTP API.
public struct EcoFlowClient: Sendable {
    public var credentials: EcoFlowCredentials
    public var host: URL
    private let session: URLSession

    public init(credentials: EcoFlowCredentials,
                host: URL = URL(string: "https://api.ecoflow.com")!,
                session: URLSession = .shared) {
        self.credentials = credentials
        self.host = host
        self.session = session
    }

    /// All current quota values for the configured device.
    public func allQuotas() async throws -> Quotas {
        let data = try await get("/iot-open/sign/device/quota/all", query: ["sn": credentials.serialNumber])
        guard let object = data as? [String: Any] else { throw EcoFlowError.malformedResponse }
        return Quotas(json: object)
    }

    /// Every device bound to the developer account. Useful for discovering serial numbers.
    public func devices() async throws -> [EcoFlowDevice] {
        let data = try await get("/iot-open/sign/device/list", query: [:])
        guard let list = data as? [[String: Any]] else { throw EcoFlowError.malformedResponse }
        return list.compactMap { item in
            guard let sn = item["sn"] as? String else { return nil }
            let name = (item["deviceName"] as? String) ?? (item["productName"] as? String) ?? sn
            let online = (item["online"] as? NSNumber)?.intValue == 1
            return EcoFlowDevice(serialNumber: sn, name: name, online: online)
        }
    }

    private func get(_ path: String, query: [String: String]) async throws -> Any? {
        var components = URLComponents(url: host.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        for (field, value) in Self.signedHeaders(params: query, credentials: credentials) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (body, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EcoFlowError.http(http.statusCode)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw EcoFlowError.malformedResponse
        }
        let code = (envelope["code"] as? String) ?? (envelope["code"] as? NSNumber)?.stringValue ?? ""
        guard code == "0" else {
            throw EcoFlowError.api(code: code, message: envelope["message"] as? String ?? "Unknown error")
        }
        return envelope["data"]
    }

    // MARK: Signing

    /// EcoFlow signs requests with HMAC-SHA256 over the request params sorted by key,
    /// followed by `accessKey`, `nonce` and `timestamp`.
    static func signedHeaders(params: [String: String],
                              credentials: EcoFlowCredentials,
                              nonce: String = String(Int.random(in: 100_000...999_999)),
                              timestamp: String = String(Int(Date.now.timeIntervalSince1970 * 1000))) -> [String: String] {
        let sign = signature(params: params, accessKey: credentials.accessKey, secretKey: credentials.secretKey,
                             nonce: nonce, timestamp: timestamp)
        return ["accessKey": credentials.accessKey, "nonce": nonce, "timestamp": timestamp, "sign": sign]
    }

    static func signature(params: [String: String], accessKey: String, secretKey: String,
                          nonce: String, timestamp: String) -> String {
        var parts = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        parts += ["accessKey=\(accessKey)", "nonce=\(nonce)", "timestamp=\(timestamp)"]
        let message = parts.joined(separator: "&")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secretKey.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
