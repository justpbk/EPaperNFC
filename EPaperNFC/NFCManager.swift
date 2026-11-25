import CoreNFC
import SwiftUI

typealias NFCJob = (ESLClient, @escaping (String) -> Void) async throws -> String

final class NFCManager: NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    @Published var log: [String] = []
    @Published var busy = false
    var forceNDEF = false

    private var session: NFCTagReaderSession?
    private var job: NFCJob?

    func append(_ s: String) {
        DispatchQueue.main.async { self.log.append(s); if self.log.count > 300 { self.log.removeFirst() } }
    }

    func run(_ job: @escaping NFCJob) {
        guard NFCTagReaderSession.readingAvailable else { append("NFC not available on this device"); return }
        self.job = job
        session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: nil)
        session?.alertMessage = "Hold the top of your iPhone on the e-paper board and keep still."
        session?.begin()
        busy = true
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let e = error as? NFCReaderError,
           e.code != .readerSessionInvalidationErrorUserCanceled {
            append("Session ended: \(e.localizedDescription)")
        }
        DispatchQueue.main.async { self.busy = false }
        self.session = nil
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "More than one tag found. Try again."
            session.restartPolling(); return
        }

        let raw: RawSend
        switch tag {
        case .iso7816(let t):
            append("Tag: ISO7816, UID \(t.identifier.hex)")
            raw = { a in
                guard let apdu = NFCISO7816APDU(data: Data(a)) else { throw ESLError.badAPDU }
                let (d, s1, s2) = try await t.sendCommand(apdu: apdu)
                return ([UInt8](d), UInt16(s1) << 8 | UInt16(s2))
            }
        case .miFare(let t):
            append("Tag: ISO14443-4 (MiFare family \(t.mifareFamily.rawValue)), UID \(t.identifier.hex)")
            raw = { a in
                guard let apdu = NFCISO7816APDU(data: Data(a)) else { throw ESLError.badAPDU }
                let (d, s1, s2) = try await t.sendMiFareISO7816Command(apdu)
                return ([UInt8](d), UInt16(s1) << 8 | UInt16(s2))
            }
        default:
            session.invalidate(errorMessage: "Unsupported tag type."); return
        }

        guard let job else { session.invalidate(); return }
        let client = ESLClient(raw: raw, forceNDEF: forceNDEF, log: { [weak self] in self?.append($0) })

        Task {
            do {
                try await session.connect(to: tag)
                let msg = try await job(client) { status in session.alertMessage = status }
                append(msg)
                session.alertMessage = msg
                session.invalidate()
            } catch {
                append("Error: \(error.localizedDescription)")
                session.invalidate(errorMessage: error.localizedDescription)
            }
        }
    }
}
