import DigestionInsightsEngine
import Foundation

// Synthetic users for the simulation study (B12). A user eats meals from a
// small food world, logs them with some diligence, gets symptoms from a
// baseline rate plus at most one planted trigger, and logs most of them.
// The generator knows the truth (every meal eaten, every symptom felt); the
// engine only sees what the user logged, as in the app.
//
// Every rate below is an assumption chosen to look like a plausible app
// user, not a measured value. results.md lists them.

/// 2026-01-05 00:00 UTC, a Monday. Day 0 of every synthetic tracking period.
public let simulationDay0 = Date(timeIntervalSince1970: 1_767_571_200)

public enum LoggingDiligence: String, Codable, CaseIterable, Sendable {
    case careful, typical, sloppy

    public var profile: DiligenceProfile {
        switch self {
        case .careful:
            return DiligenceProfile(missedDayRate: 0.01, missedMealRate: 0.03, missedSymptomRate: 0.05,
                                    timeJitterHours: 0.25, lateLogRate: 0.02, lateLogMaxHours: 2)
        case .typical:
            return DiligenceProfile(missedDayRate: 0.04, missedMealRate: 0.10, missedSymptomRate: 0.15,
                                    timeJitterHours: 0.5, lateLogRate: 0.10, lateLogMaxHours: 3)
        case .sloppy:
            return DiligenceProfile(missedDayRate: 0.12, missedMealRate: 0.25, missedSymptomRate: 0.35,
                                    timeJitterHours: 1.0, lateLogRate: 0.25, lateLogMaxHours: 4)
        }
    }
}

public struct DiligenceProfile: Codable, Sendable, Equatable {
    /// Whole day without any meal log (day not observed, B3).
    public var missedDayRate: Double
    /// Single meal eaten but not logged (exposure hidden, effect still real).
    public var missedMealRate: Double
    /// Symptom felt but not logged (counts as symptom-free on observed days).
    public var missedSymptomRate: Double
    /// SD (hours) of logged meal time and symptom onset around the truth.
    public var timeJitterHours: Double
    /// Meal logged later without fixing the time: shifted by U(1, max) hours.
    public var lateLogRate: Double
    public var lateLogMaxHours: Double
}

/// Lag window during which a planted trigger multiplies one kind's rate.
public enum LagKernel: String, Codable, CaseIterable, Sendable {
    case fast, medium, slow

    /// [lower, upper) hours after the meal.
    public var hours: Range<Double> {
        switch self {
        case .fast: return 1..<4
        case .medium: return 4..<12
        case .slow: return 24..<60
        }
    }

    /// Lag where half of the excess has occurred (box kernel: midpoint).
    public var medianLagHours: Double { (hours.lowerBound + hours.upperBound) / 2 }
}

public struct PlantedTrigger: Codable, Sendable, Equatable {
    public var featureID: String
    public var kind: String
    public var kernel: LagKernel
    /// Rate ratio while one exposure is inside the kernel window; overlapping
    /// exposures multiply (the engine's log-linear form).
    public var multiplier: Double

    public init(featureID: String, kind: String, kernel: LagKernel, multiplier: Double) {
        self.featureID = featureID
        self.kind = kind
        self.kernel = kernel
        self.multiplier = multiplier
    }
}

public struct UserSpec: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var diligence: LoggingDiligence
    public var trigger: PlantedTrigger?
    /// Calendar days generated after day 0 (enough to reach the largest
    /// horizon in logged days).
    public var calendarDays: Int

    public init(seed: UInt64, diligence: LoggingDiligence, trigger: PlantedTrigger?, calendarDays: Int) {
        self.seed = seed
        self.diligence = diligence
        self.trigger = trigger
        self.calendarDays = calendarDays
    }
}

/// Meal slots of a day.
enum MealSlot: CaseIterable {
    case breakfast, lunch, snack, dinner
}

/// One food (= one engine feature) of the synthetic food world.
struct Food {
    var id: String
    /// Allergen-type features get L1 (1.0) from barcode data (B7).
    var isAllergen: Bool
    /// Base probability per slot, before the user's own taste factor.
    var probability: (MealSlot, _ weekday: Int) -> Double
}

/// The food world shared by all users. Weekday 0 = Monday.
public enum FoodWorld {
    public static let kinds = ["abdominalPain", "bloating", "diarrhoea"]

    public static let garlic = "ingredient:en:garlic"
    public static let onion = "ingredient:en:onion"
    public static let milk = "allergen:en:milk"
    public static let legume = "group:en:legume"
    public static let coffee = "ingredient:en:coffee"
    public static let gluten = "allergen:en:gluten"
    public static let cheese = "ingredient:en:cheese"

    /// Trigger foods cycled across planted users: co-eaten pair member,
    /// occasional food, staple.
    public static let triggerFoods = [garlic, legume, milk]

