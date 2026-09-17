import ApplicationServices
import CoreGraphics

/// Small accessibility helpers shared by the event sources and the activation
/// service.
///
/// Geometry is the only public way to connect a window to its accessibility
/// element on macOS 27: the private `AXCGWindowID` attribute is gone, so a
/// `CGWindowID` has to be matched against `kAXPositionAttribute` /
/// `kAXSizeAttribute` instead.
enum AXGeometry {

    static func attribute(of element: AXUIElement, key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
            return nil
        }
        return value
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(of: element, key: kAXParentAttribute as CFString) else {
            return nil
        }
        return value as! AXUIElement?
    }

    /// The element's frame in global screen coordinates, which is the same
    /// coordinate space `CGWindowListCopyWindowInfo` reports bounds in.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(of: element, key: kAXPositionAttribute as CFString),
              let sizeValue = attribute(of: element, key: kAXSizeAttribute as CFString),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }
}
