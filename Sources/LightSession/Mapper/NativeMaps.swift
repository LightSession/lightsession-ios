#if canImport(UIKit)
import UIKit

/// Whether a view is a map, recognised by class so the SDK links no map library.
///
/// A map paints its street names, its pins and whatever address it is showing into a picture of its
/// own — Metal tiles, not labels — so the view walk finds no text in it and a capture shipped it
/// legible. The same shape as a web page, and the same answer: covered whole when text or images are
/// masked. See `ViewSnapshot.unreadable`.
///
/// By name, resolved once, and matched with `isKind(of:)` so an app's own subclass of a map view is a
/// map too. The public map views of Apple's MapKit, Google Maps, Mapbox (both generations), MapLibre
/// and HERE. Google's is also what `google_maps_flutter` puts on screen, as a platform view the walk
/// does reach inside a Flutter screen. A name that is wrong for some SDK version resolves to no class
/// and matches nothing, which is the failure worth having: it costs coverage, never a crash.
enum NativeMaps {

    private static let names = [
        "MKMapView",
        "GMSMapView",
        "MGLMapView",
        "MapboxMaps.MapView",
        "MLNMapView",
        "heresdk.MapView",
    ]

    private static let classes: [AnyClass] = names.compactMap { NSClassFromString($0) }

    static func isMap(_ view: UIView) -> Bool {
        classes.contains { view.isKind(of: $0) }
    }
}
#endif
