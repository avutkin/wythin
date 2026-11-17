import Foundation
import HealthKit

/// The boundary from HealthKit objects to the small, explicitly allowed wire model.
enum HealthWorkoutMapping {
    static func activityName(for code: UInt) -> String {
        // Raw values also preserve labels for old, deprecated HealthKit activity types.
        let names: [UInt: String] = [
            1: "American football", 2: "Archery", 3: "Australian football", 4: "Badminton",
            5: "Baseball", 6: "Basketball", 7: "Bowling", 8: "Boxing", 9: "Climbing",
            10: "Cricket", 11: "Cross training", 12: "Curling", 13: "Cycling", 14: "Dance",
            15: "Dance training", 16: "Elliptical", 17: "Equestrian sports", 18: "Fencing",
            19: "Fishing", 20: "Functional strength training", 21: "Golf", 22: "Gymnastics",
            23: "Handball", 24: "Hiking", 25: "Hockey", 26: "Hunting", 27: "Lacrosse",
            28: "Martial arts", 29: "Mind and body", 30: "Mixed cardio", 31: "Paddle sports",
            32: "Play", 33: "Preparation and recovery", 34: "Racquetball", 35: "Rowing",
            36: "Rugby", 37: "Running", 38: "Sailing", 39: "Skating", 40: "Snow sports",
            41: "Soccer", 42: "Softball", 43: "Squash", 44: "Stair climbing", 45: "Surfing",
            46: "Swimming", 47: "Table tennis", 48: "Tennis", 49: "Track and field",
            50: "Strength training", 51: "Volleyball", 52: "Walking", 53: "Water fitness",
            54: "Water polo", 55: "Water sports", 56: "Wrestling", 57: "Yoga", 58: "Barre",
            59: "Core training", 60: "Cross-country skiing", 61: "Downhill skiing",
            62: "Flexibility", 63: "High-intensity interval training", 64: "Jump rope",
            65: "Kickboxing", 66: "Pilates", 67: "Snowboarding", 68: "Stairs",
            69: "Step training", 70: "Wheelchair walk pace", 71: "Wheelchair run pace",
            72: "Tai chi", 73: "Mixed cardio", 74: "Hand cycling", 75: "Disc sports",
            76: "Fitness gaming", 77: "Cardio dance", 78: "Social dance", 79: "Pickleball",
            80: "Cooldown", 82: "Swim, bike, run", 83: "Transition", 84: "Underwater diving",
            3000: "Other workout"
        ]
        return names[code] ?? "Workout (\(code))"
    }

    static func workout(_ raw: HKWorkout) -> HealthWorkout {
        let energy = raw.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()
            ?? raw.totalEnergyBurned
        return HealthWorkout(
            id: raw.uuid, activityCode: raw.workoutActivityType.rawValue,
            activityName: activityName(for: raw.workoutActivityType.rawValue),
            startedAt: raw.startDate, endedAt: raw.endDate, activeDurationSeconds: raw.duration,
            source: source(raw.sourceRevision), timezone: raw.metadata?[HKMetadataKeyTimeZone] as? String,
            energyKcal: energy?.doubleValue(for: .kilocalorie()),
            distanceMeters: raw.totalDistance?.doubleValue(for: .meter()),
            userEntered: (raw.metadata?[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue ?? false,
            events: (raw.workoutEvents ?? []).map { event in
                HealthWorkoutEvent(kind: eventName(event.type), startedAt: event.dateInterval.start,
                                   endedAt: event.dateInterval.end)
            },
            segments: raw.workoutActivities.map { segment($0, workoutEnd: raw.endDate) }
        )
    }

    static func segment(_ raw: HKWorkoutActivity, workoutEnd: Date) -> HealthWorkoutSegment {
        HealthWorkoutSegment(activityCode: raw.workoutConfiguration.activityType.rawValue,
            startedAt: raw.startDate, endedAt: raw.endDate ?? workoutEnd)
    }

    static func source(_ raw: HKSourceRevision) -> HealthSourceInfo {
        HealthSourceInfo(bundleIdentifier: raw.source.bundleIdentifier, name: raw.source.name, version: raw.version)
    }

    static func sample(_ raw: HKQuantitySample, metric: HealthMetric) -> HealthSample {
        HealthSample(id: raw.uuid, metric: metric, value: raw.quantity.doubleValue(for: unit(metric)),
            startedAt: raw.startDate, endedAt: raw.endDate, source: source(raw.sourceRevision),
            representation: raw.endDate > raw.startDate ? .interval : .point)
    }

    static func seriesPoint(parent: HKQuantitySample, metric: HealthMetric, index: Int,
                            quantity: HKQuantity, interval: DateInterval) -> HealthSample {
        HealthSample(id: HealthSample.childID(parent: parent.uuid, index: index), metric: metric,
            value: quantity.doubleValue(for: unit(metric)), startedAt: interval.start, endedAt: interval.end,
            source: source(parent.sourceRevision), parentId: parent.uuid, representation: .series)
    }

    static func quantityType(_ metric: HealthMetric) -> HKQuantityType? {
        let identifier: HKQuantityTypeIdentifier
        switch metric {
        case .heartRate: identifier = .heartRate
        case .sdnn: identifier = .heartRateVariabilitySDNN
        case .activeEnergy: identifier = .activeEnergyBurned
        case .walkingRunningDistance: identifier = .distanceWalkingRunning
        case .cyclingDistance: identifier = .distanceCycling
        case .swimmingDistance: identifier = .distanceSwimming
        case .steps: identifier = .stepCount
        }
        return HKObjectType.quantityType(forIdentifier: identifier)
    }

    static func unit(_ metric: HealthMetric) -> HKUnit {
        switch metric {
        case .heartRate: return .count().unitDivided(by: .minute())
        case .sdnn: return .secondUnit(with: .milli)
        case .activeEnergy: return .kilocalorie()
        case .steps: return .count()
        case .walkingRunningDistance, .cyclingDistance, .swimmingDistance: return .meter()
        }
    }

    private static func eventName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: return "pause"
        case .resume: return "resume"
        case .lap: return "lap"
        case .marker: return "marker"
        case .motionPaused: return "motion_paused"
        case .motionResumed: return "motion_resumed"
        case .segment: return "segment"
        case .pauseOrResumeRequest: return "pause_or_resume_request"
        @unknown default: return "event_\(type.rawValue)"
        }
    }
}
