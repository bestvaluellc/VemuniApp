import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Foundation
import UIKit

enum ScanSaveState: Equatable {
    case saving
    case saved
    case failed(String)
}

enum VisitStorageError: LocalizedError {
    case notSignedIn
    case imageEncoding
    case invalidScanData

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in before saving this scan."
        case .imageEncoding:
            return "The bill image could not be prepared for saving."
        case .invalidScanData:
            return "The scan data could not be prepared for saving."
        }
    }
}

struct SavedVisit: Equatable {
    let id: String
    let receiptImagePath: String?
}

struct SavedVisitRecord: Identifiable, Equatable {
    let id: String
    let result: VemuniScanResult
    let createdAt: Date?
    let pageCount: Int
    let receiptImagePath: String?
}

struct VisitStorageService {
    func loadReceiptImage(at path: String) async throws -> UIImage {
        let data = try await Storage.storage()
            .reference(withPath: path)
            .data(maxSize: 20 * 1024 * 1024)
        guard let image = UIImage(data: data) else {
            throw VisitStorageError.imageEncoding
        }
        return image
    }

    func delete(_ visit: SavedVisitRecord) async throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw VisitStorageError.notSignedIn
        }

        if let receiptImagePath = visit.receiptImagePath {
            let expectedPrefix = "users/\(userId)/visits/\(visit.id)/receipts/"
            guard receiptImagePath.hasPrefix(expectedPrefix) else {
                throw VisitStorageError.invalidScanData
            }

            do {
                try await Storage.storage().reference(withPath: receiptImagePath).delete()
            } catch {
                let storageError = error as NSError
                if storageError.code != StorageErrorCode.objectNotFound.rawValue {
                    throw error
                }
            }
        }

        try await Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("visits")
            .document(visit.id)
            .delete()
    }

    func fetchVisits() async throws -> [SavedVisitRecord] {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw VisitStorageError.notSignedIn
        }

        let snapshot = try await Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("visits")
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return try snapshot.documents.map { document in
            let data = document.data()
            guard let scanData = data["scanResult"] as? [String: Any] else {
                throw VisitStorageError.invalidScanData
            }
            let encodedResult = try JSONSerialization.data(withJSONObject: scanData)
            let result = try JSONDecoder().decode(VemuniScanResult.self, from: encodedResult)

            return SavedVisitRecord(
                id: document.documentID,
                result: result,
                createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
                pageCount: data["pageCount"] as? Int ?? 1,
                receiptImagePath: data["receiptImagePath"] as? String
            )
        }
    }

    func save(
        result: VemuniScanResult,
        sourceImages: [UIImage]
    ) async throws -> SavedVisit {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw VisitStorageError.notSignedIn
        }

        let visitId = UUID().uuidString.lowercased()
        var receiptImagePath: String?
        var receiptImageReference: StorageReference?

        if result.kind == ScanMode.receipt.rawValue, let image = sourceImages.first {
            guard let imageData = image.vemuniUploadData(maxDimension: 1800) else {
                throw VisitStorageError.imageEncoding
            }

            let path = "users/\(userId)/visits/\(visitId)/receipts/original.jpg"
            let reference = Storage.storage().reference(withPath: path)
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"
            metadata.customMetadata = [
                "ownerId": userId,
                "visitId": visitId
            ]
            _ = try await reference.putDataAsync(imageData, metadata: metadata)
            receiptImagePath = path
            receiptImageReference = reference
        }

        do {
            let encodedResult = try JSONEncoder().encode(result)
            guard let scanData = try JSONSerialization.jsonObject(with: encodedResult) as? [String: Any] else {
                throw VisitStorageError.invalidScanData
            }

            var document: [String: Any] = [
                "ownerId": userId,
                "kind": result.kind,
                "restaurantName": result.restaurantName ?? NSNull(),
                "currencyCode": result.currencyCode,
                "pageCount": sourceImages.count,
                "scanResult": scanData,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let receiptImagePath {
                document["receiptImagePath"] = receiptImagePath
            }

            try await Firestore.firestore()
                .collection("users")
                .document(userId)
                .collection("visits")
                .document(visitId)
                .setData(document)

            return SavedVisit(id: visitId, receiptImagePath: receiptImagePath)
        } catch {
            // Avoid leaving an orphaned bill image if the Firestore write fails.
            try? await receiptImageReference?.delete()
            throw error
        }
    }
}
