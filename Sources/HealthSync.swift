// HealthSync.swift — 读 HealthKit(心率/步数/睡眠)POST 到潮汐 relay 的 /health。
// 用法:HealthSync.shared.configure(server:token:) 后 requestAuth();
// 前台每次进来 syncNow(),后台靠 HKObserverQuery 的 background delivery 被健康数据唤醒。
//
// 服务器契约(和快捷指令时代一致,relay 已能解析):
//   POST <server>/health?token=<token>   Content-Type: application/json
//   { "heart_rate": 76, "steps": 8412, "sleep_start": "2026-07-09 01:48", "sleep_end": "2026-07-09 07:05" }
// relay 侧宽容:有哪项发哪项,0/缺省不覆盖旧值。

import Foundation
import HealthKit

final class HealthSync {
    static let shared = HealthSync()
    private let store = HKHealthStore()
    private var serverBase = ""     // 例:https://garden.mocatbase.cc/relay
    private var token = ""

    private var hrType: HKQuantityType { HKQuantityType.quantityType(forIdentifier: .heartRate)! }
    private var stepType: HKQuantityType { HKQuantityType.quantityType(forIdentifier: .stepCount)! }
    private var sleepType: HKCategoryType { HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)! }
    private var readTypes: Set<HKObjectType> { [hrType, stepType, sleepType] }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func configure(server: String, token: String) {
        // server 传的是 relay 根,如 https://garden.mocatbase.cc/relay
        self.serverBase = server.trimmingCharacters(in: .whitespaces)
        self.token = token.trimmingCharacters(in: .whitespaces)
    }

    // 请求授权 + 打开后台送达。首次会弹"允许"窗——她点一下就好。
    func requestAuth(_ completion: @escaping (Bool) -> Void) {
        guard isAvailable else { completion(false); return }
        store.requestAuthorization(toShare: nil, read: readTypes) { [weak self] ok, _ in
            guard let self, ok else { completion(false); return }
            self.enableBackgroundDelivery()
            self.syncNow()
            completion(true)
        }
    }

    private func enableBackgroundDelivery() {
        for t in [hrType, stepType, sleepType] {
            store.enableBackgroundDelivery(for: t, frequency: .hourly) { _, _ in }
        }
        // 观察者:健康数据一有新样本就触发上报(即使 App 在后台)
        let hrObs = HKObserverQuery(sampleType: hrType, predicate: nil) { [weak self] _, done, _ in
            self?.syncNow(); done()
        }
        let stepObs = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, done, _ in
            self?.syncNow(); done()
        }
        let sleepObs = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, done, _ in
            self?.syncNow(); done()
        }
        store.execute(hrObs); store.execute(stepObs); store.execute(sleepObs)
    }

    // 拉最新心率 + 今日步数 + 最近一晚睡眠,凑一个包 POST 出去。
    func syncNow() {
        guard !serverBase.isEmpty, !token.isEmpty else { return }
        let group = DispatchGroup()
        var payload: [String: Any] = [:]

        group.enter()
        latestHeartRate { bpm in
            if let bpm { payload["heart_rate"] = Int(bpm.rounded()) }
            group.leave()
        }

        group.enter()
        todaySteps { steps in
            if let steps { payload["steps"] = Int(steps.rounded()) }
            group.leave()
        }

        group.enter()
        lastNightSleep { start, end in
            if let start, let end {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd HH:mm"
                payload["sleep_start"] = f.string(from: start)
                payload["sleep_end"] = f.string(from: end)
            }
            group.leave()
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self, !payload.isEmpty else { return }
            self.post(payload)
        }
    }

    // MARK: - 查询

    private func latestHeartRate(_ cb: @escaping (Double?) -> Void) {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let q = HKSampleQuery(sampleType: hrType, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            guard let s = samples?.first as? HKQuantitySample else { cb(nil); return }
            cb(s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
        }
        store.execute(q)
    }

    private func todaySteps(_ cb: @escaping (Double?) -> Void) {
        let start = Calendar.current.startOfDay(for: Date())
        let pred = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let q = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, _ in
            cb(stats?.sumQuantity()?.doubleValue(for: .count()))
        }
        store.execute(q)
    }

    // 最近一晚:取过去 18 小时内 asleep 的样本,最早入睡 → 最晚醒来。
    private func lastNightSleep(_ cb: @escaping (Date?, Date?) -> Void) {
        let since = Date().addingTimeInterval(-18 * 3600)
        let pred = HKQuery.predicateForSamples(withStart: since, end: Date(), options: [])
        let q = HKSampleQuery(sampleType: sleepType, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            let asleep = (samples as? [HKCategorySample])?.filter { s in
                if #available(iOS 16.0, *) {
                    return s.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                        || s.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                        || s.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                        || s.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                } else {
                    return s.value == HKCategoryValueSleepAnalysis.asleep.rawValue
                }
            } ?? []
            guard !asleep.isEmpty else { cb(nil, nil); return }
            let start = asleep.map { $0.startDate }.min()
            let end = asleep.map { $0.endDate }.max()
            cb(start, end)
        }
        store.execute(q)
    }

    // MARK: - 上报

    private func post(_ payload: [String: Any]) {
        guard var comp = URLComponents(string: serverBase.hasSuffix("/") ? serverBase + "health" : serverBase + "/health") else { return }
        comp.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comp.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
}
