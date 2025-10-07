import SwiftUI
import MapKit
import Combine
import CoreML
import Charts
import Foundation
import GoogleGenerativeAI
import ParallaxSwiftUI

// MARK: - Generative AI Setup
let GEMINI_API_KEY = "AIzaSyBlByVQ2vYjD0OpHYBLmYdOZ9rgHRBowfM" // Replace with your actual key
// IMPORTANT: For production apps, store API keys securely, e.g., in a `.plist` file not committed to version control, or using server-side proxies.
let geminiModel = GenerativeModel(name: "gemini-2.5-flash-lite", apiKey: GEMINI_API_KEY)
enum GeminiError: Error { case emptyResponse }


// MARK: - Loading Wave Animation
struct WaveShape: Shape {
    var phase: Double
    var amplitude: Double = 20
    var frequency: Double = 1.5

    var animatableData: Double {
        get { phase }
        set { self.phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: 0, y: 0))

        for x in stride(from: 0, to: rect.width, by: 1) {
            let relativeX = x / rect.width
            let angle = (relativeX * 2 * .pi * frequency) + phase
            let y = sin(angle) * amplitude
            
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()

        return path
    }
}

struct LoadingWaveView: View {
    @State private var phase = 0.0
    @State private var progress = 0.0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.9).ignoresSafeArea()
                
                WaveShape(phase: phase)
                    .fill(
                        LinearGradient(colors: [.cyan.opacity(0.8), .blue.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: geometry.size.height * 2)
                    .offset(y: (1 - progress) * geometry.size.height)
            }
        }
        .onAppear {
            // Wave animation
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
            
            withAnimation(.easeInOut(duration: 8.0).delay(0.2)) {
                progress = 1.0
            }
        }
    }
}


// MARK: - Animated Background Views
struct DynamicGradientBackground: View {
    let colors: [Color]

    var body: some View {
        if #available(iOS 18.0, *) {
            AnimatedMeshGradientBackground(colors: colors)
        } else {
            AnimatedGradientBackground(colors: colors)
        }
    }
}

@available(iOS 18.0, *)
struct AnimatedMeshGradientBackground: View {
    let colors: [Color]
    @State private var animatedColors: [Color] = []
    let gridPoints: [SIMD2<Float>] = [[0, 0], [1, 0], [0, 1], [1, 1]]

    var body: some View {
        MeshGradient(width: 2, height: 2, points: gridPoints, colors: animatedColors)
            .ignoresSafeArea()
            .onAppear {
                self.animatedColors = generateMeshColors(from: colors)
                Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
                    withAnimation(.easeInOut(duration: 5.0)) { self.animatedColors.shuffle() }
                }
            }
            .onChange(of: colors) { newColors in
                withAnimation(.easeInOut(duration: 3.0)) { self.animatedColors = generateMeshColors(from: newColors) }
            }
    }
    
    private func generateMeshColors(from input: [Color]) -> [Color] {
        guard !input.isEmpty else { return Array(repeating: .gray, count: 4) }
        var output: [Color] = []
        for i in 0..<4 { output.append(input[i % input.count]) }
        return output
    }
}

struct AnimatedGradientBackground: View {
    @State private var animateGradient = false
    let colors: [Color]

    var body: some View {
        LinearGradient(colors: colors, startPoint: animateGradient ? .topLeading : .bottomLeading, endPoint: animateGradient ? .bottomTrailing : .topTrailing)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: true)) { animateGradient.toggle() }
            }
    }
}

// MARK: - Models

struct UserProfile: Codable {
    var name: String = ""
    var race: String = ""
    var gender: String = ""
    var skinTone: Double = 0.5
    var age: Int = 30
    var allergies: String = ""
    var medicalConditions: String = ""

   
    var promptRepresentation: String {
        var components: [String] = []
        if !name.isEmpty { components.append("User's name is \(name).") }
        components.append("User is \(age) years old.")
        if !gender.isEmpty && gender != "Prefer not to say" { components.append("Gender: \(gender).") }
        if !allergies.isEmpty { components.append("User has the following allergies: \(allergies). This is critical for outdoor advice.") }
        if !medicalConditions.isEmpty { components.append("User has the following medical conditions: \(medicalConditions). This is critical for health-related advice.") }

        guard !components.isEmpty else { return "No personal user data provided." }
        return "Please consider the following user profile for personalized advice:\n" + components.joined(separator: "\n")
    }
}

class UserProfileManager: ObservableObject {
    @Published var profile = UserProfile() {
        didSet { saveProfile() }
    }

    private let userDefaultsKey = "userProfileData"

    init() {
        loadProfile()
    }

    func saveProfile() {
        if let encoded = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    func loadProfile() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            self.profile = decoded
        }
    }
    
    
}

struct PowerAPIResponse: Codable {
    let properties: Properties
    struct Properties: Codable { let parameter: Parameter }
    struct Parameter: Codable {
        let T2M: [String: Double]?
        let PRECTOTCORR: [String: Double]?
    }
}

struct MeteoCurrentWeather: Codable {
    let latitude: Double
    let longitude: Double
    let current: CurrentWeather
    
    struct CurrentWeather: Codable {
        let temperature_2m: Double
        let relative_humidity_2m: Int
        let precipitation: Double
        let weather_code: Int
        let wind_speed_10m: Double
    }
}

struct HistoricalDataPoint {
    let year: Int
    let temperature: Double
    let precipitation: Double
}

struct HourlyWeatherData: Identifiable {
    let id = UUID()
    let hour: Int
    let temperature: Double
    let precipitation: Double
    let isPrediction: Bool
}

struct DailyWeatherData: Identifiable {
    let id = UUID()
    let date: Date
    let avgTemperature: Double
    let totalPrecipitation: Double
    let hourlyData: [HourlyWeatherData]
    let isPrediction: Bool
}

// MARK: - Address Autocompletion Manager
class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var completions: [MKLocalSearchCompletion] = []
    private var completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
    }
    
    var queryFragment: String = "" {
        didSet { completer.queryFragment = queryFragment }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        self.completions = completer.results.filter { !$0.subtitle.isEmpty }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Completer failed with error: \(error.localizedDescription)")
    }
}

// MARK: - Location Manager
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
    )
    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var locationError: String?
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        DispatchQueue.main.async {
            self.currentLocation = location.coordinate
            self.region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
            )
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.locationError = "Unable to get location: \(error.localizedDescription)"
        }
        print("Location error: \(error.localizedDescription)")
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.locationError = "Location access denied. Please enable in Settings."
            }
        default:
            break
        }
    }
}

// MARK: - Weather Predictor
class WeatherPredictor {
    func predictWeather(historicalData: [HistoricalDataPoint]) -> (temperature: Double, precipitation: Double)? {
        guard !historicalData.isEmpty else { return nil }
        let tempSum = historicalData.reduce(0) { $0 + $1.temperature }
        let precipSum = historicalData.reduce(0) { $0 + $1.precipitation }
        let count = Double(historicalData.count)
        let avgTemp = tempSum / count
        let avgPrecip = precipSum / count
        return (temperature: avgTemp, precipitation: max(0, avgPrecip))
    }
}

