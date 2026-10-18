import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import Security
import UIKit

@MainActor
final class AuthViewModel: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var isCheckingSession = true
    @Published var errorMessage: String?

    private var listener: AuthStateDidChangeListenerHandle?
    private var appleCoordinator: AppleSignInCoordinator?

    init() {
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                self?.isCheckingSession = false
            }
        }
    }

    deinit {
        if let listener { Auth.auth().removeStateDidChangeListener(listener) }
    }

    func signIn(email: String, password: String) async {
        VemuniAnalytics.authAttempt(method: "password")
        await perform(method: "password") { try await Auth.auth().signIn(withEmail: email, password: password) }
    }

    func createAccount(email: String, password: String) async {
        VemuniAnalytics.authAttempt(method: "password", creatingAccount: true)
        await perform(method: "password") { try await Auth.auth().createUser(withEmail: email, password: password) }
    }

    func signInAsGuest() async {
        VemuniAnalytics.authAttempt(method: "guest")
        await perform(method: "guest") { try await Auth.auth().signInAnonymously() }
    }

    func resetPassword(email: String) async -> Bool {
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
            errorMessage = "Password reset email sent."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signInWithGoogle() async {
        VemuniAnalytics.authAttempt(method: "google")
        guard let clientID = FirebaseApp.app()?.options.clientID,
              let presenter = UIApplication.shared.topViewController else {
            errorMessage = "Google Sign-In is not configured."
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthViewError.missingGoogleToken
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            let authResult = try await Auth.auth().signIn(with: credential)
            VemuniAnalytics.authCompleted(method: "google", isNewUser: authResult.additionalUserInfo?.isNewUser == true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithApple() {
        VemuniAnalytics.authAttempt(method: "apple")
        let coordinator = AppleSignInCoordinator()
        appleCoordinator = coordinator
        coordinator.start { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let credential):
                    do {
                        let authResult = try await Auth.auth().signIn(with: credential)
                        VemuniAnalytics.authCompleted(method: "apple", isNewUser: authResult.additionalUserInfo?.isNewUser == true)
                    }
                    catch { self?.errorMessage = error.localizedDescription }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        self?.errorMessage = error.localizedDescription
                    }
                }
                self?.appleCoordinator = nil
            }
        }
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(method: String, _ operation: () async throws -> AuthDataResult) async {
        errorMessage = nil
        do {
            let result = try await operation()
            VemuniAnalytics.authCompleted(method: method, isNewUser: result.additionalUserInfo?.isNewUser == true)
        }
        catch { errorMessage = error.localizedDescription }
    }
}

private enum AuthViewError: LocalizedError {
    case missingGoogleToken
    var errorDescription: String? { "Google did not return an identity token." }
}

private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
                                             ASAuthorizationControllerPresentationContextProviding {
    private var currentNonce = ""
    private var completion: ((Result<AuthCredential, Error>) -> Void)?

    func start(completion: @escaping (Result<AuthCredential, Error>) -> Void) {
        currentNonce = Self.randomNonce()
        self.completion = completion
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(currentNonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = apple.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            completion?(.failure(AuthViewError.missingGoogleToken))
            return
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: token,
            rawNonce: currentNonce,
            fullName: apple.fullName
        )
        completion?(.success(credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion?(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonce(length: Int = 32) -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { return UUID().uuidString }
            for byte in bytes where remaining > 0 && byte < characters.count {
                result.append(characters[Int(byte)])
                remaining -= 1
            }
        }
        return result
    }
}

private extension UIApplication {
    var topViewController: UIViewController? {
        let root = connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        return Self.top(from: root)
    }

    static func top(from controller: UIViewController?) -> UIViewController? {
        if let nav = controller as? UINavigationController { return top(from: nav.visibleViewController) }
        if let tab = controller as? UITabBarController { return top(from: tab.selectedViewController) }
        if let presented = controller?.presentedViewController { return top(from: presented) }
        return controller
    }
}
