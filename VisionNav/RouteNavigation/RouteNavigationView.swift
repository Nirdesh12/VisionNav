//
//  RouteNavigationView.swift
//  VisionNav
//
//  Split screen with:
//  - Top: Map with highlighted road route (thick blue line)
//  - Bottom: Camera with resizable FOV box + voice feedback

import SwiftUI
import MapKit
import Speech
import AVFoundation
import CoreLocation
import Combine

struct RouteNavigationView: View {
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var cameraManager = NavigationCameraManager()
    @StateObject private var navigationModel = NavigationModel()
    @StateObject private var locationManager = NavigationLocationManager()
    @StateObject private var voiceManager = VoiceInputManager()
    
    @State private var isNavigating: Bool = false
    @State private var showSearch: Bool = false
    @State private var searchText: String = ""
    
    // FOV Box resize gesture state
    @State private var fovScale: CGFloat = 1.0
    @State private var lastFOVScale: CGFloat = 1.0
    
    let detectionTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    let voiceTimer = Timer.publish(every: 8.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    // TOP: Map with road route
                    mapSection
                        .frame(height: geometry.size.height * (isNavigating ? 0.4 : 0.5))
                    
                    // BOTTOM: Camera with FOV box or destination picker
                    if isNavigating {
                        cameraSection(geometry: geometry)
                    } else {
                        destinationSection
                    }
                }
                