// MARK: - API Service
class NASAPowerService: ObservableObject {
    @Published var dailyWeatherData: [DailyWeatherData] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentWeather: MeteoCurrentWeather?
    @Published var isLoadingCurrent = false
    private let predictor = WeatherPredictor()
    
    func fetchCurrentWeather(latitude: Double, longitude: Double) {
        guard !isLoadingCurrent else { return }
        
        isLoadingCurrent = true
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,relative_humidity_2m,precipitation,weather_code,wind_speed_10m&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch"
        
        guard let url = URL(string: urlString) else {
            isLoadingCurrent = false
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoadingCurrent = false
                guard let data = data, error == nil else {
                    print("Error fetching current weather: \(error?.localizedDescription ?? "Unknown")")
                    return
                }
                
                do {
                    let decoded = try JSONDecoder().decode(MeteoCurrentWeather.self, from: data)
                    self?.currentWeather = decoded
                } catch {
                    print("Decoding error: \(error)")
                }
            }
        }.resume()
    }
    
    func fetchWeatherForDateRange(latitude: Double, longitude: Double, startDate: Date, days: Int = 7) {
        isLoading = true
        errorMessage = nil
        dailyWeatherData = []
        let group = DispatchGroup()
        var fetchedDailyData: [DailyWeatherData] = []
        for dayOffset in 0..<days {
            guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: startDate) else { continue }
            group.enter()
            fetchDayData(latitude: latitude, longitude: longitude, date: date) { dailyData in
                if let dailyData = dailyData {
                    DispatchQueue.main.async { fetchedDailyData.append(dailyData) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                self?.isLoading = false
                self?.dailyWeatherData = fetchedDailyData.sorted { $0.date < $1.date }
                if fetchedDailyData.isEmpty {
                    self?.errorMessage = "No data available for the selected location and date range. Please try different parameters."
                }
            }
        }
    }
    private func fetchDayData(latitude: Double, longitude: Double, date: Date, completion: @escaping (DailyWeatherData?) -> Void) {
        if Calendar.current.startOfDay(for: date) > Calendar.current.startOfDay(for: Date()) {
            fetchHistoricalAndPredictDay(latitude: latitude, longitude: longitude, targetDate: date, completion: completion)
        } else {
            fetchActualDayData(latitude: latitude, longitude: longitude, date: date, completion: completion)
        }
    }
    private func fetchActualDayData(latitude: Double, longitude: Double, date: Date, completion: @escaping (DailyWeatherData?) -> Void) {
        fetchHourlyDataForSingleDay(latitude: latitude, longitude: longitude, date: date) { response in
            guard let decoded = response else { completion(nil); return }
            let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyyMMdd"
            let dateString = dateFormatter.string(from: date)
            var hourlyData: [HourlyWeatherData] = []
            for hour in 0..<24 {
                let hourString = String(format: "%02d", hour)
                let hourlyKey = dateString + hourString
                if let temp = decoded.properties.parameter.T2M?[hourlyKey], let precip = decoded.properties.parameter.PRECTOTCORR?[hourlyKey], temp != -999, precip != -999 {
                    hourlyData.append(HourlyWeatherData(hour: hour, temperature: temp, precipitation: precip, isPrediction: false))
                }
            }
            guard !hourlyData.isEmpty else { completion(nil); return }
            let avgTemp = hourlyData.map { $0.temperature }.reduce(0, +) / Double(hourlyData.count)
            let totalPrecip = hourlyData.map { $0.precipitation }.reduce(0, +)
            completion(DailyWeatherData(date: date, avgTemperature: avgTemp, totalPrecipitation: totalPrecip, hourlyData: hourlyData, isPrediction: false))
        }
    }
    private func fetchHistoricalAndPredictDay(latitude: Double, longitude: Double, targetDate: Date, completion: @escaping (DailyWeatherData?) -> Void) {
        let calendar = Calendar.current
        let targetComponents = calendar.dateComponents([.year, .month, .day], from: targetDate)
        var yearsToFetch: [Int] = []
        for i in 1...5 {
            if let year = targetComponents.year { yearsToFetch.append(year - i) }
        }
        let group = DispatchGroup()
        var historicalResponses = [Int: PowerAPIResponse]()
        let lock = NSLock()
        for year in yearsToFetch {
            var historicalComponents = targetComponents; historicalComponents.year = year
            guard let historicalDate = calendar.date(from: historicalComponents) else { continue }
            group.enter()
            fetchHourlyDataForSingleDay(latitude: latitude, longitude: longitude, date: historicalDate) { response in
                if let response = response { lock.lock(); historicalResponses[year] = response; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            var hourlyPredictions: [HourlyWeatherData] = []
            let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyyMMdd"
            for hour in 0..<24 {
                var historicalDataForHour: [HistoricalDataPoint] = []
                for year in yearsToFetch {
                    guard let response = historicalResponses[year] else { continue }
                    var historicalComponents = targetComponents; historicalComponents.year = year
                    guard let historicalDate = calendar.date(from: historicalComponents) else { continue }
                    let dateString = dateFormatter.string(from: historicalDate)
                    let hourString = String(format: "%02d", hour)
                    let hourlyKey = dateString + hourString
                    if let temp = response.properties.parameter.T2M?[hourlyKey], let precip = response.properties.parameter.PRECTOTCORR?[hourlyKey], temp != -999, precip != -999 {
                        historicalDataForHour.append(HistoricalDataPoint(year: year, temperature: temp, precipitation: precip))
                    }
                }
                if let prediction = self.predictor.predictWeather(historicalData: historicalDataForHour) {
                    hourlyPredictions.append(HourlyWeatherData(hour: hour, temperature: prediction.temperature, precipitation: prediction.precipitation, isPrediction: true))
                }
            }
            DispatchQueue.main.async {
                guard !hourlyPredictions.isEmpty else { completion(nil); return }
                hourlyPredictions.sort { $0.hour < $1.hour }
                let avgTemp = hourlyPredictions.map { $0.temperature }.reduce(0, +) / Double(hourlyPredictions.count)
                let totalPrecip = hourlyPredictions.map { $0.precipitation }.reduce(0, +)
                completion(DailyWeatherData(date: targetDate, avgTemperature: avgTemp, totalPrecipitation: totalPrecip, hourlyData: hourlyPredictions, isPrediction: true))
            }
        }
    }
    private func fetchHourlyDataForSingleDay(latitude: Double, longitude: Double, date: Date, completion: @escaping (PowerAPIResponse?) -> Void) {
        let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyyMMdd"
        let dateString = dateFormatter.string(from: date)
        let urlString = "https://power.larc.nasa.gov/api/temporal/hourly/point?parameters=T2M,PRECTOTCORR&community=RE&longitude=\(longitude)&latitude=\(latitude)&start=\(dateString)&end=\(dateString)&format=JSON"
        guard let url = URL(string: urlString) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else { completion(nil); return }
            do {
                completion(try JSONDecoder().decode(PowerAPIResponse.self, from: data))
            } catch {
                completion(nil)
            }
        }.resume()
    }
}

// MARK: - Helper Struct
struct IdentifiableCoordinate: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Main View
struct ContentView: View {
    @StateObject private var apiService = NASAPowerService()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var userProfileManager = UserProfileManager()
    @State private var showingPlanSheet = false
    @State private var showingGoingOutSheet = false
    @State private var selectedDayIndex = 0
    @State private var selectedHourIndex = 12
    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var hasData = false
    @State private var hasLoadedInitialWeather = false
    @State private var showingProfileSheet = false
    @State private var dragOffset: CGSize = .zero
    var body: some View {
        NavigationView {
            ZStack {
                if !hasData {
                    ZStack {
                        DynamicGradientBackground(colors: currentWeatherGradient)
                        VStack(spacing: 20) {
                            Spacer()
                            
                            if let weather = apiService.currentWeather {
                                CurrentWeatherWelcomeCard(weather: weather)
                                   
                                   
                            } else if let error = locationManager.locationError {
                                VStack(spacing: 16) {
                                    Image(systemName: "location.slash.fill")
                                        .font(.system(size: 60))
                                        .foregroundColor(.white.opacity(0.7))
                                    Text(error)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                }
                            } else {
                                VStack(spacing: 20) {
                                    ProgressView()
                                        .scaleEffect(1.5)
                                        .tint(.white)
                                    Text("Loading current weather...")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                }
                            }
                            
                            Spacer()
                            
                            Button(action: { showingGoingOutSheet = true }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "figure.walk.circle.fill").font(.title3)
                                    Text("Going Out Now?").font(.title3.bold())
                                }
                                .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 20)
                                .background(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing))
                                .cornerRadius(16).shadow(color: .green.opacity(0.4), radius: 10, x: 0, y: 5)
                            }
                            .padding(.horizontal, 30)
                            
                            Button(action: { showingPlanSheet = true }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "calendar.badge.plus").font(.title3)
                                    Text("Plan Event").font(.title3.bold())
                                }
                                .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 20)
                                .background(planEventButtonGradient)
                                .cornerRadius(16).shadow(color: planEventShadowColor, radius: 10, x: 0, y: 5)
                            }.padding(.horizontal, 30).padding(.bottom, 50)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connected to POWER")
                                
                            }
                        }
                        .font(.caption).foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.black.opacity(0.3)).cornerRadius(10).padding(.top, 10).padding(.leading, 10)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            showingProfileSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.headline)
                                Text("Profile")
                                    .font(.caption).fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(10)
                            .padding(.top, 10)
                            .padding(.trailing, 10)
                        }
                    }
                } else {
                    WeatherDataView(
                        apiService: apiService,
                        selectedDayIndex: $selectedDayIndex,
                        selectedHourIndex: $selectedHourIndex,
                        onPlanNewEvent: {
                            hasData = false
                            apiService.dailyWeatherData = []
                        }
                    )
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showingPlanSheet) {
            PlanEventSheet(
                selectedLocation: $selectedLocation,
                onComplete: { location, date in
                    selectedLocation = location
                    selectedDayIndex = 0
                    selectedHourIndex = 12
                    apiService.fetchWeatherForDateRange(latitude: location.latitude, longitude: location.longitude, startDate: date, days: 7)
                    showingPlanSheet = false
                    hasData = true
                }
            )
        }
        .sheet(isPresented: $showingProfileSheet) {
            ProfileView()
        }
        .sheet(isPresented: $showingGoingOutSheet) {
            // Pass the current UserProfile to GoingOutNowView
            GoingOutNowView(currentWeather: apiService.currentWeather, userProfile: userProfileManager.profile)
        }
        .environmentObject(userProfileManager)
        .onAppear {
            if let location = locationManager.currentLocation, !hasLoadedInitialWeather {
                apiService.fetchCurrentWeather(latitude: location.latitude, longitude: location.longitude)
                hasLoadedInitialWeather = true
            }
        }
        .onChange(of: locationManager.currentLocation) { newLocation in
            if let location = newLocation, !hasData, !hasLoadedInitialWeather {
                apiService.fetchCurrentWeather(latitude: location.latitude, longitude: location.longitude)
                hasLoadedInitialWeather = true
            }
        }
    }
    
    private var currentWeatherGradient: [Color] {
        guard let weather = apiService.currentWeather else {
            return [.pink, .purple, .blue]
        }
        let temp = weather.current.temperature_2m
        let precipitation = weather.current.precipitation
        if precipitation > 0.1 { return [Color(white: 0.4), .blue, .indigo, .gray] }
        else if temp > 75 { return [.yellow, .orange, .pink, .red] }
        else if temp < 40 { return [.white, .cyan.opacity(0.5), .blue.opacity(0.6), .gray] }
        return [.blue, .purple.opacity(0.8), .cyan]
    }
    
    private var planEventButtonGradient: LinearGradient {
        guard let weather = apiService.currentWeather else {
            return LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
        }
        let temp = weather.current.temperature_2m
        let precipitation = weather.current.precipitation
        if precipitation > 0.1 { return LinearGradient(colors: [.blue.opacity(0.8), .indigo], startPoint: .leading, endPoint: .trailing) }
        else if temp > 75 { return LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing) }
        else if temp < 40 { return LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing) }
        return LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
    }
    
    private var planEventShadowColor: Color {
        guard let weather = apiService.currentWeather else { return .blue.opacity(0.4) }
        let temp = weather.current.temperature_2m
        let precipitation = weather.current.precipitation
        if precipitation > 0.1 { return .blue.opacity(0.4) }
        else if temp > 75 { return .orange.opacity(0.4) }
        else if temp < 40 { return .cyan.opacity(0.4) }
        return .blue.opacity(0.4)
    }
}

