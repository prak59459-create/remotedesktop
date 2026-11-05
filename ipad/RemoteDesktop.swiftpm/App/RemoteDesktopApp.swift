import SwiftUI

@main
struct RemoteDesktopApp: App {
    @StateObject private var session = ViewerSession()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isShowingScreen {
                    RemoteScreenContainer(session: session)
                } else {
                    ConnectView(session: session)
                }
            }
            .alert(item: $session.alert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            #if RD_SCREENSHOTS
            .onAppear { Task { @MainActor in ScreenshotDriver.shared.start(session: session) } }
            #endif
        }
    }
}
