import SwiftUI

@main
struct TABApp: App {
    @State private var model = AppModel()
    #if SYNC
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onOpenURL { model.handleIncoming($0) }
                #if SYNC
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.requestSync() }
                }
                #endif
        }
    }
}