// MARK: - Loading Message Enum
enum LoadingPhase: CaseIterable {
    case talkingWithMERRA2
    case makingPredictions
    case askingDelphi

    var message: String {
        switch self {
        case .talkingWithMERRA2: return "Talking with MERRA-2..."
        case .makingPredictions: return "Making Predictions..."
        case .askingDelphi: return "Asking Delphi..."
        }
    }

    var imageName: String {
        switch self {
        case .talkingWithMERRA2: return "SAT"
        case .makingPredictions: return "BALL"
        case .askingDelphi: return "MAGIC"
        }
    }
}

// MARK: - Weather Data View
struct WeatherDataView: View {
    @ObservedObject var apiService: NASAPowerService
    @Binding var selectedDayIndex: Int
    @Binding var selectedHourIndex: Int
    let onPlanNewEvent: () -> Void
    
    @State private var currentLoadingPhase: LoadingPhase = .talkingWithMERRA2
    @State private var loadingMessageTask: Task<Void, Never>? = nil
    @State private var satImageScale: CGFloat = 1.0

    var currentDay: DailyWeatherData? {
        guard !apiService.dailyWeatherData.isEmpty, selectedDayIndex < apiService.dailyWeatherData.count else { return nil }
        return apiService.dailyWeatherData[selectedDayIndex]
    }
    
