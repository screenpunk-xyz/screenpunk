#if os(iOS)
import SwiftUI
import UIKit

struct DeviceMenuHold<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let open: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(open: open) }
    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        let gesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        gesture.numberOfTouchesRequired = 2
        gesture.minimumPressDuration = 5
        gesture.cancelsTouchesInView = false
        gesture.delegate = context.coordinator
        host.view.addGestureRecognizer(gesture)
        return host
    }
    func updateUIViewController(_ controller: UIHostingController<Content>, context: Context) {
        controller.rootView = content; context.coordinator.open = open
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var open: () -> Void
        init(open: @escaping () -> Void) { self.open = open }
        @objc func held(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { open() } }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
