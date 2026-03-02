//
//  CustomRouteEngine.swift
//  VisionNav

import Foundation
import MapKit
import CoreLocation

// MARK: - RoadNode

class RoadNode: Hashable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    var neighbors: [(node: RoadNode, distance: Double, roadName: String, weight: Double)] = []
    var gCost: Double = .infinity
    var hCost: Double = 0
    var fCost: Double { gCost + hCost }
    var parent: RoadNode?
    var roadNameFromParent: String = ""

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        self.id = "\(String(format: "%.6f", coordinate.latitude)),\(String(format: "%.6f", coordinate.longitude))"
    }

    func reset() { gCost = .infinity; hCost = 0; parent = nil; roadNameFromParent = "" }
    static func == (l: RoadNode, r: RoadNode) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Result Types

struct CustomRouteResult {
    let coordinates:        [CLLocationCoordinate2D]
    let totalDistance:      Double
    let steps:              [CustomRouteStep]
    let success:            Bool
    let smoothedCoordinates: [CLLocationCoordinate2D]
}

struct CustomRouteStep {
    let instruction:   String
    let distance:      Double
    let coordinate:    CLLocationCoordinate2D
    let maneuverType:  String
}

struct RouteDeviationResult {
    let isOffRoute:             Bool
    let deviationDistance:      Double
    let isWrongDirection:       Bool
    let nearestRoutePointIndex: Int
    let shouldReroute:          Bool
    let headingDifference:      Double
}

// MARK: - CustomRouteEngine

class CustomRouteEngine {

    private var nodes:           [String: RoadNode]    = [:]
    private var isGraphBuilt     = false
    private let gridSize:        Double                = 0.0008
    private var spatialIndex:    [String: [RoadNode]]  = [:]

    private let offRouteThreshold:   Double = 40.0
    private let rerouteThreshold:    Double = 80.0
    private let wrongDirectionAngle: Double = 120.0
    private let wrongDirectionDuration: Int = 3
    private var wrongDirectionCounter:  Int = 0

    // MARK: - Build Road Network

