import SwiftUI
import MapKit
import Combine
import CoreML
import Charts
import Foundation
import GoogleGenerativeAI

// MARK: - Generative AI Setup
let GEMINI_API_KEY = "AIzaSyBlByVQ2vYjD0OpHYBLmYdOZ9rgHRBowfM" // Replace with your actual key
let geminiModel = GenerativeModel(name: "gemini-2.5-flash", apiKey: GEMINI_API_KEY)
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
            
            withAnimation(.easeInOut(duration: 4.0).delay(0.2)) {
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
    @State private var showingPlanSheet = false
    @State private var showingGoingOutSheet = false // New state for Gemini sheet
    @State private var selectedDayIndex = 0
    @State private var selectedHourIndex = 12
    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var hasData = false
    @State private var hasLoadedInitialWeather = false
    
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
                                // Simplified loading view
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
                            
                            // New "Going Out Now" button
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
        // New sheet modifier for the Gemini view
        .sheet(isPresented: $showingGoingOutSheet) {
            GoingOutNowView(currentWeather: apiService.currentWeather)
        }
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

// MARK: - Weather Data View
struct WeatherDataView: View {
    @ObservedObject var apiService: NASAPowerService
    @Binding var selectedDayIndex: Int
    @Binding var selectedHourIndex: Int
    let onPlanNewEvent: () -> Void
    
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
                            DailySummaryView(day: day) // ** NEW GEMINI SUMMARY VIEW **
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
                                Image(systemName: "satellite.fill").font(.largeTitle).padding()
                                Text("Talking with MERRA-2...").fontWeight(.heavy)
                                Spacer()
                            }
                        }
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
}

// MARK: - Cards and Sliders
struct CurrentWeatherWelcomeCard: View {
    let weather: MeteoCurrentWeather
    @State private var dragOffset: CGSize = .zero
    
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
    
    var body: some View {
        ZStack {
            // Background Layer with its own parallax effect
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
                .padding(24)
                
                // Slower parallax
            
            // Foreground Content Layer
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Current Weather").font(.title2.bold()).foregroundColor(.white).offset(x: dragOffset.width * 0.2, y: dragOffset.height * 0.2)
                    Text("Your Location").font(.subheadline).foregroundColor(.white.opacity(0.7)).offset(x: dragOffset.width * 0.15, y: dragOffset.height * 0.15)
                }
                
                Image(systemName: weatherIcon)
                    .font(.system(size: 80)).foregroundStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .orange.opacity(0.3), radius: 10).offset(x: dragOffset.width * 0.4, y: dragOffset.height * 0.4)
                
                VStack(spacing: 4) {
                    Text("\(Int(weather.current.temperature_2m))°F").font(.system(size: 64, weight: .bold)).foregroundColor(.white).offset(x: dragOffset.width * 0.25, y: dragOffset.height * 0.25)
                    Text(weatherDescription).font(.title3).foregroundColor(.white.opacity(0.9)).offset(x: dragOffset.width * 0.2, y: dragOffset.height * 0.2)
                }
                
                HStack(spacing: 40) {
                    VStack(spacing: 8) {
                        Image(systemName: "humidity.fill").font(.title2).foregroundColor(.blue)
                        Text("\(weather.current.relative_humidity_2m)%").font(.headline).foregroundColor(.white)
                        Text("Humidity").font(.caption).foregroundColor(.white.opacity(0.7))
                    }.offset(x: dragOffset.width * 0.3, y: dragOffset.height * 0.3)
                    
                    VStack(spacing: 8) {
                        Image(systemName: "wind").font(.title2).foregroundColor(.cyan)
                        Text("\(Int(weather.current.wind_speed_10m)) mph").font(.headline).foregroundColor(.white)
                        Text("Wind").font(.caption).foregroundColor(.white.opacity(0.7))
                    }.offset(x: dragOffset.width * 0.35, y: dragOffset.height * 0.35)
                    
                    VStack(spacing: 8) {
                        Image(systemName: "drop.fill").font(.title2).foregroundColor(.blue)
                        Text(String(format: "%.2f\"", weather.current.precipitation)).font(.headline).foregroundColor(.white)
                        Text("Rain").font(.caption).foregroundColor(.white.opacity(0.7))
                    }.offset(x: dragOffset.width * 0.4, y: dragOffset.height * 0.4)
                }
            }
            .padding(32)
        }
        .padding(.horizontal, 24)
        .rotation3DEffect(.degrees(dragOffset.width / 20), axis: (x: 0, y: 1, z: 0))
        .rotation3DEffect(.degrees(-dragOffset.height / 20), axis: (x: 1, y: 0, z: 0))
        .gesture(
            DragGesture()
                .onChanged { value in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        dragOffset = value.translation
                    }
                }
                .onEnded { _ in withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { dragOffset = .zero } }
        )
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
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Map(coordinateRegion: $mapLocationManager.region, interactionModes: [.pan, .zoom], annotationItems: annotations) { item in
                    MapMarker(coordinate: item.coordinate, tint: .purple)
                }
                .frame(height: 250)
                .overlay { if isSearching { Color.black.opacity(0.3).ignoresSafeArea(); ProgressView("Searching...").tint(.white).foregroundColor(.white) } }
                
                ScrollView {
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
                        DatePicker("Event Date", selection: $selectedDate, in: Date()..., displayedComponents: .date).datePickerStyle(GraphicalDatePickerStyle()).padding().background(Color.gray.opacity(0.05)).cornerRadius(12)
                        Button(action: { if let coord = selectedCoordinate { onComplete(coord, selectedDate) } }) {
                            Text(isFutureDate() ? "Predict Weather" : "Get Weather").font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding().background(selectedCoordinate == nil ? Color.gray : (isFutureDate() ? Color.purple : Color.blue)).cornerRadius(12)
                        }.disabled(selectedCoordinate == nil)
                    }.padding()
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

