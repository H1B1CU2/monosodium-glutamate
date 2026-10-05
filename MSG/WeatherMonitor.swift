import AppKit
import CoreLocation
import Foundation

// MARK: - Weather Model

struct WeatherData: Codable, Equatable {
    let temperature: Double       // Celsius
    let conditionText: String     // e.g. "Light Rain", "Partly Cloudy"
    let symbolName: String        // SF Symbol name e.g. "cloud.sun.rain.fill"
    let cityName: String          // e.g. "Chiang Mai"
    let humidity: Int             // e.g. 94 (%)
    let tempMax: Double?          // e.g. 28.0
    let tempMin: Double?          // e.g. 23.0
    let isDay: Bool
    let updatedAt: Date
}

final class WeatherMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherMonitor()

    private(set) var currentWeather: WeatherData? {
        didSet {
            guard oldValue != currentWeather else { return }
            saveCache()
            notifyObservers()
        }
    }

    private var observers: [() -> Void] = []
    private var refreshTimer: Timer?
    private var isFetching = false
    private let userDefaultsKey = "MSG_CachedWeatherData"

    private override init() {
        super.init()
        loadCache()
    }

    // MARK: - Where

    /// The Mac's own position (Location Services, which MSG already has for
    /// Wi-Fi names) rather than the network's: behind a VPN the IP lookup put
    /// the weather in another city.
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return manager
    }()
    private var refetchWhenDone = false
    private var locationWaiters: [(CLLocation?) -> Void] = []
    private var locationTimeout: DispatchWorkItem?

    /// Nil when Location Services is off, denied, or slow to answer.
    private func deviceLocation(completion: @escaping (CLLocation?) -> Void) {
        DispatchQueue.main.async { [self] in
            let status = locationManager.authorizationStatus
            guard CLLocationManager.locationServicesEnabled() else {
                completion(nil)
                return
            }
            // Never asked yet: ask, and carry on with what's known meanwhile.
            if status == .notDetermined { locationManager.requestWhenInUseAuthorization() }
            // Recent enough already: weather doesn't need a fresh fix.
            if let last = locationManager.location, last.timestamp.timeIntervalSinceNow > -24 * 3600 {
                completion(last)
                return
            }
            guard status == .authorizedAlways || status == .authorized else {
                completion(nil)
                return
            }
            locationWaiters.append(completion)
            guard locationWaiters.count == 1 else { return }
            locationManager.requestLocation()
            let timeout = DispatchWorkItem { [weak self] in self?.answerLocation(nil) }
            locationTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        }
    }

    private func answerLocation(_ location: CLLocation?) {
        locationTimeout?.cancel()
        locationTimeout = nil
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0(location) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        answerLocation(locations.last)
    }

    /// Location just allowed: the weather for where the Mac really is.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorized else { return }
        // The answer arrives a moment after launch, usually mid-fetch (which
        // fell back to the network's guess): fetch again once that one is done.
        if isFetching { refetchWhenDone = true } else { refresh() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        answerLocation(manager.location)
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()

        // Periodic refresh every 15 minutes
        let timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // Refresh on system wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
        if currentWeather != nil {
            observer()
        }
    }

    private func notifyObservers() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for obs in self.observers { obs() }
        }
    }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true

        // First attempt: IP location -> Open-Meteo
        fetchLocationAndOpenMeteo { [weak self] weather in
            if let weather {
                self?.finish(weather)
            } else {
                // Fallback to wttr.in
                self?.fetchWttr { fallbackWeather in
                    self?.finish(fallbackWeather)
                }
            }
        }
    }

    private func finish(_ weather: WeatherData?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFetching = false
            if let weather {
                self.currentWeather = weather
            }
            if self.refetchWhenDone {
                self.refetchWhenDone = false
                self.refresh()
            }
        }
    }

    private func saveCache() {
        guard let currentWeather, let data = try? JSONEncoder().encode(currentWeather) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let cached = try? JSONDecoder().decode(WeatherData.self, from: data) else { return }
        currentWeather = cached
    }

    func openWeatherApp() {
        if let url = URL(string: "weather://"), NSWorkspace.shared.open(url) {
            return
        }
        let appUrl = URL(fileURLWithPath: "/System/Applications/Weather.app")
        NSWorkspace.shared.openApplication(at: appUrl, configuration: .init(), completionHandler: nil)
    }

    // MARK: - Open-Meteo & IP Geolocation

    private struct IPLocation: Decodable {
        let status: String?
        let city: String?
        let regionName: String?
        let lat: Double?
        let lon: Double?
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let relative_humidity_2m: Double
            let apparent_temperature: Double?
            let is_day: Int
            let weather_code: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily?
    }

    private func fetchLocationAndOpenMeteo(completion: @escaping (WeatherData?) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)

        deviceLocation { [weak self] location in
            guard let self else { return }
            if let location {
                // The place name for where the Mac actually is.
                CLGeocoder().reverseGeocodeLocation(location) { places, _ in
                    let place = places?.first
                    let city = Self.shortName(place?.locality ?? place?.subAdministrativeArea
                                              ?? place?.administrativeArea ?? "Local")
                    self.fetchOpenMeteo(session: session, lat: location.coordinate.latitude,
                                        lon: location.coordinate.longitude, city: city, completion: completion)
                }
                return
            }
            // No Location Services: the network's guess.
            guard let ipUrl = URL(string: "http://ip-api.com/json") else {
                completion(nil)
                return
            }
            session.dataTask(with: ipUrl) { data, _, _ in
                guard let data,
                      let loc = try? JSONDecoder().decode(IPLocation.self, from: data),
                      loc.status == "success",
                      let lat = loc.lat, let lon = loc.lon else {
                    completion(nil)
                    return
                }
                self.fetchOpenMeteo(session: session, lat: lat, lon: lon,
                                    city: loc.city ?? loc.regionName ?? "Local", completion: completion)
            }.resume()
        }
    }

    /// "Mueang Chiang Mai District" → "Chiang Mai": Thai district names as the
    /// geocoder writes them, down to the place itself.
    private static func shortName(_ name: String) -> String {
        var short = name
        for prefix in ["Amphoe Mueang ", "Mueang ", "Amphoe ", "Khet "] where short.hasPrefix(prefix) {
            short.removeFirst(prefix.count)
            break
        }
        if short.hasSuffix(" District") { short.removeLast(" District".count) }
        return short.isEmpty ? name : short
    }

    private func fetchOpenMeteo(session: URLSession, lat: Double, lon: Double, city: String,
                                completion: @escaping (WeatherData?) -> Void) {
        do {
            let meteoUrlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto"
            guard let meteoUrl = URL(string: meteoUrlStr) else {
                completion(nil)
                return
            }

            session.dataTask(with: meteoUrl) { mData, _, _ in
                guard let mData,
                      let resp = try? JSONDecoder().decode(OpenMeteoResponse.self, from: mData) else {
                    completion(nil)
                    return
                }

                let isDay = resp.current.is_day != 0
                let (sym, text) = Self.parseWMOCode(resp.current.weather_code, isDay: isDay)
                let weather = WeatherData(
                    temperature: resp.current.temperature_2m,
                    conditionText: text,
                    symbolName: sym,
                    cityName: city,
                    humidity: Int(resp.current.relative_humidity_2m.rounded()),
                    tempMax: resp.daily?.temperature_2m_max.first,
                    tempMin: resp.daily?.temperature_2m_min.first,
                    isDay: isDay,
                    updatedAt: Date()
                )
                completion(weather)
            }.resume()
        }
    }

    // MARK: - Wttr.in Fallback

    private struct WttrResponse: Decodable {
        struct NearestArea: Decodable {
            struct Value: Decodable { let value: String }
            let areaName: [Value]?
        }
        struct Condition: Decodable {
            struct Value: Decodable { let value: String }
            let temp_C: String?
            let humidity: String?
            let weatherCode: String?
            let weatherDesc: [Value]?
        }
        struct Weather: Decodable {
            let maxtempC: String?
            let mintempC: String?
        }
        let nearest_area: [NearestArea]?
        let current_condition: [Condition]?
        let weather: [Weather]?
    }

    private func fetchWttr(completion: @escaping (WeatherData?) -> Void) {
        guard let url = URL(string: "https://wttr.in/?format=j1") else {
            completion(nil)
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 6
        var req = URLRequest(url: url)
        req.setValue("curl/7.68.0", forHTTPHeaderField: "User-Agent")

        URLSession(configuration: config).dataTask(with: req) { data, _, _ in
            guard let data, let resp = try? JSONDecoder().decode(WttrResponse.self, from: data) else {
                completion(nil)
                return
            }
            let city = resp.nearest_area?.first?.areaName?.first?.value ?? "Local"
            guard let cond = resp.current_condition?.first,
                  let tempCStr = cond.temp_C, let tempC = Double(tempCStr),
                  let humStr = cond.humidity, let hum = Int(humStr),
                  let codeStr = cond.weatherCode, let code = Int(codeStr) else {
                completion(nil)
                return
            }

            let desc = cond.weatherDesc?.first?.value ?? "Clear"
            let hour = Calendar.current.component(.hour, from: Date())
            let isDay = hour >= 6 && hour < 19
            let (sym, text) = Self.parseWttrCode(code, defaultText: desc, isDay: isDay)
            let maxT = resp.weather?.first?.maxtempC.flatMap(Double.init)
            let minT = resp.weather?.first?.mintempC.flatMap(Double.init)

            let weather = WeatherData(
                temperature: tempC,
                conditionText: text,
                symbolName: sym,
                cityName: city,
                humidity: hum,
                tempMax: maxT,
                tempMin: minT,
                isDay: isDay,
                updatedAt: Date()
            )
            completion(weather)
        }.resume()
    }

    // MARK: - Code Parsers

    // Only symbols with a multicolor look: the others (sun.min.fill, snowflake)
    // draw black, unseen on the strip's black.
    static func parseWMOCode(_ code: Int, isDay: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", isDay ? "Clear" : "Clear Night")
        case 1:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", "Mainly Clear")
        case 2:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly Cloudy")
        case 3:
            return ("cloud.fill", "Overcast")
        case 45, 48:
            return ("cloud.fog.fill", "Fog")
        case 51, 53, 55:
            return ("cloud.drizzle.fill", "Drizzle")
        case 56, 57:
            return ("cloud.sleet.fill", "Freezing Drizzle")
        case 61:
            return ("cloud.rain.fill", "Light Rain")
        case 63:
            return ("cloud.rain.fill", "Rain")
        case 65:
            return ("cloud.heavyrain.fill", "Heavy Rain")
        case 66, 67:
            return ("cloud.sleet.fill", "Freezing Rain")
        case 71, 73, 75, 77:
            return ("cloud.snow.fill", "Snow")
        case 80:
            return (isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Light Showers")
        case 81:
            return (isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Rain Showers")
        case 82:
            return ("cloud.heavyrain.fill", "Heavy Showers")
        case 85, 86:
            return ("cloud.snow.fill", "Snow Showers")
        case 95:
            return ("cloud.bolt.rain.fill", "Thunderstorm")
        case 96, 99:
            return ("cloud.bolt.rain.fill", "Thunderstorm with Hail")
        default:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
        }
    }

    static func parseWttrCode(_ code: Int, defaultText: String, isDay: Bool) -> (symbol: String, text: String) {
        switch code {
        case 113:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", isDay ? "Clear" : "Clear Night")
        case 116:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly Cloudy")
        case 119, 122:
            return ("cloud.fill", "Overcast")
        case 143, 248, 260:
            return ("cloud.fog.fill", "Fog")
        case 176, 263, 266, 293, 296, 353:
            return (isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Light Rain")
        case 302, 308, 356, 359:
            return ("cloud.heavyrain.fill", "Heavy Rain")
        case 200, 386, 389, 392, 395:
            return ("cloud.bolt.rain.fill", "Thunderstorm")
        case 227, 230, 323, 326, 329, 332, 335, 338, 368, 371:
            return ("cloud.snow.fill", "Snow")
        case 179, 182, 185, 281, 284, 311, 314, 317, 350, 362, 365, 374, 377:
            return ("cloud.sleet.fill", "Sleet")
        default:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", defaultText)
        }
    }
}