    var currentHour: HourlyWeatherData? {
        guard let day = currentDay, !day.hourlyData.isEmpty, selectedHourIndex < day.hourlyData.count else { return nil }
        return day.hourlyData[selectedHourIndex]
    }
    
    private var currentGradientColors: [Color] {
        guard let hour = currentHour else { return [.blue, .purple] }
        let tempF = (hour.temperature * 9/5) + 32
        if hour.precipitation > 2.0 { return [Color(white: 0.4), .blue, .indigo, .gray] }
        else if tempF > 75 && hour.precipitation < 0.5 { return [.yellow, .orange, .pink, .red] }
        else if tempF < 40 { return [.white, .cyan.opacity(0.5), .blue.opacity(0.6), .gray] }
        return [.blue, .purple.opacity(0.8), .cyan]
    }
    
    var body: some View {
        ZStack {
            DynamicGradientBackground(colors: currentGradientColors).zIndex(0)
            
            if !apiService.isLoading {
                ScrollView {
                    VStack(spacing: 24) {
                        if let error = apiService.errorMessage {
                            VStack(spacing: 20) {
                                Text("Error").font(.title.bold())
                                Text(error).multilineTextAlignment(.center)
                                Button("Plan a New Event", action: onPlanNewEvent).buttonStyle(.borderedProminent)
                            }
                            .padding(40).background(.thinMaterial).cornerRadius(20)
                        } else if let day = currentDay {
                            CurrentWeatherCard(day: day, hour: currentHour)
                            DailySummaryView(day: day)
                            HourlyWeatherSlider(hourlyData: day.hourlyData, selectedHourIndex: $selectedHourIndex)
                            DailyForecastSlider(dailyData: apiService.dailyWeatherData, selectedDayIndex: $selectedDayIndex)
                            TemperatureChartCard(hourlyData: day.hourlyData)
                            PrecipitationChartCard(hourlyData: day.hourlyData)
                        }
                    }
                    .padding(.vertical).padding(.top, 40)
                }
                .background(.clear).zIndex(1)
            }
            
            if apiService.isLoading {
                ZStack{
                    LoadingWaveView()
                        .transition(.opacity.animation(.easeIn(duration: 0.5)))
                        .zIndex(10)
                        .overlay{
                            VStack{
                                Spacer()
                                Image(currentLoadingPhase.imageName)
                                    .resizable()
                                    .frame(width:24, height:24)
                                    .scaleEffect(satImageScale)
                                HStack{
                                    Text(currentLoadingPhase.message).fontWeight(.heavy)
                                }
                                Spacer()
                            }
                        }
                }
                .onAppear {
                    startLoadingMessageSequence()
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        satImageScale = 1.2
                    }
                }
                .onDisappear {
                    loadingMessageTask?.cancel()
                    satImageScale = 1.0
                }
            }
            
            VStack {
                HStack {
                    Button(action: onPlanNewEvent) {
                        Image(systemName: "xmark")
                            .font(.title3.bold()).foregroundColor(.white).frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.5)).clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
                    }
                    .padding(.leading, 16).padding(.top, 16)
                    Spacer()
                }
                Spacer()
            }.zIndex(2)
        }
        .colorScheme(.dark)
    }

    private func startLoadingMessageSequence() {
        loadingMessageTask?.cancel()
        currentLoadingPhase = .talkingWithMERRA2

        loadingMessageTask = Task {
            do {
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { currentLoadingPhase = .makingPredictions }

                try await Task.sleep(nanoseconds: 4 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { currentLoadingPhase = .askingDelphi }

            } catch {
                print("Loading message sequence was cancelled.")
            }
        }
    }
}

// MARK: - Cards and Sliders
struct CurrentWeatherWelcomeCard: View {
    let weather: MeteoCurrentWeather
    
    
    var weatherIcon: String {
        let code = weather.current.weather_code
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67: return "cloud.rain.fill"
        case 71...77: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.sun.fill"
        }
    }
    
    var weatherDescription: String {
        let code = weather.current.weather_code
        switch code {
        case 0: return "Clear Sky"
        case 1: return "Mainly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51...67: return "Rainy"
        case 71...77: return "Snowy"
        case 80...82: return "Rain Showers"
        case 85, 86: return "Snow Showers"
        case 95...99: return "Thunderstorm"
        default: return "Unknown"
        }
    }
  
    @State private var rotationX: Double = 0.0
    @State private var rotationY: Double = 0.0
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let maxRotation: Double = 15.0

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .foregroundStyle(Color.gray)
                    
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Current Weather").font(.title2.bold()).foregroundColor(.white)
                        Text("Your Location").font(.subheadline).foregroundColor(.white.opacity(0.7))
                    }
                    
                    Image(systemName: weatherIcon)
                        .font(.system(size: 80))
                        .foregroundStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: .orange.opacity(0.3), radius: 10)
                    
                    VStack(spacing: 4) {
                        Text("\(Int(weather.current.temperature_2m))°F").font(.system(size: 64, weight: .bold)).foregroundColor(.white)
                        Text(weatherDescription).font(.title3).foregroundColor(.white.opacity(0.9))
                    }
                    
                    HStack(spacing: 40) {
                        VStack(spacing: 8) {
                            Image(systemName: "humidity.fill").font(.title2).foregroundColor(.blue)
                            Text("\(weather.current.relative_humidity_2m)%").font(.headline).foregroundColor(.white)
                            Text("Humidity").font(.caption).foregroundColor(.white.opacity(0.7))
                        }
                        
                        VStack(spacing: 8) {
                            Image(systemName: "wind").font(.title2).foregroundColor(.cyan)
                            Text("\(Int(weather.current.wind_speed_10m)) mph").font(.headline).foregroundColor(.white)
                            Text("Wind").font(.caption).foregroundColor(.white.opacity(0.7))
                        }
                        
                        VStack(spacing: 8) {
                            Image(systemName: "drop.fill").font(.title2).foregroundColor(.blue)
                            Text(String(format: "%.2f\"", weather.current.precipitation)).font(.headline).foregroundColor(.white)
                            Text("Rain").font(.caption).foregroundColor(.white.opacity(0.7))
                        }
                    }
                    Text("Data from Open-Meteo").font(.caption)
                }
                
                .padding(32)             }
            .drawingGroup()
            
            .padding(24)
            .rotation3DEffect(.degrees(rotationX * -1.5), axis: (x: 1, y: 0, z: 0), perspective: 1)
            .rotation3DEffect(.degrees(rotationY * 1.5), axis: (x: 0, y: 1, z: 0), perspective: 1)
            .offset(x: rotationY * 0.5, y: rotationX * 0.5)
            // The gesture logic
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        rotationX = (value.location.y - size.height / 2) / (size.height / 2) * maxRotation
                        rotationY = (value.location.x - size.width / 2) / (size.width / 2) * -maxRotation
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                            rotationX = 0
                            rotationY = 0
                        }
                    }
            )
        }
        .padding(.horizontal, 24)
    }
    }
    


