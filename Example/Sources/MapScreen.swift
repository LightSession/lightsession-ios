import MapKit
import UIKit

/// A map, which paints its street names and pins into a picture of its own.
///
/// Here because nothing else in the sample has one, and a map is the shape the mask walk cannot see
/// into: MapKit draws its tiles with Metal, so there is no label and no layer contents for the walk to
/// find, and a capture of a map showed every street name on it. No key is needed, which is why it is
/// MapKit rather than the Google map an app is as likely to use — `NativeMaps` recognises both.
final class MapScreen: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "A map"
        view.backgroundColor = .systemBackground

        let map = MKMapView()
        map.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(map)
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            map.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            map.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let home = CLLocationCoordinate2D(latitude: -23.5613, longitude: -46.6565)
        map.setRegion(MKCoordinateRegion(center: home, latitudinalMeters: 600, longitudinalMeters: 600), animated: false)
        let pin = MKPointAnnotation()
        pin.coordinate = home
        pin.title = "Rua das Flores 120"
        map.addAnnotation(pin)
    }
}
