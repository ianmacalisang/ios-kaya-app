//
//  Momentum.swift
//  Kaya
//
//  Respectful progress: milestones and level names that recognize effort
//  without timers, streaks, or guilt. Everything is earned, nothing is lost.
//

import Foundation

struct Milestone: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
}

enum Momentum {

    static let all: [Milestone] = [
        Milestone(id: "first-step", title: "First step",
                  detail: "You finished your very first step.", symbol: "checkmark.seal.fill"),
        Milestone(id: "first-routine", title: "Routine done",
                  detail: "You finished a whole routine.", symbol: "flag.pattern.checkered"),
        Milestone(id: "ten-steps", title: "Ten steps",
                  detail: "Ten steps done, one at a time.", symbol: "10.circle.fill"),
        Milestone(id: "three-routines", title: "Finding your rhythm",
                  detail: "Three routines finished.", symbol: "repeat.circle.fill"),
        Milestone(id: "this-week", title: "A win this week",
                  detail: "You finished a routine this week.", symbol: "calendar.badge.checkmark"),
        Milestone(id: "voice-user", title: "Talked to Kaya",
                  detail: "You used hands-free voice control.", symbol: "waveform"),
        Milestone(id: "shared-feeling", title: "Shared how it felt",
                  detail: "You told Kaya how a routine felt.", symbol: "text.bubble.fill"),
        Milestone(id: "photo-memory", title: "Kept a memory",
                  detail: "You saved a photo of something you finished.", symbol: "photo.badge.checkmark"),
        Milestone(id: "five-routines", title: "On a roll",
                  detail: "Five routines finished.", symbol: "star.circle.fill"),
        Milestone(id: "three-days", title: "3 days in a row",
                  detail: "You showed up three days running.", symbol: "flame.fill"),
        Milestone(id: "week-run", title: "A week of showing up",
                  detail: "Seven days in a row — quietly remarkable.", symbol: "flame.circle.fill"),
        Milestone(id: "ten-days", title: "10 days you showed up",
                  detail: "Ten different days with Kaya — they add up.", symbol: "calendar.circle.fill"),
    ]

    /// Level name from total finished routines — descriptive, never judgmental.
    static func levelName(for routinesFinished: Int) -> String {
        switch routinesFinished {
        case 0: return "Just beginning"
        case 1...2: return "Finding your rhythm"
        case 3...4: return "Building momentum"
        case 5...9: return "On a roll"
        default: return "Everyday independence"
        }
    }

    /// Thresholds matching `levelName` — start of each level.
    private static let levelThresholds = [0, 1, 3, 5, 10]
    private static let levelNames = [
        "Just beginning", "Finding your rhythm", "Building momentum",
        "On a roll", "Everyday independence"
    ]

    /// 0…1 progress toward the next level — used for the progress ring.
    static func levelProgress(for routinesFinished: Int) -> Double {
        for index in (0..<levelThresholds.count).reversed() {
            guard routinesFinished >= levelThresholds[index] else { continue }
            if index == levelThresholds.count - 1 { return 1 }
            let lower = levelThresholds[index]
            let upper = levelThresholds[index + 1]
            return Double(routinesFinished - lower) / Double(upper - lower)
        }
        return 0
    }

    /// Name of the next level and how many routines it takes to reach it.
    static func nextLevel(for routinesFinished: Int) -> (name: String, routinesLeft: Int)? {
        for (index, threshold) in levelThresholds.enumerated() where routinesFinished < threshold {
            return (levelNames[index], threshold - routinesFinished)
        }
        return nil
    }