struct CurrentWeatherCard: View {
    let day: DailyWeatherData
    let hour: HourlyWeatherData?
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.date, style: .date).font(.title2.bold())
                    if let hour = hour {
                        Text(String(format: "%02d:00", hour.hour))
                            .font(.subheadline).foregroundColor(.white.opacity(0.7))
                    }
                }
                Spacer()
                if day.isPrediction {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles"); Text("Predicted")
                    }
                    .font(.caption.bold()).foregroundColor(.purple).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.purple.opacity(0.2)).cornerRadius(20)
                }
            }
            HStack(alignment: .top, spacing: 40) {
                VStack(spacing: 8) {
                    Image(systemName: "thermometer.medium").font(.system(size: 40)).foregroundColor(.orange)
                    if let hour = hour {
                        Text("\((hour.temperature * 9/5) + 32, specifier: "%.0f")°F").font(.system(size: 48, weight: .bold))
                        Text("\(hour.temperature, specifier: "%.1f")°C").font(.subheadline).foregroundColor(.white.opacity(0.7))
                    }
                }
                VStack(spacing: 8) {
                    Image(systemName: "cloud.rain.fill").font(.system(size: 40)).foregroundColor(.blue)
                    if let hour = hour {
                        Text("\(hour.precipitation / 25.4, specifier: "%.2f")\"").font(.system(size: 48, weight: .bold))
                        Text("\(hour.precipitation, specifier: "%.1f") mm").font(.subheadline).foregroundColor(.white.opacity(0.7))
                    }
                }
            }.frame(maxWidth: .infinity)
        }.padding(24).background(.thinMaterial).cornerRadius(20).padding(.horizontal)
    }
}
struct HourlyWeatherSlider: View {
    let hourlyData: [HourlyWeatherData]
    @Binding var selectedHourIndex: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hourly Forecast").font(.headline)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(hourlyData.enumerated()), id: \.element.id) { index, data in
                            VStack(spacing: 8) {
                                Text(String(format: "%02d:00", data.hour)).font(.caption.bold())
                                Image(systemName: data.precipitation > 1 ? "cloud.rain.fill" : "sun.max.fill").foregroundColor(data.precipitation > 1 ? .blue : .orange)
                                Text("\((data.temperature * 9/5) + 32, specifier: "%.0f")°").font(.subheadline.bold())
                            }
                            .frame(width: 60).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(selectedHourIndex == index ? Color.blue.opacity(0.4) : Color.white.opacity(0.1)))
                            .id(index)
                            .onTapGesture { withAnimation { selectedHourIndex = index; proxy.scrollTo(index, anchor: .center) } }
                        }
                    }
                }.onAppear { proxy.scrollTo(selectedHourIndex, anchor: .center) }
            }
        }
        .padding(24).background(.thinMaterial).cornerRadius(20).padding(.horizontal)
    }
}
struct TemperatureChartCard: View {
    let hourlyData: [HourlyWeatherData]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temperature Trend").font(.headline)
            Chart(hourlyData) { data in
                LineMark(x: .value("Hour", data.hour), y: .value("Temperature", (data.temperature * 9/5) + 32)).foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)).lineStyle(StrokeStyle(lineWidth: 3))
                AreaMark(x: .value("Hour", data.hour), y: .value("Temperature", (data.temperature * 9/5) + 32)).foregroundStyle(LinearGradient(colors: [.orange.opacity(0.3), .red.opacity(0.1)], startPoint: .top, endPoint: .bottom))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }.frame(height: 200).padding()
        }
        .padding(24).background(.thinMaterial).cornerRadius(20).padding(.horizontal)
    }
}
struct PrecipitationChartCard: View {
    let hourlyData: [HourlyWeatherData]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Precipitation").font(.headline)
            Chart(hourlyData) { data in
                BarMark(x: .value("Hour", data.hour), y: .value("Precipitation", data.precipitation / 25.4)).foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }.frame(height: 150).padding()
        }
        .padding(24).background(.thinMaterial).cornerRadius(20).padding(.horizontal)
    }
}
struct DailyForecastSlider: View {
    let dailyData: [DailyWeatherData]
    @Binding var selectedDayIndex: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("7-Day Forecast").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(dailyData.enumerated()), id: \.element.id) { index, data in
                        VStack(spacing: 8) {
                            Text(data.date, format: .dateTime.weekday(.abbreviated)).font(.caption.bold()); Text(data.date, format: .dateTime.month().day()).font(.caption2)
                            Image(systemName: data.totalPrecipitation > 5 ? "cloud.rain.fill" : "sun.max.fill").font(.title3).foregroundColor(data.totalPrecipitation > 5 ? .blue : .orange)
                            Text("\((data.avgTemperature * 9/5) + 32, specifier: "%.0f")°").font(.headline)
                            if data.isPrediction { Image(systemName: "sparkles").font(.caption2).foregroundColor(.purple) }
                        }.frame(width: 80).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 16).fill(selectedDayIndex == index ? Color.purple.opacity(0.4) : Color.white.opacity(0.1))).onTapGesture { withAnimation { selectedDayIndex = index } }
                    }
                }
            }
        }
        .padding(24).background(.thinMaterial).cornerRadius(20).padding(.horizontal)
    }
}

// MARK: - Plan Event Sheet
struct PlanEventSheet: View {
    @StateObject private var mapLocationManager = LocationManager()
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var selectedDate = Date()
    @State private var annotations: [IdentifiableCoordinate] = []
    @Binding var selectedLocation: CLLocationCoordinate2D?
    let onComplete: (CLLocationCoordinate2D, Date) -> Void
    @Environment(\.dismiss) var dismiss
    @StateObject private var addressCompleter = AddressCompleter()
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var searchError: String?