    /// Co-eaten partner of a trigger food, if any (false-hit check).
    public static func partner(of feature: String) -> String? {
        feature == garlic ? onion : nil
    }

    static func weekend(_ weekday: Int) -> Bool { weekday >= 5 }

    static let foods: [Food] = [
        Food(id: gluten, isAllergen: true) { slot, _ in
            switch slot { case .breakfast: 0.8; case .lunch: 0.6; case .snack: 0.3; case .dinner: 0.3 }
        },
        Food(id: coffee, isAllergen: false) { slot, _ in
            switch slot { case .breakfast: 0.9; case .snack: 0.4; default: 0.05 }
        },
        // Milk: drawn separately (with coffee, or in cheese); base here is "milk without coffee".
        Food(id: milk, isAllergen: true) { _, _ in 0.12 },
        Food(id: cheese, isAllergen: false) { slot, _ in
            switch slot { case .breakfast: 0.2; case .lunch: 0.25; case .snack: 0.1; case .dinner: 0.2 }
        },
        // Garlic; onion is drawn with it (co-eaten pair).
        Food(id: garlic, isAllergen: false) { slot, _ in
            switch slot { case .lunch: 0.25; case .dinner: 0.3; default: 0 }
        },
        Food(id: onion, isAllergen: false) { slot, _ in
            switch slot { case .lunch, .dinner: 0.12; default: 0 }
        },
        Food(id: "alcohol", isAllergen: false) { slot, weekday in
            guard slot == .dinner else { return 0 }
            return weekday == 4 || weekday == 5 ? 0.6 : 0.05
        },
        Food(id: "allergen:en:fish", isAllergen: true) { slot, weekday in
            guard slot == .dinner || slot == .lunch else { return 0 }
            return weekday == 4 && slot == .dinner ? 0.7 : 0.03
        },
        Food(id: "allergen:en:eggs", isAllergen: true) { slot, weekday in
            switch slot {
            case .breakfast: weekend(weekday) ? 0.6 : 0.25
            default: 0.08
            }
        },
        Food(id: "ingredient:en:tomato", isAllergen: false) { slot, _ in
            switch slot { case .lunch, .dinner: 0.3; default: 0.02 }
        },
        Food(id: "ingredient:en:apple", isAllergen: false) { slot, _ in
            switch slot { case .snack: 0.4; case .breakfast: 0.15; default: 0.02 }
        },
        Food(id: legume, isAllergen: false) { slot, _ in
            switch slot { case .lunch, .dinner: 0.15; default: 0 }
        },
        Food(id: "allergen:en:nuts", isAllergen: true) { slot, _ in
            switch slot { case .snack: 0.2; case .breakfast: 0.1; default: 0.02 }
        },
        Food(id: "ingredient:en:rice", isAllergen: false) { slot, _ in
            switch slot { case .lunch, .dinner: 0.2; default: 0 }
        },
        Food(id: "ingredient:en:chocolate", isAllergen: false) { slot, weekday in
            switch slot { case .snack: weekend(weekday) ? 0.4 : 0.25; case .dinner: 0.05; default: 0.02 }
        },
    ]

    public static var featureIDs: [String] { foods.map(\.id) }
}

/// Where a logged meal's ingredient data came from (B7 evidence levels).
enum ProfileKind {
    /// Open Food Facts, ingredients complete: allergens L1, ingredients L2.
    case barcodeComplete
    /// Open Food Facts, ingredients incomplete: allergens L1, ingredients L3, some missed.
    case barcodeIncomplete
    /// Photo AI: everything L3, missed and false detections.
    case photo
    /// No profile: meal marks the day observed, no exposures (B5).
    case none
}

/// Profile mix and misdetection rates (assumptions, see results.md).
public enum EvidenceModel {
    public static let barcodeCompleteShare = 0.25
    public static let barcodeIncompleteShare = 0.10
    public static let photoShare = 0.55
    // remaining 0.10: no profile
    public static let incompleteMissRate = 0.15
    public static let photoMissRate = 0.25
    /// Per absent food per photo meal.
    public static let photoFalseRate = 0.02
    public static let level1 = 1.0
    public static let level2 = 0.85
    public static let level3 = 0.5
}

/// Generated user: truth and what the user logged.
public struct SyntheticUser: Sendable {
    public struct Meal: Sendable {
        public var trueTime: Double      // hours after day 0
        public var foods: Set<String>
        public var logged: Bool
        public var loggedTime: Double
        /// Logged exposures (feature, evidence value); empty for unlogged meals.
        public var exposures: [(String, Double)]
    }

    public struct Symptom: Sendable {
        public var kind: String
        public var trueTime: Double
        public var logged: Bool
        public var loggedTime: Double
    }

