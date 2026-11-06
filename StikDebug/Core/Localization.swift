import Foundation

enum VNLocalization {
    static let bundle: Bundle = {
        guard let path = Bundle.main.path(forResource: "vi", ofType: "lproj"), let bundle = Bundle(path: path) else { return .main }
        return bundle
    }()
}

extension String {
    var localized: String {
        NSLocalizedString(self, bundle: VNLocalization.bundle, comment: "")
    }
}

