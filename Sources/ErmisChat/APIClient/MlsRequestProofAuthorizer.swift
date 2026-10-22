import Foundation
import CryptoKit

struct MlsRequestProofOwner {
    let userId: String
    let deviceId: String
    let publicKey: Data
    let assertCurrent: () throws -> Void
    let registrationSignature: (String, String, Int64) throws -> Data
    let sign: (String) throws -> Data
}

/// Signs final request bytes after normal auth/device encoding. Never holds MLS execution over HTTP.
final class MlsRequestProofAuthorizer {
    private let session: URLSession
    private let capture: () throws -> MlsRequestProofOwner
    private let lock = NSLock()
    private var registrations: [String: (String, Int64)] = [:]
    init(session: URLSession, capture: @escaping () throws -> MlsRequestProofOwner) {
        self.session = session; self.capture = capture
    }
    func authorize(_ request: URLRequest, guardScope: (() throws -> Void)? = nil, deadline: Date? = nil, completion: @escaping (Result<URLRequest, Error>) -> Void) {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(.failure(ClientError.Unexpected("Invalid MLS request target"))); return
        }
        let path = components.percentEncodedPath
        let operation: Int
        if request.httpMethod == "GET", path == "/v1/e2ee/key_packages/ownership/inventory" { operation = 1 }
        else if request.httpMethod == "POST", path == "/v1/e2ee/key_packages/ownership/reconcile" { operation = 2 }
        else if request.httpMethod == "POST", path == "/v1/e2ee/key_packages" { operation = 6 }
        else if request.httpMethod == "POST", path.hasSuffix("/external_join") { operation = 4 }
        else if request.httpMethod == "GET", path.contains("/external_join/operations/") { operation = 5 }
        else { completion(.success(request)); return }
        func current() throws {
            try guardScope?()
            if let deadline, deadline <= Date() { throw ClientError.Unexpected("key_package_operation_expired") }
        }
        do {
            try current(); let owner = try capture(); try owner.assertCurrent()
            guard request.value(forHTTPHeaderField: "X-Device-ID") == owner.deviceId else {
                throw ClientError.Unexpected("MLS device authority mismatch")
            }
            let segments = url.path.split(separator: "/")
            let projectId: String
            if [1, 2, 6].contains(operation) {
                let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
                let token = try Token(rawValue: authorization.replacingOccurrences(of: "Bearer ", with: ""))
                projectId = token.projectId
                guard token.userId == owner.userId else { throw ClientError.Unexpected("MLS account changed") }
            } else {
                guard segments.count > 4, let project = segments[4].split(separator: ":").first else { throw ClientError.Unexpected("Invalid MLS project") }
                projectId = String(project)
            }
            guard UUID(uuidString: projectId) != nil else { throw ClientError.Unexpected("Invalid MLS project") }
            let key = [url.scheme ?? "", url.host ?? "", String(url.port ?? 443), owner.userId, owner.deviceId, owner.publicKey.base64EncodedString(), projectId].joined(separator: "|")
            lock.lock(); let cached = registrations[key]; lock.unlock()
            let finish: (String, Int64) throws -> Void = { registrationId, generation in
                try current(); try owner.assertCurrent()
                let body = request.httpBody ?? Data()
                guard body.count <= 3 * 1024 * 1024 else { throw ClientError.Unexpected("MLS request too large") }
                let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
                let uploadId = request.value(forHTTPHeaderField: "X-Ermis-MLS-Upload-Operation")
                if let uploadId, operation != 6 || UUID(uuidString: uploadId) == nil { throw ClientError.Unexpected("mls_upload_operation_invalid") }
                let context: [String: Any] = ["version": 1, "project_id": projectId, "device_id": owner.deviceId,
                    "registration_id": registrationId, "generation": generation, "operation": operation, "target": target,
                    "body_sha256": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                    "request_id": uploadId ?? UUID().uuidString.lowercased(), "issued_at": Int64(Date().timeIntervalSince1970)]
                let bytes = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
                guard let text = String(data: bytes, encoding: .utf8) else { throw ClientError.Unexpected("Invalid MLS proof") }
                let envelope: [String: Any] = ["context": context, "ciphersuite": 3,
                    "public_key": owner.publicKey.base64EncodedString(), "signature": try owner.sign(text).base64EncodedString()]
                let header = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                guard header.count <= 8192 else { throw ClientError.Unexpected("MLS proof too large") }
                try owner.assertCurrent()
                var signed = request; signed.setValue(nil, forHTTPHeaderField: "X-Ermis-MLS-Upload-Operation"); signed.setValue(header, forHTTPHeaderField: "X-Ermis-MLS-Proof")
                completion(.success(signed))
            }
            if let cached { try finish(cached.0, cached.1); return }
            let issued = Int64(Date().timeIntervalSince1970)
            let proof: [String: Any] = ["device_id": owner.deviceId, "ciphersuite": 3, "issued_at": issued,
                "signature_public_key": owner.publicKey.base64EncodedString(),
                "signature": try owner.registrationSignature(owner.deviceId, projectId, issued).base64EncodedString()]
            var registrationURL = components; registrationURL.percentEncodedPath = "/v1/e2ee/devices/register"
            guard let endpoint = registrationURL.url else { throw ClientError.Unexpected("Invalid registration target") }
            var registration = request; registration.url = endpoint; registration.httpMethod = "POST"; registration.timeoutInterval = min(2, max(0.001, deadline?.timeIntervalSinceNow ?? 2))
            registration.httpBody = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
            try current()
            session.dataTask(with: registration) { [weak self] data, response, error in
                do {
                    if let error {
                        log.warning("mls_join_http stage=registration result=transport_error status=0", subsystems: .mls)
                        throw error
                    }
                    try current(); try owner.assertCurrent()
                    if let response = response as? HTTPURLResponse {
                        log.warning("mls_join_http stage=registration result=response status=\(response.statusCode)", subsystems: .mls)
                        if response.statusCode == 401 { throw ClientError.ExpiredToken() }
                    }
                    guard let self, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                        let data, data.count <= 4096,
                        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let state = root["registration"] as? [String: Any], state["active"] as? Bool == true,
                        state["device_id"] as? String == owner.deviceId,
                        let id = state["registration_id"] as? String, UUID(uuidString: id) != nil,
                        let generation = state["generation"] as? Int64, generation >= 0 else {
                        throw ClientError.Unexpected("MLS registration unavailable")
                    }
                    self.lock.lock(); if self.registrations.count >= 8 { self.registrations.removeAll() }; self.registrations[key] = (id, generation); self.lock.unlock()
                    try finish(id, generation)
                } catch { completion(.failure(error)) }
            }.resume()
        } catch { completion(.failure(error)) }
    }
}
