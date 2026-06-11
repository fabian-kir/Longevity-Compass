import Foundation

enum RecommendationEngine {

    static func actions(
        for domain: HealthDomain,
        status: DomainStatus
    ) -> [String] {
        switch (domain, status) {

        // MARK: Blood pressure

        case (.bloodPressure, .urgent):
            return [
                "If this reading is accurate and you feel unwell (chest pain, vision change, weakness), seek urgent medical care now.",
                "Sit, rest five minutes, and recheck once with the cuff at heart level on a bare arm.",
                "If the second reading is still ≥180/120, contact a clinician today.",
            ]
        case (.bloodPressure, .bad):
            return [
                "Recheck correctly: seated 5 min, feet flat, arm supported, cuff on bare skin at heart level.",
                "Take two readings, 1 min apart, same time of day, for a few days and average them.",
                "Add 2–3 Zone 2 cardio sessions this week.",
                "Reduce alcohol and high-sodium processed foods this week.",
                "Prioritise sleep — short sleep raises blood pressure.",
                "If repeatedly ≥130/80, discuss with a clinician.",
            ]
        case (.bloodPressure, .borderline):
            return [
                "Re-measure under the same conditions across a few days to confirm.",
                "Keep sodium moderate and add potassium-rich whole foods (legumes, vegetables, fruit).",
                "Continue cardio and protect sleep.",
            ]
        case (.bloodPressure, .good):
            return [
                "Re-check every 1–3 months to confirm the trend.",
                "Keep cardio, sleep, and weight stable — they're doing the work.",
            ]
        case (.bloodPressure, .missing):
            return [
                "Add a baseline: take one reading per day for a week.",
                "Measure seated, rested, arm supported, same time of day for consistency.",
                "One reading is not a diagnosis; trends matter.",
            ]

        // MARK: Nicotine

        case (.nicotine, .bad):
            return [
                "Stopping nicotine is the single highest-impact change available — consider talking to a clinician about combined behavioural + pharmacotherapy support.",
                "If you slipped, log it without judgement and re-engage the plan.",
                "Avoid common triggers (alcohol, breaks with smokers) for the first 2 weeks.",
            ]
        case (.nicotine, .good):
            return [
                "No nicotine logged recently — keep going.",
            ]
        case (.nicotine, _):
            return ["Log honestly — accurate data > clean streaks."]

        // MARK: Cardio

        case (.cardio, .bad):
            return [
                "Add 2 × 30 min Zone 2 sessions this week (brisk walk, easy bike, easy jog where you can still speak).",
                "Take one brisk 10-min walk after a main meal.",
                "Build minutes gradually — don't redline the first week.",
            ]
        case (.cardio, .borderline):
            return [
                "Add one more Zone 2 session this week to clear 150 min/week.",
                "Optionally add one short (10–20 min) higher-effort session if recovery is good.",
            ]
        case (.cardio, .good):
            return [
                "Hold the volume; add 1 longer (45–60 min) Zone 2 session if you enjoy it.",
                "Watch VO₂ max trend over a few months rather than weekly numbers.",
            ]
        case (.cardio, .missing):
            return [
                "Make sure Apple Health is reading workouts/steps so you don't have to log them.",
                "Plan one 30-min walk today to start a baseline.",
            ]

        // MARK: Strength

        case (.strength, .bad):
            return [
                "Do 2 full-body sessions this week — 30–45 min each.",
                "Cover 4 patterns: squat, hinge, push, pull.",
                "Start light; aim for 2–3 sets of 6–12 reps with 1–2 reps in reserve.",
            ]
        case (.strength, .borderline):
            return [
                "Add one more session this week to hit 2 sessions.",
                "Progress one set or one rep per session — small and sustainable.",
            ]
        case (.strength, .good):
            return [
                "Keep 2+ sessions/week. Rotate exercises every ~6–8 weeks.",
            ]
        case (.strength, .missing):
            return [
                "Log a yes/no when you train — one tap on the Track screen.",
                "If you train today, tap it now so trends start.",
            ]

        // MARK: Body composition

        case (.bodyComposition, .bad), (.bodyComposition, .borderline):
            return [
                "Track waist circumference monthly — more informative than weight alone.",
                "Tighten protein, fibre, and sleep before chasing a deficit.",
                "Walk after meals; reduce evening grazing.",
            ]
        case (.bodyComposition, .good):
            return [
                "Re-check weight every couple of weeks and waist monthly — no need to weigh daily.",
            ]
        case (.bodyComposition, .missing):
            return [
                "Add a waist measurement now (relaxed, at the navel) and a weight if not in Apple Health.",
            ]

        // MARK: Sleep

        case (.sleep, .bad):
            return [
                "Protect bedtime: pick a window and hold it for 14 days.",
                "Cut caffeine after midday; cut alcohol on weeknights.",
                "Dim lights 60 min before bed; aim for a cool, dark room.",
                "Recovery matters more than \"perfect\" — one short night is normal, a trend isn't.",
            ]
        case (.sleep, .borderline):
            return [
                "Bring bedtime forward 30 min this week.",
                "Anchor wake time — that's the easier dial to hold steady.",
            ]
        case (.sleep, .good):
            return [
                "Hold the routine — consistency is the win.",
            ]
        case (.sleep, .missing):
            return [
                "Wear the watch overnight so sleep is tracked automatically.",
                "Or enable Apple Health sleep tracking on the iPhone.",
            ]

        // MARK: Alcohol

        case (.alcohol, .bad):
            return [
                "Plan 3 alcohol-free nights this week.",
                "Cap at 1 standard drink on any drinking day.",
                "Watch for sleep-quality and blood-pressure impact.",
            ]
        case (.alcohol, .borderline):
            return [
                "Aim for fewer drinking days this week.",
            ]
        case (.alcohol, .good):
            return [
                "Keep it light or none. Good as-is.",
            ]
        case (.alcohol, .missing):
            return [
                "Log on the days you drink — even a quick 'none' for the day helps the trend.",
            ]

        // MARK: Protein

        case (.protein, .bad):
            return [
                "Add a high-protein breakfast (Greek yogurt, eggs, cottage cheese, whey).",
                "Aim for protein in 2–3 meals a day.",
                "Roughly 25–50 g per meal depending on body size.",
            ]
        case (.protein, .borderline):
            return [
                "Add one more high-protein meal this week.",
            ]
        case (.protein, .good):
            return [
                "Keep the rhythm. No need to count grams.",
            ]
        case (.protein, .missing):
            return [
                "Tap 'Protein hit' on Track on the days you got protein in 2+ meals.",
            ]

        // MARK: Fiber

        case (.fiber, .bad):
            return [
                "Add a serving of legumes, oats, berries, or vegetables to one meal.",
                "Increase gradually if you're not used to it.",
                "Psyllium is a cheap low-prep backup.",
            ]
        case (.fiber, .borderline):
            return [
                "Add one fibre-rich side at lunch or dinner this week.",
            ]
        case (.fiber, .good):
            return [
                "Keep the variety high.",
            ]
        case (.fiber, .missing):
            return [
                "Tap 'Fibre hit' on days where you ate clearly fibre-rich foods.",
            ]

        // MARK: Omega-3

        case (.omega3, .bad), (.omega3, .borderline):
            return [
                "Aim for fatty fish twice this week: salmon, sardines, trout, herring, anchovies, mussels.",
                "If you don't eat fish, consider algae oil. Don't default to generic high-dose fish oil.",
            ]
        case (.omega3, .good):
            return [
                "Keep two fatty-fish meals a week.",
            ]
        case (.omega3, .missing):
            return [
                "Log each fatty-fish meal — once a week is fine.",
            ]

        // MARK: Dental

        case (.dental, .bad), (.dental, .borderline):
            return [
                "Floss daily — the highest-leverage move.",
                "Brush twice daily.",
                "If fluoride gel is part of your routine, keep it.",
            ]
        case (.dental, .good):
            return [
                "Keep the routine. This only resurfaces when bigger items are handled.",
            ]
        case (.dental, .missing):
            return [
                "Tap floss/fluoride on days you do them — low effort.",
            ]

        // MARK: Bloodwork

        case (.bloodwork, .bad):
            return [
                "Review flagged markers with a clinician — don't self-treat from a single panel.",
                "Address the lifestyle levers that move the flagged numbers (e.g. LDL/ApoB → saturated fat, fibre, cardio).",
                "Plan the next draw about a year out, sooner only if clinically advised.",
            ]
        case (.bloodwork, .borderline):
            return [
                "Confirm borderline markers with a follow-up panel in ~12 months.",
                "Tighten the related lifestyle inputs in the meantime (diet, activity, sleep, alcohol).",
            ]
        case (.bloodwork, .good):
            return [
                "All markers in range — recheck in ~3 years unless something changes.",
                "Keep the habits that produced the result.",
            ]
        case (.bloodwork, .missing):
            return [
                "Book a baseline panel: lipids (ApoB, LDL, HDL, triglycerides), HbA1c, fasting glucose, hs-CRP, kidney + liver, vitamin D, TSH.",
                "Ask the lab for a printed/digital copy and enter the numbers in the Bloodwork tab.",
                "Once a year is typical; less often when results are clean.",
            ]
        case (.bloodwork, .unknown):
            return [
                "Open the most recent panel and flag each marker as good, borderline, or bad.",
            ]

        // Fallbacks
        case (_, .unknown):
            return ["Not enough data yet."]
        default:
            return []
        }
    }
}