    func buildRoadNetwork(around center: CLLocationCoordinate2D, radius: Double, completion: @escaping (Bool) -> Void) {
        nodes.removeAll(); spatialIndex.removeAll(); isGraphBuilt = false
        let terms = ["road","street","path","lane","highway","marg","marga","sadak","galli","chowk","tole"]
        let g = DispatchGroup(); var allItems: [MKMapItem] = []
        for term in terms {
            g.enter()
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = term
            req.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
            MKLocalSearch(request: req).start { resp, _ in
                if let items = resp?.mapItems { allItems.append(contentsOf: items) }; g.leave()
            }
        }
        g.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for item in allItems {
                guard let loc = item.placemark.location?.coordinate else { continue }
                let name = item.placemark.thoroughfare ?? item.name ?? "Road"
                let node = self.getOrCreateNode(at: loc)
                self.connectToNearby(node, maxDist: 250, roadName: name)
            }
            if self.nodes.count < 30 { self.buildGrid(center: center, radius: radius) }
            self.isGraphBuilt = self.nodes.count > 0
            completion(self.isGraphBuilt)
        }
    }

    private func buildGrid(center: CLLocationCoordinate2D, radius: Double) {
        let latD = radius / 111000.0
        let lonD = radius / (111000.0 * cos(center.latitude * .pi / 180))
        let step = 0.00025
        var lat = center.latitude - latD
        while lat <= center.latitude + latD {
            var lon = center.longitude - lonD
            while lon <= center.longitude + lonD {
                let c    = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let node = getOrCreateNode(at: c)
                let offs: [(Double, Double)] = [(step,0),(-step,0),(0,step),(0,-step),(step,step),(step,-step),(-step,step),(-step,-step)]
                for (dLat, dLon) in offs {
                    let nc = CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon)
                    let nn = getOrCreateNode(at: nc)
                    let d  = haversine(from: c, to: nc)
                    let w  = (dLat != 0 && dLon != 0) ? d * 1.1 : d
                    if !node.neighbors.contains(where: { $0.node.id == nn.id }) {
                        node.neighbors.append((nn, d, "Road", w))
                        nn.neighbors.append((node, d, "Road", w))
                    }
                }
                lon += step
            }
            lat += step
        }
    }

    private func getOrCreateNode(at c: CLLocationCoordinate2D) -> RoadNode {
        let sLat = (c.latitude  / gridSize).rounded() * gridSize
        let sLon = (c.longitude / gridSize).rounded() * gridSize
        let key  = "\(String(format: "%.6f", sLat)),\(String(format: "%.6f", sLon))"
        if let e = nodes[key] { return e }
        let node = RoadNode(coordinate: CLLocationCoordinate2D(latitude: sLat, longitude: sLon))
        nodes[key] = node
        let gk = "\(Int(sLat / gridSize)),\(Int(sLon / gridSize))"
        spatialIndex[gk, default: []].append(node)
        return node
    }

    private func connectToNearby(_ node: RoadNode, maxDist: Double, roadName: String = "Road") {
        let gLat = Int(node.coordinate.latitude  / gridSize)
        let gLon = Int(node.coordinate.longitude / gridSize)
        for dLat in -3...3 { for dLon in -3...3 {
            guard let cells = spatialIndex["\(gLat + dLat),\(gLon + dLon)"] else { continue }
            for other in cells where other.id != node.id {
                let d = haversine(from: node.coordinate, to: other.coordinate)
                if d <= maxDist && !node.neighbors.contains(where: { $0.node.id == other.id }) {
                    node.neighbors.append((other, d, roadName, d))
                    other.neighbors.append((node, d, roadName, d))
                }
            }
        }}
    }

    // MARK: - A* Pathfinding

    func findRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CustomRouteResult {
        let empty = CustomRouteResult(coordinates: [], totalDistance: 0, steps: [], success: false, smoothedCoordinates: [])
        for n in nodes.values { n.reset() }
        guard let sn = findNearest(to: start), let en = findNearest(to: end) else { return empty }

        var open: Set<RoadNode> = [sn]; var closed: Set<RoadNode> = []
        sn.gCost = 0; sn.hCost = haversine(from: sn.coordinate, to: en.coordinate)
        let maxIter = nodes.count * 3; var iter = 0

        while !open.isEmpty && iter < maxIter {
            iter += 1
            let cur = open.min(by: { $0.fCost < $1.fCost })!
            if cur.id == en.id { return reconstructPath(endNode: cur) }
            open.remove(cur); closed.insert(cur)
            for (nb, _, roadName, weight) in cur.neighbors {
                if closed.contains(nb) { continue }
                let tg = cur.gCost + weight
                if tg < nb.gCost {
                    nb.parent = cur; nb.roadNameFromParent = roadName
                    nb.gCost = tg; nb.hCost = haversine(from: nb.coordinate, to: en.coordinate)
                    if !open.contains(nb) { open.insert(nb) }
                }
            }
        }
        return CustomRouteResult(coordinates: [start, end], totalDistance: haversine(from: start, to: end),
                                  steps: [], success: false, smoothedCoordinates: [start, end])
    }

    private func findNearest(to c: CLLocationCoordinate2D) -> RoadNode? {
        var best: RoadNode?; var bestD: Double = .infinity
        let gLat = Int(c.latitude / gridSize); let gLon = Int(c.longitude / gridSize)
        for dLat in -5...5 { for dLon in -5...5 {
            guard let cells = spatialIndex["\(gLat + dLat),\(gLon + dLon)"] else { continue }
            for n in cells { let d = haversine(from: c, to: n.coordinate); if d < bestD { bestD = d; best = n } }
        }}
        if best == nil || bestD > 200 {
            for n in nodes.values { let d = haversine(from: c, to: n.coordinate); if d < bestD { bestD = d; best = n } }
        }
        if bestD > 150 { let nn = getOrCreateNode(at: c); connectToNearby(nn, maxDist: 300); return nn }
        return best
    }

    private func reconstructPath(endNode: RoadNode) -> CustomRouteResult {
        var coords: [CLLocationCoordinate2D] = []; var steps: [CustomRouteStep] = []
        var totalDist: Double = 0; var cur: RoadNode? = endNode; var pathNodes: [RoadNode] = []
        while let n = cur { pathNodes.insert(n, at: 0); cur = n.parent }

        var lastDir: Double?; var accDist: Double = 0; var lastRoad = ""
        for i in 0..<pathNodes.count {
            let n = pathNodes[i]; coords.append(n.coordinate)
            if i > 0 {
                let prev = pathNodes[i - 1]
                let seg  = haversine(from: prev.coordinate, to: n.coordinate)
                totalDist += seg; accDist += seg
                let bearing = calcBearing(from: prev.coordinate, to: n.coordinate)
                if let ld = lastDir {
                    let ta = normAngle(bearing - ld)
                    let mt = mType(ta)
                    if abs(ta) > 25 || n.roadNameFromParent != lastRoad {
                        steps.append(CustomRouteStep(instruction: mInstr(mt, n.roadNameFromParent, accDist),
                                                      distance: accDist, coordinate: n.coordinate, maneuverType: mt))
                        accDist = 0
                    }
                }
                lastDir = bearing; lastRoad = n.roadNameFromParent
            }
        }
        if let lc = coords.last {
            steps.append(CustomRouteStep(instruction: "Arrive at destination", distance: 0, coordinate: lc, maneuverType: "arrive"))
        }
        return CustomRouteResult(coordinates: coords, totalDistance: totalDist, steps: steps,
                                  success: true, smoothedCoordinates: catmullRom(coords, pps: 5))
    }

    // MARK: - Deviation Detection

    func checkRouteDeviation(userLocation: CLLocationCoordinate2D, userHeading: Double,
                               routeCoordinates: [CLLocationCoordinate2D]) -> RouteDeviationResult {
        guard routeCoordinates.count >= 2 else {
            return RouteDeviationResult(isOffRoute: false, deviationDistance: 0, isWrongDirection: false,
                                         nearestRoutePointIndex: 0, shouldReroute: false, headingDifference: 0)
        }
        var minD: Double = .infinity; var nearIdx = 0
        for i in 0..<routeCoordinates.count {
            let d = haversine(from: userLocation, to: routeCoordinates[i])
            if d < minD { minD = d; nearIdx = i }
        }
        for i in 0..<(routeCoordinates.count - 1) {
            let sd = ptSegDist(pt: userLocation, a: routeCoordinates[i], b: routeCoordinates[i + 1])
            if sd < minD { minD = sd; nearIdx = i }
        }
        let nextIdx  = min(nearIdx + 1, routeCoordinates.count - 1)
        let routeB   = calcBearing(from: routeCoordinates[nearIdx], to: routeCoordinates[nextIdx])
        let hDiff    = abs(normAngle(userHeading - routeB))
        let wrongDir = hDiff > wrongDirectionAngle
        if wrongDir { wrongDirectionCounter += 1 } else { wrongDirectionCounter = max(0, wrongDirectionCounter - 1) }
        let shouldReroute = minD > rerouteThreshold || wrongDirectionCounter >= wrongDirectionDuration
        if shouldReroute { wrongDirectionCounter = 0 }
        return RouteDeviationResult(isOffRoute: minD > offRouteThreshold, deviationDistance: minD,
                                     isWrongDirection: wrongDir && wrongDirectionCounter >= 2,
                                     nearestRoutePointIndex: nearIdx, shouldReroute: shouldReroute, headingDifference: hDiff)
    }

    func resetDeviationTracking() { wrongDirectionCounter = 0 }

    // MARK: - Geometry

    func haversine(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0
        let la = a.latitude * .pi / 180; let lb = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180; let dLon = (b.longitude - a.longitude) * .pi / 180
        let x = sin(dLat/2)*sin(dLat/2) + cos(la)*cos(lb)*sin(dLon/2)*sin(dLon/2)
        return R * 2 * atan2(sqrt(x), sqrt(1 - x))
    }

    func calcBearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let la = a.latitude * .pi / 180; let lb = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        return atan2(sin(dl)*cos(lb), cos(la)*sin(lb) - sin(la)*cos(lb)*cos(dl)) * 180 / .pi
    }

    private func normAngle(_ a: Double) -> Double { var n = a; while n > 180 { n -= 360 }; while n < -180 { n += 360 }; return n }

    private func ptSegDist(pt: CLLocationCoordinate2D, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Double {
        let dx = b.longitude - a.longitude; let dy = b.latitude - a.latitude
        if dx == 0 && dy == 0 { return haversine(from: pt, to: a) }
        var t = ((pt.longitude - a.longitude)*dx + (pt.latitude - a.latitude)*dy) / (dx*dx + dy*dy)
        t = max(0, min(1, t))
        return haversine(from: pt, to: CLLocationCoordinate2D(latitude: a.latitude + t*dy, longitude: a.longitude + t*dx))
    }

    private func catmullRom(_ pts: [CLLocationCoordinate2D], pps: Int) -> [CLLocationCoordinate2D] {
        guard pts.count >= 3 else { return pts }
        var out: [CLLocationCoordinate2D] = []
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i-1] : pts[i]; let p1 = pts[i]
            let p2 = pts[i+1]; let p3 = i+2 < pts.count ? pts[i+2] : pts[i+1]
            for j in 0..<pps {
                let t = Double(j)/Double(pps); let t2 = t*t; let t3 = t2*t
                let lat = 0.5*((2*p1.latitude)+(-p0.latitude+p2.latitude)*t+(2*p0.latitude-5*p1.latitude+4*p2.latitude-p3.latitude)*t2+(-p0.latitude+3*p1.latitude-3*p2.latitude+p3.latitude)*t3)
                let lon = 0.5*((2*p1.longitude)+(-p0.longitude+p2.longitude)*t+(2*p0.longitude-5*p1.longitude+4*p2.longitude-p3.longitude)*t2+(-p0.longitude+3*p1.longitude-3*p2.longitude+p3.longitude)*t3)
                out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        if let l = pts.last { out.append(l) }
        return out
    }

    private func mType(_ ta: Double) -> String {
        let a = abs(ta)
        if a < 15  { return "straight" }
        if a < 45  { return ta > 0 ? "slight_right" : "slight_left" }
        if a < 100 { return ta > 0 ? "right"        : "left"        }
        if a < 150 { return ta > 0 ? "sharp_right"  : "sharp_left"  }
        return "uturn"
    }

    private func mInstr(_ m: String, _ road: String, _ dist: Double) -> String {
        let ds = dist < 1000 ? "\(Int(dist))m" : String(format: "%.1fkm", dist/1000)
        let r  = road.isEmpty ? "" : " onto \(road)"
        switch m {
        case "straight":    return "Continue straight\(r) for \(ds)"
        case "slight_left": return "Bear left\(r)"
        case "slight_right":return "Bear right\(r)"
        case "left":        return "Turn left\(r)"
        case "right":       return "Turn right\(r)"
        case "sharp_left":  return "Sharp left\(r)"
        case "sharp_right": return "Sharp right\(r)"
        case "uturn":       return "Make a U-turn"
        default:            return "Continue\(r)"
        }
    }
}