    public let spec: UserSpec
    public let meals: [Meal]
    public let symptoms: [Symptom]
    /// Baseline symptoms per day, per kind (in `FoodWorld.kinds` order).
    public let baselinePerDay: [Double]
    /// Days ≥ 0 with at least one logged meal (B3 observed days), ascending.
    public let loggedDays: [Int]

    /// Days of history before day 0 (B3: meals from 96 h before the period).
    public static let historyDays = 4

    public init(spec: UserSpec) {
        self.spec = spec
        var rng = Xoshiro256StarStar(seed: spec.seed)
        let diligence = spec.diligence.profile

        // The user's own taste: each food's frequency scaled by a log-normal factor.
        var taste: [String: Double] = [:]
        for food in FoodWorld.foods { taste[food.id] = exp(0.3 * rng.standardNormal()) }

        // Baseline symptom rate: 0.2–0.8 per day in total, split across kinds.
        let total = rng.uniform(in: 0.2, 0.8)
        let shares = [0.4, 0.35, 0.25]
        baselinePerDay = shares.map { total * $0 }

        // Meals.
        var meals: [Meal] = []
        var dayLogged = [Int: Bool]()
        for day in -Self.historyDays..<spec.calendarDays {
            let weekday = ((day % 7) + 7) % 7
            let missedDay = rng.uniform() < diligence.missedDayRate
            let mealCount: Int = {
                let u = rng.uniform()
                return u < 0.2 ? 2 : (u < 0.75 ? 3 : 4)
            }()
            var slots: [MealSlot] = [.breakfast, .lunch, .dinner]
            if mealCount == 2 { slots = rng.uniform() < 0.5 ? [.breakfast, .dinner] : [.lunch, .dinner] }
            if mealCount == 4 { slots = [.breakfast, .lunch, .snack, .dinner] }
            let shift = FoodWorld.weekend(weekday) ? 1.0 : 0.0
            for slot in slots {
                let centre: Double
                switch slot {
                case .breakfast: centre = 7.5
                case .lunch: centre = 12.75
                case .snack: centre = 16
                case .dinner: centre = 19
                }
                let trueTime = Double(day) * 24 + centre + shift + 0.6 * rng.standardNormal()
                var foods = Set<String>()
                for food in FoodWorld.foods {
                    let p = min(0.95, food.probability(slot, weekday) * taste[food.id]!)
                    if rng.uniform() < p { foods.insert(food.id) }
                }
                // Co-eaten and nested foods.
                if foods.contains(FoodWorld.garlic), rng.uniform() < 0.85 { foods.insert(FoodWorld.onion) }
                if foods.contains(FoodWorld.coffee), rng.uniform() < 0.7 { foods.insert(FoodWorld.milk) }
                if foods.contains(FoodWorld.cheese) { foods.insert(FoodWorld.milk) }

                let logged = !missedDay && rng.uniform() >= diligence.missedMealRate
                var loggedTime = trueTime + diligence.timeJitterHours * rng.standardNormal()
                if rng.uniform() < diligence.lateLogRate {
                    loggedTime += rng.uniform(in: 1, diligence.lateLogMaxHours)
                }
                var exposures: [(String, Double)] = []
                if logged {
                    exposures = Self.detect(foods: foods, rng: &rng)
                    dayLogged[Int((loggedTime / 24).rounded(.down))] = true
                }
                meals.append(Meal(trueTime: trueTime, foods: foods, logged: logged, loggedTime: loggedTime, exposures: exposures))
            }
        }
        self.meals = meals
        loggedDays = dayLogged.keys.filter { $0 >= 0 && $0 < spec.calendarDays }.sorted()

        // Symptoms: hourly Poisson with mild time-of-day variation, trigger
        // multiplier for every true exposure (logged or not) in the kernel.
        let triggerTimes = spec.trigger.map { trigger in
            meals.filter { $0.foods.contains(trigger.featureID) }.map(\.trueTime)
        } ?? []
        var symptoms: [Symptom] = []
        var nextTrigger = 0
        for hour in 0..<(spec.calendarDays * 24) {
            let centre = Double(hour) + 0.5
            let hourOfDay = Double(hour % 24) + 0.5
            let tod = 1 + 0.3 * sin(2 * Double.pi * (hourOfDay - 9) / 24)
            var active = 0
            if let trigger = spec.trigger {
                while nextTrigger < triggerTimes.count, centre - triggerTimes[nextTrigger] >= trigger.kernel.hours.upperBound {
                    nextTrigger += 1
                }
                var i = nextTrigger
                while i < triggerTimes.count, triggerTimes[i] <= centre {
                    if trigger.kernel.hours.contains(centre - triggerTimes[i]) { active += 1 }
                    i += 1
                }
            }
            for (s, kind) in FoodWorld.kinds.enumerated() {
                var rate = baselinePerDay[s] / 24 * tod
                if let trigger = spec.trigger, trigger.kind == kind, active > 0 {
                    rate *= pow(trigger.multiplier, Double(active))
                }
                for _ in 0..<poisson(rate, &rng) {
                    let trueTime = Double(hour) + rng.uniform()
                    // Symptoms on days without meal logs fall outside the
                    // observation windows (B3), whether logged or not.
                    let logged = rng.uniform() >= diligence.missedSymptomRate
                    let loggedTime = trueTime + diligence.timeJitterHours * rng.standardNormal()
                    symptoms.append(Symptom(kind: kind, trueTime: trueTime, logged: logged, loggedTime: loggedTime))
                }
            }
        }
        self.symptoms = symptoms
    }