    // Stable minimum date for the DatePicker
    private var minimumSelectableDate: Date {
        Calendar.current.startOfDay(for: Date())
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                DynamicGradientBackground(colors: [.blue.opacity(0.7), .cyan.opacity(0.7)]) // Lighter animated background
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    
                    ScrollView {
                        Map(coordinateRegion: $mapLocationManager.region, interactionModes: [.pan, .zoom], annotationItems: annotations) { item in
                            MapMarker(coordinate: item.coordinate, tint: .purple)
                        }
                        .cornerRadius(15)
                        .padding()
                        .frame(height: 250)
                        .overlay { if isSearching { Color.black.opacity(0.3).ignoresSafeArea(); ProgressView("Searching...").tint(.white).foregroundColor(.white) } }
                        VStack(spacing: 20) {
                            if let searchError = searchError {
                                Text(searchError).font(.headline).foregroundColor(.red).frame(maxWidth: .infinity).padding().background(Color.red.opacity(0.1)).cornerRadius(12)
                            } else if let coord = selectedCoordinate {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Selected Location").font(.headline)
                                    Text("Lat: \(coord.latitude, specifier: "%.4f"), Lon: \(coord.longitude, specifier: "%.4f")").font(.subheadline).foregroundColor(.gray)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.blue.opacity(0.1)).cornerRadius(12)
                            } else {
                                Text("Use the search bar to find a location").font(.headline).foregroundColor(.secondary).frame(maxWidth: .infinity).padding().background(Color.gray.opacity(0.1)).cornerRadius(12)
                            }
                            DatePicker("Event Date", selection: $selectedDate, in: minimumSelectableDate..., displayedComponents: .date)
                                .datePickerStyle(GraphicalDatePickerStyle())
                                .padding()
                                .background(.ultraThinMaterial) // Changed to darker background
                                .cornerRadius(12)
                            Button(action: { if let coord = selectedCoordinate { onComplete(coord, selectedDate) } }) {
                                Text(isFutureDate() ? "Predict Weather" : "Get Weather").font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding().background(selectedCoordinate == nil ? Color.gray : (isFutureDate() ? Color.purple : Color.blue)).cornerRadius(12)
                            }.disabled(selectedCoordinate == nil)
                        }.padding()
                    }
                }
            }
            .navigationTitle("Plan Event").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } } }
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Enter address or city") {
                ForEach(addressCompleter.completions, id: \.self) { completion in
                    VStack(alignment: .leading) {
                        Text(completion.title).fontWeight(.bold)
                        Text(completion.subtitle).font(.subheadline).foregroundColor(.secondary)
                    }.contentShape(Rectangle()).onTapGesture { handleCompletionTapped(completion) }
                }
            }
            .onChange(of: searchQuery) { newValue in addressCompleter.queryFragment = newValue; searchError = nil }
        }
    }
    
    private func handleCompletionTapped(_ completion: MKLocalSearchCompletion) {
        let fullAddress = completion.subtitle.isEmpty ? completion.title : "\(completion.title), \(completion.subtitle)"
        self.searchQuery = fullAddress
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        geocodeAddress(from: fullAddress)
    }
    
    private func geocodeAddress(from address: String) {
        isSearching = true; searchError = nil
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = address
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                self.isSearching = false
                guard let response = response, let mapItem = response.mapItems.first else {
                    self.searchError = "Could not find location. Please try a different search."; self.annotations = []; self.selectedCoordinate = nil; return
                }
                let coordinate = mapItem.placemark.coordinate
                self.selectedCoordinate = coordinate; self.annotations = [IdentifiableCoordinate(coordinate: coordinate)]
                self.mapLocationManager.region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
            }
        }
    }
    
    private func isFutureDate() -> Bool {
        return !Calendar.current.isDateInToday(selectedDate) && selectedDate > Date()
    }
}

// MARK: - Chat Message Models and Views (NEW)

/// Represents a single message in the chat.
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let content: String
    let isFromUser: Bool // true for user, false for Gemini
}

/// A SwiftUI view for displaying a single chat message bubble.
struct ChatMessageBubble: View {
    let message: ChatMessage
    @State private var showGeminiGlow: Bool = false // State for Gemini glow animation

    var body: some View {
        HStack {
            if message.isFromUser {
                Spacer()
            }
            Text(message.content)
                .padding(12)
                .background(message.isFromUser ? Color.blue.opacity(0.8) : Color.purple.opacity(0.8)) // Blue for user, Purple for Gemini
                .foregroundColor(.white)
                .cornerRadius(15)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2) // General shadow
                // Conditional glow for Gemini messages
                .shadow(color: showGeminiGlow ? Color.purple.opacity(0.7) : .clear, radius: showGeminiGlow ? 15 : 0)
                .onAppear {
                    if !message.isFromUser { // Only for Gemini messages
                        Task {
                            withAnimation(.easeOut(duration: 0.4)) { // Fade in glow
                                showGeminiGlow = true
                            }
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // Hold glow for 1 second
                            withAnimation(.easeIn(duration: 0.6)) { // Fade out glow
                                showGeminiGlow = false
                            }
                        }
                    }
                }
            if !message.isFromUser {
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        // Apply transition for messages appearing
        .transition(
            .asymmetric(
                insertion: .move(edge: message.isFromUser ? .trailing : .leading).combined(with: .opacity),
                removal: .opacity // Simple fade out for removal
            )
        )
    }
}

/// Manages a Gemini chat session, including message history and API calls.
class GeminiChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    private var chat: Chat?
    private let dayData: DailyWeatherData? // Specific to PlanActivityView
    private let currentWeather: MeteoCurrentWeather? // Specific to GoingOutNowView
    private let userProfile: UserProfile // Common

    init(dayData: DailyWeatherData? = nil, currentWeather: MeteoCurrentWeather? = nil, userProfile: UserProfile) {
        self.dayData = dayData
        self.currentWeather = currentWeather
        self.userProfile = userProfile
        startNewChat() // Initialize chat session immediately
    }

    func startNewChat() {
        chat = geminiModel.startChat()
        self.messages = []
        self.errorMessage = nil

        // Add an initial greeting from the AI
        var greeting: String
        if let dayData = dayData {
            greeting = "Hello! I can help you plan for \(dayData.date.formatted(date: .abbreviated, time: .omitted)). What activity are you thinking of?"
        } else if let currentWeather = currentWeather {
            greeting = "Hi there! I'm ready to help you with your plans based on the current weather. What are you doing right now?"
        } else {
            greeting = "Hello! How can I assist you with your weather-related plans today?"
        }
        
        withAnimation(.easeOut(duration: 0.3)) { // Animate the initial greeting
            self.messages.append(ChatMessage(content: greeting, isFromUser: false))
        }
    }

