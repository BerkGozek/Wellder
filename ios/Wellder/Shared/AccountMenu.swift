import SharedModels
import SwiftUI

struct AccountMenu: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let p = model.profile {
                    Text(p.name)
                    if p.roles.count > 1 {
                        Picker("View as", selection: Binding(get: { model.activeRole }, set: { model.switchRole(to: $0) })) {
                            Text("Sharing (Alpha)").tag(Role.alpha)
                            Text("Caregiver (Beta)").tag(Role.beta)
                        }
                    }
                }
                Text(model.config.isLocal ? "Server: local development" : "Server: AWS")
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { Task { await model.signOut() } }
                    .accessibilityIdentifier("signOut")
            } label: {
                Image(systemName: "person.crop.circle").accessibilityLabel("Account")
            }
            .accessibilityIdentifier("accountMenu")
        }
    }
}
