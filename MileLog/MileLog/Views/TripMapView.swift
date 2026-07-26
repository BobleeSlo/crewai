import SwiftUI
import MapKit

/// Renders the GPS polyline of a trip on a map. Non-interactive by default
/// for use as a small inline preview inside a scrolling Form (pinch/pan
/// there would fight the Form's own scroll gesture) — pass
/// `isInteractive: true` for a full-screen presentation, so a user can
/// actually pinch-zoom to verify a route on what may be a tax-relevant
/// record, which the inline preview alone never allowed (round-1 UX
/// review finding).
struct TripMapView: UIViewRepresentable {
    let points: [TripPointDTO]
    var isInteractive: Bool = false

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isUserInteractionEnabled = isInteractive
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.removeOverlays(uiView.overlays)
        uiView.removeAnnotations(uiView.annotations)

        let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        guard coords.count >= 2 else { return }

        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        uiView.addOverlay(polyline)

        if let first = coords.first {
            uiView.addAnnotation(annotation(at: first, title: "Start"))
        }
        if let last = coords.last {
            uiView.addAnnotation(annotation(at: last, title: "End"))
        }

        uiView.setVisibleMapRect(
            polyline.boundingMapRect,
            edgePadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24),
            animated: false
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func annotation(at coord: CLLocationCoordinate2D, title: String) -> MKPointAnnotation {
        let a = MKPointAnnotation()
        a.coordinate = coord
        a.title = title
        return a
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemBlue
                r.lineWidth = 4
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
