//
//  Segment.swift
//
//  Created by Adriano Paladini on 20/03/20.
//  Copyright © 2020 Adriano Paladini. All rights reserved.
//

import UIKit
import CoreTelephony
import AdSupport
import Network

public class Segment {
    static public let shared =  Segment()

    public var flushAt = 20
    public var flushInterval = 5
//    public var handleAppStateNotification = true

    private let monitor = NWPathMonitor()
    private let segmentAnonymousId = UUID().uuidString
    private var timer: Timer? = nil
    private var token: String  = ""
    private var isOnWifi = false
    private var isOnCellular = false
    private var segmentType = ""
    private var segmentName: String?
    private var segmentEvent: String?
    private var segmentProperties: [String:Any]?
    private var jobs: [[String:Any]] = [] {
        didSet {
            if self.jobs.count >= flushAt {
                performFlush()
            }
        }
    }

    public func setup(key: String) {
        self.token = key

        monitor.pathUpdateHandler = { path in
            self.isOnWifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            self.isOnCellular = path.status == .satisfied && path.usesInterfaceType(.cellular)
        }
        monitor.start(queue: DispatchQueue(label: "NWPathMonitor"))

        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(flushInterval), repeats: true) { timer in
            self.performFlush()
        }

        let notifications = [UIApplication.didEnterBackgroundNotification,
                             UIApplication.didFinishLaunchingNotification,
                             UIApplication.willEnterForegroundNotification,
                             UIApplication.willTerminateNotification,
                             UIApplication.willResignActiveNotification,
                             UIApplication.didBecomeActiveNotification]

//        notifications.forEach { name in
//            NotificationCenter.default.addObserver(self, selector: #selector(handleAppStateNotification), name: name, object: nil)
//        }
    }

    @objc func handleAppStateNotification() {
        
    }

    deinit {
        monitor.cancel()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func deviceModel() -> String {
        if let simulatorModelIdentifier = ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorModelIdentifier
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let deviceModel = String(bytes: Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN)), encoding: .ascii)?.trimmingCharacters(in: .controlCharacters)
        return deviceModel ?? "-"
    }

    private func deviceIP() -> String {
        let none =  "0.0.0.0"
        guard let url = URL(string: "https://api.ipify.org") else { return none }
        do { return try String(contentsOf: url) } catch {}
        return none
    }

    private var now: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private func urlRequest(for messagesData: Data) -> URLRequest? {
        guard
            let data = token.data(using: .utf8),
            let url = URL(string: "https://api.segment.io/v1/import")
        else { return nil }
        var urlRequest = URLRequest(url: url)
        let auth = "Basic \(data.base64EncodedString())"
        urlRequest.httpMethod = "post"
        urlRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(auth, forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = messagesData
        return urlRequest
    }

    private func getData() -> Data? {
        let batch: [String:Any] = [
            "batch": jobs,
            "context": createContext()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: batch, options: []) else { return nil }
        return data
    }

    private func contextLibrary() -> [String:Any] {
        return [
            "name": "analytics-ios",
            "version": "3.7.1"
        ]
    }

    private func contextApp() -> [String:Any] {
        return [
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "-",
            "name": Bundle.main.infoDictionary?["CFBundleName"] ?? "-",
            "namespace": Bundle.main.bundleIdentifier ?? "-",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "-"
        ]
    }

    private func contextScreen() -> [String:Any] {
        return [
            "height": UIScreen.main.bounds.height,
            "width": UIScreen.main.bounds.width
        ]
    }

    private func contextNetwork() -> [String:Any] {
        let carrierName = CTTelephonyNetworkInfo().subscriberCellularProvider?.carrierName ?? "-"
        return [
            "carrier": carrierName,
            "cellular": isOnCellular,
            "wifi": isOnWifi
        ]
    }

    private func contextOS() -> [String:Any] {
        return [
          "name": "iOS",
          "version": UIDevice.current.systemVersion
        ]
    }

    private func contextDevice() -> [String:Any] {
        let adTrackingEnabled = ASIdentifierManager().isAdvertisingTrackingEnabled
        let advertisingId = ASIdentifierManager().advertisingIdentifier.uuidString
        let deviceId = UIDevice().identifierForVendor?.uuidString ?? "-"
        return [
            "adTrackingEnabled": adTrackingEnabled,
            "advertisingId": advertisingId,
            "id": deviceId,
            "manufacturer": "Apple",
            "model": deviceModel(),
            "type": "ios",
            "name": UIDevice().model
        ]
    }

    private func contextLocale() -> String {
        return "\(Locale.current.languageCode ?? "")-\(Locale.current.regionCode ?? "")"
    }

    private func contextTimezone() -> String {
        return TimeZone.current.identifier
    }

    private func createContext() -> [String:Any] {
        return [
            "library": contextLibrary(),
            "app": contextApp(),
            "screen": contextScreen(),
            "network": contextNetwork(),
            "os": contextOS(),
            "device": contextDevice(),
            "ip": deviceIP(),
            "locale": contextLocale(),
            "timezone": contextTimezone(),
            "traits": []
        ]
    }

    private func createBatch() -> [String:Any] {
        var batch: [String:Any] = [
            "userId": "_",
            "messageId": UUID().uuidString,
            "anonymousId": segmentAnonymousId,
            "type": segmentType,
            "timestamp": now,
            "sentAt": now,
            "integrations": []
        ]
        if segmentName != nil {
            batch["name"] = segmentName
        }
        if segmentEvent != nil {
            batch["event"] = segmentEvent
        }
        if segmentProperties != nil {
            batch["properties"] = segmentProperties
        }
        return batch
    }

    public func identify(_ user: String?, traits: [String:Any]?) {
        guard user != nil || traits != nil else { return }
        var batch: [String:Any] = [
            "type": "identify",
            "anonymousId": segmentAnonymousId
        ]
        if user != nil {
            batch["userId"] = user
        }
        if traits != nil {
            batch["traits"] = traits
        }
        jobs.append(batch)
    }

    public func screen(_ name: String) {
        segmentType = "screen"
        segmentName = name
        segmentEvent = nil
        segmentProperties = nil
        jobs.append(createBatch())
    }

    public func track(_ event: String, with properties: [String:Any]?) {
        segmentType = "track"
        segmentName = nil
        segmentEvent = event
        segmentProperties = properties
        jobs.append(createBatch())
    }

    private func performFlush() {
        guard
            jobs.count > 0,
            let data = getData(),
            let request = urlRequest(for: data)
        else { return }

        URLSession.shared.dataTask(with: request){(data, res, err) in
            if err == nil {
                self.jobs.removeAll(keepingCapacity: true)
            }
        }.resume()
    }
}