                // Overlays
                if voiceManager.isListening { voiceOverlay }
                if showSearch { searchOverlay(geometry: geometry) }
            }
        }
        .ignoresSafeArea(.keyboard)
        .navigationBarHidden(true)
        .onAppear {
            locationManager.requestPermission()
            voiceManager.requestPermission()
            navigationModel.onDistanceUpdate = { [weak cameraManager] distance in
                cameraManager?.updateHaptics(forDistance: distance)
            }
        }
        .onDisappear { endNavigation() }
        .onReceive(detectionTimer) { _ in
            if isNavigating { processFrame() }
        }
        .onReceive(voiceTimer) { _ in
            if isNavigating && locationManager.isRouteCalculated && !locationManager.hasArrived {
                locationManager.speakDirection()
            }
        }
    }
    
    // MARK: - Map Section with Road Route
    private var mapSection: some View {
        ZStack(alignment: .top) {
            // Map with thick blue road route
            HighlightedRouteMapView(
                userLocation: locationManager.userLocation,
                destination: locationManager.destination,
                routePolyline: locationManager.routePolyline,
                hasRoadRoute: locationManager.hasRoadRoute
            )
            
            VStack(spacing: 0) {
                topBar
                
                if isNavigating && locationManager.isRouteCalculated {
                    directionCard
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                
                Spacer()
                
                if locationManager.isRouteCalculated {
                    routeInfoBar
                }
            }
        }
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            Button {
                endNavigation()
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            }
            
            Spacer()
            
            Text(locationManager.isRouteCalculated ? locationManager.destinationName : "Navigation")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
            
            Button {
                locationManager.voiceEnabled.toggle()
                navigationModel.speechEnabled.toggle()
            } label: {
                Image(systemName: locationManager.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.7))
    }
    
    // MARK: - Direction Card
    private var directionCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(maneuverColor)
                    .frame(width: 52, height: 52)
                
                Image(systemName: locationManager.currentManeuver.systemImage)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(locationManager.currentInstruction)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                HStack(spacing: 10) {
                    Text(locationManager.formattedNextStep)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.blue)
                    
                    // Voice button
                    Button {
                        locationManager.speakDirection()
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                    }
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.systemBackground)).shadow(radius: 4))
    }
    
    private var maneuverColor: Color {
        switch locationManager.currentManeuver {
        case .straight: return .blue
        case .slightLeft, .slightRight: return .cyan
        case .left, .right: return .orange
        case .sharpLeft, .sharpRight, .uTurn: return .red
        case .arrive: return .green
        case .depart: return .blue
        }
    }
    
    // MARK: - Route Info Bar
    private var routeInfoBar: some View {
        HStack(spacing: 16) {
            Label(locationManager.formattedDistance, systemImage: "figure.walk")
            Label(locationManager.formattedTime, systemImage: "clock")
            
            Spacer()
            
            // Route type indicator
            HStack(spacing: 4) {
                Image(systemName: locationManager.hasRoadRoute ? "road.lanes" : "compass.drawing")
                Text(locationManager.hasRoadRoute ? "Road Route" : "Compass")
            }
            .font(.caption)
            .foregroundColor(locationManager.hasRoadRoute ? .green : .orange)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Camera Section with Resizable FOV Box
    private func cameraSection(geometry: GeometryProxy) -> some View {
        ZStack {
            // AR Camera
            FullScreenARView(session: cameraManager.arSession)
            
            // Detection boxes (all)
            detectionOverlay
            
            // Resizable FOV Box
            fovBoxOverlay(geometry: geometry)
            
            // UI Overlay
            VStack(spacing: 0) {
                cameraStatusBar
                Spacer()
                alertBanners.padding(.horizontal, 12).padding(.bottom, 8)
                cameraBottomBar
            }
            
            // Proximity indicator
            if cameraManager.currentProximity != .none {
                proximityIndicator
            }
        }
    }
    
    // MARK: - FOV Box Overlay (Resizable)
    private func fovBoxOverlay(geometry: GeometryProxy) -> some View {
        let fovRect = cameraManager.fovBoxNormalized
        let cameraHeight = geometry.size.height * 0.6
        let cameraWidth = geometry.size.width
        
        let boxX = fovRect.minX * cameraWidth
        let boxY = fovRect.minY * cameraHeight
        let boxWidth = fovRect.width * cameraWidth
        let boxHeight = fovRect.height * cameraHeight
        
        return ZStack {
            // Dimmed area outside FOV
            Color.black.opacity(0.3)
                .mask(
                    Rectangle()
                        .overlay(
                            Rectangle()
                                .frame(width: boxWidth, height: boxHeight)
                                .position(x: boxX + boxWidth/2, y: boxY + boxHeight/2)
                                .blendMode(.destinationOut)
                        )
                )
            
            // FOV Box border
            Rectangle()
                .stroke(Color.cyan, lineWidth: 3)
                .frame(width: boxWidth, height: boxHeight)
                .position(x: boxX + boxWidth/2, y: boxY + boxHeight/2)
            
            // Corner handles
            ForEach(0..<4) { corner in
                let xOffset: CGFloat = corner % 2 == 0 ? boxX : boxX + boxWidth
                let yOffset: CGFloat = corner < 2 ? boxY : boxY + boxHeight
                
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 20, height: 20)
                    .position(x: xOffset, y: yOffset)
            }
            
            // Depth info in FOV
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FOV Depth")
                            .font(.system(size: 10))
                        Text(String(format: "%.1fm", cameraManager.nearestObstacleDistance))
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.cyan)
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    // Resize buttons
                    HStack(spacing: 8) {
                        Button {
                            cameraManager.adjustFOVWidth(delta: -0.1)
                            cameraManager.adjustFOVHeight(delta: -0.1)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.cyan)
                        }
                        
                        Button {
                            cameraManager.resetFOVBox()
                        } label: {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.cyan)
                        }
                        
                        Button {
                            cameraManager.adjustFOVWidth(delta: 0.1)
                            cameraManager.adjustFOVHeight(delta: 0.1)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.cyan)
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 80)
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { scale in
                    let delta = (scale - lastFOVScale) * 0.5
                    cameraManager.adjustFOVWidth(delta: delta)
                    cameraManager.adjustFOVHeight(delta: delta)
                    lastFOVScale = scale
                }
                .onEnded { _ in
                    lastFOVScale = 1.0
                }
        )
    }
    
    // MARK: - Camera Status Bar
    private var cameraStatusBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(navigationModel.isModelLoaded ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(navigationModel.modelName).font(.system(size: 11, weight: .medium))
            }
            Spacer()
            if cameraManager.hasLiDAR {
                HStack(spacing: 4) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    Text("LiDAR")
                }.font(.system(size: 10)).foregroundColor(.green)
            }
            Text("\(navigationModel.detectionsInFOV.count)/\(navigationModel.detectionCount)")
                .font(.system(size: 11))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
    }
    
    // MARK: - Detection Overlay
    private var detectionOverlay: some View {
        GeometryReader { geo in
            ForEach(navigationModel.detections.prefix(10)) { det in
                let rect = CGRect(
                    x: det.boundingBox.minX * geo.size.width,
                    y: (1 - det.boundingBox.maxY) * geo.size.height,
                    width: det.boundingBox.width * geo.size.width,
                    height: det.boundingBox.height * geo.size.height
                )
                
                // Check if in FOV
                let isInFOV = navigationModel.detectionsInFOV.contains { $0.id == det.id }
                
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isInFOV ? boxColor(for: det.distance) : Color.gray.opacity(0.5), lineWidth: isInFOV ? 2 : 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                
                if isInFOV {
                    HStack(spacing: 4) {
                        Text(det.label)
                        if let d = det.distance { Text(String(format: "%.1fm", d)) }
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(boxColor(for: det.distance)))
                    .position(x: rect.midX, y: max(rect.minY - 12, 20))
                }
            }
        }
    }
    
    private func boxColor(for distance: Float?) -> Color {
        guard let d = distance else { return .green }
        if d < 1.0 { return .red }
        if d < 2.0 { return .orange }
        if d < 3.0 { return .yellow }
        return .green
    }
    
    // MARK: - Proximity Indicator
    private var proximityIndicator: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: proximityIcon).font(.system(size: 24))
                    Text(String(format: "%.1fm", cameraManager.nearestObstacleDistance)).font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(proximityColor)
                .padding(12)
                .background(Circle().fill(Color.black.opacity(0.8)))
                .padding(12)
            }
            Spacer()
        }
        .padding(.top, 50)
    }
    
    private var proximityIcon: String {
        switch cameraManager.currentProximity {
        case .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "info.circle.fill"
        case .none: return "checkmark.circle.fill"
        }
    }
    
    private var proximityColor: Color {
        switch cameraManager.currentProximity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        case .none: return .green
        }
    }
    
    // MARK: - Alert Banners
    private var alertBanners: some View {
        VStack(spacing: 6) {
            if let alert = navigationModel.currentAlert {
                HStack {
                    Image(systemName: alert.alertType.icon)
                    Text(alert.message).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(alert.alertType == .danger ? .white : .black)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(alert.alertType.color)))
            }
            
            if cameraManager.stepDetected && cameraManager.stepType != .none {
                HStack {
                    Image(systemName: "stairs")
                    Text(cameraManager.stepType.rawValue).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(.black)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow))
            }
            
            if locationManager.hasArrived {
                HStack {
                    Image(systemName: "flag.checkered")
                    Text("You have arrived!").font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green))
            }
        }
    }
    
    // MARK: - Camera Bottom Bar
    private var cameraBottomBar: some View {
        HStack {
            Button { endNavigation() } label: {
                HStack {
                    Image(systemName: "xmark")
                    Text("End")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.red))
            }
            
            Spacer()
            
            // Voice direction button
            Button {
                locationManager.speakDirection()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.blue))
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(locationManager.formattedDistance).font(.system(size: 16, weight: .bold))
                Text("remaining").font(.system(size: 10))
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Destination Section
    private var destinationSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 44))
                    .foregroundColor(.blue)
                
                Text("Set Destination")
                    .font(.title2.bold())
                
                Text("Voice-guided navigation")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 30) {
                    Button { voiceManager.startListening() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "mic.fill").font(.system(size: 26))
                            Text("Voice").font(.caption.bold())
                        }
                        .foregroundColor(.white)
                        .frame(width: 70, height: 70)
                        .background(Circle().fill(Color.blue))
                    }
                    
                    Button { showSearch = true } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 26))
                            Text("Search").font(.caption.bold())
                        }
                        .foregroundColor(.white)
                        .frame(width: 70, height: 70)
                        .background(Circle().fill(Color.green))
                    }
                }
            }
            .padding(.top, 30)
            
            Spacer()
            
            if locationManager.isRouteCalculated {
                Button { startNavigation() } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        Text("Start Navigation")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .background(Color(UIColor.systemBackground))
    }
    
    // MARK: - Voice Overlay
    private var voiceOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
                .onTapGesture { voiceManager.stopListening() }
            
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.2)).frame(width: 100, height: 100)
                    Image(systemName: "mic.fill").font(.system(size: 40)).foregroundColor(.white)
                }
                
                Text("Listening...").font(.title3.bold()).foregroundColor(.white)
                Text(voiceManager.recognizedText.isEmpty ? "Say destination" : voiceManager.recognizedText)
                    .font(.headline).foregroundColor(.white.opacity(0.8)).padding(.horizontal)
                
                HStack(spacing: 40) {
                    Button { voiceManager.stopListening() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 44)).foregroundColor(.red)
                    }
                    
                    if !voiceManager.recognizedText.isEmpty {
                        Button {
                            let q = voiceManager.recognizedText
                            voiceManager.stopListening()
                            searchText = q
                            locationManager.search(query: q)
                            showSearch = true
                        } label: {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundColor(.green)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Search Overlay
    private func searchOverlay(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search Destination").font(.headline)
                Spacer()
                Button {
                    hideKeyboard()
                    showSearch = false
                    searchText = ""
                    locationManager.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.gray)
                }
            }.padding()
            
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("Search places", text: $searchText)
                    .autocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { locationManager.search(query: searchText) }
                if !searchText.isEmpty {
                    Button { searchText = ""; locationManager.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                    }
                }
            }
            .padding(12)
            .background(Color(UIColor.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)
            
            if searchText.isEmpty && locationManager.searchResults.isEmpty {
                Text("Try: Naya Bus Park, Thamel, Ratna Park")
                    .font(.caption).foregroundColor(.secondary).padding(.top, 8)
            }
            
            if locationManager.isSearching { ProgressView().padding() }
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(locationManager.searchResults) { result in
                        Button {
                            hideKeyboard()
                            locationManager.setDestination(from: result)
                            showSearch = false
                            searchText = ""
                            locationManager.clearSearch()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").font(.title2).foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                                    Text(result.address).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if let dist = result.distance {
                                    Text(locationManager.formatDistance(dist)).font(.caption).foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right").foregroundColor(.gray)
                            }.padding()
                        }
                        Divider().padding(.leading, 56)
                    }
                }
            }
            Spacer()
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(20)
        .shadow(radius: 20)
        .padding(.horizontal, 8)
        .padding(.top, geometry.safeAreaInsets.top + 10)
        .padding(.bottom, 20)
    }
    
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    // MARK: - Navigation Functions
    private func startNavigation() {
        cameraManager.startSession()
        navigationModel.startNavigation()
        isNavigating = true
        locationManager.speak("Navigation started. \(locationManager.currentInstruction)", force: true)
    }
    
    private func endNavigation() {
        cameraManager.stopSession()
        navigationModel.endNavigation()
        locationManager.clearRoute()
        isNavigating = false
    }
    
    private func processFrame() {
        guard cameraManager.isSessionRunning, let frame = cameraManager.currentFrame else { return }
        navigationModel.processFrame(
            pixelBuffer: frame,
            depthData: cameraManager.currentDepthData,
            stepInfo: (cameraManager.stepDetected, cameraManager.stepType, cameraManager.stepDistance),
            fovBox: cameraManager.fovBoxNormalized
        )
    }
}

