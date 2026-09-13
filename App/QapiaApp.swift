import QapiaCore
import SwiftUI

@main
struct QapiaApp: App {
    @NSApplicationDelegateAdaptor(QapiaNotificationDelegate.self) private var notificationDelegate
    @StateObject private var viewModel: MeetingViewModel
    @AppStorage("qapia.selectedTheme") private var selectedTheme: QapiaTheme = .dark

    init() {
        _viewModel = StateObject(wrappedValue: MeetingViewModel(
            store: MeetingStoreFactory.makePersistentStore()
        ))
    }

    var body: some Scene {
        WindowGroup("QAP.ia") {
            RootView(viewModel: viewModel, selectedTheme: $selectedTheme)
                .preferredColorScheme(selectedTheme.colorScheme)
                .onAppear {
                    notificationDelegate.attach(viewModel: viewModel)
                    viewModel.startApplicationServices()
                }
        }
        .defaultSize(width: 900, height: 600)
    }
}
