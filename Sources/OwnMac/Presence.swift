import AVFoundation
import Vision
import AppKit

/// Verrouille l'écran quand aucun visage n'est détecté devant la webcam pendant N secondes.
/// Tout est traité en local, aucune image n'est enregistrée.
final class PresenceMonitor: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "presence.enabled"); enabled ? start() : stop() } }
    @Published var delay: Int { didSet { UserDefaults.standard.set(delay, forKey: "presence.delay") } }
    @Published var status = ""

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ownmac.presence")
    private var lastSeen = Date()
    private var lastAnalysis = Date.distantPast
    private var configured = false

    override init() {
        enabled = UserDefaults.standard.bool(forKey: "presence.enabled")
        let d = UserDefaults.standard.integer(forKey: "presence.delay")
        delay = d == 0 ? 30 : d
        super.init()
        let nc = NSWorkspace.shared.notificationCenter
        // Coupe la caméra quand l'écran dort / la session est verrouillée, la relance au retour
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.pause() }
        }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.resume() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.pause() }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.resume() }
        if enabled { start() }
    }

    private func pause() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    private func resume() { if enabled { lastSeen = Date(); queue.async { if self.configured, !self.session.isRunning { self.session.startRunning() } } } }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else { self.status = "Accès caméra refusé (Réglages Système > Confidentialité)"; self.enabled = false; return }
                self.queue.async { self.configureAndRun() }
            }
        }
    }

    private func configureAndRun() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .low
            guard let cam = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.status = "Aucune caméra disponible"; self.enabled = false }
                return
            }
            session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            session.commitConfiguration()
            configured = true
        }
        lastSeen = Date()
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async { self.status = "Actif" }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } }; status = "" }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= 1 else { return }   // 1 analyse / seconde
        lastAnalysis = now
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .up).perform([req])
        if let r = req.results, !r.isEmpty {
            lastSeen = now
        } else if now.timeIntervalSince(lastSeen) >= Double(delay) {
            lastSeen = now
            DispatchQueue.main.async { Self.lockScreen() }
        }
    }

    /// API privée de login.framework (utilisée par la plupart des apps de verrouillage), repli sur pmset.
    static func lockScreen() {
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            typealias Fn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: Fn.self)()
        } else {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]; try? p.run()
        }
    }
}
