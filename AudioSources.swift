import AVFoundation
import CoreAudio

// MARK: - Contrato

/// Fonte de áudio que entrega buffers para transcrição.
/// Microfone e saída do sistema implementam a mesma interface, então o pipeline
/// de reconhecimento não sabe de onde o som veio.
protocol AudioSource: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Chama o completion com nil em caso de sucesso, ou a mensagem de erro.
    func start(_ completion: @escaping (String?) -> Void)
    func stop()
}

// MARK: - Microfone

final class MicrophoneSource: AudioSource {

    private(set) var lastStep = "não iniciado"
    private let engine = AVAudioEngine()
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false

    private var configObserver: NSObjectProtocol?
    /// Quantas vezes o engine foi religado por mudança de configuração.
    private(set) var restarts = 0

    /// O `AVAudioEngine` **para sozinho** quando a configuração de hardware muda
    /// e não volta por conta própria. Criar o aggregate device do tap de sistema
    /// é exatamente uma dessas mudanças — era isso que matava o microfone quando
    /// o áudio do sistema era ligado. Aqui ele é religado, com o formato novo.
    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.restarts += 1
            self.lastStep = "religando após mudança de configuração (\(self.restarts))"
            self.reattach()
        }
    }

    /// Reinstala o tap com o formato atual e sobe o engine de novo.
    private func reattach() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastStep = "entrada indisponível ao religar"
            isRunning = false
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            lastStep = "engine religado (\(restarts))"
        } catch {
            lastStep = "falha ao religar: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func start(_ completion: @escaping (String?) -> Void) {
        guard !isRunning else { completion(nil); return }
        lastStep = "pedindo permissão"

        // Faltar esta permissão é uma falha silenciosa: o AVAudioEngine entrega
        // buffers vazios sem erro nenhum, e o app parece escutar sem transcrever.
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastStep = granted ? "permissão concedida" : "permissão negada"
                guard granted else {
                    completion("Microfone não autorizado. Libere em Ajustes do Sistema › Privacidade e Segurança › Microfone.")
                    return
                }
                let input = self.engine.inputNode
                let format = input.inputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    completion("Nenhuma entrada de áudio disponível.")
                    return
                }
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                    self.onBuffer?(buffer)
                }
                self.engine.prepare()
                do {
                    self.lastStep = "iniciando engine"
                    try self.engine.start()
                    self.lastStep = "engine rodando"
                    self.isRunning = true
                    self.observeConfigurationChanges()
                    completion(nil)
                } catch {
                    self.lastStep = "engine falhou: \(error.localizedDescription)"
                    input.removeTap(onBus: 0)
                    completion("Não foi possível iniciar o microfone: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lastStep = "parado"
    }
}

// MARK: - Saída do sistema

