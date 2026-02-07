//
//  NavigationLocationManager.swift
//  VisionNav
//
//  OpenStreetMap OSRM routing for Nepal (Apple Maps doesn't support Nepal)
//  Falls back to compass navigation when offline

import Foundation
import CoreLocation
import MapKit
import AVFoundation
import Combine

// MARK: - Maneuver Type
public enum ManeuverType: String {
    case straight = "Continue straight"
    case slightLeft = "Bear left"
    case slightRight = "Bear right"
    case left = "Turn left"
    case right = "Turn right"
    case sharpLeft = "Sharp left"
    case sharpRight = "Sharp right"
    case uTurn = "Make a U-turn"
    case arrive = "You have arrived"
    case depart = "Start walking"
    
    var systemImage: String {
        switch self {
        case .straight: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .sharpLeft: return "arrow.turn.down.left"
        case .sharpRight: return "arrow.turn.down.right"
        case .uTurn: return "arrow.uturn.down"
        case .arrive: return "flag.checkered"
        case .depart: return "figure.walk"
        }
    }
    
    var voiceInstruction: String {
        switch self {
        case .straight: return "Continue straight"
        case .slightLeft: return "Bear left"
        case .slightRight: return "Bear right"
        case .left: return "Turn left"
        case .right: return "Turn right"
        case .sharpLeft: return "Sharp left turn"
        case .sharpRight: return "Sharp right turn"
        case .uTurn: return "Make a U-turn"
        case .arrive: return "You have arrived at your destination"
        case .depart: return "Start walking"
        }
    }
}

// MARK: - Route Step
public struct NavigationStep: Identifiable {
    public let id = UUID()
    public let instruction: String
    public let distance: CLLocationDistance
    public let maneuver: ManeuverType
    public let coordinate: CLLocationCoordinate2D
    public var isCompleted: Bool = false
}

// MARK: - Search Result
public struct SearchResult: Identifiable, Hashable {
    public let id = UUID()
    public let mapItem: MKMapItem
    public let name: String
    public let address: String
    public let distance: CLLocationDistance?
    
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: SearchResult, rhs: SearchResult) -> Bool { lhs.id == rhs.id }
}

// MARK: - OSRM Route Response Models
struct OSRMResponse: Codable {
    let code: String
    let routes: [OSRMRoute]?
}

struct OSRMRoute: Codable {
    let geometry: String  // Encoded polyline
    let legs: [OSRMLeg]
    let distance: Double  // meters
    let duration: Double  // seconds
}

struct OSRMLeg: Codable {
    let steps: [OSRMStep]
    let distance: Double
    let duration: Double
}

struct OSRMStep: Codable {
    let geometry: String
    let maneuver: OSRMManeuver
    let distance: Double
    let duration: Double
    let name: String
}

struct OSRMManeuver: Codable {
    let type: String
    let modifier: String?
    let location: [Double]  // [longitude, latitude]
    let instruction: String?
}

// MARK: - Navigation Location Manager
class NavigationLocationManager: NSObject, ObservableObject {
    
    // Location State
    @Published var userLocation: CLLocationCoordinate2D?
    @Published var userHeading: CLLocationDirection = 0
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    // Destination
    @Published var destination: CLLocationCoordinate2D?
    @Published var destinationName: String = ""
    
    // Route
    @Published var routePolyline: MKPolyline?
    @Published var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published var routeSteps: [NavigationStep] = []
    @Published var isRouteCalculated: Bool = false
    @Published var isCalculatingRoute: Bool = false
    @Published var hasRoadRoute: Bool = false
    @Published var routeSource: String = ""  // "OSRM", "Apple", "Compass"
    
    // Current Navigation State
    @Published var currentStepIndex: Int = 0
    @Published var currentInstruction: String = "Set a destination"
    @Published var currentManeuver: ManeuverType = .depart
    @Published var distanceToNextStep: CLLocationDistance = 0
    @Published var distanceRemaining: CLLocationDistance = 0
    @Published var timeRemaining: TimeInterval = 0
    @Published var hasArrived: Bool = false
    
    // For compass-based fallback
    @Published var bearingToDestination: Double = 0
    