    func sendUserMessage(activity: String) async {
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) { // Animate user message
                self.messages.append(ChatMessage(content: activity, isFromUser: true))
            }
            self.isLoading = true
            self.errorMessage = nil
            // Dismiss the keyboard immediately after user sends message
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        do {
            // Construct the full prompt for this turn, including initial context and user's message
            let fullPrompt = buildCurrentTurnPrompt(for: activity)
            
            // The `Chat` object manages the history. We just send the current "turn" with necessary context.
            let response = try await chat!.sendMessage(fullPrompt)
            let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !text.isEmpty else { throw GeminiError.emptyResponse }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { // Animate Gemini response
                    self.messages.append(ChatMessage(content: text, isFromUser: false))
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Could not retrieve advice: \(error.localizedDescription)"
            }
            print("Gemini chat error:", error)
        }
        await MainActor.run { self.isLoading = false }
    }

    private func buildCurrentTurnPrompt(for activity: String) -> String {
        var promptComponents: [String] = []

        // 1. Core AI persona and constraints
        promptComponents.append("Your name is Delphi, and you are an AI powered by google. You are an outdoors advisor. Provide helpful, actionable advice. Be constructive and discouraging if absolutely necessary (e.g., for safety reasons or bad weather). If the user has medical conditions or allergies, tailor your advice to be safe for them. Keep responses concise, under 100 words. Do NOT use text formatting like bolding or italics. If the user isn't asking about something regarding weather, respond accordingly, but also ask the user if they need help with making plans.")

        // 2. User Profile
        promptComponents.append(userProfile.promptRepresentation)

        // 3. Specific weather context
        if let dayData = dayData {
            let temps = dayData.hourlyData.map { ($0.temperature * 9/5) + 32 }
            let high = temps.max() ?? 0
            let low = temps.min() ?? 0
            let totalPrecipitation = dayData.totalPrecipitation
            let dateString = dayData.date.formatted(date: .abbreviated, time: .omitted)
            promptComponents.append("FORECAST FOR \(dateString): High of \(String(format: "%.0f", high))°F, low of \(String(format: "%.0f", low))°F. Total precipitation: \(String(format: "%.2f", totalPrecipitation / 25.4)) inches.")
        } else if let weather = currentWeather {
            promptComponents.append("CURRENT WEATHER: \(Int(weather.current.temperature_2m))°F, with wind speeds of \(Int(weather.current.wind_speed_10m)) mph and a \(weather.current.precipitation > 0 ? "chance" : "low chance") of rain. Location: Lat: \(weather.latitude), Lon: \(weather.longitude).")
        }

        // 4. Current user activity/question
        promptComponents.append("USER'S CURRENT INPUT: \(activity)")

        return promptComponents.joined(separator: "\n\n")
    }
}


