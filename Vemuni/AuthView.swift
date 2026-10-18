import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = false
    @State private var isWorking = false

    var body: some View {
        ZStack {
            VemuniTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    VemuniWordmark()
                        .padding(.top, 44)
                    Text("Scan the menu. Check the bill.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(VemuniTheme.espresso)

                    VStack(spacing: 13) {
                        Button { Task { await auth.signInWithGoogle() } } label: {
                            Label("Continue with Google", systemImage: "g.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AuthButtonStyle())

                        Button { auth.signInWithApple() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "apple.logo")
                                Text("Continue with Apple")
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button {
                            isWorking = true
                            Task {
                                await auth.signInAsGuest()
                                isWorking = false
                            }
                        } label: {
                            Label("Continue as Guest", systemImage: "person.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AuthButtonStyle())
                        .disabled(isWorking)

                        HStack {
                            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                            Text("or").font(.footnote).foregroundStyle(.secondary)
                            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                        }

                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password)
                            .textContentType(createAccount ? .newPassword : .password)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            isWorking = true
                            Task {
                                if createAccount { await auth.createAccount(email: email, password: password) }
                                else { await auth.signIn(email: email, password: password) }
                                isWorking = false
                            }
                        } label: {
                            HStack {
                                if isWorking { ProgressView().tint(.white) }
                                Text(createAccount ? "Create Account" : "Sign In")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(VemuniPrimaryButtonStyle())
                        .disabled(email.isEmpty || password.count < 6 || isWorking)

                        Button(createAccount ? "Already have an account? Sign in" : "New to Vemuni? Create an account") {
                            createAccount.toggle()
                            auth.errorMessage = nil
                        }
                        .font(.subheadline.weight(.medium))

                        if !createAccount {
                            Button("Forgot password?") {
                                Task { _ = await auth.resetPassword(email: email) }
                            }
                            .font(.footnote)
                            .disabled(email.isEmpty)
                        }
                    }
                    .padding(20)
                    .background(VemuniTheme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 24))

                    if let message = auth.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(message.contains("sent") ? VemuniTheme.sage : .red)
                            .multilineTextAlignment(.center)
                    }

                    Text("By continuing, you agree to Vemuni’s Terms and Privacy Policy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
        }
    }
}

private struct AuthButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(VemuniTheme.espresso)
            .padding(.vertical, 15)
            .background(Color.white.opacity(configuration.isPressed ? 0.55 : 0.9))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.08)) }
    }
}