    /// Logged exposures for a meal (B7 evidence levels and misdetection).
    static func detect(foods: Set<String>, rng: inout Xoshiro256StarStar) -> [(String, Double)] {
        let u = rng.uniform()
        let kind: ProfileKind
        if u < EvidenceModel.barcodeCompleteShare {
            kind = .barcodeComplete
        } else if u < EvidenceModel.barcodeCompleteShare + EvidenceModel.barcodeIncompleteShare {
            kind = .barcodeIncomplete
        } else if u < EvidenceModel.barcodeCompleteShare + EvidenceModel.barcodeIncompleteShare + EvidenceModel.photoShare {
            kind = .photo
        } else {
            kind = .none
        }
        var result: [(String, Double)] = []
        for food in FoodWorld.foods {
            let present = foods.contains(food.id)
            switch kind {
            case .none:
                continue
            case .barcodeComplete:
                if present { result.append((food.id, food.isAllergen ? EvidenceModel.level1 : EvidenceModel.level2)) }
            case .barcodeIncomplete:
                if present {
                    if food.isAllergen {
                        result.append((food.id, EvidenceModel.level1))
                    } else if rng.uniform() >= EvidenceModel.incompleteMissRate {
                        result.append((food.id, EvidenceModel.level3))
                    }
                }
            case .photo:
                if present {
                    if rng.uniform() >= EvidenceModel.photoMissRate { result.append((food.id, EvidenceModel.level3)) }
                } else if rng.uniform() < EvidenceModel.photoFalseRate {
                    result.append((food.id, EvidenceModel.level3))
                }
            }
        }
        return result
    }

    /// Engine input after `loggedDayCount` logged days: everything the user
    /// logged up to the end of that day; observation windows = logged days.
    /// Nil when the user has fewer logged days.
    public func input(loggedDayCount: Int, config: AnalysisConfig) -> AnalysisInput? {
        guard loggedDayCount >= 1, loggedDays.count >= loggedDayCount else { return nil }
        let days = Array(loggedDays.prefix(loggedDayCount))
        let endHour = Double(days.last! + 1) * 24
        func date(_ hours: Double) -> Date { simulationDay0.addingTimeInterval(hours * 3600) }

        var windows: [ObservationWindow] = []
        var runStart = days[0], previous = days[0]
        for day in days.dropFirst() {
            if day != previous + 1 {
                windows.append(ObservationWindow(start: date(Double(runStart) * 24), end: date(Double(previous + 1) * 24)))
                runStart = day
            }
            previous = day
        }
        windows.append(ObservationWindow(start: date(Double(runStart) * 24), end: date(Double(previous + 1) * 24)))

        var exposures: [ExposureEvent] = []
        for meal in meals where meal.logged && meal.loggedTime < endHour {
            for (feature, value) in meal.exposures {
                exposures.append(ExposureEvent(featureID: feature, time: date(meal.loggedTime), value: value))
            }
        }
        let symptomEvents = symptoms
            .filter { $0.logged && $0.loggedTime >= 0 && $0.loggedTime < endHour }
            .map { SymptomEvent(kind: $0.kind, onset: date($0.loggedTime), levelRank: 0, isTopLevel: false) }
        return AnalysisInput(
            exposures: exposures,
            symptoms: symptomEvents,
            windows: windows,
            symptomKinds: FoodWorld.kinds,
            config: config
        )
    }
}

/// Poisson draw: Knuth's method, split into chunks of at most 30 for large
/// rates (sum of Poissons is Poisson), so exp(−λ) never underflows.
func poisson(_ lambda: Double, _ rng: inout Xoshiro256StarStar) -> Int {
    var remaining = lambda
    var total = 0
    while remaining > 0 {
        let chunk = min(remaining, 30)
        remaining -= chunk
        let limit = exp(-chunk)
        var product = rng.uniform()
        while product > limit {
            total += 1
            product *= rng.uniform()
        }
    }
    return total
}
