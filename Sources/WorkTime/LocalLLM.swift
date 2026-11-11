import Foundation
#if canImport(ggml)
import ggml
#endif

/// Ministral run inside WorkTime with llama.cpp on the GPU: loaded on first use and let go after a few idle minutes. All
/// llama.cpp state lives on one serial queue, so requests run one at a time.
final class LocalLLM: @unchecked Sendable {
    static let shared = LocalLLM()

    struct Reply {
        let text: String
        let promptTokens: Int
        let generatedTokens: Int
        let promptSeconds: TimeInterval
        let generateSeconds: TimeInterval

        var tokensPerSecond: Double { generateSeconds > 0 ? Double(generatedTokens) / generateSeconds : 0 }
    }

    private let queue = DispatchQueue(label: "local-llm", qos: .utility)
    private let lock = NSLock()
    private var loadedModel: LocalLLMModel?
    private var uses = 0
    private var stopping = false

    var isLoaded: Bool { lock.withLock { loadedModel != nil } }

    #if canImport(ggml)
    static let isCompiled = true
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    #else
    static let isCompiled = false
    #endif

    /// Whether a model is downloaded and this build can run it.
    static var isAvailable: Bool { isCompiled && LocalLLMModel.installed() != nil }

    /// Answers `prompt`, as JSON matching `schema` when one is given. `urgent` runs it at user-initiated priority instead
    /// of Whisper's quiet pace.
    func generate(system: String, prompt: String, schema: [String: Any]? = nil, maxTokens: Int? = nil,
                  temperature: Float = LocalLLMLogic.temperature, urgent: Bool = false) async throws -> Reply {
        let grammar = schema.map(LocalLLMLogic.grammar)
        let pace = WhisperLogic.currentPace(quiet: !urgent && TranscriptionEngine.quiet())
        let stop = StopFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async(qos: pace.qos, flags: .enforceQoS) {
                    continuation.resume(with: Result {
                        defer { self.scheduleUnload() }
                        return try self.run(system: system, prompt: prompt, grammar: grammar, maxTokens: maxTokens,
                                            temperature: temperature, threads: pace.threads, stop: stop)
                    })
                }
            }
        } onCancel: { stop.set() }
    }

    /// Loads the model ahead of a request that needs a quick answer.
    func prepare() {
        queue.async {
            guard LocalLLM.isAvailable else { return }
            try? self.load()
            self.scheduleUnload()
        }
    }

    /// Lets the model go. `wait` stops a running request and returns once it is freed, as Metal needs before the
    /// process exits.
    func unload(wait: Bool = false) {
        guard wait else { return queue.async { self.free() } }
        lock.withLock { stopping = true }
        queue.sync { free(); lock.withLock { stopping = false } }
    }

    private func scheduleUnload() {
        let use = lock.withLock { uses += 1; return uses }
        queue.asyncAfter(deadline: .now() + LocalLLMLogic.idleUnload) {
            if self.lock.withLock({ self.uses == use }) { self.free() }
        }
    }

    #if canImport(ggml)
    private static let batch = 1024

    private static let backend: Void = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        }, nil)
        llama_backend_init()
    }()

    private func load() throws {
        guard context == nil else { return }
        guard let file = LocalLLMModel.installed() else { throw LocalLLMError.notInstalled }
        Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(file.url().path, modelParams) else { throw LocalLLMError.couldNotLoad(file.name) }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(LocalLLMLogic.contextTokens)
        params.n_batch = UInt32(Self.batch)
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        params.type_k = GGML_TYPE_Q8_0
        params.type_v = GGML_TYPE_Q8_0
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw LocalLLMError.couldNotLoad(file.name)
        }
        self.model = model
        self.context = context
        lock.withLock { loadedModel = file }
    }

    private func free() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        lock.withLock { loadedModel = nil }
    }

    private func run(system: String, prompt: String, grammar: String?, maxTokens: Int?, temperature: Float,
                     threads: Int32, stop: StopFlag) throws -> Reply {
        if stop.isSet { throw CancellationError() }
        try load()
        guard let model, let context, let vocab = llama_model_get_vocab(model) else { throw LocalLLMError.notInstalled }
        llama_set_n_threads(context, threads, threads)
        llama_memory_clear(llama_get_memory(context), true)

        let tokens = try Self.tokens(of: try Self.chat(model: model, system: system, prompt: prompt), vocab: vocab)
        let room = LocalLLMLogic.contextTokens - tokens.count
        guard room > 16 else { throw LocalLLMError.tooLong(tokens: tokens.count) }
        let limit = min(room, maxTokens ?? room)

        let sampler = try Self.sampler(vocab: vocab, grammar: grammar, temperature: temperature)
        defer { llama_sampler_free(sampler) }

        let started = Date()
        var input = tokens
        for start in stride(from: 0, to: input.count, by: Self.batch) {
            if stop.isSet { throw CancellationError() }
            let count = min(Self.batch, input.count - start)
            let status = input.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress! + start, Int32(count))) }
            guard status == 0 else { throw NSError(domain: "llama", code: Int(status)) }
        }
        llama_synchronize(context)
        let prompted = Date()

        var bytes: [UInt8] = []
        var generated = 0
        var finished = false
        var piece = [CChar](repeating: 0, count: 256)
        while generated < limit {
            if stop.isSet || lock.withLock({ stopping }) { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                finished = true
                break
            }
            generated += 1
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length > 0 { bytes += piece[0..<Int(length)].map { UInt8(bitPattern: $0) } }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { break }
        }
        guard finished else { throw LocalLLMError.cutOff }
        return Reply(text: String(decoding: bytes, as: UTF8.self), promptTokens: tokens.count, generatedTokens: generated,
                     promptSeconds: prompted.timeIntervalSince(started), generateSeconds: Date().timeIntervalSince(prompted))
    }

    /// The conversation in the model's own chat template, ready for the answer.
    private static func chat(model: OpaquePointer, system: String, prompt: String) throws -> String {
        let strings: [UnsafeMutablePointer<CChar>] = ["system", system, "user", prompt].map { strdup($0)! }
        defer { strings.forEach { Darwin.free($0) } }
        var messages = [llama_chat_message(role: strings[0], content: strings[1]), llama_chat_message(role: strings[2], content: strings[3])]
        let template = llama_model_chat_template(model, nil)
        var buffer = [CChar](repeating: 0, count: (system.utf8.count + prompt.utf8.count) * 2 + 1024)
        var length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
        if length > buffer.count {
            buffer = [CChar](repeating: 0, count: Int(length) + 1)
            length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
        }
        guard length > 0 else { throw LocalLLMError.couldNotLoad("The chat template") }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func tokens(of text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString.dropLast())
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }

    private static func sampler(vocab: OpaquePointer, grammar: String?, temperature: Float) throws -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if let grammar {
            guard let constraint = llama_sampler_init_grammar(vocab, grammar, "root") else {
                llama_sampler_free(chain)
                throw LocalLLMError.badGrammar
            }
            llama_sampler_chain_add(chain, constraint)
        }
        if temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        }
        return chain
    }
    #else
    private func load() throws { throw LocalLLMError.unavailable }

    private func free() {}

    private func run(system: String, prompt: String, grammar: String?, maxTokens: Int?, temperature: Float,
                     threads: Int32, stop: StopFlag) throws -> Reply {
        throw LocalLLMError.unavailable
    }
    #endif

    /// Summarises a meeting with the downloaded model, at the quiet pace.
    static func summarise(_ lines: [String], language: MeetingLanguage,
                          progress: @MainActor (ProcessingStage) -> Void) async throws -> MeetingSummary {
        try await LocalLLMLogic.summarise(lines, language: language, progress: progress) { system, prompt in
            try await shared.generate(system: system, prompt: prompt, schema: ClaudeSummarizer.schema).text
        }
    }
}
