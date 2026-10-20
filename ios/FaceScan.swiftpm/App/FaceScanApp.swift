import SwiftUI

@main
struct FaceScanApp: App {
    @StateObject private var store = ScanStore()
    @StateObject private var portal = PortalModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(portal)
                // Appairage par QR code : facescan://pair?url=…&token=…
                .onOpenURL { url in portal.handle(url: url) }
                .alert("Portail", isPresented: Binding(
                    get: { portal.pairingMessage != nil },
                    set: { if !$0 { portal.pairingMessage = nil } }
                )) {
                    Button("OK") { portal.pairingMessage = nil }
                } message: {
                    Text(portal.pairingMessage ?? "")
                }
        }
    }
}