// MARK: - Generative AI Views
struct DailySummaryView: View {
    let day: DailyWeatherData
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
            PlanActivityView(dayData: day)
        }
    }
    
    private func generateSummary() {
        isLoading = true
        summary = ""
        Task {
            do {
                let result = try await GeminiService.summarizeDay(dayData: day)
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

struct PlanActivityView: View {
    let dayData: DailyWeatherData
    @State private var userInput: String = ""
    @State private var advice: String = ""
    @State private var isLoadingAdvice: Bool = false
    @State private var showAdvice: Bool = false
    @Environment(\.dismiss) var dismiss
    
    private var daySummary: String {
        let temps = dayData.hourlyData.map { ($0.temperature * 9/5) + 32 }
        let high = temps.max() ?? 0
        let low = temps.min() ?? 0
        return "Forecast for \(dayData.date.formatted(date: .abbreviated, time: .omitted)): High of \(String(format: "%.0f", high))°F, low of \(String(format: "%.0f", low))°F."
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                DynamicGradientBackground(colors: [.blue, .indigo, .purple]).ignoresSafeArea()
                
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text("Plan an Activity").font(.largeTitle.bold()).multilineTextAlignment(.center).foregroundStyle(.white)
                        Text(daySummary).font(.body).multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85)).padding(.horizontal)
                    }.padding(.top, 40)
                    
                    Spacer(minLength: 20)
                    
                    HStack(spacing: 10) {
                        Image(systemName: "pencil.line").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        TextField("e.g., 'Go for a long run'", text: $userInput).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                            .textInputAutocapitalization(.sentences).disableAutocorrection(false)
                    }
                    .padding(.horizontal, 16).frame(height: 56).background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8).shadow(color: .white.opacity(0.12), radius: 4, x: 0, y: 1)
                    .padding(.horizontal, 24)
                    
                    Button {
                        Task {
                            guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            isLoadingAdvice = true; advice = ""
                            defer { isLoadingAdvice = false }
                            do {
                                let result = try await GeminiService.adviseForDay(activity: userInput, dayData: dayData)
                                await MainActor.run { advice = result; showAdvice = true }
                            } catch {
                                await MainActor.run {
                                    advice = "Could not retrieve advice. Please try again."; showAdvice = true
                                }
                                print("Gemini error:", error)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                            Text(isLoadingAdvice ? "Getting Advice..." : "Get Advice").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16).foregroundStyle(.white)
                        .background(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(color: .blue.opacity(0.35), radius: 12, x: 0, y: 6)
                    }
                    .padding(.horizontal, 24).disabled(isLoadingAdvice)
                    
                    Spacer()
                    
                    Button { dismiss() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "xmark.circle.fill"); Text("Close").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16).foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                    .padding(.horizontal, 24).padding(.bottom, 30)
                }
                if isLoadingAdvice {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    ProgressView("Analyzing your plan...").tint(.white).foregroundColor(.white).scaleEffect(1.2)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showAdvice) { AdviceResultView(advice: advice) }
        }
    }
}

struct GoingOutNowView: View {
    let currentWeather: MeteoCurrentWeather?
    @State private var userInput = ""
    @State private var userResponse = ""
    @State private var advice = ""
    @State private var isLoadingAdvice = false
    @State private var showAdvice = false
    @Environment(\.dismiss) var dismiss

    var weatherSummary: String {
        guard let weather = currentWeather else {
            return "Weather data is not available."
        }
        return "\(Int(weather.current.temperature_2m))°F, with wind speeds of \(Int(weather.current.wind_speed_10m)) mph and a \(weather.current.precipitation > 0 ? "chance" : "low chance") of rain."
    }
   