// MARK: - Map View with Highlighted Road Route
struct HighlightedRouteMapView: UIViewRepresentable {
    let userLocation: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let routePolyline: MKPolyline?
    let hasRoadRoute: Bool
    
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.showsBuildings = true
        map.showsTraffic = true
        
        // User interaction enabled
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        
        // Don't auto-track to prevent jumping
        map.userTrackingMode = .none
        
        return map
    }
    
    func updateUIView(_ map: MKMapView, context: Context) {
        // Clear old overlays and annotations
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        
        // Add route polyline
        if let polyline = routePolyline {
            map.addOverlay(polyline, level: .aboveRoads)
            
            // Zoom to fit route only once
            if !context.coordinator.hasSetRegion {
                let rect = polyline.boundingMapRect
                let padding = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
                map.setVisibleMapRect(rect, edgePadding: padding, animated: true)
                context.coordinator.hasSetRegion = true
            }
        } else if let userLoc = userLocation, !context.coordinator.hasSetRegion {
            let region = MKCoordinateRegion(center: userLoc, latitudinalMeters: 1000, longitudinalMeters: 1000)
            map.setRegion(region, animated: true)
            context.coordinator.hasSetRegion = true
        }
        
        // Add destination marker
        if let dest = destination {
            let ann = MKPointAnnotation()
            ann.coordinate = dest
            ann.title = "Destination"
            map.addAnnotation(ann)
        }
        
        context.coordinator.hasRoadRoute = hasRoadRoute
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var hasSetRegion = false
        var hasRoadRoute = false
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                
                // THICK BLUE LINE for visibility
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = hasRoadRoute ? 8 : 5  // Thicker for road routes
                renderer.lineCap = .round
                renderer.lineJoin = .round
                
                // Dashed for compass routes
                if !hasRoadRoute {
                    renderer.lineDashPattern = [10, 5]
                }
                
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "dest")
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "flag.fill")
            view.displayPriority = .required
            view.animatesWhenAdded = true
            return view
        }
    }
}

// MARK: - Voice Input Manager
class VoiceInputManager: ObservableObject {
    @Published var isListening = false
    @Published var recognizedText = ""
    @Published var isAuthorized = false
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    
    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
    
    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async { self?.isAuthorized = (status == .authorized) }
        }
    }
    
    func startListening() {
        recognizedText = ""
        guard isAuthorized, let recognizer = speechRecognizer, recognizer.isAvailable else { return }
        stopListening()
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        engine.prepare()
        do { try engine.start() } catch { return }
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            if let result = result {
                DispatchQueue.main.async { self?.recognizedText = result.bestTranscription.formattedString }
            }
        }
        
        DispatchQueue.main.async { self.isListening = true }
    }
    
    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.isListening = false }
    }
}

#Preview {
    RouteNavigationView()
}
