import AudioToolbox
import AVFoundation
import UserNotifications

/// Loud, looping alarm for safety alerts on the iPhone.
///
/// Uses the `.playback` audio category, so it plays with the Ring/Silent switch on silent and
/// isn't mixed under other audio. It can't raise the system volume (no public API does), and
/// without push notifications and Apple's Critical Alerts entitlement it can't sound while the
/// app is suspended. "Overnight alarm" mode (`keepAwake`) works around the latter by holding an
/// inaudible audio session so the app keeps running and polling while the phone is locked.
@MainActor
final class AlarmPlayer {
    static let shared = AlarmPlayer()

    private var alarm: AVAudioPlayer?
    private var keepAlive: AVAudioPlayer?
    private var vibration: Task<Void, Never>?
    private(set) var isSounding = false

    static let soundName = "alarm.caf"
    /// Set via AB_CRITICAL_ALERTS_ENTITLED once Apple grants the Critical Alerts entitlement.
    static let criticalAlertsEntitled = Bundle.main.object(forInfoDictionaryKey: "ABCriticalAlertsEntitled") as? String == "YES"

    func start() {
        guard !isSounding, let url = Bundle.main.url(forResource: "alarm", withExtension: "caf") else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        alarm = try? AVAudioPlayer(contentsOf: url)
        alarm?.numberOfLoops = -1
        alarm?.volume = 1
        alarm?.play()
        isSounding = true
        vibration = Task {
            while !Task.isCancelled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        alarm?.stop()
        alarm = nil
        vibration?.cancel()
        vibration = nil
        isSounding = false
        if keepAlive != nil { startKeepAlive() } else { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// Overnight alarm mode: an inaudible looping player keeps the app running in the background
    /// (UIBackgroundModes: audio) so polling continues and the alarm can sound on a locked phone.
    /// Costs battery; meant for a phone on its charger. App Review would likely reject this.
    func keepAwake(_ on: Bool) {
        if on { startKeepAlive() } else {
            keepAlive?.stop()
            keepAlive = nil
            if !isSounding { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }

    private func startKeepAlive() {
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "caf") else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if keepAlive == nil {
            keepAlive = try? AVAudioPlayer(contentsOf: url)
            keepAlive?.numberOfLoops = -1
            keepAlive?.volume = 0
        }
        keepAlive?.play()
    }

    /// Notification with the alarm sound, for when the app isn't in the foreground. Sounds once
    /// (up to 30 s of audio). A critical alert (red, ignores silent mode and Focus) once Apple
    /// grants the entitlement; until then it respects the silent switch and Focus.
    static func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if criticalAlertsEntitled {
            content.sound = .criticalSoundNamed(UNNotificationSoundName(soundName), withAudioVolume: 1)
            content.interruptionLevel = .critical
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
            content.interruptionLevel = .timeSensitive // honoured only with the paid-team entitlement
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alarm-\(id)", content: content, trigger: nil))
    }
}
