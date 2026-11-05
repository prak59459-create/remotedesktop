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
            .alert(session.alert?.title ?? "",
                   isPresented: Binding(get: { session.alert != nil },
                                        set: { if !$0 { session.alert = nil } }),
                   presenting: session.alert) { _ in
                Button("OK") {}
            } message: { a in
                Text(a.message)
            }
            #if RD_SCREENSHOTS
            .onAppear { Task { @MainActor in ScreenshotDriver.shared.start(session: session) } }
            #endif
        }
    }
}
