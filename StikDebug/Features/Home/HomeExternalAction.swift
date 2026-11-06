//
//  HomeExternalAction.swift
//  StikDebug
//

import Foundation
import SwiftUI

struct JITEnableConfiguration {
    var bundleID: String?
    var pid: Int?
    var scriptData: Data?
    var scriptName: String?
}

enum ProcessKillTarget {
    case pid(Int32)
    case name(String)

    var description: String {
        switch self {
        case .pid(let pid): return String(pid)
        case .name(let name): return name
        }
    }
}

enum HomeExternalAction: Identifiable {
    case enableJIT(JITEnableConfiguration)
    case killProcess(ProcessKillTarget)
    case launchApp(String)

    var id: String {
        switch self {
        case .enableJIT(let configuration):
            return "enable-\(configuration.bundleID ?? "")-\(configuration.pid ?? 0)-\(configuration.scriptName ?? "")"
        case .killProcess(let target):
            return "kill-\(target)"
        case .launchApp(let bundleID):
            return "launch-\(bundleID)"
        }
    }

    var title: String {
        switch self {
        case .enableJIT:
            return "Enable JIT?".localized
        case .killProcess:
            return "Kill Process?".localized
        case .launchApp:
            return "Launch App?".localized
        }
    }

    var message: String {
        switch self {
        case .enableJIT(let configuration):
            let scriptText = configuration.scriptData == nil ? "" : " and run a script".localized
            return "Một liên kết bên ngoài yêu cầu bật JIT\(scriptText) cho \(targetDescription(for: configuration))."
        case .killProcess(let target):
            return "Một liên kết bên ngoài yêu cầu kết thúc tiến trình \(target.description)."
        case .launchApp(let bundleID):
            return "Một liên kết bên ngoài yêu cầu mở \(bundleID)."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .enableJIT(let configuration):
            return configuration.scriptData == nil ? "Enable JIT".localized : "Enable and Run Script".localized
        case .killProcess:
            return "Kill Process".localized
        case .launchApp:
            return "Launch App".localized
        }
    }

    var role: ButtonRole? {
        switch self {
        case .enableJIT(let configuration):
            return configuration.scriptData == nil ? nil : .destructive
        case .killProcess:
            return .destructive
        case .launchApp:
            return nil
        }
    }

    private func targetDescription(for configuration: JITEnableConfiguration) -> String {
        if let bundleID = configuration.bundleID {
            return bundleID
        }
        if let pid = configuration.pid {
            return "tiến trình \(pid)"
        }
        return "the requested app".localized
    }
}

