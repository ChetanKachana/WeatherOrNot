import SwiftUI
import MapKit
import Combine
import CoreML
import Charts
import GoogleGenerativeAI

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
                
                VStack {
                    Spacer()
                    Text("Fetching Weather Data...")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .padding(.bottom, 60)
                }
            }
        }
        .onAppear {
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
    
    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        region = MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
        )
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
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
    private let predictor = WeatherPredictor()
    
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
            // Simulate a slightly longer loading time to let the animation play
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
    @State private var showingPlanSheet = false
    @State private var showingGoingOutSheet = false
    @State private var selectedDayIndex = 0
    @State private var selectedHourIndex = 12
    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var hasData = false
    
    var body: some View {
        NavigationView {
            ZStack {
                if !hasData {
                    ZStack {
                        DynamicGradientBackground(colors: [.pink, .purple, .blue])
                        VStack(spacing: 30) {
                            Spacer()
                            Image(systemName: "cloud.sun.fill").font(.system(size: 100)).foregroundStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                            VStack(spacing: 12) {
                                Text("Weather Forecaster").font(.system(size: 36, weight: .bold))
                                Text("Plan your events with AI-powered weather predictions").font(.subheadline).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal)
                            }.colorScheme(.dark); Spacer()
                                Button(action: { print("View Past Events tapped") }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.title3)
                                    Text("View Past Events")
                                        .font(.title3.bold())
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .background(
                                    LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                                )
                                .cornerRadius(16)
                                .shadow(color: .purple.opacity(0.4), radius: 10, x: 0, y: 5)
                            }
                            .padding(.horizontal, 30)
                            Button(action: { showingGoingOutSheet = true }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "figure.walk.circle.fill")
                                        .font(.title3)
                                    Text("Going Outside Right Now?")
                                        .font(.title3.bold())
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .background(
                                    LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
                                )
                                .cornerRadius(16)
                                .shadow(color: .green.opacity(0.4), radius: 10, x: 0, y: 5)
                            }
                            .padding(.horizontal, 30)
                            .sheet(isPresented: $showingGoingOutSheet) {
                                GoingOutNowView()
                            }

                            Button(action: { showingPlanSheet = true }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "calendar.badge.plus").font(.title3)
                                    Text("Plan Event").font(.title3.bold())
                                }
                                .foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 20)
                                .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .cornerRadius(16).shadow(color: .blue.opacity(0.4), radius: 10, x: 0, y: 5)
                            }.padding(.horizontal, 30).padding(.bottom, 50)
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
                            showingPlanSheet = true
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
            DynamicGradientBackground(colors: currentGradientColors)
                .zIndex(0)
            
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
                            HourlyWeatherSlider(hourlyData: day.hourlyData, selectedHourIndex: $selectedHourIndex)
                            TemperatureChartCard(hourlyData: day.hourlyData)
                            PrecipitationChartCard(hourlyData: day.hourlyData)
                            DailyForecastSlider(dailyData: apiService.dailyWeatherData, selectedDayIndex: $selectedDayIndex)
                            
                            Button(action: onPlanNewEvent) {
                                HStack {
                                    Image(systemName: "calendar.badge.plus")
                                    Text("Plan Another Event").font(.headline)
                                }
                                .foregroundColor(.white).frame(maxWidth: .infinity).padding()
                                .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .cornerRadius(12)
                            }
                            .padding(.horizontal).padding(.bottom, 30)
                        }
                    }
                    .padding(.vertical)
                }
                .background(.clear)
                .zIndex(1)
            }
            
            if apiService.isLoading {
                LoadingWaveView()
                    .transition(.opacity.animation(.easeIn(duration: 0.5)))
                    .zIndex(10)
            }
        }
        .colorScheme(.dark)
        .navigationTitle("Weather Forecast")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Cards and Sliders
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
            Text("Hourly Forecast").font(.headline).padding(.horizontal)
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
                    }.padding(.horizontal)
                }.onAppear { proxy.scrollTo(selectedHourIndex, anchor: .center) }
            }
        }
    }
}
struct TemperatureChartCard: View {
    let hourlyData: [HourlyWeatherData]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temperature Trend").font(.headline).padding([.top, .horizontal])
            Chart(hourlyData) { data in
                LineMark(x: .value("Hour", data.hour), y: .value("Temperature", (data.temperature * 9/5) + 32)).foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)).lineStyle(StrokeStyle(lineWidth: 3))
                AreaMark(x: .value("Hour", data.hour), y: .value("Temperature", (data.temperature * 9/5) + 32)).foregroundStyle(LinearGradient(colors: [.orange.opacity(0.3), .red.opacity(0.1)], startPoint: .top, endPoint: .bottom))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }.frame(height: 200).padding().background(Color.gray.opacity(0.05)).cornerRadius(16).padding(.horizontal)
        }
    }
}
struct PrecipitationChartCard: View {
    let hourlyData: [HourlyWeatherData]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Precipitation").font(.headline).padding([.top, .horizontal])
            Chart(hourlyData) { data in
                BarMark(x: .value("Hour", data.hour), y: .value("Precipitation", data.precipitation / 25.4)).foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }.frame(height: 150).padding().background(Color.gray.opacity(0.05)).cornerRadius(16).padding(.horizontal)
        }
    }
}
struct DailyForecastSlider: View {
    let dailyData: [DailyWeatherData]
    @Binding var selectedDayIndex: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("7-Day Forecast").font(.headline).padding(.horizontal)
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
                }.padding(.horizontal)
            }
        }
    }
}