    // Search
    @Published var searchResults: [SearchResult] = []
    @Published var isSearching: Bool = false
    
    // Voice
    private let speechSynthesizer = AVSpeechSynthesizer()
    @Published var voiceEnabled: Bool = true
    private var lastVoiceTime: Date = .distantPast
    private var lastSpokenInstruction: String = ""
    
    // Location Manager
    private let locationManager = CLLocationManager()
    private var localSearch: MKLocalSearch?
    
    // Constants
    private let arrivalRadius: Double = 15
    private let stepCompletionRadius: Double = 25
    private let walkingSpeed: Double = 1.4
    
    // OSRM API (free, no key needed)
    private let osrmBaseURL = "https://router.project-osrm.org/route/v1"
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3
        locationManager.headingFilter = 5
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }
    
    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startUpdating() {
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }
    
    // MARK: - Voice Feedback
    func speak(_ text: String, force: Bool = false) {
        guard voiceEnabled else { return }
        
        let now = Date()
        if !force && text == lastSpokenInstruction && now.timeIntervalSince(lastVoiceTime) < 5 {
            return
        }
        
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speechSynthesizer.speak(utterance)
        
        lastVoiceTime = now
        lastSpokenInstruction = text
    }
    
    func speakDirection() {
        guard isRouteCalculated, !hasArrived else { return }
        
        let distStr = formatDistanceForVoice(distanceToNextStep)
        let instruction: String
        
        if distanceToNextStep < 30 {
            instruction = currentManeuver.voiceInstruction
        } else {
            instruction = "In \(distStr), \(currentManeuver.voiceInstruction.lowercased())"
        }
        
        speak(instruction)
    }
    
    private func formatDistanceForVoice(_ distance: CLLocationDistance) -> String {
        if distance < 50 {
            return "\(Int(distance)) meters"
        } else if distance < 1000 {
            let rounded = (Int(distance) / 50) * 50
            return "\(rounded) meters"
        } else {
            return String(format: "%.1f kilometers", distance / 1000)
        }
    }
    
    // MARK: - Search with Nepal Support
    func search(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        localSearch?.cancel()
        isSearching = true
        
        let searchQueries = [query, "\(query), Kathmandu", "\(query), Nepal"]
        var allResults: [SearchResult] = []
        let group = DispatchGroup()
        
        for q in searchQueries {
            group.enter()
            performSingleSearch(query: q) { results in
                allResults.append(contentsOf: results)
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            self?.isSearching = false
            
            var seen = Set<String>()
            var unique: [SearchResult] = []
            for r in allResults {
                let key = "\(r.name)_\(r.mapItem.placemark.coordinate.latitude)"
                if !seen.contains(key) {
                    seen.insert(key)
                    unique.append(r)
                }
            }
            
            unique.sort { ($0.distance ?? 999999) < ($1.distance ?? 999999) }
            self?.searchResults = Array(unique.prefix(15))
        }
    }
    
    private func performSingleSearch(query: String, completion: @escaping ([SearchResult]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        
        let center = userLocation ?? CLLocationCoordinate2D(latitude: 27.7172, longitude: 85.3240)
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50000, longitudinalMeters: 50000)
        
        MKLocalSearch(request: request).start { [weak self] response, _ in
            guard let items = response?.mapItems else {
                completion([])
                return
            }
            
            let results = items.compactMap { item -> SearchResult? in
                guard let name = item.name else { return nil }
                
                var parts: [String] = []
                if let street = item.placemark.thoroughfare { parts.append(street) }
                if let area = item.placemark.subLocality { parts.append(area) }
                if let city = item.placemark.locality { parts.append(city) }
                let address = parts.isEmpty ? "Nepal" : parts.joined(separator: ", ")
                
                var dist: CLLocationDistance?
                if let userLoc = self?.userLocation, let loc = item.placemark.location {
                    dist = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude).distance(from: loc)
                }
                
                return SearchResult(mapItem: item, name: name, address: address, distance: dist)
            }
            completion(results)
        }
    }
    
    func clearSearch() {
        localSearch?.cancel()
        searchResults = []
        isSearching = false
    }
    
    // MARK: - Set Destination
    func setDestination(from result: SearchResult) {
        guard let coord = result.mapItem.placemark.location?.coordinate else { return }
        destination = coord
        destinationName = result.name
        hasArrived = false
        calculateRoute()
    }
    
    // MARK: - Calculate Route (OSRM → Apple → Compass)
    func calculateRoute() {
        guard let start = userLocation, let end = destination else { return }
        
        isCalculatingRoute = true
        hasRoadRoute = false
        routeSource = ""
        
        // Try OSRM first (best for Nepal)
        requestOSRMRoute(from: start, to: end) { [weak self] success in
            if success {
                self?.isCalculatingRoute = false
                return
            }
            
            // Fallback to Apple Maps
            self?.requestAppleRoute(from: start, to: end) { appleSuccess in
                if appleSuccess {
                    self?.isCalculatingRoute = false
                    return
                }
                
                // Final fallback - compass navigation
                DispatchQueue.main.async {
                    self?.createCompassRoute(from: start, to: end)
                    self?.isCalculatingRoute = false
                }
            }
        }
    }
    
    // MARK: - OSRM Routing (OpenStreetMap)
    private func requestOSRMRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, completion: @escaping (Bool) -> Void) {
        
        // OSRM URL format: /route/v1/{profile}/{coordinates}
        // Using "foot" profile for walking
        let urlString = "\(osrmBaseURL)/foot/\(start.longitude),\(start.latitude);\(end.longitude),\(end.latitude)?overview=full&geometries=polyline&steps=true"
        
        guard let url = URL(string: urlString) else {
            completion(false)
            return
        }
        
        print("🗺️ Requesting OSRM route: \(urlString)")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                print("❌ OSRM request failed: \(error?.localizedDescription ?? "Unknown error")")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            do {
                let osrmResponse = try JSONDecoder().decode(OSRMResponse.self, from: data)
                
                guard osrmResponse.code == "Ok", let route = osrmResponse.routes?.first else {
                    print("❌ OSRM no route found")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                // Decode polyline
                let coordinates = self.decodePolyline(route.geometry)
                
                guard coordinates.count >= 2 else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                
                // Parse steps
                var steps: [NavigationStep] = []
                for leg in route.legs {
                    for step in leg.steps {
                        let maneuver = self.parseOSRMManeuver(step.maneuver)
                        let coord = CLLocationCoordinate2D(
                            latitude: step.maneuver.location[1],
                            longitude: step.maneuver.location[0]
                        )
                        
                        let instruction = step.maneuver.instruction ?? self.generateInstruction(maneuver: maneuver, streetName: step.name)
                        
                        steps.append(NavigationStep(
                            instruction: instruction,
                            distance: step.distance,
                            maneuver: maneuver,
                            coordinate: coord
                        ))
                    }
                }
                
                DispatchQueue.main.async {
                    self.processOSRMRoute(coordinates: coordinates, steps: steps, distance: route.distance, duration: route.duration)
                    completion(true)
                }
                
            } catch {
                print("❌ OSRM parse error: \(error)")
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }
    
    private func processOSRMRoute(coordinates: [CLLocationCoordinate2D], steps: [NavigationStep], distance: Double, duration: Double) {
        routeCoordinates = coordinates
        routePolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        routeSteps = steps
        distanceRemaining = distance
        timeRemaining = duration
        hasRoadRoute = true
        routeSource = "OSRM"
        
        currentStepIndex = 0
        if let firstStep = steps.first {
            currentInstruction = firstStep.instruction
            distanceToNextStep = firstStep.distance
            currentManeuver = firstStep.maneuver
        }
        
        isRouteCalculated = true
        
        speak("Route found via OpenStreetMap. \(formatDistanceForVoice(distance)) total. \(currentInstruction)", force: true)
        
        print("✅ OSRM route: \(Int(distance))m, \(steps.count) steps, \(coordinates.count) points")
    }
    
    // MARK: - Decode Google Polyline Format
    private func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat: Int32 = 0
        var lng: Int32 = 0
        
        while index < encoded.endIndex {
            // Decode latitude
            var result: Int32 = 0
            var shift: Int32 = 0
            var byte: Int32
            
            repeat {
                byte = Int32(encoded[index].asciiValue! - 63)
                index = encoded.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            lat += dlat
            
            // Decode longitude
            result = 0
            shift = 0
            
            repeat {
                byte = Int32(encoded[index].asciiValue! - 63)
                index = encoded.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            
            let dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
            lng += dlng
            
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            )
            coordinates.append(coordinate)
        }
        
        return coordinates
    }
    
    private func parseOSRMManeuver(_ maneuver: OSRMManeuver) -> ManeuverType {
        let type = maneuver.type.lowercased()
        let modifier = maneuver.modifier?.lowercased() ?? ""
        
        switch type {
        case "depart": return .depart
        case "arrive": return .arrive
        case "turn":
            switch modifier {
            case "left": return .left
            case "right": return .right
            case "slight left": return .slightLeft
            case "slight right": return .slightRight
            case "sharp left": return .sharpLeft
            case "sharp right": return .sharpRight
            case "uturn": return .uTurn
            default: return .straight
            }
        case "new name", "continue": return .straight
        case "merge": return modifier.contains("left") ? .slightLeft : .slightRight
        case "fork":
            return modifier.contains("left") ? .slightLeft : .slightRight
        case "roundabout", "rotary":
            return modifier.contains("left") ? .left : .right
        default:
            if modifier.contains("left") { return .left }
            if modifier.contains("right") { return .right }
            return .straight
        }
    }
    
    private func generateInstruction(maneuver: ManeuverType, streetName: String) -> String {
        let name = streetName.isEmpty ? "" : " onto \(streetName)"
        return "\(maneuver.rawValue)\(name)"
    }
    
    // MARK: - Apple Maps Fallback
    private func requestAppleRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, completion: @escaping (Bool) -> Void) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .walking
        
        MKDirections(request: request).calculate { [weak self] response, error in
            if let route = response?.routes.first {
                DispatchQueue.main.async {
                    self?.processAppleRoute(route)
                    completion(true)
                }
            } else {
                // Try automobile
                let carRequest = MKDirections.Request()
                carRequest.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
                carRequest.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
                carRequest.transportType = .automobile
                
                MKDirections(request: carRequest).calculate { response, _ in
                    if let route = response?.routes.first {
                        DispatchQueue.main.async {
                            self?.processAppleRoute(route)
                            completion(true)
                        }
                    } else {
                        completion(false)
                    }
                }
            }
        }
    }
    
    private func processAppleRoute(_ route: MKRoute) {
        routePolyline = route.polyline
        distanceRemaining = route.distance
        timeRemaining = route.expectedTravelTime
        
        // Extract coordinates from polyline
        let pointCount = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        routeCoordinates = coords
        
        routeSteps = route.steps.compactMap { step -> NavigationStep? in
            guard !step.instructions.isEmpty else { return nil }
            
            // Get first coordinate of step polyline
            var stepCoord = CLLocationCoordinate2D()
            if step.polyline.pointCount > 0 {
                step.polyline.getCoordinates(&stepCoord, range: NSRange(location: 0, length: 1))
            }
            
            return NavigationStep(
                instruction: step.instructions,
                distance: step.distance,
                maneuver: parseAppleManeuver(step.instructions),
                coordinate: stepCoord
            )
        }
        
        currentStepIndex = 0
        if let firstStep = routeSteps.first {
            currentInstruction = firstStep.instruction
            distanceToNextStep = firstStep.distance
            currentManeuver = firstStep.maneuver
        }
        
        hasRoadRoute = true
        routeSource = "Apple"
        isRouteCalculated = true
        
        speak("Route calculated. \(formatDistanceForVoice(route.distance)) total. \(currentInstruction)", force: true)
        print("✅ Apple route: \(Int(route.distance))m, \(routeSteps.count) steps")
    }
    
    private func parseAppleManeuver(_ instruction: String) -> ManeuverType {
        let lower = instruction.lowercased()
        if lower.contains("arrive") || lower.contains("destination") { return .arrive }
        if lower.contains("u-turn") { return .uTurn }
        if lower.contains("sharp left") { return .sharpLeft }
        if lower.contains("sharp right") { return .sharpRight }
        if lower.contains("slight left") || lower.contains("bear left") || lower.contains("keep left") { return .slightLeft }
        if lower.contains("slight right") || lower.contains("bear right") || lower.contains("keep right") { return .slightRight }
        if lower.contains("turn left") || lower.contains("left on") || lower.contains("left at") { return .left }
        if lower.contains("turn right") || lower.contains("right on") || lower.contains("right at") { return .right }
        return .straight
    }
    
    // MARK: - Compass Route Fallback
    private func createCompassRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) {
        let distance = haversineDistance(from: start, to: end)
        bearingToDestination = calculateBearing(from: start, to: end)
        
        routeCoordinates = [start, end]
        routePolyline = MKPolyline(coordinates: routeCoordinates, count: 2)
        
        distanceRemaining = distance
        distanceToNextStep = distance
        timeRemaining = distance / walkingSpeed
        
        let direction = bearingToCardinal(bearingToDestination)
        currentInstruction = "Head \(direction) towards \(destinationName)"
        currentManeuver = .depart
        
        routeSteps = [
            NavigationStep(instruction: currentInstruction, distance: distance, maneuver: .depart, coordinate: start),
            NavigationStep(instruction: "Arrive at \(destinationName)", distance: 0, maneuver: .arrive, coordinate: end)
        ]
        
        hasRoadRoute = false
        routeSource = "Compass"
        isRouteCalculated = true
        
        speak("No road route available. Head \(direction) for \(formatDistanceForVoice(distance))", force: true)
        print("⚠️ Compass route: \(Int(distance))m, direction: \(direction)")
    }
    
    // MARK: - Update Navigation Progress
    func updateProgress() {
        guard let user = userLocation, let dest = destination, isRouteCalculated else { return }
        
        let userCL = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let destCL = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        let distToDest = userCL.distance(from: destCL)
        
        distanceRemaining = distToDest
        
        // Check arrival
        if distToDest < arrivalRadius {
            if !hasArrived {
                hasArrived = true
                currentInstruction = "You have arrived at \(destinationName)"
                currentManeuver = .arrive
                speak("You have arrived at \(destinationName)", force: true)
            }
            return
        }
        
        // Update based on route type
        if hasRoadRoute && !routeSteps.isEmpty {
            updateRoadRouteProgress(userLocation: userCL)
        } else {
            updateCompassProgress(from: user, to: dest)
        }
    }
    
    private func updateRoadRouteProgress(userLocation userCL: CLLocation) {
        guard currentStepIndex < routeSteps.count else { return }
        
        let currentStep = routeSteps[currentStepIndex]
        let stepCL = CLLocation(latitude: currentStep.coordinate.latitude, longitude: currentStep.coordinate.longitude)
        let distToStep = userCL.distance(from: stepCL)
        
        // Find nearest point on route for accurate distance
        var nearestDistance: Double = Double.greatestFiniteMagnitude
        var nearestIndex = 0
        
        for (index, coord) in routeCoordinates.enumerated() {
            let coordCL = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let dist = userCL.distance(from: coordCL)
            if dist < nearestDistance {
                nearestDistance = dist
                nearestIndex = index
            }
        }
        
        // Calculate remaining distance from nearest point
        var remainingDist: Double = 0
        for i in nearestIndex..<(routeCoordinates.count - 1) {
            let p1 = CLLocation(latitude: routeCoordinates[i].latitude, longitude: routeCoordinates[i].longitude)
            let p2 = CLLocation(latitude: routeCoordinates[i + 1].latitude, longitude: routeCoordinates[i + 1].longitude)
            remainingDist += p1.distance(from: p2)
        }
        distanceRemaining = remainingDist
        
        // Check if reached current step
        if distToStep < stepCompletionRadius && currentStepIndex < routeSteps.count - 1 {
            currentStepIndex += 1
            let nextStep = routeSteps[currentStepIndex]
            currentInstruction = nextStep.instruction
            currentManeuver = nextStep.maneuver
            
            // Calculate distance to next step
            if currentStepIndex + 1 < routeSteps.count {
                let nextNextStep = routeSteps[currentStepIndex + 1]
                let nextCL = CLLocation(latitude: nextNextStep.coordinate.latitude, longitude: nextNextStep.coordinate.longitude)
                distanceToNextStep = userCL.distance(from: nextCL)
            } else {
                distanceToNextStep = distanceRemaining
            }
            
            speak(nextStep.maneuver.voiceInstruction, force: true)
        } else {
            distanceToNextStep = distToStep
        }
        
        // Update ETA
        timeRemaining = distanceRemaining / walkingSpeed
    }
    
    private func updateCompassProgress(from user: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D) {
        bearingToDestination = calculateBearing(from: user, to: dest)
        let direction = bearingToCardinal(bearingToDestination)
        
        let turnAngle = normalizeAngle(bearingToDestination - userHeading)
        currentManeuver = maneuverFromAngle(turnAngle)
        
        let dist = haversineDistance(from: user, to: dest)
        distanceToNextStep = dist
        timeRemaining = dist / walkingSpeed
        
        if abs(turnAngle) > 30 {
            currentInstruction = "\(currentManeuver.rawValue) to head \(direction)"
        } else {
            currentInstruction = "Continue \(direction) - \(formatDistance(dist))"
        }
    }
    
    private func maneuverFromAngle(_ angle: Double) -> ManeuverType {
        let absAngle = abs(angle)
        if absAngle < 15 { return .straight }
        if absAngle < 45 { return angle > 0 ? .slightRight : .slightLeft }
        if absAngle < 90 { return angle > 0 ? .right : .left }
        if absAngle < 135 { return angle > 0 ? .sharpRight : .sharpLeft }
        return .uTurn
    }
    
    // MARK: - Helper Functions
    private func haversineDistance(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDistance {
        let R: Double = 6371000
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLat = (end.latitude - start.latitude) * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) + cos(lat1) * cos(lat2) * sin(dLon/2) * sin(dLon/2)
        return R * 2 * atan2(sqrt(a), sqrt(1-a))
    }
    
    private func calculateBearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    
    private func normalizeAngle(_ angle: Double) -> Double {
        var n = angle
        while n > 180 { n -= 360 }
        while n < -180 { n += 360 }
        return n
    }
    
    private func bearingToCardinal(_ bearing: Double) -> String {
        switch bearing {
        case 0..<22.5, 337.5...360: return "North"
        case 22.5..<67.5: return "Northeast"
        case 67.5..<112.5: return "East"
        case 112.5..<157.5: return "Southeast"
        case 157.5..<202.5: return "South"
        case 202.5..<247.5: return "Southwest"
        case 247.5..<292.5: return "West"
        default: return "Northwest"
        }
    }
    
    func clearRoute() {
        destination = nil
        destinationName = ""
        routePolyline = nil
        routeCoordinates = []
        routeSteps = []
        currentStepIndex = 0
        isRouteCalculated = false
        hasRoadRoute = false
        routeSource = ""
        currentInstruction = "Set a destination"
        currentManeuver = .depart
        distanceToNextStep = 0
        distanceRemaining = 0
        timeRemaining = 0
        hasArrived = false
        bearingToDestination = 0
    }
    
    // MARK: - Formatting
    func formatDistance(_ dist: CLLocationDistance) -> String {
        if dist < 1000 { return "\(Int(dist)) m" }
        return String(format: "%.1f km", dist / 1000)
    }
    
    var formattedDistance: String { formatDistance(distanceRemaining) }
    
    var formattedTime: String {
        let mins = Int(timeRemaining / 60)
        if mins < 60 { return "\(max(1, mins)) min" }
        return "\(mins / 60) hr \(mins % 60) min"
    }
    
    var formattedNextStep: String { formatDistance(distanceToNextStep) }
    
    var routeSourceDisplay: String {
        switch routeSource {
        case "OSRM": return "OpenStreetMap"
        case "Apple": return "Apple Maps"
        case "Compass": return "Compass"
        default: return "Unknown"
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension NavigationLocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                self.startUpdating()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.userLocation = loc.coordinate
            if self.isRouteCalculated { self.updateProgress() }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.userHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}