// MARK: - Generative AI Views (Updated)
struct DailySummaryView: View {
    let day: DailyWeatherData
    @EnvironmentObject var userProfileManager: UserProfileManager
    @State private var summary: String = ""
    @State private var isLoading: Bool = false
    @State private var showingPlanActivitySheet = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .transition(.opacity)
                }
                
                Text("Powered by Gemini")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: { showingPlanActivitySheet = true }) {
                Image(systemName: "sparkles")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(
                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(Circle())
                    .shadow(color: .purple.opacity(0.4), radius: 8, y: 4)
            }
        }
        .padding(20)
        .background(.thinMaterial)
        .cornerRadius(20)
        .padding(.horizontal)
        .onAppear(perform: generateSummary)
        .onChange(of: day.id) { _ in generateSummary() }
        .sheet(isPresented: $showingPlanActivitySheet) {
            // Pass the current UserProfile to PlanActivityView
            PlanActivityView(dayData: day, userProfile: userProfileManager.profile)
        }
    }
    
    private func generateSummary() {
        isLoading = true
        summary = ""
        Task {
            do {
                let result = try await GeminiService.summarizeDay(dayData: day, userProfile: userProfileManager.profile)
                await MainActor.run {
                    withAnimation {
                        self.summary = result
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        self.summary = "Could not generate summary."
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

// PlanActivityView now becomes a chat view (updated)
struct PlanActivityView: View {
    let dayData: DailyWeatherData
    let userProfile: UserProfile // Passed directly from ContentView
    @State private var userInput: String = ""
    @StateObject private var chatSession: GeminiChatSession // Manages the chat
    @Environment(\.dismiss) var dismiss

    init(dayData: DailyWeatherData, userProfile: UserProfile) {
        self.dayData = dayData
        self.userProfile = userProfile
        // Initialize chatSession with the specific dayData and userProfile
        _chatSession = StateObject(wrappedValue: GeminiChatSession(dayData: dayData, userProfile: userProfile))
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                DynamicGradientBackground(colors: [.blue, .indigo, .purple]).ignoresSafeArea()
                
                VStack(spacing: 10) {
                    VStack(spacing: 2) {
                        HStack{
                            Image(systemName: "sparkles")
                                .resizable()
                                .frame(width: 24, height: 24)
                                .foregroundStyle(Color.yellow)
                            Text("Plan with Delphi").font(.largeTitle.bold()).multilineTextAlignment(.center).foregroundStyle(.white)
                        }
                        Text("Day Forecast: \(dayData.date.formatted(date: .abbreviated, time: .omitted))").font(.body).multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85)).padding(.horizontal)
                    }.padding(.top, 40)
                    
                    ScrollView {
                        ScrollViewReader { proxy in
                            VStack(spacing: 0) {
                                ForEach(chatSession.messages) { message in
                                    ChatMessageBubble(message: message)
                                        .id(message.id) // Assign ID for scrolling
                                }
                                if chatSession.isLoading {
                                    // Show a subtle loading indicator for Gemini's response
                                    HStack {
                                        ProgressView().tint(.purple)
                                            .scaleEffect(0.8)
                                            .padding(.leading, 12)
                                            .padding(.vertical, 4)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                }
                            }
                            .onChange(of: chatSession.messages.count) { _ in
                                // Scroll to the bottom when a new message is added
                                if let lastMessage = chatSession.messages.last {
                                    withAnimation { // Animate the scroll
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                    
                    HStack(spacing: 10) {
                        TextField("e.g., 'Go for a long run'", text: $userInput)
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.white)
                            .textInputAutocapitalization(.sentences)
                            .disableAutocorrection(false)
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .background(RoundedRectangle(cornerRadius: 50).fill(.ultraThinMaterial))
                        
                        Button {
                            Task {
                                let message = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !message.isEmpty else { return }
                                userInput = "" // Clear input field immediately
                                await chatSession.sendUserMessage(activity: message)
                            }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .clipShape(Circle())
                                .shadow(color: .purple.opacity(0.35), radius: 12, x: 0, y: 6)
                        }
                        .disabled(chatSession.isLoading || userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
            }
            .background(.clear).preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundColor(.white).frame(width: 30, height: 30).clipShape(Circle()) }
                }
            }
        }
    }
}

// GoingOutNowView now becomes a chat view (updated)
struct GoingOutNowView: View {
    let currentWeather: MeteoCurrentWeather?
    let userProfile: UserProfile // Passed directly from ContentView
    @State private var userInput = ""
    @StateObject private var chatSession: GeminiChatSession // Manages the chat
    @Environment(\.dismiss) var dismiss

    init(currentWeather: MeteoCurrentWeather?, userProfile: UserProfile) {
        self.currentWeather = currentWeather
        self.userProfile = userProfile
        // Initialize chatSession with the specific currentWeather and userProfile
        _chatSession = StateObject(wrappedValue: GeminiChatSession(currentWeather: currentWeather, userProfile: userProfile))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DynamicGradientBackground(colors: [.pink, .purple, .blue]).ignoresSafeArea()

                VStack(spacing: 10) {
                    VStack(spacing:2) {
                        HStack{
                            Image(systemName:"sparkles")
                                .resizable()
                                .frame(width: 24, height: 24)
                                .foregroundStyle(Color.yellow)
                            Text("Ask Delphi").font(.largeTitle.bold()).multilineTextAlignment(.center).foregroundStyle(.white)
                        }
                        Text("What are you going to do right now?").font(.body).multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85)).padding(.horizontal)
                    }.padding(.top, 40)
                    
                    ScrollView {
                        ScrollViewReader { proxy in
                            VStack(spacing: 0) {
                                ForEach(chatSession.messages) { message in
                                    ChatMessageBubble(message: message)
                                        .id(message.id)
                                }
                                if chatSession.isLoading {
                                    HStack {
                                        ProgressView().tint(.purple)
                                            .scaleEffect(0.8)
                                            .padding(.leading, 12)
                                            .padding(.vertical, 4)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                }
                            }
                            .onChange(of: chatSession.messages.count) { _ in
                                if let lastMessage = chatSession.messages.last {
                                    withAnimation { // Animate the scroll
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                    
                    HStack(spacing: 10) {
                        TextField("Powered by Gemini", text: $userInput)
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.white)
                            .textInputAutocapitalization(.sentences)
                            .disableAutocorrection(false)
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .background(RoundedRectangle(cornerRadius: 50).fill(.ultraThinMaterial))
                            
                        Button {
                            Task {
                                let message = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !message.isEmpty else { return }
                                userInput = "" // Clear input field
                                await chatSession.sendUserMessage(activity: message)
                            }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .clipShape(Circle())
                                .shadow(color: .purple.opacity(0.35), radius: 12, x: 0, y: 6)
                        }
                        .disabled(chatSession.isLoading || userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
            }
            .background(.clear).preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundColor(.white).frame(width: 30, height: 30).clipShape(Circle()) }
                }
            }
        }
    }
}

// AdviceResultView is no longer needed as advice is shown in chat
// struct AdviceResultView: View { ... }

// MARK: - Gemini Service (Updated - Advise methods removed)

struct GeminiService {
    // summarizeDay remains as it's used for the daily overview, not a chat session
    static func summarizeDay(dayData: DailyWeatherData, userProfile: UserProfile) async throws -> String {
        guard !dayData.hourlyData.isEmpty else {
            return "Not enough data to generate a summary."
        }
        
        let temps = dayData.hourlyData.map { ($0.temperature * 9/5) + 32 }
        let high = temps.max() ?? 0
        let low = temps.min() ?? 0
        let totalPrecipitation = dayData.totalPrecipitation
        let dateString = dayData.date.formatted(date: .abbreviated, time: .omitted)
        let profileInfo = userProfile.promptRepresentation

        let prompt = """
        Your name is Delphi, and you are an AI powered by google.
        You are a friendly weather concierge. Briefly summarize the weather for \(dateString).
        Mention the high of \(String(format: "%.0f", high))°F and the low of \(String(format: "%.0f", low))°F.
        The total precipitation is \(String(format: "%.2f", totalPrecipitation / 25.4)) inches.
        Based ONLY on this weather and the user's profile, suggest 2-3 local activities (like 'visit a museum' or 'go for a hike').
        Be creative and encouraging. Keep the entire response under 75 words. Don't use text formatting. 
        
        \(profileInfo)
        
        If the user isn't asking about something regarding weather, respond accordingly, but also ask the user if they need help with making plans.

        """
        
        let response = try await geminiModel.generateContent(prompt)
        let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw GeminiError.emptyResponse }
        return text
    }
    
    // The static `advise` and `adviseForDay` methods are now replaced by `GeminiChatSession`
}


// MARK: - Profile View (Updated)
struct ProfileView: View {
    @EnvironmentObject var userProfileManager: UserProfileManager
    @Environment(\.dismiss) var dismiss

    let races = ["Asian", "Black", "Hispanic", "White", "Mixed", "Other", "Prefer not to say"]
    let genders = ["Male", "Female", "Non-binary", "Other", "Prefer not to say"]

    var body: some View {
        NavigationStack {
            ZStack {
                DynamicGradientBackground(colors: [.indigo.opacity(0.8), .cyan.opacity(0.8)])
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 25) {
                        // MARK: - Header
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.fill.badge.shield")
                                .font(.system(size: 80))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.2), radius: 10)
                            Text("Your Profile")
                                .font(.largeTitle.bold())
                                .foregroundColor(.white)
                            Text("This info helps personalize your advice.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.top, 40)

                        // MARK: - Card
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Personal Details").font(.headline).padding(.leading)
                            
                            CustomTextField(title: "Name", text: $userProfileManager.profile.name, placeholder: "Enter your name")
                            
                            CustomPicker(title: "Gender", selection: $userProfileManager.profile.gender, items: genders)
                            
                            CustomStepper(title: "Age", value: $userProfileManager.profile.age, range: 1...120)

                            Text("Health Information").font(.headline).padding(.leading).padding(.top)

                            CustomTextField(title: "Allergies", text: $userProfileManager.profile.allergies, placeholder: "e.g., Pollen, Peanuts")
                            
                            CustomTextField(title: "Medical Conditions", text: $userProfileManager.profile.medicalConditions, placeholder: "e.g., Asthma, Diabetes")

                        }
                        .padding(.horizontal)

                        // MARK: - Save Button
                        Button(action: {
                            userProfileManager.saveProfile()
                            dismiss()
                        }) {
                            Label("Save and Close", systemImage: "checkmark.circle.fill")
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                                .cornerRadius(16)
                                .shadow(color: .blue.opacity(0.3), radius: 10)
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 20)
                    }
                }
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Profile View Components (Liquid Glass Style)
struct GlassCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
    }
}

extension View {
    func glassCardStyle() -> some View {
        self.modifier(GlassCardStyle())
    }
}

struct CustomTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.8))
            TextField(placeholder, text: $text)
                .padding(12)
                .background(.black.opacity(0.15))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
                .foregroundStyle(.white)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .glassCardStyle()
    }
}

struct CustomPicker: View {
    let title: String
    @Binding var selection: String
    let items: [String]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(items, id: \.self) { item in
                    Text(item).tag(item)
                }
            }
            .pickerStyle(.menu)
            .accentColor(.purple)
        }
        .glassCardStyle()
    }
}

struct CustomStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").fontWeight(.bold)
            Stepper(title, value: $value, in: range)
                .labelsHidden()
        }
        .glassCardStyle()
    }
}


// MARK: - Preview & Extensions
#Preview{
    ContentView()
}

extension CLLocationCoordinate2D: Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        return lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

extension DailyWeatherData: Equatable {
    static func == (lhs: DailyWeatherData, rhs: DailyWeatherData) -> Bool {
        return lhs.id == rhs.id
    }
}
