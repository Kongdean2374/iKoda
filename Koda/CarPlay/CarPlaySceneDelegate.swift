#if !targetEnvironment(macCatalyst)
import CarPlay
import UIKit

/// Used when iOS grants the signed app a CarPlay audio scene.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        let row = CPListItem(text: String(localized: "Now Playing"), detailText: nil)
        row.handler = { [weak interfaceController] _, completion in
            guard let interfaceController else { completion(); return }
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            completion()
        }
        let root = CPListTemplate(title: "Koda", sections: [CPListSection(items: [row])])
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
    }

}
#endif