// MARK: - Plan Event Sheet
struct PlanEventSheet: View {
    @StateObject private var locationManager = LocationManager()
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
                Map(coordinateRegion: $locationManager.region, interactionModes: [.pan, .zoom], annotationItems: annotations) { item in
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
                self.locationManager.region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
            }
        }
    }
    
    private func isFutureDate() -> Bool {
        return !Calendar.current.isDateInToday(selectedDate) && selectedDate > Date()
    }
}
struct GoingOutNowView: View {
    @Environment(\.dismiss) var dismiss
    
    // State for user input and the final AI response
    @State private var userInputActivity: String = ""
    @State private var aiSuggestion: String? = nil
    
    // State for managing the view's status
    @State private var isSubmitting = false
    @State private var submissionError: String?
    
    // PLACEHOLDER: You'll replace this with your actual Weather/API data
    // For this example, we'll use hardcoded current weather data
    let currentHourWeather: HourlyWeatherData = HourlyWeatherData(
        id: UUID(),
        hour: Calendar.current.component(.hour, from: Date()),
        temperature: 28.0, // 28°C ≈ 82°F
        precipitation: 0.1, // 0.1 mm/hr (light to none)
        isPrediction: false
    )

    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Text("What are you going to do outside?")
                    .font(.title2)
                    .bold()
                    .padding(.top)

                // 1. Text Editor for user input
                TextEditor(text: $userInputActivity)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                    .padding(.horizontal)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.1))

                // 2. Submit Button
                Button(action: {
                    // Trigger the submission and Gemini call
                    Task { await submitActivity() }
                }) {
                    if isSubmitting {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Text("Get Weather-Ready Suggestion")
                    }
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(userInputActivity.isEmpty || isSubmitting ? Color.gray : Color.green)
                .cornerRadius(10)
                .disabled(userInputActivity.isEmpty || isSubmitting)
                .padding(.horizontal)

                // 3. Display AI Suggestion or Error
                Group {
                    if isSubmitting {
                        Text("Generating tailored suggestion...")
                            .foregroundColor(.gray)
                    } else if let error = submissionError {
                        Text("❌ Error: \(error)").foregroundColor(.red).multilineTextAlignment(.center)
                    } else if let suggestion = aiSuggestion {
                        SuggestionCard(suggestion: suggestion)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical)
            .navigationTitle("Outdoor Planner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // MARK: - Core Submission and AI Call Function
    func submitActivity() async {
        guard !userInputActivity.isEmpty else { return }
        
        // Reset states
        isSubmitting = true
        submissionError = nil
        aiSuggestion = nil
        
        do {
            // 1. Prepare the content for Gemini
            let prompt = buildGeminiPrompt(activity: userInputActivity, weather: currentHourWeather)
            
            // 2. Call the simulated Gemini service
            // *** In your real app, you would replace this line with your actual API call ***
            let response = try await simulateGeminiAPICall(prompt: prompt)
            
            // 3. Update the UI with the AI's suggestion
            self.aiSuggestion = response
        } catch {
            // Handle any network or API errors
            self.submissionError = "Failed to get AI suggestion: \(error.localizedDescription)"
        }
        
        isSubmitting = false
    }
    
    // MARK: - Prompt Builder
    func buildGeminiPrompt(activity: String, weather: HourlyWeatherData) -> String {
        // Convert the temperature to Fahrenheit for a familiar context
        let tempF = (weather.temperature * 9/5) + 32
        let precipIn = weather.precipitation / 25.4

        let prompt = """
        The user is going outside right now. Their planned activity is: **\(activity)**.
        The current weather conditions are:
        - Temperature: \(tempF, specifier: "%.0f")°F (\(weather.temperature, specifier: "%.1f")°C)
        - Precipitation Rate: \(precipIn, specifier: "%.2f") inches/hour (\(weather.precipitation, specifier: "%.1f") mm/hr)

        Based on the activity and the weather conditions, provide a single, friendly, and practical suggestion on what the user should bring or do to stay safe and comfortable. Keep the suggestion concise and directly relevant.
        """
        return prompt
    }
}

// MARK: - Component View for Displaying the Suggestion
struct SuggestionCard: View {
    let suggestion: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("💡 Gemini Suggestion:")
                .font(.headline)
                .foregroundColor(.blue)
            
            Text(suggestion)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
        }
        .padding(.horizontal)
    }
}

// MARK: - API Call Simulation (Replace with your actual Gemini SDK/API code)
enum GeminiError: Error {
    case apiError(String)
}

func callGeminiAPI(prompt: String) async throws -> String {
    let apiKey = "YOUR_API_KEY" // **SECURITY WARNING: Use an environment variable or secure storage!**
    let model = GenerativeModel(name: "gemini-2.5-flash", apiKey: apiKey)

    do {
        let response = try await model.generateContent(prompt)
        return response.text ?? "AI failed to generate a text response."
    } catch {
        throw error
    }
}
#Preview{ ContentView() }
