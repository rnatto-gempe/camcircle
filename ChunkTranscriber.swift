import AVFoundation
import Speech

/// Transcreve por **blocos gravados em disco**, não em fluxo contínuo.
///
/// O `SFSpeechRecognizer` é muito melhor com arquivo do que com streaming: um
/// bloco de 20s recebe o contexto inteiro da fala e sai coerente, enquanto o
/// modo streaming encerra a cada silêncio, devolve `1110 No speech detected` e
/// fragmenta o texto em pedaços de duas palavras.
///
/// O preço é latência: o texto aparece ao fim de cada bloco. Como o requisito
/// aceita alguns segundos de atraso em troca de qualidade, é a troca certa.
///
/// Blocos vizinhos se sobrepõem por alguns segundos para nenhuma palavra cair na
/// emenda, e a sobreposição é removida por casamento de palavras.
final class ChunkTranscriber {

    /// Duração de cada bloco. Mais longo dá mais contexto e mais latência.
    var chunkSeconds: TimeInterval = 20
    /// Trecho final do bloco anterior repetido no início do seguinte.
    private let overlapSeconds: TimeInterval = 2.0

    private let localeID: String
    private let workDir: URL

    private var format: AVAudioFormat?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var framesInChunk: AVAudioFrameCount = 0

    /// Cauda do bloco atual, para abrir o próximo já com contexto.
    private var tail: [AVAudioPCMBuffer] = []

    private var committed: [String] = []
    private var chunkIndex = 0

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var chunksDone = 0
    private(set) var chunksInFlight = 0
    private(set) var framesFed = 0
    private(set) var writeFailures = 0
    private(set) var lastWriteError = ""
    private(set) var lastChunkBytes = 0
    private(set) var emptyResults = 0
    private(set) var flushByDuration = 0
    private(set) var flushByMismatch = 0
    private(set) var mismatchDetail = ""

    var onUpdate: ((String) -> Void)?
    var onStateChange: (() -> Void)?

