import Foundation
import FirebaseAuth
import UIKit

enum ScanServiceError: LocalizedError {
    case missingEndpoint
    case imageEncoding
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "Add your deployed Vemuni scan URL to VEMUNI_SCAN_ENDPOINT in Info.plist."
        case .imageEncoding: return "The photo could not be prepared for scanning."
        case .invalidResponse: return "Vemuni received an unreadable response. Please try again."
        case .server(let message): return message
        }
    }
}

struct ScanService {
    func analyze(image: UIImage, mode: ScanMode) async throws -> VemuniScanResult {
        guard
            let endpoint = Bundle.main.object(forInfoDictionaryKey: "VEMUNI_SCAN_ENDPOINT") as? String,
            !endpoint.isEmpty,
            !endpoint.contains("YOUR_PROJECT") ,
            let url = URL(string: endpoint)
        else { throw ScanServiceError.missingEndpoint }

        guard let imageData = image.vemuniUploadData() else {
            throw ScanServiceError.imageEncoding
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let user = Auth.auth().currentUser else {
            throw ScanServiceError.server("Sign in before scanning.")
        }
        let idToken = try await user.getIDToken(forcingRefresh: false)
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ScanRequest(
            mode: mode.rawValue,
            imageBase64: imageData.base64EncodedString()
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ScanServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(ServerError.self, from: data)
            throw ScanServiceError.server(payload?.error ?? "The scan failed. Please try again.")
        }
        return try JSONDecoder().decode(VemuniScanResult.self, from: data)
    }

}

private struct ScanRequest: Encodable {
    let mode: String
    let imageBase64: String
}

private struct ServerError: Decodable {
    let error: String
}
