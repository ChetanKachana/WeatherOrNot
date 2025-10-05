import SwiftUI
import MapKit
import Combine
import CoreML
import Charts

// MARK: - Models
struct PowerAPIResponse: Codable {
    let properties: Properties
    
    struct Properties: Codable {
        let parameter: Parameter
    }
    
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
    // UPDATED: This function now averages historical data instead of using linear regression.
    func predictWeather(historicalData: [HistoricalDataPoint]) -> (temperature: Double, precipitation: Double)? {
        guard !historicalData.isEmpty else { return nil }
        
        let tempSum = historicalData.reduce(0) { $0 + $1.temperature }
        let precipSum = historicalData.reduce(0) { $0 + $1.precipitation }
        
        let count = Double(historicalData.count)
        
        let avgTemp = tempSum / count
        let avgPrecip = precipSum / count
        
        // Ensure precipitation prediction is not negative.
        return (temperature: avgTemp, precipitation: max(0, avgPrecip))
    }
}

// MARK: - API Service
// UPDATED: This class has been refactored for more efficient and reliable data fetching.
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
                    // Using a lock to safely append to the array from multiple threads
                    DispatchQueue.main.async {
                        fetchedDailyData.append(dailyData)
                    }
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            self?.isLoading = false
            self?.dailyWeatherData = fetchedDailyData.sorted { $0.date < $1.date }
            
            if fetchedDailyData.isEmpty {
                self?.errorMessage = "No data available for the selected location and date range. Please try different parameters."
            }
        }
    }
    
    private func fetchDayData(latitude: Double, longitude: Double, date: Date, completion: @escaping (DailyWeatherData?) -> Void) {
        let now = Date()
        
        // Use start of day for comparison to correctly handle the current day
        if Calendar.current.startOfDay(for: date) > Calendar.current.startOfDay(for: now) {
            fetchHistoricalAndPredictDay(latitude: latitude, longitude: longitude, targetDate: date, completion: completion)
        } else {
            fetchActualDayData(latitude: latitude, longitude: longitude, date: date, completion: completion)
        }
    }
    
    private func fetchActualDayData(latitude: Double, longitude: Double, date: Date, completion: @escaping (DailyWeatherData?) -> Void) {
        fetchHourlyDataForSingleDay(latitude: latitude, longitude: longitude, date: date) { response in
            guard let decoded = response else {
                completion(nil)
                return
            }
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd"
            let dateString = dateFormatter.string(from: date)
            
            var hourlyData: [HourlyWeatherData] = []
            
            for hour in 0..<24 {
                let hourString = String(format: "%02d", hour)
                let hourlyKey = dateString + hourString
                
                if let temp = decoded.properties.parameter.T2M?[hourlyKey],
                   let precip = decoded.properties.parameter.PRECTOTCORR?[hourlyKey],
                   temp != -999, precip != -999 {
                    hourlyData.append(HourlyWeatherData(hour: hour, temperature: temp, precipitation: precip, isPrediction: false))
                }
            }
            
            guard !hourlyData.isEmpty else {
                completion(nil)
                return
            }
            
            let avgTemp = hourlyData.map { $0.temperature }.reduce(0, +) / Double(hourlyData.count)
            let totalPrecip = hourlyData.map { $0.precipitation }.reduce(0, +)
            
            let dailyData = DailyWeatherData(date: date, avgTemperature: avgTemp, totalPrecipitation: totalPrecip, hourlyData: hourlyData, isPrediction: false)
            completion(dailyData)
        }
    }
    
    private func fetchHistoricalAndPredictDay(latitude: Double, longitude: Double, targetDate: Date, completion: @escaping (DailyWeatherData?) -> Void) {
        let calendar = Calendar.current
        let targetComponents = calendar.dateComponents([.year, .month, .day], from: targetDate)
        
        var yearsToFetch: [Int] = []
        for i in 1...5 { // Fetch last 5 years of data for averaging
            if let year = targetComponents.year {
                yearsToFetch.append(year - i)
            }
        }
        
        let group = DispatchGroup()
        var historicalResponses = [Int: PowerAPIResponse]()
        let lock = NSLock()

        for year in yearsToFetch {
            var historicalComponents = targetComponents
            historicalComponents.year = year
            guard let historicalDate = calendar.date(from: historicalComponents) else { continue }
            
            group.enter()
            fetchHourlyDataForSingleDay(latitude: latitude, longitude: longitude, date: historicalDate) { response in
                if let response = response {
                    lock.lock()
                    historicalResponses[year] = response
                    lock.unlock()
                }
                group.leave()
            }
        }
        
        group.notify(queue: .global()) {
            var hourlyPredictions: [HourlyWeatherData] = []
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd"

            for hour in 0..<24 {
                var historicalDataForHour: [HistoricalDataPoint] = []
                
                for year in yearsToFetch {
                    guard let response = historicalResponses[year] else { continue }
                    
                    var historicalComponents = targetComponents
                    historicalComponents.year = year
                    guard let historicalDate = calendar.date(from: historicalComponents) else { continue }
                    
                    let dateString = dateFormatter.string(from: historicalDate)
                    let hourString = String(format: "%02d", hour)
                    let hourlyKey = dateString + hourString
                    
                    if let temp = response.properties.parameter.T2M?[hourlyKey],
                       let precip = response.properties.parameter.PRECTOTCORR?[hourlyKey],
                       temp != -999, precip != -999 {
                        historicalDataForHour.append(HistoricalDataPoint(year: year, temperature: temp, precipitation: precip))
                    }
                }
                
                if let prediction = self.predictor.predictWeather(historicalData: historicalDataForHour) {
                    hourlyPredictions.append(HourlyWeatherData(hour: hour, temperature: prediction.temperature, precipitation: prediction.precipitation, isPrediction: true))
                }
            }
            
            // Switch to main thread to call completion
            DispatchQueue.main.async {
                guard !hourlyPredictions.isEmpty else {
                    completion(nil)
                    return
                }
                
                hourlyPredictions.sort { $0.hour < $1.hour }
                
                let avgTemp = hourlyPredictions.map { $0.temperature }.reduce(0, +) / Double(hourlyPredictions.count)
                let totalPrecip = hourlyPredictions.map { $0.precipitation }.reduce(0, +)
                
                let dailyData = DailyWeatherData(date: targetDate, avgTemperature: avgTemp, totalPrecipitation: totalPrecip, hourlyData: hourlyPredictions, isPrediction: true)
                completion(dailyData)
            }
        }
    }
    
    // This new, efficient function fetches all hourly data for a single day in one API call.
    private func fetchHourlyDataForSingleDay(latitude: Double, longitude: Double, date: Date, completion: @escaping (PowerAPIResponse?) -> Void) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateString = dateFormatter.string(from: date)
        
        let urlString = "https://power.larc.nasa.gov/api/temporal/hourly/point?parameters=T2M,PRECTOTCORR&community=RE&longitude=\(longitude)&latitude=\(latitude)&start=\(dateString)&end=\(dateString)&format=JSON"
        
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }
            
            do {
                let decoded = try JSONDecoder().decode(PowerAPIResponse.self, from: data)
                completion(decoded)
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
    @State private var selectedDayIndex = 0
    @State private var selectedHourIndex = 12
    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var hasData = false
    
    var body: some View {
        NavigationView {
            ZStack {
                if !hasData {
                    // Welcome screen
                    VStack(spacing: 30) {
                        Spacer()
                        
                        Image(systemName: "cloud.sun.fill")
                            .font(.system(size: 100))
                            .foregroundStyle(
                                LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        
                        VStack(spacing: 12) {
                            Text("Weather Forecaster")
                                .font(.system(size: 36, weight: .bold))
                                Spacer()
                            Text("Plan your events with AI-powered weather predictions")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        
                        Spacer()
                        
                        Button(action: { showingPlanSheet = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.title3)
                                Text("Plan Event")
                                    .font(.title3.bold())
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(
                                LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(16)
                            .shadow(color: .blue.opacity(0.4), radius: 10, x: 0, y: 5)
                        }
                        .padding(.horizontal, 30)
                        .padding(.bottom, 50)
                    }
                } else {
                    // Weather data view
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
            .navigationBarHidden(!hasData)
        }
        .sheet(isPresented: $showingPlanSheet) {
            PlanEventSheet(
                selectedLocation: $selectedLocation,
                onComplete: { location, date in
                    selectedLocation = location
                    // Reset indices when fetching new data
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
        guard !apiService.dailyWeatherData.isEmpty, selectedDayIndex < apiService.dailyWeatherData.count else {
            return nil
        }
        return apiService.dailyWeatherData[selectedDayIndex]
    }
    
    var currentHour: HourlyWeatherData? {
        guard let day = currentDay, !day.hourlyData.isEmpty, selectedHourIndex < day.hourlyData.count else {
            return nil
        }
        return day.hourlyData[selectedHourIndex]
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if apiService.isLoading {
                    ProgressView("Loading weather data...")
                        .padding(40)
                } else if let error = apiService.errorMessage {
                    VStack(spacing: 20) {
                        Text("Error")
                            .font(.title.bold())
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button("Plan a New Event", action: onPlanNewEvent)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(40)

                } else if let day = currentDay {
                    // Current weather card
                    CurrentWeatherCard(day: day, hour: currentHour)
                    
                    // Hourly slider
                    HourlyWeatherSlider(
                        hourlyData: day.hourlyData,
                        selectedHourIndex: $selectedHourIndex
                    )
                    
                    // Temperature chart
                    TemperatureChartCard(hourlyData: day.hourlyData)
                    
                    // Precipitation chart
                    PrecipitationChartCard(hourlyData: day.hourlyData)
                    
                    // Daily forecast slider
                    DailyForecastSlider(
                        dailyData: apiService.dailyWeatherData,
                        selectedDayIndex: $selectedDayIndex
                    )
                    
                    // Plan new event button
                    Button(action: onPlanNewEvent) {
                        HStack {
                            Image(systemName: "calendar.badge.plus")
                            Text("Plan Another Event")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 30)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Weather Forecast")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Current Weather Card
struct CurrentWeatherCard: View {
    let day: DailyWeatherData
    let hour: HourlyWeatherData?
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.date, style: .date)
                        .font(.title2.bold())
                    if let hour = hour {
                        Text(String(format: "%02d:00", hour.hour))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
                if day.isPrediction {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Predicted")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.purple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(20)
                }
            }
            
            HStack(alignment: .top, spacing: 40) {
                VStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    
                    if let hour = hour {
                        Text("\((hour.temperature * 9/5) + 32, specifier: "%.0f")°F")
                            .font(.system(size: 48, weight: .bold))
                        Text("\(hour.temperature, specifier: "%.1f")°C")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                
                VStack(spacing: 8) {
                    Image(systemName: "cloud.rain.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    
                    if let hour = hour {
                        Text("\(hour.precipitation / 25.4, specifier: "%.2f")\"")
                            .font(.system(size: 48, weight: .bold))
                        Text("\(hour.precipitation, specifier: "%.1f") mm")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        )
        .padding(.horizontal)
    }
}

// MARK: - Hourly Weather Slider
struct HourlyWeatherSlider: View {
    let hourlyData: [HourlyWeatherData]
    @Binding var selectedHourIndex: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hourly Forecast")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(hourlyData.enumerated()), id: \.element.id) { index, data in
                            VStack(spacing: 8) {
                                Text(String(format: "%02d:00", data.hour))
                                    .font(.caption.bold())
                                Image(systemName: data.precipitation > 1 ? "cloud.rain.fill" : "sun.max.fill")
                                    .foregroundColor(data.precipitation > 1 ? .blue : .orange)
                                Text("\((data.temperature * 9/5) + 32, specifier: "%.0f")°")
                                    .font(.subheadline.bold())
                            }
                            .frame(width: 60)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedHourIndex == index ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                            )
                            .id(index)
                            .onTapGesture {
                                withAnimation {
                                    selectedHourIndex = index
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .onAppear {
                    proxy.scrollTo(selectedHourIndex, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Temperature Chart Card
struct TemperatureChartCard: View {
    let hourlyData: [HourlyWeatherData]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temperature Trend")
                .font(.headline)
                .padding([.top, .horizontal])
            
            Chart(hourlyData) { data in
                LineMark(
                    x: .value("Hour", data.hour),
                    y: .value("Temperature", (data.temperature * 9/5) + 32)
                )
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                )
                .lineStyle(StrokeStyle(lineWidth: 3))
                
                AreaMark(
                    x: .value("Hour", data.hour),
                    y: .value("Temperature", (data.temperature * 9/5) + 32)
                )
                .foregroundStyle(
                    LinearGradient(colors: [.orange.opacity(0.3), .red.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                )
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8))
            }
            .frame(height: 200)
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(16)
            .padding(.horizontal)
        }
    }
}

// MARK: - Precipitation Chart Card
struct PrecipitationChartCard: View {
    let hourlyData: [HourlyWeatherData]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Precipitation")
                .font(.headline)
                .padding([.top, .horizontal])
            
            Chart(hourlyData) { data in
                BarMark(
                    x: .value("Hour", data.hour),
                    y: .value("Precipitation", data.precipitation / 25.4)
                )
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom)
                )
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8))
            }
            .frame(height: 150)
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(16)
            .padding(.horizontal)
        }
    }
}

// MARK: - Daily Forecast Slider
struct DailyForecastSlider: View {
    let dailyData: [DailyWeatherData]
    @Binding var selectedDayIndex: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("7-Day Forecast")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(dailyData.enumerated()), id: \.element.id) { index, data in
                        VStack(spacing: 8) {
                            Text(data.date, format: .dateTime.weekday(.abbreviated))
                                .font(.caption.bold())
                            Text(data.date, format: .dateTime.month().day())
                                .font(.caption2)
                                .foregroundColor(.gray)
                            
                            Image(systemName: data.totalPrecipitation > 5 ? "cloud.rain.fill" : "sun.max.fill")
                                .font(.title3)
                                .foregroundColor(data.totalPrecipitation > 5 ? .blue : .orange)
                            
                            Text("\((data.avgTemperature * 9/5) + 32, specifier: "%.0f")°")
                                .font(.headline)
                            
                            if data.isPrediction {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundColor(.purple)
                            }
                        }
                        .frame(width: 80)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(selectedDayIndex == index ? Color.purple.opacity(0.2) : Color.gray.opacity(0.1))
                        )
                        .onTapGesture {
                            withAnimation {
                                selectedDayIndex = index
                            }
                        }
                    }
                }
                .padding(.horizontal)
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
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Map
                // UPDATED: Replaced the gesture with a more robust DragGesture to reliably capture tap locations.
                MapReader { proxy in
                    Map(coordinateRegion: $locationManager.region,
                        interactionModes: .all,
                        annotationItems: annotations) { item in
                        MapMarker(coordinate: item.coordinate, tint: .purple)
                    }
                    .overlay(alignment: .topTrailing) {
                        Text("Tap map to select location")
                            .font(.caption)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                if let coordinate = proxy.convert(value.location, from: .local) {
                                    updateAnnotation(to: coordinate)
                                }
                            }
                    )
                }
                .frame(height: 300)
                
                
                ScrollView {
                    VStack(spacing: 20) {
                        if let coord = selectedCoordinate {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Selected Location")
                                    .font(.headline)
                                Text("Lat: \(coord.latitude, specifier: "%.4f"), Lon: \(coord.longitude, specifier: "%.4f")")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                        } else {
                            Text("Select a location on the map")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(12)
                        }
                        
                        DatePicker("Event Date", selection: $selectedDate, in: Date()..., displayedComponents: .date)
                            .datePickerStyle(GraphicalDatePickerStyle())
                            .padding()
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(12)
                        
                        Button(action: {
                            if let coord = selectedCoordinate {
                                onComplete(coord, selectedDate)
                            }
                        }) {
                            Text(isFutureDate() ? "Predict Weather" : "Get Weather")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(selectedCoordinate == nil ? Color.gray : (isFutureDate() ? Color.purple : Color.blue))
                                .cornerRadius(12)
                        }
                        .disabled(selectedCoordinate == nil)
                    }
                    .padding()
                }
            }
            .navigationTitle("Plan Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func updateAnnotation(to coordinate: CLLocationCoordinate2D) {
        let clampedLat = max(-90, min(90, coordinate.latitude))
        let clampedLon = max(-180, min(180, coordinate.longitude))
        let finalCoordinate = CLLocationCoordinate2D(latitude: clampedLat, longitude: clampedLon)
        
        selectedCoordinate = finalCoordinate
        annotations = [IdentifiableCoordinate(coordinate: finalCoordinate)]
    }
    
    private func isFutureDate() -> Bool {
        return !Calendar.current.isDateInToday(selectedDate) && selectedDate > Date()
    }
}
