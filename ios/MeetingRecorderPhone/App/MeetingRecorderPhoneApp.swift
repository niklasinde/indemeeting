import SwiftUI

@main
struct MeetingRecorderPhoneApp: App {
    @State private var model = AppModel()
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}
