import AVFoundation
import Vision
import AppKit

/// Verrouille l'écran si tu es inactif (ni clavier ni souris) ET qu'aucun visage n'est vu.
/// La caméra ne s'allume que ~3 s lors de cette vérification, jamais en continu.
/// Tout est traité en local, aucune image n'est enregistrée.
final class PresenceMonitor: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "presence.enabled"); enabled ? start() : stop() } }
    @Published var delay: Int { didSet { UserDefaults.standard.set(delay, forKey: "presence.delay") } }
    @Published var status = ""

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ownmac.presence")          // callbacks vidéo + état
    private let sessionQueue = DispatchQueue(label: "ownmac.session")      // start/stop caméra (jamais depuis le callback)
    private var configured = false
    private var timer: Timer?
    private var screenOff = false
    // État de la vérification (accédé sur `queue`)
    private var checking = false
    private var checkStart = Date.distantPast
    private var lastAnalysis = Date.distantPast
    private var lastCheckEnd = Date.distantPast

    override init() {
        enabled = UserDefaults.standard.bool(forKey: "presence.enabled")
        let d = UserDefaults.standard.integer(forKey: "presence.delay")
        delay = [30, 60, 120, 300].contains(d) ? d : 60
        super.init()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.screenOff = true; self?.abortCheck() }
        }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.screenOff = false }
        }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.screenOff = true; self?.abortCheck() }
        dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.screenOff = false }
        if enabled { start() }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else { self.status = "Accès caméra refusé (Réglages Système > Confidentialité)"; self.enabled = false; return }
                self.status = "Actif"
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil; status = ""
        abortCheck()
    }

    /// Secondes depuis le dernier clavier / souris / trackpad.
    private var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        guard enabled, !screenOff else { return }
        queue.async {
            guard !self.checking, Date().timeIntervalSince(self.lastCheckEnd) >= Double(self.delay) else { return }
            guard self.idleSeconds >= Double(self.delay) else { return }
            self.beginCheck()
        }
    }

    // MARK: vérification ponctuelle (sur `queue`)

    private func beginCheck() {
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
        checking = true
        checkStart = Date()
        lastAnalysis = .distantPast
        sessionQueue.async { self.session.startRunning() }
    }

    private func endCheck(faceFound: Bool) {
        guard checking else { return }
        checking = false
        lastCheckEnd = Date()
        sessionQueue.async { self.session.stopRunning() }
        if !faceFound && idleSeconds >= Double(delay) {   // toujours inactif : on verrouille
            DispatchQueue.main.async { Self.lockScreen() }
        }
    }

    private func abortCheck() {
        queue.async { if self.checking { self.checking = false; self.lastCheckEnd = Date(); self.sessionQueue.async { self.session.stopRunning() } } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard checking else { return }
        let now = Date()
        // Si l'utilisateur est revenu pendant la vérification : on annule sans verrouiller.
        if idleSeconds < 2 { endCheck(faceFound: true); return }
        guard now.timeIntervalSince(lastAnalysis) >= 0.3 else { return }
        lastAnalysis = now
        if let px = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .up).perform([req])
            if let r = req.results, !r.isEmpty { endCheck(faceFound: true); return }
        }
        if now.timeIntervalSince(checkStart) >= 4 { endCheck(faceFound: false) }   // 4 s : laisse le temps à l'exposition
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
