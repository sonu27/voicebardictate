import Foundation
import ServiceManagement

struct LaunchAtLoginService {
    var isSupportedEnvironment: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func isEnabled() -> Bool {
        guard isSupportedEnvironment else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isSupportedEnvironment else {
            throw LaunchAtLoginError.requiresAppBundle
        }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case requiresAppBundle

    var errorDescription: String? {
        switch self {
        case .requiresAppBundle:
            return "Start at login requires running the signed .app bundle (not swift run)."
        }
    }
}
