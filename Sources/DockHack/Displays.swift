import AppKit

/// A connected display, in Quartz global coordinates
/// (origin = top-left of the main display, y grows downward).
struct Display: Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let bounds: CGRect
}

enum Displays {
    static func all() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = screen.localizedName
            }
        }

        return ids
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { Display(id: $0, uuid: uuidString($0), name: names[$0] ?? "Display \($0)", bounds: CGDisplayBounds($0)) }
    }

    static func uuidString(_ id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "id-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The display that sits highest in the arrangement (smallest Quartz minY).
    static func topmost(_ displays: [Display]) -> Display? {
        displays.min { a, b in
            a.bounds.minY != b.bounds.minY ? a.bounds.minY < b.bounds.minY : a.bounds.width > b.bounds.width
        }
    }

    /// Horizontal stretches of `display`'s bottom edge that have no other display directly below them.
    /// Only these stretches are "real" screen edges where the cursor stops and the Dock can be summoned.
    static func freeBottomSegments(of display: Display, among displays: [Display]) -> [ClosedRange<CGFloat>] {
        var segments: [ClosedRange<CGFloat>] = [display.bounds.minX...display.bounds.maxX]
        for other in displays where other.id != display.id {
            guard abs(other.bounds.minY - display.bounds.maxY) < 1 else { continue }
            let cut = other.bounds.minX...other.bounds.maxX
            segments = segments.flatMap { seg -> [ClosedRange<CGFloat>] in
                guard seg.overlaps(cut) else { return [seg] }
                var parts: [ClosedRange<CGFloat>] = []
                if seg.lowerBound < cut.lowerBound { parts.append(seg.lowerBound...cut.lowerBound) }
                if cut.upperBound < seg.upperBound { parts.append(cut.upperBound...seg.upperBound) }
                return parts
            }
        }
        return segments.filter { $0.upperBound - $0.lowerBound >= 8 }
    }

    /// Which display the Dock currently lives on. The Dock owns one on-screen window at the
    /// Dock window level that covers the display it is on.
    static func dockDisplay(among displays: [Display]) -> Display? {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: (Display, CGFloat)?
        for window in list {
            guard (window[kCGWindowOwnerName as String] as? String) == "Dock",
                  (window[kCGWindowLayer as String] as? Int) == dockLevel,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            for d in displays {
                let overlap = d.bounds.intersection(rect)
                guard !overlap.isNull else { continue }
                let area = overlap.width * overlap.height
                if area > (best?.1 ?? 0) { best = (d, area) }
            }
        }
        return best?.0 ?? dockDisplayFromVisibleFrames(among: displays)
    }

    /// Fallback: the screen whose visible frame is inset at the bottom is the one with the Dock.
    private static func dockDisplayFromVisibleFrames(among displays: [Display]) -> Display? {
        for screen in NSScreen.screens where screen.visibleFrame.minY - screen.frame.minY > 0.5 {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return displays.first { $0.id == n.uint32Value }
            }
        }
        return nil
    }

    static func dockOrientation() -> String {
        (CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String) ?? "bottom"
    }
}
