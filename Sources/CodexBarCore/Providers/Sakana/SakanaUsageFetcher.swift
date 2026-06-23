import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SakanaUsageSnapshot: Sendable {
    public struct QuotaWindow: Sendable, Equatable {
        public let usedPercent: Double
        public let resetsAt: Date?

        public init(usedPercent: Double, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public let planName: String?
    public let priceLabel: String?
    public let fiveHour: QuotaWindow?
    public let weekly: QuotaWindow?
    public let updatedAt: Date

    public init(
        planName: String?,
        priceLabel: String?,
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?,
        updatedAt: Date = Date())
    {
        self.planName = planName
        self.priceLabel = priceLabel
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = self.fiveHour.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: 5 * 60,
                resetsAt: window.resetsAt,
                resetDescription: "\(Self.formatPercent(window.usedPercent))% used")
        }
        let secondary = self.weekly.map { window in
            RateWindow(
                usedPercent: window.usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: window.resetsAt,
                resetDescription: "\(Self.formatPercent(window.usedPercent))% used")
        }
        let planLabel = [self.planName, self.priceLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let identity = ProviderIdentitySnapshot(
            providerID: .sakana,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: planLabel.isEmpty ? nil : planLabel)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func formatPercent(_ percent: Double) -> String {
        let rounded = (percent * 100).rounded() / 100
        if rounded.rounded() == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }
}

public enum SakanaUsageError: LocalizedError, Sendable, Equatable {
    case missingCookie
    case loginRequired
    case apiError(Int, String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "Missing Sakana cookie header (SAKANA_COOKIE)."
        case .loginRequired:
            "Sakana login is required."
        case let .apiError(code, message):
            "Sakana billing fetch failed (\(code)): \(message)"
        case let .parseFailed(message):
            "Failed to parse Sakana billing page: \(message)"
        }
    }
}

public enum SakanaUsageFetcher {
    private static let billingURL = URL(string: "https://console.sakana.ai/billing")!

    public static func fetchUsage(
        cookieHeader: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = 15,
        now: Date = Date()) async throws -> SakanaUsageSnapshot
    {
        guard let cookieHeader = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw SakanaUsageError.missingCookie
        }

        var request = URLRequest(url: self.billingURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let response = try await transport.response(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw SakanaUsageError.loginRequired
        }
        guard response.statusCode == 200 else {
            let body = String(data: response.data.prefix(200), encoding: .utf8) ?? ""
            throw SakanaUsageError.apiError(response.statusCode, body)
        }
        guard let html = String(data: response.data, encoding: .utf8), !html.isEmpty else {
            throw SakanaUsageError.parseFailed("Billing page response was empty.")
        }
        return try self.parseBillingHTML(html, now: now)
    }

    static func parseBillingHTML(
        _ html: String,
        now: Date = Date(),
        timeZone: TimeZone = .current) throws -> SakanaUsageSnapshot
    {
        let fiveHour = self.parseWindow(label: "5-hour", html: html, timeZone: timeZone)
        let weekly = self.parseWindow(label: "Weekly", html: html, timeZone: timeZone)
        guard fiveHour != nil || weekly != nil else {
            throw SakanaUsageError.parseFailed("Usage limit windows were not found.")
        }
        return SakanaUsageSnapshot(
            planName: self.parsePlanName(html),
            priceLabel: self.parsePlanPrice(html),
            fiveHour: fiveHour,
            weekly: weekly,
            updatedAt: now)
    }

    private static func parseWindow(
        label: String,
        html: String,
        timeZone: TimeZone) -> SakanaUsageSnapshot.QuotaWindow?
    {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "<p[^>]*>\\s*\(escaped)\\s*</p>\\s*"
            + "<p[^>]*>\\s*Resets on ([^<]+?)\\s*</p>[\\s\\S]*?"
            + "<p[^>]*>\\s*([0-9]+(?:\\.[0-9]+)?)% used\\s*</p>"
        guard let match = self.firstMatch(pattern: pattern, in: html),
              let resetText = self.capture(1, in: html, match: match),
              let percentText = self.capture(2, in: html, match: match),
              let percent = Double(percentText)
        else {
            return nil
        }
        return SakanaUsageSnapshot.QuotaWindow(
            usedPercent: min(100, max(0, percent)),
            resetsAt: self.parseResetDate(resetText, timeZone: timeZone))
    }

    private static func parsePlanName(_ html: String) -> String? {
        self.capture(
            pattern: #"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>\s*([^<]+?)\s*</span>"#,
            in: html)
    }

    private static func parsePlanPrice(_ html: String) -> String? {
        let pattern = #"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>[^<]+</span>\s*"# +
            #"<span[^>]*>\s*([^<]+?)\s*</span>"#
        return self.capture(
            pattern: pattern,
            in: html)
    }

    private static func parseResetDate(_ value: String, timeZone: TimeZone) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter.date(from: trimmed)
    }

    private static func capture(pattern: String, in html: String) -> String? {
        guard let match = self.firstMatch(pattern: pattern, in: html) else { return nil }
        return self.capture(1, in: html, match: match)
    }

    private static func firstMatch(pattern: String, in html: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.firstMatch(in: html, options: [], range: range)
    }

    private static func capture(_ index: Int, in html: String, match: NSTextCheckingResult) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: html)
        else {
            return nil
        }
        let value = html[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