    var body: some View {
        NavigationStack {
            ZStack {
                DynamicGradientBackground(colors: [.pink, .purple, .blue]).ignoresSafeArea()

                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text("Advice Page").font(.largeTitle.bold()).multilineTextAlignment(.center).foregroundStyle(.white)
                        Text("What are you going to do right now?").font(.body).multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85)).padding(.horizontal)
                    }.padding(.top, 40)
                    Spacer(minLength: 20)
                    HStack(spacing: 10) {
                        Image(systemName: "pencil.line").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        TextField("Enter Description...", text: $userInput).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                            .textInputAutocapitalization(.sentences).disableAutocorrection(false)
                    }
                    .padding(.horizontal, 16).frame(height: 56).background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8).shadow(color: .white.opacity(0.12), radius: 4, x: 0, y: 1)
                    .padding(.horizontal, 24)

                    Button {
                        Task {
                            guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  let weather = currentWeather else { return }
                            
                            isLoadingAdvice = true; advice = ""; userResponse = userInput
                            defer { isLoadingAdvice = false }
                            do {
                                let result = try await GeminiService.advise(
                                    activity: userResponse,
                                    weatherSummary: weatherSummary,
                                    latitude: weather.latitude,
                                    longitude: weather.longitude
                                )
                                await MainActor.run { advice = result; showAdvice = true }
                            } catch {
                                await MainActor.run {
                                    advice = "Could not retrieve advice. Please try again."; showAdvice = true
                                }
                                print("Gemini error:", error)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                            Text(isLoadingAdvice ? "Getting Advice..." : "Get Advice").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16).foregroundStyle(.white)
                        .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(color: .purple.opacity(0.35), radius: 12, x: 0, y: 6)
                    }
                    .padding(.horizontal, 24).disabled(isLoadingAdvice)
                    Spacer()
                    Button { dismiss() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "xmark.circle.fill"); Text("Close").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16).foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                    .padding(.horizontal, 24).padding(.bottom, 30)
                }
                if isLoadingAdvice {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    ProgressView("Analyzing your plan...").tint(.white).foregroundColor(.white).scaleEffect(1.2)
                }
            }
            .navigationBarHidden(true).toolbarBackground(.hidden, for: .navigationBar).background(.clear).preferredColorScheme(.dark)
            .navigationDestination(isPresented: $showAdvice) { AdviceResultView(advice: advice) }
        }
    }
}

struct AdviceResultView: View {
    let advice: String
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Your Advice").font(.largeTitle.bold()).foregroundStyle(.white).padding(.top, 8)
                ScrollView {
                    Text(advice).font(.title3).foregroundStyle(.white).multilineTextAlignment(.leading)
                        .lineSpacing(8).fixedSize(horizontal: false, vertical: true).padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8).padding(.horizontal, 20)
                }
                .scrollIndicators(.visible)
                
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.35), lineWidth: 1))
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 12)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct GeminiService {
    static func advise(activity: String, weatherSummary: String, latitude: Double, longitude: Double) async throws -> String {
        let prompt = """
        You are an outdoors advisor. Based on the user's plan, today's weather, and their location (to infer the current time of day),
        give short, helpful, actionable advice (under 100 words). Be constructive and discouraging if absolutely necessary (use time as a factor and account for safety).

        USER PLAN:
        \(activity)

        WEATHER:
        \(weatherSummary)
        
        LOCATION:
        Latitude: \(latitude), Longitude: \(longitude)
        """

        let response = try await geminiModel.generateContent(prompt)
        let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw GeminiError.emptyResponse }
        return text
    }
    
    static func summarizeDay(dayData: DailyWeatherData) async throws -> String {
        guard !dayData.hourlyData.isEmpty else {
            return "Not enough data to generate a summary."
        }
        
        let temps = dayData.hourlyData.map { ($0.temperature * 9/5) + 32 }
        let high = temps.max() ?? 0
        let low = temps.min() ?? 0
        let totalPrecipitation = dayData.totalPrecipitation
        let dateString = dayData.date.formatted(date: .abbreviated, time: .omitted)

        let prompt = """
        You are a friendly weather concierge. Briefly summarize the weather for \(dateString).
        Mention the high of \(String(format: "%.0f", high))°F and the low of \(String(format: "%.0f", low))°F.
        The total precipitation is \(String(format: "%.2f", totalPrecipitation / 25.4)) inches.
        Based ONLY on this weather, suggest 2-3 local activities (like 'visit a museum' or 'go for a hike').
        Be creative and encouraging. Keep the entire response under 75 words.
        """
        
        let response = try await geminiModel.generateContent(prompt)
        let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw GeminiError.emptyResponse }
        return text
    }
    
    static func adviseForDay(activity: String, dayData: DailyWeatherData) async throws -> String {
        guard !dayData.hourlyData.isEmpty else {
            return "Not enough data to generate advice."
        }
        
        let temps = dayData.hourlyData.map { ($0.temperature * 9/5) + 32 }
        let high = temps.max() ?? 0
        let low = temps.min() ?? 0
        let totalPrecipitation = dayData.totalPrecipitation
        let dateString = dayData.date.formatted(date: .abbreviated, time: .omitted)
        
        let prompt = """
        You are an expert event planning assistant.
        A user wants to '\(activity)' on \(dateString).
        The forecast is a high of \(String(format: "%.0f", high))°F, a low of \(String(format: "%.0f", low))°F, with a total precipitation of \(String(format: "%.2f", totalPrecipitation / 25.4)) inches for the day.
        Give short, helpful, and actionable advice for their plan. Be friendly and encouraging.
        Keep the response under 100 words.
        """
        
        let response = try await geminiModel.generateContent(prompt)
        let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw GeminiError.emptyResponse }
        return text
    }
}

// MARK: - Preview & Extensions
#Preview{ ContentView() }

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