/// Captura o áudio que sai do sistema usando Core Audio process tap (macOS 14.2+).
///
/// Sem driver virtual: nada de BlackHole ou Loopback. O tap é criado em modo
/// `unmuted`, então você continua ouvindo normalmente enquanto é capturado.
///
/// O caminho é: cria o tap → embrulha num aggregate device privado junto com o
/// dispositivo de saída (que serve de referência de clock) → lê com um IOProc.
final class SystemAudioSource: AudioSource {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Formato entregue pelo tap: 48kHz, estéreo, float32 **entrelaçado**.
    private var tapFormat: AVAudioFormat?
    /// Mono 16kHz é o formato canônico de reconhecimento de fala. Entregar o
    /// estéreo entrelaçado do tap direto ao SFSpeech resulta em silêncio sem
    /// erro nenhum — foi exatamente o que aconteceu na primeira versão.
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000,
                                             channels: 1,
                                             interleaved: false)
    /// Fator de decimação inteiro (48000 / 16000 = 3).
    private var decimation = 3
    /// Amostras mono a 48kHz que sobraram do buffer anterior. Sem este resto, a
    /// decimação recomeçaria fora de fase a cada buffer e o áudio viraria mingau.
    private var carry: [Float] = []

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false

    /// Instrumentação: sem isto não há como saber se o silêncio vem do tap,
    /// da conversão ou do reconhecedor.
    private(set) var deliveredFrames = 0
    private(set) var peakLevel: Float = 0
    /// Pico absoluto, sem decaimento — o decaído engana quando lido depois.
    private(set) var peakEver: Float = 0

    /// Um registro por stream de entrada do aggregate: canais, bytes e pico.
    private(set) var bufferReport: [(channels: Int, bytes: Int, peak: Float)] = []

    var bufferSummary: String {
        guard !bufferReport.isEmpty else { return "nenhum buffer visto ainda" }
        return bufferReport.enumerated().map { index, info in
            String(format: "buffer[%d] %dch %dB pico %.4f", index, info.channels, info.bytes, info.peak)
        }.joined(separator: " | ")
    }

    /// Grava o áudio já convertido, para inspecionar o que chega ao reconhecedor.
    private var dumpFile: AVAudioFile?
    private var rawDumpFile: AVAudioFile?

    /// Grava o áudio CRU do tap, antes de qualquer processamento meu — é o que
    /// separa "o tap entrega áudio ruim" de "meu processamento estraga o áudio".
    func startRawDump(to path: String) {
        guard let tapFormat else { return }
        rawDumpFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                       settings: tapFormat.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
    }

    func startDump(to path: String) {
        guard let speechFormat else { return }
        dumpFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                    settings: speechFormat.settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
    }

    func stopDump() { dumpFile = nil; rawDumpFile = nil }

    /// O IOProc roda em thread de tempo real; a entrega sai dela imediatamente.
    private let delivery = DispatchQueue(label: "com.startse.captions.systemaudio")

    func start(_ completion: @escaping (String?) -> Void) {
        guard !isRunning else { completion(nil); return }

        guard let outputUID = Self.defaultOutputUID() else {
            completion("Não foi possível identificar a saída de áudio padrão.")
            return
        }

        // Tap global de toda a saída, sem excluir processo nenhum.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "CaptionsSystemTap"
        description.isPrivate = true
        description.muteBehavior = .unmuted        // você continua ouvindo

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            completion("Captura de áudio do sistema recusada (erro \(tapStatus)). Verifique Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema.")
            return
        }
        tapID = tap

        guard let tapUID = Self.stringProperty(tap, kAudioTapPropertyUID) else {
            cleanup()
            completion("Não foi possível ler o identificador do tap.")
            return
        }

        // Formato entregue pelo tap: tipicamente 48kHz, 2 canais, float32.
        var asbd = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr,
              let audioFormat = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            completion("Não foi possível ler o formato do tap.")
            return
        }
        tapFormat = audioFormat

        guard let speechFormat else { cleanup(); return }
        let ratio = audioFormat.sampleRate / speechFormat.sampleRate
        guard ratio >= 1, abs(ratio.rounded() - ratio) < 0.001 else {
            cleanup()
            completion("Taxa de amostragem \(Int(audioFormat.sampleRate))Hz não é múltiplo de 16kHz.")
            return
        }
        decimation = Int(ratio.rounded())
        carry = []

        // Aggregate privado: não aparece na lista de dispositivos do usuário.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Captions System Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard aggStatus == noErr else {
            cleanup()
            completion("Não foi possível montar o dispositivo de captura (erro \(aggStatus)).")
            return
        }
        aggregateID = aggregateDevice

        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard ioStatus == noErr, let proc else {
            cleanup()
            completion("Não foi possível iniciar a leitura do áudio (erro \(ioStatus)).")
            return
        }
        procID = proc

        let startStatus = AudioDeviceStart(aggregateDevice, proc)
        guard startStatus == noErr else {
            cleanup()
            completion("Não foi possível iniciar o dispositivo (erro \(startStatus)).")
            return
        }

        isRunning = true
        completion(nil)
    }

    /// Chamado na thread de áudio de tempo real: só copia e sai. A conversão de
    /// formato é trabalho pesado e acontece fora daqui, na fila de entrega.
    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat else { return }
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))

        // Diagnóstico: o aggregate pode expor mais de um stream de entrada, e
        // presumir que o primeiro é o tap dá silêncio ou o microfone do headset.
        if bufferReport.isEmpty || bufferReport.count != list.count {
            bufferReport = list.map { buffer in
                var peak: Float = 0
                if let raw = buffer.mData {
                    let count = Int(buffer.mDataByteSize) / 4
                    let samples = raw.assumingMemoryBound(to: Float.self)
                    for i in 0..<count { peak = max(peak, abs(samples[i])) }
                }
                return (channels: Int(buffer.mNumberChannels),
                        bytes: Int(buffer.mDataByteSize),
                        peak: peak)
            }
        } else {
            for (index, buffer) in list.enumerated() where index < bufferReport.count {
                guard let raw = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / 4
                let samples = raw.assumingMemoryBound(to: Float.self)
                var peak: Float = 0
                for i in 0..<count { peak = max(peak, abs(samples[i])) }
                bufferReport[index].peak = max(bufferReport[index].peak, peak)
            }
        }

        guard let source = list.first, source.mDataByteSize > 0, let raw = source.mData
        else { return }

        let bytesPerFrame = max(1, tapFormat.streamDescription.pointee.mBytesPerFrame)
        let frames = source.mDataByteSize / bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames

        // Formato entrelaçado: um único bloco contíguo, uma cópia só.
        if let target = buffer.floatChannelData?[0] {
            memcpy(target, raw, Int(source.mDataByteSize))
        } else if let target = buffer.audioBufferList.pointee.mBuffers.mData {
            memcpy(target, raw, Int(source.mDataByteSize))
        } else {
            return
        }

        delivery.async { [weak self] in
            if let raw = self?.rawDumpFile { try? raw.write(from: buffer) }
            self?.convertAndDeliver(buffer)
        }
    }

    /// Mixa para mono e decima para 16kHz na mão.
    ///
    /// Feito sem `AVAudioConverter` de propósito: ele é stateful, e chamá-lo por
    /// buffer com `.noDataNow` reinicia o filtro de reamostragem a cada ~21ms.
    /// O resultado tem o nível certo e o conteúdo destruído — medi pico e RMS
    /// idênticos ao original e ainda assim "No speech detected".
    private func convertAndDeliver(_ input: AVAudioPCMBuffer) {
        guard let speechFormat, let source = input.floatChannelData?[0] else { return }

        let channels = Int(input.format.channelCount)
        let frames = Int(input.frameLength)

        // Um canal só, não a média dos dois. Se o mixdown do tap entregar os
        // canais em fase oposta, somá-los cancela a fala e sobra o ruído — o
        // nível medido continua igual e o conteúdo vira irreconhecível.
        var mono = carry
        mono.reserveCapacity(carry.count + frames)
        for frame in 0..<frames {
            mono.append(source[frame * channels])
        }

        // Média de cada grupo de `decimation` amostras: serve de filtro
        // anti-aliasing simples e mantém a fase contínua entre buffers.
        let outputCount = mono.count / decimation
        guard outputCount > 0 else { carry = mono; return }
        carry = Array(mono[(outputCount * decimation)...])

        guard let output = AVAudioPCMBuffer(pcmFormat: speechFormat,
                                            frameCapacity: AVAudioFrameCount(outputCount)),
              let target = output.floatChannelData?[0] else { return }
        output.frameLength = AVAudioFrameCount(outputCount)

        for i in 0..<outputCount {
            var sum: Float = 0
            for j in 0..<decimation { sum += mono[i * decimation + j] }
            target[i] = sum / Float(decimation)
        }

        // Pico serve de diagnóstico: distingue "não chega áudio" de
        // "chega áudio, mas o reconhecedor não entende".
        if let samples = output.floatChannelData?[0] {
            var peak: Float = 0
            for i in 0..<Int(output.frameLength) { peak = max(peak, abs(samples[i])) }
            peakLevel = max(peakLevel * 0.995, peak)
            peakEver = max(peakEver, peak)
        }
        deliveredFrames += Int(output.frameLength)
        if let dumpFile { try? dumpFile.write(from: output) }

        onBuffer?(output)
    }

    func stop() {
        cleanup()
        isRunning = false
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { cleanup() }

    // MARK: Leitura de propriedades

    private static func defaultOutputUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// Leitura tipada de propriedade CFString. Um genérico aqui seria incorreto:
    /// o valor é uma referência de objeto, não bytes soltos.
    private static func stringProperty(_ id: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
