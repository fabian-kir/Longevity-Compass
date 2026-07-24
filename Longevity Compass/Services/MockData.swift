#if DEBUG
import Foundation
import HealthKit
import IntervalEngine
import SwiftData

/// One believable "strong but improvable" 34-year-old male profile, used to populate
/// every screen for screenshots and UI work without needing real HealthKit history.
/// Pure synthetic data — nothing here calls HealthKit or persists to the on-disk store
/// (the app uses an in-memory `ModelContainer` when `MockMode.isActive`).
enum MockData {

    private static let now = Date()
    private static let cal = Calendar.current
    private static func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now) ?? now }
    private static func hoursAgo(_ h: Int) -> Date { cal.date(byAdding: .hour, value: -h, to: now) ?? now }
    private static func yearsAgo(_ y: Int) -> Date { cal.date(byAdding: .year, value: -y, to: now) ?? now }

    // MARK: - HealthKit snapshot

    static func snapshot() -> HealthKitSnapshot {
        var s = HealthKitSnapshot()
        s.dateOfBirth = yearsAgo(34)
        s.biologicalSex = .male

        s.dailyStepsAverage7d = 11_200
        s.dailyStepsAverage28d = 10_400
        s.exerciseMinutesPerWeek = 290
        s.exerciseMinutesPriorWeek = 250
        s.workoutsLast7Days = 5
        s.workoutsLast28Days = 16
        s.strengthWorkoutsLast7Days = 4
        s.strengthWorkoutsLast28Days = 12

        s.restingHeartRateAverage28d = 53
        s.restingHeartRateAverage90d = 55
        s.restingHeartRateSeries = series(days: 120, from: 58, to: 52, noise: 1.6, step: 4)

        s.hrvAverage28d = 62
        s.hrvSampleCount28d = 26
        s.hrvSamples = hrvSamples()

        s.sleepHoursAverage7d = 7.3
        s.sleepHoursAverage28d = 7.1

        s.latestBodyMass = (value: 77.5, date: daysAgo(1))
        s.bodyMassSeries = series(days: 180, from: 79.5, to: 77.5, noise: 0.4, step: 12)

        s.latestVO2Max = (value: 49, date: daysAgo(18))
        s.vo2MaxSeries = series(days: 360, from: 44, to: 49, noise: 0.6, step: 30)

        s.bloodPressureReadings = bloodPressureReadings()

        s.sampledAt = .now
        return s
    }

    // MARK: - Trends series (consumed directly by TrendsView)

    static func stepsSeries(days: Int) -> [(date: Date, value: Double)] {
        series(days: days, from: 9_400, to: 11_400, noise: 1_500, step: 1)
    }

    static func sleepSeries(days: Int) -> [(date: Date, value: Double)] {
        series(days: days, from: 6.9, to: 7.4, noise: 0.7, step: 1)
    }

    static func rhrSeries(days: Int) -> [(date: Date, value: Double)] {
        series(days: days, from: 58, to: 52, noise: 1.6, step: 2)
    }

    static func bodyMassSeries(days: Int) -> [(date: Date, value: Double)] {
        series(days: days, from: 79.5, to: 77.5, noise: 0.4, step: 12)
    }

    static func vo2MaxSeries(days: Int) -> [(date: Date, value: Double)] {
        series(days: days, from: 44, to: 49, noise: 0.6, step: 30)
    }

    static func bloodPressureSeries(days: Int) -> [BloodPressureReading] {
        bloodPressureReadings().filter { $0.date >= daysAgo(days) }
    }

    // MARK: - SwiftData seed

    static func seed(into context: ModelContext) {
        for e in manualEntries()    { context.insert(e) }
        for d in exerciseDefs()     { context.insert(d) }
        for p in bloodworkPanels()  {
            // Let the JSON-backed evaluator flag markers using the mock profile
            // (34M, no acute illness). Keeps mock state consistent with what the
            // app produces for a real user — no hand-picked flags.
            let snap = snapshot()
            for marker in p.markers {
                marker.reevaluate(
                    sex: snap.biologicalSex,
                    dateOfBirth: snap.dateOfBirth,
                    acutePhaseAtDraw: p.acutePhaseAtDraw
                )
            }
            context.insert(p)
        }
        for n in nutritionEntries() { context.insert(n) }
        for x in exerciseEntries()  { context.insert(x) }
        try? context.save()
    }

    // MARK: - Manual entries (BP, body comp, habits, behaviours)

    private static func manualEntries() -> [ManualEntry] {
        var out: [ManualEntry] = [
            ManualEntry(entryType: .waist, date: daysAgo(5), primaryValue: 84),
            ManualEntry(entryType: .bodyWeight, date: daysAgo(1), primaryValue: 77.5),
            ManualEntry(entryType: .bodyWeight, date: daysAgo(9), primaryValue: 78.1),
            ManualEntry(entryType: .bodyWeight, date: daysAgo(16), primaryValue: 78.4),
            ManualEntry(entryType: .nicotine, date: daysAgo(1), booleanValue: false),
            ManualEntry(entryType: .alcohol, date: daysAgo(3), categorical: AlcoholLevel.light.rawValue),
            ManualEntry(entryType: .alcohol, date: daysAgo(11), categorical: AlcoholLevel.light.rawValue),
            ManualEntry(entryType: .bloodPressure, date: daysAgo(2), primaryValue: 118, secondaryValue: 76),
            ManualEntry(entryType: .bloodPressure, date: daysAgo(20), primaryValue: 121, secondaryValue: 78),
        ]
        // Daily habits across the last 8 weeks so the habit-completion chart is populated.
        let habits: [(ManualEntryType, [Int])] = [
            (.proteinHabit, Array(stride(from: 0, to: 56, by: 1))),
            (.fiberHabit,   Array(stride(from: 0, to: 56, by: 2))),
            (.omega3Habit,  Array(stride(from: 0, to: 56, by: 3))),
            (.dentalFloss,  Array(stride(from: 1, to: 56, by: 2))),
        ]
        for (type, offsets) in habits {
            for d in offsets {
                out.append(ManualEntry(entryType: type, date: daysAgo(d), booleanValue: true))
            }
        }
        return out
    }

    // MARK: - Bloodwork (one fresh, mostly-clean panel with one borderline marker)

    private static func bloodworkPanels() -> [BloodworkPanel] {
        [
            BloodworkPanel(
                date: daysAgo(20),
                labName: "Synlab",
                markers: [
                    BloodworkMarker(name: "ApoB",           value: "82",  unit: "mg/dL", referenceRange: "< 90",      flag: .good),
                    BloodworkMarker(name: "LDL-C",          value: "108", unit: "mg/dL", referenceRange: "< 100",     flag: .borderline),
                    BloodworkMarker(name: "HDL-C",          value: "58",  unit: "mg/dL", referenceRange: "> 40",      flag: .good),
                    BloodworkMarker(name: "Triglycerides",  value: "88",  unit: "mg/dL", referenceRange: "< 150",     flag: .good),
                    BloodworkMarker(name: "HbA1c",          value: "5.2", unit: "%",     referenceRange: "< 5.7",     flag: .good),
                    BloodworkMarker(name: "Fasting glucose", value: "90", unit: "mg/dL", referenceRange: "70–99",     flag: .good),
                    BloodworkMarker(name: "hs-CRP",         value: "0.7", unit: "mg/L",  referenceRange: "< 1.0",     flag: .good),
                    BloodworkMarker(name: "eGFR",           value: "98",  unit: "mL/min", referenceRange: "> 90",     flag: .good),
                    BloodworkMarker(name: "ALT",            value: "22",  unit: "U/L",   referenceRange: "< 40",      flag: .good),
                ]
            )
        ]
    }

    // MARK: - Exercise log

    /// One row per exercise the mock athlete trains. Single source of truth for
    /// both the seeded `ExerciseDef`s (muscle tags → weekly balance) and the
    /// logged sets (progressive overload), so names/tags never drift apart.
    private struct ExercisePlan {
        let name: String
        let symbol: String
        let primary: [MuscleGroup]
        let secondary: [MuscleGroup]
        let baseWeight: Double      // oldest-week working weight (kg); 0 = bodyweight
        let reps: Int
        let setCount: Int
        let weeklyIncrement: Double // added per elapsed week for progressive overload
    }

    private static let barbell = "figure.strengthtraining.traditional"
    private static let dumbbell = "dumbbell.fill"
    private static let hinge = "figure.strengthtraining.functional"
    private static let bodyweight = "figure.gymnastics"

    private static let exerciseCatalog: [ExercisePlan] = [
        // Push
        ExercisePlan(name: "Bench Press",            symbol: barbell,    primary: [.chest],                          secondary: [.frontDelts, .triceps], baseWeight: 72,  reps: 5,  setCount: 4, weeklyIncrement: 2.5),
        ExercisePlan(name: "Overhead Press",         symbol: barbell,    primary: [.frontDelts],                     secondary: [.sideDelts, .triceps],  baseWeight: 45,  reps: 5,  setCount: 3, weeklyIncrement: 1.5),
        ExercisePlan(name: "Incline Dumbbell Press", symbol: dumbbell,   primary: [.chest, .frontDelts],             secondary: [.triceps],              baseWeight: 26,  reps: 8,  setCount: 3, weeklyIncrement: 1),
        ExercisePlan(name: "Lateral Raise",          symbol: dumbbell,   primary: [.sideDelts],                      secondary: [],                      baseWeight: 10,  reps: 12, setCount: 3, weeklyIncrement: 0.5),
        ExercisePlan(name: "Triceps Pushdown",       symbol: dumbbell,   primary: [.triceps],                        secondary: [],                      baseWeight: 25,  reps: 12, setCount: 3, weeklyIncrement: 1),
        // Pull
        ExercisePlan(name: "Deadlift",               symbol: hinge,      primary: [.hamstrings, .glutes, .lowerBack], secondary: [.traps, .forearms],    baseWeight: 130, reps: 3,  setCount: 3, weeklyIncrement: 5),
        ExercisePlan(name: "Pull-up",                symbol: bodyweight, primary: [.lats],                           secondary: [.biceps, .upperBack],   baseWeight: 0,   reps: 8,  setCount: 4, weeklyIncrement: 0),
        ExercisePlan(name: "Barbell Row",            symbol: barbell,    primary: [.upperBack, .lats],               secondary: [.biceps, .rearDelts],   baseWeight: 65,  reps: 8,  setCount: 4, weeklyIncrement: 2.5),
        ExercisePlan(name: "Lat Pulldown",           symbol: dumbbell,   primary: [.lats],                           secondary: [.biceps, .upperBack],   baseWeight: 55,  reps: 10, setCount: 3, weeklyIncrement: 2),
        ExercisePlan(name: "Bicep Curl",             symbol: dumbbell,   primary: [.biceps],                         secondary: [.forearms],             baseWeight: 15,  reps: 10, setCount: 3, weeklyIncrement: 0.5),
        ExercisePlan(name: "Face Pull",              symbol: dumbbell,   primary: [.rearDelts],                      secondary: [.upperBack],            baseWeight: 20,  reps: 15, setCount: 3, weeklyIncrement: 1),
        // Legs
        ExercisePlan(name: "Squat",                  symbol: barbell,    primary: [.quads, .glutes],                 secondary: [.hamstrings, .core],    baseWeight: 100, reps: 5,  setCount: 4, weeklyIncrement: 2.5),
        ExercisePlan(name: "Romanian Deadlift",      symbol: hinge,      primary: [.hamstrings, .glutes],            secondary: [.lowerBack],            baseWeight: 80,  reps: 8,  setCount: 3, weeklyIncrement: 2.5),
        ExercisePlan(name: "Leg Press",              symbol: dumbbell,   primary: [.quads, .glutes],                 secondary: [.hamstrings],           baseWeight: 160, reps: 10, setCount: 3, weeklyIncrement: 5),
        ExercisePlan(name: "Calf Raise",             symbol: dumbbell,   primary: [.calves],                         secondary: [],                      baseWeight: 90,  reps: 15, setCount: 3, weeklyIncrement: 2.5),
        ExercisePlan(name: "Plank",                  symbol: bodyweight, primary: [.core],                           secondary: [.obliques],             baseWeight: 0,   reps: 60, setCount: 3, weeklyIncrement: 0),
    ]

    private static func plan(_ name: String) -> ExercisePlan {
        exerciseCatalog.first { $0.name == name } ?? exerciseCatalog[0]
    }

    /// Muscle-tagged exercise definitions so the weekly muscle-balance view has
    /// something to aggregate against (the entries reference these by name).
    private static func exerciseDefs() -> [ExerciseDef] {
        exerciseCatalog.enumerated().map { i, p in
            let def = ExerciseDef(name: p.name, sfSymbol: p.symbol, sortOrder: i)
            def.primaryMuscles = p.primary
            def.secondaryMuscles = p.secondary
            def.musclesClassifiedAt = daysAgo(24)
            return def
        }
    }

    /// ~3.5 weeks of a Push / Pull / Legs split (12 sessions) with weight
    /// climbing week over week — looks like someone who's logged workouts for a
    /// couple of weeks. Recent sessions land inside the 7-day muscle-balance window.
    private static func exerciseEntries() -> [ExerciseEntry] {
        let push = ["Bench Press", "Overhead Press", "Incline Dumbbell Press", "Lateral Raise", "Triceps Pushdown"]
        let pull = ["Deadlift", "Pull-up", "Barbell Row", "Lat Pulldown", "Bicep Curl", "Face Pull"]
        let legs = ["Squat", "Romanian Deadlift", "Leg Press", "Calf Raise", "Plank"]
        let schedule: [(offset: Int, day: [String])] = [
            (0, push), (2, pull), (4, legs),
            (6, push), (8, pull), (11, legs),
            (13, push), (15, pull), (17, legs),
            (20, push), (22, pull), (24, legs),
        ]
        let maxOffset = 24.0
        var out: [ExerciseEntry] = []
        for (offset, names) in schedule {
            let weeksElapsed = ((maxOffset - Double(offset)) / 7).rounded(.down)
            for (idx, name) in names.enumerated() {
                let p = plan(name)
                let raw = p.baseWeight + p.weeklyIncrement * weeksElapsed
                let weight = p.baseWeight == 0 ? 0 : (raw / 0.5).rounded() * 0.5
                let sets = (0..<p.setCount).map { _ in WorkoutSet(weightKg: weight, reps: p.reps) }
                // Stagger exercises within a session so they sort sensibly.
                let date = cal.date(byAdding: .minute, value: idx * 6, to: daysAgo(offset)) ?? daysAgo(offset)
                out.append(ExerciseEntry(date: date, name: name, symbol: p.symbol, sets: sets))
            }
        }
        return out
    }

    // MARK: - Nutrition (photo entries with AI fingerprints, last 7 days = the digest window)

    private static func nutritionEntries() -> [NutritionEntry] {
        // (dayOffset, title, [category:plateFraction], [plant ingredients], kcal/100g, P, C, F, serving g)
        let meals: [(Int, String, [(MealCategory, Double)], [String], Double, Double, Double, Double, Double)] = [
            (0, "Oatmeal with blueberries, banana & chia",
                [(.wholeGrains, 0.5), (.fruit, 0.3), (.nutsAndSeeds, 0.2)],
                ["oats", "blueberries", "banana", "chia seeds"], 150, 5, 27, 4, 320),
            (0, "Salmon, quinoa & roasted broccoli",
                [(.omega3Source, 0.35), (.wholeGrains, 0.3), (.cruciferous, 0.35)],
                ["broccoli", "quinoa"], 180, 14, 14, 8, 420),
            (0, "Greek yogurt with walnuts & berries",
                [(.fermented, 0.5), (.nutsAndSeeds, 0.25), (.fruit, 0.25)],
                ["walnuts", "raspberries", "strawberries"], 120, 9, 9, 5, 220),
            (1, "Lentil & spinach curry with brown rice",
                [(.legumes, 0.45), (.leafyGreens, 0.25), (.wholeGrains, 0.3)],
                ["lentils", "spinach", "brown rice", "onion", "garlic", "tomato"], 140, 8, 20, 3, 450),
            (1, "Chicken salad with mixed leaves & avocado",
                [(.leanProtein, 0.4), (.leafyGreens, 0.3), (.otherVeg, 0.3)],
                ["arugula", "lettuce", "avocado", "cucumber", "bell pepper"], 160, 15, 6, 9, 380),
            (2, "Tofu & edamame stir-fry with peppers",
                [(.legumes, 0.4), (.otherVeg, 0.4), (.wholeGrains, 0.2)],
                ["tofu", "edamame", "bell pepper", "carrot", "mushroom"], 145, 12, 12, 6, 400),
            (2, "Kefir smoothie with kale & flax",
                [(.fermented, 0.5), (.leafyGreens, 0.3), (.nutsAndSeeds, 0.2)],
                ["kefir", "kale", "flax seeds", "apple"], 90, 6, 12, 2, 350),
            (3, "Sardines on rye with rocket",
                [(.omega3Source, 0.5), (.wholeGrains, 0.3), (.leafyGreens, 0.2)],
                ["arugula", "rye"], 200, 18, 16, 9, 250),
            (3, "Chickpea & roasted veg bowl",
                [(.legumes, 0.4), (.otherVeg, 0.4), (.cruciferous, 0.2)],
                ["chickpeas", "sweet potato", "cauliflower", "zucchini", "red onion"], 150, 8, 22, 4, 430),
            (4, "Kimchi fried rice with egg",
                [(.fermented, 0.35), (.wholeGrains, 0.4), (.leanProtein, 0.25)],
                ["kimchi", "brown rice", "scallion", "peas"], 170, 9, 24, 5, 360),
            (4, "Burger and fries",
                [(.redMeat, 0.4), (.fried, 0.35), (.refinedCarbs, 0.25)],
                [], 280, 13, 28, 14, 450),
            (5, "Bean chili with cornbread",
                [(.legumes, 0.5), (.otherVeg, 0.3), (.wholeGrains, 0.2)],
                ["kidney beans", "black beans", "sweet corn", "tomato", "celery"], 135, 8, 19, 3, 460),
            (5, "Spinach & mushroom omelette",
                [(.leanProtein, 0.5), (.leafyGreens, 0.3), (.otherVeg, 0.2)],
                ["spinach", "mushroom"], 150, 13, 3, 10, 240),
            (6, "Grilled mackerel with asparagus & potatoes",
                [(.omega3Source, 0.4), (.otherVeg, 0.3), (.wholeGrains, 0.3)],
                ["asparagus", "potato", "beetroot"], 175, 16, 14, 8, 400),
            (6, "Almond-butter toast with apple",
                [(.wholeGrains, 0.45), (.nutsAndSeeds, 0.3), (.fruit, 0.25)],
                ["almonds", "apple"], 230, 8, 24, 11, 180),
            // A couple of older entries so the list scrolls (outside the 7-day digest window).
            (9, "Protein shake & berries",
                [(.dairyOrAlt, 0.6), (.fruit, 0.4)],
                ["blueberries"], 110, 18, 8, 2, 350),
            (12, "Pasta with tomato sauce",
                [(.refinedCarbs, 0.6), (.otherVeg, 0.4)],
                ["tomato", "basil"], 190, 7, 32, 4, 380),
        ]

        let enc = JSONEncoder()
        return meals.enumerated().map { idx, m in
            let (offset, title, cats, plants, kcal, p, c, f, serving) = m
            let fp = MealFingerprint(
                items: cats.map { MealFingerprint.Item(category: $0.0, plateFraction: $0.1) },
                plantIngredients: plants,
                aiNotes: nil,
                confidence: "medium",
                title: title,
                estimatedKcalPer100g: kcal,
                proteinPer100g: p,
                carbsPer100g: c,
                fatPer100g: f,
                typicalServingGrams: serving
            )
            let json = (try? enc.encode(fp)).flatMap { String(data: $0, encoding: .utf8) }
            let grams = serving
            let macros = fp.scaledMacros(toGrams: grams)
            // Stagger times within each day so entries sort sensibly.
            let date = cal.date(byAdding: .hour, value: -(idx % 3) * 5, to: daysAgo(offset)) ?? daysAgo(offset)
            return NutritionEntry(
                date: date,
                source: .photo,
                rawInput: "",
                productName: title,
                caloriesKcal: macros?.kcal,
                portionGrams: grams,
                proteinGrams: macros?.protein,
                carbsGrams: macros?.carbs,
                fatGrams: macros?.fat,
                modelUsed: "anthropic/claude-sonnet-4.6",
                inputTokens: 1_100,
                outputTokens: 240,
                costUSD: 0.012,
                fingerprintJSON: json
            )
        }
    }

    // MARK: - Generators

    /// Linear trend from `from` (oldest) to `to` (newest) with deterministic wobble.
    /// Emits one point every `step` days across the window, oldest first.
    private static func series(days: Int, from: Double, to: Double, noise: Double, step: Int) -> [(date: Date, value: Double)] {
        let n = max(1, days / step)
        return (0...n).map { i in
            let t = Double(i) / Double(n)
            let base = from + (to - from) * t
            let wobble = sin(Double(i) * 1.3) * noise
            return (date: daysAgo(days - i * step), value: base + wobble)
        }
    }

    /// Timestamped HRV (SDNN, ms) samples over the last 28 days — irregular spacing so
    /// the engine's continuous-time EWMA has real Δt gaps to weight by.
    private static func hrvSamples() -> [(date: Date, value: Double)] {
        let dayOffsets = [0, 1, 3, 4, 6, 7, 9, 10, 12, 13, 15, 17, 18, 20, 22, 23, 25, 27]
        return dayOffsets.map { d in
            let wobble = sin(Double(d) * 0.9) * 7
            return (date: cal.date(byAdding: .hour, value: -6, to: daysAgo(d)) ?? daysAgo(d), value: 62 + wobble)
        }
    }

    private static func bloodPressureReadings() -> [BloodPressureReading] {
        let dayOffsets = [2, 9, 20, 34, 55, 78, 104, 140, 168]
        return dayOffsets.map { d in
            let sys = 118 + sin(Double(d) * 0.4) * 4
            let dia = 76 + cos(Double(d) * 0.4) * 3
            return BloodPressureReading(systolic: sys, diastolic: dia, date: daysAgo(d))
        }
    }
}
#endif