    static func isEarned(_ milestone: Milestone, profile: UserProfile) -> Bool {
        switch milestone.id {
        case "first-step": return profile.stepsFinished >= 1
        case "first-routine": return profile.routinesFinished >= 1
        case "ten-steps": return profile.stepsFinished >= 10
        case "three-routines": return profile.routinesFinished >= 3
        case "this-week": return profile.routinesFinishedThisWeek >= 1
        case "voice-user": return profile.usedVoiceControl
        case "shared-feeling": return profile.reflectionsGiven >= 1
        case "photo-memory": return profile.photosAdded >= 1
        case "five-routines": return profile.routinesFinished >= 5
        case "three-days": return longestRun(in: profile.activeDays) >= 3
        case "week-run": return longestRun(in: profile.activeDays) >= 7
        case "ten-days": return activeDayCount(profile.activeDays) >= 10
        default: return false
        }
    }

    // MARK: - Gentle streaks

    /// A "run" is consecutive calendar days with at least one step done.
    /// A run ending today or yesterday is current — a quiet day pauses it,
    /// it never displays as lost.
    static func currentRun(in days: [Date], from now: Date = Date(),
                           in calendar: Calendar = .current) -> Int {
        let unique = Set(days.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        // Start from today if active, else yesterday — the run "freezes"
        // overnight rather than breaking at midnight.
        var cursor = unique.contains(today) ? today
            : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        guard unique.contains(cursor) else { return 0 }
        var run = 0
        while unique.contains(cursor) {
            run += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return run
    }

    /// The user's best-ever consecutive run — shown when the current run
    /// has paused, so something earned is always visible.
    static func longestRun(in days: [Date], in calendar: Calendar = .current) -> Int {
        let sorted = Set(days.map { calendar.startOfDay(for: $0) }).sorted()
        var best = 0, run = 0, previous: Date?
        for day in sorted {
            if let previous,
               calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// Total distinct days with any activity — for the "10 days" milestone.
    static func activeDayCount(_ days: [Date], in calendar: Calendar = .current) -> Int {
        Set(days.map { calendar.startOfDay(for: $0) }).count
    }

    /// Milestones satisfied right now but not yet recorded as earned.
    /// Marks them earned on the profile.
    static func checkNew(in profile: UserProfile) -> [Milestone] {
        let earned = all.filter {
            !profile.earnedMilestoneIDs.contains($0.id) && isEarned($0, profile: profile)
        }
        profile.earnedMilestoneIDs.append(contentsOf: earned.map(\.id))
        return earned
    }

    /// Progress text toward the next unearned milestone, e.g.
    /// "2 more routines to earn 'On a roll'".
    static func nextHint(for profile: UserProfile) -> String? {
        guard let next = all.first(where: {
            !profile.earnedMilestoneIDs.contains($0.id) && !isEarned($0, profile: profile)
        }) else { return nil }

        switch next.id {
        case "first-step":
            return "Finish one step to earn “\(next.title)”."
        case "ten-steps":
            return "\(max(10 - profile.stepsFinished, 0)) more steps to earn “\(next.title)”."
        case "three-routines":
            return "\(max(3 - profile.routinesFinished, 0)) more routines to earn “\(next.title)”."
        case "five-routines":
            return "\(max(5 - profile.routinesFinished, 0)) more routines to earn “\(next.title)”."
        case "this-week":
            return "Finish a routine this week to earn “\(next.title)”."
        case "voice-user":
            return "Try hands-free voice control to earn “\(next.title)”."
        case "shared-feeling":
            return "Tell Kaya how a routine felt to earn “\(next.title)”."
        case "photo-memory":
            return "Save a photo of something you finished to earn “\(next.title)”."
        case "first-routine":
            return "Finish a routine to earn “\(next.title)”."
        case "three-days":
            return "Show up three days in a row to earn “\(next.title)”."
        case "week-run":
            return "Show up seven days in a row to earn “\(next.title)”."
        case "ten-days":
            return "Show up on \(max(10 - activeDayCount(profile.activeDays), 0)) more days to earn “\(next.title)”."
        default:
            return nil
        }
    }

    /// Calm praise lines for the most encouraging level.
    static let praises = [
        "Nice work.", "That's one more step done.", "Moving along.",
        "You're doing it.", "Another step finished.", "Steady progress."
    ]

    static func praise(for index: Int) -> String {
        praises[abs(index) % praises.count]
    }
}