    init(localeID: String, label: String) {
        self.localeID = localeID
        self.workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("captions-\(label)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    var text: String { committed.joined(separator: " ") }

    /// Segundos já acumulados no bloco em andamento.
    var currentChunkSeconds: TimeInterval {
        guard let format, format.sampleRate > 0 else { return 0 }
        return TimeInterval(framesInChunk) / format.sampleRate
    }

    var diagnostics: String {
        """
        blocos: \(chunksDone) prontos · \(chunksInFlight) em transcrição
              bloco atual: \(String(format: "%.1f", currentChunkSeconds))s de \(Int(chunkSeconds))s
              amostras recebidas: \(framesFed) · bytes do último bloco: \(lastChunkBytes)
              falhas de escrita: \(writeFailures) \(lastWriteError.isEmpty ? "" : "· " + lastWriteError)
              blocos vazios: \(emptyResults)
              flush por duração: \(flushByDuration) · por formato: \(flushByMismatch) \(mismatchDetail)
        """
    }

    // MARK: Ciclo

    func start() {
        guard !isRunning else { return }
        lastError = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.lastError = "Reconhecimento de fala não autorizado."
                    self.onStateChange?()
                    return
                }
                guard let rec = SFSpeechRecognizer(locale: Locale(identifier: self.localeID)),
                      rec.supportsOnDeviceRecognition else {
                    self.lastError = "Sem modelo on-device para \(self.localeID). Ative o Ditado nesse idioma."
                    self.onStateChange?()
                    return
                }
                self.isRunning = true
                self.onStateChange?()
            }
        }
    }

    func stop() {
        isRunning = false
        // Fecha o que estiver acumulado: melhor transcrever um bloco curto do
        // que descartar o que já foi falado.
        flush()
        onStateChange?()
    }

    func clear() {
        committed = []
        onUpdate?("")
    }

    // MARK: Entrada de áudio

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }
        framesFed += Int(buffer.frameLength)

        if file == nil { openChunk(format: buffer.format) }
        guard let file, let format else { return }

        // Formato mudou no meio (troca de dispositivo): recomeça o bloco.
        guard buffer.format.sampleRate == format.sampleRate,
              buffer.format.channelCount == format.channelCount else {
            flushByMismatch += 1
            mismatchDetail = "buffer \(Int(buffer.format.sampleRate))Hz/\(buffer.format.channelCount)ch vs bloco \(Int(format.sampleRate))Hz/\(format.channelCount)ch"
            flush()
            openChunk(format: buffer.format)
            return
        }

        do {
            try file.write(from: buffer)
            framesInChunk += buffer.frameLength
        } catch {
            writeFailures += 1
            lastWriteError = "\(error.localizedDescription) · buffer \(buffer.format) vs arquivo \(file.processingFormat)"
            return
        }

        // Mantém a cauda para a sobreposição do próximo bloco.
        tail.append(buffer)
        trimTail()

        if currentChunkSeconds >= chunkSeconds { flushByDuration += 1; flush() }
    }

    private func trimTail() {
        guard let format, format.sampleRate > 0 else { return }
        let wanted = AVAudioFrameCount(overlapSeconds * format.sampleRate)
        var total = tail.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        while total > wanted, tail.count > 1 {
            total -= tail[0].frameLength
            tail.removeFirst()
        }
    }

    private func openChunk(format newFormat: AVAudioFormat) {
        chunkIndex += 1
        let url = workDir.appendingPathComponent("chunk-\(chunkIndex).wav")
        try? FileManager.default.removeItem(at: url)

        // Grava em 16 bits inteiros: é o que o reconhecedor de arquivo espera
        // sem surpresa, e float32 num WAV já me rendeu arquivo malformado.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: newFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let opened = try? AVAudioFile(forWriting: url, settings: settings) else {
            lastError = "Não foi possível abrir o arquivo do bloco."
            onStateChange?()
            return
        }
        file = opened
        fileURL = url
        format = newFormat
        framesInChunk = 0

        // Abre já com a cauda do bloco anterior, para a frase não ser cortada.
        let carry = tail
        for buffer in carry where buffer.format.sampleRate == newFormat.sampleRate {
            try? opened.write(from: buffer)
            framesInChunk += buffer.frameLength
        }
    }

    /// Fecha o bloco atual e manda transcrever.
    private func flush() {
        guard let url = fileURL, framesInChunk > 0 else { return }
        // Fechar o AVAudioFile é o que finaliza o cabeçalho do WAV. Sem isso o
        // arquivo sai com duração inválida e o reconhecedor recusa.
        file = nil
        fileURL = nil
        let seconds = currentChunkSeconds
        framesInChunk = 0

        // Um bloco muito curto não vale uma transcrição.
        guard seconds >= 1.0 else {
            try? FileManager.default.removeItem(at: url)
            if isRunning { openChunkFromTail() }
            return
        }

        lastChunkBytes = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) .flatMap { $0 } ?? 0
        transcribe(url)
        if isRunning { openChunkFromTail() }
    }

    private func openChunkFromTail() {
        guard let format else { return }
        openChunk(format: format)
    }

    private func transcribe(_ url: URL) {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else { return }
        chunksInFlight += 1
        onStateChange?()

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true    // nada sai da máquina
        request.shouldReportPartialResults = false    // só o resultado inteiro
        request.addsPunctuation = true

        rec.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    let ns = error as NSError
                    self.chunksInFlight = max(0, self.chunksInFlight - 1)
                    // Bloco sem fala é rotina, não erro.
                    if ns.code != 1110 { self.lastError = ns.localizedDescription }
                    self.onStateChange?()
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                guard let result, result.isFinal else { return }

                self.chunksInFlight = max(0, self.chunksInFlight - 1)
                self.chunksDone += 1
                try? FileManager.default.removeItem(at: url)

                let words = result.bestTranscription.formattedString
                    .split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let fresh = Self.trimOverlap(committed: self.committed, words: words)
                if words.isEmpty { self.emptyResults += 1 }
                if !fresh.isEmpty {
                    self.committed.append(contentsOf: fresh)
                    if self.committed.count > 4000 {
                        self.committed.removeFirst(self.committed.count - 4000)
                    }
                    self.onUpdate?(self.text)
                }
                self.lastError = nil
                self.onStateChange?()
            }
        }
    }

    // MARK: Costura

    /// Comparação sem caixa, sem acento e sem pontuação: o reconhecedor varia
    /// esses detalhes entre duas passadas pelo mesmo trecho de áudio.
    private static func key(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Remove do início de `words` o maior trecho que já está no fim de
    /// `committed`. Prefere o casamento maior: repetir palavra é pior do que
    /// perder uma que já foi entregue.
    static func trimOverlap(committed: [String], words: [String], maxOverlap: Int = 40) -> [String] {
        let limit = min(maxOverlap, min(committed.count, words.count))
        guard limit > 0 else { return words }
        let tail = committed.suffix(limit).map(key)
        let head = words.prefix(limit).map(key)
        var k = limit
        while k > 0 {
            if Array(tail.suffix(k)) == Array(head.prefix(k)) {
                return Array(words.dropFirst(k))
            }
            k -= 1
        }
        return words
    }
}
