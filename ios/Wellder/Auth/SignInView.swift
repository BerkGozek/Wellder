import AuthenticationServices
import DesignSystem
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "person.2.wave.2.fill").font(.system(size: 44)).foregroundStyle(.tint)
                        Text("Wellder").font(.largeTitle.bold())
                        Text("Stay independent, stay connected. Share chosen health, activity and location information with people you trust.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                switch model.config {
                case .local:
                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("email")
                        SecureField("Password (8+ characters)", text: $password)
                            .textContentType(creating ? .newPassword : .password)
                            .accessibilityIdentifier("password")
                        Button(creating ? "Create account" : "Sign in") {
                            busy = true
                            Task { await model.signInLocal(email: email, password: password, register: creating); busy = false }
                        }
                        .disabled(busy || email.isEmpty || password.count < 8)
                        .accessibilityIdentifier("submitAuth")
                        Toggle("I'm new here", isOn: $creating).accessibilityIdentifier("createAccountToggle")
                    } header: {
                        Text("Local development server")
                    } footer: {
                        Text("Connected to \(model.config.apiBaseURL.absoluteString). Accounts here are for testing only.")
                    }
                case .aws:
                    Section {
                        Button("Sign in") { Task { await model.signInWithCognito(signUp: false, session: webAuth) } }
                        Button("Create account") { Task { await model.signInWithCognito(signUp: true, session: webAuth) } }
                    } footer: {
                        Text("You'll sign in on a secure Amazon Cognito page.")
                    }
                }
                if let e = model.lastError {
                    Section { Text(e).foregroundStyle(.red).accessibilityIdentifier("authError") }
                }
                Section { Text(MonitoringDisclaimer.short).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
